defmodule WandererAppWeb.MapAPIController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import Ash.Query, only: [filter: 2]
  require Logger

  alias WandererApp.Api.Character
  alias WandererApp.MapConnectionRepo
  alias WandererApp.MapSystemRepo
  alias WandererApp.MapCharacterSettingsRepo

  alias WandererApp.Zkb.KillsProvider.KillsCache

  alias WandererAppWeb.UtilAPIController, as: Util

  # Define schema as module attribute to avoid ordering issues
  @tracked_characters_response_schema %OpenApiSpex.Schema{
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

  # -----------------------------------------------------------------
  # Inline Schemas (Defined as public functions for access)
  # -----------------------------------------------------------------

  @spec map_system_schema() :: OpenApiSpex.Schema.t()
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

  @spec list_map_systems_response_schema() :: OpenApiSpex.Schema.t()
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

  @spec show_map_system_response_schema() :: OpenApiSpex.Schema.t()
  def show_map_system_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: map_system_schema()
      },
      required: ["data"]
    }
  end

  @spec upsert_systems_request_schema() :: OpenApiSpex.Schema.t()
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

  @spec upsert_systems_response_schema() :: OpenApiSpex.Schema.t()
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

  @spec delete_systems_request_schema() :: OpenApiSpex.Schema.t()
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

  @spec delete_systems_response_schema() :: OpenApiSpex.Schema.t()
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

  @spec map_connection_schema() :: OpenApiSpex.Schema.t()
  def map_connection_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        id: %OpenApiSpex.Schema{type: :string},
        map_id: %OpenApiSpex.Schema{type: :string},
        solar_system_source: %OpenApiSpex.Schema{type: :integer},
        solar_system_target: %OpenApiSpex.Schema{type: :integer},
        mass_status: %OpenApiSpex.Schema{type: :integer},
        time_status: %OpenApiSpex.Schema{type: :integer},
        ship_size_type: %OpenApiSpex.Schema{type: :integer},
        type: %OpenApiSpex.Schema{type: :integer},
        wormhole_type: %OpenApiSpex.Schema{type: :string},
        inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
        updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time}
      },
      required: ["id", "map_id", "solar_system_source", "solar_system_target", "type", "inserted_at", "updated_at"]
    }
  end

  @spec list_map_connections_response_schema() :: OpenApiSpex.Schema.t()
  def list_map_connections_response_schema do
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
              solar_system_source: %OpenApiSpex.Schema{type: :integer},
              solar_system_target: %OpenApiSpex.Schema{type: :integer},
              mass_status: %OpenApiSpex.Schema{type: :integer},
              time_status: %OpenApiSpex.Schema{type: :integer},
              ship_size_type: %OpenApiSpex.Schema{type: :integer},
              type: %OpenApiSpex.Schema{type: :integer},
              wormhole_type: %OpenApiSpex.Schema{type: :string},
              inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
              updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time}
            },
            required: ["id", "map_id", "solar_system_source", "solar_system_target", "type", "inserted_at", "updated_at"]
          }
        }
      },
      required: ["data"]
    }
  end

  @spec show_map_connection_response_schema() :: OpenApiSpex.Schema.t()
  def show_map_connection_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: map_connection_schema()
      },
      required: ["data"]
    }
  end

  @spec upsert_connections_request_schema() :: OpenApiSpex.Schema.t()
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
              mass_status: %OpenApiSpex.Schema{type: :integer, description: "Mass status: 0=GreaterThanHalf, 1=LessThanHalf, 2=Critical"},
              time_status: %OpenApiSpex.Schema{type: :integer, description: "Time status: 0=Normal, 1=EndOfLife"},
              ship_size_type: %OpenApiSpex.Schema{type: :integer, description: "Ship size type: 0=Frigate, 1=Medium, 2=Large, 3=Freight, 4=Capital"},
              type: %OpenApiSpex.Schema{type: :integer, description: "Connection type: 0=Wormhole, 1=Gate"},
              wormhole_type: %OpenApiSpex.Schema{type: :string, description: "Wormhole type code (e.g., K162, H296)"},
              count_of_passage: %OpenApiSpex.Schema{type: :integer, description: "Count of passages"},
              locked: %OpenApiSpex.Schema{type: :boolean, description: "Is connection locked"},
              custom_info: %OpenApiSpex.Schema{type: :string, description: "Custom information"}
            },
            required: ["solar_system_source", "solar_system_target"]
          }
        }
      },
      required: ["connections"]
    }
  end

  @spec upsert_connections_response_schema() :: OpenApiSpex.Schema.t()
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

  @spec upsert_systems_and_connections_request_schema() :: OpenApiSpex.Schema.t()
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
        },
        connections: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{
            type: :object,
            properties: %{
              id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Connection ID (optional for new connections)"},
              solar_system_source: %OpenApiSpex.Schema{type: :integer, description: "Source solar system ID"},
              solar_system_target: %OpenApiSpex.Schema{type: :integer, description: "Target solar system ID"},
              mass_status: %OpenApiSpex.Schema{type: :integer, description: "Mass status: 0=GreaterThanHalf, 1=LessThanHalf, 2=Critical"},
              time_status: %OpenApiSpex.Schema{type: :integer, description: "Time status: 0=Normal, 1=EndOfLife"},
              ship_size_type: %OpenApiSpex.Schema{type: :integer, description: "Ship size type: 0=Frigate, 1=Medium, 2=Large, 3=Freight, 4=Capital"},
              type: %OpenApiSpex.Schema{type: :integer, description: "Connection type: 0=Wormhole, 1=Gate"},
              wormhole_type: %OpenApiSpex.Schema{type: :string, description: "Wormhole type code (e.g., K162, H296)"},
              count_of_passage: %OpenApiSpex.Schema{type: :integer, description: "Count of passages"},
              locked: %OpenApiSpex.Schema{type: :boolean, description: "Is connection locked"},
              custom_info: %OpenApiSpex.Schema{type: :string, description: "Custom information"}
            },
            required: ["solar_system_source", "solar_system_target"]
          }
        }
      },
      required: ["systems"]
    }
  end

  @spec upsert_systems_and_connections_response_schema() :: OpenApiSpex.Schema.t()
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
                created: %OpenApiSpex.Schema{
                  type: :array,
                  items: map_system_schema()
                },
                updated: %OpenApiSpex.Schema{
                  type: :array,
                  items: map_system_schema()
                }
              }
            },
            connections: %OpenApiSpex.Schema{
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
      }
    }
  end

  @spec delete_connections_request_schema() :: OpenApiSpex.Schema.t()
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

  @spec delete_connections_response_schema() :: OpenApiSpex.Schema.t()
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

  @spec character_schema() :: OpenApiSpex.Schema.t()
  def character_schema do
    %OpenApiSpex.Schema{
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
  end

  @spec tracked_char_schema() :: OpenApiSpex.Schema.t()
  def tracked_char_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        id: %OpenApiSpex.Schema{type: :string},
        map_id: %OpenApiSpex.Schema{type: :string},
        character_id: %OpenApiSpex.Schema{type: :string},
        tracked: %OpenApiSpex.Schema{type: :boolean},
        inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
        updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
        character: character_schema()
      },
      required: ["id", "map_id", "character_id", "tracked"]
    }
  end

  @spec character_activity_item_schema() :: OpenApiSpex.Schema.t()
  def character_activity_item_schema do
    %OpenApiSpex.Schema{
      type: :object,
      description: "Character activity data",
      properties: %{
        character: character_schema(),
        passages: %OpenApiSpex.Schema{type: :integer, description: "Number of passages through systems"},
        connections: %OpenApiSpex.Schema{type: :integer, description: "Number of connections created"},
        signatures: %OpenApiSpex.Schema{type: :integer, description: "Number of signatures added"},
        timestamp: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Timestamp of the activity"}
      },
      required: ["character", "passages", "connections", "signatures"]
    }
  end

  @spec character_activity_response_schema() :: OpenApiSpex.Schema.t()
  def character_activity_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :array,
          items: character_activity_item_schema()
        }
      },
      required: ["data"]
    }
  end

  @spec user_character_schema() :: OpenApiSpex.Schema.t()
  def user_character_schema do
    %OpenApiSpex.Schema{
      type: :object,
      description: "Character group information with main character identification",
      properties: %{
        characters: %OpenApiSpex.Schema{
          type: :array,
          items: character_schema(),
          description: "List of characters belonging to a user"
        },
        main_character_eve_id: %OpenApiSpex.Schema{
          type: :string,
          description: "EVE ID of the main character for this user on this map",
          nullable: true
        }
      },
      required: ["characters"]
    }
  end

  @spec user_characters_response_schema() :: OpenApiSpex.Schema.t()
  def user_characters_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :array,
          items: user_character_schema()
        }
      },
      required: ["data"]
    }
  end

  @spec structure_timer_schema() :: OpenApiSpex.Schema.t()
  def structure_timer_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        system_id: %OpenApiSpex.Schema{type: :string},
        solar_system_name: %OpenApiSpex.Schema{type: :string},
        solar_system_id: %OpenApiSpex.Schema{type: :integer},
        structure_type_id: %OpenApiSpex.Schema{type: :integer},
        structure_type: %OpenApiSpex.Schema{type: :string},
        character_eve_id: %OpenApiSpex.Schema{type: :string},
        name: %OpenApiSpex.Schema{type: :string},
        notes: %OpenApiSpex.Schema{type: :string},
        owner_name: %OpenApiSpex.Schema{type: :string},
        owner_ticker: %OpenApiSpex.Schema{type: :string},
        owner_id: %OpenApiSpex.Schema{type: :string},
        status: %OpenApiSpex.Schema{type: :string},
        end_time: %OpenApiSpex.Schema{type: :string, format: :date_time}
      },
      required: ["system_id", "solar_system_id", "name", "status"]
    }
  end

  @spec structure_timers_response_schema() :: OpenApiSpex.Schema.t()
  def structure_timers_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :array,
          items: structure_timer_schema()
        }
      },
      required: ["data"]
    }
  end

  @spec kill_item_schema() :: OpenApiSpex.Schema.t()
  def kill_item_schema do
    %OpenApiSpex.Schema{
      type: :object,
      description: "Kill detail object",
      properties: %{
        kill_id: %OpenApiSpex.Schema{type: :integer, description: "Unique identifier for the kill"},
        kill_time: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Time when the kill occurred"},
        victim_id: %OpenApiSpex.Schema{type: :integer, description: "ID of the victim character"},
        victim_name: %OpenApiSpex.Schema{type: :string, description: "Name of the victim character"},
        ship_type_id: %OpenApiSpex.Schema{type: :integer, description: "Type ID of the destroyed ship"},
        ship_name: %OpenApiSpex.Schema{type: :string, description: "Name of the destroyed ship"}
      }
    }
  end

  @spec system_kills_schema() :: OpenApiSpex.Schema.t()
  def system_kills_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        solar_system_id: %OpenApiSpex.Schema{type: :integer},
        kills: %OpenApiSpex.Schema{
          type: :array,
          items: kill_item_schema()
        }
      },
      required: ["solar_system_id", "kills"]
    }
  end

  @spec systems_kills_response_schema() :: OpenApiSpex.Schema.t()
  def systems_kills_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :array,
          items: system_kills_schema()
        }
      },
      required: ["data"]
    }
  end

  @spec template_schema() :: OpenApiSpex.Schema.t()
  def template_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Template UUID"},
        name: %OpenApiSpex.Schema{type: :string, description: "Template name"},
        description: %OpenApiSpex.Schema{type: :string, description: "Template description"},
        category: %OpenApiSpex.Schema{type: :string, description: "Template category (e.g., 'wormhole', 'k-space')"},
        author_eve_id: %OpenApiSpex.Schema{type: :string, description: "EVE Character ID of the template creator"},
        source_map_id: %OpenApiSpex.Schema{type: :string, description: "Source map ID if created from a map"},
        is_public: %OpenApiSpex.Schema{type: :boolean, description: "Whether the template is publicly available"},
        systems: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}, description: "Array of systems in the template"},
        connections: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}, description: "Array of connections in the template"},
        metadata: %OpenApiSpex.Schema{type: :object, description: "Additional metadata for the template"},
        inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Creation timestamp"},
        updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Last update timestamp"}
      },
      required: ["id", "name", "category"]
    }
  end

  @spec template_list_response_schema() :: OpenApiSpex.Schema.t()
  def template_list_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :array,
          items: template_schema()
        }
      },
      required: ["data"]
    }
  end

  @spec template_response_schema() :: OpenApiSpex.Schema.t()
  def template_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: template_schema()
      },
      required: ["data"]
    }
  end

  @spec template_create_request_schema() :: OpenApiSpex.Schema.t()
  def template_create_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        name: %OpenApiSpex.Schema{type: :string, description: "Template name"},
        description: %OpenApiSpex.Schema{type: :string, description: "Template description"},
        category: %OpenApiSpex.Schema{type: :string, description: "Template category (e.g., 'wormhole', 'k-space')"},
        author_eve_id: %OpenApiSpex.Schema{type: :string, description: "EVE Character ID of the template creator"},
        source_map_id: %OpenApiSpex.Schema{type: :string, description: "Source map ID if created from a map"},
        is_public: %OpenApiSpex.Schema{type: :boolean, description: "Whether the template is publicly available"},
        systems: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}, description: "Array of systems in the template"},
        connections: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}, description: "Array of connections in the template"},
        metadata: %OpenApiSpex.Schema{type: :object, description: "Additional metadata for the template"}
      },
      required: ["name"]
    }
  end

  @spec template_from_map_request_schema() :: OpenApiSpex.Schema.t()
  def template_from_map_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        map_id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Map UUID"},
        slug: %OpenApiSpex.Schema{type: :string, description: "Map slug"},
        name: %OpenApiSpex.Schema{type: :string, description: "Template name"},
        description: %OpenApiSpex.Schema{type: :string, description: "Template description"},
        category: %OpenApiSpex.Schema{type: :string, description: "Template category (e.g., 'wormhole', 'k-space')"},
        author_eve_id: %OpenApiSpex.Schema{type: :string, description: "EVE Character ID of the template creator"},
        is_public: %OpenApiSpex.Schema{type: :boolean, description: "Whether the template is publicly available"},
        system_ids: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string, format: :uuid}, description: "List of system IDs to include in the template. If omitted, all systems will be included."},
        metadata: %OpenApiSpex.Schema{type: :object, description: "Additional metadata for the template"}
      },
      required: ["name"]
    }
  end

  @spec template_update_metadata_request_schema() :: OpenApiSpex.Schema.t()
  def template_update_metadata_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        name: %OpenApiSpex.Schema{type: :string},
        description: %OpenApiSpex.Schema{type: :string},
        category: %OpenApiSpex.Schema{type: :string},
        is_public: %OpenApiSpex.Schema{type: :boolean}
      }
    }
  end

  @spec template_update_content_request_schema() :: OpenApiSpex.Schema.t()
  def template_update_content_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        systems: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}},
        connections: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}},
        metadata: %OpenApiSpex.Schema{type: :object}
      }
    }
  end

  @spec template_apply_request_schema() :: OpenApiSpex.Schema.t()
  def template_apply_request_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        template_id: %OpenApiSpex.Schema{type: :string, format: :uuid}
      },
      required: ["template_id"]
    }
  end

  @spec template_apply_response_schema() :: OpenApiSpex.Schema.t()
  def template_apply_response_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            systems_added: %OpenApiSpex.Schema{type: :integer},
            connections_added: %OpenApiSpex.Schema{type: :integer}
          }
        }
      },
      required: ["data"]
    }
  end

  # -----------------------------------------------------------------
  # MAP endpoints (Remaining)
  # -----------------------------------------------------------------

  @doc """
  GET /api/map/tracked_characters_with_info

  Returns a list of tracked records, plus their fully-loaded `character` data.
  """
  @spec tracked_characters_with_info(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :tracked_characters_with_info,
    summary: "List Tracked Characters with Info",
    description: "Lists all tracked characters for a map with their information.",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID) - Either map_id or slug must be provided",
        type: :string,
        required: false
      ],
      slug: [
        in: :query,
        description: "Map slug - Either map_id or slug must be provided",
        type: :string,
        required: false
      ]
    ],
    responses: [
      ok: {
        "List of tracked characters",
        "application/json",
        @tracked_characters_response_schema
      },
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          error: %OpenApiSpex.Schema{type: :string}
        },
        required: ["error"],
        example: %{"error" => "Must provide either ?map_id=UUID or ?slug=SLUG"}
      }}
    ]
  def tracked_characters_with_info(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, settings_list} <- get_tracked_by_map_ids(map_id),
         {:ok, char_list} <- read_characters_by_ids_wrapper(Enum.map(settings_list, & &1.character_id)) do
      chars_by_id = Map.new(char_list, &{&1.id, &1})

      data =
        Enum.map(settings_list, fn setting ->
          found_char = Map.get(chars_by_id, setting.character_id)

          %{
            id: setting.id,
            map_id: setting.map_id,
            character_id: setting.character_id,
            tracked: setting.tracked,
            inserted_at: setting.inserted_at,
            updated_at: setting.updated_at,
            character:
              if found_char do
                character_to_json(found_char)
              else
                %{}
              end
          }
        end)

      json(conn, %{data: data})
    else
      {:error, :get_tracked_error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No tracked records found for map_id: #{Util.format_error(reason)}"})

      {:error, :read_characters_by_ids_error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Could not load Character records: #{Util.format_error(reason)}"})

      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})
    end
  end

  @doc """
  GET /api/map/structure_timers

  Returns structure timers for visible systems on the map or for a specific system.
  """
  @spec show_structure_timers(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :show_structure_timers,
    summary: "Show Structure Timers",
    description: "Retrieves structure timers for a map.",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID) - Either map_id or slug must be provided",
        type: :string,
        required: false
      ],
      slug: [
        in: :query,
        description: "Map slug - Either map_id or slug must be provided",
        type: :string,
        required: false
      ],
      system_id: [
        in: :query,
        description: "System ID",
        type: :string,
        required: false
      ]
    ],
    responses: [
      ok: {
        "Structure timers",
        "application/json",
        %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            data: %OpenApiSpex.Schema{
              type: :array,
              items: %OpenApiSpex.Schema{
                type: :object,
                properties: %{
                  system_id: %OpenApiSpex.Schema{type: :string},
                  solar_system_name: %OpenApiSpex.Schema{type: :string},
                  solar_system_id: %OpenApiSpex.Schema{type: :integer},
                  structure_type_id: %OpenApiSpex.Schema{type: :integer},
                  structure_type: %OpenApiSpex.Schema{type: :string},
                  character_eve_id: %OpenApiSpex.Schema{type: :string},
                  name: %OpenApiSpex.Schema{type: :string},
                  notes: %OpenApiSpex.Schema{type: :string},
                  owner_name: %OpenApiSpex.Schema{type: :string},
                  owner_ticker: %OpenApiSpex.Schema{type: :string},
                  owner_id: %OpenApiSpex.Schema{type: :string},
                  status: %OpenApiSpex.Schema{type: :string},
                  end_time: %OpenApiSpex.Schema{type: :string, format: :date_time}
                },
                required: ["system_id", "solar_system_id", "name", "status"]
              }
            }
          },
          required: ["data"]
        }
      },
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          error: %OpenApiSpex.Schema{type: :string}
        },
        required: ["error"],
        example: %{"error" => "Must provide either ?map_id=UUID or ?slug=SLUG as a query parameter"}
      }}
    ]
  def show_structure_timers(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params) do
      system_id_str = params["system_id"]

      case system_id_str do
        nil ->
          handle_all_structure_timers(conn, map_id)

        _ ->
          case Util.parse_int(system_id_str) do
            {:ok, system_id} ->
              handle_single_structure_timers(conn, map_id, system_id)

            {:error, reason} ->
              conn
              |> put_status(:bad_request)
              |> json(%{error: "system_id must be int: #{reason}"})
          end
      end
    else
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})
    end
  end

  @doc """
  GET /api/map/systems_kills

  Returns kills data for all *visible* systems on the map.
  """
  @spec list_systems_kills(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :list_systems_kills,
    summary: "List Systems Kills",
    description: "Returns kills data for all visible systems on the map.",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID) - Either map_id or slug must be provided",
        type: :string,
        required: false
      ],
      slug: [
        in: :query,
        description: "Map slug - Either map_id or slug must be provided",
        type: :string,
        required: false
      ],
      hours: [
        in: :query,
        description: "Number of hours to look back for kills",
        type: :string,
        required: false
      ]
    ],
    responses: [
      ok: {
        "Systems kills data",
        "application/json",
        %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            data: %OpenApiSpex.Schema{
              type: :array,
              items: %OpenApiSpex.Schema{
                type: :object,
                properties: %{
                  solar_system_id: %OpenApiSpex.Schema{type: :integer},
                  kills: %OpenApiSpex.Schema{
                    type: :array,
                    items: %OpenApiSpex.Schema{
                      type: :object,
                      description: "Kill detail object",
                      properties: %{
                        kill_id: %OpenApiSpex.Schema{type: :integer, description: "Unique identifier for the kill"},
                        kill_time: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Time when the kill occurred"},
                        victim_id: %OpenApiSpex.Schema{type: :integer, description: "ID of the victim character"},
                        victim_name: %OpenApiSpex.Schema{type: :string, description: "Name of the victim character"},
                        ship_type_id: %OpenApiSpex.Schema{type: :integer, description: "Type ID of the destroyed ship"},
                        ship_name: %OpenApiSpex.Schema{type: :string, description: "Name of the destroyed ship"}
                      }
                    }
                  }
                },
                required: ["solar_system_id", "kills"]
              }
            }
          },
          required: ["data"]
        }
      },
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          error: %OpenApiSpex.Schema{type: :string}
        },
        required: ["error"],
        example: %{"error" => "Must provide either ?map_id=UUID or ?slug=SLUG as a query parameter"}
      }}
    ]
  def list_systems_kills(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, systems} <- MapSystemRepo.get_visible_by_map(map_id) do

      Logger.debug(fn -> "[list_systems_kills] Found #{length(systems)} visible systems for map_id=#{map_id}" end)

      hours_ago = parse_hours_ago(params["hours_ago"] || params["hour_ago"])

      Logger.debug(fn -> "[list_systems_kills] Using hours_ago=#{inspect(hours_ago)}, from params: hours_ago=#{inspect(params["hours_ago"])}, hour_ago=#{inspect(params["hour_ago"])}" end)

      solar_ids = Enum.map(systems, & &1.solar_system_id)
      kills_map = KillsCache.fetch_cached_kills_for_systems(solar_ids)

      data =
        Enum.map(systems, fn sys ->
          kills = Map.get(kills_map, sys.solar_system_id, [])
          filtered_kills = maybe_filter_kills_by_time(kills, hours_ago)

          Logger.debug(fn ->
            "[list_systems_kills] For system_id=#{sys.solar_system_id}, " <>
            "found #{length(kills)} kills total, " <>
            "returning #{length(filtered_kills)} kills after hours_ago=#{inspect(hours_ago)} filter"
          end)

          %{
            solar_system_id: sys.solar_system_id,
            kills: filtered_kills
          }
        end)

      json(conn, %{data: data})
    else
      {:error, msg} when is_binary(msg) ->
        Logger.warning("[list_systems_kills] Bad request: #{msg}")
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, reason} ->
        Logger.error("[list_systems_kills] Could not fetch systems: #{inspect(reason)}")
        conn
        |> put_status(:not_found)
        |> json(%{error: "Could not fetch systems: #{inspect(reason)}"})
    end
  end

  @doc """
  GET /api/map/character_activity

  Returns character activity data for a map.
  """
  @spec character_activity(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :character_activity,
    summary: "Get Character Activity",
    description: "Returns character activity data for a map.",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID) - Either map_id or slug must be provided",
        type: :string,
        required: false
      ],
      slug: [
        in: :query,
        description: "Map slug - Either map_id or slug must be provided",
        type: :string,
        required: false
      ],
      days: [
        in: :query,
        description: "Optional: Number of days to look back for activity data.",
        type: :integer,
        required: false
      ]
    ],
    responses: [
      ok: {
        "Character activity data",
        "application/json",
        %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            data: %OpenApiSpex.Schema{
              type: :array,
              items: %OpenApiSpex.Schema{
                type: :object,
                description: "Character activity data",
                properties: %{
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
                  },
                  passages: %OpenApiSpex.Schema{type: :integer, description: "Number of passages through systems"},
                  connections: %OpenApiSpex.Schema{type: :integer, description: "Number of connections created"},
                  signatures: %OpenApiSpex.Schema{type: :integer, description: "Number of signatures added"},
                  timestamp: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Timestamp of the activity"}
                },
                required: ["character", "passages", "connections", "signatures"]
              }
            }
          },
          required: ["data"]
        }
      },
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          error: %OpenApiSpex.Schema{type: :string}
        },
        required: ["error"],
        example: %{"error" => "Must provide either ?map_id=UUID or ?slug=SLUG as a query parameter"}
      }}
    ]
  def character_activity(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, days} <- parse_days(params["days"]) do
      raw_activity = WandererApp.Map.get_character_activity(map_id, days)

      summarized_result =
        if raw_activity == [] do
          []
        else
          raw_activity
          |> Enum.group_by(fn activity -> activity.character.user_id end)
          |> Enum.map(fn {_user_id, user_activities} ->
            representative_activity =
              user_activities
              |> Enum.max_by(fn act -> act.passages + act.connections + act.signatures end)

            total_passages = Enum.sum(Enum.map(user_activities, & &1.passages))
            total_connections = Enum.sum(Enum.map(user_activities, & &1.connections))
            total_signatures = Enum.sum(Enum.map(user_activities, & &1.signatures))

            %{
              character: character_to_json(representative_activity.character),
              passages: total_passages,
              connections: total_connections,
              signatures: total_signatures,
              timestamp: representative_activity.timestamp
            }
          end)
        end

      json(conn, %{data: summarized_result})
    else
      {:error, msg} when is_binary(msg) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Could not fetch character activity: #{inspect(reason)}"})
    end
  end

  @doc """
  GET /api/map/user_characters

  Returns characters grouped by user for a specific map.
  """
  @spec user_characters(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :user_characters,
    summary: "Get User Characters",
    description: "Returns characters grouped by user for a specific map.",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID) - Either map_id or slug must be provided",
        type: :string,
        required: false
      ],
      slug: [
        in: :query,
        description: "Map slug - Either map_id or slug must be provided",
        type: :string,
        required: false
      ]
    ],
    responses: [
      ok: {
        "User characters with main character indication",
        "application/json",
        %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            data: %OpenApiSpex.Schema{
              type: :array,
              items: %OpenApiSpex.Schema{
                type: :object,
                description: "Character group information with main character identification",
                properties: %{
                  characters: %OpenApiSpex.Schema{
                    type: :array,
                    items: %OpenApiSpex.Schema{
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
                    },
                    description: "List of characters belonging to a user"
                  },
                  main_character_eve_id: %OpenApiSpex.Schema{
                    type: :string,
                    description: "EVE ID of the main character for this user on this map",
                    nullable: true
                  }
                },
                required: ["characters"]
              }
            }
          },
          required: ["data"]
        }
      },
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          error: %OpenApiSpex.Schema{type: :string}
        },
        required: ["error"],
        example: %{"error" => "Must provide either ?map_id=UUID or ?slug=SLUG as a query parameter"}
      }}
    ]
  def user_characters(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params) do
      case MapCharacterSettingsRepo.get_all_by_map(map_id) do
        {:ok, map_character_settings} when map_character_settings != [] ->
          character_ids = Enum.map(map_character_settings, &(&1.character_id))

          case WandererApp.Api.read(Character |> filter(id in ^character_ids)) do
            {:ok, characters} when characters != [] ->
              characters_by_user =
                characters
                |> Enum.filter(fn char -> not is_nil(char.user_id) end)
                |> Enum.group_by(&(&1.user_id))

              settings_query =
                WandererApp.Api.MapUserSettings
                |> Ash.Query.new()
                |> Ash.Query.filter(map_id == ^map_id)

              main_characters_by_user =
                case WandererApp.Api.read(settings_query) do
                  {:ok, map_user_settings} ->
                    Map.new(map_user_settings, fn settings -> {settings.user_id, settings.main_character_eve_id} end)
                  _ -> %{}
                end

              character_groups =
                Enum.map(characters_by_user, fn {user_id, user_characters} ->
                  %{
                    characters: Enum.map(user_characters, &character_to_json/1),
                    main_character_eve_id: Map.get(main_characters_by_user, user_id)
                  }
                end)

              json(conn, %{data: character_groups})

            {:ok, []} -> json(conn, %{data: []})
            {:error, reason} ->
              conn
              |> put_status(:internal_server_error)
              |> json(%{error: "Failed to fetch characters: #{inspect(reason)}"})
          end
        {:ok, []} -> json(conn, %{data: []})
        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "Failed to fetch map character settings: #{inspect(reason)}"})
      end
    else
      {:error, msg} when is_binary(msg) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Could not fetch user characters: #{inspect(reason)}"})
    end
  end

  # ---------------- Helper functions for Character Info ----------------
  defp get_tracked_by_map_ids(map_id) do
    _query =
      Character.MapCharacterSettings
      |> filter(map_id == ^map_id)
      |> filter(tracked == true)

    case MapCharacterSettingsRepo.get_all_by_map(map_id) do
      {:ok, settings} -> {:ok, settings}
      {:error, reason} -> {:error, :get_tracked_error, reason}
    end
  end

  defp read_characters_by_ids_wrapper(character_ids) do
    case WandererApp.Api.read(Character |> filter(id in ^character_ids)) do
      {:ok, characters} -> {:ok, characters}
      {:error, reason} -> {:error, :read_characters_by_ids_error, reason}
    end
  end

  # ---------------- Private Helpers (Remaining & Added for Combined Upsert) ----------------


  # --- Helpers for Structure Timers ---
  defp handle_all_structure_timers(conn, map_id) do
    case MapSystemRepo.get_visible_by_map(map_id) do
      {:ok, systems} ->
        all_timers = systems |> Enum.flat_map(&get_timers_for_system/1)
        json(conn, %{data: all_timers})
      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Could not fetch visible systems for map_id=#{map_id}: #{inspect(reason)}"})
    end
  end

  defp handle_single_structure_timers(conn, map_id, system_id) do
    case MapSystemRepo.get_by_map_and_solar_system_id(map_id, system_id) do
      {:ok, map_system} ->
        timers = get_timers_for_system(map_system)
        json(conn, %{data: timers})
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No system with solar_system_id=#{system_id} in map=#{map_id}"})
      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to retrieve system: #{inspect(reason)}"})
    end
  end

  defp get_timers_for_system(map_system) do
    structures = WandererApp.Api.MapSystemStructure.by_system_id!(map_system.id)
    structures
    |> Enum.filter(&timer_needed?/1)
    |> Enum.map(&structure_to_timer_json/1)
  end

  defp timer_needed?(structure) do
    structure.status in ["Anchoring", "Reinforced"] and not is_nil(structure.end_time)
  end

  defp structure_to_timer_json(s) do
    Map.take(s, [
      :system_id,
      :solar_system_name,
      :solar_system_id,
      :structure_type_id,
      :structure_type,
      :character_eve_id,
      :name,
      :notes,
      :owner_name,
      :owner_ticker,
      :owner_id,
      :status,
      :end_time
    ])
  end

  # --- Helpers for System Kills ---
  defp parse_hours_ago(nil), do: nil
  defp parse_hours_ago(hours_str) do
    Logger.debug(fn -> "[parse_hours_ago] Parsing hours_str: #{inspect(hours_str)}" end)
    result = case Integer.parse(hours_str) do
      {num, ""} when num > 0 ->
        Logger.debug(fn -> "[parse_hours_ago] Successfully parsed to #{num}" end)
        num
      {num, rest} ->
        Logger.debug(fn -> "[parse_hours_ago] Parsed with remainder: #{num}, rest: #{inspect(rest)}" end)
        nil
      :error ->
        Logger.debug(fn -> "[parse_hours_ago] Failed to parse" end)
        nil
    end
    Logger.debug(fn -> "[parse_hours_ago] Final result: #{inspect(result)}" end)
    result
  end

  defp maybe_filter_kills_by_time(kills, hours_ago) when is_integer(hours_ago) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours_ago * 3600, :second)
    Logger.debug(fn -> "[maybe_filter_kills_by_time] Filtering kills with cutoff: #{DateTime.to_iso8601(cutoff)}" end)
    filtered = Enum.filter(kills, fn kill ->
      kill_time = kill["kill_time"]
      result = case kill_time do
        %DateTime{} = dt -> DateTime.compare(dt, cutoff) != :lt
        time when is_binary(time) ->
          case DateTime.from_iso8601(time) do
            {:ok, dt, _} -> DateTime.compare(dt, cutoff) != :lt
            _ -> false
          end
        _ -> false
      end
      Logger.debug(fn ->
        kill_time_str = if is_binary(kill_time), do: kill_time, else: inspect(kill_time)
        "[maybe_filter_kills_by_time] Kill time: #{kill_time_str}, included: #{result}"
      end)
      result
    end)
    Logger.debug(fn -> "[maybe_filter_kills_by_time] Filtered #{length(kills)} kills to #{length(filtered)} kills" end)
    filtered
  end

  defp maybe_filter_kills_by_time(kills, nil), do: kills

  # --- Helpers for Character Activity ---
  defp parse_days(nil), do: {:ok, nil}
  defp parse_days(days_str) do
    case Integer.parse(days_str) do
      {days, ""} when days > 0 -> {:ok, days}
      _ -> {:ok, nil}
    end
  end

  # --- JSON Formatting Helpers ---
  defp character_to_json(ch) do
    WandererAppWeb.MapEventHandler.map_ui_character_stat(ch)
  end

end
