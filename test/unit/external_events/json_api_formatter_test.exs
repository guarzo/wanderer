defmodule WandererApp.ExternalEvents.JsonApiFormatterTest do
  use ExUnit.Case, async: true

  alias WandererApp.ExternalEvents.Event
  alias WandererApp.ExternalEvents.JsonApiFormatter

  @map_id "11111111-1111-1111-1111-111111111111"
  @batch_system_id 31_000_005
  @broadcast_time ~U[2026-08-03 23:59:59Z]

  # A `:map_kill` payload is a BATCH. Shape copied from
  # `MessageHandler.broadcast_killmails/3` (lib/wanderer_app/kills/
  # message_handler.ex:126-131): a top-level system id, a `"killmails"` list and
  # a batch timestamp.
  defp kill_batch(killmails) do
    %{
      "solar_system_id" => @batch_system_id,
      "killmails" => killmails,
      "timestamp" => "2026-08-03T12:35:00Z",
      "type" => :killmail_update
    }
  end

  # Keys copied from `MessageHandler.add_core_kill_data/3` and
  # `add_victim_data/2` (same file, lines 298-322), which is the only producer
  # of the killmails inside a batch.
  defp flattened_kill(overrides \\ %{}) do
    Map.merge(
      %{
        "killmail_id" => 120_000_001,
        "kill_time" => "2026-08-03T12:34:56Z",
        "solar_system_id" => @batch_system_id,
        "victim_char_id" => 95_000_001,
        "victim_char_name" => "Some Pilot",
        "victim_corp_id" => 98_000_001,
        "victim_corp_ticker" => "KARMA",
        "victim_ship_type_id" => 670,
        "victim_ship_name" => "Capsule",
        "attacker_count" => 3,
        "total_value" => 1_234_567.0,
        "npc" => false
      },
      overrides
    )
  end

  defp kill_event(payload) do
    %Event{
      id: "evt-1",
      map_id: @map_id,
      type: :map_kill,
      payload: payload,
      timestamp: @broadcast_time
    }
  end

  describe "a batch of one kill" do
    test "emits a single resource carrying that kill's own attributes" do
      %{"data" => data} =
        JsonApiFormatter.format_event(kill_event(kill_batch([flattened_kill()])))

      assert [resource] = data
      assert resource["type"] == "kills"
      assert resource["id"] == 120_000_001
      assert resource["attributes"]["killmail_id"] == 120_000_001
      assert resource["attributes"]["victim_character_name"] == "Some Pilot"
      assert resource["attributes"]["victim_ship_type"] == "Capsule"
    end

    test "occurred_at is the kill time, not the broadcast time" do
      %{"data" => [resource]} =
        JsonApiFormatter.format_event(kill_event(kill_batch([flattened_kill()])))

      assert resource["attributes"]["occurred_at"] == "2026-08-03T12:34:56Z"
      refute resource["attributes"]["occurred_at"] == @broadcast_time
    end

    test "falls back to the broadcast timestamp when that kill has no kill time" do
      kill = Map.delete(flattened_kill(), "kill_time")

      %{"data" => [resource]} = JsonApiFormatter.format_event(kill_event(kill_batch([kill])))

      assert resource["attributes"]["occurred_at"] == @broadcast_time
    end

    test "the relationships point at the batch's system and the event's map" do
      %{"data" => [resource]} =
        JsonApiFormatter.format_event(kill_event(kill_batch([flattened_kill()])))

      assert resource["relationships"]["system"]["data"] == %{
               "type" => "map_systems",
               "id" => @batch_system_id
             }

      assert resource["relationships"]["map"]["data"] == %{"type" => "maps", "id" => @map_id}
    end

    test "the system relationship stays on the batch's system id even when the kill disagrees" do
      # Deliberate: only the batch's id is guaranteed to be a system this map
      # contains, because it is what routed the event here.
      kill = flattened_kill(%{"solar_system_id" => 30_000_142})

      %{"data" => [resource]} = JsonApiFormatter.format_event(kill_event(kill_batch([kill])))

      assert resource["relationships"]["system"]["data"]["id"] == @batch_system_id
    end

    test "atom-keyed batches and kills are still supported" do
      payload = %{
        solar_system_id: 31_000_006,
        killmails: [
          %{
            killmail_id: 120_000_002,
            kill_time: "2026-08-03T01:02:03Z",
            victim_char_name: "Atom Pilot",
            victim_ship_name: "Rifter"
          }
        ]
      }

      %{"data" => [resource]} = JsonApiFormatter.format_event(kill_event(payload))

      assert resource["id"] == 120_000_002
      assert resource["attributes"]["victim_character_name"] == "Atom Pilot"
      assert resource["attributes"]["victim_ship_type"] == "Rifter"
      assert resource["attributes"]["occurred_at"] == "2026-08-03T01:02:03Z"
      assert resource["relationships"]["system"]["data"]["id"] == 31_000_006
    end
  end

  describe "a batch of several kills" do
    test "emits one resource per killmail, in batch order" do
      batch =
        kill_batch([
          flattened_kill(%{
            "killmail_id" => 1,
            "victim_char_name" => "First",
            "victim_ship_name" => "Astero",
            "kill_time" => "2026-08-03T12:00:00Z"
          }),
          flattened_kill(%{
            "killmail_id" => 2,
            "victim_char_name" => "Second",
            "victim_ship_name" => "Loki",
            "kill_time" => "2026-08-03T12:01:00Z"
          }),
          flattened_kill(%{
            "killmail_id" => 3,
            "victim_char_name" => "Third",
            "victim_ship_name" => "Venture",
            "kill_time" => "2026-08-03T12:02:00Z"
          })
        ])

      %{"data" => data} = JsonApiFormatter.format_event(kill_event(batch))

      assert length(data) == 3
      assert Enum.map(data, & &1["id"]) == [1, 2, 3]

      assert Enum.map(data, & &1["attributes"]["victim_character_name"]) == [
               "First",
               "Second",
               "Third"
             ]

      assert Enum.map(data, & &1["attributes"]["victim_ship_type"]) == [
               "Astero",
               "Loki",
               "Venture"
             ]

      assert Enum.map(data, & &1["attributes"]["occurred_at"]) == [
               "2026-08-03T12:00:00Z",
               "2026-08-03T12:01:00Z",
               "2026-08-03T12:02:00Z"
             ]
    end

    test "every resource is fully populated - no nil ids or attributes" do
      batch = kill_batch([flattened_kill(%{"killmail_id" => 7}), flattened_kill()])

      %{"data" => data} = JsonApiFormatter.format_event(kill_event(batch))

      for resource <- data do
        refute is_nil(resource["id"])
        refute is_nil(resource["attributes"]["killmail_id"])
        refute is_nil(resource["attributes"]["victim_character_name"])
        refute is_nil(resource["attributes"]["victim_ship_type"])
      end
    end
  end

  describe "degenerate batches" do
    test "an empty killmails list formats as an empty collection" do
      %{"data" => data} = JsonApiFormatter.format_event(kill_event(kill_batch([])))

      assert data == []
    end

    test "a kill missing killmail_id is dropped, the rest of the batch survives" do
      # The resource id IS the killmail id; a resource without one is not
      # addressable, so it cannot be emitted. Dropping it must not cost the
      # kills either side of it.
      batch =
        kill_batch([
          flattened_kill(%{"killmail_id" => 11}),
          Map.delete(flattened_kill(), "killmail_id"),
          flattened_kill(%{"killmail_id" => 13})
        ])

      %{"data" => data} = JsonApiFormatter.format_event(kill_event(batch))

      assert Enum.map(data, & &1["id"]) == [11, 13]
    end

    test "a batch of only unidentifiable kills formats as an empty collection" do
      batch = kill_batch([Map.delete(flattened_kill(), "killmail_id")])

      %{"data" => data} = JsonApiFormatter.format_event(kill_event(batch))

      assert data == []
    end

    test "an absent killmails key is not a batch and keeps the generic event shape" do
      # `MessageHandler.broadcast_kill_count/2` reuses `:map_kill` for
      # kill-count updates: a system id and a count, no killmails key at all.
      # Absent is not empty - formatting this as `[]` would discard the count.
      payload = %{"solar_system_id" => @batch_system_id, "count" => 4, "type" => :kill_count}

      %{"data" => data} = JsonApiFormatter.format_event(kill_event(payload))

      assert data["type"] == "events"
      assert data["id"] == "evt-1"
      assert data["attributes"] == payload
      assert data["relationships"]["map"]["data"] == %{"type" => "maps", "id" => @map_id}
    end
  end

  describe "other event types" do
    test "still emit a single resource object" do
      event = %Event{
        id: "evt-2",
        map_id: @map_id,
        type: :add_system,
        payload: %{"system_id" => "sys-1", "solar_system_id" => 30_000_142, "name" => "Jita"},
        timestamp: @broadcast_time
      }

      %{"data" => data, "meta" => meta} = JsonApiFormatter.format_event(event)

      assert data["type"] == "map_systems"
      assert data["id"] == "sys-1"
      assert data["attributes"]["name"] == "Jita"
      assert meta["event_type"] == :add_system
    end
  end
end
