defmodule WandererApp.MapIntegrationTokens do
  @moduledoc "Map-scoped read-only credentials. Plaintext exists only in issue/replace results."
  require Ash.Query

  alias WandererApp.Api
  alias WandererApp.Api.MapIntegrationToken
  alias WandererApp.Permissions

  defmodule Revealed do
    @moduledoc false
    # Keep the one-time LiveView reveal out of ordinary socket/crash inspection.
    @derive {Inspect, except: [:value]}
    defstruct [:value]
  end

  @scope "tracked_character_locations:read"
  @domain "wanderer:map-integration-token:v1"
  @metadata [:id, :map_id, :name, :scope, :generation, :revoked_at, :inserted_at, :updated_at]

  def create(map_id, user, name) do
    with :ok <- enabled(), :ok <- valid_name(name) do
      manage(map_id, user, fn map ->
        id = Ash.UUID.generate()
        {wire, digest} = credential(id)

        case MapIntegrationToken.issue(%{id: id, map_id: map.id, name: name, digest: digest}) do
          {:ok, token} -> {:ok, metadata(token), wire}
          {:error, _} -> {:error, :service_unavailable}
        end
      end)
    end
  end

  def list(map_id, user) do
    manage(map_id, user, fn map ->
      case MapIntegrationToken.by_map(map.id) do
        {:ok, tokens} ->
          {:ok, Enum.map(Enum.sort_by(tokens, &{&1.inserted_at, &1.id}), &metadata/1)}

        {:error, _} ->
          {:error, :service_unavailable}
      end
    end)
  end

  def replace(map_id, user, id, generation) do
    with :ok <- enabled() do
      manage(map_id, user, fn map ->
        with {:ok, token} <- current(map.id, id, generation) do
          {wire, digest} = credential(id)

          case MapIntegrationToken.replace(token, %{digest: digest}) do
            {:ok, replaced} -> {:ok, metadata(replaced), wire}
            {:error, _} -> {:error, :service_unavailable}
          end
        end
      end)
    end
  end

  def revoke(map_id, user, id, generation) do
    manage(map_id, user, fn map ->
      with {:ok, token} <- current(map.id, id, generation),
           {:ok, revoked} <- MapIntegrationToken.revoke(token) do
        {:ok, metadata(revoked)}
      end
    end)
  end

  def authenticate(wire) do
    with {:ok, id, secret} <- parse(wire),
         {:ok, %{revoked_at: nil} = token} <-
           MapIntegrationToken |> Ash.Query.filter(id == ^id) |> Ash.read_one(),
         true <-
           byte_size(token.digest) == 32 and
             Plug.Crypto.secure_compare(token.digest, digest(id, secret)) do
      if token.scope == @scope, do: {:ok, metadata(token)}, else: {:error, :scope_forbidden}
    else
      {:error, :invalid_token} -> {:error, :invalid_token}
      {:error, _} -> {:error, :service_unavailable}
      _ -> {:error, :invalid_token}
    end
  end

  def active_for_maps?([]), do: false

  def active_for_maps?(map_ids) do
    with :ok <- enabled(),
         {:ok, [_]} <-
           MapIntegrationToken
           |> Ash.Query.filter(map_id in ^map_ids and is_nil(revoked_at) and scope == ^@scope)
           |> Ash.Query.select([:id])
           |> Ash.Query.limit(1)
           |> Ash.read() do
      true
    else
      _ -> false
    end
  end

  # All issuance and lifecycle writes lock this same row, for the duration of
  # their ordinary DB transaction. This is not a long-lived ownership lock.
  def lock_map(map_id) do
    Api.Map |> Ash.Query.filter(id == ^map_id) |> Ash.Query.lock("FOR UPDATE") |> Ash.read_one()
  end

  def revoke_for_map!(map_id) do
    MapIntegrationToken.by_map!(map_id)
    |> Enum.filter(&is_nil(&1.revoked_at))
    |> Enum.each(&MapIntegrationToken.revoke!/1)
  end

  defp manage(map_id, %Api.User{id: user_id}, fun) do
    case Ash.transaction(Api.Map, fn ->
           with {:ok, %{deleted: false} = map} <- lock_map(map_id),
                {:ok, characters} <- Api.Character.active_by_user(%{user_id: user_id}),
                {:ok, map} <- Ash.load(map, acls: [:members]),
                [mask] <- Permissions.check_characters_access(characters, map.acls),
                %{admin_map: true} <-
                  Permissions.get_map_permissions(
                    mask,
                    map.owner_id,
                    Enum.map(characters, & &1.id)
                  ) do
             fun.(map)
           else
             {:ok, _} -> {:error, :not_found}
             %{admin_map: false} -> {:error, :forbidden}
             _ -> {:error, :service_unavailable}
           end
         end) do
      {:ok, result} -> result
      {:error, _} -> {:error, :service_unavailable}
    end
  end

  defp manage(_, _, _), do: {:error, :forbidden}

  defp current(map_id, id, generation) do
    case MapIntegrationToken.by_id(id) do
      {:ok, %{map_id: ^map_id, generation: ^generation, revoked_at: nil} = token} -> {:ok, token}
      {:ok, %{map_id: ^map_id}} -> {:error, :conflict}
      _ -> {:error, :not_found}
    end
  end

  defp credential(id) do
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {"wmi_v1_#{id}_#{secret}", digest(id, secret)}
  end

  defp digest(id, secret), do: :crypto.hash(:sha256, [@domain, <<0>>, id, <<0>>, secret])

  defp parse("wmi_v1_" <> <<id::binary-size(36), "_", secret::binary-size(43)>>) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, bytes} <- Base.url_decode64(secret, padding: false),
         true <- byte_size(bytes) == 32 and Base.url_encode64(bytes, padding: false) == secret do
      {:ok, id, secret}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp parse(_), do: {:error, :invalid_token}
  defp metadata(token), do: Map.take(token, @metadata)

  defp enabled do
    if WandererApp.Env.map_integrations_enabled?() and not WandererApp.Env.public_api_disabled?(),
      do: :ok,
      else: {:error, :disabled}
  end

  defp valid_name(name) when is_binary(name) do
    if String.valid?(name) and String.length(name) in 1..64 and String.trim(name) != "",
      do: :ok,
      else: {:error, :invalid_name}
  end

  defp valid_name(_), do: {:error, :invalid_name}
end
