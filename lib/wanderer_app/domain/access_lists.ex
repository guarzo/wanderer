defmodule WandererApp.Domain.AccessLists do
  @moduledoc """
  Domain logic for Access List operations.

  This module contains business logic that goes beyond basic CRUD operations
  for access lists and their members.
  """

  alias WandererApp.Api
  alias WandererApp.Api.AccessListMember
  import Ash.Query

  @doc """
  Updates the role of an access list member.

  This includes validation of role restrictions based on member type
  (corporations and alliances cannot have admin or manager roles).

  ## Parameters
    - acl_id: The access list ID
    - external_id: The EVE entity ID (character, corporation, or alliance)
    - new_role: The new role to assign

  ## Returns
    - {:ok, updated_member} on success
    - {:error, :not_found} if member not found
    - {:error, :invalid_role} if role is not allowed for entity type
    - {:error, changeset} for validation errors
  """
  def update_member_role(acl_id, external_id, new_role) do
    external_id_str = to_string(external_id)

    membership_query =
      AccessListMember
      |> Ash.Query.new()
      |> filter(access_list_id == ^acl_id)
      |> filter(
        eve_character_id == ^external_id_str or
          eve_corporation_id == ^external_id_str or
          eve_alliance_id == ^external_id_str
      )

    with {:ok, [membership]} <- Api.read(membership_query),
         :ok <- validate_role_for_member_type(membership, new_role) do
      AccessListMember.update_role(membership, %{"role" => new_role})
    else
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Creates a new access list member with proper entity information fetching.

  Fetches entity information from ESI and validates role restrictions.

  ## Parameters
    - acl_id: The access list ID
    - entity_type: "character", "corporation", or "alliance"
    - entity_id: The EVE entity ID
    - role: The role to assign

  ## Returns
    - {:ok, new_member} on success
    - {:error, :invalid_role} if role is not allowed for entity type
    - {:error, :entity_lookup_failed} if ESI lookup fails
    - {:error, changeset} for validation errors
  """
  def create_member(acl_id, entity_type, entity_id, role) do
    with :ok <- validate_role_for_entity_type(entity_type, role),
         {:ok, entity_info} <- fetch_entity_info(entity_type, entity_id) do
      params = build_member_params(acl_id, entity_type, entity_id, entity_info, role)
      AccessListMember.create(params)
    end
  end

  # Private functions

  defp validate_role_for_member_type(membership, new_role) do
    member_type = determine_member_type(membership)
    validate_role_for_entity_type(member_type, new_role)
  end

  defp determine_member_type(membership) do
    cond do
      membership.eve_corporation_id -> "corporation"
      membership.eve_alliance_id -> "alliance"
      membership.eve_character_id -> "character"
      true -> "character"
    end
  end

  defp validate_role_for_entity_type(entity_type, role) do
    if entity_type in ["corporation", "alliance"] and role in ["admin", "manager"] do
      {:error, :invalid_role, "#{String.capitalize(entity_type)} members cannot have #{role} role"}
    else
      :ok
    end
  end

  defp fetch_entity_info(entity_type, entity_id) do
    fetcher = get_info_fetcher(entity_type)

    case fetcher.(to_string(entity_id)) do
      {:ok, info} -> {:ok, info}
      error -> {:error, :entity_lookup_failed, error}
    end
  end

  defp get_info_fetcher("character"), do: &WandererApp.Esi.get_character_info/1
  defp get_info_fetcher("corporation"), do: &WandererApp.Esi.get_corporation_info/1
  defp get_info_fetcher("alliance"), do: &WandererApp.Esi.get_alliance_info/1

  defp build_member_params(acl_id, entity_type, entity_id, entity_info, role) do
    entity_key = "eve_#{entity_type}_id"

    %{
      "access_list_id" => acl_id,
      entity_key => to_string(entity_id),
      "name" => Map.get(entity_info, "name"),
      "role" => role
    }
  end
end
