defmodule WandererAppWeb.PrejumpPrimeStagingTest do
  use WandererAppWeb.ApiCase, async: false

  alias WandererApp.MapIntegrationTokens, as: Tokens
  alias WandererApp.PrejumpPrimes, as: Primes

  @version_header {"x-wanderer-primes-version", "1"}

  setup do
    user = insert(:user)
    owner = insert(:character, %{user_id: user.id})
    map = insert(:map, %{owner_id: owner.id})
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)

    on_exit(fn -> Application.delete_env(:wanderer_app, :map_integrations_enabled) end)

    {:ok, %{enabled: true}} = Tokens.set_enabled(map.id, user, true)
    {:ok, %{token: token}} = Primes.generate_prime_token(map.id, user)

    {:ok, %{token: read_token}} = Tokens.generate(map.id, user)

    %{user: user, map: map, wire: token.value, read_wire: read_token.value}
  end

  test "stages a prime over HTTP and is idempotent per event ID", %{map: map, wire: wire} do
    event_id = Ash.UUID.generate()

    body =
      Jason.encode!(%{
        prime: %{
          event_id: event_id,
          eve_character_id: 90_000_001,
          source_solar_system_id: 30_000_142,
          system_name: "J123",
          flags: %{eol: true, frigate: true}
        }
      })

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{wire}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header(elem(@version_header, 0), elem(@version_header, 1))
      |> post("/api/maps/#{map.slug}/prejump-primes", body)

    assert %{"staged" => true, "event_id" => ^event_id} = json_response(conn, 200)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-wanderer-primes-version") == ["1"]

    # Replay: same event id, 200 again, no duplicate/replacement.
    conn2 =
      build_conn()
      |> put_req_header("authorization", "Bearer #{wire}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/maps/#{map.slug}/prejump-primes", body)

    assert json_response(conn2, 200)["staged"] == true
    assert {:ok, stored} = Primes.lookup(map.id, 90_000_001)
    assert stored.event_id == event_id
    assert stored.flags == %{eol: true, half_mass: false, critical: false, frigate: true}
  end

  test "read-scope token is rejected with scope_forbidden", %{map: map, read_wire: read_wire} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{read_wire}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/maps/#{map.slug}/prejump-primes", valid_body())

    assert %{"code" => "scope_forbidden"} = json_response(conn, 403)
    assert get_resp_header(conn, "www-authenticate") != []
  end

  test "map API key is rejected by the prime pipeline", %{map: map} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{map.public_api_key}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/maps/#{map.slug}/prejump-primes", valid_body())

    assert conn.status == 403
    refute conn.resp_body =~ "staged"
  end

  test "malformed payloads fail closed without staging", %{map: map, wire: wire} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{wire}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/maps/#{map.slug}/prejump-primes", Jason.encode!(%{prime: %{event_id: "x"}}))

    assert %{"code" => "invalid_request"} = json_response(conn, 400)
    assert {:error, :not_found} = Primes.lookup(map.id, 90_000_001)
  end

  test "unknown version header is 406", %{map: map, wire: wire} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{wire}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-wanderer-primes-version", "9")
      |> post("/api/maps/#{map.slug}/prejump-primes", valid_body())

    assert %{"code" => "not_acceptable"} = json_response(conn, 406)
  end

  test "prime token remains rejected by every ordinary surface", %{map: map, wire: wire} do
    # Tracked locations read endpoint
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{wire}")
      |> get("/api/maps/#{map.slug}/tracked-character-locations")

    assert conn.status == 403

    # Map CRUD
    conn2 =
      build_conn()
      |> put_req_header("authorization", "Bearer #{wire}")
      |> get("/api/maps/#{map.slug}/systems")

    assert conn2.status in [401, 403]
  end

  test "unknown map is 404, not 503", %{wire: wire} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{wire}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/maps/00000000-0000-0000-0000-000000000000/prejump-primes", valid_body())

    assert %{"code" => "map_not_found"} = json_response(conn, 404)
  end

  test "prime remains usable after read-scope credential issuance for the same user+map", %{
    map: map,
    user: user,
    wire: wire
  } do
    assert {:ok, principal} = Primes.authenticate(wire)

    prime = %{
      event_id: Ash.UUID.generate(),
      eve_character_id: 90_000_001,
      source_solar_system_id: 30_000_142,
      system_name: "J123",
      flags: %{}
    }

    assert :ok = Primes.stage(map.id, principal, prime)
    assert {:ok, _} = Primes.lookup(map.id, 90_000_001)
  end

  defp valid_body do
    Jason.encode!(%{
      prime: %{
        event_id: Ash.UUID.generate(),
        eve_character_id: 90_000_001,
        source_solar_system_id: 30_000_142,
        system_name: "J123",
        flags: %{}
      }
    })
  end
end
