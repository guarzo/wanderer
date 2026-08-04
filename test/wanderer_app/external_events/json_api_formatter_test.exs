defmodule WandererApp.ExternalEvents.JsonApiFormatterTest do
  use ExUnit.Case, async: true

  alias WandererApp.ExternalEvents.{Event, JsonApiFormatter}

  @map_id "0198f0a1-1111-7000-8000-000000000001"

  defp event(type, payload) do
    %Event{
      id: "01JQXYZ0000000000000000000",
      map_id: @map_id,
      type: type,
      payload: payload,
      timestamp: ~U[2026-08-04 12:00:00Z]
    }
  end

  defp data(type, payload), do: JsonApiFormatter.format_event(event(type, payload))["data"]

  describe "add_system" do
    # Fixture: map_server_systems_impl.ex:673 (post-Task-1 shape)
    test "uses the MapSystem UUID as identity and keeps EVE id as an attribute" do
      d =
        data(:add_system, %{
          system_id: "0198f0a1-2222-7000-8000-000000000002",
          solar_system_id: 31_000_199,
          name: "J123456",
          position_x: 100,
          position_y: 200
        })

      assert d["type"] == "map_systems"
      assert d["id"] == "0198f0a1-2222-7000-8000-000000000002"
      assert d["attributes"]["solar_system_id"] == 31_000_199
      assert d["attributes"]["name"] == "J123456"
      assert d["attributes"]["position_x"] == 100
      assert d["attributes"]["position_y"] == 200
      assert d["relationships"]["map"]["data"] == %{"type" => "maps", "id" => @map_id}
      # The EVE id is data, not identity, and JSON:API forbids an "id" attribute.
      refute d["attributes"]["id"]
      refute d["attributes"]["type"]
    end

    # Fixture: map_server_systems_impl.ex:943 - this call site omits :name
    test "handles the producer variant that omits name" do
      d =
        data(:add_system, %{
          system_id: "0198f0a1-3333-7000-8000-000000000003",
          solar_system_id: 31_000_200,
          position_x: 10,
          position_y: 20
        })

      assert d["id"] == "0198f0a1-3333-7000-8000-000000000003"
      assert d["attributes"]["name"] == nil
      assert d["attributes"]["position_x"] == 10
    end

    # A replayed pre-Task-1 event has no system_id. A null id is not valid
    # JSON:API, so identity falls back to the event ULID under a type that
    # makes no map_systems claim.
    test "falls back to an event-keyed resource when system_id is absent" do
      d = data(:add_system, %{solar_system_id: 31_000_199, position_x: 1, position_y: 2})

      assert d["type"] == "system_events"
      assert d["id"] == "01JQXYZ0000000000000000000"
      assert d["attributes"]["solar_system_id"] == 31_000_199
    end

    test "accepts string-keyed payloads" do
      d = data(:add_system, %{"system_id" => "abc", "solar_system_id" => 31_000_199})
      assert d["id"] == "abc"
      assert d["attributes"]["solar_system_id"] == 31_000_199
    end

    test "stringifies a non-string id" do
      d = data(:add_system, %{system_id: 12_345, solar_system_id: 31_000_199})
      assert d["id"] == "12345"
    end
  end

  describe "deleted_system" do
    # Fixture: map_server_systems_impl.ex:385 - name/position are deliberately nil
    test "marks deletion and preserves the producer's intentional nils" do
      d =
        data(:deleted_system, %{
          system_id: "0198f0a1-4444-7000-8000-000000000004",
          solar_system_id: 31_000_199,
          name: nil,
          position_x: nil,
          position_y: nil
        })

      assert d["type"] == "map_systems"
      assert d["id"] == "0198f0a1-4444-7000-8000-000000000004"
      assert d["attributes"]["solar_system_id"] == 31_000_199
      assert d["meta"]["deleted"] == true
      assert d["meta"]["deleted_at"] == ~U[2026-08-04 12:00:00Z]
    end
  end

  describe "system_metadata_changed" do
    # Fixture: map_server_systems_impl.ex:1187
    test "renders every metadata attribute the producer sends" do
      d =
        data(:system_metadata_changed, %{
          system_id: "0198f0a1-5555-7000-8000-000000000005",
          solar_system_id: 31_000_199,
          name: "J123456",
          temporary_name: "Home",
          labels: "dead end",
          description: "staging",
          status: 1,
          locked: false,
          position_x: 5,
          position_y: 6
        })

      assert d["type"] == "map_systems"
      assert d["id"] == "0198f0a1-5555-7000-8000-000000000005"
      assert d["attributes"]["temporary_name"] == "Home"
      assert d["attributes"]["labels"] == "dead end"
      assert d["attributes"]["description"] == "staging"
      assert d["attributes"]["status"] == 1
      # Regression: `payload["locked"] || payload[:locked]` turned false into nil.
      assert d["attributes"]["locked"] == false
    end
  end

  describe "signature events" do
    # Fixture: map_server_signatures_impl.ex:148
    test "signature_added uses the event ULID as identity, not the EVE sig code" do
      d =
        data(:signature_added, %{
          solar_system_id: 31_000_199,
          signature_id: "ABC-123",
          name: "Unstable Wormhole",
          kind: "cosmic_signature",
          group: "wormhole",
          type: "K162"
        })

      assert d["type"] == "signature_events"
      assert d["id"] == "01JQXYZ0000000000000000000"
      assert d["attributes"]["signature_id"] == "ABC-123"
      assert d["attributes"]["solar_system_id"] == 31_000_199
      assert d["attributes"]["kind"] == "cosmic_signature"
      assert d["attributes"]["group"] == "wormhole"
      # Producer key :type, renamed because JSON:API reserves "type".
      assert d["attributes"]["signature_type"] == "K162"
      refute Map.has_key?(d["attributes"], "type")
      refute Map.has_key?(d["attributes"], "id")
      # No relationship may point at a map_system_signatures record we cannot name.
      refute Map.has_key?(d["relationships"], "signature")
    end

    # Fixture: map_server_signatures_impl.ex:159 - only two keys are sent
    test "signature_removed marks deletion with the sparse producer payload" do
      d = data(:signature_removed, %{solar_system_id: 31_000_199, signature_id: "ABC-123"})

      assert d["type"] == "signature_events"
      assert d["id"] == "01JQXYZ0000000000000000000"
      assert d["attributes"]["signature_id"] == "ABC-123"
      assert d["meta"]["deleted"] == true
    end

    # Fixture: map_server_signatures_impl.ex:166 and :250 (same shape)
    test "signatures_updated summarises counts instead of hitting the catch-all" do
      d =
        data(:signatures_updated, %{
          solar_system_id: 31_000_199,
          added_count: 2,
          updated_count: 1,
          removed_count: 0
        })

      assert d["type"] == "signature_updates"
      assert d["id"] == "01JQXYZ0000000000000000000"
      assert d["attributes"]["added_count"] == 2
      assert d["attributes"]["updated_count"] == 1
      assert d["attributes"]["removed_count"] == 0
      assert d["attributes"]["solar_system_id"] == 31_000_199
    end
  end

  describe "connection events" do
    # Fixture: map_server_connections_impl.ex:779
    test "connection_added reads solar_system_source_id, not solar_system_source" do
      d =
        data(:connection_added, %{
          connection_id: "0198f0a1-6666-7000-8000-000000000006",
          solar_system_source_id: 31_000_199,
          solar_system_target_id: 31_000_200,
          type: 0,
          ship_size_type: 2,
          mass_status: 0,
          time_status: 0
        })

      assert d["type"] == "map_connections"
      assert d["id"] == "0198f0a1-6666-7000-8000-000000000006"
      assert d["attributes"]["solar_system_source_id"] == 31_000_199
      assert d["attributes"]["solar_system_target_id"] == 31_000_200
      assert d["attributes"]["ship_size_type"] == 2
      # Producer key :type, renamed because JSON:API reserves "type".
      assert d["attributes"]["connection_type"] == 0
      refute Map.has_key?(d["attributes"], "type")
      # EVE system ids are attributes; they must not become relationship ids.
      assert d["relationships"] == %{"map" => %{"data" => %{"type" => "maps", "id" => @map_id}}}
    end

    # Fixture: map_server_connections_impl.ex:1161
    test "connection_updated preserves locked: false" do
      d =
        data(:connection_updated, %{
          connection_id: "0198f0a1-7777-7000-8000-000000000007",
          solar_system_source_id: 31_000_199,
          solar_system_target_id: 31_000_200,
          type: 0,
          ship_size_type: 2,
          mass_status: 1,
          time_status: 0,
          locked: false,
          custom_info: "eol"
        })

      assert d["id"] == "0198f0a1-7777-7000-8000-000000000007"
      assert d["attributes"]["locked"] == false
      assert d["attributes"]["custom_info"] == "eol"
      assert d["attributes"]["mass_status"] == 1
    end

    # Fixture: map_server_connections_impl.ex:1104 - three keys only
    test "connection_removed marks deletion and keeps both endpoints" do
      d =
        data(:connection_removed, %{
          connection_id: "0198f0a1-8888-7000-8000-000000000008",
          solar_system_source_id: 31_000_199,
          solar_system_target_id: 31_000_200
        })

      assert d["type"] == "map_connections"
      assert d["id"] == "0198f0a1-8888-7000-8000-000000000008"
      assert d["attributes"]["solar_system_source_id"] == 31_000_199
      assert d["meta"]["deleted"] == true
    end
  end

  describe "character events" do
    # Fixture: map_server_characters_impl.ex:1037 broadcasts an Api.Character
    # struct, which carries OAuth tokens.
    defp character_struct do
      %WandererApp.Api.Character{
        id: "0198f0a1-9999-7000-8000-000000000009",
        eve_id: "2112625428",
        name: "Test Pilot",
        corporation_id: 98_000_001,
        corporation_ticker: "TEST",
        alliance_id: 99_000_001,
        ship_name: "Astero",
        solar_system_id: 31_000_199,
        online: false,
        access_token: "SECRET-ACCESS-TOKEN",
        refresh_token: "SECRET-REFRESH-TOKEN",
        character_owner_hash: "SECRET-OWNER-HASH"
      }
    end

    test "character_added does not raise on a struct payload" do
      d = data(:character_added, character_struct())

      assert d["type"] == "characters"
      assert d["id"] == "0198f0a1-9999-7000-8000-000000000009"
      assert d["attributes"]["eve_id"] == "2112625428"
      assert d["attributes"]["name"] == "Test Pilot"
      assert d["attributes"]["corporation_ticker"] == "TEST"
      assert d["attributes"]["solar_system_id"] == 31_000_199
      # Regression: `payload["online"] || payload[:online]` turned false into nil.
      assert d["attributes"]["online"] == false
      # JSON:API forbids reserved attribute names; the UUID is the identity.
      refute Map.has_key?(d["attributes"], "id")
      refute Map.has_key?(d["attributes"], "type")
    end

    # Fixture: map_server_characters_impl.ex:486 sends a list of structs
    test "characters_updated emits one resource per character" do
      a = character_struct()
      b = %{character_struct() | id: "0198f0a1-aaaa-7000-8000-00000000000a", name: "Second"}

      d = data(:characters_updated, %{characters: [a, b], timestamp: ~U[2026-08-04 12:00:00Z]})

      assert is_list(d)
      assert length(d) == 2

      assert Enum.map(d, & &1["id"]) == [
               "0198f0a1-9999-7000-8000-000000000009",
               "0198f0a1-aaaa-7000-8000-00000000000a"
             ]

      assert Enum.map(d, & &1["attributes"]["name"]) == ["Test Pilot", "Second"]
      assert Enum.all?(d, &(&1["type"] == "characters"))
    end

    test "characters_updated handles an empty list" do
      assert data(:characters_updated, %{characters: [], timestamp: nil}) == []
    end

    for event_type <- [:character_added, :character_removed, :character_updated] do
      test "#{event_type} never leaks OAuth tokens" do
        rendered = inspect(data(unquote(event_type), character_struct()), limit: :infinity)

        refute rendered =~ "SECRET-ACCESS-TOKEN"
        refute rendered =~ "SECRET-REFRESH-TOKEN"
        refute rendered =~ "SECRET-OWNER-HASH"
        refute rendered =~ "access_token"
        refute rendered =~ "refresh_token"
        refute rendered =~ "character_owner_hash"
      end
    end

    test "characters_updated never leaks OAuth tokens" do
      rendered =
        inspect(data(:characters_updated, %{characters: [character_struct()], timestamp: nil}),
          limit: :infinity
        )

      refute rendered =~ "SECRET-ACCESS-TOKEN"
      refute rendered =~ "SECRET-REFRESH-TOKEN"
      refute rendered =~ "SECRET-OWNER-HASH"
      refute rendered =~ "access_token"
      refute rendered =~ "refresh_token"
      refute rendered =~ "character_owner_hash"
    end

    test "character_removed marks removal" do
      d = data(:character_removed, character_struct())

      assert d["type"] == "characters"
      assert d["id"] == "0198f0a1-9999-7000-8000-000000000009"
      assert d["meta"]["removed"] == true
    end
  end

  describe "acl member events" do
    # Fixture: acl_event_broadcaster.ex:52
    defp acl_payload do
      %{
        acl_id: "0198f0a1-bbbb-7000-8000-00000000000b",
        member_id: "0198f0a1-cccc-7000-8000-00000000000c",
        member_name: "Test Pilot",
        member_type: "character",
        eve_id: "2112625428",
        role: "member"
      }
    end

    test "acl_member_added reads member_name and eve_id, not character_*" do
      d = data(:acl_member_added, acl_payload())

      assert d["type"] == "access_list_members"
      assert d["id"] == "0198f0a1-cccc-7000-8000-00000000000c"
      assert d["attributes"]["member_name"] == "Test Pilot"
      assert d["attributes"]["eve_id"] == "2112625428"
      assert d["attributes"]["member_type"] == "character"
      assert d["attributes"]["role"] == "member"

      assert d["relationships"]["access_list"]["data"] == %{
               "type" => "access_lists",
               "id" => "0198f0a1-bbbb-7000-8000-00000000000b"
             }
    end

    test "acl_member_updated reads acl_id for the access_list relationship" do
      d = data(:acl_member_updated, acl_payload())

      assert d["attributes"]["role"] == "member"

      assert d["relationships"]["access_list"]["data"]["id"] ==
               "0198f0a1-bbbb-7000-8000-00000000000b"
    end

    test "acl_member_removed marks deletion" do
      d = data(:acl_member_removed, acl_payload())

      assert d["id"] == "0198f0a1-cccc-7000-8000-00000000000c"
      assert d["meta"]["deleted"] == true

      assert d["relationships"]["access_list"]["data"]["id"] ==
               "0198f0a1-bbbb-7000-8000-00000000000b"
    end
  end

  describe "rally point events" do
    # Fixture: map_server_pings_impl.ex:41
    test "rally_point_added keeps the real system UUID relationship" do
      d =
        data(:rally_point_added, %{
          rally_point_id: "0198f0a1-dddd-7000-8000-00000000000d",
          solar_system_id: 31_000_199,
          system_id: "0198f0a1-eeee-7000-8000-00000000000e",
          character_id: "0198f0a1-ffff-7000-8000-00000000000f",
          character_name: "Test Pilot",
          character_eve_id: "2112625428",
          system_name: "J123456",
          message: "form up",
          created_at: ~U[2026-08-04 11:00:00Z]
        })

      assert d["type"] == "rally_points"
      assert d["id"] == "0198f0a1-dddd-7000-8000-00000000000d"
      assert d["attributes"]["message"] == "form up"
      assert d["attributes"]["character_name"] == "Test Pilot"
      assert d["attributes"]["system_name"] == "J123456"
      assert d["attributes"]["solar_system_id"] == 31_000_199

      assert d["relationships"]["system"]["data"] == %{
               "type" => "map_systems",
               "id" => "0198f0a1-eeee-7000-8000-00000000000e"
             }
    end

    # Fixture: map_server_pings_impl.ex:94 - the id key is :id, not :rally_point_id
    test "rally_point_removed reads :id" do
      d =
        data(:rally_point_removed, %{
          id: "0198f0a1-dddd-7000-8000-00000000000d",
          solar_system_id: 31_000_199,
          system_id: "0198f0a1-eeee-7000-8000-00000000000e",
          character_id: "0198f0a1-ffff-7000-8000-00000000000f",
          character_name: "Test Pilot",
          character_eve_id: "2112625428",
          system_name: "J123456"
        })

      assert d["type"] == "rally_points"
      assert d["id"] == "0198f0a1-dddd-7000-8000-00000000000d"
      assert d["meta"]["deleted"] == true

      assert d["relationships"]["system"]["data"]["id"] ==
               "0198f0a1-eeee-7000-8000-00000000000e"
    end
  end

  describe "map_kill" do
    # Fixture: kills/message_handler.ex:126 (batch) and :298-350 (kill element)
    defp killmail(id) do
      %{
        "killmail_id" => id,
        "kill_time" => "2026-08-04T11:59:00Z",
        "solar_system_id" => 31_000_199,
        "victim_char_id" => 2_112_625_428,
        "victim_char_name" => "Victim #{id}",
        "victim_corp_ticker" => "TEST",
        "victim_corp_name" => "Test Corp",
        "victim_alliance_ticker" => "TSTA",
        "victim_alliance_name" => "Test Alliance",
        "victim_ship_type_id" => 587,
        "victim_ship_name" => "Rifter",
        "final_blow_char_name" => "Killer",
        "attacker_count" => 3,
        "total_value" => 12_500_000.0,
        "npc" => false
      }
    end

    test "a batch of three kills yields three distinct resources" do
      d =
        data(:map_kill, %{
          "solar_system_id" => 31_000_199,
          "killmails" => [killmail(1), killmail(2), killmail(3)],
          "timestamp" => "2026-08-04T12:00:00Z",
          "type" => :killmail_update
        })

      assert is_list(d)
      assert length(d) == 3
      assert Enum.map(d, & &1["id"]) == ["1", "2", "3"]
      # Each resource carries its own kill, not the first kill repeated.
      assert Enum.map(d, & &1["attributes"]["victim_char_name"]) == [
               "Victim 1",
               "Victim 2",
               "Victim 3"
             ]

      first = hd(d)
      assert first["type"] == "kills"
      assert first["attributes"]["victim_ship_type_id"] == 587
      assert first["attributes"]["attacker_count"] == 3
      assert first["attributes"]["total_value"] == 12_500_000.0
      # Regression: `npc || nil` turned false into nil.
      assert first["attributes"]["npc"] == false
      # The batch's solar_system_id is authoritative - it routed the event here.
      assert first["attributes"]["solar_system_id"] == 31_000_199
    end

    test "an empty batch yields an empty array" do
      assert data(:map_kill, %{"solar_system_id" => 31_000_199, "killmails" => []}) == []
    end

    # Dispatch is on key presence, not value: a malformed batch is still a
    # batch, not a kill count.
    test "a present-but-nil killmails key is an empty batch, not a count" do
      d = data(:map_kill, %{"solar_system_id" => 31_000_199, "killmails" => nil, "count" => 7})
      assert d == []
    end

    # validate_flat_format_kill/1 (message_handler.ex:247) checks required
    # fields via validate_required_fields/2, which tests presence with
    # Map.has_key?/2 (:444), so a present-but-nil "killmail_id" is
    # broadcast. A kills resource has no identity other than that id, and
    # fabricating one - event.id, say - would collide across the batch, so
    # the element is dropped rather than emitted with a null id.
    test "a killmail with a nil id is skipped rather than emitted with a null id" do
      d =
        data(:map_kill, %{
          "solar_system_id" => 31_000_199,
          "killmails" => [killmail(1), %{killmail(2) | "killmail_id" => nil}]
        })

      assert length(d) == 1
      assert hd(d)["id"] == "1"
      assert hd(d)["attributes"]["victim_char_name"] == "Victim 1"
      refute Enum.any?(d, &is_nil(&1["id"]))
    end

    test "a batch whose killmails all lack ids yields an empty array" do
      d =
        data(:map_kill, %{
          "solar_system_id" => 31_000_199,
          "killmails" => [%{killmail(1) | "killmail_id" => nil}]
        })

      assert d == []
    end

    # Fixture: kills/message_handler.ex:111 - no killmails key at all
    test "the kill_count variant keeps the count instead of being discarded" do
      d =
        data(:map_kill, %{
          "solar_system_id" => 31_000_199,
          "count" => 7,
          "type" => :kill_count
        })

      refute is_list(d)
      assert d["type"] == "kill_counts"
      assert d["id"] == "01JQXYZ0000000000000000000"
      assert d["attributes"]["count"] == 7
      assert d["attributes"]["solar_system_id"] == 31_000_199
    end
  end

  describe "event meta" do
    # Both bulk event types summarise many records under one event, so they
    # share an action vocabulary rather than one of them being "unknown".
    test "the bulk event types report bulk_updated" do
      meta = fn type, payload ->
        JsonApiFormatter.format_event(event(type, payload))["meta"]["event_action"]
      end

      assert meta.(:signatures_updated, %{solar_system_id: 31_000_199}) == "bulk_updated"
      assert meta.(:characters_updated, %{characters: [], timestamp: nil}) == "bulk_updated"
    end
  end

  describe "module-wide invariants" do
    # Every event type declared by Event.event_type/0, with a representative
    # producer-shaped payload.
    defp all_event_fixtures do
      char = %WandererApp.Api.Character{
        id: "0198f0a1-9999-7000-8000-000000000009",
        eve_id: "2112625428",
        name: "Test Pilot",
        online: false,
        access_token: "SECRET-ACCESS-TOKEN"
      }

      [
        {:add_system, %{system_id: "u1", solar_system_id: 31_000_199}},
        # Replayed pre-Task-1 payload: no system_id, must still be compliant.
        {:add_system, %{solar_system_id: 31_000_199}},
        {:deleted_system, %{system_id: "u1", solar_system_id: 31_000_199}},
        {:system_renamed, %{system_id: "u1", name: "J1"}},
        {:system_metadata_changed, %{system_id: "u1", solar_system_id: 31_000_199}},
        {:signature_added, %{solar_system_id: 31_000_199, signature_id: "ABC-123"}},
        {:signature_removed, %{solar_system_id: 31_000_199, signature_id: "ABC-123"}},
        {:signatures_updated,
         %{solar_system_id: 31_000_199, added_count: 1, updated_count: 0, removed_count: 0}},
        {:connection_added,
         %{connection_id: "u2", solar_system_source_id: 1, solar_system_target_id: 2}},
        {:connection_removed,
         %{connection_id: "u2", solar_system_source_id: 1, solar_system_target_id: 2}},
        {:connection_updated,
         %{connection_id: "u2", solar_system_source_id: 1, solar_system_target_id: 2}},
        {:character_added, char},
        {:character_removed, char},
        {:character_updated, char},
        {:characters_updated, %{characters: [char], timestamp: nil}},
        {:map_kill, %{"solar_system_id" => 31_000_199, "killmails" => [killmail(1)]}},
        # The same event type also carries a count-only payload with no
        # "killmails" key, which renders as a different resource. Without
        # this fixture no invariant below ever runs over that shape.
        {:map_kill, %{"solar_system_id" => 31_000_199, "count" => 7, "type" => :kill_count}},
        # acl_event_broadcaster.ex:52 sends the same payload shape - acl_id,
        # member_id, member_name, member_type, eve_id, role - for all three
        # ACL event types, so all three fixtures carry it.
        {:acl_member_added,
         %{
           member_id: "u3",
           acl_id: "u4",
           member_name: "Test Pilot",
           member_type: "character",
           eve_id: "2112625428"
         }},
        {:acl_member_removed,
         %{
           member_id: "u3",
           acl_id: "u4",
           member_name: "Test Pilot",
           member_type: "character",
           eve_id: "2112625428"
         }},
        {:acl_member_updated,
         %{
           member_id: "u3",
           acl_id: "u4",
           member_name: "Test Pilot",
           member_type: "character",
           eve_id: "2112625428",
           role: "member"
         }},
        # solar_system_id matches the EVE-id sentinel used below so the
        # "no EVE id as a relationship identifier" invariant has something to
        # bite on for the rally-point "system" relationship.
        {:rally_point_added,
         %{rally_point_id: "u5", system_id: "u6", solar_system_id: 31_000_199}},
        {:rally_point_removed, %{id: "u5", system_id: "u6", solar_system_id: 31_000_199}}
      ]
    end

    defp resources(d) when is_list(d), do: d
    defp resources(d), do: [d]

    # Every invariant below is a loop over all_event_fixtures/0, so a new
    # event type with no fixture would be silently exempt from all of them.
    test "the fixture list covers every supported event type" do
      assert MapSet.new(all_event_fixtures(), &elem(&1, 0)) ==
               MapSet.new(Event.supported_event_types())
    end

    test "every event type is handled without raising" do
      for {type, payload} <- all_event_fixtures() do
        assert %{"data" => _, "meta" => _, "links" => _} =
                 JsonApiFormatter.format_event(event(type, payload)),
               "#{type} failed to format"
      end
    end

    test "no event type falls through to the generic events fallback" do
      for {type, payload} <- all_event_fixtures() do
        for resource <- resources(data(type, payload)) do
          refute resource["type"] == "events",
                 "#{type} fell through to the generic fallback"
        end
      end
    end

    test "every resource id is a string" do
      for {type, payload} <- all_event_fixtures() do
        for resource <- resources(data(type, payload)) do
          assert is_binary(resource["id"]), "#{type} emitted a non-string id"
        end
      end
    end

    test "every relationship is a valid identifier object or an explicit null" do
      for {type, payload} <- all_event_fixtures() do
        for resource <- resources(data(type, payload)),
            {name, rel} <- resource["relationships"] || %{} do
          assert Map.has_key?(rel, "data"), "#{type} relationship #{name} has no data member"

          case rel["data"] do
            nil ->
              :ok

            %{"type" => rel_type, "id" => id} ->
              assert is_binary(rel_type) and is_binary(id),
                     "#{type} relationship #{name} emitted a non-string type or id"

            other ->
              flunk("#{type} relationship #{name} emitted #{inspect(other)}")
          end
        end
      end
    end

    # None of the fixtures above ever supply a nil to-one relationship id -
    # acl_id and system_id are always present in the real producer payloads -
    # so the null branch of the previous test never executes against them.
    # This exercises it directly against the shared `relationship/2` helper.
    test "an absent to-one relationship id emits an explicit null, not a null-id identifier" do
      d = data(:acl_member_added, %{member_id: "u3", acl_id: nil, eve_id: "2112625428"})
      assert d["relationships"]["access_list"] == %{"data" => nil}
    end

    test "no resource uses a reserved attribute name" do
      for {type, payload} <- all_event_fixtures() do
        for resource <- resources(data(type, payload)) do
          attrs = resource["attributes"] || %{}

          refute Map.has_key?(attrs, "id"), "#{type} has a reserved \"id\" attribute"
          refute Map.has_key?(attrs, "type"), "#{type} has a reserved \"type\" attribute"
        end
      end
    end

    test "no EVE solar system id is used as a relationship identifier" do
      for {type, payload} <- all_event_fixtures() do
        for resource <- resources(data(type, payload)),
            {name, rel} <- resource["relationships"] || %{} do
          refute rel["data"]["id"] == "31000199",
                 "#{type} relationship #{name} used an EVE id as an identifier"
        end
      end
    end

    test "no event type leaks an OAuth token" do
      for {type, payload} <- all_event_fixtures() do
        rendered = inspect(data(type, payload), limit: :infinity)
        refute rendered =~ "SECRET-ACCESS-TOKEN", "#{type} leaked an access token"
      end
    end

    # Timestamps the formatter injects itself from event.timestamp rather than
    # reading them from the payload, so they are never nil. Left in, they would
    # single-handedly satisfy the refute below for every fixture whose clause
    # injects one - defeating the invariant exactly where it is most needed.
    @formatter_injected_timestamps ~w(created_at updated_at added_at deleted_at removed_at)

    # This is the original bug's signature: a clause reading payload keys its
    # producer never sends renders every attribute as null while still
    # returning a well-formed-looking resource object. None of the invariants
    # above would catch it - a resource can have a string id, no reserved
    # names, and no bad relationships while still being empty of information.
    test "no resource has an attributes map that is entirely null-valued" do
      for {type, payload} <- all_event_fixtures() do
        for resource <- resources(data(type, payload)) do
          attrs = Map.drop(resource["attributes"] || %{}, @formatter_injected_timestamps)

          refute attrs != %{} and Enum.all?(Map.values(attrs), &is_nil/1),
                 "#{type} emitted an attributes map with every value nil"
        end
      end
    end
  end
end
