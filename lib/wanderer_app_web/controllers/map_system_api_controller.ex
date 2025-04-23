defmodule WandererAppWeb.MapSystemAPIController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.MapSystemRepo
  alias WandererApp.MapConnectionRepo
  alias WandererAppWeb.UtilAPIController, as: Util
  alias WandererAppWeb.Schemas.MapApiSchemas

  action_fallback WandererAppWeb.FallbackController

  plug :load_map_id when action in [
    :list_systems,
    :show_system,
    :upsert_systems,
    :delete_systems,
    :list_connections,
    :upsert_connections,
    :delete_connections,
    :upsert_systems_and_connections
  ]

  @doc """
  GET /api/map/systems
  Lists visible systems for a map.
  """
  operation(
    :list_systems,
    summary: "List Map Systems"
  )
  def list_systems(conn, _params) do
    with {:ok, systems} <- MapSystemRepo.get_visible_by_map(conn.assigns.map_id) do
      json(conn, %{data: Enum.map(systems, &Util.map_system_to_json/1)})
    end
  end

  @doc """
  GET /api/map/system
  Retrieves a single system by ID or name.
  """
  operation(
    :show_system,
    summary: "Show Map System by ID or Name"
  )
  def show_system(conn, %{"id" => id_param}) do
    case Util.parse_int(id_param) do
      {:ok, system_id} ->
        # When parameter is a valid integer, proceed with ID lookup
        with {:ok, system} <- MapSystemRepo.get_by_map_and_solar_system_id(conn.assigns.map_id, system_id) do
          json(conn, %{data: Util.map_system_to_json(system)})
        end

      _ ->
        # If not a valid integer, treat as a system name
        solar_system_id = WandererApp.CachedInfo.find_system_id_by_name(id_param)

        if solar_system_id do
          with {:ok, system} <- MapSystemRepo.get_by_map_and_solar_system_id(conn.assigns.map_id, solar_system_id) do
            json(conn, %{data: Util.map_system_to_json(system)})
          else
            _ ->
              conn
              |> put_status(:not_found)
              |> json(%{error: "System not found in this map"})
          end
        else
          conn
          |> put_status(:not_found)
          |> json(%{error: "System not found"})
        end
    end
  end

  @doc """
  PATCH /api/map/systems
  Upserts multiple systems individually.
  """
  operation(
    :upsert_systems,
    summary: "Batch upsert systems"
  )
  def upsert_systems(conn, _params) do
    map_id = conn.assigns.map_id
    systems = Map.get(conn.body_params, "systems", [])

    # Split into systems to create vs update
    {to_create, to_update} = partition_entities(systems, map_id, &prepare_system/2)

    # Use proper Map.Server.add_system for new systems
    created = Enum.map(to_create, fn attrs ->
      # Convert to the format expected by the MapServer.add_system
      solar_system_id = attrs.solar_system_id

      # Extract position coordinates if provided
      coordinates = if Map.has_key?(attrs, :position_x) && Map.has_key?(attrs, :position_y) do
        %{"x" => attrs.position_x, "y" => attrs.position_y}
      else
        nil # Let the server calculate position
      end

      # Create system_info struct for server call
      system_info = %{
        solar_system_id: solar_system_id,
        coordinates: coordinates
      }

      # Call the proper MapServer add_system implementation
      WandererApp.Map.Server.add_system(map_id, system_info, nil, nil)

      # Fetch the system to return in the response
      {:ok, system} = MapSystemRepo.get_by_map_and_solar_system_id(map_id, solar_system_id)
      system
    end)

    # Use existing update for system updates
    updated = Enum.map(to_update, &update_system!/1)

    json(conn, %{data: %{
      created: Enum.map(created, &Util.map_system_to_json/1),
      updated: Enum.map(updated, &Util.map_system_to_json/1)
    }})
  end

  @doc """
  DELETE /api/map/systems
  Deletes multiple systems and associated connections.
  """
  operation(
    :delete_systems,
    summary: "Batch delete systems"
  )
  def delete_systems(conn, _params) do
    ids = Map.get(conn.body_params, "system_ids", [])

    with {:ok, systems} <- fetch_entities_by_ids(MapSystemRepo, conn.assigns.map_id, ids) do
      # Extract system solar_system_ids for actual deletion
      solar_system_ids = Enum.map(systems, & &1.solar_system_id)

      # Use the full MapServer implementation to properly delete systems
      # This handles connections, rtree data, broadcasting, and other cleanup
      WandererApp.Map.Server.delete_systems(
        conn.assigns.map_id,
        solar_system_ids,
        nil,  # user_id is optional for this operation
        nil   # character_id is optional for this operation
      )

      # Count connections that were deleted
      deleted_conn_count = delete_connections_for_systems(conn.assigns.map_id, systems)

      # Return success response with counts
      json(conn, %{data: %{
        deleted_connections_count: deleted_conn_count,
        deleted_count: length(solar_system_ids)
      }})
    end
  end

  @doc """
  GET /api/map/connections
  Lists connections for a map.
  """
  operation(
    :list_connections,
    summary: "List Map Connections"
  )
  def list_connections(conn, _params) do
    with {:ok, conns} <- MapConnectionRepo.get_by_map(conn.assigns.map_id) do
      json(conn, %{data: Enum.map(conns, &Util.connection_to_json/1)})
    end
  end

  @doc """
  PATCH /api/map/connections
  Upserts multiple connections individually.
  """
  operation(
    :upsert_connections,
    summary: "Batch upsert connections"
  )
  def upsert_connections(conn, _params) do
    map_id = conn.assigns.map_id
    connections = Map.get(conn.body_params, "connections", [])

    {to_create, to_update} = partition_entities(connections, map_id, &prepare_connection/2)

    created = Enum.map(to_create, &create_connection!/1)
    updated = Enum.map(to_update, &update_connection!/1)

    json(conn, %{data: %{
      created: Enum.map(created, &Util.connection_to_json/1),
      updated: Enum.map(updated, &Util.connection_to_json/1)
    }})
  end

  @doc """
  DELETE /api/map/connections
  Deletes multiple connections.
  """
  operation(
    :delete_connections,
    summary: "Batch delete connections"
  )
  def delete_connections(conn, _params) do
    ids = Map.get(conn.body_params, "connection_ids", [])

    with {:ok, conns} <- fetch_entities_by_ids(MapConnectionRepo, conn.assigns.map_id, ids) do
      deleted_count =
        conns
        |> Enum.map(fn c ->
          MapConnectionRepo.destroy(conn.assigns.map_id, c)
          1
        end)
        |> Enum.sum()

      json(conn, %{data: %{deleted_count: deleted_count}})
    end
  end

  @doc """
  PATCH /api/map/systems-and-connections
  Batch upsert systems and connections.
  """
  operation(
    :upsert_systems_and_connections,
    summary: "Batch upsert systems and connections"
  )
  def upsert_systems_and_connections(conn, _params) do
    map_id = conn.assigns.map_id
    systems = Map.get(conn.body_params, "systems", [])
    connections = Map.get(conn.body_params, "connections", [])

    {sc, su} = partition_entities(systems, map_id, &prepare_system/2)
    {cc, cu} = partition_entities(connections, map_id, &prepare_connection/2)

    # Use proper Map.Server.add_system for new systems
    created_sys = Enum.map(sc, fn attrs ->
      # Convert to the format expected by the MapServer.add_system
      solar_system_id = attrs.solar_system_id

      # Extract position coordinates if provided
      coordinates = if Map.has_key?(attrs, :position_x) && Map.has_key?(attrs, :position_y) do
        %{"x" => attrs.position_x, "y" => attrs.position_y}
      else
        nil # Let the server calculate position
      end

      # Create system_info struct for server call
      system_info = %{
        solar_system_id: solar_system_id,
        coordinates: coordinates
      }

      # Call the proper MapServer add_system implementation
      WandererApp.Map.Server.add_system(map_id, system_info, nil, nil)

      # Fetch the system to return in the response
      {:ok, system} = MapSystemRepo.get_by_map_and_solar_system_id(map_id, solar_system_id)
      system
    end)

    updated_sys = Enum.map(su, &update_system!/1)
    created_conns = Enum.map(cc, &create_connection!/1)
    updated_conns = Enum.map(cu, &update_connection!/1)

    json(conn, %{data: %{
      systems: %{created: Enum.map(created_sys, &Util.map_system_to_json/1), updated: Enum.map(updated_sys, &Util.map_system_to_json/1)},
      connections: %{created: Enum.map(created_conns, &Util.connection_to_json/1), updated: Enum.map(updated_conns, &Util.connection_to_json/1)}
    }})
  end

  #----------------------------------------
  # Helpers

  defp create_system!(attrs) do
    case MapSystemRepo.create(attrs) do
      {:ok, sys} -> sys
      {:error, _} ->
        {:ok, sys} = MapSystemRepo.get_by_map_and_solar_system_id(attrs.map_id, attrs.solar_system_id)
        sys
    end
  end

  defp update_system!(%{id: id} = attrs) do
    # First get the system to get its map_id and solar_system_id
    {:ok, existing_system} = WandererApp.Api.MapSystem.by_id(id)
    map_id = existing_system.map_id
    solar_system_id = existing_system.solar_system_id

    # Use the MapServer methods for proper RTree updates and broadcasting
    # Each property needs its own specific update method call

    # Position updates are most critical for RTree
    if Map.has_key?(attrs, :position_x) || Map.has_key?(attrs, :position_y) do
      WandererApp.Map.Server.update_system_position(map_id, %{
        solar_system_id: solar_system_id,
        position_x: Map.get(attrs, :position_x, existing_system.position_x),
        position_y: Map.get(attrs, :position_y, existing_system.position_y)
      })
    end

    # Status updates
    if Map.has_key?(attrs, :status) do
      WandererApp.Map.Server.update_system_status(map_id, %{
        solar_system_id: solar_system_id,
        status: attrs.status
      })
    end

    # Description updates
    if Map.has_key?(attrs, :description) do
      WandererApp.Map.Server.update_system_description(map_id, %{
        solar_system_id: solar_system_id,
        description: attrs.description
      })
    end

    # Tag updates
    if Map.has_key?(attrs, :tag) do
      WandererApp.Map.Server.update_system_tag(map_id, %{
        solar_system_id: solar_system_id,
        tag: attrs.tag
      })
    end

    # Labels updates
    if Map.has_key?(attrs, :labels) do
      WandererApp.Map.Server.update_system_labels(map_id, %{
        solar_system_id: solar_system_id,
        labels: attrs.labels
      })
    end

    # Visibility updates
    if Map.has_key?(attrs, :visible) do
      if attrs.visible do
        # If making visible, use add_system with use_old_coordinates
        # This will handle all RTree updates and broadcasting
        WandererApp.Map.Server.add_system(map_id, %{
          solar_system_id: solar_system_id,
          use_old_coordinates: true
        }, nil, nil)
      else
        # When hiding a system, use the delete_systems method which properly
        # handles removing from RTree and broadcasting the change
        # This is equivalent to turning off visibility in the UI
        WandererApp.Map.Server.delete_systems(
          map_id,
          [solar_system_id],
          nil,   # user_id is optional
          nil    # character_id is optional
        )
      end
    end

    # Temporary name updates
    if Map.has_key?(attrs, :temporary_name) do
      WandererApp.Map.Server.update_system_temporary_name(map_id, %{
        solar_system_id: solar_system_id,
        temporary_name: attrs.temporary_name
      })
    end

    # Lock status updates
    if Map.has_key?(attrs, :locked) do
      WandererApp.Map.Server.update_system_locked(map_id, %{
        solar_system_id: solar_system_id,
        locked: attrs.locked
      })
    end

    # Return the updated system
    {:ok, updated_system} = MapSystemRepo.get_by_map_and_solar_system_id(map_id, solar_system_id)
    updated_system
  end

  defp create_connection!(attrs) do
    allowed = [:map_id, :solar_system_source, :solar_system_target, :type]

    clean = attrs
    |> Util.atomize_keys()
    |> Map.take(allowed)

    # Use MapServer for consistent connection creation
    connection_info = %{
      solar_system_source_id: clean.solar_system_source,
      solar_system_target_id: clean.solar_system_target,
      character_id: "00000000-0000-0000-0000-000000000000", # Use a default character ID
      type: Map.get(clean, :type, 0)
    }

    # Call the MapServer method to ensure proper RTree updates and broadcasting
    WandererApp.Map.Server.add_connection(clean.map_id, connection_info)

    # Retrieve the connection from the database
    {:ok, connections} = MapConnectionRepo.get_by_locations(
      clean.map_id,
      clean.solar_system_source,
      clean.solar_system_target
    )

    if connections && length(connections) > 0 do
      List.first(connections)
    else
      # For backward compatibility, try the old way as a fallback
      case MapConnectionRepo.create(clean) do
        {:ok, conn} -> conn
        {:error, _} ->
          {:ok, list} = MapConnectionRepo.get_by_locations(clean.map_id, clean.solar_system_source, clean.solar_system_target)
          List.first(list)
      end
    end
  end

  defp update_connection!(%{id: id} = attrs) do
    # First get the connection to get its map_id, source and target system IDs
    {:ok, existing_connection} = WandererApp.Api.MapConnection.by_id(id)
    map_id = existing_connection.map_id
    solar_system_source_id = existing_connection.solar_system_source
    solar_system_target_id = existing_connection.solar_system_target

    # Use the MapServer methods for proper RTree updates and broadcasting
    # Each property needs its own specific update method call

    # Type updates
    if Map.has_key?(attrs, :type) do
      WandererApp.Map.Server.update_connection_type(map_id, %{
        solar_system_source_id: solar_system_source_id,
        solar_system_target_id: solar_system_target_id,
        type: attrs.type
      })
    end

    # Mass status updates
    if Map.has_key?(attrs, :mass_status) do
      WandererApp.Map.Server.update_connection_mass_status(map_id, %{
        solar_system_source_id: solar_system_source_id,
        solar_system_target_id: solar_system_target_id,
        mass_status: attrs.mass_status
      })
    end

    # Time status updates
    if Map.has_key?(attrs, :time_status) do
      WandererApp.Map.Server.update_connection_time_status(map_id, %{
        solar_system_source_id: solar_system_source_id,
        solar_system_target_id: solar_system_target_id,
        time_status: attrs.time_status
      })
    end

    # Ship size updates
    if Map.has_key?(attrs, :ship_size_type) do
      WandererApp.Map.Server.update_connection_ship_size_type(map_id, %{
        solar_system_source_id: solar_system_source_id,
        solar_system_target_id: solar_system_target_id,
        ship_size_type: attrs.ship_size_type
      })
    end

    # Lock status updates
    if Map.has_key?(attrs, :locked) do
      WandererApp.Map.Server.update_connection_locked(map_id, %{
        solar_system_source_id: solar_system_source_id,
        solar_system_target_id: solar_system_target_id,
        locked: attrs.locked
      })
    end

    # Custom info updates
    if Map.has_key?(attrs, :custom_info) do
      WandererApp.Map.Server.update_connection_custom_info(map_id, %{
        solar_system_source_id: solar_system_source_id,
        solar_system_target_id: solar_system_target_id,
        custom_info: attrs.custom_info
      })
    end

    # Wormhole type updates - this doesn't have a direct MapServer method
    # but needs to be updated via the Repo with a direct DB update
    if Map.has_key?(attrs, :wormhole_type) do
      # Since there's no MapServer method for this, we need to update directly
      # and then broadcast the change ourselves
      {:ok, updated_connection} = WandererApp.MapConnectionRepo.update_wormhole_type(
        existing_connection,
        %{wormhole_type: attrs.wormhole_type}
      )

      # Since there's no matching MapServer method, we need to update the RTree manually
      # This is a simplified approach - in a complete solution, you might want to
      # add a dedicated MapServer method for this update
      WandererApp.Map.update_connection(map_id, updated_connection)
    end

    # Return the updated connection
    # First try to find it in the database via locations since that's most reliable
    {:ok, connections} = MapConnectionRepo.get_by_locations(
      map_id,
      solar_system_source_id,
      solar_system_target_id
    )

    if connections && length(connections) > 0 do
      List.first(connections)
    else
      # Fallback to getting by ID (less reliable as ID could change in some edge cases)
      {:ok, conn} = WandererApp.Api.MapConnection.by_id(id)
      conn
    end
  end

  defp delete_connections_for_systems(map_id, systems) do
    system_ids = Enum.map(systems, & &1.solar_system_id)
    {:ok, all_conns} = MapConnectionRepo.get_by_map(map_id)

    all_conns
    |> Enum.filter(fn c -> c.solar_system_source in system_ids or c.solar_system_target in system_ids end)
    |> Enum.map(fn c ->
      MapConnectionRepo.destroy(map_id, c)
      1
    end)
    |> Enum.sum()
  end

  defp load_map_id(conn, _) do
    case Util.fetch_map_id(Map.merge(conn.params, conn.body_params)) do
      {:ok, mid} -> assign(conn, :map_id, mid)
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})
        |> halt()
    end
  end

  defp partition_entities(list, map_id, fun) do
    list
    |> Enum.map(&fun.(&1, map_id))
    |> Enum.split_with(fn {action, _} -> action == :create end)
    |> then(fn {creates, updates} -> {Enum.map(creates, &elem(&1, 1)), Enum.map(updates, &elem(&1, 1))} end)
  end

  defp prepare_system(%{"id" => _} = params, _), do: {:update, Util.atomize_keys(params)}
  defp prepare_system(%{"solar_system_id" => sid} = params, map_id), do:
    {:create, Util.atomize_keys(params) |> Map.put(:map_id, map_id) |> Map.put_new(:name, "System #{sid}")}
  defp prepare_system(_, _), do: {:create, %{}}

  defp prepare_connection(%{"id" => _} = params, _), do: {:update, Util.atomize_keys(params)}
  defp prepare_connection(%{"solar_system_source" => _, "solar_system_target" => _} = params, map_id), do:
    {:create, Util.atomize_keys(params) |> Map.put(:map_id, map_id)}
  defp prepare_connection(_, _), do: {:create, %{}}

  defp fetch_entities_by_ids(repo, map_id, ids) do
    fetch_fun = cond do
      function_exported?(repo, :get_by_map, 1)     -> &repo.get_by_map/1
      function_exported?(repo, :get_all_by_map, 1) -> &repo.get_all_by_map/1
    end

    with {:ok, all} <- fetch_fun.(map_id) do
      filtered = Enum.filter(all, &(&1.id in ids))
      {:ok, filtered}
    end
  end
end
