defmodule WandererApp.ExternalEvents.Discord.WorkerSupervisor do
  @moduledoc """
  Starts one delivery worker per Discord webhook on demand, addressed through a
  Registry keyed by webhook id.

  Per webhook, not per map: Discord's rate limits are per webhook, and a failure
  must be attributable to the destination that caused it. Sharing a worker
  between a map's system and character channels would let a 429 on one stall the
  other, and a 404 on one disable both.

  Workers are transient: they own an in-memory queue, shut down when idle, and
  are not restarted with their queue intact. Losing a queued notification on
  crash is acceptable; duplicating a delivered one is not.
  """

  use Supervisor

  require Logger

  alias WandererApp.ExternalEvents.Discord.Worker

  @registry WandererApp.ExternalEvents.Discord.Registry
  @dyn_sup WandererApp.ExternalEvents.Discord.DynamicSupervisor
  # Bounded so a worker wedged on a slow DB call cannot block the destroy that
  # is stopping it. The exit is caught either way; the worker is brought down.
  @stop_timeout_ms 5_000

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {Task.Supervisor, name: WandererApp.ExternalEvents.Discord.TaskSupervisor},
      {DynamicSupervisor, name: @dyn_sup, strategy: :one_for_one}
    ]

    # :rest_for_one, not :one_for_one — workers register in the Registry, so a
    # Registry crash would leave them running but unreachable, and the next
    # deliver/2 would start a *second* worker for the same webhook and
    # double-post. Restarting everything after the Registry clears those orphans.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Enqueues messages for one webhook, starting its worker if it is not running.

  Takes the webhook *id*, never the record: the worker reloads it just before
  each send so a replaced or deleted webhook is not used, and so a stale
  `consecutive_failures` snapshot cannot corrupt the counter.

  Returns `{:error, :not_running}` when the worker infrastructure is not
  started (e.g. webhooks globally disabled), mirroring `stop_worker/1`'s
  tolerance of the same condition. Callers on the dispatch path must not crash
  just because the kill-switch is off.
  """
  def deliver(_webhook_id, []), do: :ok

  def deliver(webhook_id, messages) do
    case ensure_worker(webhook_id) do
      {:ok, pid} ->
        Worker.enqueue(pid, messages)

      {:error, :not_running} ->
        # Not an error worth logging on every event: the kill-switch being off
        # is a normal configuration, not a failure.
        {:error, :not_running}

      {:error, reason} ->
        Logger.warning(
          "[Discord] could not start worker for webhook #{webhook_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Stops one webhook's delivery worker if one is running, discarding its queue.

  Called from the webhook resource's destroy, and from the parent notification's
  destroy for each of its children: without it, a removed webhook keeps
  receiving whatever was already queued. A no-op when the worker infrastructure
  is not running at all (e.g. webhooks globally disabled, or in tests that do
  not start this supervisor).
  """
  def stop_worker(webhook_id) do
    case Process.whereis(@registry) do
      nil ->
        :ok

      _ ->
        case Registry.lookup(@registry, webhook_id) do
          # The worker may have idled out or crashed between the lookup and the
          # stop; either way the post-condition (no worker running) holds.
          [{pid, _}] -> try_stop(pid)
          [] -> :ok
        end

        :ok
    end
  end

  defp try_stop(pid) do
    GenServer.stop(pid, :normal, @stop_timeout_ms)
  catch
    # Already gone, or did not terminate within the timeout — in the latter case
    # GenServer.stop/3 has already killed it. Either way there is no worker left.
    :exit, _ -> :ok
  end

  defp ensure_worker(webhook_id) do
    # Guard exactly as stop_worker/1 does: Registry.lookup on an unregistered
    # name raises ArgumentError, which would crash the dispatcher whenever
    # webhooks are globally disabled and this supervisor was never started.
    case Process.whereis(@registry) do
      nil -> {:error, :not_running}
      _ -> lookup_or_start(webhook_id)
    end
  end

  defp lookup_or_start(webhook_id) do
    case Registry.lookup(@registry, webhook_id) do
      # Registry releases a dead owner's key asynchronously, so a lookup can
      # still return a pid that has just exited (idle shutdown or stop_worker).
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: start_worker(webhook_id)

      [] ->
        start_worker(webhook_id)
    end
  end

  defp start_worker(webhook_id) do
    spec = {Worker, webhook_id: webhook_id, registry: @registry}

    case DynamicSupervisor.start_child(@dyn_sup, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def registry, do: @registry
end
