defmodule WandererApp.MapTemplateRepo do
  @moduledoc """
  Repository for map templates operations.
  """

  use WandererApp, :repository
  import Ash.Query
  require Logger

  alias WandererApp.Api.MapTemplate
  alias WandererApp.MapSystemRepo
  alias WandererApp.MapConnectionRepo
  alias Wandererpp.MapCharacterSettingsRepo

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
    with {:ok, validated_params} <- validate_author_eve_id(params) do
      validated_params
      |> atomize_keys()
      |> Map.take(@known_attrs)
      |> MapTemplate.create()
    else
      # Propagate the validation error
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Gets a template by ID."
  def get(id), do: MapTemplate.read(id)

  @doc "Lists all public templates."
  def list_public, do: MapTemplate.read_public()

  @doc "Lists templates by author."
  def list_by_author(author_id),
    do: MapTemplate.read_by_author(%{author_eve_id: author_id})

  @doc "Lists templates by category."
  def list_by_category(category),
    do: MapTemplate.read_by_category(%{category: category})

  @doc "Lists all templates associated with a specific source map ID."
  def list_all_for_map(map_id),
    do: MapTemplate.read_all_for_map(%{source_map_id: map_id})

  @doc "Updates metadata of a template."
  def update_metadata(template, params),
    do: MapTemplate.update_metadata(template, params)

  @doc "Updates content of a template."
  def update_content(template, params),
    do: MapTemplate.update_content(template, params)

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
      normalized = normalize_selection_params(validated)
      selected = filter_systems_by_selection(systems, normalized)

      if Enum.empty?(selected) do
        Logger.warning("No systems selected for template creation from map_id=#{map_id}")
        {:error, :no_systems_selected}
      else
        template_attrs = %{
          name: Map.get(validated, "name", "Unnamed Template"),
          description: Map.get(validated, "description", ""),
          category: Map.get(validated, "category", "custom"),
          author_eve_id: Map.get(validated, "author_eve_id"),
          source_map_id: map_id,
          is_public: Map.get(validated, "is_public", false),
          systems: prepare_systems_for_template(selected),
          connections: prepare_connections_for_template(connections, selected),
          metadata: Map.get(validated, "metadata", %{})
        }

        create(template_attrs)
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
    cleanup_existing = Map.get(opts, "cleanup_existing", false)

    # Chain the operations, handling errors at each step
    with {:ok, template} <- get(template_id),
         _ <- Logger.info("Applying template repo - Template ID: #{template_id}, Map ID: #{map_id}"),
         {:ok, visible_systems} <- MapSystemRepo.get_visible_by_map(map_id),
         visible_ids_before <- MapSet.new(visible_systems, & &1.solar_system_id),
         _ <- Logger.info("Visible systems before apply: #{inspect(visible_ids_before)}"),
         _ <- maybe_cleanup_existing_systems(map_id, cleanup_existing),
         {:ok, created_systems} <- create_systems_from_template(map_id, template.systems || []),
         conn_result = create_connections_from_template(map_id, template.connections, created_systems, template.systems || []),
         {:ok, visible_systems_after} <- MapSystemRepo.get_visible_by_map(map_id),
         visible_systems_after_ids <- MapSet.new(visible_systems_after, & &1.solar_system_id) do

      # Count newly visible systems by comparing before and after
      newly_visible = MapSet.difference(visible_systems_after_ids, visible_ids_before)
      newly_visible_count = MapSet.size(newly_visible)

      Logger.info("Visible systems after apply: #{inspect(visible_systems_after_ids)}")
      Logger.info("Newly visible systems: #{inspect(newly_visible)}, count: #{newly_visible_count}")

      # Create connections now that systems are in place
      # Don't call this again since we already have conn_result
      # conn_result = create_connections_from_template(map_id, template.connections, created_systems, template.systems || [])

      # Calculate connections_added from the connection result
      connections_added = case conn_result do
        {:ok, %{connections: conns, failed_connections: failed}} ->
          Logger.info("Created #{length(conns)} connections, failed: #{failed}")
          length(conns)
        {:ok, conns} when is_list(conns) ->
          # Handle legacy format for backward compatibility
          length(conns)
        _ -> 0
      end

      result = %{
        summary: %{
          systems_added: length(created_systems),
          connections_added: connections_added,
          newly_visible: MapSet.size(newly_visible)
        },
        failed_connections: case conn_result do
          {:ok, %{failed_connections: failed}} -> failed
          _ -> 0
        end
      }

      {:ok, result}
    else
      # Handle errors from any step in the 'with' chain
      {:error, :not_found} ->
        {:error, "Template not found"}

      {:error, reason} ->
        # Catches errors returned from create_systems or create_connections
        {:error, "Error applying template: #{inspect(reason)}"}

      # Catch potential errors from the initial get(template_id) call
      other_error ->
        {:error, "Failed to fetch template or unexpected error: #{inspect(other_error)}"}
    end
  end

  # Helper function to optionally clean up existing systems before applying a template
  defp maybe_cleanup_existing_systems(map_id, true) do
    # Get all visible systems
    with {:ok, visible_systems} <- MapSystemRepo.get_visible_by_map(map_id) do
      # Extract system IDs
      solar_system_ids = Enum.map(visible_systems, & &1.solar_system_id)

      if length(solar_system_ids) > 0 do
        # Use the MapServer deletion for proper cleanup
        Logger.info("Cleanup requested - removing #{length(solar_system_ids)} existing systems")
        WandererApp.Map.Server.delete_systems(map_id, solar_system_ids, nil, nil)
      end

      :ok
    else
      err ->
        Logger.error("Error during cleanup of existing systems: #{inspect(err)}")
        :ok # Continue anyway
    end
  end

  defp maybe_cleanup_existing_systems(_map_id, _cleanup_existing), do: :ok

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp atomize_keys(map) do
    map
    |> Enum.map(fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      other -> other
    end)
    |> Enum.into(%{})
  end

  defp normalize_selection_params(params) do
    sel = Map.get(params, "selection", %{})

    solar_ids =
      sel["solar_system_ids"] ||
        sel["system_ids"] ||
        params["solar_system_ids"] ||
        params["system_ids"]

    sys_ids = sel["system_ids"] || params["system_ids"]

    params
    |> Map.put("solar_system_ids", solar_ids)
    |> Map.put("system_ids", sys_ids)
  end

  defp filter_systems_by_selection(systems, %{"solar_system_ids" => ids})
       when is_list(ids) and ids != [] do
    Enum.filter(systems, fn s ->
      s.solar_system_id in ids || to_string(s.id) in ids
    end)
  end

  defp filter_systems_by_selection(systems, %{"system_ids" => ids})
       when is_list(ids) and ids != [] do
    Enum.filter(systems, fn s -> to_string(s.id) in ids end)
  end

  defp filter_systems_by_selection(systems, _), do: systems

  defp prepare_systems_for_template(systems) do
    Enum.map(systems, fn s ->
      %{
        solar_system_id: s.solar_system_id,
        name: s.name,
        position_x: s.position_x,
        position_y: s.position_y
      }
      |> put_if_present(:status, s.status)
      |> put_if_present(:tag, s.tag)
      |> put_if_present(:description, s.description)
    end)
  end

  defp prepare_connections_for_template(conns, systems) do
    ids = MapSet.new(Enum.map(systems, & &1.solar_system_id))

    conns
    |> Enum.filter(fn c ->
      MapSet.member?(ids, c.solar_system_source) and
        MapSet.member?(ids, c.solar_system_target)
    end)
    |> Enum.map(&connection_template_entry(&1, systems))
    |> Enum.reject(&is_nil/1)
  end

  defp connection_template_entry(conn, systems) do
    src_idx =
      Enum.find_index(systems, fn s -> s.solar_system_id == conn.solar_system_source end)

    tgt_idx =
      Enum.find_index(systems, fn s -> s.solar_system_id == conn.solar_system_target end)

    if src_idx && tgt_idx do
      %{
        source_index: src_idx,
        target_index: tgt_idx,
        type: conn.type
      }
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, val), do: Map.put(map, key, val)

  defp get_property(map, key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp validate_author_eve_id(params) do
    case ensure_string(Map.get(params, "author_eve_id")) do
      nil ->
        {:ok, params}

      eve_id ->
        case WandererApp.Esi.get_character_info(eve_id) do
          {:ok, info} ->
            {:ok, Map.put(params, "author_eve_id", info["eve_id"])}

          {:error, :not_found} ->
            {:error, "Character #{eve_id} not found in EVE"}

          {:error, reason} ->
            {:error, "Error validating character: #{inspect(reason)}"}
        end
    end
  end

  defp ensure_string(val) when is_integer(val), do: Integer.to_string(val)
  defp ensure_string(val) when is_binary(val),  do: val
  defp ensure_string(_),                       do: nil

  defp create_systems_from_template(map_id, template_systems) do
    with {:ok, existing_systems} <- MapSystemRepo.get_all_by_map(map_id),
         {:ok, visible_systems} <- MapSystemRepo.get_visible_by_map(map_id),
         _ <- Logger.info("Input template_systems: #{inspect(template_systems)}"),
         {:ok, %{id: char_id, user_id: user_id}} <- get_owner_character_id(map_id) do

      existing_ids = MapSet.new(existing_systems, & &1.solar_system_id)
      visible_ids = MapSet.new(visible_systems, & &1.solar_system_id)

      # 1. Resolve all system identifiers first
      processed_attrs =
        template_systems
        |> Enum.map(&build_system_attrs(&1, map_id, existing_ids))

      valid_processed_attrs = Enum.filter(processed_attrs, fn {:ok, _} -> true; _ -> false end) |> Enum.map(&elem(&1, 1))
      errors = Enum.filter(processed_attrs, fn {:error, _} -> true; _ -> false end)

      if errors != [] do
        Logger.warning("Errors encountered building system attributes from template: #{inspect(errors)}")
        # Decide if we should proceed or return an error
        # For now, we proceed with valid ones
      end

      # 2. Calculate initially_not_visible using RESOLVED IDs
      resolved_template_ids = MapSet.new(valid_processed_attrs, & &1.solar_system_id)
      initially_not_visible_ids = MapSet.difference(resolved_template_ids, visible_ids)

      Logger.info("Existing IDs: #{inspect(existing_ids)}")
      Logger.info("Visible IDs: #{inspect(visible_ids)}")
      Logger.info("Resolved Template IDs: #{inspect(resolved_template_ids)}")
      Logger.info("Corrected Initially Not Visible IDs: #{inspect(initially_not_visible_ids)}")

      # 3. Assign positions to valid attributes
      attrs_to_create = assign_positions(valid_processed_attrs)
      Logger.info("Attributes to create/update (after validation & positioning): #{inspect(attrs_to_create)}")

      # 4. Process entries and accumulate based on the corrected set
      attrs_to_create
      |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
        Logger.info("Processing system entry for attrs: #{inspect(attrs)}")
        case create_system_entry(attrs, map_id, user_id, char_id) do
          {:ok, sys} ->
            # 5. Add to accumulator ONLY if it wasn't initially visible
            if MapSet.member?(initially_not_visible_ids, sys.solar_system_id) do
              Logger.debug("System #{sys.solar_system_id} was initially not visible, adding to result.")
              {:cont, {:ok, [sys | acc]}}
            else
              Logger.debug("System #{sys.solar_system_id} was already visible, skipping in result.")
              {:cont, {:ok, acc}}
            end

          {:skip, reason} -> # Handle cases where creation might be skipped (e.g., already exists and visible)
             Logger.debug("Skipping system entry processing: #{reason}")
            {:cont, {:ok, acc}}

          {:error, reason} -> # Handle errors during creation/update
            Logger.error("Error processing system entry: #{inspect(reason)}, continuing with others.")
            # Decide whether to halt or continue. Continuing for now.
            {:cont, {:ok, acc}}
        end
      end)
      |> case do
        {:ok, created} -> {:ok, Enum.reverse(created)}
        err -> err # Propagate halt errors if any
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_system_attrs(system, map_id, existing_ids) do
    with {:ok, system_identifier} <- determine_system_identifier(system),
         {:ok, static_info} <- WandererApp.CachedInfo.get_system_static_info(system_identifier) do

      # Use template positions if available, otherwise fallback to static info (if exists), else default to 0
      pos_x = get_property(system, "position_x") || Map.get(static_info, :position_x, 0)
      pos_y = get_property(system, "position_y") || Map.get(static_info, :position_y, 0)

      attrs = %{
        map_id: map_id,
        solar_system_id: system_identifier,
        already_exists: MapSet.member?(existing_ids, system_identifier),
        position_x: pos_x,
        position_y: pos_y
      }

      final_attrs =
        [:status, :tag, :description]
        |> Enum.reduce(attrs, fn key, acc ->
          put_if_present(acc, key, get_property(system, Atom.to_string(key)))
        end)

      {:ok, final_attrs}
    else
      # Propagate errors from identifier determination or static info lookup
      {:error, :static_info_not_found} ->
        Logger.warning("Static info not found for system identifier determined from: #{inspect(system)}")
        {:error, :static_info_not_found}
      {:error, reason} ->
        Logger.warning("Could not build system attrs for #{inspect(system)}: #{reason}")
        {:error, reason}
    end
  end

  defp determine_system_identifier(system) do
    cond do
      id = get_property(system, "solar_system_id") ->
        {:ok, id}
      name = get_property(system, "name") ->
        # find_system_id_by_name returns the ID directly or nil
        case WandererApp.CachedInfo.find_system_id_by_name(name) do
          id when is_integer(id) -> # Successfully found the ID
            {:ok, id}
          nil -> # Explicitly handle lookup failure
            {:error, "Failed to find system ID by name '#{name}'"}
          _ -> # Should not happen, but capture unexpected non-integer/non-nil results
             {:error, "Unexpected non-ID result from name lookup for '#{name}'"}
        end
      true ->
        {:error, :missing_identifier}
    end
  end

  defp assign_positions(systems) do
    spacing_x = 200
    spacing_y = 150
    count     = max(length(systems), 1)
    grid      = trunc(:math.sqrt(count))

    Enum.with_index(systems)
    |> Enum.map(fn {sys, idx} ->
      if Map.has_key?(sys, :position_x) and Map.has_key?(sys, :position_y) do
        sys
      else
        Map.merge(sys, %{position_x: 100 + rem(idx, grid) * spacing_x, position_y: 100 + div(idx, grid) * spacing_y})
      end
    end)
  end

  defp create_system_entry(attrs, map_id, user_id, char_id) do
    id = attrs.solar_system_id
    Logger.debug("Processing system entry for attrs: #{inspect(attrs)}")

    # Create system_info struct with coordinates for MapServer.add_system
    coordinates = %{"x" => attrs.position_x, "y" => attrs.position_y}
    params = %{solar_system_id: id, coordinates: coordinates, visible: true}

    # Use the same add_system method that the API now uses
    Logger.debug("Calling Map.Server.add_system with params: #{inspect(params)}")
    WandererApp.Map.Server.add_system(map_id, params, user_id, char_id)

    # Check if system exists after attempting to add it
    Logger.debug("Calling MapSystemRepo.get_by_map_and_solar_system_id for map_id: #{map_id}, solar_system_id: #{id}")
    case MapSystemRepo.get_by_map_and_solar_system_id(map_id, id) do
      {:ok, system} ->
        # System exists, check visibility
        Logger.debug("System #{id} found after add. Visible: #{system.visible}")
        if not system.visible do
          # The system already exists but isn't visible
          # add_system will handle making it visible for us, so call it again
          WandererApp.Map.Server.add_system(map_id, %{
            solar_system_id: id,
            use_old_coordinates: true
          }, user_id, char_id)

          # Fetch the updated system to return
          {:ok, updated_system} = MapSystemRepo.get_by_map_and_solar_system_id(map_id, id)
          {:ok, updated_system}
        else
          {:ok, system}
        end

      {:error, :not_found} ->
        Logger.error("System #{id} not found after successful add_system call. Cannot proceed.")
        {:error, :system_not_found_after_add}

      {:error, reason} ->
          Logger.error("Error fetching system #{id} after add: #{inspect(reason)}")
          {:error, reason}
    end
  rescue
    e in [MatchError] ->
      Logger.error("Pattern match error in create_system_entry (likely from add_system result): #{inspect(e)}")
      {:error, :match_error}
    e ->
      Logger.error("Exception in create_system_entry: #{inspect(e)}")
      {:error, e}
  end

  defp create_connections_from_template(map_id, template_conns, systems, template_systems) do
    template_conns = template_conns || []
    _systems = systems || [] # Keep for backward compatibility but prefix with _ since unused
    template_systems = template_systems || []

    {:ok, existing} = MapConnectionRepo.get_by_map(map_id)

    # First, ensure we have all needed systems
    with {:ok, %{id: char_id, user_id: user_id}} <- get_owner_character_id(map_id),
         {:ok, all_systems} <- MapSystemRepo.get_all_by_map(map_id) do

      # For each connection in the template
      system_ids_by_template_index = get_system_ids_from_template(template_systems)
      Logger.info("System IDs by Template Index: #{inspect(system_ids_by_template_index)}")

      # Map by solar_system_id for all systems on map
      system_by_id = Map.new(all_systems, &{&1.solar_system_id, &1})

      # Process each connection using the direct template indices
      attrs_list = Enum.flat_map(template_conns, fn conn ->
        # Build connections based on template indices and corresponding system IDs
        process_connection_by_template_index(conn, system_ids_by_template_index, system_by_id, map_id, existing)
      end)

      {created, errors} = Enum.reduce(attrs_list, {[], []}, fn attrs, {oks, errs} ->
        case create_connection(attrs, map_id, user_id, char_id) do
          {:ok, conn} -> {[conn | oks], errs}
          {:skip, _} -> {oks, errs} # Don't count skips as errors
          {:error, e} -> {oks, [e | errs]}
        end
      end)

      if errors != [], do: Logger.error("Connection creation errors: #{inspect(errors)}")
      # Include count of errored connections in the result
      {:ok, %{connections: Enum.reverse(created), failed_connections: length(errors)}}
    else
      err ->
        Logger.error("Failed to create connections: #{inspect(err)}")
        {:ok, %{connections: [], failed_connections: 0}} # Return empty list for connections rather than error
    end
  end

  # New helper to get system IDs directly from template definitions
  defp get_system_ids_from_template(template_systems) do
    template_systems
    |> Enum.with_index()
    |> Enum.flat_map(fn {system, idx} ->
      case determine_system_identifier(system) do
        {:ok, system_id} -> [{idx, system_id}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  # Process connection using template index to directly map to system IDs
  defp process_connection_by_template_index(conn, system_ids_by_index, system_by_id, map_id, existing) do
    src_idx = Map.get(conn, "source_index")
    tgt_idx = Map.get(conn, "target_index")
    conn_type = Map.get(conn, "type", 0)

    Logger.info("Processing connection by template index - src_idx: #{inspect(src_idx)}, tgt_idx: #{inspect(tgt_idx)}")

    # Get the actual system IDs from the index map built from template
    src_id = Map.get(system_ids_by_index, src_idx)
    tgt_id = Map.get(system_ids_by_index, tgt_idx)

    Logger.info("Template index mapped to system IDs - src_id: #{inspect(src_id)}, tgt_id: #{inspect(tgt_id)}")

    # If we found both systems by ID, create the connection
    if src_id && tgt_id do
      src_system = Map.get(system_by_id, src_id)
      tgt_system = Map.get(system_by_id, tgt_id)

      if src_system && tgt_system do
        exists = connection_exists?(src_id, tgt_id, existing)

        if exists do
          Logger.info("Connection already exists between #{src_id} and #{tgt_id}, skipping")
          []
        else
          Logger.info("Adding connection between #{src_id} and #{tgt_id}")
          [%{
            map_id: map_id,
            solar_system_source: src_id,
            solar_system_target: tgt_id,
            type: conn_type
          }]
        end
      else
        Logger.warning("Could not find system objects for IDs: src_id=#{src_id}, tgt_id=#{tgt_id}")
        []
      end
    else
      Logger.warning("Missing source or target ID from template indices: src_idx=#{src_idx}, tgt_idx=#{tgt_idx}")
      []
    end
  end

  defp connection_exists?(sid1, sid2, existing) do
    Enum.any?(existing, fn c ->
      # A connection is considered to exist if either direction (source->target or target->source) exists
      (c.solar_system_source == sid1 and c.solar_system_target == sid2) or
      (c.solar_system_source == sid2 and c.solar_system_target == sid1)
    end)
  end

  defp create_connection(attrs, map_id, user_id, char_id) do
    Logger.info("Creating connection: #{inspect(attrs)}")

    # Verify first if this exact connection already exists (double-check)
    with {:ok, existing} <- MapConnectionRepo.get_by_map(map_id) do
      if connection_exists?(attrs.solar_system_source, attrs.solar_system_target, existing) do
        Logger.info("Connection already exists, skipping creation")
        {:skip, :already_exists}
      else
        # Use MapServer for adding connections consistently
        connection_info = %{
          solar_system_source_id: attrs.solar_system_source,
          solar_system_target_id: attrs.solar_system_target,
          character_id: char_id || "00000000-0000-0000-0000-000000000000", # Ensure a character ID is always provided
          type: attrs.type
        }

        # Call the server method for adding connections
        WandererApp.Map.Server.add_connection(map_id, connection_info)

        # Retrieve the created connection for the response - with retry logic
        retrieve_connection_with_retry(map_id, attrs.solar_system_source, attrs.solar_system_target)
      end
    else
      err ->
        Logger.error("Error fetching existing connections: #{inspect(err)}")
        err
    end
  rescue
    e ->
      Logger.error("Exception in create_connection: #{inspect(e)}")
      {:error, e}
  end

  # New helper function to retry connection retrieval a few times with a delay
  defp retrieve_connection_with_retry(map_id, source_id, target_id, retries \\ 3) do
    {:ok, connections} = MapConnectionRepo.get_by_locations(
      map_id,
      source_id,
      target_id
    )

    if connections && length(connections) > 0 do
      conn = List.first(connections)
      Logger.info("Created connection: #{inspect(conn)}")
      {:ok, conn}
    else
      # Try the reverse direction as well
      {:ok, reverse_connections} = MapConnectionRepo.get_by_locations(
        map_id,
        target_id,
        source_id
      )

      if reverse_connections && length(reverse_connections) > 0 do
        conn = List.first(reverse_connections)
        Logger.info("Created connection (found in reverse direction): #{inspect(conn)}")
        {:ok, conn}
      else
        if retries > 0 do
          # Add a small delay and retry
          Process.sleep(100)
          Logger.info("Retrying connection retrieval (#{retries} attempts left)")
          retrieve_connection_with_retry(map_id, source_id, target_id, retries - 1)
        else
          err = {:error, :connection_not_found_after_creation}
          Logger.error("Error retrieving created connection after retries: #{inspect(err)}")
          err
        end
      end
    end
  end

  def get_owner_character_id(map_id) do
    with {:ok, map} <- WandererApp.MapRepo.get(map_id, [:owner]),
         %{owner: owner} <- map,
         {:ok, settings} <- WandererApp.MapCharacterSettingsRepo.get_all_by_map(map_id),
         char_ids when is_list(char_ids) and char_ids != [] <- Enum.map(settings, & &1.character_id),
         {:ok, all_chars} <-
           WandererApp.Api.read(
             WandererApp.Api.Character
             |> Ash.Query.new()
             |> Ash.Query.filter(id in ^char_ids)
           ),
         {:ok, user_settings} <- WandererApp.MapUserSettingsRepo.get(map_id, owner.id),
         user_chars <- Enum.filter(all_chars, fn c -> to_string(c.user_id) == to_string(owner.id) end),
         {:ok, main_char} <- WandererApp.Character.TrackingUtils.get_main_character(user_settings, user_chars, all_chars) do

      {:ok, %{id: main_char.id, user_id: main_char.user_id}}
    else
      nil ->
        Logger.warning("No valid fallback character found")
        {:error, "No valid characters for map owner"}

      {:error, reason} ->
        Logger.error("Failed to resolve main character: #{inspect(reason)}")
        {:error, reason}

      [] ->
        Logger.warning("No characters associated with map")
        {:error, "No characters associated with this map"}
    end
  end

  # This function is kept for potential future use but prefixed with underscore to avoid unused warnings
  defp _find_fallback_character(chars, owner_user_id) do
    Enum.find(chars, fn c ->
      to_string(c.user_id) == to_string(owner_user_id)
    end)
  end
end
