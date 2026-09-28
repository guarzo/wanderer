defmodule WandererApp.PrejumpPrimes do
  @moduledoc """
  Pre-jump prime handoff (issue #281, ADR 0001 in FlyGD-Wingman).

  A prime is a bounded record captured at Set Root time: the root J-code plus
  finisher tags parsed from a single selected bookmark. It is staged here by
  the Wingman integration, bound to a map, character (EVE character ID) and
  expected source system, and consumed at most once by the movement flow when
  that character's tracked location update creates a new connection.

  Invariants:
  - One active (unconsumed, unexpired) prime per map+character; newest wins.
  - Unconsumed primes expire harmlessly after @ttl.
  - Claims are atomic: a claimed prime can never be claimed again.
  - `e` maps to the 4-hour EOL bucket; omitted flags leave fields at defaults.
  """
  require Ash.Query
  require Logger

  alias WandererApp.Api
  alias WandererApp.MapIntegrationTokens, as: Tokens
  alias WandererApp.Repo

  @ttl_minutes 15
  # Deliberate (Q5): the bookmark `e` tag asserts "end of life"; the map UI
  # accepts the approximation. The issue suggested the 1h bucket; 4h was chosen.
  @eol_time_status 4
  @domain "wanderer:map-integration-token:v1"
  @prime_scope "prejump_prime:write"
  @max_name_bytes 255

  defmodule Revealed do
    @moduledoc false
    @derive {Inspect, except: [:value]}
    defstruct [:id, :generation, :value]
  end

  # ---- Credential ----------------------------------------------------------

  def generate_prime_token(map_id, %Api.User{id: user_id} = user) do
    safely(fn ->
      with {:ok, %{enabled: true}} <- Tokens.set_enabled(map_id, user, true) do
        case own_prime_token(map_id, user_id) do
          {:ok, current} when not is_nil(current) ->
            reveal(current)

          _ ->
            id = Ash.UUID.generate()
            {wire, digest} = credential(id)

            with {:ok, encrypted} <- WandererApp.Vault.encrypt(wire),
                 {:ok, token} <-
                   Api.MapIntegrationToken.issue(%{
                     id: id,
                     map_id: map_id,
                     user_id: user_id,
                     scope: @prime_scope,
                     digest: digest,
                     encrypted_value: encrypted
                   }) do
              reveal(token)
            end
        end
      end
    end)
  end

  def revoke_prime_token(map_id, %Api.User{id: user_id}, id, generation) do
    safely(fn ->
      with {:ok, token} <- current_prime_token(map_id, user_id, id, generation),
           {:ok, _} <- Api.MapIntegrationToken.revoke(token) do
        {:ok, nil}
      end
    end)
  end

  # Digest-only, bounded lookup. Mirrors MapIntegrationTokens.authenticate/1
  # but validates the prime scope instead of the read scope.
  def authenticate(wire) do
    safely(fn ->
      with {:ok, id, secret} <- parse(wire),
           {:ok, %{revoked_at: nil, user_id: user_id, scope: scope} = token}
           when not is_nil(user_id) <-
             Api.MapIntegrationToken
             |> Ash.Query.filter(id == ^id)
             |> Ash.Query.select([
               :id,
               :map_id,
               :user_id,
               :scope,
               :generation,
               :revoked_at,
               :digest
             ])
             |> Ash.read_one(),
           true <-
             byte_size(token.digest) == 32 and
               Plug.Crypto.secure_compare(token.digest, digest(id, secret)) do
        if scope == @prime_scope,
          do:
            {:ok,
             %{
               id: token.id,
               map_id: token.map_id,
               user_id: token.user_id,
               scope: token.scope,
               generation: token.generation
             }},
          else: {:error, :scope_forbidden}
      else
        {:error, :invalid_token} -> {:error, :invalid_token}
        {:error, _} -> {:error, :service_unavailable}
        _ -> {:error, :invalid_token}
      end
    end)
  end

  # Map access for the token owner. Tokens.authorize/1 is scope-agnostic: it
  # verifies the principal's user still has view access to the principal's map
  # and that map integrations are enabled for it.
  def authorize(principal) when is_map(principal) do
    safely(fn ->
      case Tokens.authorize(principal) do
        :ok -> :ok
        {:error, :forbidden} -> {:error, :forbidden}
        {:error, :disabled} -> {:error, :disabled}
        _ -> {:error, :service_unavailable}
      end
    end)
  end

  def authorize(_), do: {:error, :invalid_token}

  # ---- Staging -------------------------------------------------------------

  def stage(map_id, %{map_id: principal_map}, _prime) when map_id != principal_map do
    {:error, :wrong_map}
  end

  def stage(map_id, %{map_id: map_id, user_id: user_id} = principal, prime) do
    safely(fn ->
      with :ok <- validate_prime(prime),
           :ok <- authorize(principal),
           :ok <- policy(map_id) do
        now = DateTime.utc_now()
        expires_at = DateTime.add(now, @ttl_minutes * 60, :second)
        flags = prime.flags || %{}

        row = %{
          map_id: map_id,
          user_id: user_id,
          event_id: prime.event_id,
          eve_character_id: prime.eve_character_id,
          source_solar_system_id: prime.source_solar_system_id,
          system_name: prime.system_name,
          flags_eol: !!flags[:eol],
          flags_half_mass: !!flags[:half_mass],
          flags_critical: !!flags[:critical],
          flags_frigate: !!flags[:frigate],
          consumed_at: nil,
          expires_at: expires_at
        }

        # Idempotency: replaying the same event_id on this map is a no-op
        # success. Otherwise the character's previous active prime is replaced
        # (newest wins) by deleting it before insert; the partial unique index
        # on (map_id, eve_character_id) WHERE consumed_at IS NULL backs this up.
        result =
          Repo.transaction(fn ->
            replayed? =
              Repo.query!(
                "SELECT 1 FROM prejump_primes_v1 WHERE map_id = $1 AND event_id = $2 LIMIT 1",
                [uuid(map_id), uuid(row.event_id)]
              )
              |> Map.get(:num_rows) > 0

            if replayed? do
              :replayed
            else
              Repo.query!(
                "DELETE FROM prejump_primes_v1 WHERE map_id = $1 AND eve_character_id = $2 AND consumed_at IS NULL",
                [uuid(map_id), row.eve_character_id]
              )

              %{num_rows: 1} =
                Repo.query!(
                  """
                  INSERT INTO prejump_primes_v1
                    (map_id, user_id, event_id, eve_character_id, source_solar_system_id,
                     system_name, flags_eol, flags_half_mass, flags_critical, flags_frigate,
                     consumed_at, expires_at, inserted_at, updated_at)
                  VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,NULL,$11, now(), now())
                  """,
                  [
                    uuid(row.map_id),
                    uuid(row.user_id),
                    uuid(row.event_id),
                    row.eve_character_id,
                    row.source_solar_system_id,
                    row.system_name,
                    row.flags_eol,
                    row.flags_half_mass,
                    row.flags_critical,
                    row.flags_frigate,
                    row.expires_at
                  ]
                )

              :staged
            end
          end)

        case result do
          {:ok, :replayed} -> :ok
          {:ok, :staged} -> :ok
          _ -> {:error, :service_unavailable}
        end
      end
    end)
  end

  def stage(_, _, _), do: {:error, :invalid_request}

  def lookup(map_id, eve_character_id) do
    safely(fn ->
      case active_row(map_id, eve_character_id) do
        nil -> {:error, :not_found}
        row -> {:ok, to_prime(row)}
      end
    end)
  end

  # Atomic claim: consume the active, unexpired prime matching map+character
  # and expected source system. Exactly one claimant wins; claimed primes are
  # never returned again (crash-safe: consumed_at set only on success here).
  def claim(map_id, eve_character_id, source_solar_system_id) do
    safely(fn ->
      now = DateTime.utc_now()

      result =
        Repo.query!(
          """
          UPDATE prejump_primes_v1
             SET consumed_at = $1, updated_at = now()
           WHERE id = (
             SELECT id FROM prejump_primes_v1
              WHERE map_id = $2
                AND eve_character_id = $3
                AND source_solar_system_id = $4
                AND consumed_at IS NULL
                AND inserted_at > now() - interval '15 minutes'
              ORDER BY inserted_at DESC
              LIMIT 1
              FOR UPDATE SKIP LOCKED
           )
          RETURNING event_id, system_name,
                    flags_eol, flags_half_mass, flags_critical, flags_frigate
          """,
          [now, uuid(map_id), eve_character_id, source_solar_system_id]
        )

      rows = if is_map(result), do: Map.get(result, :rows), else: []

      case rows do
        [[event_id, name, eol, half, crit, frig]] ->
          {:ok,
           %{
             event_id: Ecto.UUID.load!(event_id),
             system_name: name,
             flags: %{
               eol: eol,
               half_mass: half,
               critical: crit,
               frigate: frig
             },
             eol_time_status: if(eol, do: @eol_time_status, else: nil)
           }}

        _ ->
          {:error, :not_found}
      end
    end)
  end

  defp active_row(map_id, eve_character_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT event_id, system_name, source_solar_system_id,
               flags_eol, flags_half_mass, flags_critical, flags_frigate
          FROM prejump_primes_v1
         WHERE map_id = $1 AND eve_character_id = $2
           AND consumed_at IS NULL AND inserted_at > now() - interval '15 minutes'
         ORDER BY inserted_at DESC
         LIMIT 1
        """,
        [uuid(map_id), eve_character_id]
      )

    case rows do
      [[event_id, name, source, eol, half, crit, frig]] ->
        %{
          event_id: Ecto.UUID.load!(event_id),
          system_name: name,
          source_solar_system_id: source,
          flags_eol: eol,
          flags_half_mass: half,
          flags_critical: crit,
          flags_frigate: frig
        }

      _ ->
        nil
    end
  end

  defp to_prime(row) do
    %{
      event_id: row.event_id,
      system_name: row.system_name,
      source_solar_system_id: row.source_solar_system_id,
      flags: %{
        eol: row.flags_eol,
        half_mass: row.flags_half_mass,
        critical: row.flags_critical,
        frigate: row.flags_frigate
      }
    }
  end

  # ---- Map resolution (same rules as the tracked-locations read path) ------

  def resolve_map(identifier) when is_binary(identifier) and byte_size(identifier) <= 255 do
    require Ash.Query

    alias WandererApp.Api

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

  # ---- Shared policy -------------------------------------------------------

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

  # ---- Finisher-tag parsing ------------------------------------------------

  @doc """
  Parses the finisher-tag vocabulary out of a bookmark name: `e` (EOL),
  `/` (half mass), `c` (critical), `f` (frigate).

  The finisher keybinds append tags as a trailing space-separated token after
  the signature id, so only that final token carries tags — letters elsewhere
  in the name (e.g. "frigate", "halcyon") are never tags. `e` and `f` stack
  (repeat); `/` and `c` are authored mutually exclusively but both parse
  independently if present.
  """
  def parse_flags(name) when is_binary(name) do
    tag_token =
      name
      |> String.trim_trailing()
      |> String.split(" ", trim: true)
      |> List.last("")
      |> String.downcase()

    # The trailing token carries tags only when it is composed entirely of tag
    # characters; otherwise it is the signature id (or other prose) and the
    # bookmark carries no tags.
    tag_token =
      if tag_token != "" and String.match?(tag_token, ~r/^[e\/cf]+$/),
        do: tag_token,
        else: ""

    %{
      eol: String.contains?(tag_token, "e"),
      half_mass: String.contains?(tag_token, "/"),
      critical: String.contains?(tag_token, "c"),
      frigate: String.contains?(tag_token, "f")
    }
  end

  def parse_flags(_), do: %{eol: false, half_mass: false, critical: false, frigate: false}

  # ---- Internals -----------------------------------------------------------

  defp validate_prime(%{event_id: event_id} = prime)
       when is_binary(event_id) and byte_size(event_id) > 0 do
    with {:ok, _} <- Ecto.UUID.cast(event_id),
         :ok <- validate_name(prime[:system_name]),
         :ok <- validate_id(prime[:eve_character_id]),
         :ok <- validate_id(prime[:source_solar_system_id]),
         :ok <- validate_flags(prime[:flags]) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_prime(_), do: {:error, :invalid_request}

  defp validate_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed != "" and byte_size(trimmed) <= @max_name_bytes,
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp validate_name(_), do: {:error, :invalid_request}

  defp validate_id(id) when is_integer(id) and id > 0, do: :ok
  defp validate_id(_), do: {:error, :invalid_request}

  defp validate_flags(nil), do: :ok

  defp validate_flags(flags) when is_map(flags) do
    known = [:eol, :half_mass, :critical, :frigate]

    if flags |> Map.keys() |> Enum.all?(&(&1 in known)),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp validate_flags(_), do: {:error, :invalid_request}

  defp own_prime_token(map_id, user_id) do
    Api.MapIntegrationToken
    |> Ash.Query.filter(
      map_id == ^map_id and user_id == ^user_id and is_nil(revoked_at) and scope == ^@prime_scope
    )
    |> Ash.read_one()
  end

  defp current_prime_token(map_id, user_id, id, generation)
       when is_binary(id) and is_integer(generation) and generation > 0 do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, token} <- own_prime_token(map_id, user_id) do
      case token do
        %{id: ^id, generation: ^generation} -> {:ok, token}
        _ -> {:error, :conflict}
      end
    else
      {:ok, _} -> {:error, :conflict}
      :error -> {:error, :conflict}
      error -> error
    end
  end

  defp current_prime_token(_, _, _, _), do: {:error, :conflict}

  defp reveal(token) do
    with {:ok, value} <- WandererApp.Vault.decrypt(token.encrypted_value),
         {:ok, id, secret} <- parse(value),
         true <- id == token.id and Plug.Crypto.secure_compare(token.digest, digest(id, secret)) do
      {:ok, %{token: %Revealed{id: token.id, generation: token.generation, value: value}}}
    else
      _ ->
        Logger.warning(
          "prime_token_unreadable token_id=#{token.id} generation=#{token.generation}"
        )

        {:error, {:unreadable, %{id: token.id, generation: token.generation}}}
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

  defp uuid(string) when is_binary(string) do
    case Ecto.UUID.dump(string) do
      {:ok, binary} -> binary
      :error -> raise ArgumentError, "invalid uuid: #{inspect(string)}"
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    exception ->
      Logger.error(
        "prime_exception kind=#{inspect(exception.__struct__)} msg=#{Exception.message(exception)}",
        stacktrace: __STACKTRACE__
      )

      {:error, :service_unavailable}
  catch
    :exit, _ ->
      Logger.error("prime_exit")
      {:error, :service_unavailable}
  end
end
