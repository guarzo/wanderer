defmodule WandererApp.Kills.MessageHandlerAttackersTest do
  use ExUnit.Case, async: true

  alias WandererApp.Kills.MessageHandler

  # A realistic nested killmail: one NPC attacker (no character_id, no
  # corporation_id), two pilots from the same corporation (so corp
  # deduplication is exercised), and a third pilot from another corp who lands
  # the final blow while a *different* pilot deals the most damage.
  defp nested_kill do
    %{
      "killmail_id" => 120_345_678,
      "kill_time" => "2026-08-03T14:22:31Z",
      "solar_system_id" => 31_000_005,
      "victim" => %{
        "character_id" => 95_465_499,
        "character_name" => "Victim Pilot",
        "corporation_id" => 98_000_001,
        "corporation_ticker" => "VCTM",
        "corporation_name" => "Victim Corp",
        "alliance_id" => 99_000_001,
        "alliance_ticker" => "VALL",
        "alliance_name" => "Victim Alliance",
        "ship_type_id" => 670,
        "ship_name" => "Capsule"
      },
      "attackers" => [
        %{
          "character_id" => nil,
          "corporation_id" => nil,
          "damage_done" => 120,
          "final_blow" => false,
          "ship_type_id" => 30_889,
          "ship_name" => "Sleepless Sentinel"
        },
        %{
          "character_id" => 91_000_001,
          "character_name" => "Top Damage Pilot",
          "corporation_id" => 98_100_001,
          "corporation_ticker" => "TDMG",
          "corporation_name" => "Top Damage Corp",
          "alliance_id" => 99_100_001,
          "alliance_ticker" => "TALL",
          "alliance_name" => "Top Alliance",
          "damage_done" => 9_500,
          "final_blow" => false,
          "ship_type_id" => 11_567,
          "ship_name" => "Avatar"
        },
        %{
          "character_id" => 91_000_002,
          "character_name" => "Same Corp Pilot",
          "corporation_id" => 98_100_001,
          "corporation_ticker" => "TDMG",
          "corporation_name" => "Top Damage Corp",
          "damage_done" => 400,
          "final_blow" => false,
          "ship_type_id" => 587,
          "ship_name" => "Rifter"
        },
        %{
          "character_id" => 91_000_003,
          "character_name" => "Final Blow Pilot",
          "corporation_id" => 98_100_002,
          "corporation_ticker" => "FBLW",
          "corporation_name" => "Final Blow Corp",
          "damage_done" => 1_200,
          "final_blow" => true,
          "ship_type_id" => 621,
          "ship_name" => "Caracal"
        }
      ],
      "zkb" => %{"total_value" => 1_234_567.0, "npc" => false}
    }
  end

  describe "attacker id lists" do
    test "collects attacker character ids, rejecting NPC nils" do
      assert {:ok, kill} = MessageHandler.adapt_kill_data(nested_kill())

      assert kill["attacker_char_ids"] == [91_000_001, 91_000_002, 91_000_003]
    end

    test "collects attacker corporation ids, rejecting nils and deduplicating" do
      assert {:ok, kill} = MessageHandler.adapt_kill_data(nested_kill())

      assert kill["attacker_corp_ids"] == [98_100_001, 98_100_002]
    end

    test "an all-NPC kill yields empty lists rather than missing keys" do
      npc_kill =
        Map.put(nested_kill(), "attackers", [
          %{
            "character_id" => nil,
            "corporation_id" => nil,
            "damage_done" => 500,
            "final_blow" => true,
            "ship_type_id" => 30_889
          }
        ])

      assert {:ok, kill} = MessageHandler.adapt_kill_data(npc_kill)

      assert kill["attacker_char_ids"] == []
      assert kill["attacker_corp_ids"] == []
    end

    test "attacker_count still reflects every attacker, NPCs included" do
      assert {:ok, kill} = MessageHandler.adapt_kill_data(nested_kill())

      assert kill["attacker_count"] == 4
    end
  end

  describe "top damage attacker" do
    test "selects the highest-damage attacker when it differs from the final blow" do
      assert {:ok, kill} = MessageHandler.adapt_kill_data(nested_kill())

      # Top damage: 9_500. Final blow: a different pilot with 1_200.
      assert kill["top_damage_char_id"] == 91_000_001
      assert kill["top_damage_char_name"] == "Top Damage Pilot"
      assert kill["top_damage_corp_id"] == 98_100_001
      assert kill["top_damage_corp_ticker"] == "TDMG"

      assert kill["final_blow_char_id"] == 91_000_003
    end

    test "still populates the fields when top damage is the final blow attacker" do
      solo =
        Map.put(nested_kill(), "attackers", [
          %{
            "character_id" => 91_000_003,
            "character_name" => "Final Blow Pilot",
            "corporation_id" => 98_100_002,
            "corporation_ticker" => "FBLW",
            "corporation_name" => "Final Blow Corp",
            "damage_done" => 8_000,
            "final_blow" => true,
            "ship_type_id" => 621,
            "ship_name" => "Caracal"
          }
        ])

      assert {:ok, kill} = MessageHandler.adapt_kill_data(solo)

      assert kill["top_damage_char_id"] == 91_000_003
      assert kill["top_damage_char_name"] == "Final Blow Pilot"
      assert kill["final_blow_char_id"] == 91_000_003
    end

    test "an all-NPC kill has nil top damage pilot fields but is still valid" do
      npc_kill =
        Map.put(nested_kill(), "attackers", [
          %{
            "character_id" => nil,
            "corporation_id" => nil,
            "damage_done" => 500,
            "final_blow" => true,
            "ship_type_id" => 30_889
          }
        ])

      assert {:ok, kill} = MessageHandler.adapt_kill_data(npc_kill)

      assert kill["top_damage_char_id"] == nil
      assert kill["top_damage_char_name"] == nil
      assert kill["top_damage_corp_id"] == nil
      assert kill["top_damage_corp_ticker"] == nil
    end

    test "attackers with no damage_done key do not crash selection" do
      no_damage =
        Map.put(nested_kill(), "attackers", [
          %{
            "character_id" => 91_000_010,
            "character_name" => "No Damage Key",
            "corporation_id" => 98_100_010,
            "corporation_ticker" => "NDMG",
            "final_blow" => true,
            "ship_type_id" => 587
          }
        ])

      assert {:ok, kill} = MessageHandler.adapt_kill_data(no_damage)

      assert kill["top_damage_char_id"] == 91_000_010
    end
  end

  describe "already-flat payloads" do
    test "pass through without the new keys — absent, not empty" do
      flat = %{
        "killmail_id" => 120_345_679,
        "kill_time" => "2026-08-03T14:25:00Z",
        "solar_system_id" => 31_000_005,
        "victim_char_id" => 95_465_499,
        "victim_corp_id" => 98_000_001,
        "victim_ship_type_id" => 670,
        "attacker_count" => 4,
        "total_value" => 1_234_567.0
      }

      assert {:ok, kill} = MessageHandler.adapt_kill_data(flat)

      # Task 7 relies on absence meaning "unknown". Defaulting these to []
      # here would silently disable all attacker matching for flat payloads.
      refute Map.has_key?(kill, "attacker_char_ids")
      refute Map.has_key?(kill, "attacker_corp_ids")
      refute Map.has_key?(kill, "top_damage_char_id")
      refute Map.has_key?(kill, "top_damage_corp_id")
    end

    test "a flat payload that already carries the new keys keeps them" do
      flat = %{
        "killmail_id" => 120_345_680,
        "kill_time" => "2026-08-03T14:26:00Z",
        "solar_system_id" => 31_000_005,
        "victim_char_id" => 95_465_499,
        "victim_corp_id" => 98_000_001,
        "attacker_char_ids" => [91_000_001],
        "attacker_corp_ids" => [98_100_001]
      }

      assert {:ok, kill} = MessageHandler.adapt_kill_data(flat)

      assert kill["attacker_char_ids"] == [91_000_001]
      assert kill["attacker_corp_ids"] == [98_100_001]
    end
  end
end
