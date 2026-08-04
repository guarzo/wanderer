defmodule WandererApp.ExternalEvents.Discord.SystemNameTest do
  # `async: false` is mandatory: this file seeds `:system_static_info_cache`,
  # a global Cachex table shared with every other test file, and it writes to
  # the database.
  use WandererApp.DataCase, async: false

  import Ecto.Query

  alias WandererApp.ExternalEvents.Discord.SystemName
  alias WandererApp.Repo
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

    # Ash's `:string` type defaults `allow_empty?` to false and casts `""` to
    # `nil` on write, so writing through the Factory/Ash changeset can never
    # persist an empty string in the first place — it would only ever exercise
    # the `nil` branch, not `present("")`. Bypass Ash's write-side casting with
    # a raw Ecto update straight against the table so the row genuinely holds
    # `""`, then confirm the read path treats it as unset.
    test "an empty-string map-local name is treated as unset", %{map: map} do
      system =
        Factory.insert(:map_system, %{
          map_id: map.id,
          solar_system_id: @ks_system,
          name: "Jita"
        })

      Repo.update_all(
        from(s in "map_system_v1", where: s.id == type(^system.id, Ecto.UUID)),
        set: [temporary_name: "", custom_name: ""]
      )

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

    # A nil map_id is rejected by the action's `allow_nil?: false` and comes
    # back as `{:error, _}`, which the `_ -> nil` clause absorbs whether or not
    # the `is_binary(map_id)` guard is present — that path alone can't prove
    # the guard does anything. Ash's `:string` argument casting auto-stringifies
    # atoms (`cast_input/2` calls `to_string/1` for `is_atom` values), so an
    # atom that happens to stringify to a *real* map id sails through the Ash
    # call successfully instead of erroring. Without the guard, this atom would
    # reach the Ash lookup, resolve the real system, and leak "HOME" onto a
    # role that should only ever see canonical names for a malformed map_id.
    test "a non-binary map_id that stringifies to a real map id is still rejected before the Ash lookup",
         %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @wh_system,
        name: "J115405",
        temporary_name: "HOME"
      })

      atom_map_id = String.to_atom(map.id)

      assert SystemName.display_name(atom_map_id, @wh_system, :system) == "J115405"
    end
  end
end
