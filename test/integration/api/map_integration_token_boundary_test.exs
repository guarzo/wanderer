defmodule WandererAppWeb.MapIntegrationTokenBoundaryTest do
  use WandererAppWeb.ApiCase, async: false

  import Phoenix.LiveViewTest
  import Phoenix.ChannelTest, only: [subscribe_and_join: 3]
  require Phoenix.ChannelTest

  alias WandererApp.Api
  alias WandererApp.Repo

  alias WandererAppWeb.Plugs.{
    CheckAclApiKey,
    CheckJsonApiAuth,
    CheckMapApiKey,
    RejectIntegrationToken
  }

  @moduletag :integration
  @token "wmi_v1_boundary_test_not_a_credential"

  setup do
    user = insert(:user)
    character = insert(:character, %{user_id: user.id})
    map = insert(:map, %{owner_id: character.id})
    acl = insert(:access_list, %{owner_id: character.id})
    %{user: user, character: character, map: map, acl: acl}
  end

  test "JSON API namespace denial emits the existing audit and auth telemetry without credentials",
       %{user: user} do
    id = {__MODULE__, :audit, self()}
    parent = self()
    events = [[:wanderer_app, :security_audit], [:wanderer_app, :json_api, :auth]]

    :ok =
      :telemetry.attach_many(
        id,
        events,
        fn event, measurements, metadata, _ ->
          if self() == parent, do: send(parent, {:auth_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    watch_queries()

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        integration_conn()
        |> Plug.Test.init_test_session(user_id: user.id)
        |> CheckJsonApiAuth.call([])
        |> assert_forbidden()
      end)

    assert log =~ "Security audit: auth_failure"
    refute log =~ @token

    assert_receive {:auth_event, [:wanderer_app, :security_audit], %{count: 1},
                    %{event_type: :auth_failure, user_id: nil}}

    assert_receive {:auth_event, [:wanderer_app, :json_api, :auth],
                    %{count: 1, duration: duration}, metadata}

    assert duration >= 0
    assert metadata == %{auth_type: "bearer_token", result: "failure"}
    refute_receive :boundary_db_query, 0
  end

  # Removing any auth plug's early namespace check must fail these without
  # relying on downstream controller validation or an existing credential row.
  for plug <- [CheckMapApiKey, CheckAclApiKey, CheckJsonApiAuth],
      header <- [
        "Bearer wmi_v1_boundary_test_not_a_credential",
        "bearer wmi_v99_unknown",
        "bEaReR wmi_",
        "Bearer\twmi_malformed",
        "wmi_no_scheme",
        "Bearer ordinary, Bearer wmi_unknown",
        "Bearer wmi_unknown, Bearer ordinary"
      ] do
    test "#{inspect(plug)} rejects #{inspect(header)} before lookup or fallback", %{user: user} do
      watch_queries()

      result =
        build_conn()
        |> Plug.Test.init_test_session(user_id: user.id)
        |> put_req_header("authorization", unquote(header))
        |> Map.put(:params, %{})
        |> unquote(plug).call([])

      assert_forbidden(result)
      refute_receive :boundary_db_query, 0
    end
  end

  for {header, value} <- [
        {"cache-control", "no-store"},
        {"content-type", "application/json; charset=utf-8"},
        {"x-wanderer-locations-version", "1"},
        {"www-authenticate", ~s(Bearer error="insufficient_scope")}
      ] do
    test "namespace denial sets fixed #{header} despite a preexisting response header" do
      conn =
        integration_conn()
        |> put_resp_header(unquote(header), "preexisting-value")
        |> RejectIntegrationToken.call([])

      assert get_resp_header(conn, unquote(header)) == [unquote(value)]
      assert_forbidden(conn)
    end
  end

  test "namespace denial removes a preexisting ETag" do
    conn =
      integration_conn()
      |> put_resp_header("etag", ~s(W/"preexisting-validator"))
      |> RejectIntegrationToken.call([])

    assert get_resp_header(conn, "etag") == []
    assert_forbidden(conn)
  end

  test "map and ACL rejection precedes unknown identifier lookup" do
    watch_queries()

    for {plug, params} <- [
          {CheckMapApiKey, %{"map_identifier" => Ecto.UUID.generate()}},
          {CheckAclApiKey, %{"id" => Ecto.UUID.generate()}}
        ] do
      result =
        integration_conn()
        |> Map.put(:params, params)
        |> plug.call([])

      assert_forbidden(result)
    end

    refute_receive :boundary_db_query, 0
  end

  test "all auth plugs inspect duplicate headers in both orders", %{
    map: map,
    acl: acl,
    user: user
  } do
    for {plug, key, params} <- [
          {CheckMapApiKey, map.public_api_key, %{"map_identifier" => map.id}},
          {CheckAclApiKey, acl.api_key, %{"id" => acl.id}},
          {CheckJsonApiAuth, map.public_api_key, %{}}
        ],
        values <- [["Bearer #{key}", "bEaReR #{@token}"], ["bEaReR #{@token}", "Bearer #{key}"]] do
      result =
        build_conn()
        |> Plug.Test.init_test_session(user_id: user.id)
        |> authorization_headers(values)
        |> Map.put(:params, params)
        |> plug.call([])

      assert_forbidden(result)
    end
  end

  test "reserved values stored as legacy map and ACL keys cannot authenticate", %{
    map: map,
    acl: acl
  } do
    {:ok, map} = Api.Map.update_api_key(map, %{public_api_key: @token})
    {:ok, acl} = Api.AccessList.update(acl, %{api_key: @token})
    watch_queries()

    for {plug, params} <- [
          {CheckMapApiKey, %{"map_identifier" => map.id}},
          {CheckAclApiKey, %{"id" => acl.id}},
          {CheckJsonApiAuth, %{}}
        ] do
      result =
        integration_conn()
        |> Plug.Test.init_test_session(%{})
        |> Map.put(:params, params)
        |> plug.call([])

      assert_forbidden(result)
    end

    refute_receive :boundary_db_query, 0
  end

  test "ordinary legacy map, ACL and v1 session authority remains valid", %{
    map: map,
    acl: acl,
    user: user
  } do
    watch_queries()

    map_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{map.public_api_key}")
      |> Map.put(:params, %{"map_identifier" => map.slug})
      |> CheckMapApiKey.call([])

    refute map_conn.halted
    assert map_conn.assigns.current_character.id == map.owner_id

    acl_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{acl.api_key}")
      |> Map.put(:params, %{"id" => acl.id})
      |> CheckAclApiKey.call([])

    refute acl_conn.halted

    session_conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)
      |> CheckJsonApiAuth.call([])

    refute session_conn.halted
    assert session_conn.assigns.current_user.id == user.id
    assert Ash.PlugHelpers.get_actor(session_conn).user.id == user.id
    assert_receive :boundary_db_query
  end

  test "ordinary API rejects before content negotiation without map auth" do
    conn =
      integration_conn()
      |> put_req_header("accept", "text/html")
      |> get("/api/common/system-static-info?solar_system_id=30000142")

    assert_forbidden(conn)
  end

  test "ordinary API rejects mixed headers through actual map and ACL routes", %{
    map: map,
    acl: acl
  } do
    for {path, key} <- [
          {"/api/maps/#{map.slug}/systems", map.public_api_key},
          {"/api/acls/#{acl.id}", acl.api_key}
        ],
        values <- [["Bearer #{key}", "Bearer #{@token}"], ["Bearer #{@token}", "Bearer #{key}"]] do
      conn = build_conn() |> authorization_headers(values) |> get(path)
      assert_forbidden(conn)
    end
  end

  test "v1 rejects a valid owner session before falling back to it", %{user: user} do
    conn =
      integration_conn()
      |> put_req_header("content-type", "application/vnd.api+json")
      |> Plug.Test.init_test_session(user_id: user.id)
      |> get("/api/v1/map_systems")

    assert_forbidden(conn)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/vnd.api+json")
      |> Plug.Test.init_test_session(user_id: user.id)
      |> get("/api/v1/map_systems")

    assert %{"data" => _} = json_response(conn, 200)
    assert conn.assigns.current_user.id == user.id
  end

  for accept <- ["text/html", "application/json"] do
    test "browser rejects mixed owner session with accept #{accept}", %{map: map, user: user} do
      conn =
        integration_conn()
        |> Plug.Test.init_test_session(user_id: user.id)
        |> put_req_header("accept", unquote(accept))
        |> get("/maps/#{map.slug}/settings")

      assert_forbidden(conn)
      assert Repo.get!(Api.Map, map.id).public_api_key == map.public_api_key
    end
  end

  test "enabled SSE reaches map auth and rejects the namespace", %{map: map} do
    original = Application.fetch_env!(:wanderer_app, :sse)
    Application.put_env(:wanderer_app, :sse, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:wanderer_app, :sse, original) end)

    path = "/api/maps/#{map.slug}/events/stream"

    assert_forbidden(
      integration_conn()
      |> put_req_header("accept", "text/event-stream")
      |> get(path)
    )

    # A normal bad key reaches CheckMapApiKey, rather than the default 503 gate.
    conn = build_conn() |> put_req_header("authorization", "Bearer wrong-key") |> get(path)
    assert %{"error" => "Unauthorized (invalid token for map)"} = json_response(conn, 401)

    conn = build_conn() |> put_api_key(map.public_api_key) |> get(path)
    assert conn.assigns.map_id == map.id
    assert conn.assigns.current_character.id == map.owner_id
    assert json_response(conn, 403)["code"] == "SSE_DISABLED_FOR_MAP"
  end

  test "experimental routes reject before dispatch, including their canned create", %{map: map} do
    before = Repo.all(Api.Map)
    payload = %{"name" => "Boundary map", "owner_id" => map.owner_id}

    # The forwarded prefix differs from the route table. Neither response is a
    # mutation positive control: one misses and the other is explicitly canned.
    missing =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/versioned/maps", payload)

    assert json_response(missing, 404)["error"]["code"] == "ROUTE_NOT_FOUND"

    canned =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/versioned/api/v1/maps", payload)

    assert json_response(canned, 200)["data"]["id"] == "new-map-id"
    assert Repo.all(Api.Map) == before

    for path <- ["/api/versioned/maps", "/api/versioned/api/v1/maps"] do
      assert_forbidden(integration_conn() |> post(path, payload))
    end
  end

  test "experimental rejection precedes request validation" do
    conn =
      integration_conn()
      |> put_req_header("content-type", "application/xml")
      |> post("/api/versioned/api/v1/maps", "<map/>")

    assert_forbidden(conn)
  end

  describe "real mutation routes" do
    setup %{map: map, acl: acl, character: character} do
      insert(:map_character_settings, %{map_id: map.id, character_id: character.id})
      system = insert(:map_system, %{map_id: map.id, solar_system_id: 30_000_142})
      deletable_system = insert(:map_system, %{map_id: map.id, solar_system_id: 30_002_659})
      connection = insert(:map_connection, %{map_id: map.id})

      signature =
        insert(:map_system_signature, %{system_id: system.id, character_eve_id: character.eve_id})

      structure =
        insert(:map_system_structure, %{system_id: system.id, character_eve_id: character.eve_id})

      member = insert(:access_list_member, %{access_list_id: acl.id})
      insert(:map_access_list, %{map_id: map.id, access_list_id: acl.id})

      %{
        system: system,
        deletable_system: deletable_system,
        connection: connection,
        signature: signature,
        structure: structure,
        member: member
      }
    end

    test "legacy mutation families reject valid payloads without writes or events", context do
      watch_mutations(context)
      before = persisted_state()

      for {method, path, payload} <- legacy_mutations(context) do
        assert_forbidden(dispatch(integration_conn(), @endpoint, method, path, payload))
      end

      assert persisted_state() == before
      refute_receive {:boundary_mutation, _, _}, 100
      refute_receive {:boundary_external_event, _}, 0
      refute_receive {:acl_updated, _}, 0
      refute_receive %Phoenix.Socket.Broadcast{}, 0
    end

    test "ordinary legacy keys still perform representative mutations", context do
      WandererApp.TestHelpers.ensure_map_server_started(context.map.id)
      watch_mutations(context)

      for {method, path, payload} <- legacy_mutations(context) do
        key =
          if String.starts_with?(path, "/api/acls/"),
            do: context.acl.api_key,
            else: context.map.public_api_key

        conn = dispatch(build_conn() |> put_api_key(key), @endpoint, method, path, payload)
        assert conn.status == 200, "#{method} #{path}: #{conn.status} #{conn.resp_body}"
      end

      assert Repo.get!(Api.MapSystem, context.system.id).description == "Boundary update"
      assert Repo.get!(Api.MapConnection, context.connection.id).mass_status == 1

      assert Repo.get!(Api.MapSystemSignature, context.signature.id).description ==
               "Boundary update"

      assert Repo.get!(Api.MapSystemStructure, context.structure.id).name == "Boundary structure"
      assert Repo.get!(Api.AccessList, context.acl.id).description == "Boundary update"
      assert Repo.get!(Api.AccessListMember, context.member.id).role == :admin
      assert_receive {:boundary_mutation, _, _}
      assert_receive {:boundary_external_event, _}
    end

    test "v1 create update and delete reject without writes or events", context do
      watch_mutations(context)
      before = persisted_state()

      for {method, path, payload} <- v1_mutations(context) do
        conn = integration_conn() |> put_req_header("content-type", "application/vnd.api+json")
        assert_forbidden(dispatch(conn, @endpoint, method, path, payload))
      end

      assert persisted_state() == before
      refute_receive {:boundary_mutation, _, _}, 100
      refute_receive {:boundary_external_event, _}, 0
      refute_receive %Phoenix.Socket.Broadcast{}, 0
    end

    test "ordinary v1 key creates updates and deletes persisted systems", context do
      for {method, path, payload} <- v1_mutations(context) do
        conn =
          dispatch(
            create_authenticated_conn(build_conn(), context.map),
            @endpoint,
            method,
            path,
            payload
          )

        assert conn.status == if(method == :post, do: 201, else: 200)

        if method == :patch do
          assert Repo.get!(Api.MapSystem, context.system.id).description == "Boundary update"
        end
      end

      assert Repo.get_by!(Api.MapSystem, map_id: context.map.id, solar_system_id: 30_002_187).name ==
               "Amarr"

      assert Repo.get(Api.MapSystem, context.deletable_system.id) == nil
    end

    test "alternative transports do not authenticate or demote ordinary authority", context do
      payload = %{"description" => @token}

      path =
        "/api/maps/#{context.map.slug}/systems/#{context.system.solar_system_id}?api_key=#{@token}"

      conn =
        build_conn()
        |> put_req_header("x-api-key", @token)
        |> put_req_cookie("integration_token", @token)

      assert json_response(patch(conn, path, payload), 401)
      assert Repo.get!(Api.MapSystem, context.system.id).description == context.system.description

      WandererApp.TestHelpers.ensure_map_server_started(context.map.id)
      conn = conn |> put_api_key(context.map.public_api_key) |> patch(path, payload)
      assert json_response(conn, 200)
      assert Repo.get!(Api.MapSystem, context.system.id).description == @token
    end
  end

  test "token alone cannot join the live management channel or mount settings", %{map: map} do
    assert {:ok, socket} =
             Phoenix.ChannelTest.connect(Phoenix.LiveView.Socket, %{"token" => @token},
               connect_info: %{session: %{}}
             )

    assert {:error, %{reason: "stale"}} =
             subscribe_and_join(socket, "lv:integration-token-only", %{
               "session" => @token,
               "url" => @endpoint.url() <> "/maps/#{map.slug}/settings"
             })

    assert {:error, {:redirect, %{to: "/welcome"}}} =
             live(build_conn(), "/maps/#{map.slug}/settings?token=#{@token}")

    assert Repo.get!(Api.Map, map.id).public_api_key == map.public_api_key
  end

  test "independent browser session can mount and manage with irrelevant token data", %{
    map: map,
    user: user
  } do
    WandererApp.TestHelpers.ensure_map_server_started(map.id)
    conn = build_conn() |> Plug.Test.init_test_session(user_id: user.id)
    conn = put_connect_params(conn, %{"token" => @token, "authorization" => "Bearer #{@token}"})
    assert {:ok, view, _html} = live(conn, "/maps/#{map.slug}/settings?token=#{@token}")
    render_click(view, "generate-map-api-key", %{"token" => @token})
    new_key = Repo.get!(Api.Map, map.id).public_api_key
    assert is_binary(new_key)
    refute new_key in [map.public_api_key, @token]
  end

  defp integration_conn do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp authorization_headers(conn, values) do
    # put_req_header replaces values and cannot exercise duplicate-header attacks.
    %{conn | req_headers: Enum.map(values, &{"authorization", &1}) ++ conn.req_headers}
  end

  defp assert_forbidden(conn) do
    assert conn.status == 403,
           "expected namespace rejection, got #{inspect(conn.status)} #{inspect(conn.resp_body)}"

    assert conn.halted

    assert json_response(conn, 403) == %{
             "error" => "Integration tokens cannot access this endpoint",
             "code" => "token_scope_forbidden"
           }

    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "etag") == []
    assert get_resp_header(conn, "x-wanderer-locations-version") == ["1"]
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="insufficient_scope")]
    assert byte_size(conn.resp_body) < 100
    refute conn.resp_body =~ "wmi_"

    for key <- [
          :current_user,
          :current_character,
          :map,
          :map_id,
          :owner_user_id,
          :owner_character_id
        ] do
      refute Map.has_key?(conn.assigns, key)
    end

    refute Ash.PlugHelpers.get_actor(conn)
  end

  defp watch_queries do
    id = {__MODULE__, self()}
    pid = self()

    :ok =
      :telemetry.attach(
        id,
        [:wanderer_app, :repo, :query],
        fn _, _, _, _ ->
          if self() == pid, do: send(pid, :boundary_db_query)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp watch_mutations(%{map: map, acl: acl}) do
    pid = self()
    id = {__MODULE__, :external_events, pid}

    :ok =
      :telemetry.attach(
        id,
        [:wanderer_app, :external_events, :broadcast],
        fn _, _, metadata, _ ->
          if metadata.map_id == map.id,
            do: send(pid, {:boundary_external_event, metadata.event_type})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    topics = ["maps:#{map.id}", "acls:#{acl.id}", map.id]
    Enum.each(topics, &Phoenix.PubSub.subscribe(WandererApp.PubSub, &1))
    # The standard test support discards these broadcasts; observe delivery at
    # that boundary instead, including map-server processes using global Mox.
    for function <- [:broadcast, :broadcast!] do
      Mox.stub(Test.PubSubMock, function, fn server, topic, message ->
        if topic in topics, do: send(pid, {:boundary_mutation, topic, message})
        Phoenix.PubSub.broadcast(server, topic, message)
      end)
    end
  end

  defp persisted_state do
    for resource <- [
          Api.Map,
          Api.MapSystem,
          Api.MapConnection,
          Api.MapSystemSignature,
          Api.MapSystemStructure,
          Api.AccessList,
          Api.AccessListMember
        ] do
      {resource, Repo.all(resource) |> Enum.sort_by(& &1.id)}
    end
  end

  defp legacy_mutations(c) do
    base = "/api/maps/#{c.map.slug}"

    [
      {:patch, "#{base}/systems/#{c.system.solar_system_id}",
       %{"description" => "Boundary update"}},
      {:patch, "#{base}/connections/#{c.connection.id}", %{"mass_status" => 1}},
      {:patch, "#{base}/signatures/#{c.signature.id}", %{"description" => "Boundary update"}},
      {:patch, "#{base}/structures/#{c.structure.id}", %{"name" => "Boundary structure"}},
      {:put, "/api/acls/#{c.acl.id}", %{"acl" => %{"description" => "Boundary update"}}},
      {:put, "/api/acls/#{c.acl.id}/members/#{c.member.eve_character_id}",
       %{"member" => %{"role" => "admin"}}}
    ]
  end

  defp v1_mutations(c) do
    [
      {:post, "/api/v1/map_systems",
       %{
         "data" => %{
           "type" => "map_systems",
           "attributes" => %{
             "solar_system_id" => 30_002_187,
             "name" => "Amarr",
             "position_x" => 100,
             "position_y" => 200
           }
         }
       }},
      {:patch, "/api/v1/map_systems/#{c.system.id}",
       %{
         "data" => %{
           "type" => "map_systems",
           "id" => c.system.id,
           "attributes" => %{"description" => "Boundary update"}
         }
       }},
      {:delete, "/api/v1/map_systems/#{c.deletable_system.id}", nil}
    ]
  end
end
