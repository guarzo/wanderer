defmodule WandererApp.Env do
  @moduledoc false
  use Nebulex.Caching

  require Logger

  @app :wanderer_app

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "vsn_version"
            )
  def vsn(), do: Application.spec(@app)[:vsn]

  def git_sha(), do: get_key(:git_sha, "<GIT_SHA>")
  def base_url(), do: get_key(:web_app_url, "<BASE_URL>")
  def base_metrics_only(), do: get_key(:base_metrics_only, false)
  def custom_route_base_url(), do: get_key(:custom_route_base_url, "<CUSTOM_ROUTE_BASE_URL>")
  def invites(), do: get_key(:invites, false)

  def map_subscriptions_enabled?(), do: get_key(:map_subscriptions_enabled, false)
  def intel_sharing_enabled?(), do: get_key(:intel_sharing_enabled, false)
  def public_api_disabled?(), do: get_key(:public_api_disabled, false)

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "active_tracking_pool"
            )
  def active_tracking_pool(), do: get_key(:active_tracking_pool, "default")

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "tracking_pool_max_size"
            )
  def tracking_pool_max_size(), do: get_key(:tracking_pool_max_size, 300)
  def character_tracking_pause_disabled?(), do: get_key(:character_tracking_pause_disabled, true)
  def character_api_disabled?(), do: get_key(:character_api_disabled, false)
  def wanderer_kills_service_enabled?(), do: get_key(:wanderer_kills_service_enabled, false)
  def wanderer_kills_ipv6?(), do: get_key(:wanderer_kills_ipv6, false)
  def wallet_tracking_enabled?(), do: get_key(:wallet_tracking_enabled, false)
  def admins(), do: get_key(:admins, [])
  def admin_username(), do: get_key(:admin_username)
  def admin_password(), do: get_key(:admin_password)
  def corp_wallet(), do: get_key(:corp_wallet, "")
  def corp_wallet_eve_id(), do: get_key(:corp_wallet_eve_id, "-1")
  def corp_eve_id(), do: get_key(:corp_id, -1)
  def subscription_settings(), do: get_key(:subscription_settings)

  @doc """
  Returns the promo code configuration map.
  Keys are uppercase code strings, values are discount percentages.
  """
  def promo_codes() do
    case subscription_settings() do
      %{promo_codes: codes} when is_map(codes) -> codes
      _ -> %{}
    end
  end

  @doc """
  Validates a promo code and returns the discount percentage.
  Returns {:ok, discount_percent} if valid, {:error, :invalid_code} otherwise.
  Codes are case-insensitive.
  """
  def validate_promo_code(nil), do: {:error, :invalid_code}
  def validate_promo_code(""), do: {:error, :invalid_code}

  def validate_promo_code(code) when is_binary(code) do
    normalized = String.upcase(String.trim(code))

    case Map.get(promo_codes(), normalized) do
      nil -> {:error, :invalid_code}
      discount when is_integer(discount) and discount > 0 and discount <= 100 -> {:ok, discount}
      _ -> {:error, :invalid_code}
    end
  end

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "restrict_maps_creation"
            )
  def restrict_maps_creation?(), do: get_key(:restrict_maps_creation, false)

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "restrict_acls_creation"
            )
  def restrict_acls_creation?(), do: get_key(:restrict_acls_creation, false)

  def sse_enabled?() do
    Application.get_env(@app, :sse, [])
    |> Keyword.get(:enabled, false)
  end

  def webhooks_enabled?() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:webhooks_enabled, false)
  end

  @default_discord_max_killmail_age_seconds 3600

  @doc """
  Killmails older than this are dropped at the Discord dispatcher.

  Guards against an upstream replay burst on reconnect posting hours of history
  into a chat channel. Deliberately not cached: it is read once per killmail
  batch, and `Application.get_env/3` on a keyword list is cheaper than the cache
  round trip.

  The declared contract is `pos_integer()`. A non-positive configured value is
  a misconfiguration, not a valid setting. `kill_fresh?/3` keeps a kill when
  `age <= max_age_seconds`, and a kill that has already happened always has a
  non-negative age, so `0` drops every real killmail and a negative value is
  stricter still — it would keep only kills timestamped in the future (see
  `WandererApp.ExternalEvents.DiscordDispatcher.kill_fresh?/3`). Both fail in
  the same direction, silently suppressing every notification, and both are
  otherwise invisible. So both fall back to the default with a loud warning
  rather than being honoured.
  """
  def discord_max_killmail_age_seconds() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:discord_max_killmail_age_seconds, @default_discord_max_killmail_age_seconds)
    |> validate_positive_integer(
      :discord_max_killmail_age_seconds,
      @default_discord_max_killmail_age_seconds
    )
  end

  @default_discord_startup_grace_seconds 600
  @default_discord_startup_max_killmail_age_seconds 120

  @doc """
  How long after the Discord dedup marks are lost the tighter startup maximum
  age applies, in seconds. `0` disables the window.

  The marks live in `:discord_dedup_cache`, which is memory-only, so a restart
  loses every one of them. The kills client then rejoins its channel and the
  upstream service replays recent killmails, which the ordinary 3600-second
  freshness limit happily admits — an hour of already-posted kills, posted
  again. During this window `discord_startup_max_killmail_age_seconds/0`
  applies instead.

  Ten minutes rather than two because a long window is nearly free: it only
  ever drops *old* killmails. The replay burst arrives when the kills client
  joins the channel, which can be minutes after boot when the upstream service
  is slow to accept the connection, and a short window would miss it.

  Validated as NON-NEGATIVE, unlike its sibling below. `0` is a legitimate
  setting meaning "no startup window", and `validate_positive_integer/3` would
  turn an operator's "disabled" into #{@default_discord_startup_grace_seconds}
  seconds plus a warning — the opposite of what they asked for.
  """
  def discord_startup_grace_seconds() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:discord_startup_grace_seconds, @default_discord_startup_grace_seconds)
    |> validate_non_negative_integer(
      :discord_startup_grace_seconds,
      @default_discord_startup_grace_seconds
    )
  end

  @doc """
  Maximum killmail age, in seconds, while the startup window is armed.

  Validated as POSITIVE, like `discord_max_killmail_age_seconds/0` and for the
  same reason: a kill that has already happened always has a non-negative age
  and the guard keeps a kill only when `age <= max`, so `0` or a negative value
  would silently and invisibly suppress every notification.

  The accepted cost of the tighter limit is that a genuinely delayed killmail —
  upstream lag beyond this many seconds — is dropped during the window. That is
  the same trade the dispatcher already makes for at-most-once dedup: a dropped
  kill stays visible in the kills widget and on zKillboard, while a duplicate
  post in a chat channel is irreversible.
  """
  def discord_startup_max_killmail_age_seconds() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(
      :discord_startup_max_killmail_age_seconds,
      @default_discord_startup_max_killmail_age_seconds
    )
    |> validate_positive_integer(
      :discord_startup_max_killmail_age_seconds,
      @default_discord_startup_max_killmail_age_seconds
    )
  end

  @doc """
  Bot token for the voice-mention gateway connection, trimmed. `nil` when
  unset, blank, or whitespace-only — an unusable token must read as "not
  configured", or `discord_voice_mentions_enabled?/0` would enable the
  feature against a token Nostrum can never authenticate with.
  """
  def discord_bot_token() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:discord_bot_token)
    |> normalize_token()
  end

  defp normalize_token(token) when is_binary(token) do
    case String.trim(token) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_token(_), do: nil

  @doc """
  Guild whose voice channels feed kill-notification mentions, as a positive
  integer. `nil` when unset or malformed — a malformed id disables the
  feature; `VoiceGateway` warns once at boot rather than per kill.
  """
  def discord_guild_id() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:discord_guild_id)
    |> parse_guild_id()
  end

  defp parse_guild_id(nil), do: nil
  defp parse_guild_id(id) when is_integer(id) and id > 0, do: id
  defp parse_guild_id(id) when is_integer(id), do: nil

  defp parse_guild_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_guild_id(_), do: nil

  @doc """
  Voice-participant mentions are on iff both the bot token and a valid guild
  id are configured. Presence of config IS the feature flag (spec decision:
  env vars only, no DB toggle).
  """
  def discord_voice_mentions_enabled?() do
    discord_bot_token() != nil and discord_guild_id() != nil
  end

  @default_notable_items_threshold_isk 50_000_000
  @default_notable_items_limit 5
  @default_notable_items_timeout_ms 1_500

  @doc """
  Whether Discord kill embeds carry a **Notable Items** section.

  Off by default: the section costs an ESI killmail fetch and a market lookup on
  the dispatcher's critical path, so it is opt-in per deployment.
  """
  def notable_items_enabled?() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:notable_items_enabled, false)
  end

  @doc """
  Minimum ISK value for a dropped item to be worth naming. Matches
  wanderer-notifier's threshold.
  """
  def notable_items_threshold_isk() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:notable_items_threshold_isk, @default_notable_items_threshold_isk)
    |> validate_positive_integer(
      :notable_items_threshold_isk,
      @default_notable_items_threshold_isk
    )
  end

  @doc "Maximum items listed per kill. Matches wanderer-notifier's limit."
  def notable_items_limit() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:notable_items_limit, @default_notable_items_limit)
    |> validate_positive_integer(:notable_items_limit, @default_notable_items_limit)
  end

  @doc """
  Hard ceiling on how long enrichment may block the singleton dispatcher.

  This budget is load-bearing — see the concurrency notes in
  `WandererApp.ExternalEvents.Discord.NotableItems`. Raising it stalls kill
  notifications for every map on the instance.
  """
  def notable_items_timeout_ms() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:notable_items_timeout_ms, @default_notable_items_timeout_ms)
    |> validate_positive_integer(:notable_items_timeout_ms, @default_notable_items_timeout_ms)
  end

  @default_corp_tickers_timeout_ms 1_500

  @doc """
  Whether the Discord dispatcher fills in corporation tickers a killmail arrived
  without.

  On by default, unlike `notable_items_enabled?/0`: an off switch here means
  embeds silently lose the `(TICKER)` after each pilot name, which is a bug, not
  a preference. It exists as a switch only so an operator can stop the ESI
  lookups during an incident without waiting for a deploy — the enrichment
  already costs nothing on batches whose payload carried its tickers.
  """
  def corp_tickers_enabled?() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:corp_tickers_enabled, true)
  end

  @doc """
  Hard ceiling on how long corporation-ticker resolution may block the singleton
  dispatcher, in the same sense as `notable_items_timeout_ms/0`.

  Separate from that budget rather than shared with it because the two do very
  different amounts of work: ticker lookups are per-corporation and cached for
  an hour, so the steady state is a cache read, while notable items pay an ESI
  killmail fetch per kill every time.
  """
  def corp_tickers_timeout_ms() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:corp_tickers_timeout_ms, @default_corp_tickers_timeout_ms)
    |> validate_positive_integer(:corp_tickers_timeout_ms, @default_corp_tickers_timeout_ms)
  end

  @doc """
  Whether Discord messages may carry role/user pings via `allowed_mentions`.

  On by default, unlike `notable_items_enabled?/0`: mentions are already a
  per-map, per-webhook opt-in (`MapDiscordWebhook.mention_targets`), so an
  instance with nothing configured pings nobody regardless of this flag.
  This exists purely as an incident kill-switch — an operator who needs
  every mention silenced immediately (a runaway role ping, a compromised
  mention target) flips this without touching per-map config or waiting for
  a deploy.

  Gates BOTH mention paths: route-alert pings (`EmbedFormatter.route_ping/2`)
  and kill-message voice mentions (`DiscordDispatcher.voice_mention_prefix/1`).
  Deliberately not folded into `discord_voice_mentions_enabled?/0`, which also
  decides whether `VoiceGateway` connects at boot — this must take effect on
  the next message, not on the next deploy.
  """
  def discord_mentions_enabled?() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:discord_mentions_enabled, true)
  end

  defp validate_positive_integer(value, _key, _default) when is_integer(value) and value > 0,
    do: value

  defp validate_positive_integer(value, key, default) do
    Logger.warning(
      "[Discord] #{key} must be a positive integer, " <>
        "got #{inspect(value)}; falling back to #{default}"
    )

    default
  end

  # Sibling of `validate_positive_integer/3` for settings where `0` is a
  # legitimate value meaning "off" rather than a misconfiguration. Both fall
  # back loudly rather than silently.
  defp validate_non_negative_integer(value, _key, _default)
       when is_integer(value) and value >= 0,
       do: value

  defp validate_non_negative_integer(value, key, default) do
    Logger.warning(
      "[Discord] #{key} must be a non-negative integer, " <>
        "got #{inspect(value)}; falling back to #{default}"
    )

    default
  end

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "map-connection-auto-expire-hours"
            )
  def map_connection_auto_expire_hours(), do: get_key(:map_connection_auto_expire_hours)

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "map-connection-auto-eol-hours"
            )
  def map_connection_auto_eol_hours(), do: get_key(:map_connection_auto_eol_hours)

  @decorate cacheable(
              cache: WandererApp.Cache,
              key: "map-connection-eol-expire-timeout-mins"
            )
  def map_connection_eol_expire_timeout_mins(),
    do: get_key(:map_connection_eol_expire_timeout_mins)

  def get_key(key, default \\ nil), do: Application.get_env(@app, key, default)

  @doc """
  A single map containing environment variables
  made available to react
  """
  def to_client_env() do
    %{
      detailedKillsDisabled: not wanderer_kills_service_enabled?(),
      intelSharingEnabled: intel_sharing_enabled?()
    }
  end
end
