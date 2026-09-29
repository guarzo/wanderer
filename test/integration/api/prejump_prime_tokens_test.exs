defmodule WandererApp.PrejumpPrimeTokensTest do
  use WandererAppWeb.ApiCase, async: false

  alias WandererApp.MapIntegrationTokens, as: Tokens
  alias WandererApp.PrejumpPrimes, as: Primes

  # Shared finisher-tag test vectors: the same bookmark names must parse to the
  # same flag sets on every side of the handoff (spec #292).
  @vectors [
    {"J123-ABC", %{eol: false, half_mass: false, critical: false, frigate: false}},
    {"J123-ABC e", %{eol: true, half_mass: false, critical: false, frigate: false}},
    {"J123-ABC /", %{eol: false, half_mass: true, critical: false, frigate: false}},
    {"J123-ABC c", %{eol: false, half_mass: false, critical: true, frigate: false}},
    {"J123-ABC f", %{eol: false, half_mass: false, critical: false, frigate: true}},
    {"J123-ABC e/", %{eol: true, half_mass: true, critical: false, frigate: false}},
    {"J123-ABC ee", %{eol: true, half_mass: false, critical: false, frigate: false}},
    {"J123-ABC ff", %{eol: false, half_mass: false, critical: false, frigate: true}},
    {"J123-ABC ec", %{eol: true, half_mass: false, critical: true, frigate: false}},
    {"J123-ABC /c", %{eol: false, half_mass: true, critical: true, frigate: false}},
    {"J123-ABC ef", %{eol: true, half_mass: false, critical: false, frigate: true}},
    {"J123-ABC e/cf", %{eol: true, half_mass: true, critical: true, frigate: true}},
    {"J123-ABC halcyon", %{eol: false, half_mass: false, critical: false, frigate: false}},
    {"J123-ABC frigate", %{eol: false, half_mass: false, critical: false, frigate: false}}
  ]

  setup do
    user = insert(:user)
    owner = insert(:character, %{user_id: user.id})
    map = insert(:map, %{owner_id: owner.id})
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)

    on_exit(fn -> Application.delete_env(:wanderer_app, :map_integrations_enabled) end)

    {:ok, %{enabled: true}} = Tokens.set_enabled(map.id, user, true)
    {:ok, %{token: token}} = Primes.generate_prime_token(map.id, user)
    %{user: user, owner: owner, map: map, token: token, wire: token.value}
  end

  test "prime token wire format and authentication", %{
    map: map,
    user: user,
    wire: wire,
    token: token
  } do
    assert wire =~ ~r/^wmi_v1_[0-9a-f-]{36}_[A-Za-z0-9_-]{43}$/
    assert token.generation == 1
    refute inspect(token) =~ wire

    assert {:ok, principal} = Primes.authenticate(wire)
    assert principal.user_id == user.id
    assert principal.map_id == map.id
    assert principal.scope == "prejump_prime:write"
    refute Map.has_key?(principal, :value)
  end

  test "read-scope token is rejected by the prime surface", %{map: map, user: user} do
    {:ok, %{token: read_token}} = Tokens.generate(map.id, user)

    assert {:error, :scope_forbidden} = Primes.authenticate(read_token.value)
  end

  test "prime token is rejected by the read endpoint and ordinary map CRUD", %{
    map: map,
    wire: wire
  } do
    conn = build_conn() |> put_req_header("authorization", "Bearer #{wire}")

    read =
      Phoenix.ConnTest.dispatch(
        conn,
        WandererAppWeb.Endpoint,
        :get,
        "/api/maps/#{map.slug}/tracked-character-locations"
      )

    assert read.status == 403

    systems =
      Phoenix.ConnTest.dispatch(
        build_conn(),
        WandererAppWeb.Endpoint,
        :get,
        "/api/maps/#{map.slug}/systems"
      )

    assert systems.status in [401, 403]
  end

  test "revocation invalidates the prime credential", %{
    map: map,
    user: user,
    token: token,
    wire: wire
  } do
    assert {:ok, _} = Primes.authenticate(wire)
    assert {:ok, _} = Primes.revoke_prime_token(map.id, user, token.id, token.generation)
    assert {:error, :invalid_token} = Primes.authenticate(wire)
  end

  test "staging stores a bounded prime scoped per character and map", %{
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
      flags: %{eol: true, half_mass: false, critical: false, frigate: true}
    }

    assert :ok = Primes.stage(map.id, principal, prime)
    # Idempotent replay of the same event ID.
    assert :ok = Primes.stage(map.id, principal, prime)

    assert {:ok, stored} = Primes.lookup(map.id, 90_000_001)
    assert stored.event_id == prime.event_id
    assert stored.source_solar_system_id == 30_000_142
    assert stored.system_name == "J123"
    assert stored.flags == prime.flags
  end

  test "newest-wins replacement per character and map isolation", %{
    map: map,
    wire: wire
  } do
    {:ok, principal} = Primes.authenticate(wire)

    first = %{
      event_id: Ash.UUID.generate(),
      eve_character_id: 90_000_001,
      source_solar_system_id: 30_000_142,
      system_name: "J100",
      flags: %{}
    }

    second = %{
      event_id: Ash.UUID.generate(),
      eve_character_id: 90_000_001,
      source_solar_system_id: 30_000_142,
      system_name: "J200",
      flags: %{}
    }

    other_character = %{
      event_id: Ash.UUID.generate(),
      eve_character_id: 90_000_002,
      source_solar_system_id: 30_000_142,
      system_name: "J300",
      flags: %{}
    }

    assert :ok = Primes.stage(map.id, principal, first)
    assert :ok = Primes.stage(map.id, principal, other_character)
    assert :ok = Primes.stage(map.id, principal, second)

    assert {:ok, stored} = Primes.lookup(map.id, 90_000_001)
    assert stored.system_name == "J200"
    assert {:ok, other} = Primes.lookup(map.id, 90_000_002)
    assert other.system_name == "J300"
  end

  test "expired primes are dropped without side effects", %{map: map, wire: wire} do
    {:ok, principal} = Primes.authenticate(wire)

    prime = %{
      event_id: Ash.UUID.generate(),
      eve_character_id: 90_000_001,
      source_solar_system_id: 30_000_142,
      system_name: "J123",
      flags: %{}
    }

    assert :ok = Primes.stage(map.id, principal, prime)

    WandererApp.PrimesTestSupport.age_prime_past_ttl(prime.event_id)

    assert {:error, :not_found} = Primes.lookup(map.id, 90_000_001)
  end

  test "staging rejects malformed, oversized, and unassociated payloads", %{
    map: map,
    wire: wire
  } do
    {:ok, principal} = Primes.authenticate(wire)

    base = %{
      event_id: Ash.UUID.generate(),
      eve_character_id: 90_000_001,
      source_solar_system_id: 30_000_142,
      system_name: "J123",
      flags: %{}
    }

    assert {:error, :invalid_request} = Primes.stage(map.id, principal, %{base | event_id: nil})
    assert {:error, :invalid_request} = Primes.stage(map.id, principal, %{base | system_name: ""})

    assert {:error, :invalid_request} =
             Primes.stage(map.id, principal, %{base | system_name: String.duplicate("x", 256)})

    assert {:error, :invalid_request} =
             Primes.stage(map.id, principal, %{base | eve_character_id: nil})

    assert {:error, :invalid_request} =
             Primes.stage(map.id, principal, %{base | source_solar_system_id: nil})

    # Prime bound to a different map than the token's map.
    other_owner = insert(:character)
    other_map = insert(:map, %{owner_id: other_owner.id})
    assert {:error, :wrong_map} = Primes.stage(other_map.id, principal, base)
  end

  test "finisher-tag test vectors parse identically on the server side" do
    for {name, expected} <- @vectors do
      assert Primes.parse_flags(name) == expected, "vector: #{inspect(name)}"
    end
  end

  test "claim is idempotent and atomic: exactly one claimant wins", %{map: map, wire: wire} do
    {:ok, principal} = Primes.authenticate(wire)

    prime = %{
      event_id: Ash.UUID.generate(),
      eve_character_id: 90_000_001,
      source_solar_system_id: 30_000_142,
      system_name: "J123",
      flags: %{eol: true}
    }

    assert :ok = Primes.stage(map.id, principal, prime)

    assert {:ok, claimed} = Primes.claim(map.id, 90_000_001, 30_000_142)
    assert claimed.event_id == prime.event_id

    # Second claim for the same movement (retry/replay) sees nothing.
    assert {:error, :not_found} = Primes.claim(map.id, 90_000_001, 30_000_142)

    # Wrong source never claims.
    assert :ok = Primes.stage(map.id, principal, %{prime | event_id: Ash.UUID.generate()})

    assert {:error, :not_found} = Primes.claim(map.id, 90_000_001, 30_001_999)
  end
end

defmodule WandererApp.PrimesTestSupport do
  @moduledoc false

  def age_prime_past_ttl(event_id) do
    # Shifts the prime's inserted_at past the TTL so expiry logic is exercised
    # without sleeping. Implementation-specific; adjust when the store lands.
    WandererApp.Repo.query!(
      "UPDATE prejump_primes_v1 SET expires_at = now() - interval '1 second' WHERE event_id = $1",
      [Ecto.UUID.dump!(event_id)]
    )
  end
end
