defmodule WandererAppWeb.MapSystemAPIController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.MapSystemRepo
  alias WandererAppWeb.UtilAPIController, as: Util
  alias WandererAppWeb.Schemas.{ApiSchemas, ResponseSchemas}
  alias OpenApiSpex.Schema

  action_fallback WandererAppWeb.FallbackController

  @map_system_schema %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string, description: "Unique identifier for the map system"},
      map_id: %Schema{type: :string, description: "Map ID this system belongs to"},
      solar_system_id: %Schema{type: :integer, description: "EVE solar system ID"},
      solar_system_name: %Schema{type: :string, description: "EVE solar system name"},
      region_name: %Schema{type: :string, description: "EVE region name"},
      position_x: %Schema{type: :number, format: :float, description: "X coordinate on the map"},
      position_y: %Schema{type: :number, format: :float, description: "Y coordinate on the map"},
      status: %Schema{type: :string, description: "System status"},
      visible: %Schema{type: :boolean, description: "Whether system is visible on the map"},
      description: %Schema{type: :string, description: "Custom description", nullable: true},
      tag: %Schema{type: :string, description: "Custom tag", nullable: true},
      locked: %Schema{type: :boolean, description: "Whether system is locked"},
      temporary_name: %Schema{type: :string, description: "Temporary system name", nullable: true},
      labels: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "System labels",
        nullable: true
      }
    },
    required: ["id", "map_id", "solar_system_id"]
  }

  @system_single_upsert_schema %Schema{
    type: :object,
    properties: %{
      solar_system_id: %Schema{type: :integer, description: "EVE solar system ID"},
      position_x: %Schema{type: :number, format: :float, description: "X coordinate on the map"},
      position_y: %Schema{type: :number, format: :float, description: "Y coordinate on the map"},
      status: %Schema{type: :string, description: "System status"},
      visible: %Schema{type: :boolean, description: "Whether system is visible on the map"},
      description: %Schema{type: :string, description: "Custom description", nullable: true},
      tag: %Schema{type: :string, description: "Custom tag", nullable: true},
      locked: %Schema{type: :boolean, description: "Whether system is locked"},
      temporary_name: %Schema{type: :string, description: "Temporary system name", nullable: true},
      labels: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "System labels",
        nullable: true
      }
    },
    required: ["solar_system_id"],
    example: %{
      "solar_system_id" => 30000142,
      "position_x" => 100.5,
      "position_y" => 200.3,
      "visible" => true
    }
  }

  @systems_list_response_schema ApiSchemas.data_wrapper(
    %Schema{
      type: :array,
      items: @map_system_schema
    }
  )

  @system_detail_response_schema ApiSchemas.data_wrapper(@map_system_schema)

  operation :index,
    summary: "List Map Systems",
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
      ok: ResponseSchemas.ok(@systems_list_response_schema, "List of visible map systems"),
      bad_request: ResponseSchemas.bad_request("Invalid map slug or ID"),
      not_found: ResponseSchemas.not_found("Map not found"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def index(conn, _), do: fetch_systems(conn)

  operation :show,
    summary: "Show Map System",
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
      id: [
        in: :path,
        description: "System ID or solar system ID",
        type: :string,
        required: true,
        example: "30000142"
      ]
    ],
    responses: [
      ok: ResponseSchemas.ok(@system_detail_response_schema, "Map system details"),
      not_found: ResponseSchemas.not_found("System not found in this map"),
      bad_request: ResponseSchemas.bad_request("Invalid map slug or ID"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def show(conn, %{"id" => id}), do: fetch_system(conn, id)

  operation :create,
    summary: "Create System",
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
    request_body: {"System create request", "application/json", @system_single_upsert_schema},
    responses: [
      created: ResponseSchemas.created(@system_detail_response_schema, "System created successfully"),
      bad_request: ResponseSchemas.bad_request("Invalid map slug/ID or system data"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def create(conn, _), do: create_system(conn)

  operation :update,
    summary: "Update System",
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
      id: [
        in: :path,
        description: "System ID or solar system ID",
        type: :string,
        required: true,
        example: "30000142"
      ]
    ],
    request_body: {"System update request", "application/json", @system_single_upsert_schema},
    responses: [
      ok: ResponseSchemas.ok(@system_detail_response_schema, "System updated successfully"),
      not_found: ResponseSchemas.not_found("System not found"),
      bad_request: ResponseSchemas.bad_request("Invalid map slug/ID or system data"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def update(conn, %{"id" => id}), do: update_system(conn, id)

  operation :delete,
    summary: "Delete System",
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
      id: [
        in: :path,
        description: "System ID or solar system ID",
        type: :string,
        required: true,
        example: "30000142"
      ]
    ],
    responses: [
      ok: ResponseSchemas.ok(
        ApiSchemas.data_wrapper(
          %Schema{
            type: :object,
            properties: %{
              connections_deleted_count: %Schema{type: :integer, description: "Number of connections deleted"},
              deleted_count: %Schema{type: :integer, description: "Number of systems deleted"}
            },
            required: ["connections_deleted_count", "deleted_count"]
          }
        ),
        "System and associated connections deleted"
      ),
      not_found: ResponseSchemas.not_found("System not found"),
      bad_request: ResponseSchemas.bad_request("Invalid map slug/ID or system ID"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def delete(conn, %{"id" => id}), do: delete_system(conn, id)

  @systems_and_connections_request_schema %Schema{
    type: :object,
    properties: %{
      systems: %Schema{
        type: :array,
        items: @system_single_upsert_schema,
        description: "List of systems to create or update"
      },
      connections: %Schema{
        type: :array,
        items: %Schema{
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
          required: ["solar_system_source", "solar_system_target"]
        },
        description: "List of connections to create or update"
      }
    },
    required: ["systems"]
  }

  operation :systems_and_connections,
    summary: "Batch Upsert Systems+Connections",
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
    request_body: {"Systems and connections batch upsert", "application/json", @systems_and_connections_request_schema},
    responses: [
      ok: ResponseSchemas.ok(
        ApiSchemas.data_wrapper(
          %Schema{
            type: :object,
            properties: %{
              systems: %Schema{
                type: :object,
                properties: %{
                  created: %Schema{type: :integer},
                  updated: %Schema{type: :integer}
                },
                required: ["created", "updated"]
              },
              connections: %Schema{
                type: :object,
                properties: %{
                  created: %Schema{type: :integer},
                  updated: %Schema{type: :integer},
                  deleted: %Schema{type: :integer}
                },
                required: ["created", "updated", "deleted"]
              }
            },
            required: ["systems", "connections"]
          }
        ),
        "Batch upsert results"
      ),
      bad_request: ResponseSchemas.bad_request("Invalid map slug/ID or systems/connections data"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def systems_and_connections(conn, _), do: upsert_systems_and_connections(conn)

  operation :list_systems,
    summary: "List Map Systems",
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
      ok: ResponseSchemas.ok(@systems_list_response_schema, "List of map systems"),
      bad_request: ResponseSchemas.bad_request("Invalid map slug or ID"),
      not_found: ResponseSchemas.not_found("Map not found"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def list_systems(conn, _params) do
    systems = WandererApp.Map.list_systems!(conn.assigns.map_id)
    json(conn, %{data: Enum.map(systems, &Util.map_system_to_json/1)})
  end

  operation :show_system,
    summary: "Show Map System",
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
      id: [
        in: :query,
        description: "System ID or solar system ID",
        type: :string,
        required: true,
        example: "30000142"
      ]
    ],
    responses: [
      ok: ResponseSchemas.ok(@system_detail_response_schema, "Map system details"),
      not_found: ResponseSchemas.not_found("System not found in this map"),
      bad_request: ResponseSchemas.bad_request("Invalid map slug or ID"),
      internal_server_error: ResponseSchemas.internal_server_error()
    ]
  def show_system(conn, %{"id" => id}) do
    case Util.parse_int(id) do
      {:ok, system_id} ->
        system = WandererApp.Map.find_system_by_location(conn.assigns.map_id, %{solar_system_id: system_id})
        if system do
          json(conn, %{data: Util.map_system_to_json(system)})
        else
          Util.error_not_found(conn, "System not found")
        end
      {:error, _} ->
        Util.error_not_found(conn, "Invalid system ID")
    end
  end

  # -- Helpers --
  defp fetch_systems(conn) do
    systems = WandererApp.Map.list_systems!(conn.assigns.map_id)
    json(conn, %{data: Enum.map(systems, &Util.map_system_to_json/1)})
  end

  defp fetch_system(conn, id) do
    case Util.parse_int(id) do
      {:ok, system_id} ->
        system = WandererApp.Map.find_system_by_location(conn.assigns.map_id, %{solar_system_id: system_id})
        if system do
          json(conn, %{data: Util.map_system_to_json(system)})
        else
          Util.error_not_found(conn, "System not found")
        end
      {:error, _} ->
        Util.error_not_found(conn, "Invalid system ID")
    end
  end

  defp create_system(conn) do
    params = Map.put(conn.body_params, "map_id", conn.assigns.map_id)
    map_id = conn.assigns.map_id

    # Extract required parameters
    solar_system_id = params["solar_system_id"]

    # Create coordinates if provided
    coordinates = if Map.has_key?(params, "position_x") && Map.has_key?(params, "position_y") do
      %{"x" => params["position_x"], "y" => params["position_y"]}
    else
      nil # Let the server calculate position
    end

    # Get the character ID from map owner
    case WandererApp.MapTemplateRepo.get_owner_character_id(map_id) do
      {:ok, character_id} ->
        # Create system_info struct for server call
        system_info = %{
          solar_system_id: solar_system_id,
          coordinates: coordinates
        }

        # Call the proper Map.Server add_system implementation
        WandererApp.Map.Server.add_system(map_id, system_info, character_id, nil)

        # Fetch the system to return in the response
        system = WandererApp.Map.find_system_by_location(map_id, %{solar_system_id: solar_system_id})

        if system do
          conn |> put_status(:created) |> json(%{data: Util.map_system_to_json(system)})
        else
          Util.standardized_error_response(conn, :internal_server_error, "System created but could not be retrieved")
        end

      _ ->
        Util.standardized_error_response(
          conn,
          :internal_server_error,
          "Could not determine map owner for system creation"
        )
    end
  end

  defp update_system(conn, id) do
    case Util.parse_int(id) do
      {:ok, solar_system_id} ->
        map_id = conn.assigns.map_id
        system = WandererApp.Map.find_system_by_location(map_id, %{solar_system_id: solar_system_id})

        if system do
          attrs = conn.body_params

          # Update relevant fields
          # Name updates
          if Map.has_key?(attrs, "name") do
            WandererApp.Map.Server.update_system_name(map_id, %{
              solar_system_id: solar_system_id,
              name: attrs["name"]
            })
          end

          # Description updates
          if Map.has_key?(attrs, "description") do
            WandererApp.Map.Server.update_system_description(map_id, %{
              solar_system_id: solar_system_id,
              description: attrs["description"]
            })
          end

          # Status updates
          if Map.has_key?(attrs, "status") do
            WandererApp.Map.Server.update_system_status(map_id, %{
              solar_system_id: solar_system_id,
              status: attrs["status"]
            })
          end

          # Tag updates
          if Map.has_key?(attrs, "tag") do
            WandererApp.Map.Server.update_system_tag(map_id, %{
              solar_system_id: solar_system_id,
              tag: attrs["tag"]
            })
          end

          # Labels updates
          if Map.has_key?(attrs, "labels") do
            WandererApp.Map.Server.update_system_labels(map_id, %{
              solar_system_id: solar_system_id,
              labels: attrs["labels"]
            })
          end

          # Temporary name updates
          if Map.has_key?(attrs, "temporary_name") do
            WandererApp.Map.Server.update_system_temporary_name(map_id, %{
              solar_system_id: solar_system_id,
              temporary_name: attrs["temporary_name"]
            })
          end

          # Return the updated system
          updated_system = WandererApp.Map.find_system_by_location(map_id, %{solar_system_id: solar_system_id})
          json(conn, %{data: Util.map_system_to_json(updated_system)})
        else
          Util.error_not_found(conn, "System not found")
        end

      {:error, _} ->
        Util.standardized_error_response(conn, :bad_request, "Invalid system ID")
    end
  end

  defp delete_system(conn, id) do
    case Util.parse_int(id) do
      {:ok, solar_system_id} ->
        map_id = conn.assigns.map_id
        system = WandererApp.Map.find_system_by_location(map_id, %{solar_system_id: solar_system_id})

        if system do
          # Get the character ID from map owner
          case WandererApp.MapTemplateRepo.get_owner_character_id(map_id) do
            {:ok, character_id} ->
              # Get connections for the system to count deletions
              connections = WandererApp.Map.list_connections!(map_id)
              system_connections = Enum.filter(connections, fn c ->
                c.solar_system_source == solar_system_id || c.solar_system_target == solar_system_id
              end)

              # Delete the system
              WandererApp.Map.Server.delete_systems(map_id, [solar_system_id], character_id, nil)

              # Return success response
              json(conn, %{data: %{
                connections_deleted_count: length(system_connections),
                deleted_count: 1
              }})

            _ ->
              Util.standardized_error_response(
                conn,
                :internal_server_error,
                "Could not determine map owner for system deletion"
              )
          end
        else
          Util.error_not_found(conn, "System not found")
        end

      {:error, _} ->
        Util.standardized_error_response(conn, :bad_request, "Invalid system ID")
    end
  end

  defp upsert_systems_and_connections(conn) do
    params = conn.body_params
    map_id = conn.assigns.map_id
    systems = params["systems"] || []
    connections = params["connections"] || []

    # Check if we can get the owner ID (needed for system and connection processing)
    owner_id_result = WandererApp.MapTemplateRepo.get_owner_character_id(map_id)

    case owner_id_result do
      {:error, _} ->
        Util.standardized_error_response(
          conn,
          :internal_server_error,
          "Could not determine map owner for system/connection operations"
        )

      _ ->
        # Process systems
        {created_systems, updated_systems} = process_systems(map_id, systems)

        # Process connections
        {created_connections, updated_connections} = process_connections(map_id, connections)

        # If systems were provided but none were created/updated due to owner ID error,
        # or if connections were provided but none were created/updated due to owner ID error
        if (length(systems) > 0 and length(created_systems) == 0 and length(updated_systems) == 0)
           or (length(connections) > 0 and length(created_connections) == 0 and length(updated_connections) == 0) do
          Util.standardized_error_response(
            conn,
            :internal_server_error,
            "Failed to process systems/connections due to owner ID retrieval issues"
          )
        else
          # Calculate connections that might have been deleted
          # In this implementation, we're not supporting automatic deletion
          # of stale connections through the batch upsert operation
          deleted_connections = 0

          # Return the response
          json(conn, %{data: %{
            systems: %{
              created: length(created_systems),
              updated: length(updated_systems)
            },
            connections: %{
              created: length(created_connections),
              updated: length(updated_connections),
              deleted: deleted_connections
            }
          }})
        end
    end
  end

  # Helper functions for processing systems and connections
  defp process_systems(map_id, systems) do
    # Get the character ID from map owner
    character_id_result = WandererApp.MapTemplateRepo.get_owner_character_id(map_id)

    case character_id_result do
      {:ok, character_id} ->
        # We have a valid owner ID, proceed with systems
        Enum.reduce(systems, {[], []}, fn system, {created, updated} ->
          solar_system_id = system["solar_system_id"]

          # Check if system already exists
          existing = WandererApp.Map.find_system_by_location(map_id, %{solar_system_id: solar_system_id})

          if existing do
            # Update existing system with provided attributes

            # Update position if provided
            if Map.has_key?(system, "position_x") && Map.has_key?(system, "position_y") do
              WandererApp.Map.Server.update_system_position(map_id, %{
                solar_system_id: solar_system_id,
                coordinates: %{
                  "x" => system["position_x"],
                  "y" => system["position_y"]
                }
              })
            end

            # Update status if provided
            if Map.has_key?(system, "status") do
              WandererApp.Map.Server.update_system_status(map_id, %{
                solar_system_id: solar_system_id,
                status: system["status"]
              })
            end

            # Update visibility if provided
            if Map.has_key?(system, "visible") do
              WandererApp.Map.Server.update_system_visibility(map_id, %{
                solar_system_id: solar_system_id,
                visible: system["visible"]
              })
            end

            # Update description if provided
            if Map.has_key?(system, "description") do
              WandererApp.Map.Server.update_system_description(map_id, %{
                solar_system_id: solar_system_id,
                description: system["description"]
              })
            end

            # Update tag if provided
            if Map.has_key?(system, "tag") do
              WandererApp.Map.Server.update_system_tag(map_id, %{
                solar_system_id: solar_system_id,
                tag: system["tag"]
              })
            end

            # Update locked status if provided
            if Map.has_key?(system, "locked") do
              WandererApp.Map.Server.update_system_locked(map_id, %{
                solar_system_id: solar_system_id,
                locked: system["locked"]
              })
            end

            # Update temporary name if provided
            if Map.has_key?(system, "temporary_name") do
              WandererApp.Map.Server.update_system_temporary_name(map_id, %{
                solar_system_id: solar_system_id,
                temporary_name: system["temporary_name"]
              })
            end

            # Update labels if provided
            if Map.has_key?(system, "labels") do
              WandererApp.Map.Server.update_system_labels(map_id, %{
                solar_system_id: solar_system_id,
                labels: system["labels"]
              })
            end

            {created, [system | updated]}
          else
            # Create new system
            coordinates = if Map.has_key?(system, "position_x") && Map.has_key?(system, "position_y") do
              %{"x" => system["position_x"], "y" => system["position_y"]}
            else
              nil
            end

            system_info = %{
              solar_system_id: solar_system_id,
              coordinates: coordinates
            }

            WandererApp.Map.Server.add_system(map_id, system_info, character_id, nil)
            {[system | created], updated}
          end
        end)

      _ ->
        # If we can't get owner ID, return empty lists to indicate no systems processed
        {[], []}
    end
  end

  defp process_connections(map_id, connections) do
    # First check if we can get a valid owner ID
    case WandererApp.MapTemplateRepo.get_owner_character_id(map_id) do
      {:ok, character_id} ->
        # We have a valid owner ID, proceed with connections
        Enum.reduce(connections, {[], []}, fn connection, {created, updated} ->
          source_id = connection["solar_system_source"]
          target_id = connection["solar_system_target"]

          # Create connection info
          connection_info = %{
            solar_system_source_id: source_id,
            solar_system_target_id: target_id,
            character_id: character_id,
            type: Map.get(connection, "type", 0)
          }

          # Call the Map.Server add_connection implementation
          WandererApp.Map.Server.add_connection(map_id, connection_info)
          {[connection | created], updated}
        end)

      _ ->
        # If we can't get owner ID, return empty lists to indicate no connections processed
        {[], []}
    end
  end
end
