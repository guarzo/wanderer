defmodule WandererAppWeb.MapConnectionAPIController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.MapConnectionRepo
  alias WandererAppWeb.UtilAPIController, as: Util
  alias WandererAppWeb.Schemas.{ApiSchemas, ResponseSchemas}
  alias OpenApiSpex.Schema

  action_fallback WandererAppWeb.FallbackController

  @map_connection_schema %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string, description: "Unique identifier for the connection"},
      map_id: %Schema{type: :string, description: "Map ID this connection belongs to"},
      solar_system_source: %Schema{type: :integer, description: "Source solar system ID"},
      solar_system_target: %Schema{type: :integer, description: "Target solar system ID"},
      type: %Schema{type: :integer, description: "Connection type ID"},
      mass_status: %Schema{type: :integer, description: "Mass status (0-3)"},
      time_status: %Schema{type: :integer, description: "Time status (0-3)"},
      ship_size_type: %Schema{type: :integer, description: "Ship size limitation (0-3)"},
      locked: %Schema{type: :boolean, description: "Whether connection is locked"},
      custom_info: %Schema{type: :string, description: "Custom information", nullable: true},
      wormhole_type: %Schema{type: :string, description: "Wormhole type code", nullable: true}
    },
    required: ["id", "map_id", "solar_system_source", "solar_system_target"]
  }

  @connection_single_upsert_schema %Schema{
    type: :object,
    properties: %{
      solar_system_source: %Schema{type: :integer, description: "Source solar system ID"},
      solar_system_target: %Schema{type: :integer, description: "Target solar system ID"},
      type: %Schema{type: :integer, description: "Connection type ID"},
      mass_status: %Schema{type: :integer, description: "Mass status (0-3)"},
      time_status: %Schema{type: :integer, description: "Time status (0-3)"},
      ship_size_type: %Schema{type: :integer, description: "Ship size limitation (0-3)"},
      locked: %Schema{type: :boolean, description: "Whether connection is locked"},
      custom_info: %Schema{type: :string, description: "Custom information", nullable: true},
      wormhole_type: %Schema{type: :string, description: "Wormhole type code", nullable: true}
    },
    required: ["solar_system_source", "solar_system_target"],
    example: %{
      "solar_system_source" => 30000142,
      "solar_system_target" => 30000144,
      "type" => 0
    }
  }

  @connection_batch_delete_schema %Schema{
    type: :object,
    properties: %{
      connection_ids: %Schema{
        type: :array,
        items: %Schema{type: :string, description: "Connection ID to delete"},
        description: "List of connection IDs to delete"
      }
    },
    required: ["connection_ids"]
  }

  @connections_list_response_schema ApiSchemas.data_wrapper(
    %Schema{
      type: :array,
      items: @map_connection_schema
    }
  )

  @connection_detail_response_schema ApiSchemas.data_wrapper(@map_connection_schema)

  operation :index,
    summary: "List Map Connections",
    parameters: [
      map_slug: [
        in: :path,
        description: "Map slug",
        type: :string,
        required: false,
        example: "my-awesome-map"
      ],
      map_id: [
        in: :path,
        description: "Map identifier (UUID)",
        type: :string,
        required: false,
        example: "466e922b-e758-485e-9b86-afae06b88363"
      ],
      system_id: [
        in: :path,
        description: "System ID",
        type: :string,
        required: true,
        example: "30000142"
      ]
    ],
    responses: [
      ok: ResponseSchemas.ok(@connections_list_response_schema, "List of connections for the system"),
      bad_request: ResponseSchemas.bad_request("Invalid map or system ID"),
      not_found: ResponseSchemas.not_found("System not found"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def index(conn, %{"system_id" => sid}) do
    # Get all connections
    all_connections = WandererApp.Map.list_connections!(conn.assigns.map_id)

    # Filter connections related to the specified system
    case Util.parse_int(sid) do
      {:ok, system_id} ->
        connections = Enum.filter(all_connections, fn conn ->
          conn.solar_system_source == system_id || conn.solar_system_target == system_id
        end)
        json(conn, %{data: Enum.map(connections, &Util.connection_to_json/1)})

      {:error, _} ->
        Util.standardized_error_response(conn, :bad_request, "Invalid system ID")
    end
  end

  operation :show,
    summary: "Show Connection",
    parameters: [
      map_slug: [
        in: :path,
        description: "Map slug",
        type: :string,
        required: false,
        example: "my-awesome-map"
      ],
      map_id: [
        in: :path,
        description: "Map identifier (UUID)",
        type: :string,
        required: false,
        example: "466e922b-e758-485e-9b86-afae06b88363"
      ],
      system_id: [
        in: :path,
        description: "System ID",
        type: :string,
        required: true,
        example: "30000142"
      ],
      id: [
        in: :path,
        description: "Connection ID",
        type: :string,
        required: true,
        example: "abcdef-12345-67890"
      ]
    ],
    responses: [
      ok: ResponseSchemas.ok(@connection_detail_response_schema, "Connection details"),
      not_found: ResponseSchemas.not_found("Connection not found"),
      bad_request: ResponseSchemas.bad_request("Invalid map, system, or connection ID"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def show(conn, %{"system_id" => sid, "id" => id}) do
    map_id = conn.assigns.map_id

    # Get all connections
    connections = WandererApp.Map.list_connections!(map_id)

    # Find the specific connection by ID
    connection = Enum.find(connections, fn c -> c.id == id end)

    if connection do
      # Check if connection is related to the specified system
      case Util.parse_int(sid) do
        {:ok, system_id} ->
          if connection.solar_system_source == system_id || connection.solar_system_target == system_id do
            json(conn, %{data: Util.connection_to_json(connection)})
          else
            Util.error_not_found(conn, "Connection not associated with the specified system")
          end

        {:error, _} ->
          Util.standardized_error_response(conn, :bad_request, "Invalid system ID")
      end
    else
      Util.error_not_found(conn, "Connection not found")
    end
  end

  operation :create,
    summary: "Create Connection",
    parameters: [
      map_slug: [
        in: :path,
        description: "Map slug",
        type: :string,
        required: false,
        example: "my-awesome-map"
      ],
      map_id: [
        in: :path,
        description: "Map identifier (UUID)",
        type: :string,
        required: false,
        example: "466e922b-e758-485e-9b86-afae06b88363"
      ],
      system_id: [
        in: :path,
        description: "System ID",
        type: :string,
        required: true,
        example: "30000142"
      ]
    ],
    request_body: {"Connection create request", "application/json", @connection_single_upsert_schema},
    responses: [
      created: ResponseSchemas.created(@connection_detail_response_schema, "Connection created"),
      bad_request: ResponseSchemas.bad_request("Invalid map identifier or connection data"),
      not_found: ResponseSchemas.not_found("Source or target system not found"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def create(conn, %{"system_id" => sid}) do
    map_id = conn.assigns.map_id
    attrs = conn.body_params

    # Verify that the connection involves the specified system
    case Util.parse_int(sid) do
      {:ok, system_id} ->
        source_id = attrs["solar_system_source"]
        target_id = attrs["solar_system_target"]

        # Check if either source or target is the specified system
        if source_id == system_id || target_id == system_id do
          # Get character ID from map owner
          case WandererApp.MapTemplateRepo.get_owner_character_id(map_id) do
            {:ok, character_id} ->
              # Create connection info
              connection_info = %{
                solar_system_source_id: source_id,
                solar_system_target_id: target_id,
                character_id: character_id,
                type: Map.get(attrs, "type", 0)
              }

              # Add connection
              WandererApp.Map.Server.add_connection(map_id, connection_info)

              # Fetch connections to find the one we just created
              connections = WandererApp.Map.list_connections!(map_id)
              connection = Enum.find(connections, fn c ->
                c.solar_system_source == source_id && c.solar_system_target == target_id
              end)

              if connection do
                conn |> put_status(:created) |> json(%{data: Util.connection_to_json(connection)})
              else
                Util.standardized_error_response(
                  conn,
                  :internal_server_error,
                  "Connection created but could not be retrieved"
                )
              end

            _ ->
              Util.standardized_error_response(
                conn,
                :internal_server_error,
                "Could not determine map owner for connection creation"
              )
          end
        else
          Util.standardized_error_response(
            conn,
            :bad_request,
            "Connection must involve the specified system"
          )
        end

      {:error, _} ->
        Util.standardized_error_response(conn, :bad_request, "Invalid system ID")
    end
  end

  operation :delete,
    summary: "Delete Connection",
    parameters: [
      map_slug: [
        in: :path,
        description: "Map slug",
        type: :string,
        required: false,
        example: "my-awesome-map"
      ],
      map_id: [
        in: :path,
        description: "Map identifier (UUID)",
        type: :string,
        required: false,
        example: "466e922b-e758-485e-9b86-afae06b88363"
      ],
      system_id: [
        in: :path,
        description: "System ID",
        type: :string,
        required: true,
        example: "30000142"
      ],
      id: [
        in: :path,
        description: "Connection ID",
        type: :string,
        required: true,
        example: "abcdef-12345-67890"
      ]
    ],
    responses: [
      no_content: {"Connection deleted", nil, nil},
      not_found: ResponseSchemas.not_found("Connection not found"),
      bad_request: ResponseSchemas.bad_request("Invalid map, system, or connection ID"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def delete(conn, %{"system_id" => sid, "id" => id}) do
    map_id = conn.assigns.map_id

    # Get all connections
    connections = WandererApp.Map.list_connections!(map_id)

    # Find the specific connection
    connection = Enum.find(connections, fn c -> c.id == id end)

    if connection do
      case Util.parse_int(sid) do
        {:ok, system_id} ->
          # Check if connection involves the specified system
          if connection.solar_system_source == system_id || connection.solar_system_target == system_id do
            # Get character ID from map owner
            case WandererApp.MapTemplateRepo.get_owner_character_id(map_id) do
              {:ok, _} ->
                # Delete the connection
                WandererApp.Map.Server.delete_connection(map_id, %{
                  solar_system_source_id: connection.solar_system_source,
                  solar_system_target_id: connection.solar_system_target
                })

                send_resp(conn, :no_content, "")

              _ ->
                Util.standardized_error_response(
                  conn,
                  :internal_server_error,
                  "Could not determine map owner for connection deletion"
                )
            end
          else
            Util.error_not_found(conn, "Connection not associated with the specified system")
          end

        {:error, _} ->
          Util.standardized_error_response(conn, :bad_request, "Invalid system ID")
      end
    else
      Util.error_not_found(conn, "Connection not found")
    end
  end

  operation :batch_delete,
    summary: "Batch Delete Connections",
    parameters: [
      map_slug: [
        in: :path,
        description: "Map slug",
        type: :string,
        required: false,
        example: "my-awesome-map"
      ],
      map_id: [
        in: :path,
        description: "Map identifier (UUID)",
        type: :string,
        required: false,
        example: "466e922b-e758-485e-9b86-afae06b88363"
      ]
    ],
    request_body: {"Connection batch delete request", "application/json", @connection_batch_delete_schema},
    responses: [
      ok: ResponseSchemas.ok(
        ApiSchemas.data_wrapper(
          %Schema{
            type: :object,
            properties: %{
              deleted_count: %Schema{type: :integer, description: "Number of connections deleted"}
            },
            required: ["deleted_count"]
          }
        ),
        "Connections deleted"
      ),
      bad_request: ResponseSchemas.bad_request("Invalid map identifier or connection IDs"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def batch_delete(conn, params) do
    map_id = conn.assigns.map_id

    # Check if connection_ids key is present and is a list
    case params do
      %{"connection_ids" => ids} when is_list(ids) ->
        # Get all connections
        connections = WandererApp.Map.list_connections!(map_id)

        # Filter to only requested connections that exist on this map
        connections_to_delete = Enum.filter(connections, fn c -> c.id in ids end)

        if Enum.empty?(connections_to_delete) do
          # No connections matched the provided IDs for this map
          json(conn, %{data: %{deleted_count: 0, message: "No matching connections found to delete"}})
        else
          # Check for owner ID first
          case WandererApp.MapTemplateRepo.get_owner_character_id(map_id) do
            {:ok, _character_id} ->
              # Delete each connection
              deleted_count = Enum.reduce(connections_to_delete, 0, fn connection, count ->
                WandererApp.Map.Server.delete_connection(map_id, %{
                  solar_system_source_id: connection.solar_system_source,
                  solar_system_target_id: connection.solar_system_target
                })
                count + 1
              end)

              # Return success response
              json(conn, %{data: %{deleted_count: deleted_count}})

            _ ->
              Util.standardized_error_response(
                conn,
                :internal_server_error,
                "Could not determine map owner for connection deletion"
              )
          end
        end

      %{"connection_ids" => _} ->
        Util.standardized_error_response(conn, :bad_request, "connection_ids must be a list")

      _ ->
        Util.standardized_error_response(conn, :bad_request, "connection_ids parameter is required")
    end
  end

  operation :list_all_connections,
    summary: "List All Map Connections",
    parameters: [
      map_slug: [
        in: :path,
        description: "Map slug",
        type: :string,
        required: false,
        example: "my-awesome-map"
      ],
      map_id: [
        in: :path,
        description: "Map identifier (UUID)",
        type: :string,
        required: false,
        example: "466e922b-e758-485e-9b86-afae06b88363"
      ]
    ],
    responses: [
      ok: ResponseSchemas.ok(@connections_list_response_schema, "List of all map connections"),
      bad_request: ResponseSchemas.bad_request("Invalid map ID"),
      not_found: ResponseSchemas.not_found("Map not found"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def list_all_connections(conn, _params) do
    # Get all connections for the map
    connections = WandererApp.Map.list_connections!(conn.assigns.map_id)
    json(conn, %{data: Enum.map(connections, &Util.connection_to_json/1)})
  end
end
