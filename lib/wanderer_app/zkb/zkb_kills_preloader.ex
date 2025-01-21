defmodule WandererApp.Zkb.KillsPreloader do
  @moduledoc """
  (1) A 'quick pass' (fewer kills) and
  (2) An 'expanded pass' (more kills).
  """

  use GenServer
  require Logger

  alias WandererApp.Zkb.KillsProvider
  alias WandererApp.Zkb.KillsProvider.KillsCache

  @quick_limit 1
  @expanded_limit 25
  @default_hours 1
  @default_max_concurrency 2

  # How many minutes back we look for “last active” maps
  @last_active_cutoff 30

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

    # Kick off the preload passes
    send(self(), :start_preload)
    {:ok, state}
  end

  @impl true
  def handle_info(:start_preload, state) do
    cutoff_time =
      DateTime.utc_now()
      |> DateTime.add(-@last_active_cutoff, :minute)

    last_active_result = WandererApp.Api.MapState.get_last_active(cutoff_time)

    # gather last-active maps, or fallback
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

    # gather systems from these maps
    system_tuples = gather_visible_systems(last_active_maps)
    unique_systems = Enum.uniq(system_tuples)

    Logger.debug("""
      [KillsPreloader] Found #{length(unique_systems)} unique systems \
      across #{length(last_active_maps)} map(s)
    """)

    # ---- QUICK PASS ----
    state_quick = %{state | phase: :quick_pass}

    {time_quick_ms, state_after_quick} =
      measure_execution_time(fn ->
        do_quick_pass(unique_systems, state_quick)
      end)

    Logger.info("""
      [KillsPreloader] Phase 1 (quick) done => calls_count=#{state_after_quick.calls_count},
      elapsed=#{time_quick_ms}ms
    """)

    # ---- EXPANDED PASS ----
    state_expanded = %{state_after_quick | phase: :expanded_pass}

    {time_expanded_ms, final_state} =
      measure_execution_time(fn ->
        do_expanded_pass(unique_systems, state_expanded)
      end)

    Logger.info("""
      [KillsPreloader] Phase 2 (expanded) done => calls_count=#{final_state.calls_count},
      elapsed=#{time_expanded_ms}ms
    """)

    # Reset phase to :idle
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
      |> Enum.reduce({state, %{}}, &reduce_fetch_result(:quick, &1, &2))

    if map_size(kills_map) > 0 do
      broadcast_all_kills(kills_map, :quick)
    end

    final_state
  end

  defp fetch_quick_kills_for_system(_map_id, system_id, st) do
    Logger.debug("[KillsPreloader] Quick fetch for system=#{system_id}")

    # 1 kill, from the last hour, no force
    case KillsProvider.Fetcher.fetch_kills_for_system(system_id, @default_hours, st,
           limit: @quick_limit,
           force: false
         ) do
      {:ok, kills, updated_state} ->
        {:ok, system_id, kills, updated_state}

      {:error, reason, updated_state} ->
        Logger.warning("[KillsPreloader] Quick fetch failed => system=#{system_id}, reason=#{inspect(reason)}")
        {:error, reason, updated_state}
    end
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
      |> Enum.reduce({state, %{}}, &reduce_fetch_result(:expanded, &1, &2))

    if map_size(kills_map) > 0 do
      broadcast_all_kills(kills_map, :expanded)
    end

    final_state
  end

  defp fetch_expanded_kills_for_system(_map_id, system_id, st) do
    # 1) Try up to @expanded_limit from the last hour
    with {:ok, kills_1h, updated_state} <-
           KillsProvider.Fetcher.fetch_kills_for_system(system_id, @default_hours, st,
             limit: @expanded_limit,
             force: true
           ),
         {:ok, final_kills, final_state} <-
           maybe_fetch_24h_if_needed(system_id, kills_1h, updated_state) do
      {:ok, system_id, final_kills, final_state}
    else
      {:error, reason, updated_state} ->
        Logger.warning("[KillsPreloader] Expanded fetch (1-hour) failed => system=#{system_id}, reason=#{inspect(reason)}")
        {:error, reason, updated_state}
    end
  end

  defp maybe_fetch_24h_if_needed(system_id, kills_1h, st) do
    if length(kills_1h) < @expanded_limit do
      needed = @expanded_limit - length(kills_1h)

      case KillsProvider.Fetcher.fetch_kills_for_system(system_id, 24, st,
             limit: needed,
             force: true
           ) do
        {:ok, _kills_24h, updated_state2} ->
          final_kills =
            KillsCache.fetch_cached_kills(system_id)
            |> Enum.take(@expanded_limit)

          {:ok, final_kills, updated_state2}

        {:error, reason2, updated_state2} ->
          Logger.warning("[KillsPreloader] 24h fetch failed => system=#{system_id}, reason=#{inspect(reason2)}")
          {:error, reason2, updated_state2}
      end
    else
      {:ok, kills_1h, st}
    end
  end

  defp reduce_fetch_result(phase, task_result, {acc_st, acc_map}) do
    case task_result do
      {:ok, {:ok, sys_id, kills, updated_state}} ->
        new_st = merge_calls_count(acc_st, updated_state)
        new_map = Map.put(acc_map, sys_id, kills)
        {new_st, new_map}

      {:ok, {:error, reason, updated_state}} ->
        if phase == :quick do
          Logger.warning("[KillsPreloader] Quick fetch task failed => #{inspect(reason)}")
        else
          Logger.error("[KillsPreloader] Expanded fetch task failed => #{inspect(reason)}")
        end

        new_st = merge_calls_count(acc_st, updated_state)
        {new_st, acc_map}

      {:error, reason} ->
        Logger.error("[KillsPreloader] #{phase} fetch task crashed => #{inspect(reason)}")
        {acc_st, acc_map}
    end
  end

  defp gather_visible_systems(maps) do
    maps
    |> Enum.flat_map(fn map_record ->
      case WandererApp.MapSystemRepo.get_visible_by_map(map_record.map_id) do
        {:ok, systems} ->
          Enum.map(systems, fn sys -> {map_record.map_id, sys.solar_system_id} end)

        {:error, reason} ->
          Logger.warning("[KillsPreloader] get_visible_by_map failed => map_id=#{map_record.map_id}, reason=#{inspect(reason)}")
          []
      end
    end)
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
