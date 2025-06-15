defmodule WandererApp.Api.Preparations.FilterMapsByRoles do
  @moduledoc false

  use Ash.Resource.Preparation
  require Ash.Query

  def prepare(query, _params, %{actor: nil}) do
    query
    |> Ash.Query.filter(expr(deleted == false))
    |> Ash.Query.load([:owner, :acls])
  end

  def prepare(query, _params, %{actor: actor}) do
    result =
      query
      |> Ash.Query.filter(expr(deleted == false))
      |> filter_membership(actor)
      |> Ash.Query.load([:owner, acls: [:members]])

    result
  end

  defp filter_membership(query, actor) do
    characters = actor.characters

    character_ids = characters |> Enum.map(& &1.id)
    character_eve_ids = characters |> Enum.map(& &1.eve_id)

    character_corporation_ids =
      characters |> Enum.map(& &1.corporation_id) |> Enum.map(&to_string/1)

    character_alliance_ids = characters |> Enum.map(& &1.alliance_id) |> Enum.map(&to_string/1)

    # Apply the actual filtering logic - fixed to properly check ACL members
    query
    |> Ash.Query.filter(
      expr(
        # User owns the map
        # Map has ACLs with members that include user's characters, corporations, or alliances
        owner_id in ^character_ids or
          exists(
            acls,
            exists(
              members,
              eve_character_id in ^character_eve_ids or
                eve_corporation_id in ^character_corporation_ids or
                eve_alliance_id in ^character_alliance_ids
            )
          )
      )
    )
  end
end
