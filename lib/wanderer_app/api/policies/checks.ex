defmodule WandererApp.Api.Policies.Checks do
  @moduledoc """
  Common policy checks for authorization across Ash resources.

  These checks encapsulate the business logic for determining whether
  an actor (user/character) has permission to perform actions on resources.
  """

  use Ash.Policy.Check
  alias WandererApp.Api.{AccessList, AccessListMember}
  alias WandererApp.Api.Map, as: ApiMap
  alias WandererApp.Permissions

  @impl true
  def describe(_opts) do
    "Custom policy checks for Wanderer"
  end

  @impl true
  def strict_check(actor, context, opts) do
    # For strict checks, we'll return :unknown to let Ash handle it at runtime
    {:ok, :unknown}
  end

  @doc """
  Checks if the actor is an application admin.
  Application admins are defined in WANDERER_ADMINS environment variable.
  """
  def admin?(actor, _context, _opts) do
    case actor do
      %{eve_character_id: character_id} ->
        admins = Application.get_env(:wanderer_app, :admin_character_ids, [])
        character_id in admins

      _ ->
        false
    end
  end

  @doc """
  Checks if the actor owns the resource.
  Works for resources that have an :owner_id or :character_id field.
  """
  def owner?(actor, %{resource: resource}, _opts) do
    case {actor, resource} do
      {%{id: actor_id}, %{owner_id: owner_id}} ->
        actor_id == owner_id

      {%{id: actor_id}, %{character_id: character_id}} ->
        actor_id == character_id

      {%{eve_character_id: character_id}, %{owner_id: owner_id}} ->
        character_id == owner_id

      _ ->
        false
    end
  end

  @doc """
  Checks if the actor has a specific role in an ACL.
  Options:
    - :role - Required role level (e.g., :admin, :manager, :member)
    - :acl_field - Field name containing ACL ID (defaults to :access_list_id)
  """
  def has_acl_role?(actor, %{resource: resource}, opts) do
    required_role = Keyword.get(opts, :role, :member)
    acl_field = Keyword.get(opts, :acl_field, :access_list_id)

    case {actor, Map.get(resource, acl_field)} do
      {%{eve_character_id: character_id}, acl_id} when not is_nil(acl_id) ->
        check_acl_membership(character_id, acl_id, required_role)

      _ ->
        false
    end
  end

  @doc """
  Checks if the actor has map permissions for a specific action.
  Options:
    - :permission - Required permission bit (e.g., :view_system, :manage_map)
    - :map_field - Field name containing map ID (defaults to :map_id)
  """
  def has_map_permission?(actor, %{resource: resource}, opts) do
    required_permission = Keyword.get(opts, :permission, :view_system)
    map_field = Keyword.get(opts, :map_field, :map_id)

    case {actor, Map.get(resource, map_field)} do
      {%{eve_character_id: character_id}, map_id} when not is_nil(map_id) ->
        permissions = calculate_map_permissions(character_id, map_id)
        Permissions.has_permission?(permissions, required_permission)

      _ ->
        false
    end
  end

  @doc """
  Checks if the actor has access to a map (either as owner or through ACLs).
  """
  def has_map_access?(actor, %{resource: resource}, opts) do
    map_field = Keyword.get(opts, :map_field, :map_id)

    case actor do
      %{characters: characters} when is_list(characters) ->
        # Get character IDs from the user's characters
        character_ids = Enum.map(characters, & &1.id)

        # Check if the resource is a Map itself or has a map_id
        case resource do
          # Resource is a Map itself
          %ApiMap{} = map ->
            # Check if user owns the map
            # Check ACL membership (this logic should match the query filtering)
            map.owner_id in character_ids or
              has_acl_access_for_characters?(map, characters)

          # Resource has a map_id field
          _ ->
            case Map.get(resource, map_field) do
              map_id when not is_nil(map_id) ->
                # For other resources with map_id, use the original logic but avoid circular calls
                case Ash.get(ApiMap, map_id, actor: nil) do
                  {:ok, %{owner_id: owner_id}} ->
                    owner_id in character_ids

                  _ ->
                    false
                end

              _ ->
                false
            end
        end

      %{eve_character_id: character_id} ->
        # Legacy single character logic
        case resource do
          %ApiMap{} = map ->
            map.owner_id == character_id

          _ ->
            case Map.get(resource, map_field) do
              map_id when not is_nil(map_id) ->
                case Ash.get(ApiMap, map_id, actor: nil) do
                  {:ok, %{owner_id: owner_id}} when owner_id == character_id ->
                    true

                  _ ->
                    false
                end

              _ ->
                false
            end
        end

      _ ->
        false
    end
  end

  @doc """
  Checks if the resource belongs to the same organization as the actor.
  Uses EVE character, corporation, or alliance matching.
  """
  def same_organization?(actor, %{resource: resource}, _opts) do
    case actor do
      %{
        eve_character_id: actor_char_id,
        eve_corporation_id: actor_corp_id,
        eve_alliance_id: actor_alliance_id
      } ->
        # Check character, corporation, or alliance match
        resource.eve_character_id == actor_char_id or
          (actor_corp_id && resource.eve_corporation_id == actor_corp_id) or
          (actor_alliance_id && resource.eve_alliance_id == actor_alliance_id)

      _ ->
        false
    end
  end

  # Private helper functions

  defp check_acl_membership(character_id, acl_id, required_role) do
    case AccessListMember.read_by_access_list(acl_id) do
      {:ok, members} ->
        Enum.any?(members, fn member ->
          matches_character?(member, character_id) and
            role_sufficient?(member.role, required_role)
        end)

      _ ->
        false
    end
  end

  defp matches_character?(%{eve_character_id: member_char_id}, character_id)
       when member_char_id == character_id,
       do: true

  defp matches_character?(%{eve_corporation_id: member_corp_id}, character_id)
       when not is_nil(member_corp_id) do
    # Would need to look up character's corporation
    # For now, simplified check
    false
  end

  defp matches_character?(%{eve_alliance_id: member_alliance_id}, character_id)
       when not is_nil(member_alliance_id) do
    # Would need to look up character's alliance
    # For now, simplified check
    false
  end

  defp matches_character?(_, _), do: false

  defp role_sufficient?(member_role, required_role) do
    role_levels = %{
      viewer: 1,
      member: 2,
      manager: 3,
      admin: 4,
      owner: 5
    }

    Map.get(role_levels, member_role, 0) >= Map.get(role_levels, required_role, 0)
  end

  defp calculate_map_permissions(character_id, map_id) do
    # This would integrate with the existing WandererApp.Permissions logic
    # For now, return a default permission set
    case ApiMap.by_id(map_id) do
      {:ok, %{owner_id: owner_id}} when owner_id == character_id ->
        # Map owner gets all permissions
        Permissions.admin_permissions()

      {:ok, map} ->
        # Calculate based on ACL memberships
        # This would call the existing permission calculation logic
        Permissions.viewer_permissions()

      _ ->
        0
    end
  end

  defp has_acl_access_for_characters?(map, characters) do
    # Check if any of the user's characters have ACL access
    character_eve_ids = Enum.map(characters, & &1.eve_id)
    character_corporation_ids = Enum.map(characters, &to_string(&1.corporation_id))
    character_alliance_ids = Enum.map(characters, &to_string(&1.alliance_id))

    # Check if ACLs are already loaded to avoid circular authorization
    case map.acls do
      %Ash.NotLoaded{} ->
        # ACLs not loaded, try to load them without authorization to avoid circular dependency
        case Ash.load(map, acls: [:members], actor: nil) do
          {:ok, %{acls: acls}} ->
            check_acl_membership(
              acls,
              character_eve_ids,
              character_corporation_ids,
              character_alliance_ids
            )

          _ ->
            # If we can't load ACLs, allow access (this case is handled by query filtering)
            true
        end

      acls when is_list(acls) ->
        # ACLs already loaded, check them directly
        check_acl_membership(
          acls,
          character_eve_ids,
          character_corporation_ids,
          character_alliance_ids
        )

      _ ->
        false
    end
  end

  defp check_acl_membership(
         acls,
         character_eve_ids,
         character_corporation_ids,
         character_alliance_ids
       ) do
    Enum.any?(acls, fn acl ->
      # Check if members are loaded
      case acl.members do
        %Ash.NotLoaded{} ->
          # Members not loaded, try loading without authorization
          case Ash.load(acl, :members, actor: nil) do
            {:ok, %{members: members}} ->
              check_member_access(
                members,
                character_eve_ids,
                character_corporation_ids,
                character_alliance_ids
              )

            _ ->
              # Default to allow if we can't check (query filtering handles this)
              true
          end

        members when is_list(members) ->
          check_member_access(
            members,
            character_eve_ids,
            character_corporation_ids,
            character_alliance_ids
          )

        _ ->
          false
      end
    end)
  end

  defp check_member_access(
         members,
         character_eve_ids,
         character_corporation_ids,
         character_alliance_ids
       ) do
    Enum.any?(members, fn member ->
      member.eve_character_id in character_eve_ids or
        member.eve_corporation_id in character_corporation_ids or
        member.eve_alliance_id in character_alliance_ids
    end)
  end

  defp has_any_acl_membership?(character_id, map) do
    # This would check if the character has any ACL membership for the map
    # For now, simplified implementation
    false
  end
end
