defmodule WandererApp.MapIntegrationTokensTest do
  use WandererAppWeb.ApiCase, async: false

  alias WandererApp.Api
  alias WandererApp.MapIntegrationTokens, as: Tokens
  alias WandererApp.Repo

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
    {viewer, _, _} = viewer(map)
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
    {viewer, _, _} = viewer(map)
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
    assert {:error, :service_unavailable} = Tokens.get(map.id, user)
    assert {:error, :service_unavailable} = Tokens.generate(map.id, user)
    assert Api.MapIntegrationToken.by_id!(token.id).generation == 1
    assert {:ok, _} = Tokens.authenticate(token.value)
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
        WandererApp.Test.TrackedLocationsFixtures.cleanup([map, owner, user])
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
    {viewer, _, _} = viewer(map)
    {:ok, %{token: own}} = Tokens.generate(map.id, user)
    {:ok, %{token: other}} = Tokens.generate(map.id, viewer)
    encrypted = Repo.get!(Api.MapIntegrationToken, other.id).encrypted_value

    Repo.query!("UPDATE map_integration_tokens_v1 SET encrypted_value = $1 WHERE id = $2", [
      encrypted,
      Ecto.UUID.dump!(own.id)
    ])

    assert {:error, :service_unavailable} = Tokens.get(map.id, user)
    assert {:error, :service_unavailable} = Tokens.generate(map.id, user)
    assert {:ok, _} = Tokens.authenticate(own.value)
    assert Api.MapIntegrationToken.by_id!(own.id).generation == 1
  end

  defp parallel(fun) do
    Task.async_stream(1..2, fn _ -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end,
      max_concurrency: 2
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp enable(map, user),
    do: assert({:ok, %{enabled: true}} = Tokens.set_enabled(map.id, user, true))

  defp viewer(map) do
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

    {user, char, member}
  end
end
