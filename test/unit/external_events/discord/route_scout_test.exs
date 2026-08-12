defmodule WandererApp.ExternalEvents.Discord.RouteScoutTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.UserActivity
  alias WandererApp.ExternalEvents.Discord.RouteScout
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

  describe "resolve/2" do
    defp track_connection_added(map, character, user, source, target) do
      {:ok, _} =
        WandererApp.User.ActivityTracker.track_map_event(:map_connection_added, %{
          character_id: character.id,
          user_id: user.id,
          map_id: map.id,
          solar_system_source_id: source,
          solar_system_target_id: target
        })

      :ok
    end

    test "credits the character who added a system on the path", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @wh_hop)

      assert %{name: "Kraven Ordos", eve_id: eve_id} =
               RouteScout.resolve(ctx.map.id, [@home, @wh_hop, @exit_system])

      assert eve_id == ctx.character.eve_id
    end

    test "credits the character who added a connection on the path", ctx do
      :ok = track_connection_added(ctx.map, ctx.character, ctx.user, @home, @wh_hop)

      assert %{name: "Kraven Ordos"} =
               RouteScout.resolve(ctx.map.id, [@home, @wh_hop, @exit_system])
    end

    # The recorded source/target follow the direction the character jumped,
    # which need not match the direction the solved route runs.
    test "matches a connection recorded in the reverse orientation", ctx do
      :ok = track_connection_added(ctx.map, ctx.character, ctx.user, @wh_hop, @home)

      assert %{name: "Kraven Ordos"} =
               RouteScout.resolve(ctx.map.id, [@home, @wh_hop, @exit_system])
    end

    test "does not credit a non-adjacent pair", ctx do
      :ok = track_connection_added(ctx.map, ctx.character, ctx.user, @home, @exit_system)

      assert RouteScout.resolve(ctx.map.id, [@home, @wh_hop, @exit_system]) == nil
    end

    test "returns nil when nothing recent explains the route", ctx do
      # No activity at all: the transition came from a :connection_updated
      # label edit, which credits nobody.
      assert RouteScout.resolve(ctx.map.id, [@home, @wh_hop, @exit_system]) == nil
    end

    test "returns nil for an unknown map", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @wh_hop)
      assert RouteScout.resolve(Ecto.UUID.generate(), [@home, @wh_hop]) == nil
    end

    test "returns nil for a degenerate path or bad map id", ctx do
      assert RouteScout.resolve(ctx.map.id, []) == nil
      assert RouteScout.resolve(nil, [@home, @wh_hop]) == nil
    end

    # A path element with no `Jason.Encoder` implementation (a PID, here)
    # makes `Jason.encode!/1` raise inside `system_event_data/1`, before any
    # Ash call happens. This exercises the `rescue` clause directly: without
    # it, this test fails with an unhandled `Protocol.UndefinedError` instead
    # of the assertion below.
    test "returns nil instead of raising when the path cannot be encoded", ctx do
      assert RouteScout.resolve(ctx.map.id, [self()]) == nil
    end

    # The realistic operational failure this module protects against: the DB
    # connection is unavailable when `read_route_attribution/1` is called.
    # AshPostgres's own `handle_raised_error/4` catch-all
    # (ash_postgres/lib/data_layer.ex) converts that into `{:error, %Ash.Error...}`
    # before it ever reaches `resolve/2` — so this exercises the `case`'s `_ ->
    # nil` catch-all, not the `rescue` clause. Tearing down the sandbox owner
    # mid-test is what forces that error tuple deterministically, with no
    # production change.
    test "returns nil when the attribution lookup errors instead of matching", ctx do
      owner_pid = Process.get(:sandbox_owner_pid)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner_pid)

      assert RouteScout.resolve(ctx.map.id, [@home, @wh_hop]) == nil
    end
  end
end
