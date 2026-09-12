defmodule WandererApp.PersonalTokenRevocationTest do
  use WandererAppWeb.ApiCase, async: false
  alias WandererApp.Api
  alias WandererApp.MapIntegrationTokens, as: Tokens
  alias WandererApp.Repo

  setup do
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)
    on_exit(fn -> Application.delete_env(:wanderer_app, :map_integrations_enabled) end)
    user = insert(:user)
    owner = insert(:character, %{user_id: user.id})
    map = insert(:map, %{owner_id: owner.id})
    {:ok, _} = Tokens.set_enabled(map.id, user, true)
    acl = insert(:access_list, %{owner_id: owner.id})
    join = insert(:map_access_list, %{map_id: map.id, access_list_id: acl.id})
    reader = insert(:user)
    char = insert(:character, %{user_id: reader.id})
    member = grant(acl, char)
    {:ok, %{token: token}} = Tokens.generate(map.id, reader)
    {:ok, %{token: owner_token}} = Tokens.generate(map.id, user)

    %{
      map: map,
      user: user,
      owner: owner,
      acl: acl,
      join: join,
      reader: reader,
      char: char,
      member: member,
      token: token,
      owner_token: owner_token
    }
  end

  test "offline grant removal permanently revokes only the departed user's credential", c do
    Ash.destroy!(c.member)
    revoked(c.token)
    grant(c.acl, c.char)
    revoked(c.token)
    active(c.owner_token)
    {:ok, %{token: replacement}} = Tokens.generate(c.map.id, c.reader)
    refute replacement.id == c.token.id
  end

  test "blocked creation revokes combined users while direct grants override corporation blocks",
       c do
    alt = insert(:character, %{user_id: c.reader.id})
    Api.Character.update_corporation!(alt, %{corporation_id: 999})

    insert(:access_list_member, %{
      access_list_id: c.acl.id,
      eve_corporation_id: "999",
      role: :blocked
    })

    active(c.token)

    block =
      insert(:access_list_member, %{
        access_list_id: c.acl.id,
        eve_character_id: alt.eve_id,
        role: :blocked
      })

    revoked(c.token)
    Ash.destroy!(block)
    revoked(c.token)
    active(c.owner_token)
  end

  test "remaining alt grant preserves access on unlink; losing the last alt revokes", c do
    alt = insert(:character, %{user_id: c.reader.id})
    grant(c.acl, alt)
    Api.Character.mark_as_deleted!(c.char)
    active(c.token)
    Api.Character.mark_as_deleted!(alt)
    revoked(c.token)
    active(c.owner_token)
  end

  test "reassignment revalidates old and new users; generic update can restore a blocked alt",
       c do
    blocked = insert(:character, %{user_id: c.reader.id})
    blocked = Api.Character.mark_as_deleted!(blocked)

    insert(:access_list_member, %{
      access_list_id: c.acl.id,
      eve_character_id: blocked.eve_id,
      role: :blocked
    })

    active(c.token)
    assigned = Api.Character.assign_user!(blocked, %{user_id: c.reader.id})
    active(c.token)
    Api.Character.update!(assigned, %{})
    revoked(c.token)
    {:ok, %{token: renewed}} = Tokens.generate(c.map.id, c.user)
    assert renewed.id == c.owner_token.id
    stranger = insert(:user)
    Api.Character.assign_user!(c.owner, %{user_id: stranger.id})
    revoked(c.owner_token)
  end

  for {action, field, eve_field} <- [
        {:update_corporation, :corporation_id, :eve_corporation_id},
        {:update_alliance, :alliance_id, :eve_alliance_id}
      ] do
    test "#{action} revokes after the last affiliation grant disappears", c do
      Ash.destroy!(c.member)
      assert {:ok, _} = apply(Api.Character, unquote(action), [c.char, %{unquote(field) => 9001}])

      insert(:access_list_member, %{
        unquote(eve_field) => "9001",
        access_list_id: c.acl.id,
        role: :viewer
      })

      {:ok, %{token: token}} = Tokens.generate(c.map.id, c.reader)
      assert {:ok, _} = apply(Api.Character, unquote(action), [c.char, %{unquote(field) => 9002}])
      revoked(token)
      active(c.owner_token)
    end
  end

  test "standalone join deletion and ACL cascading deletion revoke offline holders", c do
    Ash.destroy!(c.join)
    revoked(c.token)
    insert(:map_access_list, %{map_id: c.map.id, access_list_id: c.acl.id})
    {:ok, %{token: next}} = Tokens.generate(c.map.id, c.reader)
    Ash.destroy!(c.acl)
    revoked(next)
    active(c.owner_token)
  end

  test "membership and standalone join moves cover both old and new maps", c do
    second_acl = insert(:access_list, %{owner_id: c.owner.id})
    Ash.update!(c.member, %{access_list_id: second_acl.id}, action: :update)
    revoked(c.token)
    other_map = insert(:map, %{owner_id: c.owner.id})
    {:ok, _} = Tokens.set_enabled(other_map.id, c.user, true)
    Api.Map.update_acls!(c.map, %{acls: [second_acl.id]})
    {:ok, %{token: token}} = Tokens.generate(c.map.id, c.reader)
    [join] = Api.MapAccessList.read_by_map!(%{map_id: c.map.id})
    Ash.update!(join, %{map_id: other_map.id}, action: :update)
    revoked(token)
    assert {:ok, %{token: _}} = Tokens.generate(other_map.id, c.reader)
  end

  test "parent ACL replacement evaluates final state, not intermediate detachment", c do
    replacement = insert(:access_list, %{owner_id: c.owner.id})
    grant(replacement, c.char)
    Api.Map.update_acls!(c.map, %{acls: [replacement.id]})
    active(c.token)
    Api.Map.update!(c.map, %{acls: [c.acl.id]})
    active(c.token)
    Api.Map.update_acls!(c.map, %{acls: []})
    revoked(c.token)
    active(c.owner_token)
  end

  for acls <- [nil, []], disabled <- [false, true] do
    test "explicit ACL removal #{inspect(acls)} revokes offline holders (disabled=#{disabled})",
         c do
      {:ok, _} = Tokens.set_enabled(c.map.id, c.user, not unquote(disabled))
      updated = Api.Map.update!(c.map, %{acls: unquote(acls)})

      assert Ash.load!(updated, :acls).acls == []
      assert Repo.get!(Api.MapIntegrationToken, c.token.id).revoked_at != nil
      revoked(c.token)
      active(c.owner_token)

      Api.Map.update_acls!(updated, %{acls: [c.acl.id]})
      revoked(c.token)
      {:ok, _} = Tokens.set_enabled(c.map.id, c.user, true)
      assert {:ok, %{token: owner_token}} = Tokens.get(c.map.id, c.user)
      assert owner_token == c.owner_token
      assert {:ok, %{token: replacement}} = Tokens.generate(c.map.id, c.reader)
      refute replacement.id == c.token.id
    end
  end

  test "omitting the ACL argument preserves membership and existing credentials", c do
    updated = Api.Map.update!(c.map, %{description: "Description only"})
    assert Enum.map(Ash.load!(updated, :acls).acls, & &1.id) == [c.acl.id]
    active(c.token)
    active(c.owner_token)
  end

  test "owner transfer preserves eligible viewers and owners with remaining grants", c do
    grant(c.acl, c.owner)
    new_owner = insert(:character)
    Api.Map.assign_owner!(c.map, %{owner_id: new_owner.id})
    active(c.token)
    active(c.owner_token)

    owner_grant =
      Api.AccessListMember.read_by_access_list!(%{access_list_id: c.acl.id})
      |> Enum.find(&(&1.eve_character_id == c.owner.eve_id))

    Ash.destroy!(owner_grant)
    revoked(c.owner_token)
    active(c.token)
  end

  test "temporary map disable preserves credentials but real access loss while off revokes", c do
    {:ok, _} = Tokens.set_enabled(c.map.id, c.user, false)
    active(c.token)
    refute Tokens.active_for_maps?([c.map.id])
    {:ok, principal} = Tokens.authenticate(c.token.value)
    assert {:error, :disabled} = Tokens.authorize(principal)
    assert {:ok, %{enabled: false, token: nil}} = Tokens.get(c.map.id, c.reader)
    Api.AccessListMember.update_role!(c.member, %{role: :blocked})
    revoked(c.token)
    active(c.owner_token)
    {:ok, _} = Tokens.set_enabled(c.map.id, c.user, true)
    assert {:ok, %{token: token}} = Tokens.get(c.map.id, c.user)
    assert token.id == c.owner_token.id
    revoked(c.token)
  end

  test "soft deletion permanently revokes, restore never resurrects and hard deletion cascades",
       c do
    deleted = Api.Map.mark_as_deleted!(c.map)
    revoked(c.token)
    revoked(c.owner_token)
    restored = Api.Map.restore!(deleted)
    revoked(c.token)
    assert {:ok, %{token: nil}} = Tokens.get(restored.id, c.user)
    Ash.destroy!(restored)
    assert Repo.get(Api.MapIntegrationToken, c.token.id) == nil
  end

  test "rollback of a permission mutation also rolls back revocation", c do
    assert {:error, :forced} =
             Repo.transaction(fn ->
               Api.AccessListMember.update_role!(c.member, %{role: :blocked},
                 return_notifications?: true
               )

               revoked(c.token)
               Repo.rollback(:forced)
             end)

    active(c.token)
    assert Api.AccessListMember.by_id!(c.member.id).role == :viewer
  end

  test "failed revocation aborts the permission mutation instead of committing access loss", c do
    Repo.query!(
      "UPDATE map_integration_tokens_v1 SET generation = 9223372036854775807 WHERE id = $1",
      [Ecto.UUID.dump!(c.token.id)]
    )

    assert {:error, _} = Api.AccessListMember.update_role(c.member, %{role: :blocked})
    assert Api.AccessListMember.by_id!(c.member.id).role == :viewer
    active(c.token)
  end

  test "fresh old character row detects stale restoration and character deletion", c do
    stranger = insert(:user)
    Api.Character.assign_user!(c.char, %{user_id: stranger.id})
    revoked(c.token)
    # Stale data still claims the reader; hook must use the actual current row.
    grant(c.acl, c.owner)
    {:ok, %{token: token}} = Tokens.generate(c.map.id, stranger)
    Ash.destroy!(c.char)
    revoked(token)
  end

  test "linking a blocked character revokes the otherwise eligible combined user", c do
    eve_id = "93000001"

    insert(:access_list_member, %{
      access_list_id: c.acl.id,
      eve_character_id: eve_id,
      role: :blocked
    })

    active(c.token)

    Ash.create!(
      Api.Character,
      %{eve_id: eve_id, name: "Blocked linked alt", user_id: c.reader.id},
      action: :link
    )

    revoked(c.token)
    active(c.owner_token)
  end

  test "unrelated character updates do not query tokens, maps or ACL permissions", c do
    parent = self()
    handler = {__MODULE__, :unrelated, parent}

    :telemetry.attach(
      handler,
      [:wanderer_app, :repo, :query],
      fn _, _, meta, _ ->
        if self() == parent and
             Regex.match?(
               ~r/FROM "(maps_v1|map_integration_tokens_v1|access_list_members_v1)"/,
               meta.query
             ),
           do: send(parent, :permission_work)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    Api.Character.update!(c.char, %{expires_at: 2_000_000_000})
    Api.Character.update_location!(c.char, %{solar_system_id: 30_000_142})
    refute_receive :permission_work, 0
  end

  test "atomic bulk permission changes fail safely and streaming fallback revokes", c do
    result =
      Ash.bulk_update([c.member], :update_role, %{role: :blocked},
        strategy: [:atomic],
        return_errors?: true
      )

    assert result.status == :error
    active(c.token)

    result =
      Ash.bulk_update([c.member], :update_role, %{role: :blocked},
        strategy: [:stream],
        return_errors?: true
      )

    assert result.status == :success
    revoked(c.token)
  end

  defp grant(acl, char),
    do:
      insert(:access_list_member, %{
        access_list_id: acl.id,
        eve_character_id: char.eve_id,
        role: :viewer
      })

  defp active(token), do: assert({:ok, _} = Tokens.authenticate(token.value))
  defp revoked(token), do: assert({:error, :invalid_token} = Tokens.authenticate(token.value))
end
