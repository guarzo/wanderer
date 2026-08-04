defmodule WandererApp.ExternalEvents.JsonApiFormatter do
  @moduledoc """
  JSON:API event formatter for real-time events.

  Converts internal event structures to JSON:API compliant format
  for consistency with the API specification.
  """

  alias WandererApp.ExternalEvents.Event

  # Explicit allowlist for character payloads. Character events broadcast a
  # WandererApp.Api.Character struct, which also carries the OAuth token fields
  # and the owner hash - those must never be read.
  #
  # :id is deliberately absent: it is the resource identity, and JSON:API
  # forbids an attribute named "id".
  @character_attribute_keys [
    :eve_id,
    :name,
    :corporation_id,
    :corporation_ticker,
    :alliance_id,
    :ship_name,
    :solar_system_id,
    :online
  ]

  @doc """
  Formats an event into JSON:API structure.

  Converts internal events to JSON:API format:
  - `data`: Resource object with type, id, attributes, relationships
  - `meta`: Event metadata (type, timestamp, etc.)
  - `links`: Related resource links where applicable
  """
  @spec format_event(Event.t()) :: map()
  def format_event(%Event{} = event) do
    %{
      "data" => format_resource_data(event),
      "meta" => format_event_meta(event),
      "links" => format_event_links(event)
    }
  end

  @doc """
  Formats a legacy event (map format) into JSON:API structure.

  Handles events that are already in map format from existing system.
  """
  @spec format_legacy_event(map()) :: map()
  def format_legacy_event(event) when is_map(event) do
    %{
      "data" => format_legacy_resource_data(event),
      "meta" => format_legacy_event_meta(event),
      "links" => format_legacy_event_links(event)
    }
  end

  # Event-specific resource data formatting
  #
  # Producer: map_server_systems_impl.ex:635 and :899. The :899 variant omits
  # :name, so that attribute is legitimately nil there.
  defp format_resource_data(%Event{type: :add_system, payload: payload} = event) do
    {type, id} = system_identity(event, payload)

    %{
      "type" => type,
      "id" => id,
      "attributes" => %{
        "solar_system_id" => fetch(payload, :solar_system_id),
        "name" => fetch(payload, :name),
        "position_x" => fetch(payload, :position_x),
        "position_y" => fetch(payload, :position_y),
        "created_at" => event.timestamp
      },
      "relationships" => %{"map" => map_relationship(event)}
    }
  end

  # Producer: map_server_systems_impl.ex:348. name/position_x/position_y are
  # deliberately sent as nil and are omitted here rather than echoed as nulls.
  defp format_resource_data(%Event{type: :deleted_system, payload: payload} = event) do
    {type, id} = system_identity(event, payload)

    %{
      "type" => type,
      "id" => id,
      "attributes" => %{
        "solar_system_id" => fetch(payload, :solar_system_id)
      },
      "meta" => %{
        "deleted" => true,
        "deleted_at" => event.timestamp
      },
      "relationships" => %{"map" => map_relationship(event)}
    }
  end

  # No producer for :system_renamed exists in lib/. This clause bounds the
  # output shape; its attribute names are unverified against a real payload.
  defp format_resource_data(%Event{type: :system_renamed, payload: payload} = event) do
    {type, id} = system_identity(event, payload)

    %{
      "type" => type,
      "id" => id,
      "attributes" => %{
        "solar_system_id" => fetch(payload, :solar_system_id),
        "name" => fetch(payload, :name),
        "updated_at" => event.timestamp
      },
      "relationships" => %{"map" => map_relationship(event)}
    }
  end

  # Producer: map_server_systems_impl.ex:1115
  defp format_resource_data(%Event{type: :system_metadata_changed, payload: payload} = event) do
    {type, id} = system_identity(event, payload)

    %{
      "type" => type,
      "id" => id,
      "attributes" => %{
        "solar_system_id" => fetch(payload, :solar_system_id),
        "name" => fetch(payload, :name),
        "temporary_name" => fetch(payload, :temporary_name),
        "labels" => fetch(payload, :labels),
        "description" => fetch(payload, :description),
        "status" => fetch(payload, :status),
        "locked" => fetch(payload, :locked),
        "position_x" => fetch(payload, :position_x),
        "position_y" => fetch(payload, :position_y),
        "updated_at" => event.timestamp
      },
      "relationships" => %{"map" => map_relationship(event)}
    }
  end

  # Producer: map_server_signatures_impl.ex:148 and :159.
  #
  # The producer sends sig.eve_id - the in-game signature code, not the record
  # UUID. api/map_system_signature.ex is uuid_primary_key with eve_id unique
  # only as identity :uniq_system_eve_id, [:system_id, :eve_id], so the code
  # neither resolves as a map_system_signatures id nor is globally unique.
  # Identity is therefore the event ULID and the code is an attribute.
  defp format_resource_data(%Event{type: :signature_added, payload: payload} = event) do
    %{
      "type" => "signature_events",
      "id" => event.id,
      "attributes" => %{
        "solar_system_id" => fetch(payload, :solar_system_id),
        "signature_id" => fetch(payload, :signature_id),
        "name" => fetch(payload, :name),
        "kind" => fetch(payload, :kind),
        "group" => fetch(payload, :group),
        # The producer key is :type; renamed on the wire because JSON:API
        # forbids an attribute named "type".
        "signature_type" => fetch(payload, :type),
        "created_at" => event.timestamp
      },
      "relationships" => %{"map" => map_relationship(event)}
    }
  end

  # Producer: map_server_signatures_impl.ex:159 and :245. Sends only
  # solar_system_id and signature_id.
  defp format_resource_data(%Event{type: :signature_removed, payload: payload} = event) do
    %{
      "type" => "signature_events",
      "id" => event.id,
      "attributes" => %{
        "solar_system_id" => fetch(payload, :solar_system_id),
        "signature_id" => fetch(payload, :signature_id)
      },
      "meta" => %{
        "deleted" => true,
        "deleted_at" => event.timestamp
      },
      "relationships" => %{"map" => map_relationship(event)}
    }
  end

  # Producer: map_server_signatures_impl.ex:166 and :250. A summary event that
  # names no single signature, so the event ULID is the identity.
  defp format_resource_data(%Event{type: :signatures_updated, payload: payload} = event) do
    %{
      "type" => "signature_updates",
      "id" => event.id,
      "attributes" => %{
        "solar_system_id" => fetch(payload, :solar_system_id),
        "added_count" => fetch(payload, :added_count),
        "updated_count" => fetch(payload, :updated_count),
        "removed_count" => fetch(payload, :removed_count),
        "updated_at" => event.timestamp
      },
      "relationships" => %{"map" => map_relationship(event)}
    }
  end

  # Producer: map_server_connections_impl.ex:748. Endpoints are EVE solar
  # system ids, so they are attributes: no map_systems UUID is available.
  defp format_resource_data(%Event{type: :connection_added, payload: payload} = event) do
    %{
      "type" => "map_connections",
      "id" => rid(fetch(payload, :connection_id)),
      "attributes" => %{
        "solar_system_source_id" => fetch(payload, :solar_system_source_id),
        "solar_system_target_id" => fetch(payload, :solar_system_target_id),
        # The producer key is :type; renamed on the wire because JSON:API
        # forbids an attribute named "type".
        "connection_type" => fetch(payload, :type),
        "ship_size_type" => fetch(payload, :ship_size_type),
        "mass_status" => fetch(payload, :mass_status),
        "time_status" => fetch(payload, :time_status),
        "created_at" => event.timestamp
      },
      "relationships" => %{"map" => map_relationship(event)}
    }
  end

  # Producer: map_server_connections_impl.ex:1083
  defp format_resource_data(%Event{type: :connection_removed, payload: payload} = event) do
    %{
      "type" => "map_connections",
      "id" => rid(fetch(payload, :connection_id)),
      "attributes" => %{
        "solar_system_source_id" => fetch(payload, :solar_system_source_id),
        "solar_system_target_id" => fetch(payload, :solar_system_target_id)
      },
      "meta" => %{
        "deleted" => true,
        "deleted_at" => event.timestamp
      },
      "relationships" => %{"map" => map_relationship(event)}
    }
  end

  # Producer: map_server_connections_impl.ex:1140
  defp format_resource_data(%Event{type: :connection_updated, payload: payload} = event) do
    %{
      "type" => "map_connections",
      "id" => rid(fetch(payload, :connection_id)),
      "attributes" => %{
        "solar_system_source_id" => fetch(payload, :solar_system_source_id),
        "solar_system_target_id" => fetch(payload, :solar_system_target_id),
        # Renamed from the producer's :type - JSON:API reserves "type".
        "connection_type" => fetch(payload, :type),
        "ship_size_type" => fetch(payload, :ship_size_type),
        "mass_status" => fetch(payload, :mass_status),
        "time_status" => fetch(payload, :time_status),
        "locked" => fetch(payload, :locked),
        "custom_info" => fetch(payload, :custom_info),
        "updated_at" => event.timestamp
      },
      "relationships" => %{"map" => map_relationship(event)}
    }
  end

  defp format_resource_data(%Event{type: :character_added, payload: payload} = event) do
    %{
      "type" => "characters",
      "id" => payload["character_id"] || payload[:character_id],
      "attributes" => %{
        "eve_id" => payload["eve_id"] || payload[:eve_id],
        "name" => payload["name"] || payload[:name],
        "corporation_name" => payload["corporation_name"] || payload[:corporation_name],
        "corporation_ticker" => payload["corporation_ticker"] || payload[:corporation_ticker],
        "added_at" => event.timestamp
      },
      "relationships" => %{
        "system" => %{
          "data" => %{
            "type" => "map_systems",
            "id" => payload["system_id"] || payload[:system_id]
          }
        },
        "map" => %{
          "data" => %{"type" => "maps", "id" => event.map_id}
        }
      }
    }
  end

  defp format_resource_data(%Event{type: :character_removed, payload: payload} = event) do
    %{
      "type" => "characters",
      "id" => payload["character_id"] || payload[:character_id],
      "meta" => %{
        "removed_from_system" => true,
        "removed_at" => event.timestamp
      },
      "relationships" => %{
        "system" => %{
          "data" => %{
            "type" => "map_systems",
            "id" => payload["system_id"] || payload[:system_id]
          }
        },
        "map" => %{
          "data" => %{"type" => "maps", "id" => event.map_id}
        }
      }
    }
  end

  defp format_resource_data(%Event{type: :character_updated, payload: payload} = event) do
    %{
      "type" => "characters",
      "id" => payload["character_id"] || payload[:character_id],
      "attributes" => %{
        "ship_type_id" => payload["ship_type_id"] || payload[:ship_type_id],
        "ship_name" => payload["ship_name"] || payload[:ship_name],
        "updated_at" => event.timestamp
      },
      "relationships" => %{
        "system" => %{
          "data" => %{
            "type" => "map_systems",
            "id" => payload["system_id"] || payload[:system_id]
          }
        },
        "map" => %{
          "data" => %{"type" => "maps", "id" => event.map_id}
        }
      }
    }
  end

  defp format_resource_data(%Event{type: :acl_member_added, payload: payload} = event) do
    %{
      "type" => "access_list_members",
      "id" => payload["member_id"] || payload[:member_id],
      "attributes" => %{
        "character_eve_id" => payload["character_eve_id"] || payload[:character_eve_id],
        "character_name" => payload["character_name"] || payload[:character_name],
        "role" => payload["role"] || payload[:role],
        "added_at" => event.timestamp
      },
      "relationships" => %{
        "access_list" => %{
          "data" => %{
            "type" => "access_lists",
            "id" => payload["access_list_id"] || payload[:access_list_id]
          }
        },
        "map" => %{
          "data" => %{"type" => "maps", "id" => event.map_id}
        }
      }
    }
  end

  defp format_resource_data(%Event{type: :acl_member_removed, payload: payload} = event) do
    %{
      "type" => "access_list_members",
      "id" => payload["member_id"] || payload[:member_id],
      "meta" => %{
        "deleted" => true,
        "deleted_at" => event.timestamp
      },
      "relationships" => %{
        "access_list" => %{
          "data" => %{
            "type" => "access_lists",
            "id" => payload["access_list_id"] || payload[:access_list_id]
          }
        },
        "map" => %{
          "data" => %{"type" => "maps", "id" => event.map_id}
        }
      }
    }
  end

  defp format_resource_data(%Event{type: :acl_member_updated, payload: payload} = event) do
    %{
      "type" => "access_list_members",
      "id" => payload["member_id"] || payload[:member_id],
      "attributes" => %{
        "role" => payload["role"] || payload[:role],
        "updated_at" => event.timestamp
      },
      "relationships" => %{
        "access_list" => %{
          "data" => %{
            "type" => "access_lists",
            "id" => payload["access_list_id"] || payload[:access_list_id]
          }
        },
        "map" => %{
          "data" => %{"type" => "maps", "id" => event.map_id}
        }
      }
    }
  end

  defp format_resource_data(%Event{type: :map_kill, payload: payload} = event) do
    %{
      "type" => "kills",
      "id" => payload["killmail_id"] || payload[:killmail_id],
      "attributes" => %{
        "killmail_id" => payload["killmail_id"] || payload[:killmail_id],
        "victim_character_name" =>
          payload["victim_character_name"] || payload[:victim_character_name],
        "victim_ship_type" => payload["victim_ship_type"] || payload[:victim_ship_type],
        "occurred_at" => payload["killmail_time"] || payload[:killmail_time] || event.timestamp
      },
      "relationships" => %{
        "system" => %{
          "data" => %{
            "type" => "map_systems",
            "id" => payload["system_id"] || payload[:system_id]
          }
        },
        "map" => %{
          "data" => %{"type" => "maps", "id" => event.map_id}
        }
      }
    }
  end

  defp format_resource_data(%Event{type: :rally_point_added, payload: payload} = event) do
    %{
      "type" => "rally_points",
      "id" => payload["rally_point_id"] || payload[:rally_point_id],
      "attributes" => %{
        "name" => payload["name"] || payload[:name],
        "description" => payload["description"] || payload[:description],
        "created_at" => event.timestamp
      },
      "relationships" => %{
        "system" => %{
          "data" => %{
            "type" => "map_systems",
            "id" => payload["system_id"] || payload[:system_id]
          }
        },
        "map" => %{
          "data" => %{"type" => "maps", "id" => event.map_id}
        }
      }
    }
  end

  defp format_resource_data(%Event{type: :rally_point_removed, payload: payload} = event) do
    %{
      "type" => "rally_points",
      "id" => payload["rally_point_id"] || payload[:rally_point_id],
      "meta" => %{
        "deleted" => true,
        "deleted_at" => event.timestamp
      },
      "relationships" => %{
        "map" => %{
          "data" => %{"type" => "maps", "id" => event.map_id}
        }
      }
    }
  end

  # Generic fallback for unknown event types
  defp format_resource_data(%Event{payload: payload} = event) do
    %{
      "type" => "events",
      "id" => event.id,
      "attributes" => payload,
      "relationships" => %{
        "map" => %{
          "data" => %{"type" => "maps", "id" => event.map_id}
        }
      }
    }
  end

  # --- Payload helpers -------------------------------------------------------
  #
  # These live after the last format_resource_data/1 clause on purpose:
  # interleaving them triggers "clauses with the same name and arity should be
  # grouped together", which `mix compile` reports and `credo` does not.

  # Reads a key from a payload that may be atom-keyed, string-keyed, or a
  # struct. Structs do not implement Access, so `payload[key]` raises for the
  # Api.Character structs that character events broadcast. Using Map.fetch/2
  # rather than `a || b` also preserves `false`, which the previous idiom
  # silently converted to nil.
  defp fetch(payload, key) when is_atom(key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, Atom.to_string(key))
    end
  end

  # Presence check that tolerates both key styles. Needed where an absent key
  # and a present nil mean different things - see the :map_kill clause, whose
  # two variants are distinguished by whether "killmails" was sent at all.
  defp has_key?(payload, key) when is_atom(key) do
    Map.has_key?(payload, key) or Map.has_key?(payload, Atom.to_string(key))
  end

  # JSON:API requires a string id on every resource object.
  defp rid(nil), do: nil
  defp rid(value) when is_binary(value), do: value
  defp rid(value), do: to_string(value)

  # System events identify a map_systems record when the producer sent its
  # UUID. Events broadcast before that producer change - replayed from a
  # queue, say - have no UUID, and a null id is not valid JSON:API. Those fall
  # back to the aggregate shape used by the signature events: the event ULID as
  # identity, under a type that makes no claim to be a UUID-keyed resource.
  defp system_identity(%Event{} = event, payload) do
    case rid(fetch(payload, :system_id)) do
      nil -> {"system_events", event.id}
      system_id -> {"map_systems", system_id}
    end
  end

  defp map_relationship(%Event{map_id: map_id}) do
    relationship("maps", map_id)
  end

  # An empty to-one relationship is represented as "data": null. Emitting
  # %{"type" => t, "id" => nil} instead would be an invalid identifier object.
  defp relationship(type, id) do
    case rid(id) do
      nil -> %{"data" => nil}
      id -> %{"data" => %{"type" => type, "id" => id}}
    end
  end

  # Projects a character payload through @character_attribute_keys. Never pass
  # a character payload through wholesale - it carries OAuth credentials.
  defp character_attrs(payload) do
    Map.new(@character_attribute_keys, fn key ->
      {Atom.to_string(key), fetch(payload, key)}
    end)
  end

  # Legacy event formatting (for events already in map format)
  defp format_legacy_resource_data(event) do
    event_type = event["type"] || "unknown"
    payload = event["payload"] || event
    map_id = event["map_id"]

    case event_type do
      "connected" ->
        %{
          "type" => "connection_status",
          "id" => event["id"] || Ecto.ULID.generate(),
          "attributes" => %{
            "status" => "connected",
            "server_time" => payload["server_time"],
            "connected_at" => payload["server_time"]
          },
          "relationships" => %{
            "map" => %{
              "data" => %{"type" => "maps", "id" => map_id}
            }
          }
        }

      _ ->
        # Use existing payload structure but wrap it in JSON:API format
        %{
          "type" => "events",
          "id" => event["id"] || Ecto.ULID.generate(),
          "attributes" => payload,
          "relationships" => %{
            "map" => %{
              "data" => %{"type" => "maps", "id" => map_id}
            }
          }
        }
    end
  end

  # Event metadata formatting
  defp format_event_meta(%Event{} = event) do
    %{
      "event_type" => event.type,
      "event_action" => determine_action(event.type),
      "timestamp" => DateTime.to_iso8601(event.timestamp),
      "map_id" => event.map_id,
      "event_id" => event.id
    }
  end

  defp format_legacy_event_meta(event) do
    %{
      "event_type" => event["type"],
      "event_action" => determine_legacy_action(event["type"]),
      "timestamp" => event["timestamp"] || DateTime.to_iso8601(DateTime.utc_now()),
      "map_id" => event["map_id"],
      "event_id" => event["id"]
    }
  end

  # Event links formatting
  defp format_event_links(%Event{map_id: map_id}) do
    %{
      "related" => "/api/v1/maps/#{map_id}",
      "self" => "/api/v1/maps/#{map_id}/events/stream"
    }
  end

  defp format_legacy_event_links(event) do
    map_id = event["map_id"]

    %{
      "related" => "/api/v1/maps/#{map_id}",
      "self" => "/api/v1/maps/#{map_id}/events/stream"
    }
  end

  # Helper functions
  defp determine_action(event_type) do
    case event_type do
      type
      when type in [
             :add_system,
             :signature_added,
             :connection_added,
             :character_added,
             :acl_member_added,
             :rally_point_added
           ] ->
        "created"

      type
      when type in [
             :deleted_system,
             :signature_removed,
             :connection_removed,
             :character_removed,
             :acl_member_removed,
             :rally_point_removed
           ] ->
        "deleted"

      type
      when type in [
             :system_renamed,
             :system_metadata_changed,
             :connection_updated,
             :character_updated,
             :acl_member_updated
           ] ->
        "updated"

      :signatures_updated ->
        "bulk_updated"

      :map_kill ->
        "created"

      _ ->
        "unknown"
    end
  end

  defp determine_legacy_action(event_type) do
    case event_type do
      "connected" ->
        "connected"

      _ ->
        try do
          determine_action(String.to_existing_atom(event_type))
        rescue
          ArgumentError -> "unknown"
        end
    end
  end
end
