defmodule WandererApp.ExternalEvents.JsonApiFormatterTest do
  use ExUnit.Case, async: true

  alias WandererApp.ExternalEvents.Event
  alias WandererApp.ExternalEvents.JsonApiFormatter

  # Keys copied from `MessageHandler.add_core_kill_data/3` and
  # `add_victim_data/2` (lib/wanderer_app/kills/message_handler.ex:298-322),
  # which is the only producer of `:map_kill` payloads.
  defp flattened_kill do
    %{
      "killmail_id" => 120_000_001,
      "kill_time" => "2026-08-03T12:34:56Z",
      "solar_system_id" => 31_000_005,
      "victim_char_id" => 95_000_001,
      "victim_char_name" => "Some Pilot",
      "victim_corp_id" => 98_000_001,
      "victim_corp_ticker" => "KARMA",
      "victim_ship_type_id" => 670,
      "victim_ship_name" => "Capsule",
      "attacker_count" => 3,
      "total_value" => 1_234_567.0,
      "npc" => false
    }
  end

  defp kill_event(payload) do
    %Event{
      id: "evt-1",
      map_id: "11111111-1111-1111-1111-111111111111",
      type: :map_kill,
      payload: payload,
      timestamp: ~U[2026-08-03 23:59:59Z]
    }
  end

  test "populates victim attributes from the flattened killmail keys" do
    %{"data" => data} = JsonApiFormatter.format_event(kill_event(flattened_kill()))

    assert data["type"] == "kills"
    assert data["id"] == 120_000_001
    assert data["attributes"]["killmail_id"] == 120_000_001
    assert data["attributes"]["victim_character_name"] == "Some Pilot"
    assert data["attributes"]["victim_ship_type"] == "Capsule"
  end

  test "occurred_at is the kill time, not the broadcast time" do
    %{"data" => data} = JsonApiFormatter.format_event(kill_event(flattened_kill()))

    assert data["attributes"]["occurred_at"] == "2026-08-03T12:34:56Z"
    refute data["attributes"]["occurred_at"] == ~U[2026-08-03 23:59:59Z]
  end

  test "the system relationship carries the solar system id" do
    %{"data" => data} = JsonApiFormatter.format_event(kill_event(flattened_kill()))

    assert data["relationships"]["system"]["data"] == %{
             "type" => "map_systems",
             "id" => 31_000_005
           }
  end

  test "falls back to the broadcast timestamp when the kill time is missing" do
    payload = Map.delete(flattened_kill(), "kill_time")

    %{"data" => data} = JsonApiFormatter.format_event(kill_event(payload))

    assert data["attributes"]["occurred_at"] == ~U[2026-08-03 23:59:59Z]
  end

  test "atom-keyed payloads are still supported" do
    payload = %{
      killmail_id: 120_000_002,
      kill_time: "2026-08-03T01:02:03Z",
      solar_system_id: 31_000_006,
      victim_char_name: "Atom Pilot",
      victim_ship_name: "Rifter"
    }

    %{"data" => data} = JsonApiFormatter.format_event(kill_event(payload))

    assert data["attributes"]["victim_character_name"] == "Atom Pilot"
    assert data["attributes"]["victim_ship_type"] == "Rifter"
    assert data["attributes"]["occurred_at"] == "2026-08-03T01:02:03Z"
    assert data["relationships"]["system"]["data"]["id"] == 31_000_006
  end
end
