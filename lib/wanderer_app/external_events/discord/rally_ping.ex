defmodule WandererApp.ExternalEvents.Discord.RallyPing do
  @moduledoc """
  Formats a rally point and hands it to the destination's delivery worker.

  Lives outside `DiscordDispatcher` because that process is a singleton shared
  by every map: it may gate and hand off, and nothing else. Everything here runs
  in a task, so it may render and enqueue.

  Creation only. `:rally_point_removed` is deliberately not handled — a rally
  normally ends by the 60-minute expiry in `WandererApp.Map.MapManager`, and
  that path emits no external event at all, so a cancellation message would fire
  for manual cancels and stay silent for the common case. Its absence would then
  read as "still active", which is worse than never posting one.
  """

  require Logger

  alias WandererApp.ExternalEvents.Discord.EmbedFormatter
  alias WandererApp.ExternalEvents.Discord.WorkerSupervisor

  @doc """
  Renders `payload` and enqueues it for `webhook`. Always returns `:ok`.
  """
  @spec deliver(String.t(), struct(), map()) :: :ok
  def deliver(map_id, webhook, payload) do
    messages =
      payload
      |> Map.put(:map_id, map_id)
      |> EmbedFormatter.format_rally_ping(mention_targets: webhook.mention_targets)

    case worker_supervisor_impl().deliver(webhook.id, messages) do
      :ok ->
        emit_telemetry(map_id, :delivered)

      # "Nothing was enqueued" — the Discord supervision tree is down. Mirrors
      # RouteWatcher's handling of the same result, minus the state revert:
      # a rally ping carries no persisted state to roll back.
      {:error, :not_running} ->
        emit_telemetry(map_id, :not_running)

      {:error, reason} ->
        Logger.warning(
          "[Discord.RallyPing] rally ping delivery enqueue failed for map #{map_id}: #{inspect(reason)}"
        )

        emit_telemetry(map_id, :error)
    end

    :ok
  end

  defp emit_telemetry(map_id, outcome) do
    :telemetry.execute(
      [:wanderer_app, :discord, :rally_ping],
      %{count: 1},
      %{map_id: map_id, outcome: outcome}
    )
  end

  defp worker_supervisor_impl,
    do: Application.get_env(:wanderer_app, :rally_ping_worker_supervisor, WorkerSupervisor)
end
