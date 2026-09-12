defmodule WandererApp.MapIntegrationTokens do
  @moduledoc "Personal read-only credentials, bound to a user and map's current access."
  require Ash.Query
  require Logger

  alias WandererApp.Api
  alias WandererApp.Api.MapIntegrationToken
  alias WandererApp.Permissions

  defmodule Revealed do
    @moduledoc false
    @derive {Inspect, except: [:value]}
    defstruct [:id, :generation, :value]
  end

  @scope "tracked_character_locations:read"
  @domain "wanderer:map-integration-token:v1"
  @metadata [:id, :map_id, :user_id, :scope, :generation, :revoked_at]

  def settings(map_id, user) do
    manage(map_id, user, :read, fn map, _ -> {:ok, availability(map)} end)
  end

  def set_enabled(map_id, user, enabled) when is_boolean(enabled) do
    manage(map_id, user, :admin, fn map, _ ->
      with {:ok, updated} <-
             Api.Map.set_location_api_enabled(map, %{location_api_enabled: enabled}) do
        {:ok, availability(updated)}
      end
    end)
  end

  def set_enabled(_, _, _), do: {:error, :invalid_request}

  def get(map_id, user) do
    manage(map_id, user, :read, fn map, user_id ->
      if usable?(map) do
        with {:ok, token} <- own_token(map.id, user_id), do: reveal(map, token)
      else
        reveal(map, nil)
      end
    end)
  end

  def generate(map_id, user) do
    manage(map_id, user, :read, fn map, user_id ->
      with :ok <- enabled(map),
           {:ok, current} <- own_token(map.id, user_id) do
        if current do
          reveal(map, current)
        else
          id = Ash.UUID.generate()
          {wire, digest} = credential(id)

          with {:ok, encrypted} <- WandererApp.Vault.encrypt(wire),
               {:ok, token} <-
                 MapIntegrationToken.issue(%{
                   id: id,
                   map_id: map.id,
                   user_id: user_id,
                   digest: digest,
                   encrypted_value: encrypted
                 }) do
            reveal(map, token)
          end
        end
      end
    end)
  end

  def regenerate(map_id, user, id, generation) do
    manage(map_id, user, :read, fn map, user_id ->
      with :ok <- enabled(map),
           {:ok, token} <- current(map.id, user_id, id, generation) do
        {wire, digest} = credential(id)

        with {:ok, encrypted} <- WandererApp.Vault.encrypt(wire),
             {:ok, replaced} <-
               MapIntegrationToken.replace(token, %{digest: digest, encrypted_value: encrypted}) do
          reveal(map, replaced)
        end
      end
    end)
  end

  def revoke(map_id, user, id, generation) do
    manage(map_id, user, :read, fn map, user_id ->
      with {:ok, token} <- current(map.id, user_id, id, generation),
           {:ok, _} <- MapIntegrationToken.revoke(token) do
        reveal(map, nil)
      end
    end)
  end

  # Digest-only, bounded lookup. Do not move user/map reads or decryption here:
  # the HTTP controller charges authenticated quota before expensive permission work.
  def authenticate(wire) do
    safely(fn ->
      with {:ok, id, secret} <- parse(wire),
           {:ok, %{revoked_at: nil, user_id: user_id} = token} when not is_nil(user_id) <-
             MapIntegrationToken
             |> Ash.Query.filter(id == ^id)
             |> Ash.Query.select(@metadata ++ [:digest])
             |> Ash.read_one(),
           true <-
             byte_size(token.digest) == 32 and
               Plug.Crypto.secure_compare(token.digest, digest(id, secret)) do
        if token.scope == @scope, do: {:ok, metadata(token)}, else: {:error, :scope_forbidden}
      else
        {:error, :invalid_token} -> {:error, :invalid_token}
        {:error, _} -> {:error, :service_unavailable}
        _ -> {:error, :invalid_token}
      end
    end)
  end

  # Permission loss is permanent; availability flags are only kill switches.
  def authorize(%{user_id: user_id} = principal) when is_binary(user_id) do
    safely(fn ->
      case map_access(principal.map_id, user_id) do
        {:ok, map, _permissions} -> enabled(map)
        {:error, :forbidden} -> revoke_denied(principal)
        _ -> {:error, :service_unavailable}
      end
    end)
  end

  def authorize(_), do: {:error, :invalid_token}

  def active_for_maps?([]), do: false

  def active_for_maps?(map_ids) do
    with true <- available?(),
         {:ok, [_]} <-
           MapIntegrationToken
           |> Ash.Query.filter(
             map_id in ^map_ids and is_nil(revoked_at) and not is_nil(user_id) and
               scope == ^@scope and map.location_api_enabled == true and map.deleted == false
           )
           |> Ash.Query.select([:id])
           |> Ash.Query.limit(1)
           |> Ash.read() do
      true
    else
      _ -> false
    end
  end

  def lock_map(map_id) do
    Api.Map |> Ash.Query.filter(id == ^map_id) |> Ash.Query.lock("FOR UPDATE") |> Ash.read_one()
  end

  # Called only from in-transaction resource hooks. Bang reads intentionally
  # abort the permission mutation on data failures rather than revoking blindly.
  def revalidate_map!(map_id) do
    case lock_map(map_id) do
      {:ok, nil} ->
        :ok

      {:ok, map} ->
        tokens =
          MapIntegrationToken
          |> Ash.Query.filter(map_id == ^map_id and is_nil(revoked_at))
          |> Ash.read!()

        map = Ash.load!(map, acls: [:members])

        Enum.each(Enum.group_by(tokens, & &1.user_id), fn {user_id, tokens} ->
          case access(map, user_id) do
            {:ok, _} -> :ok
            {:error, :forbidden} -> Enum.each(tokens, &MapIntegrationToken.revoke!/1)
            {:error, error} -> Ash.DataLayer.rollback(Api.Map, error)
          end
        end)

      {:error, error} ->
        Ash.DataLayer.rollback(Api.Map, error)
    end
  end

  defp manage(map_id, %Api.User{id: user_id}, permission, fun) do
    safely(fn ->
      case Ash.transaction(Api.Map, fn ->
             with {:ok, map} when not is_nil(map) <- lock_map(map_id),
                  {:ok, map} <- Ash.load(map, acls: [:members]) do
               case access(map, user_id) do
                 {:ok, permissions} ->
                   if permission == :read or permissions.admin_map,
                     do: fun.(map, user_id),
                     else: {:error, :forbidden}

                 {:error, :forbidden} ->
                   with {:ok, token} <- own_token(map_id, user_id),
                        :ok <- revoke_if_present(token) do
                     {:error, :forbidden}
                   end

                 error ->
                   error
               end
             else
               {:ok, nil} -> {:error, :forbidden}
               _ -> {:error, :service_unavailable}
             end
           end) do
        {:ok, result} ->
          normalize(result)

        {:error, reason} ->
          # Sanitized classification only: reasons can carry changeset/Vault payloads.
          Logger.error(
            "location_api_token_transaction_failed map_id=#{map_id} kind=#{classify(reason)}"
          )

          {:error, :service_unavailable}
      end
    end)
  end

  defp manage(_, _, _, _), do: {:error, :forbidden}

  defp classify(%{__struct__: module}), do: inspect(module)
  defp classify(reason) when is_atom(reason), do: inspect(reason)
  defp classify(_), do: "unknown"

  defp map_access(map_id, user_id) do
    with {:ok, map} when not is_nil(map) <-
           Api.Map |> Ash.Query.filter(id == ^map_id) |> Ash.read_one(),
         {:ok, map} <- Ash.load(map, acls: [:members]),
         {:ok, permissions} <- access(map, user_id) do
      {:ok, map, permissions}
    else
      {:ok, nil} -> {:error, :forbidden}
      other -> other
    end
  end

  defp access(%{deleted: deleted}, _) when deleted != false, do: {:error, :forbidden}
  defp access(_, nil), do: {:error, :forbidden}

  defp access(map, user_id) do
    with {:ok, characters} <- Api.Character.active_by_user(%{user_id: user_id}) do
      [mask] = Permissions.check_characters_access(characters, map.acls)

      permissions =
        Permissions.get_map_permissions(mask, map.owner_id, Enum.map(characters, & &1.id))

      if permissions.view_system and permissions.view_character,
        do: {:ok, permissions},
        else: {:error, :forbidden}
    end
  end

  defp revoke_denied(principal) do
    case Ash.transaction(Api.Map, fn ->
           with {:ok, _} <- lock_map(principal.map_id),
                {:ok, token} <-
                  current(principal.map_id, principal.user_id, principal.id, principal.generation),
                {:ok, _} <- MapIntegrationToken.revoke(token) do
             {:error, :forbidden}
           else
             {:error, :conflict} -> {:error, :invalid_token}
             _ -> {:error, :service_unavailable}
           end
         end) do
      {:ok, result} -> result
      _ -> {:error, :service_unavailable}
    end
  end

  defp revoke_if_present(nil), do: :ok

  defp revoke_if_present(token) do
    case MapIntegrationToken.revoke(token) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp own_token(map_id, user_id) do
    MapIntegrationToken
    |> Ash.Query.filter(map_id == ^map_id and user_id == ^user_id and is_nil(revoked_at))
    |> Ash.read_one()
  end

  defp current(map_id, user_id, id, generation)
       when is_binary(id) and is_integer(generation) and generation > 0 do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, token} <- own_token(map_id, user_id) do
      case token do
        %{id: ^id, generation: ^generation} -> {:ok, token}
        _ -> {:error, :conflict}
      end
    else
      # A normalized UUID is not an authorized record; Ash also accepts raw IDs for updates.
      {:ok, _} -> {:error, :conflict}
      :error -> {:error, :conflict}
      error -> error
    end
  end

  defp current(_, _, _, _), do: {:error, :conflict}

  defp reveal(map, nil), do: {:ok, Map.put(availability(map), :token, nil)}

  defp reveal(map, token) do
    with {:ok, value} <- WandererApp.Vault.decrypt(token.encrypted_value),
         {:ok, id, secret} <- parse(value),
         true <- id == token.id and Plug.Crypto.secure_compare(token.digest, digest(id, secret)) do
      {:ok,
       Map.put(availability(map), :token, %Revealed{
         id: token.id,
         generation: token.generation,
         value: value
       })}
    else
      _ ->
        # Never rotate here: a Vault/key misconfiguration must not silently
        # invalidate every stored credential. Return the row's non-secret
        # metadata so the owner can deliberately regenerate or revoke instead.
        Logger.warning(
          "location_api_token_unreadable map_id=#{map.id} token_id=#{token.id} generation=#{token.generation}"
        )

        {:error,
         {:unreadable,
          Map.put(availability(map), :token, %{id: token.id, generation: token.generation})}}
    end
  end

  defp availability(map), do: %{available: available?(), enabled: map.location_api_enabled}

  defp available?,
    do: WandererApp.Env.map_integrations_enabled?() and not WandererApp.Env.public_api_disabled?()

  defp usable?(map), do: available?() and map.location_api_enabled
  defp enabled(map), do: if(usable?(map), do: :ok, else: {:error, :disabled})

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
  defp normalize({:ok, _} = result), do: result

  defp normalize({:error, {:unreadable, _details}} = result), do: result

  defp normalize({:error, code})
       when code in [:forbidden, :disabled, :conflict, :service_unavailable],
       do: {:error, code}

  defp normalize(_), do: {:error, :service_unavailable}

  defp safely(fun) do
    fun.()
  rescue
    exception ->
      # Only the exception module: Cloak.MissingCipher carries ciphertext in its struct.
      # The stacktrace is safe and carries no payload, so keep it for correlation.
      Logger.error("location_api_token_exception kind=#{inspect(exception.__struct__)}",
        stacktrace: __STACKTRACE__
      )

      {:error, :service_unavailable}
  catch
    :exit, _ ->
      Logger.error("location_api_token_exit")
      {:error, :service_unavailable}
  end
end
