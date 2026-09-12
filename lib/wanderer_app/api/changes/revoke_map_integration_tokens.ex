defmodule WandererApp.Api.Changes.RevokeMapIntegrationTokens do
  @moduledoc false
  use Ash.Resource.Change

  alias WandererApp.Api
  alias WandererApp.MapIntegrationTokens, as: Tokens

  @character_inputs [:user_id, :deleted, :eve_id, :corporation_id, :alliance_id]
  @member_inputs [
    :access_list_id,
    :role,
    :eve_character_id,
    :eve_corporation_id,
    :eve_alliance_id
  ]

  @impl true
  def change(changeset, _opts, _context) do
    if relevant?(changeset) and not parent_managed_join?(changeset) do
      Ash.Changeset.around_action(changeset, &revalidate/2)
    else
      changeset
    end
  end

  # No atomic implementation: Ash must use ordinary actions, including bulk
  # fallback, so revocation cannot be skipped by a data-layer-only mutation.
  defp revalidate(changeset, callback) do
    old = old_record!(changeset)

    if unchanged_character?(changeset, old) do
      callback.(changeset)
    else
      revalidate_changed(changeset, old, callback)
    end
  end

  defp unchanged_character?(%{resource: Api.Character, action_type: :update} = changeset, old)
       when not is_nil(old) do
    changeset.relationships == %{} and
      not Enum.any?(changeset.atomics, fn {field, _} -> field in @character_inputs end) and
      Map.take(old, @character_inputs) ==
        Map.take(Map.merge(old, changeset.attributes), @character_inputs)
  end

  defp unchanged_character?(_, _), do: false

  defp revalidate_changed(changeset, old, callback) do
    before_maps = affected_maps(changeset.resource, old, prospective(changeset))
    lock_maps!(before_maps)

    case callback.(changeset) do
      {:ok, result, _changeset, _instructions} = success ->
        final = if changeset.action_type == :destroy, do: nil, else: result

        if permission_inputs(changeset.resource, old) !=
             permission_inputs(changeset.resource, final) do
          # Parent map actions have completed managed relationship writes here.
          (before_maps ++ affected_maps(changeset.resource, old, final))
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.each(&Tokens.revalidate_map!/1)
        end

        success

      error ->
        error
    end
  end

  defp old_record!(%{action_type: :create}), do: nil

  defp old_record!(changeset) do
    changeset.resource
    |> Ash.Query.filter(id == ^changeset.data.id)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one!()
  end

  defp prospective(changeset) do
    changeset.attributes
    |> Map.put_new(:id, changeset.data.id)
    |> Map.put_new(:user_id, Ash.Changeset.get_argument(changeset, :user_id))
  end

  defp affected_maps(Api.Map, old, new), do: values(old, new, :id)
  defp affected_maps(Api.MapAccessList, old, new), do: values(old, new, :map_id)
  defp affected_maps(Api.AccessList, old, new), do: maps_for_acls(values(old, new, :id))

  defp affected_maps(Api.AccessListMember, old, new),
    do: maps_for_acls(values(old, new, :access_list_id))

  defp affected_maps(Api.Character, old, new) do
    user_ids = values(old, new, :user_id)

    Api.MapIntegrationToken
    |> Ash.Query.filter(user_id in ^user_ids and is_nil(revoked_at))
    |> Ash.Query.select([:map_id])
    |> Ash.read!()
    |> Enum.map(& &1.map_id)
    |> Enum.uniq()
  end

  defp maps_for_acls([]), do: []

  defp maps_for_acls(ids) do
    Api.MapAccessList
    |> Ash.Query.filter(access_list_id in ^ids)
    |> Ash.Query.select([:map_id])
    |> Ash.read!()
    |> Enum.map(& &1.map_id)
    |> Enum.uniq()
  end

  defp values(old, new, key),
    do:
      [old && Map.get(old, key), new && Map.get(new, key)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

  defp lock_maps!(ids) do
    ids
    |> Enum.sort()
    |> Enum.each(fn id ->
      case Tokens.lock_map(id) do
        {:ok, _} -> :ok
        {:error, error} -> Ash.DataLayer.rollback(Api.Map, error)
      end
    end)
  end

  defp permission_inputs(_, nil), do: nil
  # Every relevant parent map action must recheck its final relationships, which
  # may not appear in the returned record. Other resources compare only inputs.
  defp permission_inputs(Api.Map, record),
    do: {record.owner_id, record.deleted, record.updated_at}

  defp permission_inputs(Api.Character, record), do: Map.take(record, @character_inputs)
  defp permission_inputs(Api.AccessListMember, record), do: Map.take(record, @member_inputs)

  defp permission_inputs(Api.MapAccessList, record),
    do: Map.take(record, [:map_id, :access_list_id])

  defp permission_inputs(Api.AccessList, record), do: record.id

  defp relevant?(%{resource: Api.Map} = changeset) do
    changeset.action.name in [:update_acls, :assign_owner, :mark_as_deleted] or
      (changeset.action.name == :update and
         (Ash.Changeset.changing_attribute?(changeset, :owner_id) or
            not is_nil(Ash.Changeset.get_argument(changeset, :acls))))
  end

  defp relevant?(%{resource: Api.AccessList, action_type: type}), do: type == :destroy

  defp relevant?(%{resource: Api.Character, action: action}) do
    action.name in [
      :create,
      :link,
      :assign,
      :mark_as_deleted,
      :update_corporation,
      :update_alliance,
      :update,
      :destroy
    ]
  end

  defp relevant?(_), do: true

  defp parent_managed_join?(%{
         resource: Api.MapAccessList,
         context: %{accessing_from: %{source: Api.Map, name: name}}
       }) do
    # Framework-owned relationship context, never a submitted bypass flag.
    name == Ash.Resource.Info.relationship(Api.Map, :acls).join_relationship
  end

  defp parent_managed_join?(_), do: false
end
