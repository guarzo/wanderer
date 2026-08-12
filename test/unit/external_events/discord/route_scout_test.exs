defmodule WandererApp.ExternalEvents.Discord.RouteScoutTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.UserActivity
  alias WandererAppWeb.Factory

  @home 31_000_005
  @wh_hop 31_000_006
  @exit_system 30_002_053

  setup do
    user = Factory.insert(:user, %{})
    character = Factory.insert(:character, %{user_id: user.id, name: "Kraven Ordos"})
    map = Factory.insert(:map, %{})

    %{user: user, character: character, map: map}
  end

  # Written through the REAL tracker, not a hand-built event_data string.
  # `SecurityAudit.sanitize_metadata/1` stringifies keys before
  # `Jason.encode!/1`, so a hand-written fixture could agree with the lookup
  # while both disagree with production. Going through the tracker pins the
  # encoding end to end.
  defp track_system_added(map, character, user, solar_system_id) do
    {:ok, _} =
      WandererApp.User.ActivityTracker.track_map_event(:system_added, %{
        character_id: character.id,
        user_id: user.id,
        map_id: map.id,
        solar_system_id: solar_system_id
      })

    :ok
  end

  describe "read_route_attribution" do
    test "finds a system_added row for a system on the path", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @wh_hop)

      {:ok, [activity]} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), -900, :second),
          system_event_data: [Jason.encode!(%{"solar_system_id" => @wh_hop})],
          connection_event_data: []
        })

      assert activity.character.name == "Kraven Ordos"
    end

    test "ignores rows older than the since bound", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @wh_hop)

      {:ok, []} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), 60, :second),
          system_event_data: [Jason.encode!(%{"solar_system_id" => @wh_hop})],
          connection_event_data: []
        })
    end

    test "ignores rows belonging to another map", ctx do
      other_map = Factory.insert(:map, %{})
      :ok = track_system_added(other_map, ctx.character, ctx.user, @wh_hop)

      {:ok, []} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), -900, :second),
          system_event_data: [Jason.encode!(%{"solar_system_id" => @wh_hop})],
          connection_event_data: []
        })
    end

    test "returns only the newest of several candidates", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @home)
      Process.sleep(5)
      other = Factory.insert(:character, %{user_id: ctx.user.id, name: "Later Scout"})
      :ok = track_system_added(ctx.map, other, ctx.user, @exit_system)

      {:ok, [activity]} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), -900, :second),
          system_event_data: [
            Jason.encode!(%{"solar_system_id" => @home}),
            Jason.encode!(%{"solar_system_id" => @exit_system})
          ],
          connection_event_data: []
        })

      assert activity.character.name == "Later Scout"
    end

    # A one-system path produces no adjacent pairs. Ecto renders `in ^[]` as a
    # false literal rather than invalid `IN ()` SQL, and this pins that.
    test "tolerates an empty candidate list on either side", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @wh_hop)

      {:ok, [_]} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), -900, :second),
          system_event_data: [Jason.encode!(%{"solar_system_id" => @wh_hop})],
          connection_event_data: []
        })

      {:ok, []} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), -900, :second),
          system_event_data: [],
          connection_event_data: []
        })
    end
  end
end
