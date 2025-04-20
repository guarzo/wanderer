defmodule WandererAppWeb.MapSystemAPIController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.Api
  alias WandererApp.MapSystemRepo
  alias WandererApp.MapConnectionRepo
  alias WandererAppWeb.UtilAPIController, as: Util

  # Reference schemas from MapAPIController
  alias WandererAppWeb.MapAPIController, as: MapAPISchemas

  @doc """
  GET /api/map/systems

  Requires either `?map_id=<UUID>` **OR** `?slug=<map-slug>` in the query params.

  Only "visible" systems are returned.

  Examples:
      GET /api/map/systems?map_id=466e922b-e758-485e-9b86-afae06b88363
      GET /api/map/systems?slug=my-unique-wormhole-map
  """
  @spec list_systems(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :list_systems,
    summary: "List Map Systems",
    description: "Lists all visible systems for a map. Requires either 'map_id' or 'slug' as a query parameter to identify the map.",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID) - Either map_id or slug must be provided",
        type: :string,
        required: false,
        example: ""
      ],
      slug: [
        in: :query,
        description: "Map slug - Either map_id or slug must be provided",
        type: :string,
        required: false,
        example: "map-name"
      ]
    ],
    responses: [
      ok: {
        "List of map systems",
        "application/json",
        MapAPISchemas.list_map_systems_response_schema()
      },
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          error: %OpenApiSpex.Schema{type: :string}
        },
        required: ["error"],
        example: %{
          "error" => "Must provide either ?map_id=UUID or ?slug=SLUG"
        }
      }}
    ]
  def list_systems(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, systems} <- MapSystemRepo.get_visible_by_map(map_id) do
      data = Enum.map(systems, &map_system_to_json/1)
      json(conn, %{data: data})
    else
      {:error, msg} when is_binary(msg) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Could not fetch systems: #{inspect(reason)}"})
    end
  end

  @doc """
  GET /api/map/system

  Requires 'id' (the solar_system_id)
  plus either ?map_id=<UUID> or ?slug=<map-slug>.

  Example:
      GET /api/map/system?id=31002229&map_id=466e922b-e758-485e-9b86-afae06b88363
      GET /api/map/system?id=31002229&slug=my-unique-wormhole-map
  """
  @spec show_system(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :show_system,
    summary: "Show Map System",
    description: "Retrieves details for a specific map system (by solar_system_id + map). Requires either 'map_id' or 'slug' as a query parameter to identify the map.",
    parameters: [
      id: [
        in: :query,
        description: "System ID",
        type: :string,
        required: true,
        example: "30000142"
      ],
      map_id: [
        in: :query,
        description: "Map identifier (UUID) - Either map_id or slug must be provided",
        type: :string,
        required: false,
        example: ""
      ],
      slug: [
        in: :query,
        description: "Map slug - Either map_id or slug must be provided",
        type: :string,
        required: false,
        example: "map-name"
      ]
    ],
    responses: [
      ok: {
        "Map system details",
        "application/json",
        MapAPISchemas.show_map_system_response_schema()
      },
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          error: %OpenApiSpex.Schema{type: :string}
        },
        required: ["error"],
        example: %{
          "error" => "Must provide either ?map_id=UUID or ?slug=SLUG as a query parameter"
        }
      }},
      not_found: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          error: %OpenApiSpex.Schema{type: :string}
        },
        required: ["error"],
        example: %{
          "error" => "System not found"
        }
      }}
    ]
  def show_system(conn, params) do
    with {:ok, solar_system_str} <- Util.require_param(params, "id"),
         {:ok, solar_system_id} <- Util.parse_int(solar_system_str),
         {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, system} <- MapSystemRepo.get_by_map_and_solar_system_id(map_id, solar_system_id) do
      data = map_system_to_json(system)
      json(conn, %{data: data})
    else
      {:error, msg} when is_binary(msg) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "System not found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Could not load system: #{inspect(reason)}"})
    end
  end

  @doc """
  PATCH /api/map/systems

  Upserts (creates or updates) multiple systems in a batch operation.

  If a system includes an 'id', it will be updated if it exists.
  If a system does not have an 'id' but includes a 'solar_system_id', it will attempt to
  find an existing system with that solar_system_id for the map, and update it if found,
  or create a new one if not.

  This endpoint supports partial updates - only fields that are included will be modified.

  Example body:
  ```json
  {
    "map_id": "466e922b-e758-485e-9b86-afae06b88363",
    "systems": [
      {
        "solar_system_id": 30000142,
        "position_x": 100,
        "position_y": 200,
        "labels": "{"customLabel":"Hub","labels":["highsec"]}"
      },
      {
        "id": "some-uuid",
        "status": 1,
        "description": "Updated description"
      }
    ]
  }
  ```
  """
  @spec upsert_systems(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :upsert_systems,
    summary: "Batch upsert systems",
    description: "Creates or updates multiple systems in one operation. Systems with IDs are updated, systems without IDs but with solar_system_ids are matched and updated if they exist, or created if they don't.",
    request_body: {"Map systems to upsert", "application/json", MapAPISchemas.upsert_systems_request_schema()},
    responses: [
      ok: {"System upsert result", "application/json", MapAPISchemas.upsert_systems_response_schema()},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]
  def upsert_systems(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, systems_to_upsert} <- extract_systems_from_params(params),
         {:ok, existing_systems} <- MapSystemRepo.get_all_by_map(map_id),
         {:ok, {systems_to_create, systems_to_update}} <- prepare_systems_for_upsert(map_id, systems_to_upsert, existing_systems),
         {:ok, created_systems} <- create_systems(systems_to_create),
         {:ok, updated_systems} <- update_systems(systems_to_update) do
      json(conn, %{
        data: %{
          created: Enum.map(created_systems || [], &map_system_to_json/1),
          updated: Enum.map(updated_systems || [], &map_system_to_json/1)
        }
      })
    else
      {:error, msg} when is_binary(msg) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Error processing systems: #{inspect(reason)}"})
    end
  end

  @doc """
  DELETE /api/map/systems

  Deletes multiple systems in a batch operation.

  This will also delete any connections associated with the deleted systems.

  Example body:
  ```json
  {
    "map_id": "466e922b-e758-485e-9b86-afae06b88363",
    "system_ids": [
      "system-uuid-1",
      "system-uuid-2"
    ]
  }
  ```
  """
  @spec delete_systems(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :delete_systems,
    summary: "Batch delete systems",
    description: "Deletes multiple systems in one operation. This will also delete any connections associated with the deleted systems.",
    request_body: {"Map systems to delete", "application/json", MapAPISchemas.delete_systems_request_schema()},
    responses: [
      ok: {"System delete result", "application/json", MapAPISchemas.delete_systems_response_schema()},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]
  def delete_systems(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, system_ids} <- extract_system_ids_from_params(params),
         {:ok, systems} <- get_systems_by_ids(map_id, system_ids),
         {:ok, connections} <- get_connections_for_systems(map_id, systems),
         {:ok, _} <- delete_connections_for_systems(connections),
         {:ok, deleted_count} <- bulk_delete_systems(systems) do
      json(conn, %{
        data: %{
          deleted_count: deleted_count,
          deleted_connections_count: length(connections)
        }
      })
    else
      {:error, msg} when is_binary(msg) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Error deleting systems: #{inspect(reason)}"})
    end
  end

  # ---------------- Private Helpers ----------------

  # Extract systems from params
  defp extract_systems_from_params(%{"systems" => systems}) when is_list(systems), do: {:ok, systems}
  defp extract_systems_from_params(_), do: {:error, "Missing or invalid 'systems' parameter"}

  # Prepare systems for upsert by separating them into create and update operations
  defp prepare_systems_for_upsert(map_id, systems_to_upsert, existing_systems) do
    # Create a map of existing systems by id and by solar_system_id for quick lookup
    existing_by_id = Map.new(existing_systems, &{&1.id, &1})
    existing_by_solar_id = Map.new(existing_systems, &{&1.solar_system_id, &1})

    {to_create, to_update} =
      Enum.reduce(systems_to_upsert, {[], []}, fn system_params, {creates, updates} ->
        cond do
          # Case 1: System has ID and exists - update
          Map.has_key?(system_params, "id") && Map.has_key?(existing_by_id, system_params["id"]) ->
            # Get the existing system ID, but use params directly for the update
            system_id = system_params["id"]
            update_params = atomize_keys(system_params)
            updates = [{system_id, update_params} | updates]
            {creates, updates}

          # Case 2: System has solar_system_id and exists for this map - update
          Map.has_key?(system_params, "solar_system_id") &&
          Map.has_key?(existing_by_solar_id, system_params["solar_system_id"]) ->
            # Get the existing system ID, but use params directly for the update
            existing = Map.get(existing_by_solar_id, system_params["solar_system_id"])
            system_id = existing.id
            update_params = atomize_keys(system_params)
            updates = [{system_id, update_params} | updates]
            {creates, updates}

          # Case 3: New system with at least a solar_system_id - create
          Map.has_key?(system_params, "solar_system_id") ->
            system_params = Map.put(system_params, "map_id", map_id)
            creates = [atomize_keys(system_params) | creates]
            {creates, updates}

          # Case 4: Invalid system data - skip it
          true ->
            {creates, updates}
        end
      end)

    {:ok, {to_create, to_update}}
  end

  # Create multiple systems
  defp create_systems([]), do: {:ok, []}
  defp create_systems(systems_to_create) do
    MapSystemRepo.bulk_create(systems_to_create)
  end

  # Update multiple systems
  defp update_systems([]), do: {:ok, []}
  defp update_systems(systems_to_update) do
    # Create a list of {id, params} for bulk update
    updated_systems = Enum.map(systems_to_update, fn {system_id, update_params} ->
      case MapSystemRepo.update_by_id(system_id, update_params) do
        {:ok, updated} -> updated
        {:error, reason} ->
          IO.puts("Error updating system #{system_id}: #{inspect(reason)}")
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    {:ok, updated_systems}
  end

  # Extract system IDs from params
  defp extract_system_ids_from_params(%{"system_ids" => system_ids}) when is_list(system_ids), do: {:ok, system_ids}
  defp extract_system_ids_from_params(_), do: {:error, "Missing or invalid 'system_ids' parameter"}

  # Get systems by IDs for a specific map
  defp get_systems_by_ids(map_id, system_ids) do
    MapSystemRepo.get_all_by_map(map_id)
    |> case do
      {:ok, all_systems} ->
        systems = Enum.filter(all_systems, fn system -> system.id in system_ids end)
        {:ok, systems}

      error ->
        error
    end
  end

  # Get connections for specific systems (used in deletion)
  defp get_connections_for_systems(map_id, systems) do
    system_solar_ids = Enum.map(systems, & &1.solar_system_id)

    MapConnectionRepo.get_by_map(map_id)
    |> case do
      {:ok, all_connections} ->
        connections = Enum.filter(all_connections, fn connection ->
          connection.solar_system_source in system_solar_ids ||
          connection.solar_system_target in system_solar_ids
        end)

        {:ok, connections}

      error ->
        error
    end
  end

  # Delete connections for systems being deleted
  defp delete_connections_for_systems([]), do: {:ok, 0}
  defp delete_connections_for_systems(connections) do
    WandererApp.Api.MapConnection.destroy(connections)
    |> case do
      %Ash.BulkResult{status: :success} ->
        {:ok, length(connections)}

      %Ash.BulkResult{status: :error, errors: errors} ->
        {:error, errors}

      error ->
        {:error, error}
    end
  end

  # Bulk delete systems
  defp bulk_delete_systems([]), do: {:ok, 0}
  defp bulk_delete_systems(systems) do
    WandererApp.Api.MapSystem.destroy(systems)
    |> case do
      %Ash.BulkResult{status: :success} ->
        {:ok, length(systems)}

      %Ash.BulkResult{status: :error, errors: errors} ->
        {:error, errors}

      error ->
        {:error, error}
    end
  end

  defp map_system_to_json(system) do
    # Get the original system name from the database
    original_name = get_original_system_name(system.solar_system_id)

    # Start with the basic system data
    result = Map.take(system, [
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
    display_name = cond do
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

  defp get_original_system_name(solar_system_id) do
    # Fetch the original system name from the MapSolarSystem resource
    case WandererApp.Api.MapSolarSystem.by_solar_system_id(solar_system_id) do
      {:ok, system} ->
        system.solar_system_name
      _error ->
        "Unknown System"
    end
  end

  # Safer implementation of atomize_keys using a whitelist
  # Duplicated here and in MapAPIController for the combined endpoint
  defp atomize_keys(map) do
    allowed_keys = [
      :id, :solar_system_id, :position_x, :position_y,
      :status, :description, :map_id, :locked, :visible,
      :solar_system_source, :solar_system_target, :type,
      :name, :author_id, :author_eve_id, :category, :is_public, :source_map_id,
      :systems, :connections, :metadata
    ]

    # First normalize author_eve_id to author_id if present
    normalized_map = if Map.has_key?(map, "author_eve_id") do
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
      entry -> [entry]
    end)
    |> Map.new()
  end
end
