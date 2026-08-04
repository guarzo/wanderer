defmodule WandererApp.ExternalEvents.DiscordDispatcher do
  @moduledoc """
  Delivers `:map_kill` events to a map's configured Discord webhook.

  A sibling of `WebhookDispatcher`, not a variant of it: Discord ignores HMAC
  signatures and the `X-Wanderer-*` headers, requires its own body shape, and
  enforces its own rate limits.

  ## Why a GenServer

  `dispatch_event/2` is a cast, matching `WebhookDispatcher`
  (`webhook_dispatcher.ex:16,42-43`). `MapEventRelay` calls it inline, and the
  work here — config lookup, system-class resolution, formatting — involves
  cache misses that hit the database. Doing that on the relay's process would
  delay SSE and generic webhook delivery for every other subscriber.

  Responsibilities here are filtering and deduplication; serialized HTTP
  delivery belongs to the per-map worker.

  ## Deduplication is at-most-once, by choice

  The dedup key is `"\#{map_id}:\#{killmail_id}"` and is deliberately NOT scoped by
  webhook role. A kill posts once per map, to one destination — routing chooses
  which. Scoping the key by role would double-post any kill eligible for both.

  Killmails are marked as *attempted* before delivery is confirmed, so an event
  lost to a delivery failure is never re-sent. This is deliberate. Marking only
  after success would require holding the batch across an async worker
  round-trip and would still race on a crash between send and mark. Of the two
  failure modes — post a kill twice, or silently drop one — a duplicate post in
  a chat channel is irreversible and worse; a dropped kill is still visible in
  the kills widget and on zKillboard.

  This is not a delivery guarantee. It is an explicit decision to lose the
  occasional kill rather than ever double-post one.

  The one exception is `{:error, :not_running}` from the worker supervisor,
  which means nothing was enqueued at all: those marks are released, since no
  request can possibly have gone out and therefore no duplicate is possible.

  The rationale covers losses to *delivery failure* only. Kills past the
  formatter's per-event cap are never rendered into a message, so they are not
  marked at all and stay eligible if they arrive again.
  """

  use GenServer

  require Logger

  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.Env
  alias WandererApp.ExternalEvents.Discord.{EmbedFormatter, WorkerSupervisor}
  alias WandererApp.SystemClass

  @cache :discord_notification_cache
  @dedup_cache :discord_dedup_cache
  # Comfortably longer than any plausible upstream replay window, matching the
  # 24h TTLs already used for kill caches.
  @dedup_ttl :timer.hours(24)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @doc """
  Entry point called by `MapEventRelay` for every external event.

  A cast: the relay must never block on Discord-side work.
  """
  @spec dispatch_event(map_id :: String.t(), struct()) :: :ok
  def dispatch_event(map_id, event) do
    GenServer.cast(__MODULE__, {:dispatch_event, map_id, event})
  end

  @doc """
  Posts a fixed sample message to ONE webhook so a user can confirm it works.
  Routed through the same worker so it cannot jump the queue.

  Takes a webhook id, not a map id: a map can have two destinations and the
  user tests them separately.

  Reports *configuration* errors synchronously: the global kill-switch being
  off (`:notifications_disabled`) and the webhook being missing or disabled
  (`:not_configured`) are both resolved before returning.

  Delivery success is **not** awaited. The final hop is `Worker.enqueue/2`, a
  cast, so `:ok` means "accepted for delivery", not "Discord accepted it" — a
  dead or revoked webhook URL still returns `:ok` here and surfaces later as a
  failure recorded on the webhook record (`last_error`, `consecutive_failures`).
  UI built on this must not promise the user that the message arrived.
  """
  @spec send_test_message(webhook_id :: String.t()) ::
          :ok | {:error, :notifications_disabled | :not_configured | term()}
  def send_test_message(webhook_id) do
    # Checked here rather than inside the worker: when the gate is off the
    # worker supervisor and its Registry are not running at all, so calling
    # into them would crash the caller (the LiveView).
    if enabled_globally?() do
      case MapDiscordWebhook.by_id(webhook_id) do
        {:ok, %{enabled?: true} = webhook} ->
          message = %{
            "content" => "Wanderer test message — Discord kill notifications are configured."
          }

          case WorkerSupervisor.deliver(webhook.id, [message]) do
            :ok ->
              :ok

            # The gate read as on, but the worker tree is not up (e.g. the app
            # was started with webhooks disabled and the config flipped since).
            # Report it rather than claiming the test message was sent.
            {:error, :not_running} ->
              {:error, :notifications_disabled}

            {:error, reason} ->
              {:error, reason}
          end

        _ ->
          {:error, :not_configured}
      end
    else
      {:error, :notifications_disabled}
    end
  end

  @doc """
  Drops the cached config for a map after its record changes.

  A plain function, not a GenServer call: it is invoked from Ash after_action
  hooks that may run before this process exists.
  """
  def invalidate_cache(map_id) do
    Cachex.del(@cache, map_id)
    :ok
  rescue
    # The cache is not started in every context (e.g. unit tests); a missing
    # cache must not fail the write that triggered the invalidation.
    _ -> :ok
  end

  @impl true
  def handle_cast({:dispatch_event, map_id, event}, state) do
    do_dispatch(map_id, event)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug(fn -> "[Discord] dispatcher received unexpected message: #{inspect(msg)}" end)
    {:noreply, state}
  end

  defp do_dispatch(map_id, %{type: :map_kill, payload: payload}) do
    now = DateTime.utc_now()

    with true <- enabled_globally?(),
         {:ok, notification} <- fetch_config(map_id),
         true <- notification.enabled?,
         # Phase A resolves ONE destination. Routing between the system and
         # character webhooks arrives with the Router; until then the system
         # webhook is the only destination, exactly as before the split.
         {:ok, webhook} <- system_webhook(notification),
         {:ok, system_id, killmails} <- extract_kills(payload),
         true <- system_allowed?(notification, system_id),
         # Resolved ONCE per batch, not per kill: `kill_fresh?/3` runs once per
         # killmail below, and re-reading (and re-validating) config on every
         # one of potentially dozens of kills would turn a single misconfigured
         # deployment into a warning-per-kill log flood. Task 8: this binding,
         # and the explicit third argument to `kill_fresh?/3` below, must
         # survive any rewrite of this `with` chain — dropping it silently
         # reopens that flood.
         max_killmail_age_seconds = Env.discord_max_killmail_age_seconds(),
         # Stale kills (an upstream replay burst on reconnect) are filtered
         # BEFORE dedup: a kill dropped here for age was never marked attempted,
         # so it stays eligible if it arrives again inside the freshness window.
         [_ | _] = recent <-
           Enum.filter(killmails, &kill_fresh?(&1, now, max_killmail_age_seconds)),
         [_ | _] = fresh <- reject_duplicates(map_id, recent) do
      system_name = system_name(system_id)

      # Only the kills the formatter will actually render are marked. Kills past
      # its per-event cap are never turned into a message, so marking them would
      # burn them for the full dedup TTL without ever sending them — a loss to a
      # formatting cap, which the at-most-once rationale does not cover. Derived
      # from the formatter's own constant so the two cannot drift apart.
      #
      # `fresh` (not `formatted`) is still handed to format_batch/2 so it can
      # count the overflow and append its "…and N more kills not shown." line.
      formatted = Enum.take(fresh, EmbedFormatter.max_kills_per_event())

      # Marked before delivery: see the moduledoc — this is at-most-once by
      # choice, not an oversight.
      mark_attempted(map_id, formatted)

      fresh
      |> EmbedFormatter.format_batch(system_name)
      |> then(&WorkerSupervisor.deliver(webhook.id, &1))
      |> handle_delivery_result(map_id, formatted)

      :ok
    else
      _ -> :ok
    end
  end

  defp do_dispatch(_map_id, _event), do: :ok

  # A notification always has a `:system` child (the create action makes both in
  # one transaction), but the list can still be empty if the row was removed out
  # of band — return an error rather than raising on the dispatch path.
  # A disabled destination is dropped HERE, before `mark_attempted/2`: the worker
  # would drop it too, but only after the kill had been burned for the dedup TTL.
  defp system_webhook(notification) do
    case Enum.find(notification.webhooks, &(&1.role == :system and &1.enabled?)) do
      nil -> {:error, :not_configured}
      webhook -> {:ok, webhook}
    end
  end

  defp handle_delivery_result(:ok, map_id, fresh) do
    :telemetry.execute(
      [:wanderer_app, :discord_dispatcher, :dispatched],
      %{count: length(fresh)},
      %{map_id: map_id}
    )
  end

  # Nothing was enqueued, so no duplicate is possible: release the dedup marks
  # so a later event carrying these kills can still be delivered once the
  # worker tree is up. Not logged at warning level — the kill-switch being off
  # is a normal configuration, not a failure.
  defp handle_delivery_result({:error, :not_running}, map_id, fresh) do
    unmark(map_id, fresh)

    Logger.debug(fn ->
      "[Discord] worker infrastructure not running; dropped #{length(fresh)} kills for map #{map_id}"
    end)

    emit_not_delivered(map_id, fresh, :not_running)
  end

  defp handle_delivery_result({:error, reason}, map_id, fresh) do
    Logger.warning("[Discord] delivery enqueue failed for map #{map_id}: #{inspect(reason)}")
    emit_not_delivered(map_id, fresh, reason)
  end

  defp emit_not_delivered(map_id, fresh, reason) do
    :telemetry.execute(
      [:wanderer_app, :discord_dispatcher, :not_delivered],
      %{count: length(fresh)},
      %{map_id: map_id, reason: reason}
    )
  end

  defp enabled_globally?, do: WandererApp.Env.webhooks_enabled?()

  defp fetch_config(map_id) do
    case Cachex.get(@cache, map_id) do
      {:ok, nil} ->
        load_and_cache(map_id)

      {:ok, :none} ->
        {:error, :not_configured}

      {:ok, notification} ->
        {:ok, notification}

      _ ->
        load_and_cache(map_id)
    end
  end

  defp load_and_cache(map_id) do
    # `:webhooks` is loaded here, once, and rides along in the cached struct: the
    # dispatch path must not query the destination table per killmail. Every
    # child create/update/destroy invalidates this entry (Task 1), so a newly
    # added or removed webhook is picked up immediately rather than after the
    # 5-minute TTL.
    with {:ok, notification} when not is_nil(notification) <-
           MapDiscordNotification.by_map(map_id),
         {:ok, notification} <- Ash.load(notification, :webhooks) do
      Cachex.put(@cache, map_id, notification)
      {:ok, notification}
    else
      _ ->
        # Cache the negative result too, so busy unconfigured maps do not
        # hit the database on every killmail.
        Cachex.put(@cache, map_id, :none)
        {:error, :not_configured}
    end
  end

  # Only killmail batches are interesting; `:kill_count` updates carry no
  # killmails and would be noise in a channel.
  defp extract_kills(%{"type" => :killmail_update} = payload) do
    case payload["killmails"] do
      [_ | _] = kills -> {:ok, payload["solar_system_id"], kills}
      _ -> :skip
    end
  end

  defp extract_kills(_), do: :skip

  defp system_allowed?(notification, system_id) do
    cond do
      system_id in (notification.excluded_systems || []) -> false
      notification.wh_only -> SystemClass.wormhole_system?(system_id)
      true -> true
    end
  end

  defp reject_duplicates(map_id, killmails) do
    Enum.reject(killmails, fn kill ->
      case Cachex.exists?(@dedup_cache, dedup_key(map_id, kill)) do
        {:ok, true} -> true
        _ -> false
      end
    end)
  end

  # Records that we have *attempted* this killmail, not that Discord accepted
  # it. Named accordingly so the at-most-once semantics are not misread.
  defp mark_attempted(map_id, killmails) do
    Enum.each(killmails, fn kill ->
      Cachex.put(@dedup_cache, dedup_key(map_id, kill), true, ttl: @dedup_ttl)
    end)
  end

  defp unmark(map_id, killmails) do
    Enum.each(killmails, fn kill -> Cachex.del(@dedup_cache, dedup_key(map_id, kill)) end)
  end

  defp dedup_key(map_id, kill), do: "#{map_id}:#{kill["killmail_id"]}"

  defp system_name(system_id) do
    case WandererApp.CachedInfo.get_system_static_info(system_id) do
      {:ok, %{solar_system_name: name}} -> name
      _ -> nil
    end
  end

  @doc """
  Whether a killmail is recent enough to post.

  Guards against an upstream replay burst on reconnect dumping hours of history
  into a chat channel, and is the precondition that would make a join-time
  preload safe if one is ever added.

  **Fail-open on purpose.** An absent, non-string, or unparseable `kill_time`
  allows the kill through, matching the dispatcher's posture everywhere else: a
  malformed field must not silently suppress notifications. Do not change this
  to fail-closed — a parse regression would then look exactly like a quiet map.

  `now` is an argument rather than an internal `DateTime.utc_now/0` call so the
  boundary cases are testable without sleeping or freezing the clock.

  `max_age_seconds` is likewise an argument, not read from `Env` here: this
  runs once per killmail, and `do_dispatch/2` resolves it ONCE per batch and
  passes it down explicitly. Reading `Env.discord_max_killmail_age_seconds/0`
  per kill would mean a misconfigured value (see `Env`'s own validation)
  re-logs its warning once per kill instead of once per batch. The default
  here exists only so this function stays directly callable with two
  arguments in tests; `do_dispatch/2` always supplies the third explicitly.
  """
  @spec kill_fresh?(map(), DateTime.t(), pos_integer()) :: boolean()
  def kill_fresh?(
        kill,
        now \\ DateTime.utc_now(),
        max_age_seconds \\ Env.discord_max_killmail_age_seconds()
      )

  def kill_fresh?(%{"kill_time" => kill_time}, now, max_age_seconds) when is_binary(kill_time) do
    case DateTime.from_iso8601(kill_time) do
      {:ok, killed_at, _utc_offset} ->
        # Positive when the kill is in the past. A future-dated kill_time gives a
        # negative age and passes, which is the intent: this guard is about
        # staleness only.
        DateTime.diff(now, killed_at, :second) <= max_age_seconds

      {:error, _reason} ->
        true
    end
  end

  def kill_fresh?(_kill, _now, _max_age_seconds), do: true
end
