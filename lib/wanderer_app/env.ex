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

  defp validate_positive_integer(value, _key, _default) when is_integer(value) and value > 0,
    do: value

  defp validate_positive_integer(value, key, default) do
    Logger.warning(
      "[Discord] #{key} must be a positive integer, " <>
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
