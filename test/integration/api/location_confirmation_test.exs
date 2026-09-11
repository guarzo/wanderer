defmodule WandererApp.LocationConfirmationTest do
  use WandererAppWeb.ApiCase, async: false
  alias WandererApp.Api
  alias WandererApp.Character.LocationConfirmations, as: Store
  alias WandererApp.Character.Tracker
  alias WandererApp.Esi.ApiClient

  setup do
    character = insert(:character)
    {:ok, character} = Api.Character.update_location(character, %{solar_system_id: 30_000_142})
    state = Tracker.new(character_id: character.id, track_location: true, is_online: true)
    original = Req.default_options()
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)

    on_exit(fn ->
      Req.default_options(original)
      Application.delete_env(:wanderer_app, :map_integrations_enabled)
      Cachex.del(:character_cache, character.id)
      Cachex.del(:api_cache, "/characters/#{character.eve_id}/location")
      Cachex.del(:api_cache, "/characters/#{character.eve_id}/online")
    end)

    %{character: character, state: state}
  end

  test "scheduled stationary tracking confirms real 200s before movement dedup without DB heartbeat",
       %{character: char, state: state} do
    parent = self()

    Req.default_options(
      plug: fn conn ->
        send(parent, {:http, conn.request_path, Plug.Conn.get_req_header(conn, "if-none-match")})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("etag", "same")
        |> Plug.Conn.send_resp(200, ~s({"solar_system_id":30000142}))
      end
    )

    path = "/characters/#{char.eve_id}/location"
    Cachex.put(:api_cache, path, %{"solar_system_id" => 30_002_187})
    before = Api.Character.by_id!(char.id)
    assert :ok = Tracker.update_location(state)
    assert_receive {:http, ^path, []}
    assert {:ok, %{entries: entries}} = Store.snapshot()
    first = Map.fetch!(entries, char.id)
    assert first.solar_system_id == 30_000_142
    assert first.fingerprint == Store.fingerprint(char.access_token)
    assert :ok = Tracker.update_location(state)
    assert_receive {:http, ^path, []}
    assert {:ok, %{entries: entries}} = Store.snapshot()
    assert DateTime.compare(entries[char.id].observed_at, first.observed_at) == :gt
    assert Api.Character.by_id!(char.id).updated_at == before.updated_at
    assert Cachex.get!(:api_cache, path) == %{"solar_system_id" => 30_002_187}
  end

  test "a fixture HTTP movement confirms and persists the new system while other calls keep their cache contract",
       %{character: char, state: state} do
    Req.default_options(
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"solar_system_id":30002187}))
      end
    )

    assert :ok = Tracker.update_location(state)
    assert Api.Character.by_id!(char.id).solar_system_id == 30_002_187
    assert {:ok, %{entries: entries}} = Store.snapshot()
    assert entries[char.id].solar_system_id == 30_002_187
    Cachex.put(:api_cache, "/characters/#{char.eve_id}/online", %{"online" => true})

    assert {:ok, %{"online" => true}} =
             ApiClient.get_character_online(char.eve_id,
               character_id: char.id,
               access_token: char.access_token,
               confirm_location?: true
             )
  end

  test "only opt-in location bypasses caches and emits fresh evidence", %{character: char} do
    Req.default_options(
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("etag", "fixture")
        |> Plug.Conn.send_resp(200, ~s({"solar_system_id":30000142}))
      end
    )

    opts = [character_id: char.id, access_token: char.access_token]
    path = "/characters/#{char.eve_id}/location"
    # Warm Req's response cache, then reject any conditional request at the HTTP boundary.
    assert {:ok, %{"solar_system_id" => 30_000_142}} =
             ApiClient.get_character_location(char.eve_id, opts)

    Req.default_options(
      plug: fn conn ->
        assert Plug.Conn.get_req_header(conn, "if-none-match") == []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"solar_system_id":300002187}))
      end
    )

    assert {:ok, %{"solar_system_id" => 300_002_187}, %DateTime{}} =
             ApiClient.get_character_location(
               char.eve_id,
               Keyword.put(opts, :confirm_location?, true)
             )

    Cachex.put(:api_cache, path, %{"solar_system_id" => 30_000_142})

    assert {:ok, %{"solar_system_id" => 30_000_142}} =
             ApiClient.get_character_location(char.eve_id, opts)

    Application.put_env(:wanderer_app, :map_integrations_enabled, false)

    assert :ok =
             Tracker.update_location(
               Tracker.new(character_id: char.id, track_location: true, is_online: true)
             )

    assert {:ok, %{entries: entries}} = Store.snapshot()
    refute Map.has_key?(entries, char.id)
  end

  test "304, invalid bodies, HTTP failures and offline tracking never confirm", %{
    character: char,
    state: state
  } do
    for {status, body} <- [
          {304, ""},
          {200, ~s({"solar_system_id":"30000142"})},
          {200, "{}"},
          {500, "{}"}
        ] do
      Req.default_options(
        plug: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, body)
        end
      )

      assert {:error, :skipped} = Tracker.update_location(state)
      assert {:ok, %{entries: entries}} = Store.snapshot()
      refute Map.has_key?(entries, char.id)
      WandererApp.Cache.delete("character:#{char.id}:location_forbidden")
    end

    Req.default_options(plug: fn _ -> flunk("offline tracking must not call HTTP") end)
    assert {:error, :skipped} = Tracker.update_location(%{state | is_online: false})
  end

  test "expiry boundary and future timestamps cannot extend freshness", %{character: char} do
    {:ok, ticket} = Store.begin_request(char.id, char.access_token)
    now = DateTime.utc_now()
    assert :ok = Store.confirm(ticket, 30_000_142, now)

    assert {:ok, %{entries: entries}} =
             Store.snapshot(DateTime.add(now, 14_999_999, :microsecond))

    assert entries[char.id].solar_system_id == 30_000_142
    assert {:ok, %{entries: entries}} = Store.snapshot(DateTime.add(now, 15, :second))
    refute Map.has_key?(entries, char.id)
    {:ok, next} = Store.begin_request(char.id, char.access_token)

    assert :discarded =
             Store.confirm(next, 30_000_142, DateTime.add(DateTime.utc_now(), 1, :second))
  end

  test "late requests cannot overwrite newer dispatches or survive a store restart", %{
    character: char
  } do
    {:ok, old} = Store.begin_request(char.id, char.access_token)
    {:ok, newer} = Store.begin_request(char.id, char.access_token)
    assert :ok = Store.confirm(newer, 30_002_187, DateTime.utc_now())
    assert :discarded = Store.confirm(old, 30_000_142, DateTime.utc_now())
    assert {:ok, %{entries: entries}} = Store.snapshot()
    assert entries[char.id].solar_system_id == 30_002_187
    :ok = Supervisor.terminate_child(WandererApp.Supervisor, Store)
    assert {:error, :service_unavailable} = Store.snapshot()
    {:ok, _} = Supervisor.restart_child(WandererApp.Supervisor, Store)
    assert :discarded = Store.confirm(newer, 30_000_142, DateTime.utc_now())
    assert {:ok, %{entries: %{}}} = Store.snapshot()
  end
end
