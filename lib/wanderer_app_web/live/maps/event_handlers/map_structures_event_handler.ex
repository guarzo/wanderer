defmodule WandererAppWeb.MapStructuresEventHandler do
  use WandererAppWeb, :live_component
  use Phoenix.Component
  require Logger

  alias WandererAppWeb.MapEventHandler
  alias WandererApp.Api.MapSystemStructures

  def handle_server_event(%{event: :structures_updated, payload: solar_system_id}, socket) do
    socket
    |> MapEventHandler.push_map_event("structures_updated", solar_system_id)
  end

  def handle_ui_event(
        "update_structures",
        %{
          # The front-end is sending "system_id"= EVE solar ID (31001394) here,
          # but we want the actual Ash resource to store "system_id"=UUID (the parent's ID).
          # We'll fix that by loading `map_system` from DB & pass that record into parse_structures
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

      # Let's log the entire map_system record so we see what fields are in it
      Logger.info(fn ->
        "[handle_ui_event] => Loaded map_system:\n" <> inspect(system, pretty: true)
      end)

      # We pass the full system to do_update_structures
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

  def handle_ui_event(
        "get_structures",
        %{"system_id" => solar_system_id},
        %{assigns: %{map_id: map_id}} = socket
      ) do
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
          case WandererApp.Character.search(
                 first_char.id,
                 params: [search: search, categories: "corporation"]
               ) do
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
  # Private Helpers
  # ----------------------------------------------------------------------------

  # We load the map system record by the real EVE solar ID the user gave
  defp get_map_system(map_id, solar_system_id) do
    case WandererApp.Api.MapSystem.read_by_map_and_solar_system(%{
           map_id: map_id,
           solar_system_id: String.to_integer(solar_system_id)
         }) do
      {:ok, system} ->
        {:ok, system}

      _ ->
        :error
    end
  end

  defp ensure_user_has_tracked_character(user_characters) do
    if Enum.empty?(user_characters) or is_nil(List.first(user_characters)) do
      :no_tracked_character
    else
      :ok
    end
  end

  defp do_update_structures(system, added_structures, updated_structures, removed_structures, user_characters) do
    first_character_eve_id = List.first(user_characters)

    added_structs =
      parse_structures(added_structures, first_character_eve_id, system)
      # We remove :id from any new item so Ash doesn't conflict
      |> Enum.map(&Map.delete(&1, :id))

    updated_structs = parse_structures(updated_structures, first_character_eve_id, system)
    updated_ids = Enum.map(updated_structs, & &1.id)

    removed_ids =
      parse_structures(removed_structures, first_character_eve_id, system)
      |> Enum.map(& &1.id)
      |> Enum.reject(&is_nil/1)

    remove_structures(system.id, removed_ids)
    update_structures(system.id, updated_structs, updated_ids)
    add_structures(added_structs)
  end

  defp remove_structures(system_id, removed_ids) do
    MapSystemStructures.by_system_id!(system_id)
    |> Enum.filter(fn s -> s.id in removed_ids end)
    |> Enum.each(&Ash.destroy!/1)
  end

  defp update_structures(system_id, updated_structs, updated_ids) do
    # "system_id" here is the map_system.id, i.e. the parent row's ID
    MapSystemStructures.by_system_id!(system_id)
    |> Enum.filter(fn s -> s.id in updated_ids end)
    |> Enum.each(fn s ->
      updated_data = Enum.find(updated_structs, fn u -> u.id == s.id end)

      Logger.info(fn ->
        "[handle_ui_event] about to update with =>\n" <> inspect(updated_data, pretty: true)
      end)

      if updated_data do
        updated_data = Map.delete(updated_data, :id)
        new_record =
          s
          |> MapSystemStructures.update(
            Map.put(updated_data, :updated, System.os_time(:second))
          )

        Logger.info(fn ->
          "[handle_ui_event] updated record =>\n" <> inspect(new_record, pretty: true)
        end)
      end
    end)
  end

  defp add_structures(added_structs) do
    # Each item in added_structs should have all required fields for Ash:
    #   * system_id (the parent map system's id, a UUID)
    #   * solar_system_id (the EVE system ID, an integer)
    #   * solar_system_name (the name from map_system.name)
    #   * etc
    Enum.each(added_structs, fn struct ->
      Logger.info(fn ->
        "[add_structures] Creating structure =>\n" <> inspect(struct, pretty: true)
      end)

      # This will fail if your resource expects any required fields not included
      MapSystemStructures.create!(struct)
    end)
  end

  defp broadcast_structures_updated(system, map_id) do
    # We'll broadcast system.solar_system_id so the front-end knows which system changed
    Phoenix.PubSub.broadcast!(WandererApp.PubSub, map_id, %{
      event: :structures_updated,
      payload: system.solar_system_id
    })
  end

  # get_system_structures/1 remains the same except we might want to include solar_system_id/name
  def get_system_structures(system_id) do
    results =
      MapSystemStructures.by_system_id!(system_id)
      |> Enum.map(fn %{inserted_at: inserted_at, updated_at: updated_at} = s ->
        s
        |> Map.take([
          :id,
          :system_id,           # This might be the parent's ID if your resource calls it `system_id`
          :solar_system_id,     # The EVE ID
          :solar_system_name,   # The EVE name
          :type_id,
          :name,
          :description,
          :kind,
          :group,
          :type,
          :custom_info,
          :owner,
          :owner_ticker,
          :owner_id,
          :status,
          :end_time
        ])
        |> Map.put(:endTime, s.end_time)
        |> Map.delete(:end_time)
        |> Map.put(:inserted_at, Calendar.strftime(inserted_at, "%Y/%m/%d %H:%M:%S"))
        |> Map.put(:updated_at, Calendar.strftime(updated_at, "%Y/%m/%d %H:%M:%S"))
      end)

    Logger.info(fn ->
      "[get_system_structures] => returning:\n" <> inspect(results, pretty: true)
    end)

    results
  end

  # We pass the entire %MapSystem{} record so we can grab system.id, system.solar_system_id, system.name
  defp parse_structures(structures, character_eve_id, system) do
    Logger.info(fn ->
      "Server parse_structures sees =>\n" <> inspect(structures, pretty: true)
    end)

    Logger.info(fn ->
      "map_system contents =>\n" <> inspect(system, pretty: true)
    end)

    Enum.map(structures, fn s ->
      # The parent's Ash resource uses 'system_id' for the parent's ID
      # We'll copy the EVE system ID from system.solar_system_id
      # We'll also store the system name from system.name
      %{
        id: Map.get(s, "id"),

        # Usually your resource's "system_id" is the parent's ID
        system_id: system.id,

        # The EVE ID, an integer
        solar_system_id: system.solar_system_id,

        # EVE system name
        solar_system_name: system.name,

        # The rest
        type_id: Map.get(s, "typeId"),
        name: Map.get(s, "name"),
        description: Map.get(s, "description"),
        kind: Map.get(s, "kind"),
        group: Map.get(s, "group"),
        type: Map.get(s, "type"),
        custom_info: Map.get(s, "customInfo"),
        character_eve_id: character_eve_id,
        owner: Map.get(s, "owner"),
        owner_ticker: Map.get(s, "ownerTicker"),
        owner_id: Map.get(s, "ownerId"),
        status: Map.get(s, "status"),
        end_time: parse_end_time(Map.get(s, "endTime"))
      }
    end)
  end

  defp parse_end_time(nil), do: nil

  defp parse_end_time(string_time) do
    case DateTime.from_iso8601(string_time) do
      {:ok, dt, _offset} ->
        dt

      {:error, reason} ->
        Logger.error("Error parsing ISO-8601 string: #{string_time}. Reason: #{inspect(reason)}")
        nil
    end
  end
end
