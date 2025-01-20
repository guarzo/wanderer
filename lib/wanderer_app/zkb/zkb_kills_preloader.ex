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

    # Kick off the preload passes
    send(self(), :start_preload)
    {:ok, state}
  end

  @impl true
  def handle_info(:start_preload, state) do
    state_quick = %{state | phase: :quick_pass}

    {time_quick_ms, state_after_quick} =
      measure_execution_time(fn ->
        do_quick_pass(state_quick)
      end)

    Logger.info("""
      [KillsPreloader] Phase 1 (quick) done => calls_count=#{state_after_quick.calls_count},
      elapsed=#{time_quick_ms}ms
    """)

    state_expanded = %{state_after_quick | phase: :expanded_pass}

    {time_expanded_ms, final_state} =
      measure_execution_time(fn ->
        do_expanded_pass(state_expanded)
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

  @doc false
  defp do_quick_pass(state) do
    cutoff_time =
      DateTime.utc_now()
      |> DateTime.add(-@last_active_cutoff, :minute)

    case WandererApp.Api.MapState.get_last_active(cutoff_time) do
      {:ok, []} ->
        Logger.warning("[KillsPreloader] No last-active maps found, skipping quick pass.")
        state

      {:ok, last_active_maps} ->
        Logger.debug("[KillsPreloader] Quick pass: found #{length(last_active_maps)} active maps")

        # Gather visible systems from the last-active maps
        all_systems = gather_visible_systems(last_active_maps)
        Logger.debug("[KillsPreloader] Quick pass: total systems=#{length(all_systems)}")

        {final_state, kills_map} =
          all_systems
          |> Task.async_stream(
            fn {map_id, system_id} ->
              fetch_quick_kills_for_system(map_id, system_id, state)
            end,
            max_concurrency: state.max_concurrency,
            timeout: :timer.minutes(2)
          )
          |> Enum.reduce({state, %{}}, &reduce_quick_result/2)

        # Broadcast once for all quick kills
        if map_size(kills_map) > 0 do
          broadcast_all_kills(kills_map, :quick)
        end

        final_state

      {:error, reason} ->
        Logger.error("[KillsPreloader] Could not load last-active maps => #{inspect(reason)}")
        state
    end
  end

  @doc false
  defp do_expanded_pass(state) do
    cutoff_time =
      DateTime.utc_now()
      |> DateTime.add(-@last_active_cutoff, :minute)

    case WandererApp.Api.MapState.get_last_active(cutoff_time) do
      {:ok, []} ->
        Logger.warning("[KillsPreloader] No last-active maps found, skipping expanded pass.")
        state

      {:ok, last_active_maps} ->
        Logger.debug("[KillsPreloader] Expanded pass: found #{length(last_active_maps)} active maps")

        all_systems = gather_visible_systems(last_active_maps)
        Logger.debug("[KillsPreloader] Expanded pass: total systems=#{length(all_systems)}")

        {final_state, kills_map} =
          all_systems
          |> Task.async_stream(
            fn {map_id, system_id} ->
              fetch_expanded_kills_for_system(map_id, system_id, state)
            end,
            max_concurrency: state.max_concurrency,
            timeout: :timer.minutes(5)
          )
          |> Enum.reduce({state, %{}}, &reduce_expanded_result/2)

        # Broadcast once for all expanded kills
        if map_size(kills_map) > 0 do
          broadcast_all_kills(kills_map, :expanded)
        end

        final_state

      {:error, reason} ->
        Logger.error("[KillsPreloader] Could not load last-active maps => #{inspect(reason)}")
        state
    end
  end

  @doc false
  defp fetch_quick_kills_for_system(_map_id, system_id, st) do
    Logger.debug("[KillsPreloader] Quick fetch for system=#{system_id}")
    case KillsProvider.Fetcher.fetch_kills_for_system_up_to_age_and_limit(
           system_id,
           @default_hours,
           @quick_limit,
           st
         ) do
      {:ok, kills, updated_state} ->
        {:ok, system_id, kills, updated_state}

      {:error, reason, updated_state} ->
        Logger.warning("[KillsPreloader] Quick fetch failed => system=#{system_id}, reason=#{inspect(reason)}")
        {:error, reason, updated_state}
    end
  end

  @doc false
  defp fetch_expanded_kills_for_system(_map_id, system_id, st) do
    case KillsProvider.Fetcher.fetch_kills_for_system_up_to_age_and_limit(
           system_id,
           1,                  # 1 hour
           @expanded_limit,
           st,
           force: true
         ) do
      {:ok, kills_1h, updated_state} ->
        if length(kills_1h) < @expanded_limit do
          needed = @expanded_limit - length(kills_1h)
          case KillsProvider.Fetcher.fetch_kills_for_system_up_to_age_and_limit(
                 system_id,
                 24,  # check up to 24 hours if needed
                 needed,
                 updated_state,
                 force: true
               ) do
            {:ok, _kills_24h, updated_state2} ->
              final_kills =
                KillsCache.fetch_cached_kills(system_id)
                |> Enum.take(@expanded_limit)

              {:ok, system_id, final_kills, updated_state2}

            {:error, reason2, updated_state2} ->
              Logger.warning("[KillsPreloader] 24h fetch failed => system=#{system_id}, reason=#{inspect(reason2)}")
              {:error, reason2, updated_state2}
          end
        else
          {:ok, system_id, kills_1h, updated_state}
        end

      {:error, reason, updated_state} ->
        Logger.warning("[KillsPreloader] Expanded fetch (1-hour) failed => system=#{system_id}, reason=#{inspect(reason)}")
        {:error, reason, updated_state}
    end
  end

  @doc false
  defp gather_visible_systems(map_states) do
    map_states
    |> Enum.flat_map(fn map_state ->
      case WandererApp.MapSystemRepo.get_visible_by_map(map_state.map_id) do
        {:ok, systems} ->
          # Return a list of {map_id, system_id} tuples
          Enum.map(systems, fn sys ->
            {map_state.map_id, sys.solar_system_id}
          end)

        {:error, reason} ->
          Logger.warning("[KillsPreloader] get_visible_by_map failed => map_id=#{map_state.map_id}, reason=#{inspect(reason)}")
          []
      end
    end)
  end

  @doc false
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

  @doc false
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

  @doc false
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
