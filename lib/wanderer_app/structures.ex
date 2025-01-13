defmodule WandererApp.StructuresService do
  @moduledoc """
  Encapsulates the logic for parsing and updating system structures.
  """

  require Logger
  alias WandererApp.Api.MapSystemStructures

  def update_structures(system, added, updated, removed, user_characters) do
    first_char_eve_id = List.first(user_characters)

    added_structs =
      parse_structures(added, first_char_eve_id, system)
      |> Enum.map(&Map.delete(&1, :id))

    updated_structs = parse_structures(updated, first_char_eve_id, system)
    removed_structs = parse_structures(removed, first_char_eve_id, system)

    remove_structures(system.id, Enum.map(removed_structs, & &1.id))
    update_structures_in_db(system.id, updated_structs, Enum.map(updated_structs, & &1.id))
    add_structures(added_structs)

    :ok
  end

  def search_corporation_names([], _search), do: {:ok, []}

  def search_corporation_names([first_char | _], search) when is_binary(search) do
    Character.search(first_char.id, params: [search: search, categories: "corporation"])
  end

  def search_corporation_names(_user_chars, _search), do: {:ok, []}

  defp parse_structures(list_of_maps, character_eve_id, system) do
    Logger.debug(fn ->
      "[StructuresService] parse_structures sees =>\n" <> inspect(list_of_maps, pretty: true)
    end)

    Enum.map(list_of_maps, fn item ->
      %{
        id: Map.get(item, "id"),
        system_id: system.id,
        solar_system_id: system.solar_system_id,
        solar_system_name: system.name,
        type_id: Map.get(item, "typeId") || "???",
        character_eve_id: character_eve_id,
        name: Map.get(item, "name"),
        notes: Map.get(item, "notes"),
        type: Map.get(item, "type"),
        owner: Map.get(item, "owner"),
        owner_ticker: Map.get(item, "ownerTicker"),
        owner_id: Map.get(item, "ownerId"),
        status: Map.get(item, "status"),
        end_time: parse_end_time(Map.get(item, "endTime"))
      }
    end)
  end

  defp parse_end_time(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        dt

      {:error, reason} ->
        Logger.error("Error parsing ISO-8601 string: #{str}, reason: #{inspect(reason)}")
        nil
    end
  end

  defp parse_end_time(_), do: nil

  defp remove_structures(system_id, removed_ids) do
    MapSystemStructures.by_system_id!(system_id)
    |> Enum.filter(fn s -> s.id in removed_ids end)
    |> Enum.each(&Ash.destroy!/1)
  end

  defp update_structures_in_db(system_id, updated_structs, updated_ids) do
    existing_records = MapSystemStructures.by_system_id!(system_id)

    Enum.each(existing_records, fn existing ->
      if existing.id in updated_ids do
        updated_data = Enum.find(updated_structs, fn u -> u.id == existing.id end)

        if updated_data do
          Logger.debug(fn ->
            "[StructuresService] about to update =>\n" <>
              inspect(updated_data, pretty: true)
          end)

          updated_data = Map.delete(updated_data, :id)

          new_record = MapSystemStructures.update(existing, updated_data)
          Logger.debug(fn ->
            "[StructuresService] updated record =>\n" <> inspect(new_record, pretty: true)
          end)
        end
      end
    end)
  end

  defp add_structures(added_structs) do
    Enum.each(added_structs, fn struct_map ->
      Logger.debug(fn ->
        "[StructuresService] Creating structure =>\n" <>
          inspect(struct_map, pretty: true)
      end)
      MapSystemStructures.create!(struct_map)
    end)
  end
end
