defmodule WandererApp.MapIntegrationTokensTest do
  use WandererAppWeb.ApiCase, async: false

  alias WandererApp.Api
  alias WandererApp.MapIntegrationTokens, as: Tokens
  alias WandererApp.Repo
  alias WandererApp.Test.TrackedLocationsFixtures, as: Fixtures

  setup do
    user = insert(:user)
    owner = insert(:character, %{user_id: user.id})
    map = insert(:map, %{owner_id: owner.id})
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)
    on_exit(fn -> Application.delete_env(:wanderer_app, :map_integrations_enabled) end)
    %{user: user, owner: owner, map: map}
  end

  test "requires explicit map opt-in and fresh admin permission", %{map: map, user: user} do
    assert {:ok, %{available: true, enabled: false}} = Tokens.settings(map.id, user)
    assert {:ok, %{token: nil, enabled: false}} = Tokens.get(map.id, user)
    assert {:error, :disabled} = Tokens.generate(map.id, user)
    %{user: viewer} = Fixtures.viewer_access(map)
    assert {:error, :forbidden} = Tokens.set_enabled(map.id, viewer, true)
    assert {:ok, %{enabled: true}} = Tokens.set_enabled(map.id, user, true)
    assert {:ok, %{token: %{value: wire}}} = Tokens.generate(map.id, viewer)
    assert {:ok, %{user_id: id}} = Tokens.authenticate(wire)
    assert id == viewer.id
  end

  test "retrieves one encrypted personal credential without implicit generation or rotation", %{
    map: map,
    user: user
  } do
    enable(map, user)
    assert {:ok, %{token: nil}} = Tokens.get(map.id, user)
    assert {:ok, %{token: token}} = Tokens.generate(map.id, user)
    assert token.value =~ ~r/^wmi_v1_[0-9a-f-]{36}_[A-Za-z0-9_-]{43}$/
    assert token.generation == 1
    assert {:ok, %{token: ^token}} = Tokens.generate(map.id, user)
    assert {:ok, %{token: ^token}} = Tokens.get(map.id, user)
    refute inspect(token) =~ token.value
    assert_raise Protocol.UndefinedError, fn -> Jason.encode!(token) end
    stored = Repo.get!(Api.MapIntegrationToken, token.id)
    assert byte_size(stored.digest) == 32
    assert is_binary(stored.encrypted_value)
    refute :erlang.term_to_binary(stored) =~ token.value
    refute inspect(stored) =~ inspect(stored.digest)
    refute inspect(stored, limit: :infinity) =~ inspect(stored.encrypted_value, limit: :infinity)
    refute Map.has_key?(Api.MapIntegrationToken.by_id!(token.id), :value)
    assert {:ok, principal} = Tokens.authenticate(token.value)
    assert principal.user_id == user.id
    refute Map.has_key?(principal, :value)
    refute Map.has_key?(principal, :encrypted_value)
    refute Map.has_key?(principal, :digest)
    refute AshJsonApi.Resource.Info.type(Api.MapIntegrationToken)
  end

  test "keeps plaintext out of Ash inputs and redacts encrypted changesets", %{
    map: map,
    user: user
  } do
    secret = "wmi_v1_private-must-not-appear"
    {:ok, encrypted} = WandererApp.Vault.encrypt(secret)

    for action <- [:issue, :replace, :revoke] do
      refute Enum.any?(
               Ash.Resource.Info.action(Api.MapIntegrationToken, action).arguments,
               &(&1.name == :value)
             )
    end

    changeset =
      Ash.Changeset.for_create(Api.MapIntegrationToken, :issue, %{
        map_id: map.id,
        user_id: user.id,
        encrypted_value: encrypted,
        digest: "digest"
      })

    refute inspect(changeset) =~ secret
    refute inspect(changeset) =~ inspect(encrypted)

    invalid =
      Ash.Changeset.for_create(Api.MapIntegrationToken, :issue, %{encrypted_value: encrypted})

    assert {:error, error} = Ash.create(invalid)
    refute inspect(error) =~ secret
    refute inspect(error) =~ inspect(encrypted)
    refute Exception.message(error) =~ secret
  end

  test "isolates users and maps and enforces generation compare-and-swap", %{map: map, user: user} do
    enable(map, user)
    %{user: viewer} = Fixtures.viewer_access(map)
    {:ok, %{token: own}} = Tokens.generate(map.id, user)
    {:ok, %{token: other}} = Tokens.generate(map.id, viewer)
    refute own.value == other.value

    for operation <- [&Tokens.regenerate/4, &Tokens.revoke/4] do
      assert {:error, :conflict} = operation.(map.id, user, other.id, 1)
    end

    {:ok, %{token: rotated}} = Tokens.regenerate(map.id, user, own.id, 1)
    assert rotated.generation == 2
    assert {:error, :invalid_token} = Tokens.authenticate(own.value)
    assert {:error, :conflict} = Tokens.regenerate(map.id, user, own.id, 1)
    assert {:ok, %{token: ^rotated}} = Tokens.get(map.id, user)
    assert {:ok, _} = Tokens.authenticate(other.value)
    {:ok, %{token: nil}} = Tokens.revoke(map.id, user, rotated.id, 2)
    assert {:error, :invalid_token} = Tokens.authenticate(rotated.value)
    assert {:error, :conflict} = Tokens.regenerate(map.id, user, rotated.id, 3)
    {:ok, %{token: fresh}} = Tokens.generate(map.id, user)
    refute fresh.id == own.id
    second_map = insert(:map, %{owner_id: map.owner_id})
    enable(second_map, user)
    {:ok, %{token: separate}} = Tokens.generate(second_map.id, user)
    refute separate.value == fresh.value
    assert {:error, :conflict} = Tokens.revoke(second_map.id, user, fresh.id, 1)
  end

  for operation <- [:regenerate, :revoke], target <- [:own, :other_user, :other_map] do
    test "#{operation} rejects noncanonical #{target} IDs without changing credentials", c do
      enable(c.map, c.user)

      {caller, token_map, token_user} =
        case unquote(target) do
          :own ->
            {c.user, c.map, c.user}

          :other_user ->
            %{user: reader} = Fixtures.viewer_access(c.map)
            {reader, c.map, c.user}

          :other_map ->
            other_map = insert(:map, %{owner_id: c.owner.id})
            enable(other_map, c.user)
            {c.user, other_map, c.user}
        end

      token = known_token(token_map, token_user)
      stored = Repo.get!(Api.MapIntegrationToken, token.id)

      for generation <- [token.generation, token.generation + 1] do
        assert {:error, :conflict} =
                 apply(Tokens, unquote(operation), [
                   c.map.id,
                   caller,
                   String.upcase(token.id),
                   generation
                 ])

        assert Repo.get!(Api.MapIntegrationToken, token.id) == stored
        assert {:ok, %{token: ^token}} = Tokens.get(token_map.id, token_user)
      end
    end
  end

  test "fails closed on partial retrieval without changing a usable digest", %{
    map: map,
    user: user
  } do
    enable(map, user)
    {:ok, %{token: token}} = Tokens.generate(map.id, user)

    Repo.query!("UPDATE map_integration_tokens_v1 SET encrypted_value = $1 WHERE id = $2", [
      "broken-ciphertext",
      Ecto.UUID.dump!(token.id)
    ])

    assert {:ok, principal} = Tokens.authenticate(token.value)
    assert :ok = Tokens.authorize(principal)
    assert Tokens.active_for_maps?([map.id])
    id = token.id

    assert {:error, {:unreadable, %{token: %{id: ^id, generation: 1}}}} =
             Tokens.get(map.id, user)

    assert {:error, {:unreadable, %{token: %{id: ^id, generation: 1}}}} =
             Tokens.generate(map.id, user)

    assert Api.MapIntegrationToken.by_id!(token.id).generation == 1
    assert {:ok, _} = Tokens.authenticate(token.value)
  end

  test "an unreadable credential stays owner-recoverable without self-rotating", %{
    map: map,
    user: user
  } do
    enable(map, user)
    {:ok, %{token: token}} = Tokens.generate(map.id, user)

    Repo.query!("UPDATE map_integration_tokens_v1 SET encrypted_value = $1 WHERE id = $2", [
      "broken-ciphertext",
      Ecto.UUID.dump!(token.id)
    ])

    # The reply exposes metadata for a deliberate rotation, never the secret.
    assert {:error, {:unreadable, details}} = Tokens.get(map.id, user)
    assert details.token == %{id: token.id, generation: token.generation}
    assert details.available and details.enabled
    refute Map.has_key?(details.token, :value)

    # Reads alone must not rotate: only the explicit command does.
    assert Api.MapIntegrationToken.by_id!(token.id).generation == token.generation

    assert {:ok, %{token: replaced}} =
             Tokens.regenerate(map.id, user, details.token.id, details.token.generation)

    assert replaced.generation == token.generation + 1
    assert {:ok, _} = Tokens.authenticate(replaced.value)
    assert {:error, :invalid_token} = Tokens.authenticate(token.value)
  end

  test "global disable is a kill switch not a rotation trigger", %{map: map, user: user} do
    enable(map, user)
    {:ok, %{token: token}} = Tokens.generate(map.id, user)
    Application.put_env(:wanderer_app, :map_integrations_enabled, false)
    assert {:ok, %{available: false, enabled: true, token: nil}} = Tokens.get(map.id, user)
    assert {:error, :disabled} = Tokens.generate(map.id, user)
    refute Tokens.active_for_maps?([map.id])
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)
    assert {:ok, %{token: ^token}} = Tokens.get(map.id, user)
  end

  test "rejects malformed credentials without accepting alternate namespaces", %{
    map: map,
    user: user
  } do
    enable(map, user)
    {:ok, %{token: token}} = Tokens.generate(map.id, user)

    for invalid <- [
          nil,
          "",
          "legacy",
          token.value <> "x",
          String.replace_prefix(token.value, "wmi_v1_", "wmi_v2_")
        ] do
      assert {:error, :invalid_token} = Tokens.authenticate(invalid)
    end

    assert {:error, :forbidden} = Tokens.generate(map.id, %{id: user.id})
  end

  test "concurrent issuance and rotation have one active row and one rotation winner" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      user = insert(:user)
      owner = insert(:character, %{user_id: user.id})
      map = insert(:map, %{owner_id: owner.id})

      try do
        enable(map, user)
        results = parallel(fn -> Tokens.generate(map.id, user) end)
        assert [{:ok, %{token: token}}, {:ok, %{token: same}}] = results
        assert token == same
        results = parallel(fn -> Tokens.regenerate(map.id, user, token.id, 1) end)
        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &(&1 == {:error, :conflict})) == 1
        assert {:error, :invalid_token} = Tokens.authenticate(token.value)
      after
        Fixtures.cleanup([map, owner, user])
      end
    end)
  end

  test "rejects userless credentials even if the map owner is an unlinked character", %{
    map: map,
    user: user
  } do
    enable(map, user)
    {:ok, %{token: token}} = Tokens.generate(map.id, user)
    # An invalidated migration row is allowed to retain no owner.
    Repo.query!(
      "UPDATE map_integration_tokens_v1 SET user_id = NULL, revoked_at = now() WHERE id = $1",
      [Ecto.UUID.dump!(token.id)]
    )

    assert {:error, :invalid_token} = Tokens.authenticate(token.value)

    assert {:error, :invalid_token} =
             Tokens.authorize(%{id: token.id, map_id: map.id, user_id: nil, generation: 1})
  end

  test "active token database constraint rejects missing personal ownership", %{map: map} do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "INSERT INTO map_integration_tokens_v1 (map_id, digest, encrypted_value) VALUES ($1, $2, $3)",
               [Ecto.UUID.dump!(map.id), <<0::256>>, "ciphertext"]
             )
  end

  test "retrieval rejects another credential's valid ciphertext without rotation", %{
    map: map,
    user: user
  } do
    enable(map, user)
    %{user: viewer} = Fixtures.viewer_access(map)
    {:ok, %{token: own}} = Tokens.generate(map.id, user)
    {:ok, %{token: other}} = Tokens.generate(map.id, viewer)
    encrypted = Repo.get!(Api.MapIntegrationToken, other.id).encrypted_value

    Repo.query!("UPDATE map_integration_tokens_v1 SET encrypted_value = $1 WHERE id = $2", [
      encrypted,
      Ecto.UUID.dump!(own.id)
    ])

    assert {:error, {:unreadable, _}} = Tokens.get(map.id, user)
    assert {:error, {:unreadable, _}} = Tokens.generate(map.id, user)
    assert {:ok, _} = Tokens.authenticate(own.value)
    assert Api.MapIntegrationToken.by_id!(own.id).generation == 1
  end

  defp known_token(map, user) do
    # A fixed selector guarantees casing differs; random UUIDs can contain only digits.
    id = "abcdefab-cdef-4abc-8def-abcdefabcdef"
    secret = Base.url_encode64(<<0::256>>, padding: false)
    value = "wmi_v1_#{id}_#{secret}"

    digest =
      :crypto.hash(:sha256, ["wanderer:map-integration-token:v1", <<0>>, id, <<0>>, secret])

    {:ok, encrypted} = WandererApp.Vault.encrypt(value)

    Api.MapIntegrationToken.issue!(%{
      id: id,
      map_id: map.id,
      user_id: user.id,
      digest: digest,
      encrypted_value: encrypted
    })

    {:ok, %{token: token}} = Tokens.get(map.id, user)
    token
  end

  # Both branches contend on the same map row's FOR UPDATE lock, so one task can
  # wait for the other. Task.async_stream's 5s default would exit the caller and
  # kill the test process; 30s with :kill_task turns a lock timeout into a
  # readable failure instead.
  defp parallel(fun) do
    Task.async_stream(1..2, fn _ -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end,
      max_concurrency: 2,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> flunk("parallel task failed: #{inspect(reason)}")
    end)
  end

  defp enable(map, user),
    do: assert({:ok, %{enabled: true}} = Tokens.set_enabled(map.id, user, true))
end
