defmodule WandererApp.Zkb.KillsPreloader do
  @moduledoc """
  Two-phase preload for each visible system:

  1) Quick pass: 1 kill (up to 1h old)
  2) Expanded pass: up to 25 kills. Phase 2 always "forces" a refetch (ignores recent window).
     If <25 kills found in last hour, expand to 24h, still up to 25 total.
  """

  use GenServer
  require Logger

  alias WandererApp.Zkb.KillsProvider
  alias WandererApp.Zkb.KillsProvider.KillsCache

  @quick_limit 1
  @expanded_limit 25

  @default_hours 1
  @default_max_concurrency 2

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
    Logger.info("[KillsPreloader] Starting two-phase preload...")

    state1 = %{state | phase: :quick_pass}
    {time_quick_ms, state2} = measure(fn -> do_quick_pass(state1) end)
    Logger.info("[KillsPreloader] Phase 1 done => calls_count=#{state2.calls_count}, elapsed=#{time_quick_ms}ms")

    state3 = %{state2 | phase: :expanded_pass}
    {time_expanded_ms, final_state} = measure(fn -> do_expanded_pass(state3) end)
    Logger.info("[KillsPreloader] Phase 2 done => calls_count=#{final_state.calls_count}, elapsed=#{time_expanded_ms}ms")

    {:noreply, %{final_state | phase: :idle}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_quick_pass(state) do
    case WandererApp.Api.Map.available() do
      {:ok, maps} ->
        all_systems = gather_visible_systems(maps)

        all_systems
        |> Task.async_stream(
          fn {map_id, system_id} -> fetch_quick_kills_for_system(map_id, system_id, state) end,
          max_concurrency: state.max_concurrency,
          timeout: :timer.minutes(2)
        )
        |> Enum.reduce(state, fn
          {:ok, {:ok, updated_state}}, acc ->
            merge_calls_count(acc, updated_state)

          {:ok, {:error, reason, updated_state}}, acc ->
            Logger.warning("[KillsPreloader] Quick fetch task failed => #{inspect(reason)}")
            merge_calls_count(acc, updated_state)

          {:error, reason}, acc ->
            Logger.error("[KillsPreloader] Quick fetch task crashed => #{inspect(reason)}")
            acc
        end)

      {:error, reason} ->
        Logger.error("[KillsPreloader] Could not load maps => #{inspect(reason)}")
        state
    end
  end

  defp fetch_quick_kills_for_system(map_id, system_id, state) do
    Logger.debug("[KillsPreloader] Quick fetch => system=#{system_id}")

    case KillsProvider.Fetcher.fetch_kills_for_system_up_to_age_and_limit(
           system_id,
           @default_hours,  # 1 hour
           @quick_limit,    # 1 kill
           state
         ) do
      {:ok, kills, updated_state} ->
        broadcast_system_kills(map_id, system_id, kills, :quick)
        {:ok, updated_state}

      {:error, reason, updated_state} ->
        Logger.warning("[KillsPreloader] Quick fetch failed => system=#{system_id}, reason=#{inspect(reason)}")
        {:error, reason, updated_state}
    end
  end

  defp do_expanded_pass(state) do
    case WandererApp.Api.Map.available() do
      {:ok, maps} ->
        all_systems = gather_visible_systems(maps)

        all_systems
        |> Task.async_stream(
          fn {map_id, system_id} -> fetch_expanded_kills_for_system(map_id, system_id, state) end,
          max_concurrency: state.max_concurrency,
          timeout: :timer.minutes(5)
        )
        |> Enum.reduce(state, fn
          {:ok, {:ok, updated_state}}, acc ->
            merge_calls_count(acc, updated_state)

          {:ok, {:error, reason, updated_state}}, acc ->
            Logger.error("[KillsPreloader] Expanded fetch task failed => #{inspect(reason)}")
            merge_calls_count(acc, updated_state)

          {:error, reason}, acc ->
            Logger.error("[KillsPreloader] Expanded fetch task crashed => #{inspect(reason)}")
            acc
        end)

      {:error, reason} ->
        Logger.error("[KillsPreloader] Could not load maps => #{inspect(reason)}")
        state
    end
  end

  defp fetch_expanded_kills_for_system(map_id, system_id, state) do
    Logger.debug("[KillsPreloader] Expanded fetch => system=#{system_id} (1-hour pass)")

    # Notice we pass force: true => ignoring the "recently fetched" window
    case KillsProvider.Fetcher.fetch_kills_for_system_up_to_age_and_limit(
           system_id,
           1,               # first try 1 hour
           @expanded_limit, # up to 25 kills
           state,
           force: true
         ) do
      {:ok, kills_1h, updated_state} ->
        if length(kills_1h) < @expanded_limit do
          needed = @expanded_limit - length(kills_1h)
          Logger.debug("[KillsPreloader] Found only #{length(kills_1h)} kills in 1h; expanding to 24h for #{needed} more...")

          case KillsProvider.Fetcher.fetch_kills_for_system_up_to_age_and_limit(
                 system_id,
                 24,
                 needed,
                 updated_state,
                 force: true
               ) do
            {:ok, _kills_24h, updated_state2} ->
              final_kills = KillsCache.fetch_cached_kills(system_id) |> Enum.take(@expanded_limit)
              broadcast_system_kills(map_id, system_id, final_kills, :expanded)
              {:ok, updated_state2}

            {:error, reason2, updated_state2} ->
              Logger.warning("[KillsPreloader] 24h fetch failed => #{inspect(reason2)}")
              {:error, reason2, updated_state2}
          end
        else
          broadcast_system_kills(map_id, system_id, kills_1h, :expanded)
          {:ok, updated_state}
        end

      {:error, reason, updated_state} ->
        Logger.warning("[KillsPreloader] Expanded fetch (1-hour) failed => #{inspect(reason)}")
        {:error, reason, updated_state}
    end
  end

  defp gather_visible_systems(maps) do
    maps
    |> Enum.flat_map(fn map ->
      case WandererApp.MapSystemRepo.get_visible_by_map(map.id) do
        {:ok, systems} ->
          Enum.map(systems, fn sys -> {map.id, sys.solar_system_id} end)

        {:error, reason} ->
          Logger.warning("[KillsPreloader] get_visible_by_map failed => map=#{map.id}, reason=#{inspect(reason)}")
          []
      end
    end)
  end

  defp broadcast_system_kills(map_id, system_id, kills, phase_type) do
    Phoenix.PubSub.broadcast!(
      WandererApp.PubSub,
      map_id,
      %{
        event: :detailed_kills_updated,
        payload: %{system_id => kills},
        fetch_type: phase_type
      }
    )
  end

  defp merge_calls_count(%{calls_count: c1} = st1, %{calls_count: c2} = _st2),
    do: %{st1 | calls_count: c1 + c2}

  defp measure(fun) when is_function(fun, 0) do
    start = System.monotonic_time()
    new_state = fun.()
    fin = System.monotonic_time()
    ms = System.convert_time_unit(fin - start, :native, :millisecond)
    {ms, new_state}
  end
end
