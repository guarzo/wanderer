defmodule WandererAppWeb.MapStructuresEventHandler do
  use WandererAppWeb, :live_component
  use Phoenix.Component
  require Logger

  alias WandererAppWeb.MapEventHandler
  alias WandererApp.Api.MapSystemStructures

  # ----------------------------------------------------------------------------
  # PUBLIC: Event Handler
  # ----------------------------------------------------------------------------

  def handle_server_event(%{event: :structures_updated, payload: solar_system_id}, socket) do
    socket
    |> MapEventHandler.push_map_event("structures_updated", solar_system_id)
  end

  def handle_ui_event(
        "update_structures",
        %{
          # The front-end is sending system_id= EVE ID (like "31001394"),
          # plus arrays "added" / "updated" / "removed"
          "system_id" => solar_system_id,
          "added" => added_structures,
          "updated" => updated_structures,
          "removed" => removed_structures
        },
        %{
          assigns: %{
            map_id: map_id,
            user_characters: user_characters,
            user_permissions: %{update_system: true}
          }
        } = socket
      ) do
    with {:ok, system} <- get_map_system(map_id, solar_system_id),
         :ok <- ensure_user_has_tracked_character(user_characters) do
      Logger.info(fn ->
        "[handle_ui_event:update_structures] loaded map_system =>\n" <>
          inspect(system, pretty: true)
      end)

      do_update_structures(system, added_structures, updated_structures, removed_structures, user_characters)
      broadcast_structures_updated(system, map_id)

      {:reply, %{structures: get_system_structures(system.id)}, socket}
    else
      :no_tracked_character ->
        {:reply,
         %{structures: []},
         put_flash(socket, :error, "You must have at least one tracked character to work with structures.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_ui_event("get_structures", %{"system_id" => solar_system_id}, %{assigns: %{map_id: map_id}} = socket) do
    case WandererApp.Api.MapSystem.read_by_map_and_solar_system(%{
           map_id: map_id,
           solar_system_id: String.to_integer(solar_system_id)
         }) do
      {:ok, system} ->
        {:reply, %{structures: get_system_structures(system.id)}, socket}

      _ ->
        {:reply, %{structures: []}, socket}
    end
  end

  def handle_ui_event("get_corporation_names", %{"search" => search}, %{assigns: %{current_user: current_user}} = socket) do
    case current_user.characters do
      [first_char | _] ->
        results =
          case WandererApp.Character.search(first_char.id, params: [search: search, categories: "corporation"]) do
            {:ok, matches} -> matches
            _ -> []
          end

        {:reply, %{results: results}, socket}

      _ ->
        {:reply, %{results: []}, socket}
    end
  end

  def handle_ui_event("get_corporation_ticker", %{"corp_id" => corp_id}, socket) do
    case WandererApp.Esi.get_corporation_info(corp_id) do
      {:ok, %{"ticker" => ticker}} ->
        {:reply, %{ticker: ticker}, socket}

      _ ->
        {:reply, %{ticker: nil}, socket}
    end
  end

  # ----------------------------------------------------------------------------
  # PRIVATE Helpers
  # ----------------------------------------------------------------------------

  # This loads a MapSystem row by map_id + solar_system_id (the EVE ID).
  defp get_map_system(map_id, solar_system_id) do
    case WandererApp.Api.MapSystem.read_by_map_and_solar_system(%{
           map_id: map_id,
           solar_system_id: String.to_integer(solar_system_id)
         }) do
      {:ok, system} -> {:ok, system}
      _ -> :error
    end
  end

  defp ensure_user_has_tracked_character(user_characters) do
    if Enum.empty?(user_characters) or is_nil(List.first(user_characters)) do
      :no_tracked_character
    else
      :ok
    end
  end

  # do_update_structures: We parse "added"/"updated"/"removed" arrays
  # and pass them to Ash via create!/update!/destroy!.
  defp do_update_structures(system, added_structures, updated_structures, removed_structures, user_characters) do
    first_char_eve_id = List.first(user_characters)

    added_structs =
      parse_structures(added_structures, first_char_eve_id, system)
      |> Enum.map(&Map.delete(&1, :id))

    updated_structs = parse_structures(updated_structures, first_char_eve_id, system)
    removed_structs = parse_structures(removed_structures, first_char_eve_id, system)

    remove_structures(system.id, Enum.map(removed_structs, & &1.id))
    update_structures(system.id, updated_structs, Enum.map(updated_structs, & &1.id))
    add_structures(added_structs)
  end

  defp remove_structures(system_id, removed_ids) do
    MapSystemStructures.by_system_id!(system_id)
    |> Enum.filter(fn s -> s.id in removed_ids end)
    |> Enum.each(&Ash.destroy!/1)
  end

  defp update_structures(system_id, updated_structs, updated_ids) do
    MapSystemStructures.by_system_id!(system_id)
    |> Enum.filter(fn s -> s.id in updated_ids end)
    |> Enum.each(fn existing ->
      updated_data = Enum.find(updated_structs, fn u -> u.id == existing.id end)

      Logger.info(fn ->
        "[handle_ui_event:update_structures] about to update =>\n" <> inspect(updated_data, pretty: true)
      end)

      if updated_data do
        # Remove :id so Ash doesn't treat it as the PK param
        updated_data = Map.delete(updated_data, :id)

        new_record =
          existing
          |> MapSystemStructures.update(updated_data)

        Logger.info(fn ->
          "[handle_ui_event:update_structures] updated record =>\n" <>
            inspect(new_record, pretty: true)
        end)
      end
    end)
  end

  defp add_structures(added_structs) do
    Enum.each(added_structs, fn struct_map ->
      Logger.info(fn ->
        "[handle_ui_event:add_structures] Creating structure =>\n" <>
          inspect(struct_map, pretty: true)
      end)

      # If the resource is correct, all required fields are present, it should succeed
      MapSystemStructures.create!(struct_map)
    end)
  end

  defp broadcast_structures_updated(system, map_id) do
    # We broadcast system.solar_system_id for the front-end
    Phoenix.PubSub.broadcast!(
      WandererApp.PubSub,
      map_id,
      %{event: :structures_updated, payload: system.solar_system_id}
    )
  end

  # Returns the data as a list of maps for the UI
  def get_system_structures(system_id) do
    results =
      MapSystemStructures.by_system_id!(system_id)
      |> Enum.map(fn record ->
        record
        |> Map.take([
          :id,
          :system_id,
          :solar_system_id,
          :solar_system_name,
          :type_id,
          :character_eve_id,
          :name,
          :notes,
          :owner,
          :owner_ticker,
          :owner_id,
          :status,
          :end_time,
          :inserted_at,
          :updated_at,
          :type
        ])
        |> Map.update!(:inserted_at, &Calendar.strftime(&1, "%Y/%m/%d %H:%M:%S"))
        |> Map.update!(:updated_at, &Calendar.strftime(&1, "%Y/%m/%d %H:%M:%S"))
      end)

    Logger.info(fn ->
      "[get_system_structures] => returning:\n" <> inspect(results, pretty: true)
    end)

    results
  end

  # parse_structures: The front-end snippet passes e.g.:
  #  [
  #    {"id" => "some-uuid"?, "name" => "Something", "owner" => "", "notes" => "...", "typeId" => "35832"}
  #  ]
  # We convert them to the final map that Ash expects.
  defp parse_structures(list_of_maps, character_eve_id, system) do
    Logger.info(fn ->
      "parse_structures sees =>\n" <> inspect(list_of_maps, pretty: true)
    end)

    Logger.info(fn ->
      "map_system =>\n" <> inspect(system, pretty: true)
    end)

    Enum.map(list_of_maps, fn item ->
      %{
        # If an existing item, we keep the "id" so Ash knows which record to update
        id: Map.get(item, "id"),

        # The parent's PK (UUID)
        system_id: system.id,

        # The EVE ID for the system
        solar_system_id: system.solar_system_id,
        # The EVE name
        solar_system_name: system.name,

        # A required field
        type_id: Map.get(item, "typeId") || "???",

        # Another required field
        character_eve_id: character_eve_id,

        # Optional fields
        name: Map.get(item, "name"),
        notes: Map.get(item, "notes"),
        type: Map.get(item, "type"),
        owner: Map.get(item, "owner"),
        owner_ticker: Map.get(item, "ownerTicker"),
        owner_id: Map.get(item, "ownerId"),
        status: Map.get(item, "status"),

        # If there's a possible "endTime"
        end_time: parse_end_time(Map.get(item, "endTime"))
      }
    end)
  end

  defp parse_end_time(nil), do: nil

  defp parse_end_time(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, reason} ->
        Logger.error("Error parsing ISO-8601 string: #{str}, reason: #{inspect(reason)}")
        nil
    end
  end

  defp parse_end_time(_), do: nil
end
