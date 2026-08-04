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
end
