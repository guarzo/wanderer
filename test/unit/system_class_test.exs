defmodule WandererApp.SystemClassTest do
  # `wormhole_system?/1` resolves static info via `CachedInfo`, which hits the
  # DB-backed cache, so this needs sandbox access rather than plain ExUnit.Case.
  use WandererApp.DataCase, async: true

  alias WandererApp.SystemClass

  describe "wormhole?/1" do
    test "returns true for c1-c6" do
      for class <- 1..6 do
        assert SystemClass.wormhole?(class), "class #{class} should be wormhole"
      end
    end

    test "returns true for thera and c13" do
      assert SystemClass.wormhole?(12)
      assert SystemClass.wormhole?(13)
    end

    test "returns true for drifter holes" do
      for class <- 14..18 do
        assert SystemClass.wormhole?(class), "class #{class} should be wormhole"
      end
    end

    test "returns false for known space" do
      refute SystemClass.wormhole?(7)
      refute SystemClass.wormhole?(8)
      refute SystemClass.wormhole?(9)
    end

    test "returns false for pochven and zarzakh" do
      refute SystemClass.wormhole?(25)
      refute SystemClass.wormhole?(10_100)
    end

    test "returns false for nil and unknown classes" do
      refute SystemClass.wormhole?(nil)
      refute SystemClass.wormhole?(999)
    end
  end

  describe "wormhole_classes/0" do
    test "returns the exact canonical set" do
      assert Enum.sort(SystemClass.wormhole_classes()) == [
               1,
               2,
               3,
               4,
               5,
               6,
               12,
               13,
               14,
               15,
               16,
               17,
               18
             ]
    end
  end

  describe "wormhole_system?/1" do
    test "returns false for non-integer input" do
      refute SystemClass.wormhole_system?("31000005")
      refute SystemClass.wormhole_system?(:not_an_id)
      refute SystemClass.wormhole_system?(nil)
    end

    test "returns false for an unresolvable solar system id" do
      refute SystemClass.wormhole_system?(-1)
    end
  end
end

defmodule WandererAppWeb.KillmailFactoryTest do
  use ExUnit.Case, async: true

  alias WandererAppWeb.Factory

  test "build(:killmail) produces string keys with required fields" do
    kill = Factory.build(:killmail)

    assert is_integer(kill["killmail_id"])
    assert is_binary(kill["kill_time"])
    assert is_integer(kill["solar_system_id"])
    assert kill["total_value"] == 84_000_000
  end

  test "build(:killmail) accepts atom-key overrides" do
    kill = Factory.build(:killmail, %{victim_ship_name: nil, total_value: 0})

    assert kill["victim_ship_name"] == nil
    assert kill["total_value"] == 0
  end

  test "build(:kill_event) wraps killmails in the batch shape" do
    event = Factory.build(:kill_event)

    assert event["type"] == :killmail_update
    assert [%{"killmail_id" => _}] = event["killmails"]
  end

  test "build(:kill_count_event) has no killmails" do
    event = Factory.build(:kill_count_event)

    assert event["type"] == :kill_count
    refute Map.has_key?(event, "killmails")
  end
end
