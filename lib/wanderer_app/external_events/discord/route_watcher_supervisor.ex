defmodule WandererApp.ExternalEvents.Discord.RouteWatcherSupervisor do
  @moduledoc """
  Starts one `Discord.RouteWatcher` per map on demand, addressed through the
  Registry `RouteWatcher` owns (`RouteWatcher.registry/0`).

  Unlike `Discord.WorkerSupervisor` (whose moduledoc this otherwise mirrors),
  this supervisor does NOT declare the Registry as its own child: that
  Registry is started unconditionally in `application.ex`'s `core_children`
  (alongside `:discord_route_alert_cache`) so `RouteWatcher`'s own tests can
  start a bare watcher without this supervisor at all — declaring it again
  here would collide with that already-running process. Consequently the
  liveness guard below keys off the `DynamicSupervisor` this module DOES own,
  not the Registry, which is always up independently of whether this
  supervisor is started.

  Only started when webhooks are globally enabled (`application.ex`), so
  `notify/1` and `stop_watcher/1` guard `Process.whereis/1` exactly as
  `WorkerSupervisor` does — a no-op when this tree is not running, never a
  crash, so callers on the dispatch and resource-destroy paths do not need to
  know whether the feature is enabled.
  """

  use Supervisor

  alias WandererApp.ExternalEvents.Discord.RouteWatcher

  @dyn_sup WandererApp.ExternalEvents.Discord.RouteWatcherDynamicSupervisor
  # Same cache RouteWatcher.persist/1 and rehydrate/1 read and write
  # (route_watcher.ex:41). Named directly rather than through an accessor
  # because RouteWatcher does not expose one — application.ex names this same
  # atom directly too when declaring the Cachex worker.
  @cache :discord_route_alert_cache
  @stop_timeout_ms 5_000

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: @dyn_sup, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Starts the map's watcher if needed, then forwards the notify."
  @spec notify(binary()) :: :ok
  def notify(map_id) do
    # Both the dyn sup (owned here) and the Registry (owned by RouteWatcher,
    # started unconditionally elsewhere — see the moduledoc) must be checked:
    # Registry.lookup/2 raises ArgumentError on an unregistered name, and the
    # two processes' lifecycles are independent, so either one being absent
    # must degrade to a no-op rather than a crash.
    if running?() do
      with {:ok, _pid} <- ensure_watcher(map_id) do
        RouteWatcher.notify(map_id)
      end
    end

    :ok
  end

  @doc """
  Stops the map's watcher if one is running, and evicts its cached
  route_state/config_version so a subsequent watcher for the same map starts
  fresh at `:unknown` instead of rehydrating stale state (the TTL-less
  `:discord_route_alert_cache` otherwise outlives the process indefinitely).
  """
  @spec stop_watcher(binary()) :: :ok
  def stop_watcher(map_id) do
    if running?() do
      case Registry.lookup(RouteWatcher.registry(), map_id) do
        [{pid, _}] -> try_stop(pid)
        [] -> :ok
      end
    end

    evict_cache(map_id)
    :ok
  end

  defp running?, do: Process.whereis(@dyn_sup) && Process.whereis(RouteWatcher.registry())

  defp try_stop(pid) do
    GenServer.stop(pid, :normal, @stop_timeout_ms)
  catch
    :exit, _ -> :ok
  end

  # Defensive the same way RouteWatcher.persist/1 and rehydrate/1 are: the
  # cache is not started in every test context, and a missing cache must not
  # turn a stop into a crash.
  defp evict_cache(map_id) do
    Cachex.del(@cache, map_id)
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_watcher(map_id) do
    case Registry.lookup(RouteWatcher.registry(), map_id) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: start_watcher(map_id)

      [] ->
        start_watcher(map_id)
    end
  end

  defp start_watcher(map_id) do
    spec = {RouteWatcher, map_id: map_id}

    case DynamicSupervisor.start_child(@dyn_sup, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end
end
