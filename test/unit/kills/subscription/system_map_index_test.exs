defmodule WandererApp.Kills.Subscription.SystemMapIndexTest do
  # `async: false`: the index owns a NAMED ETS table and a named GenServer, so
  # two of these running concurrently would fight over both.
  use WandererApp.DataCase, async: false

  alias WandererApp.Kills.Subscription.SystemMapIndex
  alias WandererAppWeb.Factory

  @visible_system 31_000_005
  @removed_system 31_000_006

  # A real removal, through the repo function the map server calls, rather than
  # writing `visible: false` directly — so this test fails if removal ever stops
  # being a soft delete and starts destroying the row.
  test "a system removed from the map is dropped from the index" do
    map = Factory.insert(:map, %{})

    Factory.insert(:map_system, %{map_id: map.id, solar_system_id: @visible_system})
    Factory.insert(:map_system, %{map_id: map.id, solar_system_id: @removed_system})

    {:ok, _} = WandererApp.MapSystemRepo.remove_from_map(map.id, @removed_system)

    start_supervised!(SystemMapIndex)
    # `init/1` sends itself `:build_index`; a system message is appended behind
    # it, so this returns only once the build has run.
    :sys.get_state(SystemMapIndex)

    assert SystemMapIndex.get_maps_for_system(@visible_system) == [map.id]
    assert SystemMapIndex.get_maps_for_system(@removed_system) == []
  end
end
