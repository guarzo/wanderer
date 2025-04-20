defmodule WandererAppWeb.UtilAPIController do
  @moduledoc """
  Utility functions for parameter handling, fetch helpers, etc.
  """

  alias WandererApp.Api
  import Ash.Query

  def fetch_map_id(%{"map_id" => mid}) when is_binary(mid) and mid != "" do
    {:ok, mid}
  end

  def fetch_map_id(%{"slug" => slug}) when is_binary(slug) and slug != "" do
    case Api.Map.get_map_by_slug(slug) do
      {:ok, map} ->
        {:ok, map.id}

      {:error, _reason} ->
        {:error, "No map found for slug=#{slug}"}
    end
  end

  def fetch_map_id(_),
    do: {:error, "Must provide either ?map_id=UUID or ?slug=SLUG"}

  # Require a given param to be present and non-empty
  def require_param(params, key) do
    case params[key] do
      nil -> {:error, "Missing required param: #{key}"}
      "" -> {:error, "Param #{key} cannot be empty"}
      val -> {:ok, val}
    end
  end

  # Parse a string into an integer
  def parse_int(str) do
    case Integer.parse(str) do
      {num, ""} -> {:ok, num}
      _ -> {:error, "Invalid integer for param id=#{str}"}
    end
  end

  # Validate that an ID is a valid UUID
  def validate_uuid(nil), do: {:error, "ID cannot be nil"}

  def validate_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> {:ok, id}
      :error -> {:error, "Invalid UUID format"}
    end
  end

  def validate_uuid(_), do: {:error, "ID must be a string"}

  # Format an error response with a standardized structure
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(:not_found), do: "Resource not found"
  def format_error({:not_found, resource}), do: "#{resource} not found"
  def format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_error(_reason), do: "An error occurred"

  # Convert string keys to atoms (safely)
  def atomize_keys(map) do
    allowed_keys = [
      :id,
      :solar_system_id,
      :position_x,
      :position_y,
      :status,
      :description,
      :map_id,
      :locked,
      :visible,
      :solar_system_source,
      :solar_system_target,
      :type,
      :name,
      :author_id,
      :author_eve_id,
      :category,
      :is_public,
      :source_map_id,
      :systems,
      :connections,
      :metadata,
      :mass_status,
      :time_status,
      :ship_size_type,
      :wormhole_type,
      :count_of_passage,
      :custom_info,
      :tag,
      :custom_name,
      :temporary_name,
      :labels
    ]

    # First normalize author_eve_id to author_id if present
    normalized_map =
      if Map.has_key?(map, "author_eve_id") do
        author_id = Map.get(map, "author_eve_id")

        map
        |> Map.put("author_id", author_id)
        |> Map.delete("author_eve_id")
      else
        map
      end

    normalized_map
    |> Enum.flat_map(fn
      {k, v} when is_binary(k) ->
        try do
          key_atom = String.to_existing_atom(k)

          if Enum.member?(allowed_keys, key_atom) do
            [{key_atom, v}]
          else
            []
          end
        rescue
          ArgumentError -> []
        end

      entry ->
        [entry]
    end)
    |> Map.new()
  end

  # JSON conversion for map systems
  def map_system_to_json(system) do
    # Get the original system name from the database
    original_name = get_original_system_name(system.solar_system_id)

    # Start with the basic system data
    result =
      Map.take(system, [
        :id,
        :map_id,
        :solar_system_id,
        :custom_name,
        :temporary_name,
        :description,
        :tag,
        :labels,
        :locked,
        :visible,
        :status,
        :position_x,
        :position_y,
        :inserted_at,
        :updated_at
      ])

    # Add the original name
    result = Map.put(result, :original_name, original_name)

    # Set the name field based on the display priority:
    # 1. If temporary_name is set, use that
    # 2. If custom_name is set, use that
    # 3. Otherwise, use the original system name
    display_name =
      cond do
        not is_nil(system.temporary_name) and system.temporary_name != "" ->
          system.temporary_name

        not is_nil(system.custom_name) and system.custom_name != "" ->
          system.custom_name

        true ->
          original_name
      end

    # Add the display name as the "name" field
    Map.put(result, :name, display_name)
  end

  # Get original system name
  defp get_original_system_name(solar_system_id) do
    # Fetch the original system name from the MapSolarSystem resource
    case WandererApp.Api.MapSolarSystem.by_solar_system_id(solar_system_id) do
      {:ok, system} ->
        system.solar_system_name

      _error ->
        "Unknown System"
    end
  end

  # JSON conversion for connections
  def connection_to_json(connection) do
    Map.take(connection, [
      :id,
      :map_id,
      :solar_system_source,
      :solar_system_target,
      :mass_status,
      :time_status,
      :ship_size_type,
      :type,
      :wormhole_type,
      :inserted_at,
      :updated_at
    ])
  end

  # Helper to handle different return values from destroy operations
  def handle_destroy_result(:ok), do: :ok
  def handle_destroy_result({:ok, _}), do: :ok
  # Handle Ash bulk result structs specifically
  def handle_destroy_result(%Ash.BulkResult{status: :success}), do: :ok
  def handle_destroy_result(%Ash.BulkResult{status: :error, errors: errors}), do: {:error, errors}
  # Catch-all for other potential error tuples/values
  def handle_destroy_result(error), do: {:error, error}

  @doc """
  Gets the most appropriate character for performing operations on a map.
  Prioritizes the main character for the map owner, then falls back to any available character.

  Returns:
    * `{:ok, %{id: character_id, user_id: user_id}}` on success
    * `{:error, reason}` on failure
  """
  def get_character_for_map_operation(map_id) do
    # First try to get character settings for the map
    case WandererApp.MapCharacterSettingsRepo.get_all_by_map(map_id) do
      {:ok, map_character_settings} when map_character_settings != [] ->
        # Get the character IDs from settings
        character_ids_list = Enum.map(map_character_settings, & &1.character_id)

        # Create a query for characters with these IDs
        character_query =
          WandererApp.Character
          |> filter(id in ^character_ids_list)

        case WandererApp.Api.read(character_query) do
          {:ok, characters} when characters != [] ->
            # Filter characters with valid user IDs and group by user
            valid_characters =
              characters
              |> Enum.filter(fn char -> not is_nil(char.user_id) end)

            if Enum.empty?(valid_characters) do
              {:error, "No valid characters found for map"}
            else
              # Get map info to find the owner
              case WandererApp.MapRepo.get(map_id) do
                {:ok, map} ->
                  owner_id = map.owner_id

                  # Try to find the main character for this map
                  # Create a variable to use in the query
                  map_id_val = map_id

                  settings_query =
                    WandererApp.Api.MapUserSettings
                    |> Ash.Query.new()
                    |> Ash.Query.filter(map_id == ^map_id_val)

                  main_characters_by_user =
                    case WandererApp.Api.read(settings_query) do
                      {:ok, map_user_settings} ->
                        Map.new(map_user_settings, fn settings ->
                          {settings.user_id, settings.main_character_eve_id}
                        end)

                      _ ->
                        %{}
                    end

                  # First try to get the owner's main character
                  owner_characters =
                    Enum.filter(valid_characters, fn char -> char.user_id == owner_id end)

                  character =
                    cond do
                      # 1. Owner's main character
                      owner_id && Map.has_key?(main_characters_by_user, owner_id) ->
                        main_eve_id = Map.get(main_characters_by_user, owner_id)

                        Enum.find(owner_characters, fn char ->
                          to_string(char.eve_id) == to_string(main_eve_id)
                        end)

                      # 2. Any owner character
                      not Enum.empty?(owner_characters) ->
                        hd(owner_characters)

                      # 3. Any user's main character
                      not Enum.empty?(main_characters_by_user) ->
                        any_user_id = hd(Map.keys(main_characters_by_user))
                        main_eve_id = Map.get(main_characters_by_user, any_user_id)

                        Enum.find(valid_characters, fn char ->
                          to_string(char.eve_id) == to_string(main_eve_id)
                        end)

                      # 4. Any character
                      true ->
                        hd(valid_characters)
                    end

                  if character do
                    {:ok, %{id: character.id, user_id: character.user_id}}
                  else
                    {:error, "No suitable character found"}
                  end

                {:error, reason} ->
                  {:error, "Failed to load map: #{inspect(reason)}"}
              end
            end

          {:ok, []} ->
            {:error, "No characters found"}

          {:error, reason} ->
            {:error, "Failed to fetch characters: #{inspect(reason)}"}
        end

      {:ok, []} ->
        # No character settings, try to get the map owner's main character
        with {:ok, map} <- WandererApp.MapRepo.get(map_id, [:owner]),
             owner when not is_nil(owner) <- map.owner,
             {:ok, main_char} <- WandererApp.CharacterRepo.get_main_character(owner.id) do
          if is_nil(main_char.id) or is_nil(main_char.user_id) do
            {:error, "Main character has invalid data"}
          else
            {:ok, %{id: main_char.id, user_id: main_char.user_id}}
          end
        else
          nil -> {:error, "Map has no owner"}
          {:error, reason} -> {:error, reason}
          _ -> {:error, "Could not find a valid character"}
        end

      {:error, reason} ->
        {:error, "Failed to fetch map character settings: #{inspect(reason)}"}
    end
  end
end
