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
  formatter's per-destination cap are never rendered into a message, so they are
  not marked at all and stay eligible if they arrive again. The same holds for
  kills the router drops: they belong to no partition and are never marked.
  """

  use GenServer

  require Logger

  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.Env
  alias WandererApp.ExternalEvents.Discord.{EmbedFormatter, Matcher, Router, SystemName}
  alias WandererApp.ExternalEvents.Discord.WorkerSupervisor

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

  Reports *configuration* errors synchronously, each as its own atom, because
  they ask the user for different things:

    * `:notifications_disabled` — the global kill-switch is off. Only an
      administrator can change it.
    * `:webhook_not_found` — no row with that id, in practice a stale page whose
      destination was deleted in another session.
    * `:webhook_url_missing` — the row exists but carries no usable URL.
    * `:webhook_disabled` — the row exists and has a URL; `enabled?` is false.
      Nothing is wrong with the configuration, it is switched off.

  These were one `:not_configured` until the Task 16 gate. Telling a user to
  save a webhook URL when they had already saved one and merely unticked the
  box is why they were split; `map_notifications_component.ex` had to
  re-derive the disabled case from its own assigns to avoid printing that.

  Delivery success is **not** awaited. The final hop is `Worker.enqueue/2`, a
  cast, so `:ok` means "accepted for delivery", not "Discord accepted it" — a
  dead or revoked webhook URL still returns `:ok` here and surfaces later as a
  failure recorded on the webhook record (`last_error`, `consecutive_failures`).
  UI built on this must not promise the user that the message arrived.
  """
  @spec send_test_message(webhook_id :: String.t()) ::
          :ok
          | {:error,
             :notifications_disabled
             | :webhook_not_found
             | :webhook_url_missing
             | :webhook_disabled
             | term()}
  def send_test_message(webhook_id) do
    # Checked here rather than inside the worker: when the gate is off the
    # worker supervisor and its Registry are not running at all, so calling
    # into them would crash the caller (the LiveView).
    if enabled_globally?() do
      with {:ok, webhook} <- resolve_test_webhook(webhook_id) do
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
      end
    else
      {:error, :notifications_disabled}
    end
  end

  # Clause order is the user-facing precedence and is load-bearing: a row that
  # is BOTH disabled and URL-less reports `:webhook_disabled`. That preserves
  # what the component rendered before this split, where its local `enabled?`
  # check ran ahead of any call into the dispatcher.
  defp resolve_test_webhook(webhook_id) do
    case MapDiscordWebhook.by_id(webhook_id) do
      {:ok, %{enabled?: false}} ->
        {:error, :webhook_disabled}

      {:ok, %{webhook_url: url} = webhook} when is_binary(url) and url != "" ->
        {:ok, webhook}

      {:ok, _webhook} ->
        # `webhook_url` is `allow_nil? false` and validated on write, so this is
        # not reachable through the UI. It is reachable through a hand-repaired
        # row or a vault key that no longer decrypts the stored ciphertext —
        # exactly the cases where "save a URL first" is the right advice and
        # "no such destination" would send the operator looking in the wrong
        # place. Deliberately NOT `valid_webhook_url?/1`: re-running the
        # stricter write-time validator here would reclassify rows that were
        # accepted when they were saved.
        {:error, :webhook_url_missing}

      _ ->
        {:error, :webhook_not_found}
    end
  end

  @doc """
  Drops the cached config for a map after its record changes.

  A plain function, not a GenServer call: it is invoked from Ash
  after_transaction hooks that may run before this process exists.
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
         {:ok, system_id, killmails} <- extract_kills(payload),
         # Resolved ONCE per batch, not per kill: `kill_fresh?/3` runs once per
         # killmail below, and re-reading (and re-validating) config on every
         # one of potentially dozens of kills would turn a single misconfigured
         # deployment into a warning-per-kill log flood. This binding, and the
         # explicit third argument to `kill_fresh?/3` below, must survive any
         # rewrite of this `with` chain — dropping either silently reopens that
         # flood. Filtering for age happens HERE, once, before partitioning:
         # moving it inside the per-destination loop reintroduces the flood.
         max_killmail_age_seconds = Env.discord_max_killmail_age_seconds(),
         # Stale kills (an upstream replay burst on reconnect) are filtered
         # BEFORE dedup: a kill dropped here for age was never marked attempted,
         # so it stays eligible if it arrives again inside the freshness window.
         # It is also upstream of every partition, so no partition can mark a
         # stale kill.
         [_ | _] = recent <-
           Enum.filter(killmails, &kill_fresh?(&1, now, max_killmail_age_seconds)),
         [_ | _] = fresh <- reject_duplicates(map_id, recent) do
      # System-level filtering used to happen here for the whole batch. It now
      # lives in `Router.route/3`, because `excluded_systems` and `wh_only` have
      # per-kill carve-outs for kills involving this map's own pilots.
      fresh
      |> partition(map_id, notification)
      |> Enum.each(fn {webhook, entries} ->
        deliver_partition(map_id, system_id, webhook, entries)
      end)

      :ok
    else
      _ -> :ok
    end
  end

  defp do_dispatch(_map_id, _event), do: :ok

  # Routing is per kill, so a single `:map_kill` batch can now contain kills
  # bound for different destinations, or for none. Kills that drop belong to no
  # partition and are NEVER MARKED, so they stay eligible if they arrive again.
  #
  # Each entry keeps its verdict alongside the kill: the formatter needs it for
  # colouring and title (loss vs kill).
  defp partition(kills, map_id, notification) do
    tracked = Matcher.tracked_eve_ids(map_id)
    focus = notification.focus_corp_ids || []

    kills
    |> Enum.reduce(%{}, fn kill, acc ->
      verdict = Matcher.involvement(kill, tracked, focus)

      case Router.route(kill, notification, verdict) do
        {:ok, webhook} -> Map.update(acc, webhook, [{kill, verdict}], &[{kill, verdict} | &1])
        :drop -> acc
      end
    end)
    # Reduce prepends; restore the batch's original order per destination.
    |> Map.new(fn {webhook, entries} -> {webhook, Enum.reverse(entries)} end)
  end

  # The role reaching `SystemName.display_name/3` is a LITERAL atom matched out
  # of the destination itself, one clause per role — never `webhook.role`
  # threaded through as a variable. That resolver is the privacy boundary
  # (map-local chain names on the `:system` webhook only, because the character
  # channel is commonly public), and it can only enforce that boundary if the
  # role it receives is genuinely this destination's own. A variable reused
  # across partitions is the one remaining leak path, and a Discord post cannot
  # be recalled. An unknown role raises here instead of guessing — correct.
  defp deliver_partition(map_id, system_id, %{role: :system} = webhook, entries) do
    deliver_to(
      map_id,
      webhook,
      :system,
      SystemName.display_name(map_id, system_id, :system),
      entries
    )
  end

  defp deliver_partition(map_id, system_id, %{role: :character} = webhook, entries) do
    deliver_to(
      map_id,
      webhook,
      :character,
      SystemName.display_name(map_id, system_id, :character),
      entries
    )
  end

  # Each non-empty partition is formatted and delivered independently.
  defp deliver_to(map_id, webhook, role, system_name, entries) do
    # THE CAP IS PER DESTINATION, NOT PER EVENT. It is a Discord message-size
    # concern, so two destinations do not compete for one 30-kill budget.
    rendered = Enum.take(entries, EmbedFormatter.max_kills_per_event())
    marked = Enum.map(rendered, fn {kill, _verdict} -> kill end)

    # Marked before delivery: see the moduledoc — this is at-most-once by
    # choice, not an oversight. Only the kills the formatter will actually
    # render are marked; kills past the cap are never turned into a message, so
    # marking them would burn them for the full dedup TTL without ever sending
    # them.
    mark_attempted(map_id, marked)

    # PASS THE WHOLE PARTITION, NOT `rendered`. The formatter applies the cap
    # itself and counts the remainder into its "…and N more kills not shown."
    # line. Handing it the pre-truncated list compiles, passes most tests, and
    # silently deletes the overflow line.
    entries
    |> EmbedFormatter.format_batch(system_name)
    |> then(&WorkerSupervisor.deliver(webhook.id, &1))
    |> handle_delivery_result(map_id, role, marked)
  end

  defp handle_delivery_result(:ok, map_id, role, kills) do
    :telemetry.execute(
      [:wanderer_app, :discord_dispatcher, :dispatched],
      %{count: length(kills)},
      %{map_id: map_id, role: role}
    )
  end

  # Nothing was enqueued, so no duplicate is possible: release this partition's
  # dedup marks so a later event carrying these kills can still be delivered
  # once the worker tree is up. Other partitions in the same event are
  # unaffected — their marks stand or fall on their own delivery result. Not
  # logged at warning level — the kill-switch being off is a normal
  # configuration, not a failure.
  defp handle_delivery_result({:error, :not_running}, map_id, role, kills) do
    unmark(map_id, kills)

    Logger.debug(fn ->
      "[Discord] worker infrastructure not running; dropped #{length(kills)} " <>
        "#{role} kills for map #{map_id}"
    end)

    emit_not_delivered(map_id, role, kills, :not_running)
  end

  defp handle_delivery_result({:error, reason}, map_id, role, kills) do
    Logger.warning(
      "[Discord] #{role} delivery enqueue failed for map #{map_id}: #{inspect(reason)}"
    )

    emit_not_delivered(map_id, role, kills, reason)
  end

  defp emit_not_delivered(map_id, role, kills, reason) do
    :telemetry.execute(
      [:wanderer_app, :discord_dispatcher, :not_delivered],
      %{count: length(kills)},
      %{map_id: map_id, role: role, reason: reason}
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

  # The `seen` accumulator matters as much as the cache lookup: `mark_attempted/2`
  # only runs after the whole batch is filtered, so a batch carrying the same
  # killmail_id twice passed both copies through and posted the kill twice.
  defp reject_duplicates(map_id, killmails) do
    {kept, _seen} =
      Enum.reduce(killmails, {[], MapSet.new()}, fn kill, {kept, seen} ->
        key = dedup_key(map_id, kill)

        cached? =
          case Cachex.exists?(@dedup_cache, key) do
            {:ok, true} -> true
            _ -> false
          end

        if cached? or MapSet.member?(seen, key) do
          {kept, seen}
        else
          {[kill | kept], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(kept)
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

  @doc """
  Dedup cache key for one killmail, by kill map or by bare killmail id.

  Public so tests derive the key instead of hardcoding its format: a hardcoded
  key makes `refute`-style assertions ("this kill was never marked") pass
  vacuously the moment the format changes.

  NOT role-scoped, deliberately: exactly one destination is chosen per kill,
  so one key per (map, killmail) is exactly right. Should a future change ever
  post one kill to BOTH channels, this key must gain the role — otherwise the
  first post marks the kill and the second is silently suppressed.
  """
  @spec dedup_key(String.t(), map() | integer() | String.t()) :: String.t()
  def dedup_key(map_id, kill) when is_map(kill), do: dedup_key(map_id, kill["killmail_id"])
  def dedup_key(map_id, killmail_id), do: "#{map_id}:#{killmail_id}"

  @doc "Name of the dedup cache, so tests do not hardcode it either."
  @spec dedup_cache() :: atom()
  def dedup_cache, do: @dedup_cache

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
