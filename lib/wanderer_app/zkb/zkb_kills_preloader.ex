defmodule WandererApp.Zkb.KillsPreloader do
  @moduledoc """
  On startup, kicks off two passes (quick and expanded) to preload kills data.

  There is also a `run_preload_now/0` function for manual triggering of the same logic.
  """

  use GenServer
  require Logger

  alias WandererApp.Zkb.KillsProvider.Fetcher
  alias WandererApp.Zkb.KillsProvider.KillsCache

  @type system_id :: integer()
  @type hours :: non_neg_integer()
  @type state :: %{
    systems: [system_id()],
    hours: hours(),
    interval: non_neg_integer(),
    timer: reference() | nil,
    last_active_maps: %{optional(system_id()) => [system_id()]}
  }

  # ----------------
  # Configuration
  # ----------------

  @passes %{
    quick: %{limit: 5, hours: 1},
    expanded: %{limit: 100, hours: 24}
  }

  # How many minutes back we look for "last active" maps
  @last_active_cutoff 30

  # Default concurrency if not provided
  @default_max_concurrency 2

  # Client API

  @doc """
  Starts the GenServer with optional opts (like `max_concurrency`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Public helper to explicitly request a fresh preload pass (both quick & expanded).
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc """
  Public helper to explicitly request a fresh preload pass (both quick & expanded).
  """
  def run_preload_now() do
    send(__MODULE__, :start_preload)
  end

  @impl true
  def init(opts) do
    state = %{
      phase: :idle,
      calls_count: 0,
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      last_active_maps: %{}
    }

    # Kick off the preload passes once at startup
    send(self(), :start_preload)
    {:ok, state}
  end

  @impl true
  def handle_info(:start_preload, state) do
    # Gather last-active maps (or fallback).
    cutoff_time =
      DateTime.utc_now()
      |> DateTime.add(-@last_active_cutoff, :minute)

    last_active_maps_result = WandererApp.Api.MapState.get_last_active(cutoff_time)

    case resolve_last_active_maps(last_active_maps_result) do
      {:ok, last_active_maps} ->
        active_maps_with_subscription = get_active_maps_with_subscription(last_active_maps)

        # Gather systems from those maps
        system_tuples = gather_visible_systems(active_maps_with_subscription)
        unique_systems = Enum.uniq(system_tuples)

        Logger.debug(fn -> "
        [KillsPreloader] Found #{length(unique_systems)} unique systems \
        across #{length(last_active_maps)} map(s)
        " end)

        # Run both passes in sequence
        {time_quick_ms, state_after_quick} =
          measure_execution_time(fn ->
            handle_pass(state, :quick)
          end)

        Logger.info(
          "[KillsPreloader] Phase 1 (quick) done => calls_count=#{state_after_quick.calls_count}, elapsed=#{time_quick_ms}ms"
        )

        {time_expanded_ms, final_state} =
          measure_execution_time(fn ->
            handle_pass(state, :expanded)
          end)

        Logger.info(
          "[KillsPreloader] Phase 2 (expanded) done => calls_count=#{final_state.calls_count}, elapsed=#{time_expanded_ms}ms"
        )

        # Reset phase to :idle
        {:noreply, %{final_state | phase: :idle}}

      {:error, reason} ->
        Logger.error("[KillsPreloader] Failed to get active maps: #{inspect(reason)}")
        {:noreply, %{state | phase: :idle}}
    end
  end

  @impl true
  def handle_info(:pass, state) do
    # Get the pass configuration
    pass_config = @passes[state.pass_type]
    since_hours = pass_config[:since_hours]
    limit = pass_config[:limit]

    Logger.info("[KillsPreloader] Starting pass type=#{state.pass_type}, since_hours=#{since_hours}, limit=#{limit}")

    # Get last active maps and filter for active subscriptions
    case resolve_last_active_maps() do
      {:ok, last_active_maps} ->
        Logger.info("[KillsPreloader] Found #{length(last_active_maps)} last active maps")

        # Filter maps with active subscriptions
        active_maps = get_active_maps_with_subscription(last_active_maps)
        Logger.info("[KillsPreloader] Found #{length(active_maps)} maps with active subscriptions")

        # Gather visible systems from all active maps
        systems = gather_visible_systems(active_maps)
        Logger.info("[KillsPreloader] Found #{length(systems)} visible systems to process")

        # Process systems in parallel with rate limiting
        tasks =
          systems
          |> Enum.map(fn system_id ->
            Task.async(fn ->
              Logger.info("[KillsPreloader] Fetching kills for system=#{system_id}, since_hours=#{since_hours}, limit=#{limit}")
              result = Fetcher.fetch_kills_for_system(system_id, since_hours, state, limit: limit)
              Logger.info("[KillsPreloader] Result for system=#{system_id}: #{inspect(result)}")
              result
            end)
          end)

        # Wait for all tasks to complete
        results = Task.await_many(tasks, 30_000)
        Logger.info("[KillsPreloader] Completed processing #{length(results)} systems")

        # Update state with new calls count
        new_state = %{state | calls_count: state.calls_count + length(systems)}

        # Schedule next pass
        schedule_next_pass(new_state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[KillsPreloader] Failed to get active maps: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Resolves the last active maps from the state.
  Returns {:ok, maps} or {:error, reason}.
  """
  def resolve_last_active_maps(result \\ nil) do
    case result do
      nil ->
        case WandererApp.Maps.get_last_active_maps() do
          {:ok, maps} when is_list(maps) and length(maps) > 0 ->
            Logger.info("[KillsPreloader] Successfully resolved #{length(maps)} last active maps")
            {:ok, maps}

          {:ok, []} ->
            Logger.warning("[KillsPreloader] No last active maps found")
            {:error, :no_active_maps}

          {:error, reason} ->
            Logger.error("[KillsPreloader] Failed to resolve last active maps: #{inspect(reason)}")
            {:error, reason}
        end

      {:ok, maps} when is_list(maps) ->
        Logger.info("[KillsPreloader] Using provided maps: #{length(maps)} maps")
        {:ok, maps}

      {:error, reason} ->
        Logger.error("[KillsPreloader] Error in provided maps: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets active maps that have an active subscription.
  """
  def get_active_maps_with_subscription(maps) do
    maps
    |> Enum.filter(fn map ->
      {:ok, is_subscription_active} = map.id |> WandererApp.Map.is_subscription_active?()
      is_subscription_active
    end)
  end

  @doc """
  Gathers all visible systems from the given maps.
  """
  def gather_visible_systems(maps) do
    maps
    |> Enum.flat_map(fn map_record ->
      the_map_id = Map.get(map_record, :map_id) || Map.get(map_record, :id)

      case WandererApp.MapSystemRepo.get_visible_by_map(the_map_id) do
        {:ok, systems} ->
          Enum.map(systems, fn sys -> {the_map_id, sys.solar_system_id} end)

        {:error, reason} ->
          Logger.warning(
            "[KillsPreloader] get_visible_by_map failed => map_id=#{inspect(the_map_id)}, reason=#{inspect(reason)}"
          )

          []
      end
    end)
  end

  defp handle_pass(state, pass_type) do
    # Get the pass configuration
    pass_config = Map.get(@passes, pass_type)
    since_hours = pass_config.hours
    limit = pass_config.limit

    Logger.info("[KillsPreloader] Starting #{pass_type} pass with config: hours=#{since_hours}, limit=#{limit}")

    # Get systems from last active maps
    cutoff_time = DateTime.utc_now() |> DateTime.add(-@last_active_cutoff, :minute)
    last_active_maps_result = WandererApp.Api.MapState.get_last_active(cutoff_time)

    case resolve_last_active_maps(last_active_maps_result) do
      {:ok, last_active_maps} ->
        active_maps_with_subscription = get_active_maps_with_subscription(last_active_maps)
        system_tuples = gather_visible_systems(active_maps_with_subscription)
        system_ids = Enum.map(system_tuples, &elem(&1, 1)) |> Enum.uniq()

        Logger.info("[KillsPreloader] Starting #{pass_type} pass => #{length(system_ids)} systems: #{inspect(system_ids)}")

        # Process systems in parallel with rate limiting
        results =
          system_ids
          |> Enum.map(fn system_id ->
            Task.async(fn ->
              {system_id, fetch_kills_for_system(system_id, since_hours, state, limit: limit)}
            end)
          end)
          |> Enum.map(&Task.await(&1, 30_000))

        # Process results
        total_kills = Enum.reduce(results, 0, fn {system_id, result}, acc ->
          case result do
            {:ok, kills, _state} when is_list(kills) ->
              if Enum.empty?(kills) do
                Logger.info("[KillsPreloader] No kills found for system=#{system_id}")
                acc
              else
                Logger.info("[KillsPreloader] Fetched #{length(kills)} kills for system=#{system_id}")
                acc + length(kills)
              end

            {:error, reason, _state} ->
              Logger.warning("[KillsPreloader] Failed to fetch kills for system=#{system_id}: #{inspect(reason)}")
              acc
          end
        end)

        Logger.info("[KillsPreloader] #{pass_type} pass complete => total_kills=#{total_kills}, systems_processed=#{length(system_ids)}")

        # Update state with new calls count
        %{state | calls_count: state.calls_count + length(system_ids)}

      {:error, reason} ->
        Logger.error("[KillsPreloader] Failed to get active maps for #{pass_type} pass: #{inspect(reason)}")
        state
    end
  end

  defp fetch_kills_for_system(system_id, since_hours, state, limit: _limit) do
    force = since_hours == 24
    Logger.info("[KillsPreloader] Fetching kills for system=#{system_id}, since_hours=#{since_hours}, force=#{force}")

    case Fetcher.fetch_kills_for_system(system_id, since_hours, state, force: force) do
      {:ok, kills, new_state} when is_list(kills) ->
        Logger.info("[KillsPreloader] Successfully fetched #{length(kills)} kills for system=#{system_id}")
        {:ok, kills, new_state}

      {:error, reason, new_state} ->
        Logger.warning("[KillsPreloader] Error fetching kills for system=#{system_id}: #{inspect(reason)}")
        {:error, reason, new_state}
    end
  end

  defp measure_execution_time(fun) when is_function(fun, 0) do
    start = System.monotonic_time()
    result = fun.()
    finish = System.monotonic_time()
    ms = System.convert_time_unit(finish - start, :native, :millisecond)
    {ms, result}
  end

  defp schedule_next_pass(state) do
    # Schedule next pass based on pass type
    interval = case state.pass_type do
      :quick -> 5 * 60 * 1000  # 5 minutes
      :expanded -> 30 * 60 * 1000  # 30 minutes
      _ -> 5 * 60 * 1000  # default to 5 minutes
    end

    Process.send_after(self(), :pass, interval)
  end
end
