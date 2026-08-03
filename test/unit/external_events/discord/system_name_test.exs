defmodule WandererApp.ExternalEvents.Discord.SystemNameTest do
  # `async: false` is mandatory: this file seeds `:system_static_info_cache`,
  # a global Cachex table shared with every other test file, and it writes to
  # the database.
  use WandererApp.DataCase, async: false

  alias WandererApp.ExternalEvents.Discord.SystemName
  alias WandererAppWeb.Factory

  # Real EVE ids: a J-space system and Jita.
  @wh_system 31_000_005
  @ks_system 30_000_142

  setup do
    seed_static_info()
    map = Factory.insert(:map, %{})
    %{map: map}
  end

  # `map_solar_systems` is static import data and is NOT populated by `mix test`
  # on a clean database, so the canonical name has to come from the cache.
  # This mirrors `discord_dispatcher_test.exs:61-80`; the `on_exit` cleanup is
  # required because the table is global.
  defp seed_static_info do
    Cachex.put(:system_static_info_cache, @wh_system, %{
      solar_system_id: @wh_system,
      solar_system_name: "J115405",
      system_class: 3
    })

    Cachex.put(:system_static_info_cache, @ks_system, %{
      solar_system_id: @ks_system,
      solar_system_name: "Jita",
      system_class: 0
    })

    on_exit(fn ->
      Cachex.del(:system_static_info_cache, @wh_system)
      Cachex.del(:system_static_info_cache, @ks_system)
    end)

    :ok
  end

  describe "the privacy constraint" do
    # This test is named for the constraint on purpose. The asymmetry it locks
    # in looks like an inconsistency and will invite a "fix"; the reason lives
    # in the SystemName moduledoc. See the design doc §7.
    test "map-local system names never reach the character webhook", %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @wh_system,
        name: "J115405",
        temporary_name: "HOME"
      })

      assert SystemName.display_name(map.id, @wh_system, :character) == "J115405"
      assert SystemName.display_name(map.id, @wh_system, :system) == "HOME"
    end

    test "a custom_name is equally confined to the system webhook", %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @wh_system,
        name: "J115405",
        custom_name: "Staging"
      })

      assert SystemName.display_name(map.id, @wh_system, :character) == "J115405"
      assert SystemName.display_name(map.id, @wh_system, :system) == "Staging"
    end
  end

  describe "display_name/3 resolution order" do
    test "temporary_name wins over custom_name on the system webhook", %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @wh_system,
        name: "J115405",
        custom_name: "Staging",
        temporary_name: "HOME"
      })

      assert SystemName.display_name(map.id, @wh_system, :system) == "HOME"
    end

    test "falls through to the canonical name when neither is set", %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @ks_system,
        name: "Jita"
      })

      assert SystemName.display_name(map.id, @ks_system, :system) == "Jita"
      assert SystemName.display_name(map.id, @ks_system, :character) == "Jita"
    end

    test "an empty-string map-local name is treated as unset", %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @ks_system,
        name: "Jita",
        temporary_name: "",
        custom_name: ""
      })

      assert SystemName.display_name(map.id, @ks_system, :system) == "Jita"
    end

    test "a system absent from the map still resolves canonically", %{map: map} do
      assert SystemName.display_name(map.id, @ks_system, :system) == "Jita"
      assert SystemName.display_name(map.id, @ks_system, :character) == "Jita"
    end

    test "returns nil when nothing can be resolved", %{map: map} do
      unknown = 39_999_999

      assert SystemName.display_name(map.id, unknown, :system) == nil
      assert SystemName.display_name(map.id, unknown, :character) == nil
    end

    test "a nil map_id does not crash the system role" do
      assert SystemName.display_name(nil, @ks_system, :system) == "Jita"
    end
  end
end
