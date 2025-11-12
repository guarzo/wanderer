defmodule WandererApp.Api.Changes.BroadcastSignatureUpdate do
  @moduledoc """
  Ash change that broadcasts PubSub events after signature updates.

  Signatures require loading the related system to get map_id and solar_system_id
  for the broadcast, since they don't have a direct map_id field.

  ## Usage

  In an Ash resource action:

      update :update do
        accept [:type, :group]
        change BroadcastSignatureUpdate
      end

  ## Broadcast Format

  Signatures broadcast :signatures_updated with the solar_system_id as payload:
  - Topic: map_id (from related system)
  - Message: %{event: :signatures_updated, payload: solar_system_id}
  """

  use Ash.Resource.Change

  require Logger

  alias WandererApp.Map.Server.Impl

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.after_action(fn _changeset, result ->
      broadcast_signature_update(result)
      {:ok, result}
    end)
  end

  defp broadcast_signature_update(signature) do
    # Load the related system to get map_id and solar_system_id
    case Ash.load(signature, :system) do
      {:ok, %{system: system}} when not is_nil(system) ->
        case {system.map_id, system.solar_system_id} do
          {nil, _} ->
            Logger.error(
              "[BroadcastSignatureUpdate] Cannot broadcast - missing map_id in system #{system.id}"
            )

            :ok

          {_, nil} ->
            Logger.error(
              "[BroadcastSignatureUpdate] Cannot broadcast - missing solar_system_id in system #{system.id}"
            )

            :ok

          {map_id, solar_system_id} ->
            Logger.debug(
              "[BroadcastSignatureUpdate] Broadcasting signatures_updated for system #{solar_system_id} on map #{map_id}"
            )

            # Use the same broadcast mechanism as the Map.Server.Impl
            # Signature broadcasts use the solar_system_id as the payload
            Impl.broadcast!(map_id, :signatures_updated, solar_system_id)
        end

      {:ok, %{system: nil}} ->
        Logger.error(
          "[BroadcastSignatureUpdate] Cannot broadcast - system not loaded for signature #{signature.id}"
        )

        :ok

      {:error, error} ->
        Logger.error(
          "[BroadcastSignatureUpdate] Failed to load system for signature #{signature.id}: #{inspect(error)}"
        )

        :ok
    end
  end
end
