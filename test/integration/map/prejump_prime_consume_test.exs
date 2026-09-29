defmodule WandererApp.Map.PrejumpPrimeConsumeTest do
  @moduledoc """
  Movement-seam integration tests for the pre-jump prime handoff
  (issue #281, ticket #294).

  A staged prime is consumed exactly once, when the tracked character's
  movement creates a NEW connection whose source matches the prime's expected
  source system: the J-code names the destination system (when it is also
  new) and the flags ride into the connection at creation time. Wrong source,
  expiry, an already-connected pair, and duplicate polls leave the map
  untouched and the prime unconsumed.
  """

  use WandererApp.IntegrationCase, async: false

  @moduletag :shared_sandbox

  import Mox

  setup :verify_on_exit!

  import WandererApp.MapTestHelpers

  alias WandererApp.Map.Server.CharactersImpl
  alias WandererApp.PrejumpPrimes, as: Primes

  @test_character_eve_id 2_123_456_789

  # Jita is deliberately NOT used (prohibited on maps); see the prior-art
  # location-tracking test for the full rationale.
  @system_hek 30_002_053
  @system_amarr 30_002_187
  @system_dodixie 30_002_659

  setup do
    setup_system_static_info_cache()
    setup_ddrt_mocks()

    user = create_user(%{name: "Prime User", hash: "test_hash_#{:rand.uniform(1_000_000)}"})

    character =
      create_character(%{
        eve_id: "#{@test_character_eve_id}",
        name: "Prime Character",
        user_id: user.id,
        scopes: "esi-location.read_location.v1 esi-location.read_ship_type.v1",
        tracking_pool: "default"
      })

    map =
      create_map(%{
        name: "Prime Consume",
        slug: "prime-consume-#{:rand.uniform(1_000_000)}",
        owner_id: character.id,
        scope: :all,
        scopes: [:hi, :low, :null, :pochven, :wormholes],
        only_tracked_characters: false
      })

    # Prime staging/consuming requires map integrations to be enabled
    # (same switch the staging tests set) and an active subscription policy.
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)
    Application.put_env(:wanderer_app, :public_api_disabled, false)

    # Same enablement the staging tests use: integrations on globally, and the
    # map's location-API flag on (Tokens.authorize/1 checks both).
    {:ok, _} = WandererApp.MapIntegrationTokens.set_enabled(map.id, user, true)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :map_integrations_enabled)
      Application.delete_env(:wanderer_app, :public_api_disabled)
      cleanup_test_data(map.id)
    end)

    {:ok, user: user, character: character, map: map}
  end

  defp stage_prime(map, character, overrides) do
    base = %{
      event_id: Ash.UUID.generate(),
      eve_character_id: String.to_integer(character.eve_id),
      source_solar_system_id: @system_hek,
      system_name: "J123",
      flags: %{}
    }

    prime = Map.merge(base, overrides)
    principal = %{map_id: map.id, user_id: character.user_id, scope: "prejump_prime:write"}

    assert :ok = Primes.stage(map.id, principal, prime)
    prime
  end

  defp connection_between(map_id, a, b) do
    {:ok, connections} = WandererApp.Map.list_connections(map_id)

    Enum.find(connections, fn c ->
      {c.solar_system_source, c.solar_system_target} in [{a, b}, {b, a}]
    end)
  end

  describe "prime consumed on a matching new-connection movement" do
    @tag :integration
    test "matching jump names the new system and flags the new connection", %{
      map: map,
      character: character
    } do
      ensure_map_started(map.id)
      track_character_on_map(map.id, character.id)

      set_character_location(character.id, @system_hek)
      CharactersImpl.update_characters(map.id)

      stage_prime(map, character, %{
        system_name: "J123",
        flags: %{eol: true, frigate: true, half_mass: true}
      })

      set_character_location(character.id, @system_amarr)
      CharactersImpl.update_characters(map.id)

      assert wait_for_system_on_map(map.id, @system_amarr)

      assert wait_until(fn ->
               case WandererApp.MapSystemRepo.get_by_map_and_solar_system_id(
                      map.id,
                      @system_amarr
                    ) do
                 {:ok, system} -> system.temporary_name == "J123"
                 _ -> false
               end
             end)

      assert wait_until(fn -> connection_between(map.id, @system_hek, @system_amarr) != nil end)

      conn = connection_between(map.id, @system_hek, @system_amarr)
      assert conn.ship_size_type == 0, "frigate -> ship_size_type 0"
      assert conn.time_status == 2, "eol -> 4h time_status bucket"
      assert conn.mass_status == 1, "half mass -> mass_status 1"

      # Consumed exactly once.
      assert {:error, :not_found} =
               Primes.claim(map.id, String.to_integer(character.eve_id), @system_hek)

      assert {:error, :not_found} = Primes.lookup(map.id, String.to_integer(character.eve_id))
    end

    @tag :integration
    test "destination already mapped: flags apply to the new connection, name untouched", %{
      map: map,
      character: character
    } do
      ensure_map_started(map.id)
      track_character_on_map(map.id, character.id)

      # The destination is already mapped before the primed jump.
      create_map_system(map.id, %{solar_system_id: @system_amarr, name: "Amarr"})

      set_character_location(character.id, @system_hek)
      CharactersImpl.update_characters(map.id)

      stage_prime(map, character, %{system_name: "J999", flags: %{critical: true}})

      set_character_location(character.id, @system_amarr)
      CharactersImpl.update_characters(map.id)

      assert wait_until(fn -> connection_between(map.id, @system_hek, @system_amarr) != nil end)

      {:ok, system} =
        WandererApp.MapSystemRepo.get_by_map_and_solar_system_id(map.id, @system_amarr)

      refute system.temporary_name == "J999", "already-mapped destination keeps its name"

      conn = connection_between(map.id, @system_hek, @system_amarr)
      assert conn.mass_status == 2, "critical flag still applies to the new connection"
    end
  end

  describe "prime not consumed" do
    @tag :integration
    test "wrong source: movement applies nothing, prime survives", %{
      map: map,
      character: character
    } do
      ensure_map_started(map.id)
      track_character_on_map(map.id, character.id)

      set_character_location(character.id, @system_dodixie)
      CharactersImpl.update_characters(map.id)

      stage_prime(map, character, %{source_solar_system_id: @system_hek, flags: %{eol: true}})

      set_character_location(character.id, @system_amarr)
      CharactersImpl.update_characters(map.id)

      assert wait_until(fn ->
               connection_between(map.id, @system_dodixie, @system_amarr) != nil
             end)

      conn = connection_between(map.id, @system_dodixie, @system_amarr)
      assert conn.time_status != 2

      assert {:ok, _} = Primes.lookup(map.id, String.to_integer(character.eve_id))

      assert {:error, :not_found} =
               Primes.claim(map.id, String.to_integer(character.eve_id), @system_dodixie)
    end

    @tag :integration
    test "expired prime: nothing applied", %{map: map, character: character} do
      ensure_map_started(map.id)
      track_character_on_map(map.id, character.id)

      set_character_location(character.id, @system_hek)
      CharactersImpl.update_characters(map.id)

      prime = stage_prime(map, character, %{flags: %{eol: true}})

      # Shift the prime past its TTL without sleeping (same trick as the
      # staging tests): expiry is DB-clock anchored, so update expires_at.
      WandererApp.Repo.query!(
        "UPDATE prejump_primes_v1 SET expires_at = now() - interval '1 second' WHERE event_id = $1",
        [Ecto.UUID.dump!(prime.event_id)]
      )

      set_character_location(character.id, @system_amarr)
      CharactersImpl.update_characters(map.id)

      assert wait_until(fn -> connection_between(map.id, @system_hek, @system_amarr) != nil end)

      conn = connection_between(map.id, @system_hek, @system_amarr)
      assert conn.time_status != 2

      {:ok, system} =
        WandererApp.MapSystemRepo.get_by_map_and_solar_system_id(map.id, @system_amarr)

      refute system.temporary_name == "J123"
    end

    @tag :integration
    test "repeat movement over the same pair: no second consume, no duplicate connection", %{
      map: map,
      character: character
    } do
      ensure_map_started(map.id)
      track_character_on_map(map.id, character.id)

      set_character_location(character.id, @system_hek)
      CharactersImpl.update_characters(map.id)

      stage_prime(map, character, %{flags: %{eol: true}})

      # First movement: creates the connection and consumes the prime.
      set_character_location(character.id, @system_amarr)
      CharactersImpl.update_characters(map.id)

      assert wait_until(fn -> connection_between(map.id, @system_hek, @system_amarr) != nil end)

      # Bounce back and repeat the same jump (duplicate/replayed polls).
      set_character_location(character.id, @system_hek)
      CharactersImpl.update_characters(map.id)
      set_character_location(character.id, @system_amarr)
      CharactersImpl.update_characters(map.id)

      assert {:error, :not_found} =
               Primes.claim(map.id, String.to_integer(character.eve_id), @system_hek)

      {:ok, connections} = WandererApp.MapConnectionRepo.get_by_map(map.id)
      assert length(connections) == 1
    end
  end
end
