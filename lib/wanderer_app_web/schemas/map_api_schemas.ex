defmodule WandererAppWeb.Schemas.MapApiSchemas do
  @moduledoc """
  OpenAPI schema definitions for the Map API controllers.

  This module centralizes schema definitions to reduce duplication and keep
  controller files focused on routing and action handling.
  """

  @doc """
  Schema for a map system resource
  """
  def map_system_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        id: %OpenApiSpex.Schema{type: :string},
        map_id: %OpenApiSpex.Schema{type: :string},
        solar_system_id: %OpenApiSpex.Schema{type: :integer},
        original_name: %OpenApiSpex.Schema{type: :string},
        name: %OpenApiSpex.Schema{type: :string},
        custom_name: %OpenApiSpex.Schema{type: :string},
        temporary_name: %OpenApiSpex.Schema{type: :string},
        description: %OpenApiSpex.Schema{type: :string},
        tag: %OpenApiSpex.Schema{type: :string},
        labels: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string}},
        locked: %OpenApiSpex.Schema{type: :boolean},
        visible: %OpenApiSpex.Schema{type: :boolean},
        status: %OpenApiSpex.Schema{type: :string},
        position_x: %OpenApiSpex.Schema{type: :integer},
        position_y: %OpenApiSpex.Schema{type: :integer},
        inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
        updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time}
      },
      required: ["id", "solar_system_id", "original_name", "name"]
    }
  end

  @doc """
  Response schema for listing map systems
  """
  def list_map_systems_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :array,
          items: map_system_schema()
        }
      },
      required: ["data"]
    }
  end

  @doc """
  Response schema for showing a single map system
  """
  def show_map_system_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: map_system_schema()
      },
      required: ["data"]
    }
  end

  @doc """
  Request schema for upserting systems
  """
  def upsert_systems_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        systems: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{
            type: :object,
            properties: %{
              id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "System ID (optional for new systems)"},
              solar_system_id: %OpenApiSpex.Schema{type: :integer, description: "EVE Solar System ID"},
              name: %OpenApiSpex.Schema{type: :string, description: "System name"},
              custom_name: %OpenApiSpex.Schema{type: :string, description: "Custom name"},
              description: %OpenApiSpex.Schema{type: :string, description: "System description"},
              tag: %OpenApiSpex.Schema{type: :string, description: "System tag"},
              temporary_name: %OpenApiSpex.Schema{type: :string, description: "Temporary name"},
              labels: %OpenApiSpex.Schema{type: :string, description: "System labels JSON string"},
              status: %OpenApiSpex.Schema{type: :integer, description: "System status code: 0=Unknown, 1=Friendly, 2=Warning, 3=TargetPrimary, 4=TargetSecondary, 5=DangerousPrimary, 6=DangerousSecondary, 7=LookingFor, 8=Home"},
              position_x: %OpenApiSpex.Schema{type: :integer, description: "X position on the map canvas"},
              position_y: %OpenApiSpex.Schema{type: :integer, description: "Y position on the map canvas"},
              locked: %OpenApiSpex.Schema{type: :boolean, description: "Is system locked"},
              visible: %OpenApiSpex.Schema{type: :boolean, description: "Is system visible"}
            },
            required: ["solar_system_id"]
          }
        }
      },
      required: ["systems"]
    }
  end

  @doc """
  Response schema for upserting systems
  """
  def upsert_systems_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            created: %OpenApiSpex.Schema{
              type: :array,
              items: map_system_schema()
            },
            updated: %OpenApiSpex.Schema{
              type: :array,
              items: map_system_schema()
            }
          }
        }
      }
    }
  end

  @doc """
  Request schema for deleting systems
  """
  def delete_systems_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        system_ids: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{type: :string, format: :uuid},
          description: "List of system IDs to delete"
        }
      },
      required: ["system_ids"]
    }
  end

  @doc """
  Response schema for deleting systems
  """
  def delete_systems_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            deleted_count: %OpenApiSpex.Schema{type: :integer, description: "Number of systems deleted"},
            deleted_connections_count: %OpenApiSpex.Schema{type: :integer, description: "Number of orphaned connections deleted"}
          }
        }
      }
    }
  end

  @doc """
  Schema for a map connection
  """
  def map_connection_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        id: %OpenApiSpex.Schema{type: :string},
        map_id: %OpenApiSpex.Schema{type: :string},
        solar_system_source: %OpenApiSpex.Schema{type: :integer},
        solar_system_target: %OpenApiSpex.Schema{type: :integer},
        type: %OpenApiSpex.Schema{type: :string},
        mass_status: %OpenApiSpex.Schema{type: :integer},
        time_status: %OpenApiSpex.Schema{type: :integer},
        ship_size_type: %OpenApiSpex.Schema{type: :integer},
        wormhole_type: %OpenApiSpex.Schema{type: :string},
        count_of_passage: %OpenApiSpex.Schema{type: :integer},
        locked: %OpenApiSpex.Schema{type: :boolean},
        custom_info: %OpenApiSpex.Schema{type: :string},
        inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
        updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time}
      },
      required: ["id", "map_id", "solar_system_source", "solar_system_target"]
    }
  end

  @doc """
  Response schema for listing map connections
  """
  def list_map_connections_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :array,
          items: map_connection_schema()
        }
      },
      required: ["data"]
    }
  end

  @doc """
  Request schema for upserting connections
  """
  def upsert_connections_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        connections: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{
            type: :object,
            properties: %{
              id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Connection ID (optional for new connections)"},
              solar_system_source: %OpenApiSpex.Schema{type: :integer, description: "Source solar system ID"},
              solar_system_target: %OpenApiSpex.Schema{type: :integer, description: "Target solar system ID"},
              type: %OpenApiSpex.Schema{type: :integer, description: "Connection type (0=wormhole, 1=gate)"},
              mass_status: %OpenApiSpex.Schema{type: :integer, description: "Mass status (0=normal, 1=reduced, 2=critical)"},
              time_status: %OpenApiSpex.Schema{type: :integer, description: "Time status (0=normal, 1=EOL)"},
              ship_size_type: %OpenApiSpex.Schema{type: :integer, description: "Ship size type (0=frigate, 1=medium, 2=large, 3=freight, 4=capital)"},
              wormhole_type: %OpenApiSpex.Schema{type: :string, description: "Wormhole type (e.g., 'K162')"},
              count_of_passage: %OpenApiSpex.Schema{type: :integer, description: "Count of passages through this connection"},
              locked: %OpenApiSpex.Schema{type: :boolean, description: "Whether the connection is locked"},
              custom_info: %OpenApiSpex.Schema{type: :string, description: "Custom information about the connection"}
            },
            required: ["solar_system_source", "solar_system_target"]
          }
        }
      },
      required: ["connections"]
    }
  end

  @doc """
  Response schema for upserting connections
  """
  def upsert_connections_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            created: %OpenApiSpex.Schema{
              type: :array,
              items: map_connection_schema()
            },
            updated: %OpenApiSpex.Schema{
              type: :array,
              items: map_connection_schema()
            }
          }
        }
      }
    }
  end

  @doc """
  Request schema for deleting connections
  """
  def delete_connections_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        connection_ids: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{type: :string, format: :uuid},
          description: "List of connection IDs to delete"
        }
      },
      required: ["connection_ids"]
    }
  end

  @doc """
  Response schema for deleting connections
  """
  def delete_connections_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            deleted_count: %OpenApiSpex.Schema{type: :integer, description: "Number of connections deleted"}
          }
        }
      }
    }
  end

  @doc """
  Request schema for upserting systems and connections together
  """
  def upsert_systems_and_connections_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        systems: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{
            type: :object,
            properties: %{
              id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "System ID (optional for new systems)"},
              solar_system_id: %OpenApiSpex.Schema{type: :integer, description: "EVE Solar System ID"},
              # Other system properties as in upsert_systems_request_schema
            }
          }
        },
        connections: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{
            type: :object,
            properties: %{
              id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Connection ID (optional for new connections)"},
              solar_system_source: %OpenApiSpex.Schema{type: :integer, description: "Source solar system ID"},
              solar_system_target: %OpenApiSpex.Schema{type: :integer, description: "Target solar system ID"},
              # Other connection properties as in upsert_connections_request_schema
            }
          }
        }
      }
    }
  end

  @doc """
  Response schema for upserting systems and connections together
  """
  def upsert_systems_and_connections_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            systems: %OpenApiSpex.Schema{
              type: :object,
              properties: %{
                created: %OpenApiSpex.Schema{type: :array, items: map_system_schema()},
                updated: %OpenApiSpex.Schema{type: :array, items: map_system_schema()}
              }
            },
            connections: %OpenApiSpex.Schema{
              type: :object,
              properties: %{
                created: %OpenApiSpex.Schema{type: :array, items: map_connection_schema()},
                updated: %OpenApiSpex.Schema{type: :array, items: map_connection_schema()}
              }
            }
          }
        }
      }
    }
  end

  @doc """
  Schema for tracked characters response
  """
  def tracked_characters_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{
            type: :object,
            properties: %{
              id: %OpenApiSpex.Schema{type: :string},
              map_id: %OpenApiSpex.Schema{type: :string},
              character_id: %OpenApiSpex.Schema{type: :string},
              tracked: %OpenApiSpex.Schema{type: :boolean},
              inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
              updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
              character: %OpenApiSpex.Schema{
                type: :object,
                properties: %{
                  eve_id: %OpenApiSpex.Schema{type: :string},
                  name: %OpenApiSpex.Schema{type: :string},
                  corporation_id: %OpenApiSpex.Schema{type: :string},
                  corporation_ticker: %OpenApiSpex.Schema{type: :string},
                  alliance_id: %OpenApiSpex.Schema{type: :string},
                  alliance_ticker: %OpenApiSpex.Schema{type: :string}
                },
                required: ["eve_id", "name"]
              }
            },
            required: ["id", "map_id", "character_id", "tracked"]
          }
        }
      },
      required: ["data"]
    }
  end

  @doc """
  Schema for template response
  """
  def template_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: template_schema(true)
      },
      required: ["data"]
    }
  end

  @doc """
  Schema for template list response
  """
  def template_list_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :array,
          items: template_schema(false)
        }
      },
      required: ["data"]
    }
  end

  @doc """
  Schema for template create request
  """
  def template_create_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        name: %OpenApiSpex.Schema{type: :string, description: "Template name"},
        description: %OpenApiSpex.Schema{type: :string, description: "Template description"},
        category: %OpenApiSpex.Schema{type: :string, description: "Template category (e.g., 'wormhole', 'k-space')"},
        author_eve_id: %OpenApiSpex.Schema{type: :string, description: "EVE Character ID of the template creator"},
        is_public: %OpenApiSpex.Schema{type: :boolean, description: "Whether the template is publicly available"},
        systems: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{type: :object},
          description: "System data for the template"
        },
        connections: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{type: :object},
          description: "Connection data for the template"
        }
      },
      required: ["name", "category", "author_eve_id"]
    }
  end

  @doc """
  Schema for template from map request
  """
  def template_from_map_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        map_id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Source map ID"},
        slug: %OpenApiSpex.Schema{type: :string, description: "Source map slug (alternative to map_id)"},
        name: %OpenApiSpex.Schema{type: :string, description: "Template name"},
        description: %OpenApiSpex.Schema{type: :string, description: "Template description"},
        category: %OpenApiSpex.Schema{type: :string, description: "Template category (e.g., 'wormhole', 'k-space')"},
        author_eve_id: %OpenApiSpex.Schema{type: :string, description: "EVE Character ID of the template creator"},
        is_public: %OpenApiSpex.Schema{type: :boolean, description: "Whether the template is publicly available"},
        system_ids: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{type: :string},
          description: "Optional list of specific system IDs to include"
        }
      },
      required: ["name", "category", "author_eve_id"]
    }
  end

  defp template_schema(include_content) do
    properties = %{
      id: %OpenApiSpex.Schema{type: :string},
      name: %OpenApiSpex.Schema{type: :string},
      description: %OpenApiSpex.Schema{type: :string},
      category: %OpenApiSpex.Schema{type: :string},
      author_eve_id: %OpenApiSpex.Schema{type: :string},
      author_name: %OpenApiSpex.Schema{type: :string},
      is_public: %OpenApiSpex.Schema{type: :boolean},
      version: %OpenApiSpex.Schema{type: :integer},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time}
    }

    # Only include content for single template view
    properties = if include_content do
      Map.merge(properties, %{
        systems: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{type: :object}
        },
        connections: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{type: :object}
        }
      })
    else
      properties
    end

    %OpenApiSpex.Schema{
      type: :object,
      properties: properties
    }
  end

  @doc """
  Schema for template update metadata request
  """
  def template_update_metadata_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        name: %OpenApiSpex.Schema{type: :string, description: "Template name"},
        description: %OpenApiSpex.Schema{type: :string, description: "Template description"},
        category: %OpenApiSpex.Schema{type: :string, description: "Template category"},
        is_public: %OpenApiSpex.Schema{type: :boolean, description: "Whether the template is publicly available"}
      }
    }
  end

  @doc """
  Schema for template update content request
  """
  def template_update_content_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        systems: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{type: :object},
          description: "Updated system data for the template"
        },
        connections: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{type: :object},
          description: "Updated connection data for the template"
        }
      },
      required: ["systems", "connections"]
    }
  end

  @doc """
  Schema for applying a template request
  """
  def template_apply_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        template_id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "ID of the template to apply"},
        map_id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Target map ID"},
        slug: %OpenApiSpex.Schema{type: :string, description: "Target map slug (alternative to map_id)"},
        position_x: %OpenApiSpex.Schema{type: :integer, description: "X position to place the template at"},
        position_y: %OpenApiSpex.Schema{type: :integer, description: "Y position to place the template at"},
        scale: %OpenApiSpex.Schema{type: :number, format: :float, description: "Scale factor for the template (default: 1.0)"},
        cleanup_existing: %OpenApiSpex.Schema{type: :boolean, description: "If true, removes existing visible systems before applying the template"}
      },
      required: ["template_id"]
    }
  end

  @doc """
  Schema for apply template response
  """
  def template_apply_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            systems: %OpenApiSpex.Schema{
              type: :array,
              items: map_system_schema()
            },
            connections: %OpenApiSpex.Schema{
              type: :array,
              items: map_connection_schema()
            }
          }
        }
      }
    }
  end
end
