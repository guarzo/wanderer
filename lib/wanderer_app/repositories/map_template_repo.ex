defmodule WandererApp.MapTemplateRepo do
  @moduledoc """
  Repository for map templates operations.
  """

  use WandererApp, :repository
  require Logger

  alias WandererApp.Api.MapTemplate
  alias WandererApp.MapSystemRepo
  alias WandererApp.MapConnectionRepo

  @known_attrs [
    :name,
    :description,
    :category,
    :author_eve_id,
    :source_map_id,
    :is_public,
    :systems,
    :connections,
    :metadata
  ]

  @doc "Creates a new template."
  def create(params) when is_map(params) do
    atomized =
      for {k, v} <- params, into: %{} do
        key = if is_binary(k), do: String.to_atom(k), else: k
        if key in @known_attrs, do: {key, v}, else: {:__drop__, nil}
      end
      |> Map.drop([:__drop__])

    Logger.debug("Atomized params for create: #{inspect(atomized)}")
    MapTemplate.create(atomized)
  end

  @doc "Gets a template by ID."
  def get(id), do: MapTemplate.read(id)

  @doc "Lists all public templates."
  def list_public, do: MapTemplate.read_public()

  @doc "Lists templates by author."
  def list_by_author(author_id), do: MapTemplate.read_by_author(%{author_eve_id: author_id})

  @doc "Lists templates by category."
  def list_by_category(category), do: MapTemplate.read_by_category(%{category: category})

  @doc "Updates metadata of a template."
  def update_metadata(template, params), do: MapTemplate.update_metadata(template, params)

  @doc "Updates content of a template."
  def update_content(template, params), do: MapTemplate.update_content(template, params)

  @doc "Deletes a template."
  def destroy(template), do: MapTemplate.destroy(template)

  @doc """
  Creates a template from a map.

  Loads systems and connections, applies filters, and saves as a reusable template.
  """
  def create_from_map(map_id, params) do
    with {:ok, validated} <- validate_author_eve_id(params),
         {:ok, systems} <- MapSystemRepo.get_all_by_map(map_id),
         {:ok, connections} <- MapConnectionRepo.get_by_map(map_id) do
      norm = normalize_selection_params(validated)
      selected = filter_systems_by_selection(systems, norm)

      if Enum.empty?(selected) do
        {:error, :no_systems_selected}
      else
        sys_data = prepare_systems_for_template(selected)
        conn_data = prepare_connections_for_template(connections, selected)

        template = %{
          name: Map.get(validated, "name", "Unnamed Template"),
          description: Map.get(validated, "description", ""),
          category: Map.get(validated, "category", "custom"),
          author_eve_id: Map.get(validated, "author_eve_id"),
          source_map_id: map_id,
          is_public: Map.get(validated, "is_public", false),
          systems: sys_data,
          connections: conn_data,
          metadata: Map.get(validated, "metadata", %{})
        }

        Logger.debug("Creating template: #{inspect(template)}")
        create(template)
      end
    else
      {:error, reason} ->
        Logger.error("Error creating template from map: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Applies a template to a map.

  Creates systems and connections as defined in the template.
  """
  def apply_template(map_id, template_id, opts \\ %{}) do
    Logger.debug("Template apply options: #{inspect(opts)}")

    with {:ok, template} <- get(template_id),
         {:ok, _} <- MapSystemRepo.get_all_by_map(map_id),
         {:ok, new_systems} <- create_systems_from_template(map_id, template.systems),
         {:ok, new_conns} <-
           create_connections_from_template(map_id, template.connections, new_systems) do
      {:ok,
       %{
         summary: %{
           systems_added: length(new_systems),
           connections_added: length(new_conns)
         }
       }}
    else
      {:error, :not_found} -> {:error, "Template not found"}
      {:error, err} when is_binary(err) -> {:error, err}
      other -> {:error, other}
    end
  end

  # -- Helper Functions --

  defp parse_author_eve_id(params) do
    Map.get(params, "author_eve_id")
  end

  defp ensure_string(val) when is_integer(val), do: Integer.to_string(val)
  defp ensure_string(val) when is_binary(val), do: val
  defp ensure_string(_), do: nil

  defp validate_author_eve_id(params) do
    case ensure_string(parse_author_eve_id(params)) do
      nil ->
        {:ok, params}

      eve_id ->
        case WandererApp.Esi.get_character_info(eve_id) do
          {:ok, info} -> {:ok, Map.put(params, "author_eve_id", info["eve_id"])}
          {:error, :not_found} -> {:error, "Character #{eve_id} not found in EVE"}
          {:error, reason} -> {:error, "Error validating character: #{inspect(reason)}"}
        end
    end
  end

  defp normalize_selection_params(params) do
    selection = Map.get(params, "selection", %{})

    solar_ids =
      selection["solar_system_ids"] || selection["system_ids"] || params["solar_system_ids"] ||
        params["system_ids"]

    system_ids = selection["system_ids"] || params["system_ids"]

    params
    |> Map.put("solar_system_ids", solar_ids)
    |> Map.put("system_ids", system_ids)
  end

  defp filter_systems_by_selection(systems, %{"solar_system_ids" => ids})
       when is_list(ids) and ids != [] do
    Enum.filter(systems, fn s -> s.solar_system_id in ids || to_string(s.id) in ids end)
  end

  defp filter_systems_by_selection(systems, %{"system_ids" => ids})
       when is_list(ids) and ids != [] do
    Enum.filter(systems, fn s -> to_string(s.id) in ids end)
  end

  defp filter_systems_by_selection(systems, _params), do: systems

  defp prepare_systems_for_template(systems) do
    Enum.map(systems, fn s ->
      %{
        solar_system_id: s.solar_system_id,
        name: s.name,
        position_x: s.position_x,
        position_y: s.position_y
      }
      |> maybe_put(:status, s.status)
      |> maybe_put(:tag, s.tag)
      |> maybe_put(:description, s.description)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp prepare_connections_for_template(conns, systems) do
    ids = MapSet.new(Enum.map(systems, & &1.solar_system_id))

    conns
    |> Enum.filter(fn c ->
      MapSet.member?(ids, c.solar_system_source) and MapSet.member?(ids, c.solar_system_target)
    end)
    |> Enum.map(
      &%{
        source_index:
          Enum.find_index(systems, fn s -> s.solar_system_id == &1.solar_system_source end),
        target_index:
          Enum.find_index(systems, fn s -> s.solar_system_id == &1.solar_system_target end),
        type: &1.type
      }
    )
    |> Enum.reject(&(is_nil(&1.source_index) or is_nil(&1.target_index)))
  end

  # Create systems from a template
  defp create_systems_from_template(map_id, template_systems) do
    with {:ok, existing_systems} <- MapSystemRepo.get_all_by_map(map_id),
         {:ok, %{id: char_id, user_id: user_id}} <- get_first_valid_character_for_map(map_id) do
      Logger.info("Using character #{char_id} for system import")

      existing_ids = MapSet.new(existing_systems, & &1.solar_system_id)

      template_systems
      |> Enum.map(&build_system_attrs(&1, map_id, existing_ids))
      |> Enum.reject(&is_nil/1)
      |> assign_positions()
      |> Enum.reduce_while({:ok, []}, fn system, {:ok, acc} ->
        create_system_entry(system, map_id, user_id, char_id, acc)
      end)
      |> case do
        {:ok, created} -> {:ok, Enum.reverse(created)}
        err -> err
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_system_attrs(system, map_id, existing_ids) do
    id = get_property(system, "solar_system_id")

    attrs = %{
      map_id: map_id,
      solar_system_id: id,
      already_exists: MapSet.member?(existing_ids, id)
    }

    attrs
    |> maybe_put(:name, get_property(system, "name"))
    |> maybe_put(:position_x, get_property(system, "position_x"))
    |> maybe_put(:position_y, get_property(system, "position_y"))
    |> Enum.reduce([:status, :tag, :description], fn key, acc ->
      maybe_put(acc, key, get_property(system, Atom.to_string(key)))
    end)
  end

  defp assign_positions(systems) do
    spacing_x = 200
    spacing_y = 150
    count = length(systems)
    grid = trunc(:math.sqrt(count))

    Enum.with_index(systems)
    |> Enum.map(fn {s, idx} ->
      if Map.has_key?(s, :position_x) and Map.has_key?(s, :position_y) do
        s
      else
        Map.merge(s, %{
          position_x: 100 + rem(idx, grid) * spacing_x,
          position_y: 100 + div(idx, grid) * spacing_y
        })
      end
    end)
  end

  defp create_system_entry(attrs, map_id, user_id, char_id, acc) do
    id = attrs.solar_system_id

    with {:ok, _info} <- WandererApp.CachedInfo.get_system_static_info(id),
         coordinates <- %{"x" => attrs.position_x, "y" => attrs.position_y},
         params <- %{solar_system_id: id, coordinates: coordinates},
         {:ok, _} <- WandererApp.Map.Server.add_system(map_id, params, user_id, char_id),
         {:ok, sys} <- MapSystemRepo.get_by_map_and_solar_system_id(map_id, id) do
      {:cont, {:ok, [sys | acc]}}
    else
      {:error, reason} ->
        Logger.warning("Skipped system #{id}: #{inspect(reason)}")
        {:cont, {:ok, acc}}
    end
  rescue
    e ->
      Logger.error("Error adding system #{inspect(e)}")
      {:cont, {:ok, acc}}
  end

  defp create_connections_from_template(map_id, template_conns, systems) do
    {:ok, existing} = MapConnectionRepo.get_by_map(map_id)

    index_map = systems |> Enum.with_index() |> Map.new(fn {s, i} -> {i, s} end)
    id_map = Map.new(systems, &{&1.solar_system_id, &1})

    with {:ok, %{id: char_id, user_id: user_id}} <- get_first_valid_character_for_map(map_id) do
      template_conns
      |> Enum.flat_map(&build_connection_attrs(&1, index_map, id_map, map_id, existing))
      |> Enum.reduce({[], []}, fn attrs, {ok, err} ->
        case create_connection(attrs, map_id, user_id, char_id) do
          {:ok, conn} -> {[conn | ok], err}
          {:error, e} -> {ok, [e | err]}
        end
      end)
      |> then(fn {created, _errors} -> {:ok, Enum.reverse(created)} end)
    end
  end

  defp build_connection_attrs(conn, idx_map, id_map, map_id, existing) do
    source =
      Map.get(conn, "source_index") |> then(&Map.get(idx_map, &1)) ||
        Map.get(conn, "source_solar_system_id") |> then(&Map.get(id_map, &1))

    target =
      Map.get(conn, "target_index") |> then(&Map.get(idx_map, &1)) ||
        Map.get(conn, "target_solar_system_id") |> then(&Map.get(id_map, &1))

    if source && target &&
         !connection_exists?(source.solar_system_id, target.solar_system_id, existing) do
      [
        %{
          map_id: map_id,
          solar_system_source: source.solar_system_id,
          solar_system_target: target.solar_system_id,
          type: Map.get(conn, "type", 0)
        }
      ]
    else
      []
    end
  end

  defp connection_exists?(sid1, sid2, existing) do
    Enum.any?(existing, fn c ->
      (c.solar_system_source == sid1 && c.solar_system_target == sid2) ||
        (c.solar_system_source == sid2 && c.solar_system_target == sid1)
    end)
  end

  defp create_connection(attrs, map_id, _user_id, _char_id) do
    case MapConnectionRepo.create(attrs) do
      {:ok, conn} ->
        WandererApp.Map.add_connection(map_id, conn)
        {:ok, conn}

      err ->
        err
    end
  rescue
    e -> {:error, e}
  end

defp get_first_valid_character_for_map(map_id) do
  Logger.info("Resolving character for map_id=#{map_id}")

  with {:ok, map} <- WandererApp.MapRepo.get(map_id, [:owner]),
       %{owner: owner} <- map,
       {:ok, map_char_settings} <- MapCharacterSettingsRepo.get_all_by_map(map_id),
       true <- map_char_settings != [] do
    character_ids = Enum.map(map_char_settings, & &1.character_id)
    Logger.info("Found map character IDs: #{inspect(character_ids)}")

    case WandererApp.Api.read(Character |> Ash.Query.filter(id in ^character_ids)) do
      {:ok, characters} when is_list(characters) and characters != [] ->
        Logger.info("Loaded character records: #{inspect(Enum.map(characters, & &1.id))}")

        characters_by_user =
          characters
          |> Enum.filter(& &1.user_id)
          |> Enum.group_by(& &1.user_id)

        Logger.info("Grouped characters by user: #{inspect(Map.keys(characters_by_user))}")

        # Load map user settings
        settings_query =
          WandererApp.Api.MapUserSettings
          |> Ash.Query.new()
          |> Ash.Query.filter(map_id == ^map_id)

        main_eve_id =
          case WandererApp.Api.read(settings_query) do
            {:ok, [setting | _]} ->
              Logger.info("Found MapUserSettings: #{inspect(setting)}")
              setting.main_character_eve_id

            {:ok, []} ->
              Logger.info("No MapUserSettings found for map_id=#{map_id}")
              nil

            {:error, err} ->
              Logger.info("Error loading MapUserSettings: #{inspect(err)}")
              nil
          end

        # Try to find a match for main_character_eve_id
        character =
          if main_eve_id do
            Enum.find(characters, fn c -> to_string(c.eve_id) == to_string(main_eve_id) end)
          else
            # Fall back to any character owned by the map owner
            List.first(characters_by_user[owner.id] || [])
          end

        case character do
          nil ->
            Logger.info("No matching character found, even with fallback")
            {:error, "No valid characters for map owner (user_id=#{owner.id}) on map #{map_id}"}

          _ ->
            Logger.info("Selected character: #{inspect(character)}")
            {:ok, %{id: character.id, user_id: character.user_id}}
        end

      {:ok, []} ->
        Logger.info("No character records found for map_id=#{map_id}")
        {:error, "No character records available for this map"}

      {:error, reason} ->
        Logger.info("Failed to load characters: #{inspect(reason)}")
        {:error, "Could not fetch characters: #{inspect(reason)}"}
    end
  else
    {:error, reason} ->
      Logger.info("Error resolving map or map character settings: #{inspect(reason)}")
      {:error, reason}

    false ->
      Logger.info("Map has no character settings associated.")
      {:error, "Map has no characters assigned"}
  end
end


  def get_map_user_settings(map_id, user_id) do
    case WandererApp.MapUserSettingsRepo.get(map_id, user_id) do
      {:ok, settings} when not is_nil(settings) ->
        Logger.info("Settings: #{inspect(settings)}")
        {:ok, settings}
      _ ->
        {:ok, %{main_character_eve_id: nil}}
    end
  end

  defp get_property(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
