defmodule WandererAppWeb.TrackedCharacterLocationsTest do
  use WandererAppWeb.ApiCase, async: false
  import WandererApp.Test.TrackedLocationsFixtures
  alias WandererApp.Api
  alias WandererApp.Character.LocationConfirmations, as: Store
  alias WandererApp.MapIntegrationTokens, as: Tokens

  @keys ~w(character_id character_name tracked online solar_system_id solar_system_name display_name map_system_visible location_observed_at map_system_updated_at)

  setup do
    unless Process.whereis(:unique_tracker_pool_registry) do
      start_supervised!({Registry, keys: :unique, name: :unique_tracker_pool_registry})
    end

    Application.put_env(:wanderer_app, :map_integrations_enabled, true)
    original = Req.default_options()
    Req.default_options(plug: fn _ -> flunk("snapshot must never call ESI") end)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :map_integrations_enabled)
      Req.default_options(original)
    end)

    user = insert(:user)
    owner = insert(:character, %{user_id: user.id})
    map = insert(:map, %{owner_id: owner.id})
    {:ok, _} = Tokens.set_enabled(map.id, user, true)
    {:ok, %{token: token}} = Tokens.generate(map.id, user)
    wire = token.value
    %{map: map, user: user, owner: owner, token: token, wire: wire}
  end

  test "returns the exact sorted envelope and joins visible names without leaking credentials", %{
    map: map,
    user: user,
    wire: wire
  } do
    static_system()

    char =
      tracked_character(map, %{user_id: user.id, eve_id: "90000002", name: "Second Pilot"})
      |> online(map)

    first =
      tracked_character(map, %{user_id: user.id, eve_id: "90000001", name: "First Pilot"})
      |> online(map)

    system =
      insert(:map_system, %{
        map_id: map.id,
        solar_system_id: 30_000_142,
        name: "Rename",
        custom_name: "Custom",
        temporary_name: "HOME"
      })

    observed = confirm(char)
    confirm(first)
    conn = request(map.slug, wire)

    assert %{"data" => [one, two], "observed_at" => snapshot_at, "revision" => revision} =
             body = json_response(conn, 200)

    assert Enum.sort(Map.keys(body)) == ~w(data observed_at revision)
    assert one["character_id"] == 90_000_001

    assert two == %{
             "character_id" => 90_000_002,
             "character_name" => "Second Pilot",
             "tracked" => true,
             "online" => true,
             "solar_system_id" => 30_000_142,
             "solar_system_name" => "Jita",
             "display_name" => "HOME",
             "map_system_visible" => true,
             "location_observed_at" => DateTime.to_iso8601(observed),
             "map_system_updated_at" => DateTime.to_iso8601(system.updated_at)
           }

    assert Enum.sort(Map.keys(one)) == Enum.sort(@keys)
    assert {:ok, _, 0} = DateTime.from_iso8601(snapshot_at)
    assert is_binary(revision)
    assert get_resp_header(conn, "etag") == [~s(W/"#{revision}")]

    assert get_resp_header(conn, "cache-control") == [
             "private, no-cache, max-age=0, must-revalidate"
           ]

    assert get_resp_header(conn, "x-wanderer-locations-version") == ["1"]

    assert get_resp_header(conn, "vary") == [
             "Authorization, Accept, X-Wanderer-Locations-Version"
           ]

    refute conn.resp_body =~ "access_token"
    refute conn.resp_body =~ wire
  end

  test "excludes untracked and denied identities but retains authorized unavailable identities",
       %{map: map, user: user, wire: wire} do
    allowed = tracked_character(map, %{user_id: user.id, eve_id: "90000001"})
    denied = tracked_character(map, %{eve_id: "90000002"}) |> online(map)
    untracked = tracked_character(map, %{user_id: user.id, eve_id: "90000003"})

    settings =
      Api.MapCharacterSettings.read_by_map_and_character!(%{
        map_id: map.id,
        character_id: untracked.id
      })

    Api.MapCharacterSettings.update!(settings, %{tracked: false})
    confirm(denied)
    assert [record] = json_response(request(map.id, wire), 200)["data"]
    assert record["character_id"] == String.to_integer(allowed.eve_id)
    assert_unavailable(record, nil)
  end

  test "ACL tracking membership is rechecked before every response including 304", %{
    map: map,
    wire: wire
  } do
    acl = insert(:access_list, %{owner_id: map.owner_id})
    insert(:map_access_list, %{map_id: map.id, access_list_id: acl.id})
    member_user = insert(:user)
    char = tracked_character(map, %{user_id: member_user.id}) |> online(map)

    member =
      insert(:access_list_member, %{
        access_list_id: acl.id,
        eve_character_id: char.eve_id,
        role: :member
      })

    confirm(char)
    first = request(map.id, wire)
    assert length(json_response(first, 200)["data"]) == 1
    Api.AccessListMember.update_role!(member, %{role: :blocked})
    second = request(map.id, wire, [{"if-none-match", hd(get_resp_header(first, "etag"))}])
    assert json_response(second, 200)["data"] == []
  end

  test "excludes a userless ACL member despite configured tracking and a live fresh location", %{
    map: map,
    wire: wire
  } do
    member_user = insert(:user)
    char = tracked_character(map, %{user_id: member_user.id}) |> online(map)
    acl = insert(:access_list, %{owner_id: map.owner_id})
    insert(:map_access_list, %{map_id: map.id, access_list_id: acl.id})

    insert(:access_list_member, %{
      access_list_id: acl.id,
      eve_character_id: char.eve_id,
      role: :member
    })

    confirm(char)
    first = request(map.id, wire)
    assert [%{"solar_system_id" => 30_000_142}] = json_response(first, 200)["data"]

    # The normal update clears deleted without restoring a user association.
    unlinked = char |> Api.Character.mark_as_deleted!() |> Api.Character.update!(%{})
    assert %{user_id: nil, deleted: false} = unlinked
    conn = request(map.id, wire, [{"if-none-match", hd(get_resp_header(first, "etag"))}])
    assert json_response(conn, 200)["data"] == []
  end

  test "excludes a userless map owner despite configured tracking and a live fresh location", %{
    map: map,
    owner: owner
  } do
    {viewer, _} = reader(map)
    {:ok, %{token: token}} = Tokens.generate(map.id, viewer)
    wire = token.value

    owner =
      Api.Character.update!(owner, %{
        access_token: "fixture-owner-access",
        expires_at: DateTime.to_unix(DateTime.utc_now()) + 3600
      })

    insert(:map_character_settings, %{map_id: map.id, character_id: owner.id, tracked: true})
    owner |> online(map) |> confirm()

    assert [%{"solar_system_id" => 30_000_142}] =
             json_response(request(map.id, wire), 200)["data"]

    unlinked = owner |> Api.Character.mark_as_deleted!() |> Api.Character.update!(%{})
    assert %{user_id: nil, deleted: false} = unlinked
    assert json_response(request(map.id, wire), 200)["data"] == []
  end

  test "freshness, grant and live tracker eligibility determine unavailable fields", %{
    map: map,
    user: user,
    wire: wire
  } do
    char = tracked_character(map, %{user_id: user.id}) |> online(map)
    confirm(char)
    assert hd(json_response(request(map.id, wire), 200)["data"])["online"] == true
    Cachex.put(:character_state_cache, char.id, %{is_online: false})
    assert_unavailable(hd(json_response(request(map.id, wire), 200)["data"]), false)
    online(char, map)
    Api.Character.update!(char, %{access_token: "new-grant"})
    assert_unavailable(hd(json_response(request(map.id, wire), 200)["data"]), nil)
    Api.Character.update!(char, %{access_token: char.access_token})
    Registry.unregister(:unique_tracker_pool_registry, {:locations_fixture, char.id})
    assert_unavailable(hd(json_response(request(map.id, wire), 200)["data"]), nil)
    online(char, map)
    Cachex.del(:character_state_cache, char.id)
    assert_unavailable(hd(json_response(request(map.id, wire), 200)["data"]), nil)
  end

  test "hidden and unmapped systems expose only real static names and visible precedence is unchanged",
       %{map: map, user: user, wire: wire} do
    static_system()
    char = tracked_character(map, %{user_id: user.id}) |> online(map)
    confirm(char)

    hidden =
      insert(:map_system, %{
        map_id: map.id,
        solar_system_id: 30_000_142,
        name: "Secret",
        temporary_name: "Hidden",
        visible: false
      })

    record = hd(json_response(request(map.id, wire), 200)["data"])
    assert record["solar_system_name"] == "Jita"
    assert record["solar_system_id"] == 30_000_142
    assert record["display_name"] == nil
    assert record["map_system_updated_at"] == nil
    assert record["map_system_visible"] == false
    hidden = Api.MapSystem.update_visible!(hidden, %{visible: true})
    assert hd(json_response(request(map.id, wire), 200)["data"])["display_name"] == "Hidden"
    hidden = Api.MapSystem.update_temporary_name!(hidden, %{temporary_name: nil})
    assert hd(json_response(request(map.id, wire), 200)["data"])["display_name"] == "Secret"
    Api.MapSystem.update_custom_name!(hidden, %{custom_name: "Custom"})
    assert hd(json_response(request(map.id, wire), 200)["data"])["display_name"] == "Custom"
    confirm(char, 31_999_999)
    record = hd(json_response(request(map.id, wire), 200)["data"])
    assert record["solar_system_id"] == 31_999_999
    assert record["solar_system_name"] == nil
    assert record["display_name"] == nil
  end

  test "ETag excludes envelope time, changes on confirmations and expires without renewal by 304",
       %{map: map, user: user, wire: wire} do
    char = tracked_character(map, %{user_id: user.id}) |> online(map)
    observed = confirm(char)
    first = request(map.id, wire)
    etag = hd(get_resp_header(first, "etag"))
    assert request(map.id, wire, [{"if-none-match", etag}]).status == 304

    assert request(map.id, wire, [{"if-none-match", String.replace_prefix(etag, "W/", "")}]).status ==
             304

    assert {:ok, %{entries: entries}} = Store.snapshot()
    assert entries[char.id].observed_at == observed
    # Advance only the ephemeral store's captured candidate, not the wall clock.
    :sys.replace_state(Store, fn state ->
      put_in(
        state,
        [:entries, char.id, :observed_at],
        DateTime.add(DateTime.utc_now(), -15, :second)
      )
    end)

    expired = request(map.id, wire, [{"if-none-match", etag}])
    assert_unavailable(hd(json_response(expired, 200)["data"]), nil)
    confirm(char)
    newer = request(map.id, wire, [{"if-none-match", etag}])
    assert newer.status == 200
    refute get_resp_header(newer, "etag") == [etag]
  end

  test "auth accepts only one bearer credential, never sessions, legacy keys or alternate transports",
       %{map: map, user: user, wire: wire} do
    for candidate <- [
          nil,
          "",
          "Bearer invalid",
          "Bearer #{map.public_api_key}",
          "Bearer #{wire}, Bearer #{wire}",
          "Basic #{wire}",
          String.duplicate("x", 513)
        ] do
      conn = build_conn() |> Plug.Test.init_test_session(user_id: user.id)
      conn = if candidate, do: put_req_header(conn, "authorization", candidate), else: conn

      conn =
        conn
        |> put_req_header("x-api-key", wire)
        |> put_req_cookie("integration_token", wire)
        |> get("/api/maps/#{map.id}/tracked-character-locations?token=#{wire}")

      assert_error(conn, 401, "invalid_token")
    end

    conn = build_conn()

    conn = %{
      conn
      | req_headers: [{"authorization", "Bearer #{wire}"}, {"authorization", "Bearer #{wire}"}]
    }

    assert_error(
      get(conn, "/api/maps/#{map.id}/tracked-character-locations"),
      401,
      "invalid_token"
    )

    assert request(map.id, wire).status == 200
  end

  test "replaced, revoked and wrong-map tokens retain distinct failures", %{
    map: map,
    user: user,
    wire: wire,
    token: token
  } do
    other = insert(:map)
    assert_error(request(other.id, wire), 403, "wrong_map")
    assert_error(request("missing-map", wire), 404, "map_not_found")
    {:ok, %{token: token}} = Tokens.regenerate(map.id, user, token.id, token.generation)
    new = token.value
    assert_error(request(map.id, wire), 401, "invalid_token")
    first = request(map.id, new)
    Tokens.revoke(map.id, user, token.id, token.generation)

    assert_error(
      request(map.id, new, [{"if-none-match", hd(get_resp_header(first, "etag"))}]),
      401,
      "invalid_token"
    )
  end

  test "global and subscription policy and media/version/header limits are enforced", %{
    map: map,
    wire: wire
  } do
    assert_error(request(map.id, wire, [{"accept", "text/html"}]), 406, "not_acceptable")

    assert_error(
      request(map.id, wire, [{"x-wanderer-locations-version", "2"}]),
      406,
      "not_acceptable"
    )

    assert_error(
      request(map.id, wire, [{"if-none-match", String.duplicate("a", 1025)}]),
      400,
      "invalid_request"
    )

    assert_error(request(String.duplicate("a", 256), wire), 400, "invalid_request")
    Application.put_env(:wanderer_app, :map_integrations_enabled, false)
    assert_error(request(map.id, wire), 403, "disabled")
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)
    Application.put_env(:wanderer_app, :public_api_disabled, true)
    on_exit(fn -> Application.put_env(:wanderer_app, :public_api_disabled, false) end)
    assert_error(request(map.id, wire), 403, "disabled")
    Application.put_env(:wanderer_app, :public_api_disabled, false)
    Application.put_env(:wanderer_app, :map_subscriptions_enabled, true)
    on_exit(fn -> Application.put_env(:wanderer_app, :map_subscriptions_enabled, false) end)
    assert_error(request(map.id, wire), 403, "subscription_required")
  end

  test "store failures are 503, not empty successful rosters", %{map: map, wire: wire} do
    :ok = Supervisor.terminate_child(WandererApp.Supervisor, Store)

    try do
      assert_error(request(map.id, wire), 503, "service_unavailable")
    after
      Supervisor.restart_child(WandererApp.Supervisor, Store)
    end
  end

  test "burst limits count conditional requests and are isolated per issued token", %{
    map: map,
    wire: wire,
    token: token
  } do
    first = request(map.id, wire)
    etag = hd(get_resp_header(first, "etag"))
    assert request(map.id, wire, [{"if-none-match", etag}]).status == 304

    # Fill the real burst bucket directly rather than assuming ten fresh ACL
    # snapshots finish inside one second on a loaded test runner.
    {_, _, wait, _, _} = ExRated.inspect_bucket({:tracked_locations_burst, token.id}, 1000, 10)
    Process.sleep(wait + 1)
    for _ <- 1..10, do: ExRated.check_rate({:tracked_locations_burst, token.id}, 1000, 10)
    assert_error(request(map.id, wire, [{"if-none-match", etag}]), 429, "rate_limited")
    {viewer, _} = reader(map)
    {:ok, %{token: other}} = Tokens.generate(map.id, viewer)
    assert request(map.id, other.value).status == 200
  end

  test "malformed identities and overflowing source names fail rather than truncate", %{
    map: map,
    user: user,
    wire: wire
  } do
    char = tracked_character(map, %{user_id: user.id, eve_id: "not-numeric"})
    assert_error(request(map.id, wire), 503, "invalid_snapshot")

    settings =
      Api.MapCharacterSettings.read_by_map_and_character!(%{map_id: map.id, character_id: char.id})

    Api.MapCharacterSettings.update!(settings, %{tracked: false})
    tracked_character(map, %{user_id: user.id, name: String.duplicate("a", 256)})
    assert_error(request(map.id, wire), 503, "invalid_snapshot")
  end

  test "retries once on changed tracking consent and does not mix old grant or local eligibility",
       %{map: map, user: user, wire: wire} do
    char = tracked_character(map, %{user_id: user.id}) |> online(map)
    confirm(char)
    after_system_read(fn -> Cachex.put(:character_state_cache, char.id, %{is_online: false}) end)
    assert_unavailable(hd(json_response(request(map.id, wire), 200)["data"]), false)
    online(char, map)

    after_system_read(fn ->
      Api.Character.update!(char, %{access_token: "changed-during-snapshot"})
    end)

    assert_unavailable(hd(json_response(request(map.id, wire), 200)["data"]), nil)

    settings =
      Api.MapCharacterSettings.read_by_map_and_character!(%{map_id: map.id, character_id: char.id})

    after_system_read(fn -> Api.MapCharacterSettings.update!(settings, %{tracked: false}) end)
    assert json_response(request(map.id, wire), 200)["data"] == []
  end

  test "rechecks token revocation and fails closed after repeated authorization changes", %{
    map: map,
    user: user,
    token: token,
    wire: wire
  } do
    after_system_read(fn -> Tokens.revoke(map.id, user, token.id, 1) end)
    assert_error(request(map.id, wire), 401, "invalid_token")
    {:ok, %{token: renewed}} = Tokens.generate(map.id, user)
    wire = renewed.value
    char = tracked_character(map, %{user_id: user.id})

    after_system_read(fn ->
      Api.Character.update!(char, %{name: "Changed once"})
      after_system_read(fn -> Api.Character.update!(char, %{name: "Changed twice"}) end)
    end)

    assert_error(request(map.id, wire), 503, "service_unavailable")
  end

  test "issued integration token cannot mutate ordinary REST or JSON API even with an owner session",
       %{map: map, user: user, wire: wire} do
    system = insert(:map_system, %{map_id: map.id, solar_system_id: 30_000_142})

    for path <- ["/api/maps/#{map.id}/systems/30000142", "/api/v1/map_systems/#{system.id}"] do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{wire}")
        |> Plug.Test.init_test_session(user_id: user.id)

      conn = patch(conn, path, %{description: "Must not write"})
      assert_error(conn, 403, "token_scope_forbidden")
    end

    refute Api.MapSystem.by_id!(system.id).description == "Must not write"
  end

  test "honors explicit media rejection over a wildcard and rejects malformed quality", %{
    map: map,
    wire: wire
  } do
    for accept <- [
          "application/json;q=0, */*;q=1",
          "application/json;q=garbage",
          "application/json;q=0.0000"
        ] do
      assert_error(request(map.id, wire, [{"accept", accept}]), 406, "not_acceptable")
    end
  end

  @tag timeout: 120_000
  test "accepts 2000 records, rejects 2001 and rejects JSON larger than one MiB", %{
    map: map,
    user: user,
    wire: wire
  } do
    attrs =
      for n <- 1..2000,
          do: %{eve_id: Integer.to_string(91_000_000 + n), name: "Pilot #{n}", user_id: user.id}

    result = Ash.bulk_create!(attrs, Api.Character, :link, return_records?: true)
    assert result.status == :success
    settings = Enum.map(result.records, &%{map_id: map.id, character_id: &1.id, tracked: true})
    assert Ash.bulk_create!(settings, Api.MapCharacterSettings, :create).status == :success
    conn = request(map.id, wire)
    assert length(json_response(conn, 200)["data"]) == 2000
    assert byte_size(conn.resp_body) <= 1_048_576
    extra = tracked_character(map, %{user_id: user.id})
    assert_error(request(map.id, wire), 503, "invalid_snapshot")

    settings =
      Api.MapCharacterSettings.read_by_map_and_character!(%{
        map_id: map.id,
        character_id: extra.id
      })

    Api.MapCharacterSettings.update!(settings, %{tracked: false})

    # Oversized-source fixture, not an application permission mutation. Ordinary
    # resource updates deliberately cannot use an atomic bulk bypass.
    WandererApp.Repo.query!("UPDATE character_v1 SET name = $1 WHERE user_id = $2", [
      String.duplicate("界", 255),
      Ecto.UUID.dump!(user.id)
    ])

    assert_error(request(map.id, wire), 503, "invalid_snapshot")
  end

  test "minute quota counts requests beyond independent burst windows", %{
    map: map,
    wire: wire,
    token: token
  } do
    for _ <- 1..60, do: ExRated.check_rate({:tracked_locations_minute, token.id}, 60_000, 60)
    assert_error(request(map.id, wire), 429, "rate_limited")
  end

  test "wrong and missing maps consume authenticated quota before any map lookup", %{
    wire: wire,
    token: token
  } do
    other = insert(:map)
    assert_error(request(other.id, wire), 403, "wrong_map")
    assert_error(request("missing-map", wire), 404, "map_not_found")

    {count, _, _, _, _} =
      ExRated.inspect_bucket({:tracked_locations_minute, token.id}, 60_000, 60)

    assert count == 2

    for _ <- 1..60, do: ExRated.check_rate({:tracked_locations_minute, token.id}, 60_000, 60)
    parent = self()
    id = {__MODULE__, :quota, parent}

    :telemetry.attach(
      id,
      [:wanderer_app, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == parent and String.contains?(metadata.query, ~s(FROM "maps_v1")),
          do: send(parent, :map_lookup)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    assert_error(request(other.id, wire), 429, "rate_limited")
    assert_error(request("missing-map", wire), 429, "rate_limited")
    refute_receive :map_lookup, 0
  end

  test "invalid token cannot consume its claimed identity's quota", %{
    map: map,
    wire: wire,
    token: token
  } do
    invalid = String.slice(wire, 0, 44) <> String.duplicate("A", 43)
    assert_error(request(map.id, invalid), 401, "invalid_token")

    {count, _, _, _, _} =
      ExRated.inspect_bucket({:tracked_locations_minute, token.id}, 60_000, 60)

    assert count == 0
  end

  test "scope mismatch is forbidden with a bearer challenge", %{
    map: map,
    wire: wire,
    token: token
  } do
    # Simulate an incompatible persisted scope; no action can request a broader scope.
    WandererApp.Repo.query!(
      "UPDATE map_integration_tokens_v1 SET scope = 'other:read' WHERE id = $1",
      [Ecto.UUID.dump!(token.id)]
    )

    conn = request(map.id, wire)
    assert_error(conn, 403, "scope_forbidden")
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="insufficient_scope")]
  end

  test "rejects noncanonical EVE identities", %{
    map: map,
    user: user,
    wire: wire
  } do
    for eve_id <- ["+90000001", "090000001"] do
      char = tracked_character(map, %{user_id: user.id, eve_id: eve_id})
      assert_error(request(map.id, wire), 503, "invalid_snapshot")

      settings =
        Api.MapCharacterSettings.read_by_map_and_character!(%{
          map_id: map.id,
          character_id: char.id
        })

      Api.MapCharacterSettings.update!(settings, %{tracked: false})
    end
  end

  test "OpenAPI publishes the dedicated scheme and exact record contract" do
    spec = build_conn() |> get("/api/openapi") |> json_response(200)
    operation = spec["paths"]["/api/maps/{map_identifier}/tracked-character-locations"]["get"]
    assert operation["security"] == [%{"mapIntegrationToken" => []}]
    assert spec["components"]["securitySchemes"]["mapIntegrationToken"]["scheme"] == "bearer"

    assert Enum.sort(spec["components"]["schemas"]["TrackedCharacterLocation"]["required"]) ==
             Enum.sort(@keys)
  end

  test "reader access is checked after quota and before conditional data", %{
    map: map,
    wire: owner_wire
  } do
    {viewer, member} = reader(map)
    {:ok, %{token: token}} = Tokens.generate(map.id, viewer)
    first = request(map.id, token.value)
    assert json_response(first, 200)["data"] == []
    # External DB mutation models a missed hook; request authorization must still
    # deny and permanently revoke without mistaking this reader for the roster.
    WandererApp.Repo.query!("UPDATE access_list_members_v1 SET role = 'blocked' WHERE id = $1", [
      Ecto.UUID.dump!(member.id)
    ])

    assert_error(
      request(map.id, token.value, [{"if-none-match", hd(get_resp_header(first, "etag"))}]),
      403,
      "forbidden"
    )

    assert {:error, :invalid_token} = Tokens.authenticate(token.value)
    assert request(map.id, owner_wire).status == 200
  end

  test "final reader authorization rejects access changed during an in-flight conditional snapshot",
       %{map: map} do
    {viewer, member} = reader(map)
    {:ok, %{token: token}} = Tokens.generate(map.id, viewer)
    first = request(map.id, token.value)

    after_system_read(fn ->
      WandererApp.Repo.query!(
        "UPDATE access_list_members_v1 SET role = 'blocked' WHERE id = $1",
        [Ecto.UUID.dump!(member.id)]
      )
    end)

    assert_error(
      request(map.id, token.value, [{"if-none-match", hd(get_resp_header(first, "etag"))}]),
      403,
      "forbidden"
    )

    assert {:error, :invalid_token} = Tokens.authenticate(token.value)
  end

  test "reader data-service failures fail closed without revocation", %{map: map} do
    {viewer, _} = reader(map)
    {:ok, %{token: token}} = Tokens.generate(map.id, viewer)
    wire = token.value

    WandererApp.Repo.query!(
      "ALTER TABLE access_list_members_v1 RENAME COLUMN role TO unavailable_role"
    )

    assert_error(request(map.id, wire), 503, "service_unavailable")
    assert {:ok, _} = Tokens.authenticate(wire)
  end

  test "subject permission queries never run before authenticated quota", %{map: map} do
    {viewer, _} = reader(map)
    {:ok, %{token: token}} = Tokens.generate(map.id, viewer)
    for _ <- 1..60, do: ExRated.check_rate({:tracked_locations_minute, token.id}, 60_000, 60)
    parent = self()
    handler = {__MODULE__, :subject_quota, parent}

    :telemetry.attach(
      handler,
      [:wanderer_app, :repo, :query],
      fn _, _, meta, _ ->
        if self() == parent and String.contains?(meta.query, ~s(FROM "character_v1")),
          do: send(parent, :subject_read)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert_error(request(map.id, token.value), 429, "rate_limited")
    refute_receive :subject_read, 0
  end

  defp reader(map) do
    user = insert(:user)
    char = insert(:character, %{user_id: user.id})
    acl = insert(:access_list, %{owner_id: map.owner_id})
    insert(:map_access_list, %{map_id: map.id, access_list_id: acl.id})

    member =
      insert(:access_list_member, %{
        access_list_id: acl.id,
        eve_character_id: char.eve_id,
        role: :viewer
      })

    {user, member}
  end

  defp after_system_read(fun) do
    id = {__MODULE__, self(), make_ref()}
    parent = self()

    :telemetry.attach(
      id,
      [:wanderer_app, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == parent and String.contains?(metadata.query, ~s(FROM "map_system_v1")) do
          :telemetry.detach(id)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp request(identifier, wire, headers \\ []) do
    conn = build_conn() |> put_req_header("authorization", "Bearer #{wire}")

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)

    get(conn, "/api/maps/#{identifier}/tracked-character-locations")
  end

  defp assert_unavailable(record, online) do
    assert record["online"] == online
    assert record["tracked"] == true
    assert record["map_system_visible"] == false

    for key <-
          ~w(solar_system_id solar_system_name display_name location_observed_at map_system_updated_at),
        do: assert(record[key] == nil)
  end

  defp assert_error(conn, status, code) do
    assert %{"code" => ^code, "error" => error} = body = json_response(conn, status)
    assert is_binary(error)
    assert Enum.sort(Map.keys(body)) == ~w(code error)
    assert byte_size(conn.resp_body) <= 2048
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "etag") == []
    assert get_resp_header(conn, "x-wanderer-locations-version") == ["1"]
    if status == 401, do: assert(get_resp_header(conn, "www-authenticate") != [])
    refute conn.resp_body =~ "wmi_"
  end
end
