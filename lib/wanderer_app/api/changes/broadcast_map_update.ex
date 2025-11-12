defmodule WandererApp.Api.Changes.BroadcastMapUpdate do
  @moduledoc """
  Ash change that broadcasts PubSub events after map resource updates.

  This enables real-time updates for the V1 JSON:API endpoints by triggering
  the same PubSub broadcasts that the Map.Server.Impl uses.

  ## Usage

  In an Ash resource action:

      update :update do
        accept [:status, :tag]
        change {BroadcastMapUpdate, event: :update_system}
      end

  ## Options

  - `:event` - The event type to broadcast (e.g., :update_system, :delete_system, :add_system)

  ## Broadcast Format

  Uses the same format as WandererApp.Map.Server.Impl.broadcast!/3:
  - Topic: map_id
  - Message: %{event: event, payload: record}
  """

  use Ash.Resource.Change

  require Logger

  alias WandererApp.Map.Server.Impl

  @impl true
  def change(changeset, opts, _context) do
    # Store the event type in changeset metadata
    event = Keyword.fetch!(opts, :event)

    changeset
    |> Ash.Changeset.after_action(fn changeset_for_action, result ->
      # Determine the actual event based on changes
      actual_event = determine_event(changeset_for_action, result, event)
      broadcast_update(result, actual_event)
      {:ok, result}
    end)
  end

  # For systems: detect when visible is set to false (removal) vs other updates
  defp determine_event(changeset, %{__struct__: WandererApp.Api.MapSystem} = _result, :update_system) do
    case Ash.Changeset.get_attribute(changeset, :visible) do
      false -> :systems_removed
      _ -> :update_system
    end
  end

  # For all other cases, use the provided event
  defp determine_event(_changeset, _result, event), do: event

  defp broadcast_update(%{__struct__: WandererApp.Api.MapSystem, visible: false} = record, :systems_removed) do
    # When removing a system, broadcast just the solar_system_id in an array (matches existing format)
    case Map.get(record, :map_id) do
      nil ->
        Logger.error(
          "[BroadcastMapUpdate] Cannot broadcast systems_removed - missing map_id"
        )

        :ok

      map_id ->
        Logger.debug(
          "[BroadcastMapUpdate] Broadcasting systems_removed for system #{record.solar_system_id} on map #{map_id}"
        )

        # Match existing broadcast format: array of solar_system_ids
        Impl.broadcast!(map_id, :systems_removed, [record.solar_system_id])
    end
  end

  defp broadcast_update(record, event) do
    # Get map_id from the record
    case Map.get(record, :map_id) do
      nil ->
        Logger.error(
          "[BroadcastMapUpdate] Cannot broadcast #{event} - missing map_id in record: #{inspect(record.__struct__)}"
        )

        :ok

      map_id ->
        Logger.debug(
          "[BroadcastMapUpdate] Broadcasting #{event} for #{inspect(record.__struct__)} on map #{map_id}"
        )

        # Use the same broadcast mechanism as the Map.Server.Impl
        Impl.broadcast!(map_id, event, record)
    end
  end
end
