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
    # Fixture: map_server_systems_impl.ex:635 (post-Task-1 shape)
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

    # Fixture: map_server_systems_impl.ex:899 - this call site omits :name
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
    # Fixture: map_server_systems_impl.ex:348 - name/position are deliberately nil
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
    # Fixture: map_server_systems_impl.ex:1115
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
    # Fixture: map_server_connections_impl.ex:748
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

    # Fixture: map_server_connections_impl.ex:1140
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

    # Fixture: map_server_connections_impl.ex:1083 - three keys only
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
    # Fixture: map_server_characters_impl.ex:1030 broadcasts an Api.Character
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

    # Fixture: map_server_characters_impl.ex:485 sends a list of structs
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
end
