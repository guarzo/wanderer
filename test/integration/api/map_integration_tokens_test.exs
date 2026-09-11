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

  test "issues a private digest-only credential and lists metadata without secrets", %{
    map: map,
    user: user
  } do
    assert {:ok, token, wire} = Tokens.create(map.id, user, "Wingman")
    assert wire =~ ~r/^wmi_v1_[0-9a-f-]{36}_[A-Za-z0-9_-]{43}$/
    assert token.name == "Wingman"
    assert token.generation == 1
    assert {:ok, principal} = Tokens.authenticate(wire)
    assert principal.map_id == map.id
    assert principal.scope == "tracked_character_locations:read"
    assert {:ok, [listed]} = Tokens.list(map.id, user)
    refute Map.has_key?(listed, :digest)
    refute inspect(listed) =~ wire
    stored = Repo.get!(Api.MapIntegrationToken, token.id)
    assert byte_size(stored.digest) == 32
    refute inspect(stored) =~ inspect(stored.digest)
    refute :erlang.term_to_binary(stored) =~ wire
    refute AshJsonApi.Resource.Info.type(Api.MapIntegrationToken)
  end

  test "replaces atomically, rejects conflicting generations and never reactivates revocation", %{
    map: map,
    user: user
  } do
    {:ok, token, old} = Tokens.create(map.id, user, "Wingman")
    assert {:ok, replacement, new} = Tokens.replace(map.id, user, token.id, 1)
    assert replacement.generation == 2
    assert {:error, :invalid_token} = Tokens.authenticate(old)
    assert {:ok, _} = Tokens.authenticate(new)
    assert {:error, :conflict} = Tokens.replace(map.id, user, token.id, 1)
    assert {:error, :conflict} = Tokens.revoke(map.id, user, token.id, 1)
    assert {:ok, _} = Tokens.revoke(map.id, user, token.id, 2)
    assert {:error, :invalid_token} = Tokens.authenticate(new)
    assert {:error, :conflict} = Tokens.replace(map.id, user, token.id, 3)
  end

  test "rechecks ordinary permission and binds all management to the selected map", %{
    map: map,
    user: user
  } do
    other_user = insert(:user)
    admin = insert(:character, %{user_id: other_user.id})
    acl = insert(:access_list, %{owner_id: map.owner_id})
    insert(:map_access_list, %{map_id: map.id, access_list_id: acl.id})

    member =
      insert(:access_list_member, %{
        access_list_id: acl.id,
        eve_character_id: admin.eve_id,
        role: :admin
      })

    assert {:ok, token, _} = Tokens.create(map.id, other_user, "ACL admin")
    {:ok, _} = Api.AccessListMember.update_role(member, %{role: :manager})
    assert {:error, :forbidden} = Tokens.list(map.id, other_user)
    assert {:error, :forbidden} = Tokens.replace(map.id, other_user, token.id, 1)
    assert {:error, :forbidden} = Tokens.revoke(map.id, other_user, token.id, 1)
    other_map = insert(:map, %{owner_id: map.owner_id})
    assert {:error, :not_found} = Tokens.replace(other_map.id, user, token.id, 1)
    assert {:error, :forbidden} = Tokens.create(map.id, %{map_id: map.id}, "No user")
    assert {:error, :invalid_name} = Tokens.create(map.id, user, "")
    assert {:error, :invalid_name} = Tokens.create(map.id, user, String.duplicate("a", 65))
  end

  test "ownership updates and soft deletion revoke without revival; hard deletion cascades", %{
    map: map,
    user: user,
    owner: owner
  } do
    {:ok, _, first} = Tokens.create(map.id, user, "First")
    other = insert(:character, %{user_id: user.id})
    {:ok, moved} = Api.Map.assign_owner(map, %{owner_id: other.id})
    assert {:error, :invalid_token} = Tokens.authenticate(first)
    {:ok, _, second} = Tokens.create(map.id, user, "Second")
    {:ok, moved_back} = Api.Map.update(moved, %{owner_id: owner.id})
    assert {:error, :invalid_token} = Tokens.authenticate(second)
    {:ok, token, third} = Tokens.create(map.id, user, "Third")
    {:ok, deleted} = Api.Map.mark_as_deleted(moved_back)
    assert {:error, :invalid_token} = Tokens.authenticate(third)
    assert {:error, :not_found} = Tokens.create(map.id, user, "Deleted")
    {:ok, restored} = Api.Map.restore(deleted)
    assert {:error, :invalid_token} = Tokens.authenticate(third)
    :ok = Ash.destroy(restored)
    assert Repo.get(Api.MapIntegrationToken, token.id) == nil
  end

  test "duplicating an empty map does not copy its integration tokens", %{
    map: map,
    user: user,
    owner: owner
  } do
    {:ok, _, wire} = Tokens.create(map.id, user, "Original")

    {:ok, copy} =
      Api.Map.duplicate(
        %{
          source_map_id: map.id,
          name: "Token-free copy",
          copy_acls: false,
          copy_user_settings: false
        },
        actor: owner
      )

    assert {:ok, []} = Tokens.list(copy.id, user)
    assert {:ok, _} = Tokens.authenticate(wire)
  end

  test "rolls lifecycle revocation back with a failed map transaction", %{map: map, user: user} do
    {:ok, _, wire} = Tokens.create(map.id, user, "Rollback")
    new_owner = insert(:character, %{user_id: user.id})

    assert {:error, :forced} =
             Repo.transaction(fn ->
               Api.Map.assign_owner!(map, %{owner_id: new_owner.id})
               Repo.rollback(:forced)
             end)

    assert {:ok, _} = Tokens.authenticate(wire)
    assert Api.Map.by_id!(map.id).owner_id == map.owner_id
  end

  test "unrelated map updates do not take the integration lifecycle row lock", %{map: map} do
    parent = self()
    id = {__MODULE__, :locks, parent}

    :telemetry.attach(
      id,
      [:wanderer_app, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == parent and String.contains?(metadata.query, "FOR UPDATE"),
          do: send(parent, :map_lock)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    assert {:ok, _} = Api.Map.update(map, %{name: "Unrelated update"})
    refute_receive :map_lock, 0
  end

  test "disabled integrations still revoke on transfer and deletion before re-enable", %{
    map: map,
    user: user
  } do
    {:ok, _, transferred} = Tokens.create(map.id, user, "Transfer")
    other = insert(:character, %{user_id: user.id})
    Application.put_env(:wanderer_app, :map_integrations_enabled, false)
    moved = Api.Map.assign_owner!(map, %{owner_id: other.id})
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)
    assert {:error, :invalid_token} = Tokens.authenticate(transferred)
    {:ok, _, deleted} = Tokens.create(map.id, user, "Delete")
    Application.put_env(:wanderer_app, :map_integrations_enabled, false)
    restored = moved |> Api.Map.mark_as_deleted!() |> Api.Map.restore!()
    assert restored.deleted == false
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)
    assert {:error, :invalid_token} = Tokens.authenticate(deleted)
  end

  test "stale lifecycle writes return an Ash error when the map row is missing", %{map: map} do
    Ash.destroy!(map)
    assert {:error, %Ash.Error.Invalid{}} = Api.Map.mark_as_deleted(map)
  end

  test "invalid lifecycle identity returns an Ash error instead of raising", %{map: map} do
    assert {:error, _} = Api.Map.mark_as_deleted(%{map | id: "invalid-uuid"})
  end

  test "token list data-layer failure returns a service error", %{map: map, user: user} do
    Repo.query!("ALTER TABLE map_integration_tokens_v1 DROP COLUMN name")
    assert {:error, :service_unavailable} = Tokens.list(map.id, user)
  end

  test "replacement data-layer failure returns a service error", %{map: map, user: user} do
    {:ok, token, _} = Tokens.create(map.id, user, "Overflow")

    Repo.query!(
      "UPDATE map_integration_tokens_v1 SET generation = 9223372036854775807 WHERE id = $1",
      [Ecto.UUID.dump!(token.id)]
    )

    assert {:error, :service_unavailable} =
             Tokens.replace(map.id, user, token.id, 9_223_372_036_854_775_807)
  end

  test "map token foreign key has exactly one supporting index" do
    result =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE tablename = 'map_integration_tokens_v1' AND indexdef LIKE '%(map_id)%'"
      )

    assert [[definition]] = result.rows
    assert definition =~ "USING btree (map_id)"
  end

  test "concurrent replacements on independent DB connections have exactly one winner" do
    # Committed fixtures and independent connections exercise actual row locks,
    # not the single shared sandbox connection used by ordinary integration tests.
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      user = insert(:user)
      owner = insert(:character, %{user_id: user.id})
      map = insert(:map, %{owner_id: owner.id})

      try do
        {:ok, token, old} = Tokens.create(map.id, user, "Concurrent")

        results =
          Task.async_stream(
            1..2,
            fn _ ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                Tokens.replace(map.id, user, token.id, 1)
              end)
            end,
            max_concurrency: 2
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
        assert Enum.count(results, &(&1 == {:error, :conflict})) == 1
        assert {:error, :invalid_token} = Tokens.authenticate(old)
        {:ok, _, new} = Enum.find(results, &match?({:ok, _, _}, &1))
        assert {:ok, _} = Tokens.authenticate(new)
      after
        WandererApp.Test.TrackedLocationsFixtures.cleanup([map, owner, user])
      end
    end)
  end

  test "rejects malformed and tampered credentials and disabled issuance", %{map: map, user: user} do
    {:ok, _, wire} = Tokens.create(map.id, user, "Wingman")

    for invalid <- [
          nil,
          "",
          "legacy",
          wire <> "x",
          String.replace_prefix(wire, "wmi_v1_", "wmi_v2_")
        ] do
      assert {:error, :invalid_token} = Tokens.authenticate(invalid)
    end

    Application.put_env(:wanderer_app, :map_integrations_enabled, false)
    assert {:error, :disabled} = Tokens.create(map.id, user, "Disabled")
  end
end
