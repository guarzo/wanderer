defmodule WandererApp.Zkb.KillsPreloader do
  @moduledoc """
  (1) A 'quick pass' (fewer kills) and
  (2) An 'expanded pass' (more kills).
  """

  use GenServer
  require Logger

  alias WandererApp.Zkb.KillsProvider
  alias WandererApp.Zkb.KillsProvider.KillsCache

  @default_hours 1            # For "quick" fetch or the 1-hour portion of expanded
  @expanded_hours 24          # The fallback age in hours if 1-hour kills are insufficient

  @quick_kills_limit 1        # For quick pass
  @expanded_kills_limit 25    # For expanded pass

  @default_max_concurrency 2
  @last_active_cutoff 30

  @doc """
  Starts the KillsPreloader GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      phase: :idle,
      calls_count: 0,
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    }

    send(self(), :start_preload)
    {:ok, state}
  end

  @impl true
  def handle_info(:start_preload, state) do
    cutoff_time = DateTime.utc_now() |> DateTime.add(-@last_active_cutoff, :minute)

    last_active_result = WandererApp.Api.MapState.get_last_active(cutoff_time)

    last_active_maps =
      case last_active_result do
        {:ok, []} ->
          Logger.warning("[KillsPreloader] No last-active maps found. Using fallback logic...")

          fallback_all_maps = WandererApp.Api.Map.available()

          fallback_map =
            fallback_all_maps
            |> Enum.max_by(& &1.updated_at, fn -> nil end)

          if fallback_map, do: [fallback_map], else: []

        {:ok, maps} ->
          maps

        {:error, reason} ->
          Logger.error("[KillsPreloader] Could not load last-active maps => #{inspect(reason)}")
          []
      end

    system_list = gather_visible_systems(last_active_maps)
    unique_systems = Enum.uniq(system_list)

    Logger.debug("[KillsPreloader] Found #{length(unique_systems)} unique systems across #{length(last_active_maps)} map(s)")

    state_quick = %{state | phase: :quick_pass}
    {time_quick_ms, state_after_quick} =
      measure_execution_time(fn ->
        do_quick_pass(unique_systems, state_quick)
      end)

    Logger.info("""
    [KillsPreloader] Phase 1 (quick) done => calls_count=#{state_after_quick.calls_count},
    elapsed=#{time_quick_ms}ms
    """)

    state_expanded = %{state_after_quick | phase: :expanded_pass}
    {time_expanded_ms, final_state} =
      measure_execution_time(fn ->
        do_expanded_pass(unique_systems, state_expanded)
      end)

    Logger.info("""
    [KillsPreloader] Phase 2 (expanded) done => calls_count=#{final_state.calls_count},
    elapsed=#{time_expanded_ms}ms
    """)

    {:noreply, %{final_state | phase: :idle}}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  defp do_quick_pass(system_tuples, state) do
    {final_state, kills_map} =
      system_tuples
      |> Task.async_stream(
        fn {map_id, system_id} ->
          fetch_quick_kills_for_system(map_id, system_id, state)
        end,
        max_concurrency: state.max_concurrency,
        timeout: :timer.minutes(2)
      )
      |> Enum.reduce({state, %{}}, &reduce_quick_result/2)

    if map_size(kills_map) > 0 do
      broadcast_all_kills(kills_map, :quick)
    end

    final_state
  end

  defp do_expanded_pass(system_tuples, state) do
    {final_state, kills_map} =
      system_tuples
      |> Task.async_stream(
        fn {map_id, system_id} ->
          fetch_expanded_kills_for_system(map_id, system_id, state)
        end,
        max_concurrency: state.max_concurrency,
        timeout: :timer.minutes(5)
      )
      |> Enum.reduce({state, %{}}, &reduce_expanded_result/2)

    if map_size(kills_map) > 0 do
      broadcast_all_kills(kills_map, :expanded)
    end

    final_state
  end

  defp fetch_quick_kills_for_system(_map_id, system_id, st) do
    Logger.debug("[KillsPreloader] Quick fetch for system=#{system_id}")

    case KillsProvider.Fetcher.fetch_kills_for_system_up_to_age_and_limit(
           system_id,
           @default_hours,
           @quick_kills_limit,
           st
         ) do
      {:ok, kills, updated_state} ->
        {:ok, system_id, kills, updated_state}

      {:error, reason, updated_state} ->
        Logger.warning("[KillsPreloader] Quick fetch failed => system=#{system_id}, reason=#{inspect(reason)}")
        {:error, reason, updated_state}
    end
  end

  defp fetch_expanded_kills_for_system(_map_id, system_id, st) do
    with {:ok, kills_default_time, updated_state} <-
           KillsProvider.Fetcher.fetch_kills_for_system_up_to_age_and_limit(
             system_id,
             @default_hours,
             @expanded_kills_limit,
             st,
             force: true
           ),
         {:ok, final_kills, final_state} <-
           maybe_fetch_24h_if_needed(system_id, kills_default_time, updated_state)
    do
      {:ok, system_id, final_kills, final_state}
    else
      {:error, reason, updated_state} ->
        Logger.warning("[KillsPreloader] Expanded fetch (1-hour) failed => system=#{system_id}, reason=#{inspect(reason)}")
        {:error, reason, updated_state}
    end
  end

  defp maybe_fetch_24h_if_needed(system_id, kills_default_time, st) do
    if length(kills_default_time) < @expanded_kills_limit do
      needed = @expanded_kills_limit - length(kills_default_time)

      case KillsProvider.Fetcher.fetch_kills_for_system_up_to_age_and_limit(
             system_id,
             @expanded_hours,
             needed,
             st,
             force: true
           ) do
        {:ok, _kills_expanded_time, updated_state2} ->
          final_kills =
            KillsCache.fetch_cached_kills(system_id)
            |> Enum.take(@expanded_kills_limit)

          {:ok, final_kills, updated_state2}

        {:error, reason2, updated_state2} ->
          Logger.warning("[KillsPreloader] 24h fetch failed => system=#{system_id}, reason=#{inspect(reason2)}")
          {:error, reason2, updated_state2}
      end
    else
      {:ok, kills_default_time, st}
    end
  end

  defp gather_visible_systems(maps) do
    maps
    |> Enum.flat_map(&visible_systems_for_map/1)
  end

  defp visible_systems_for_map(map_record) do
    case WandererApp.MapSystemRepo.get_visible_by_map(map_record.map_id) do
      {:ok, systems} ->
        # Return a list of {map_id, system_id} tuples
        Enum.map(systems, fn sys ->
          {map_record.map_id, sys.solar_system_id}
        end)

      {:error, reason} ->
        Logger.warning("[KillsPreloader] get_visible_by_map failed => map_id=#{map_record.map_id}, reason=#{inspect(reason)}")
        []
    end
  end

  defp reduce_quick_result({:ok, {:ok, sys_id, kills, updated_state}}, {acc_st, acc_map}) do
    new_st = merge_calls_count(acc_st, updated_state)
    new_map = Map.put(acc_map, sys_id, kills)
    {new_st, new_map}
  end

  defp reduce_quick_result({:ok, {:error, reason, updated_state}}, {acc_st, acc_map}) do
    Logger.warning("[KillsPreloader] Quick fetch task failed => #{inspect(reason)}")
    new_st = merge_calls_count(acc_st, updated_state)
    {new_st, acc_map}
  end

  defp reduce_quick_result({:error, reason}, {acc_st, acc_map}) do
    Logger.error("[KillsPreloader] Quick fetch task crashed => #{inspect(reason)}")
    {acc_st, acc_map}
  end

  defp reduce_expanded_result({:ok, {:ok, sys_id, kills, updated_state}}, {acc_st, acc_map}) do
    new_st = merge_calls_count(acc_st, updated_state)
    new_map = Map.put(acc_map, sys_id, kills)
    {new_st, new_map}
  end

  defp reduce_expanded_result({:ok, {:error, reason, updated_state}}, {acc_st, acc_map}) do
    Logger.error("[KillsPreloader] Expanded fetch task failed => #{inspect(reason)}")
    new_st = merge_calls_count(acc_st, updated_state)
    {new_st, acc_map}
  end

  defp reduce_expanded_result({:error, reason}, {acc_st, acc_map}) do
    Logger.error("[KillsPreloader] Expanded fetch task crashed => #{inspect(reason)}")
    {acc_st, acc_map}
  end

  defp broadcast_all_kills(kills_map, phase_type) do
    Logger.debug("[KillsPreloader] Broadcasting #{map_size(kills_map)} kills (#{phase_type})")

    Phoenix.PubSub.broadcast!(
      WandererApp.PubSub,
      "zkb_preload",
      %{
        event: :detailed_kills_updated,
        payload: kills_map,
        fetch_type: phase_type
      }
    )
  end

  defp merge_calls_count(%{calls_count: c1} = st1, %{calls_count: c2}),
    do: %{st1 | calls_count: c1 + c2}

  defp merge_calls_count(st1, _other),
    do: st1

  defp measure_execution_time(fun) when is_function(fun, 0) do
    start = System.monotonic_time()
    result = fun.()
    finish = System.monotonic_time()
    ms = System.convert_time_unit(finish - start, :native, :millisecond)
    {ms, result}
  end
end
