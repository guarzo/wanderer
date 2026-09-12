defmodule WandererApp.TrackedCharacterLocations do
  @moduledoc "Read-only snapshot of permitted tracking consent and this process's fresh confirmations."
  require Ash.Query

  alias WandererApp.Api
  alias WandererApp.Character.LocationConfirmations, as: Store
  alias WandererApp.MapIntegrationTokens, as: Tokens
  alias WandererApp.Permissions
  alias WandererAppWeb.Helpers.APIUtils

  def resolve_map(identifier) when is_binary(identifier) and byte_size(identifier) <= 255 do
    query =
      case Ecto.UUID.cast(identifier) do
        {:ok, id} -> Ash.Query.filter(Api.Map, id == ^id or slug == ^identifier)
        :error -> Ash.Query.filter(Api.Map, slug == ^identifier)
      end

    case Ash.read(query) do
      {:ok, []} ->
        {:error, :map_not_found}

      {:ok, maps} ->
        map = Enum.find(maps, &(String.downcase(identifier) == &1.id)) || hd(maps)
        if map.deleted, do: {:error, :map_not_found}, else: {:ok, map}

      _ ->
        {:error, :service_unavailable}
    end
  end

  def resolve_map(_), do: {:error, :invalid_request}

  def policy(map_id) do
    if not WandererApp.Env.map_integrations_enabled?() or WandererApp.Env.public_api_disabled?() do
      {:error, :disabled}
    else
      case WandererApp.Map.is_subscription_active?(map_id) do
        {:ok, true} -> :ok
        {:ok, false} -> {:error, :subscription_required}
        _ -> {:error, :service_unavailable}
      end
    end
  end

  def snapshot(map_id, principal, wire), do: assemble(map_id, principal, wire, 1)

  defp assemble(map_id, principal, wire, retries) do
    with :ok <- Tokens.authorize(principal),
         :ok <- policy(map_id),
         {:ok, capture} <- authorization_capture(map_id),
         {:ok, observations} <- Store.snapshot(),
         {:ok, local} <- tracker_capture(capture.characters),
         {:ok, systems} <- Api.MapSystem.read_all_by_map(%{map_id: map_id}),
         {:ok, names} <- raw_names(observations.entries, capture.characters),
         {:ok, rechecked} <- authorization_capture(map_id),
         {:ok, current_local} <- tracker_capture(rechecked.characters),
         {:ok, current_token} <- Tokens.authenticate(wire),
         :ok <- Tokens.authorize(current_token),
         :ok <- policy(map_id) do
      cond do
        current_token != principal ->
          {:error, :invalid_token}

        capture != rechecked or local != current_local ->
          retry(map_id, principal, wire, retries)

        observations.lifetime != Process.whereis(Store) ->
          {:error, :service_unavailable}

        true ->
          # Age is evaluated after the final authorization read, including for
          # conditional requests. Envelope time is not location evidence.
          now = DateTime.utc_now()
          records(capture, local, observations.entries, systems, names, now)
      end
    end
  end

  defp retry(map_id, principal, wire, retries) when retries > 0,
    do: assemble(map_id, principal, wire, retries - 1)

  defp retry(_, _, _, _), do: {:error, :service_unavailable}

  defp authorization_capture(map_id) do
    with {:ok, map} <- Api.Map |> Ash.Query.filter(id == ^map_id) |> Ash.read_one(),
         true <- map != nil and map.deleted == false,
         {:ok, map} <- Ash.load(map, [:owner, acls: [:members]]),
         {:ok, roster} <-
           Api.MapCharacterSettings.tracked_by_map_all(%{map_id: map_id},
             query: [limit: 2001],
             load: [:character]
           ) do
      if length(roster) > 2000 do
        {:error, :invalid_snapshot}
      else
        # Keep only the authorization/identity/grant inputs. Ordinary tracker DB
        # movement updates must not spuriously invalidate a capture.
        characters =
          roster
          |> Enum.map(fn settings ->
            char = settings.character

            char
            |> Map.take([
              :id,
              :eve_id,
              :name,
              :user_id,
              :corporation_id,
              :alliance_id,
              :deleted,
              :expires_at
            ])
            |> Map.put(:fingerprint, Store.fingerprint(char.access_token))
          end)
          |> Enum.sort_by(& &1.id)

        acls =
          map.acls
          |> Enum.map(fn acl ->
            %{
              id: acl.id,
              owner_id: acl.owner_id,
              members:
                acl.members
                |> Enum.map(
                  &Map.take(&1, [
                    :id,
                    :role,
                    :eve_character_id,
                    :eve_corporation_id,
                    :eve_alliance_id
                  ])
                )
                |> Enum.sort_by(& &1.id)
            }
          end)
          |> Enum.sort_by(& &1.id)

        {:ok,
         %{
           map_id: map_id,
           owner_id: map.owner_id,
           owner_user_id: map.owner && map.owner.user_id,
           acls: acls,
           characters: characters
         }}
      end
    else
      false -> {:error, :map_not_found}
      _ -> {:error, :service_unavailable}
    end
  end

  defp tracker_capture(characters) do
    case Cachex.export(:character_state_cache) do
      {:ok, states} ->
        ids = MapSet.new(characters, & &1.id)

        states =
          for {:entry, id, _, _, state} <- states,
              MapSet.member?(ids, id),
              into: %{},
              do: {id, Map.take(state, [:is_online, :track_location, :active_maps])}

        pools =
          if Process.whereis(:unique_tracker_pool_registry) do
            Registry.select(:unique_tracker_pool_registry, [
              {{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
            ])
          else
            []
          end

        live_ids =
          pools
          |> Enum.filter(fn {pid, _} -> Process.alive?(pid) end)
          |> Enum.flat_map(&elem(&1, 1))
          |> MapSet.new()
          |> MapSet.intersection(ids)

        {:ok, %{states: states, live_ids: live_ids}}

      _ ->
        {:error, :service_unavailable}
    end
  end

  defp raw_names(entries, characters) do
    ids =
      entries
      |> Map.take(Enum.map(characters, & &1.id))
      |> Map.values()
      |> Enum.map(& &1.solar_system_id)
      |> Enum.uniq()

    case Api.MapSolarSystem
         |> Ash.Query.filter(solar_system_id in ^ids)
         |> Ash.Query.select([:solar_system_id, :solar_system_name])
         |> Ash.read() do
      {:ok, systems} -> {:ok, Map.new(systems, &{&1.solar_system_id, &1.solar_system_name})}
      _ -> {:error, :service_unavailable}
    end
  end

  defp records(capture, local, entries, systems, names, now) do
    systems = Map.new(systems, &{&1.solar_system_id, &1})

    result =
      capture.characters
      |> Enum.filter(&permitted?(&1, capture))
      |> Enum.reduce_while([], fn char, acc ->
        with {:ok, eve_id} <- identity(char.eve_id),
             true <- valid_name?(char.name) do
          base = %{
            character_id: eve_id,
            character_name: char.name,
            tracked: true,
            online:
              if(get_in(local.states, [char.id, :is_online]) == false, do: false, else: nil),
            solar_system_id: nil,
            solar_system_name: nil,
            display_name: nil,
            map_system_visible: false,
            location_observed_at: nil,
            map_system_updated_at: nil
          }

          record =
            locate(base, char, capture.map_id, local, entries[char.id], systems, names, now)

          if valid_name?(record.solar_system_name) and valid_name?(record.display_name),
            do: {:cont, [record | acc]},
            else: {:halt, :invalid}
        else
          _ -> {:halt, :invalid}
        end
      end)

    if is_list(result) and length(Enum.uniq_by(result, & &1.character_id)) == length(result) do
      {:ok, Enum.sort_by(result, & &1.character_id), now}
    else
      {:error, :invalid_snapshot}
    end
  end

  defp permitted?(%{deleted: true}, _), do: false
  defp permitted?(%{user_id: nil}, _), do: false

  defp permitted?(char, capture) do
    if char.id == capture.owner_id or
         (char.user_id != nil and char.user_id == capture.owner_user_id) do
      true
    else
      [mask] = Permissions.check_characters_access([char], capture.acls)
      permissions = Permissions.get_permissions(mask)
      permissions.track_character and permissions.view_system
    end
  end

  defp locate(base, char, map_id, local, entry, systems, names, now) do
    state = local.states[char.id] || %{}

    eligible =
      entry != nil and entry.fingerprint == char.fingerprint and char.fingerprint != nil and
        is_integer(char.expires_at) and char.expires_at > DateTime.to_unix(now) and
        state[:is_online] == true and state[:track_location] == true and
        map_id in (state[:active_maps] || []) and
        MapSet.member?(local.live_ids, char.id) and Store.fresh?(entry.observed_at, now)

    if eligible do
      system = systems[entry.solar_system_id]
      visible = system != nil and system.visible == true
      raw = names[entry.solar_system_id]

      %{
        base
        | online: true,
          solar_system_id: entry.solar_system_id,
          solar_system_name: raw,
          display_name: if(visible, do: APIUtils.display_name(system, raw), else: nil),
          map_system_visible: visible,
          location_observed_at: DateTime.to_iso8601(entry.observed_at),
          map_system_updated_at:
            if(visible, do: DateTime.to_iso8601(system.updated_at), else: nil)
      }
    else
      base
    end
  end

  defp identity(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_007_199_254_740_991 ->
        if Integer.to_string(id) == value, do: {:ok, id}, else: {:error, :invalid_identity}

      _ ->
        {:error, :invalid_identity}
    end
  end

  defp identity(_), do: {:error, :invalid_identity}
  defp valid_name?(nil), do: true

  defp valid_name?(name) when is_binary(name) and byte_size(name) <= 1024,
    do: String.valid?(name) and length(String.codepoints(name)) <= 255

  defp valid_name?(_), do: false
end
