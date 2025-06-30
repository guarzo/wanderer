defmodule WandererApp.Character.EventBroadcaster do
  @moduledoc """
  Handles broadcasting of character-related events to the external events system.

  This module is responsible for generating and broadcasting the new character events:
  - character_location_changed
  - character_online_status_changed
  - character_ship_changed
  - character_ready_status_changed
  """

  require Logger

  alias WandererApp.ExternalEvents

  @doc """
  Broadcasts a character location change event to all maps where the character is tracked.
  """
  def broadcast_location_change(character_id, previous_location, current_location) do
    case get_character_info(character_id) do
      {:ok, {character_name, active_maps}} ->
        Enum.each(active_maps, fn map_id ->
          event_payload = %{
            character_id: character_id,
            character_name: character_name,
            previous_location: format_location(previous_location),
            current_location: format_location(current_location)
          }

          ExternalEvents.broadcast(map_id, :character_location_changed, event_payload)
        end)

      _ ->
        Logger.debug("Could not broadcast location change for character #{character_id}")
    end
  end

  @doc """
  Broadcasts a character ship change event to all maps where the character is tracked.
  """
  def broadcast_ship_change(character_id, previous_ship, current_ship) do
    case get_character_info(character_id) do
      {:ok, {character_name, active_maps}} ->
        Enum.each(active_maps, fn map_id ->
          event_payload = %{
            character_id: character_id,
            character_name: character_name,
            previous_ship: format_ship(previous_ship),
            current_ship: format_ship(current_ship)
          }

          ExternalEvents.broadcast(map_id, :character_ship_changed, event_payload)
        end)

      _ ->
        Logger.debug("Could not broadcast ship change for character #{character_id}")
    end
  end

  @doc """
  Broadcasts a character online status change event to all maps where the character is tracked.
  """
  def broadcast_online_status_change(character_id, previous_online, current_online) do
    case get_character_info(character_id) do
      {:ok, {character_name, active_maps}} ->
        Enum.each(active_maps, fn map_id ->
          event_payload = %{
            character_id: character_id,
            character_name: character_name,
            previous_online: previous_online,
            current_online: current_online
          }

          ExternalEvents.broadcast(map_id, :character_online_status_changed, event_payload)
        end)

      _ ->
        Logger.debug("Could not broadcast online status change for character #{character_id}")
    end
  end

  @doc """
  Broadcasts a character ready status change event.
  This is called from map user settings when ready status changes.
  """
  def broadcast_ready_status_change(
        map_id,
        character_id,
        character_name,
        ready,
        changed_by_user_id
      ) do
    event_payload = %{
      character_id: character_id,
      character_name: character_name,
      ready: ready,
      changed_by_user_id: changed_by_user_id
    }

    ExternalEvents.broadcast(map_id, :character_ready_status_changed, event_payload)
  end

  # Private functions

  defp get_character_info(character_id) do
    with {:ok, character} <- WandererApp.Character.get_character(character_id),
         {:ok, state} <- WandererApp.Character.get_character_state(character_id) do
      {:ok, {character.name, state.active_maps}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp format_location(%{
         solar_system_id: solar_system_id,
         station_id: station_id,
         structure_id: structure_id
       }) do
    %{
      solar_system_id: solar_system_id,
      solar_system_name: get_system_name(solar_system_id),
      station_id: station_id,
      station_name: get_station_name(station_id),
      structure_id: structure_id,
      structure_name: get_structure_name(structure_id)
    }
  end

  defp format_location(_), do: nil

  defp format_ship(%{
         ship: ship_type_id,
         ship_name: ship_name,
         ship_item_id: ship_item_id
       }) do
    %{
      ship: get_ship_type_name(ship_type_id),
      ship_type_id: ship_type_id,
      ship_name: ship_name,
      ship_item_id: ship_item_id
    }
  end

  defp format_ship(%{
         ship_type_id: ship_type_id,
         ship_name: ship_name
       }) do
    %{
      ship: get_ship_type_name(ship_type_id),
      ship_type_id: ship_type_id,
      ship_name: ship_name,
      ship_item_id: nil
    }
  end

  defp format_ship(_), do: nil

  defp get_system_name(nil), do: nil

  defp get_system_name(solar_system_id) do
    case WandererApp.CachedInfo.get_system_static_info(solar_system_id) do
      {:ok, info} -> info["name"]
      _ -> "Unknown System"
    end
  end

  defp get_station_name(nil), do: nil

  defp get_station_name(_station_id) do
    # Station info is not cached in current implementation
    nil
  end

  defp get_structure_name(nil), do: nil

  defp get_structure_name(_structure_id) do
    # Structure names require an authenticated ESI call, so we'll skip for now
    nil
  end

  defp get_ship_type_name(nil), do: nil

  defp get_ship_type_name(_ship_type_id) do
    # Ship type info is not cached in current implementation
    "Unknown Ship"
  end
end
