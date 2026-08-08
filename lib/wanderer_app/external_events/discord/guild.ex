defmodule WandererApp.ExternalEvents.Discord.Guild do
  @moduledoc """
  Reads the roles and members of a Discord guild, so the mention pickers can
  offer names instead of asking an operator to paste snowflakes.

  ## Why per-guild, and why a picker at all

  Discord renders an unknown role or user mention as inert text: no error, no
  warning, just a message that silently pings nobody. Sourcing ids from a
  picker scoped to *this destination's* guild — `MapDiscordWebhook.guild_id`,
  resolved by `ChannelInfo` — makes that failure structurally impossible. The
  installation-wide `DISCORD_GUILD_ID` could not: a map pointed at a different
  guild would offer ids that are inert there.

  ## Why not Nostrum

  Nostrum is a dependency, but its gateway only starts when both a bot token
  and `DISCORD_GUILD_ID` are configured (`Env.discord_voice_mentions_enabled?/0`),
  which would couple a mention picker to voice mentions being set up.
  `HttpClient.get/2` is the seam the rest of the Discord integration already
  goes through and the one the test suite already stubs.

  ## Degrading

  Both reads need a bot token **and** the bot to be in the guild. Neither is
  guaranteed, so `{:error, :no_bot_token}`, `{:error, :unauthorized}` and
  `{:error, :forbidden}` are ordinary outcomes rather than faults — the UI
  swaps the picker for a manual "add by id" input and says why. They are
  returned distinctly because "this instance has no bot" and "your guild has
  not invited ours" are different things for an operator to fix.

  Nothing here logs the bot token, and no failure path inspects a response
  body — the same discipline `ChannelInfo` documents.
  """

  require Logger

  alias WandererApp.ExternalEvents.Discord.HttpClient

  @type entry :: %{id: String.t(), name: String.t()}

  @cache :api_cache

  # A guild's role list changes on the order of weeks, and a stale entry costs
  # nothing worse than a role missing from a picker for a few minutes. Member
  # searches are deliberately **not** cached: the query is part of the key, so
  # the key space is unbounded and every keystroke would leave an entry behind.
  @roles_cache_ttl :timer.minutes(15)
  @roles_cache_namespace "discord_guild_roles"

  # Discord caps `limit` at 1000. This is a typeahead: a list longer than the
  # dropdown can show is worse than no list, because the entry someone is
  # looking for is off the bottom with nothing saying so.
  @default_search_limit 25
  @max_search_limit 100

  # Pinned for the same reason as `ChannelInfo`: the unversioned path follows
  # Discord's current default, which has moved under callers before.
  @bot_api_base "https://discord.com/api/v10"

  @doc """
  Every mentionable role in `guild_id`, in the order Discord returns them,
  cached for #{div(@roles_cache_ttl, 60_000)} minutes. That order is not
  specified — the payload carries a `position` field precisely because the
  array is not sorted — so treat it as arbitrary rather than meaningful.

  `@everyone` is excluded. Discord returns it as a role whose id *is* the guild
  id, and it is the one entry in this list that can wake an entire server up —
  offering it one click away from a kill feed toggle is not a picker, it is a
  trap. An operator who genuinely wants it can still type the id into the
  manual fallback.

  Errors are not cached: a guild that is failing because the bot was just
  invited should start working on the next open of the tab, not fifteen
  minutes later.
  """
  @spec roles(String.t() | nil) :: {:ok, [entry()]} | {:error, term()}
  def roles(guild_id) when is_binary(guild_id) do
    case cached_roles(guild_id) do
      {:ok, roles} ->
        {:ok, roles}

      :miss ->
        with {:ok, decoded} <- get_json("#{@bot_api_base}/guilds/#{guild_id}/roles", guild_id),
             roles when is_list(roles) <- decoded do
          entries =
            roles
            |> Enum.reject(&(&1["id"] == guild_id))
            |> Enum.map(&role_entry/1)
            |> Enum.reject(&is_nil/1)

          put_cached_roles(guild_id, entries)
          {:ok, entries}
        else
          {:error, reason} -> {:error, reason}
          _not_a_list -> {:error, :unexpected_response}
        end
    end
  end

  def roles(_guild_id), do: {:error, :no_guild}

  @doc """
  Members of `guild_id` whose username or nickname starts with `query`.

  Options: `:limit` (default #{@default_search_limit}, capped at
  #{@max_search_limit}).

  A blank query returns `{:ok, []}` without a request — Discord rejects an
  empty `query`, and a typeahead asks on every keystroke including the one that
  empties the box.

  The displayed name prefers the guild nickname, then the account's display
  name, then the username, which is the order Discord's own clients use.
  """
  @spec search_members(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, [entry()]} | {:error, term()}
  def search_members(guild_id, query, opts \\ [])

  def search_members(guild_id, query, opts) when is_binary(guild_id) and is_binary(query) do
    case String.trim(query) do
      "" ->
        {:ok, []}

      trimmed ->
        limit =
          opts
          |> Keyword.get(:limit, @default_search_limit)
          |> clamp(1, @max_search_limit)

        # `URI.encode_query/1` is what makes a query containing a space, an `&`
        # or a `#` a value rather than another parameter.
        params = URI.encode_query(%{"query" => trimmed, "limit" => limit})
        url = "#{@bot_api_base}/guilds/#{guild_id}/members/search?#{params}"

        with {:ok, decoded} <- get_json(url, guild_id),
             members when is_list(members) <- decoded do
          {:ok, members |> Enum.map(&member_entry/1) |> Enum.reject(&is_nil/1)}
        else
          {:error, reason} -> {:error, reason}
          _not_a_list -> {:error, :unexpected_response}
        end
    end
  end

  def search_members(guild_id, _query, _opts) when is_binary(guild_id), do: {:ok, []}
  def search_members(_guild_id, _query, _opts), do: {:error, :no_guild}

  @doc """
  Whether `reason` means "this instance cannot search this guild" rather than
  "this request went wrong". The UI shows its manual-entry fallback for these
  and leaves the picker in place for anything else, which is why the callers
  ask a named predicate instead of matching atoms at three call sites.
  """
  @spec unavailable?(term()) :: boolean()
  def unavailable?(reason), do: reason in [:no_bot_token, :no_guild, :unauthorized, :forbidden]

  ## Entry shaping

  defp role_entry(%{"id" => id, "name" => name}) when is_binary(id) do
    case present(name) do
      nil -> nil
      name -> %{id: id, name: name}
    end
  end

  defp role_entry(_role), do: nil

  defp member_entry(%{"user" => %{"id" => id} = user} = member) when is_binary(id) do
    name =
      present(member["nick"]) || present(user["global_name"]) || present(user["username"])

    case name do
      nil -> nil
      name -> %{id: id, name: name}
    end
  end

  defp member_entry(_member), do: nil

  ## HTTP

  defp get_json(url, subject) do
    with {:ok, token} <- bot_token(),
         {:ok, status, body} <-
           safe_get(url, [{"authorization", "Bot #{token}"}], subject),
         :ok <- check_status(status, subject) do
      decode(body, subject)
    end
  end

  defp bot_token do
    case WandererApp.Env.discord_bot_token() do
      token when is_binary(token) -> {:ok, token}
      _absent -> {:error, :no_bot_token}
    end
  end

  # 401 and 403 are distinct because they point at different fixes: a bad or
  # missing token for the whole instance versus a bot that is simply not in
  # this operator's guild. `channel_info.ex` already documents the second as
  # normal.
  defp check_status(200, _subject), do: :ok
  defp check_status(401, _subject), do: {:error, :unauthorized}
  defp check_status(403, _subject), do: {:error, :forbidden}
  defp check_status(404, _subject), do: {:error, :not_found}
  defp check_status(429, _subject), do: {:error, :rate_limited}

  defp check_status(status, subject) do
    Logger.debug(fn -> "[Discord.Guild] unexpected status #{status} for guild #{subject}" end)
    {:error, {:http_status, status}}
  end

  # Same `rescue` **and** `catch` discipline as `ChannelInfo.safe_get/4`: an
  # unrescued raise on a keystroke path has already killed this settings tab
  # once, and a dead Finch pool exits rather than raising, which `rescue`
  # alone does not cover.
  defp safe_get(url, headers, subject) do
    HttpClient.get(url, headers)
  rescue
    error ->
      Logger.warning(
        "[Discord.Guild] request raised for guild #{subject}: #{Exception.message(error)}"
      )

      {:error, :unavailable}
  catch
    :exit, _reason ->
      Logger.warning("[Discord.Guild] request exited for guild #{subject}")
      {:error, :unavailable}
  end

  defp decode(body, subject) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      _ ->
        # Never `inspect/1` the body: a proxy in front of Discord can echo the
        # request line back, and this request line carries the bot token's
        # `Authorization` header's subject — and in the general case a URL.
        Logger.debug(fn -> "[Discord.Guild] unparseable response for guild #{subject}" end)
        {:error, :unexpected_response}
    end
  end

  ## Cache

  defp cached_roles(guild_id) do
    case Cachex.get(@cache, roles_cache_key(guild_id)) do
      {:ok, roles} when is_list(roles) -> {:ok, roles}
      _ -> :miss
    end
  rescue
    _error -> :miss
  end

  defp put_cached_roles(guild_id, roles) do
    Cachex.put(@cache, roles_cache_key(guild_id), roles, ttl: @roles_cache_ttl)
    roles
  rescue
    _error -> roles
  end

  defp roles_cache_key(guild_id), do: "#{@roles_cache_namespace}:#{guild_id}"

  ## Helpers

  defp clamp(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)
  defp clamp(_value, _min, _max), do: @default_search_limit

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
