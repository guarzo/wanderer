defmodule WandererApp.ExternalEvents.Discord.ChannelInfo do
  @moduledoc """
  Resolves a human-readable identity for a Discord webhook destination, so the
  map settings tab can tell one destination from another without rendering a
  credential.

  ## Why

  The settings tab used to render `".../1534657087244603394/40AX••••"`. That is
  two problems in one string. The snowflake is the webhook **id** — half of the
  `{id, token}` pair that authorises posting — rendered in full on a panel that
  gets screenshotted into support threads. And it does not actually identify
  anything: two destinations pointed at the same channel render byte-identical
  hints, which is how a map ends up with its route alerts quietly sharing the
  public kill feed.

  ## Three tiers, degrading

  1. `GET` the webhook URL itself. This needs no credential beyond the URL, and
     returns the webhook's own `name` plus its `channel_id`. Always attempted.
  2. If a bot token is configured (`WandererApp.Env.discord_bot_token/0`),
     `GET /channels/{channel_id}` with `Authorization: Bot …` resolves the real
     `#channel-name`. The bot must share the guild, so **403 here is normal**
     and falls back to tier 1 rather than erroring.
  3. A fully-masked hint derived from a hash of the URL. Unlike the old
     `masked_url/1`, the id is masked too — nothing here is ever recoverable
     into a credential, and two destinations still render differently because
     the hash differs.

  ## What the label claims

  `source` says which tier produced the label, because the UI's wording depends
  on it: `:channel` is a real `#channel-name`, `:webhook_name` is only the
  nickname whoever created the webhook typed, `:masked` is the hash hint, and
  `:unknown` is a label persisted before this field existed. `:unknown` renders
  bare — no "Channel:"/"Webhook:" prefix — because guessing the tier from the
  label's shape is exactly the inference this field exists to stop. It is also
  treated as stale, so a row drains to a real tier on its next render rather
  than needing a backfill that nothing recorded enough to write.

  ## Blocking policy

  `describe/1` **never** blocks and never performs I/O: it answers from cache,
  then from the label persisted on the row, then from the masked hint, and
  schedules a background refresh when the cache is cold. This is deliberate.
  The settings template re-renders on every `live_select` keystroke, and three
  destinations × two HTTP calls on a render path is a settings tab that hangs
  for half a minute the first time it is opened.

  `resolve/1` is the blocking counterpart, for callers that want the answer now
  (and for tests).

  ## What is never logged

  No function here logs, inspects, or caches under the webhook URL. Cache keys
  and log lines carry `fingerprint/1` — a truncated SHA-256 — which identifies
  a destination across lines without carrying any part of the credential.
  """

  require Logger

  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.ExternalEvents.Discord.HttpClient

  @type role :: :system | :character | :route

  @type info :: %{
          label: String.t(),
          channel_id: String.t() | nil,
          guild_id: String.t() | nil,
          source: :channel | :webhook_name | :unknown | :masked
        }

  # Role order, and the order collisions are reported in. Mirrors
  # `MapDiscordWebhook`'s `:role` constraint.
  @roles [:system, :character, :route]

  # `:api_cache` per CLAUDE.md's "Caching Strategy" — the cache for
  # third-party lookups, already at a 1h default TTL. Named explicitly rather
  # than relying on that default so a change to the cache's configuration
  # cannot silently change how long a stale channel name is shown.
  @cache :api_cache
  @cache_ttl :timer.hours(1)

  # A masked result means "Discord did not answer", which is usually transient.
  # Caching it for the full hour would pin every destination on the screen to a
  # placeholder for an hour because of one bad minute; not caching it at all
  # would re-ask on every render while Discord is down. Short is the middle.
  @masked_cache_ttl :timer.minutes(5)

  # Short-lived marker that a background refresh is already in flight, so a
  # template re-rendering on every keystroke schedules one task, not one per
  # keystroke. Comfortably longer than the client's read timeout, so the lock
  # outlives the request it guards.
  @refresh_lock_ttl :timer.seconds(30)

  @cache_namespace "discord_channel_info"
  @refresh_lock_namespace "discord_channel_info_refresh"

  # Hex characters of the URL fingerprint. 8 for cache keys (collision-free
  # enough for a handful of destinations per map) and 4 for the visible hint,
  # which only has to differ between the three destinations on one screen.
  @fingerprint_length 8
  @hint_length 4

  @masked_prefix "••••"

  # Kept at or under `MapDiscordWebhook`'s `:channel_label` constraint. Discord
  # caps names well below this, so truncation only ever fires on a response
  # that is not what it claims to be — and a label that fails the constraint
  # would make `persist/2` retry the same rejected write every refresh.
  @max_label_length 128

  # Pinned API version: an unversioned `/api/channels/...` follows Discord's
  # current default, which has changed under callers before.
  @bot_api_base "https://discord.com/api/v10"

  @doc """
  Non-blocking identity for a destination, suitable for a render path.

  Accepts a `MapDiscordWebhook` record or a raw webhook URL. Answers from
  cache, then the label persisted on the record, then a masked hint —
  scheduling a background refresh whenever the cache is cold, so the next
  render carries the real name.

  Returns `{:error, :no_webhook_url}` when handed nothing usable; callers
  rendering an unconfigured destination should not be asking in the first
  place, and a `{:ok, "••••"}` there would look like a configured one.

  ## `notify:`

  Pass `notify: self()` from a render path to be told when the background
  refresh lands, so the masked hint this call returns is replaced by the real
  name instead of sitting there until something else happens to re-render.
  The message is

      {:discord_channel_info, notification_id, source}

  a **three**-tuple, deliberately. `MapsLive` carries an unguarded
  `handle_info({ref, result}, socket)` catch-all that calls
  `Process.demonitor(ref, [:flush])` (`maps_live.ex:651`), and
  `Process.demonitor/2` raises `ArgumentError` on anything that is not a
  reference — so a two-tuple here would take the whole map LiveView down on the
  first refresh. Ordering our clause above the catch-all would also work and is
  worse: it makes correctness depend on a source-file position that any later
  edit can silently break.

  Nothing is sent for a raw URL (there is no row to name), and a send to a pid
  that has since died is a no-op, so a closed settings tab costs nothing.
  """
  @spec describe(MapDiscordWebhook.t() | String.t() | nil, keyword()) ::
          {:ok, info()} | {:error, term()}
  def describe(webhook_or_url, opts \\ []) do
    with {:ok, url} <- webhook_url(webhook_or_url) do
      case cached(url) do
        {:ok, %{source: :masked} = info} ->
          # A masked cache entry means the last resolution could not reach
          # Discord or could not name the channel. It must not displace a real
          # label already on the row — `persist/2` refuses to write one over the
          # other for exactly this reason, and letting it win here would undo
          # that on screen: a destination showing "#kills" would drop back to a
          # hash hint the moment Discord had one bad minute.
          {:ok, persisted(webhook_or_url) || info}

        {:ok, info} ->
          {:ok, info}

        :miss ->
          refresh_async(webhook_or_url, opts)
          {:ok, persisted(webhook_or_url) || masked(url)}
      end
    end
  end

  @doc """
  Blocking identity for a destination: performs the tiered resolution above,
  caching the result.

  Never raises and never returns a tier-3 `{:error, _}` for a reachable-but-
  unidentifiable webhook — a destination that cannot be named still gets its
  masked hint, because "we could not reach Discord" and "this destination does
  not exist" must not render the same way as each other, and neither should
  take down the settings tab.
  """
  @spec resolve(MapDiscordWebhook.t() | String.t() | nil) :: {:ok, info()} | {:error, term()}
  def resolve(webhook_or_url) do
    with {:ok, url} <- webhook_url(webhook_or_url) do
      case cached(url) do
        {:ok, info} -> {:ok, info}
        :miss -> {:ok, put_cached(url, resolve_uncached(url))}
      end
    end
  end

  @doc """
  Resolves in the background and persists the result onto the webhook row, so
  the next open of the settings tab renders instantly from the row instead of
  waiting on Discord.

  Deduplicated through a short-lived cache lock and always `:ok` — a refresh
  that cannot be scheduled is not an error, it is one more render showing the
  masked hint.

  Accepts the same `notify:` option as `describe/2`. Note that the lock is what
  makes the notification worth having and also its one sharp edge: a caller
  whose refresh is deduped against one already in flight is not notified,
  because the in-flight task was scheduled by whoever won the lock. That is the
  right trade for a settings tab, where losing the race means someone else's
  refresh is about to write the row anyway.
  """
  @spec refresh_async(MapDiscordWebhook.t() | String.t() | nil, keyword()) :: :ok
  def refresh_async(webhook_or_url, opts \\ []) do
    with {:ok, url} <- webhook_url(webhook_or_url),
         :ok <- acquire_refresh_lock(url) do
      Task.Supervisor.start_child(WandererApp.TaskSupervisor, fn ->
        info = put_cached(url, resolve_uncached(url))
        persist(webhook_or_url, info)
        notify(webhook_or_url, info, opts)
      end)
    end

    :ok
  end

  @doc """
  Given the settings tab's `%{system: _, character: _, route: _}` map, returns
  the groups of roles that deliver into the same Discord channel.

  Each group is a list of two or more roles in `#{inspect(@roles)}` order;
  `[]` means no collision. A `:route` group matters most: the route alert help
  text tells operators the channel names every system in the chain in order and
  must be trusted, and sharing it with the public kill feed is a real leak that
  nothing else on the screen would reveal.

  Non-blocking, like `describe/1`. Two **different** webhook URLs into one
  channel are only detectable once their `channel_id` has resolved and been
  persisted; before that they are treated as distinct. The same URL reused
  twice is caught immediately, without any resolution at all.
  """
  @spec colliding_roles(%{optional(role()) => MapDiscordWebhook.t() | nil}) :: [[role()]]
  def colliding_roles(webhooks) when is_map(webhooks) do
    @roles
    |> Enum.map(&{&1, identity(Map.get(webhooks, &1))})
    |> Enum.reject(fn {_role, identity} -> is_nil(identity) end)
    |> Enum.group_by(fn {_role, identity} -> identity end, fn {role, _identity} -> role end)
    |> Enum.map(fn {_identity, roles} -> Enum.sort_by(roles, &role_index/1) end)
    |> Enum.filter(&(length(&1) > 1))
    |> Enum.sort_by(fn [first | _rest] -> role_index(first) end)
  rescue
    error ->
      # A collision warning that fails to compute must not take the settings
      # tab with it; "no collision reported" is the same state the tab was in
      # before this module existed.
      Logger.warning("[ChannelInfo] collision check failed: #{Exception.message(error)}")
      []
  end

  def colliding_roles(_webhooks), do: []

  @doc """
  Stable, non-reversible short identifier for a destination.

  Public because it is what log lines and support conversations should use to
  refer to a specific destination. Never derived from the token: four
  characters of a credential are still four characters of a credential.
  """
  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(url) when is_binary(url) do
    :sha256
    |> :crypto.hash(url)
    |> Base.encode16(case: :upper)
    |> binary_part(0, @fingerprint_length)
  end

  ## Resolution tiers

  defp resolve_uncached(url) do
    case fetch_webhook(url) do
      {:ok, %{"channel_id" => channel_id} = webhook} when is_binary(channel_id) ->
        # The webhook payload carries a `guild_id` of its own. It is the weaker
        # of the two — tier 2 answers for the channel that is actually being
        # posted into — so it is only the fallback.
        webhook_guild_id = present(webhook["guild_id"])

        # Reachable and it named a channel, but a name is a separate question:
        # the bot may not share the guild and the webhook itself may be
        # unnamed. Falling back to the masked hint here must NOT count as
        # resolved, or the hint would be cached for the full hour and written
        # over whatever real label the row already holds.
        case bot_channel(channel_id) do
          %{label: label, guild_id: guild_id} ->
            %{
              label: label,
              channel_id: channel_id,
              guild_id: guild_id || webhook_guild_id,
              source: :channel
            }

          nil ->
            case webhook_label(webhook) do
              nil ->
                %{
                  label: masked_label(url),
                  channel_id: channel_id,
                  guild_id: webhook_guild_id,
                  source: :masked
                }

              label ->
                %{
                  label: label,
                  channel_id: channel_id,
                  guild_id: webhook_guild_id,
                  source: :webhook_name
                }
            end
        end

      {:ok, webhook} ->
        # Reachable, but Discord did not hand back a channel — nothing to ask
        # the bot about, and nothing to collide on.
        case webhook_label(webhook) do
          nil ->
            masked(url)

          label ->
            %{
              label: label,
              channel_id: nil,
              guild_id: present(webhook["guild_id"]),
              source: :webhook_name
            }
        end

      :error ->
        masked(url)
    end
  end

  # Tier 1. Authorised by the URL itself; deliberately sends no bot token.
  defp fetch_webhook(url) do
    case safe_get(url, [], "webhook identity", url) do
      {:ok, 200, body} -> decode(body, url)
      _other -> :error
    end
  end

  # Tier 2. A 401/403 here is the ordinary case for an instance whose bot is
  # not in the operator's guild, so it is not logged as a failure.
  #
  # Returns the guild alongside the name: this is the only response that ties a
  # destination to a specific guild authoritatively, and the mention pickers
  # need it to know which guild's roles and members to offer.
  defp bot_channel(channel_id) do
    with token when is_binary(token) <- WandererApp.Env.discord_bot_token(),
         {:ok, 200, body} <-
           safe_get(
             "#{@bot_api_base}/channels/#{channel_id}",
             [{"authorization", "Bot #{token}"}],
             "channel lookup",
             channel_id
           ),
         {:ok, %{"name" => name} = channel} <- decode(body, channel_id),
         name when is_binary(name) <- present(name) do
      %{label: truncate("##{name}"), guild_id: present(channel["guild_id"])}
    else
      _ -> nil
    end
  end

  defp webhook_label(%{"name" => name}), do: name |> present() |> truncate()
  defp webhook_label(_webhook), do: nil

  defp truncate(nil), do: nil
  defp truncate(label), do: String.slice(label, 0, @max_label_length)

  ## Masking

  defp masked(url),
    do: %{label: masked_label(url), channel_id: nil, guild_id: nil, source: :masked}

  defp masked_label(url) do
    "#{@masked_prefix} #{url |> fingerprint() |> binary_part(0, @hint_length)}"
  end

  ## Cache

  defp cached(url) do
    case Cachex.get(@cache, cache_key(url)) do
      {:ok, %{label: _label} = info} -> {:ok, info}
      _ -> :miss
    end
  rescue
    _error -> :miss
  end

  defp put_cached(url, info) do
    Cachex.put(@cache, cache_key(url), info, ttl: ttl_for(info))
    info
  rescue
    _error -> info
  end

  defp ttl_for(%{source: :masked}), do: @masked_cache_ttl
  # A guard, not the draining mechanism. `put_cached/2` is only ever handed
  # `resolve_uncached/1`'s output, which never carries `:unknown` — a legacy row
  # reaches the UI through `persisted/1` on a cache miss, and that same miss is
  # what schedules the refresh that records the tier. This clause exists so that
  # if an `:unknown` ever does get cached, it gets the short TTL rather than
  # falling through to the hour-long one below.
  defp ttl_for(%{source: :unknown}), do: @masked_cache_ttl
  defp ttl_for(_info), do: @cache_ttl

  # `:ok` only for the caller that won the lock. `get_and_update/3` is the
  # atomic half: two concurrent renders cannot both commit.
  #
  # The expiry is carried in the *value*, not in a Cachex TTL, because setting a
  # TTL is a second call — and a task that dies in the window between claiming
  # the lock and expiring it would leave a lock with no expiry at all, i.e. a
  # destination stuck on its masked hint until the node restarts.
  defp acquire_refresh_lock(url) do
    now = System.monotonic_time(:millisecond)

    Cachex.get_and_update(@cache, refresh_lock_key(url), fn
      held_until when is_integer(held_until) and held_until > now -> {:ignore, held_until}
      _expired_or_absent -> {:commit, now + @refresh_lock_ttl}
    end)
    |> case do
      {:commit, _held_until} -> :ok
      _ -> :locked
    end
  rescue
    # No cache means no dedupe, and refreshing anyway is better than a tab
    # permanently stuck on masked hints.
    _error -> :ok
  end

  defp cache_key(url), do: "#{@cache_namespace}:#{fingerprint(url)}"
  defp refresh_lock_key(url), do: "#{@refresh_lock_namespace}:#{fingerprint(url)}"

  ## Persistence

  # Only a saved row has somewhere to persist to; a raw URL string (a paste
  # not yet submitted) resolves into the cache and stops there.
  defp persist(%MapDiscordWebhook{id: id} = webhook, %{source: source} = info)
       when is_binary(id) and source in [:channel, :webhook_name] do
    if stale?(webhook, info) do
      case MapDiscordWebhook.cache_channel_info(webhook, %{
             channel_id: info.channel_id,
             channel_label: info.label,
             channel_label_source: source,
             guild_id: info.guild_id
           }) do
        {:ok, _record} ->
          :ok

        {:error, error} ->
          # A rejected write is silent otherwise: the row keeps its stale label
          # and every refresh retries the same rejected change forever.
          Logger.warning(
            "[ChannelInfo] could not persist identity for webhook #{id}: #{error_summary(error)}"
          )
      end
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "[ChannelInfo] could not persist identity for webhook #{id}: #{Exception.message(error)}"
      )

      :ok
  end

  # A masked result is never persisted: it carries no information the row does
  # not already imply, and writing it would overwrite a good label that a
  # single unreachable moment produced no better answer than.
  defp persist(_webhook_or_url, _info), do: :ok

  # All four fields are compared, so a row that already has the right label but
  # a null `channel_label_source` — every row written before that column
  # existed — still counts as stale and gets its tier recorded on the first
  # refresh that reaches it.
  defp stale?(%MapDiscordWebhook{} = webhook, info) do
    webhook.channel_id != info.channel_id or webhook.channel_label != info.label or
      webhook.channel_label_source != info.source or webhook.guild_id != info.guild_id
  end

  ## Notification

  # Sent whatever the outcome, including `:masked`. A refresh that could do no
  # better than the hint is still news to a tab that has been showing the hint
  # with no way to know whether it is still waiting.
  #
  # Three-tuple: see `describe/2`. Two-tuple crashes `MapsLive`.
  defp notify(%MapDiscordWebhook{notification_id: notification_id}, info, opts)
       when is_binary(notification_id) do
    case Keyword.get(opts, :notify) do
      pid when is_pid(pid) -> send(pid, {:discord_channel_info, notification_id, info.source})
      _no_listener -> :ok
    end

    :ok
  end

  defp notify(_webhook_or_url, _info, _opts), do: :ok

  # Never `inspect/1` an Ash error: `InvalidAttribute` carries the submitted
  # value, and `sensitive? true` does not redact it. Only this action's four
  # fields could appear here and none is a credential, but the rule is worth
  # keeping mechanical rather than reasoning about it at each call site — so
  # this reports field names and messages and never a value.
  defp error_summary(%{errors: errors}) when is_list(errors) and errors != [] do
    Enum.map_join(errors, "; ", fn
      %{field: field, message: message} when not is_nil(field) -> "#{field}: #{message}"
      %{message: message} -> to_string(message)
      other -> error_summary(other)
    end)
  end

  defp error_summary(%struct_name{}), do: inspect(struct_name)
  defp error_summary(error) when is_atom(error), do: to_string(error)
  defp error_summary(_error), do: "unknown error"

  defp persisted(%MapDiscordWebhook{channel_label: label} = webhook) do
    case present(label) do
      nil ->
        nil

      label ->
        %{
          label: label,
          channel_id: present(webhook.channel_id),
          guild_id: present(webhook.guild_id),
          # Null means the row predates the column. The label is still worth
          # showing — it is what the operator sees today — but nothing recorded
          # which tier produced it, so the UI must not claim one.
          source: webhook.channel_label_source || :unknown
        }
    end
  end

  defp persisted(_webhook_or_url), do: nil

  ## Collision identity

  # Prefers the resolved channel — that is what "same destination" actually
  # means — and falls back to the URL fingerprint so an identical URL pasted
  # into two roles is caught before anything resolves.
  defp identity(%MapDiscordWebhook{} = webhook) do
    case present(webhook.channel_id) do
      nil ->
        case webhook_url(webhook) do
          {:ok, url} -> resolved_channel_id(url) || {:url, fingerprint(url)}
          _ -> nil
        end

      channel_id ->
        channel_id
    end
  end

  defp identity(_webhook), do: nil

  defp resolved_channel_id(url) do
    case cached(url) do
      {:ok, %{channel_id: channel_id}} -> present(channel_id)
      :miss -> nil
    end
  end

  defp role_index(role), do: Enum.find_index(@roles, &(&1 == role)) || length(@roles)

  ## Input normalization

  defp webhook_url(%MapDiscordWebhook{webhook_url: url}) when is_binary(url) do
    case present(url) do
      nil -> {:error, :no_webhook_url}
      url -> {:ok, url}
    end
  end

  defp webhook_url(url) when is_binary(url) do
    case present(url) do
      nil -> {:error, :no_webhook_url}
      url -> {:ok, url}
    end
  end

  defp webhook_url(_webhook_or_url), do: {:error, :no_webhook_url}

  ## HTTP

  # `search_corporations/2` in the settings component carries a `rescue` for
  # exactly this reason: an unrescued raise in a token-refresh path killed the
  # whole settings tab on a single keystroke. Every HTTP call here is on a
  # render or background path and gets the same treatment, plus `catch` for the
  # `:exit` a dead Finch pool produces, which `rescue` alone does not cover.
  #
  # `context` and `subject` are for the log line only. `subject` is never the
  # URL for a webhook read — it is passed through `fingerprint/1` — so no log
  # line here can carry a credential.
  defp safe_get(url, headers, context, subject) do
    HttpClient.get(url, headers)
  rescue
    error ->
      Logger.warning(
        "[ChannelInfo] #{context} raised for #{ref(subject)}: #{Exception.message(error)}"
      )

      :error
  catch
    :exit, _reason ->
      Logger.warning("[ChannelInfo] #{context} exited for #{ref(subject)}")
      :error
  end

  # A webhook URL is fingerprinted; a channel id is already public and is
  # exactly what makes a log line useful.
  defp ref(subject) do
    if String.starts_with?(subject, "http"), do: fingerprint(subject), else: subject
  end

  defp decode(body, subject) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} ->
        {:ok, decoded}

      _ ->
        # Never `inspect/1` the body: an error response from a proxy sitting in
        # front of Discord can echo the request line, and the request line is
        # the webhook URL.
        Logger.debug(fn -> "[ChannelInfo] unparseable response for #{ref(subject)}" end)
        :error
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
