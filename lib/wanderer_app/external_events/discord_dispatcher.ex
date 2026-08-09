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

  alias WandererApp.ExternalEvents.Discord.{
    CorpTickers,
    EmbedFormatter,
    Matcher,
    NotableItems,
    Router,
    SystemName,
    VoiceParticipants
  }

  alias WandererApp.ExternalEvents.Discord.WorkerSupervisor

  @cache :discord_notification_cache
  @dedup_cache :discord_dedup_cache
  # Comfortably longer than any plausible upstream replay window, matching the
  # 24h TTLs already used for kill caches.
  @dedup_ttl :timer.hours(24)

  # Lives in the dedup cache rather than the dispatcher's own state ON PURPOSE:
  # the window exists because the dedup MARKS are gone, and those marks belong
  # to that cache. The two are separate children of a `:one_for_one` supervisor,
  # so a dedup-cache-only crash loses every mark while the dispatcher keeps
  # running -- exactly the case a dispatcher-lifecycle window would miss.
  #
  # Cannot collide with a dedup key: those are `"#{map_id}:#{killmail_id}"`
  # with a UUID map_id, and this contains no colon.
  @startup_sentinel "discord-startup-grace-until"

  # Enrichment failure cooldown, shared by both enrichment steps. The counter
  # lives in the shared api cache and carries the cooldown as its TTL, so it both
  # counts and expires. Threshold and window are deliberate guesses: telemetry on
  # `[:wanderer_app, :discord, :notable_items]` and
  # `[:wanderer_app, :discord, :corp_tickers]` is what will tune them.
  @enrichment_cache :api_cache
  @notable_items_failure_key "discord-notable-items-failures"
  @enrichment_failure_threshold 3
  @enrichment_cooldown_ms :timer.seconds(60)

  # Corporation-ticker enrichment shares that bookkeeping, under its own key so
  # an ESI outage that stops ticker lookups does not also suppress notable items
  # (or the reverse).
  @corp_tickers_failure_key "discord-corp-tickers-failures"

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
         # Before the age filter and dedup on purpose: a kill dropped here was
         # never marked attempted, so it stays eligible if the same batch
         # arrives again once the map cache says the system is present.
         true <- system_on_map_counted?(map_id, system_id, length(killmails)),
         # Resolved here, ONCE per batch, and deliberately below every
         # enablement gate: the sentinel read, the `Env` reads and their
         # validation warnings must not be paid by maps that will never post to
         # Discord. See `age_limits/0`.
         {:ok, max_killmail_age_seconds, drop_context} <- age_limits(),
         # Stale kills (an upstream replay burst on reconnect) are filtered
         # BEFORE dedup: a kill dropped here for age was never marked attempted,
         # so it stays eligible if it arrives again inside the freshness window.
         # It is also upstream of every partition, so no partition can mark a
         # stale kill.
         [_ | _] = recent <-
           filter_fresh(map_id, killmails, now, max_killmail_age_seconds, drop_context),
         [_ | _] = fresh <- reject_duplicates_counted(map_id, recent) do
      # System-level filtering used to happen here for the whole batch. It now
      # lives in `Router.route/3`, because `excluded_systems` and `wh_only` have
      # per-kill carve-outs for kills involving this map's own pilots.
      # Both enrichment steps block this singleton, and they run in sequence,
      # so the worst-case hold on a batch is the SUM of their budgets — 3s with
      # both at the default 1500ms, not 1500ms. That is accepted rather than
      # shared: notable items is opt-in, so the default ceiling stays at one
      # budget, and a deployment that opts in has already accepted paying for
      # ESI killmail fetches on this path. Adding a third enrichment here, or
      # turning notable items on by default, is the point at which the two
      # should be bounded by one shared deadline instead.
      fresh
      |> partition(map_id, notification)
      |> enrich_notable_items()
      |> enrich_corp_tickers()
      |> Enum.each(fn {webhook, entries} ->
        deliver_partition(map_id, system_id, webhook, entries)
      end)

      :ok
    else
      _ -> :ok
    end
  end

  # No DB or HTTP work of its own: fetch_config/1 reads the already-cached
  # notification (a cache miss costs one Ecto query, same as the kill path
  # pays on any cache-cold map), and RouteWatcherSupervisor.notify/1 is a cast
  # into a different process. This dispatcher is a SINGLETON shared by every
  # map's kill batches — the solve, the embed, and the HTTP post all belong to
  # Discord.RouteWatcher, one GenServer per map, never to this clause.
  # Removals are in this list for the same reason additions are: the transition
  # table only runs during an evaluation, and an evaluation only happens on a
  # notify. Without a notify on removal the state stays `{:qualifying, N}`
  # indefinitely, so a route that closes and later re-opens at the same or a
  # worse jump count takes the silent `jumps < old` branch and is never
  # announced. Solver load stays bounded by the watcher's debounce and the
  # 15-minute route cache, which is what bounds it for the additions too.
  defp do_dispatch(map_id, %{type: type})
       when type in [
              :add_system,
              :connection_added,
              :connection_updated,
              :connection_removed,
              :deleted_system
            ] do
    with true <- enabled_globally?(),
         {:ok, notification} <- fetch_config(map_id),
         true <- notification.route_alerts_enabled?,
         home_system_id when not is_nil(home_system_id) <- notification.home_system_id do
      route_watcher_supervisor().notify(map_id)
    end

    :ok
  end

  defp do_dispatch(_map_id, _event), do: :ok

  defp route_watcher_supervisor,
    do:
      Application.get_env(
        :wanderer_app,
        :route_watcher_supervisor,
        WandererApp.ExternalEvents.Discord.RouteWatcherSupervisor
      )

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

  # -- notable items ---------------------------------------------------------
  #
  # Enrichment happens HERE — after routing and after the per-destination cap —
  # for two reasons. Enriching before `partition/3` spends ESI and market calls
  # on kills the router then drops. Enriching a whole partition spends the
  # budget on kills past `max_kills_per_event/0`, which are never rendered, and
  # starves the ones that are.
  #
  # It runs inline, so it BLOCKS THE SINGLETON DISPATCHER for up to
  # `Env.notable_items_timeout_ms/0`. That budget is load-bearing: every map's
  # kill batches funnel through this one process. Do not remove or raise it
  # without revisiting the decision — an unbounded enrichment here stalls kill
  # notifications instance-wide.
  #
  # The budget bounds ONE batch, not the mailbox. During a sustained ESI or
  # market outage every batch would pay it in full and the dispatcher would fall
  # arbitrarily far behind, so the failure cooldown below is part of the feature
  # rather than a follow-up: after @enrichment_failure_threshold consecutive
  # failures, enrichment is skipped outright for the cooldown window.
  defp enrich_notable_items(partitions) do
    cond do
      not Env.notable_items_enabled?() ->
        emit_notable_items(0, 0, 0, :disabled)
        partitions

      cooldown_active?(@notable_items_failure_key) ->
        emit_notable_items(0, 0, 0, :skipped_cooldown)
        partitions

      true ->
        run_enrichment(partitions, render_candidates(partitions))
    end
  end

  defp run_enrichment(partitions, []) do
    emit_notable_items(0, 0, 0, :ok)
    partitions
  end

  defp run_enrichment(partitions, candidates) do
    started = System.monotonic_time()

    case start_enrichment(candidates) do
      nil ->
        # No task supervisor: nothing was attempted, so this is not a failure to
        # count against the cooldown. Distinct from `:timeout` so the telemetry
        # does not read as a slow enricher when it is a missing supervisor.
        emit_notable_items(0, length(candidates), 0, :unavailable)
        partitions

      task ->
        # The documented `yield || shutdown` idiom. `Task.yield/2` returns
        # `{:exit, reason}` INLINE when the task crashes, so all three outcomes
        # are handled here and none of them reaches `handle_info/2`.
        result =
          Task.yield(task, Env.notable_items_timeout_ms()) ||
            Task.shutdown(task, :brutal_kill)

        handle_enrichment(partitions, candidates, result, System.monotonic_time() - started)
    end
  end

  defp handle_enrichment(partitions, candidates, result, duration) do
    case result do
      {:ok, by_kill} when is_map(by_kill) ->
        reset_failures(@notable_items_failure_key)
        emit_notable_items(duration, length(candidates), item_count(by_kill), :ok)
        merge_notable_items(partitions, by_kill)

      {:ok, _unexpected} ->
        reset_failures(@notable_items_failure_key)
        emit_notable_items(duration, length(candidates), 0, :ok)
        partitions

      {:exit, reason} ->
        note_notable_items_failure("enricher crashed: #{inspect(reason)}")
        emit_notable_items(duration, length(candidates), 0, :crash)
        partitions

      _ ->
        note_notable_items_failure("enricher timed out")
        emit_notable_items(duration, length(candidates), 0, :timeout)
        partitions
    end
  end

  # `async_nolink`, never `Task.async`: a linked task would take this singleton
  # down with it on an enrichment exception — the exact opposite of fail-open.
  # `Discord.TaskSupervisor` is started by `WorkerSupervisor`, which only runs
  # when webhooks are globally enabled; `do_dispatch/2` gates on that before
  # reaching here, so this is safe. Do not move enrichment above that gate.
  defp start_enrichment(candidates) do
    enricher = NotableItems.impl()

    start_task(fn -> enricher.enrich(candidates) end)
  end

  # Returns nil when the task could not be started at all, which in practice
  # means the Discord task supervisor is not running. Logged rather than
  # swallowed: it silently disables *both* enrichments, and unlike the other
  # failure paths it is a supervision-tree problem, not an ESI one.
  defp start_task(fun) do
    Task.Supervisor.async_nolink(WandererApp.ExternalEvents.Discord.TaskSupervisor, fun)
  rescue
    # The supervisor is not up. Fail open like every other enrichment failure.
    error ->
      Logger.warning("[Discord] enrichment task not started: #{Exception.message(error)}")
      nil
  catch
    :exit, reason ->
      Logger.warning("[Discord] enrichment task not started, exited: #{inspect(reason)}")
      nil
  end

  # Only the kills that will actually be rendered, deduplicated. `Router.route/3`
  # returns exactly one destination per kill so a kill cannot currently appear in
  # two partitions; the dedup is cheap insurance against that property changing.
  defp render_candidates(partitions) do
    partitions
    |> Enum.flat_map(fn {_webhook, entries} ->
      entries
      |> Enum.take(EmbedFormatter.max_kills_per_event())
      |> Enum.map(fn {kill, _verdict} -> kill end)
    end)
    |> Enum.uniq_by(& &1["killmail_id"])
  end

  defp merge_notable_items(partitions, by_kill) when map_size(by_kill) == 0, do: partitions

  defp merge_notable_items(partitions, by_kill) do
    Map.new(partitions, fn {webhook, entries} ->
      entries =
        Enum.map(entries, fn {kill, verdict} ->
          case Map.get(by_kill, kill["killmail_id"]) do
            nil -> {kill, verdict}
            items -> {Map.put(kill, "notable_items", items), verdict}
          end
        end)

      {webhook, entries}
    end)
  end

  defp item_count(by_kill),
    do: by_kill |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

  defp cooldown_active?(key) do
    case Cachex.get(@enrichment_cache, key) do
      {:ok, count} when is_integer(count) -> count >= @enrichment_failure_threshold
      _ -> false
    end
  end

  # The counter carries the cooldown TTL, so reaching the threshold suppresses
  # enrichment until the entry expires and a fresh attempt is made.
  defp note_notable_items_failure(reason) do
    note_failure(@notable_items_failure_key, fn count ->
      "[Discord] notable items #{reason} (#{count} consecutive); " <>
        "batch delivered without the section"
    end)
  end

  defp note_failure(key, message_fun) do
    count =
      case Cachex.get(@enrichment_cache, key) do
        {:ok, n} when is_integer(n) -> n + 1
        _ -> 1
      end

    Cachex.put(@enrichment_cache, key, count, ttl: @enrichment_cooldown_ms)

    Logger.warning(message_fun.(count))
  rescue
    # The cache is not started in every context; a bookkeeping failure must not
    # cost the batch.
    _ -> :ok
  end

  defp reset_failures(key) do
    Cachex.del(@enrichment_cache, key)
  rescue
    _ -> :ok
  end

  defp emit_notable_items(duration, kill_count, item_count, outcome) do
    :telemetry.execute(
      [:wanderer_app, :discord, :notable_items],
      %{duration: duration, kill_count: kill_count, item_count: item_count},
      %{outcome: outcome}
    )
  end

  # -- corporation tickers ---------------------------------------------------
  #
  # Same placement, budget and fail-open rules as notable items above: after
  # routing and the per-destination cap, blocking for at most
  # `Env.corp_tickers_timeout_ms/0`, and every failure path returns the
  # partitions untouched so the batch still posts.
  #
  # Unlike notable items this is NOT opt-in. The embed already claims to show
  # corporations; a payload that arrives without a ticker silently deletes the
  # whole parenthetical, which reads as "this pilot has no corp" rather than as
  # a missing optional section. See `Discord.CorpTickers` for why the payload
  # cannot be trusted here.
  defp enrich_corp_tickers(partitions) do
    cond do
      not Env.corp_tickers_enabled?() ->
        emit_corp_tickers(0, 0, 0, :disabled)
        partitions

      cooldown_active?(@corp_tickers_failure_key) ->
        emit_corp_tickers(0, 0, 0, :skipped_cooldown)
        partitions

      true ->
        # `render_candidates/1` deliberately runs once per enrichment rather
        # than once per batch. Hoisting it would mean handing the second
        # enricher a list built before the first one ran, which is correct only
        # while no enricher reads another's output — an unwritten invariant
        # worth more than the microseconds a second pass over ten maps costs.
        run_corp_tickers(partitions, render_candidates(partitions))
    end
  end

  defp run_corp_tickers(partitions, []) do
    emit_corp_tickers(0, 0, 0, :ok)
    partitions
  end

  defp run_corp_tickers(partitions, candidates) do
    # Counted here rather than inside the task so the telemetry still reports
    # how much work was owed when the task times out or crashes.
    wanted = length(CorpTickers.missing_corp_ids(candidates))

    if wanted == 0 do
      emit_corp_tickers(0, 0, 0, :ok)
      partitions
    else
      started = System.monotonic_time()
      enricher = CorpTickers.impl()

      case start_task(fn -> enricher.enrich(candidates) end) do
        nil ->
          emit_corp_tickers(0, wanted, 0, :unavailable)
          partitions

        task ->
          result =
            Task.yield(task, Env.corp_tickers_timeout_ms()) ||
              Task.shutdown(task, :brutal_kill)

          handle_corp_tickers(partitions, wanted, result, System.monotonic_time() - started)
      end
    end
  end

  defp handle_corp_tickers(partitions, wanted, result, duration) do
    case result do
      # Work was owed and none of it came back. Unlike notable items — where an
      # empty result legitimately means "this kill dropped nothing notable" —
      # every id here was asked for because a ticker is missing, so resolving
      # none of them means ESI answered nothing. Counting it is what lets the
      # cooldown stop us paying the full round trip on every subsequent batch,
      # and what makes an ESI outage visible instead of silently reappearing as
      # the exact bug this enrichment exists to fix.
      {:ok, tickers} when is_map(tickers) and map_size(tickers) == 0 ->
        note_corp_tickers_failure("resolved none of #{wanted} corporations")
        emit_corp_tickers(duration, wanted, 0, :unresolved)
        partitions

      {:ok, tickers} when is_map(tickers) ->
        reset_failures(@corp_tickers_failure_key)
        log_partial_corp_tickers(wanted, map_size(tickers))
        emit_corp_tickers(duration, wanted, map_size(tickers), :ok)
        merge_corp_tickers(partitions, tickers)

      # Only reachable through a misconfigured `:corp_tickers_enricher`. Treated
      # as a failure rather than an empty result so it cannot masquerade as a
      # healthy batch forever.
      {:ok, unexpected} ->
        note_corp_tickers_failure("enricher returned #{inspect(unexpected)}, expected a map")
        emit_corp_tickers(duration, wanted, 0, :invalid)
        partitions

      {:exit, reason} ->
        note_corp_tickers_failure("enricher crashed: #{inspect(reason)}")
        emit_corp_tickers(duration, wanted, 0, :crash)
        partitions

      _ ->
        note_corp_tickers_failure("enricher timed out")
        emit_corp_tickers(duration, wanted, 0, :timeout)
        partitions
    end
  end

  # A batch that resolves *some* of what it asked for is a success — the kills it
  # did resolve render correctly — so it neither trips the cooldown nor counts as
  # a failure. It is still worth a line: sustained partial resolution means an
  # ESI problem that no other signal here reports, since the outcome stays `:ok`.
  #
  # Only when the *majority* went unresolved, though. A corporation ESI does not
  # know, or whose record carries no ticker, never resolves and is re-requested
  # by every batch containing that kill, since nothing is ever written back to
  # the payload. Warning on any shortfall would turn one such corporation into a
  # permanent warning stream describing a fixed data condition rather than the
  # degradation this is meant to catch.
  defp log_partial_corp_tickers(wanted, resolved) when resolved * 2 < wanted do
    Logger.warning(
      "[Discord] corp tickers resolved #{resolved} of #{wanted} corporations; " <>
        "the rest post without their ticker"
    )
  end

  defp log_partial_corp_tickers(_wanted, _resolved), do: :ok

  defp merge_corp_tickers(partitions, tickers) when map_size(tickers) == 0, do: partitions

  defp merge_corp_tickers(partitions, tickers) do
    Map.new(partitions, fn {webhook, entries} ->
      {webhook,
       Enum.map(entries, fn {kill, verdict} ->
         {CorpTickers.apply_tickers(kill, tickers), verdict}
       end)}
    end)
  end

  defp note_corp_tickers_failure(reason) do
    note_failure(@corp_tickers_failure_key, fn count ->
      "[Discord] corp tickers #{reason} (#{count} consecutive); " <>
        "batch delivered without corporation tickers"
    end)
  end

  defp emit_corp_tickers(duration, corp_count, resolved_count, outcome) do
    :telemetry.execute(
      [:wanderer_app, :discord, :corp_tickers],
      %{duration: duration, corp_count: corp_count, resolved_count: resolved_count},
      %{outcome: outcome}
    )
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

    {prefix, mention_count} = voice_mention_prefix(role)

    # PASS THE WHOLE PARTITION, NOT `rendered`. The formatter applies the cap
    # itself and counts the remainder into its "…and N more kills not shown."
    # line. Handing it the pre-truncated list compiles, passes most tests, and
    # silently deletes the overflow line.
    entries
    |> EmbedFormatter.format_batch(system_name)
    |> VoiceParticipants.prepend_to_messages(prefix)
    |> then(&WorkerSupervisor.deliver(webhook.id, &1))
    |> handle_delivery_result(map_id, role, marked, mention_count)
  end

  # Voice mentions go to the system channel only (spec decision), and only
  # when configured. `nil` count means "feature off" and keeps the
  # measurement out of telemetry entirely, so 0 always means "enabled but
  # nobody taggable" — the distinction operators need.
  #
  # `discord_mentions_enabled?/0` is the instance-wide incident switch and
  # gates this path too, not just route alerts: .env.example documents it as
  # silencing "role and user pings on kill and route notifications". It is
  # checked HERE rather than folded into `discord_voice_mentions_enabled?/0`,
  # which also decides whether `VoiceGateway` connects at boot — flipping the
  # switch must silence pings immediately, not require a redeploy to undo.
  defp voice_mention_prefix(:system) do
    if Env.discord_mentions_enabled?() and Env.discord_voice_mentions_enabled?() do
      VoiceParticipants.get_active_voice_mentions()
      |> VoiceParticipants.mention_prefix()
    else
      {nil, nil}
    end
  end

  defp voice_mention_prefix(_role), do: {nil, nil}

  defp handle_delivery_result(:ok, map_id, role, kills, mention_count) do
    measurements =
      case mention_count do
        nil -> %{count: length(kills)}
        n -> %{count: length(kills), mention_count: n}
      end

    :telemetry.execute(
      [:wanderer_app, :discord_dispatcher, :dispatched],
      measurements,
      %{map_id: map_id, role: role}
    )
  end

  # Nothing was enqueued, so no duplicate is possible: release this partition's
  # dedup marks so a later event carrying these kills can still be delivered
  # once the worker tree is up. Other partitions in the same event are
  # unaffected — their marks stand or fall on their own delivery result. Not
  # logged at warning level — the kill-switch being off is a normal
  # configuration, not a failure.
  defp handle_delivery_result({:error, :not_running}, map_id, role, kills, _mention_count) do
    unmark(map_id, kills)

    Logger.debug(fn ->
      "[Discord] worker infrastructure not running; dropped #{length(kills)} " <>
        "#{role} kills for map #{map_id}"
    end)

    emit_not_delivered(map_id, role, kills, :not_running)
  end

  defp handle_delivery_result({:error, reason}, map_id, role, kills, _mention_count) do
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

  # Bounds the `SystemMapIndex` staleness window: the index refreshes on a
  # 5-minute timer when the kills client is disconnected, so a system removed
  # from a map keeps producing kill broadcasts until the next refresh. The live
  # map cache is dropped by `WandererApp.Map.remove_system/2` immediately, so it
  # is strictly fresher.
  #
  # FAIL-OPEN, and this is the whole reason the guard is safe to add: it returns
  # false ONLY on a positive "this map is readable and does not have that
  # system". A map with no live GenServer has no `:map_cache` entry, which is
  # not evidence of removal. `systems` is keyed by `solar_system_id`
  # (`WandererApp.Map` defstruct, and `add_system/2`).
  #
  # The started flag is checked FIRST because a present entry is not yet a
  # readable one: `WandererApp.Map.new/1` commits the struct with `systems: %{}`
  # and `add_systems!/2` fills it one `update_map/2` at a time, so during map
  # start the entry positively reports "not on this map" for every system. Same
  # precondition `can_broadcast?/1` uses (`map_server_impl.ex:463-467`); it is
  # `insert`ed `false` at `start_map/1` entry, `true` only at its end, and
  # deleted on stop, so all three non-ready states fall through to `true`.
  defp system_on_map?(map_id, system_id) do
    with true <- WandererApp.Cache.lookup!("map_#{map_id}:started", false),
         {:ok, %{systems: systems}} when is_map(systems) <- WandererApp.Map.get_map(map_id) do
      Map.has_key?(systems, system_id)
    else
      _ -> true
    end
  rescue
    # `Cachex.get/2` RAISES against an unstarted cache rather than returning an
    # error tuple, and `get_map/1` has no catch-all clause, so a non-`{:ok, _}`
    # return raises CaseClauseError. Either would crash the dispatcher and lose
    # the whole batch — the opposite of failing open. Same contract
    # `Matcher.tracked_eve_ids/1` rescues (`discord/matcher.ex:53-60`).
    _ -> true
  end

  # Batch-level, so it costs nothing per kill. Without it the membership guard
  # is the one drop path with no trace at all, and an operator asking "why did
  # this kill not post?" gets `:age`, `:startup_age`, `:duplicate`, and silence.
  defp system_on_map_counted?(map_id, system_id, count) do
    if system_on_map?(map_id, system_id) do
      true
    else
      emit_dropped(map_id, count, :not_on_map)
      false
    end
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

  # Resolves everything the age filter needs, ONCE per batch, never per kill:
  # `kill_fresh?/3` runs once per killmail, and re-reading (and re-validating)
  # config on every one of potentially dozens of kills would turn a single
  # misconfigured deployment into a warning-per-kill log flood. The `{:ok, ...}`
  # shape exists only so this can be a `with` clause in `do_dispatch/2` — an
  # `if` cannot be one in either its block or its keyword form, and hoisting it
  # back out of the chain would make every map on the instance pay for it before
  # the enablement gates rejected the batch.
  #
  # The result, and the explicit third argument to `kill_fresh?/3`, must survive
  # any rewrite of that chain — dropping either silently reopens the flood.
  # Filtering for age happens ONCE, before partitioning: moving it inside the
  # per-destination loop reintroduces it too.
  #
  # The `arm_startup_grace/0` read is one ETS read per batch, deliberately NOT
  # cached in dispatcher state: the dedup cache and this GenServer are
  # independent children of a `:one_for_one` supervisor, so a cache-only crash
  # would leave cached state stale in exactly the scenario the window exists for.
  defp age_limits do
    startup_arm_until = arm_startup_grace()

    ordinary_max_age_seconds = Env.discord_max_killmail_age_seconds()

    # The branch picks WHICH accessor to call. It does not move the call
    # per-kill.
    max_killmail_age_seconds =
      if within_startup_grace?(startup_arm_until) do
        Env.discord_startup_max_killmail_age_seconds()
      else
        ordinary_max_age_seconds
      end

    {:ok, max_killmail_age_seconds,
     {ordinary_max_age_seconds, startup_grace_remaining_ms(startup_arm_until)}}
  end

  # Wraps the age filter purely so the drop is counted. A kill dropped for age
  # otherwise falls out of the `with` chain into its catch-all `:ok` and leaves
  # no trace whatsoever, which makes "did we suppress it, or did we never
  # receive it?" unanswerable during an incident.
  defp filter_fresh(map_id, killmails, now, max_age_seconds, drop_context) do
    {ordinary_max_age_seconds, remaining_ms} = drop_context

    {kept, dropped} = Enum.split_with(killmails, &kill_fresh?(&1, now, max_age_seconds))

    # Classified PER KILL against the ORDINARY limit, not by whether the window
    # is open. Inside the window a kill can fail the tighter limit for either
    # of two reasons: the window suppressed it, or it was old enough that the
    # pre-existing hour limit would have dropped it anyway. Labelling both
    # `:startup_age` inflates "kills the window suppressed" with kills the
    # window had nothing to do with -- in exactly the metric an operator reads
    # to judge whether the window is too aggressive.
    #
    # Outside the window `max_age_seconds == ordinary_max_age_seconds`, so
    # every dropped kill fails this second test too and classifies as `:age`.
    # No branch on `startup?` is needed to get that: it falls out.
    {startup_age, age} =
      Enum.split_with(dropped, &kill_fresh?(&1, now, ordinary_max_age_seconds))

    emit_dropped(map_id, length(startup_age), :startup_age)
    emit_dropped(map_id, length(age), :age)

    # At info, not debug: this fires at most once per batch, only when the
    # window actually suppressed something, and it is the line an operator
    # searches for when a restart looks too quiet. Ordinary age and dedup drops
    # stay telemetry-only -- they are steady-state behaviour, not an event.
    if startup_age != [] do
      Logger.info(fn ->
        "[Discord] startup grace window suppressed #{length(startup_age)} " <>
          "replayed killmail(s); #{div(remaining_ms, 1000)}s of the window remain"
      end)
    end

    kept
  end

  defp reject_duplicates_counted(map_id, killmails) do
    kept = reject_duplicates(map_id, killmails)

    emit_dropped(map_id, length(killmails) - length(kept), :duplicate)

    kept
  end

  # Silent when nothing was dropped: a counter that fires with `count: 0` on
  # every healthy batch buries the signal it exists to carry.
  defp emit_dropped(_map_id, 0, _reason), do: :ok

  defp emit_dropped(map_id, count, reason) do
    :telemetry.execute(
      [:wanderer_app, :discord_dispatcher, :killmail_dropped],
      %{count: count},
      %{map_id: map_id, reason: reason}
    )

    :ok
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

  @doc "Name of the startup-window sentinel key, so tests do not hardcode it."
  @spec startup_sentinel_key() :: String.t()
  def startup_sentinel_key, do: @startup_sentinel

  @doc """
  Reads the startup-window deadline from the dedup cache, writing one if it is
  absent. Idempotent, and called once per kill batch.

  ABSENT means the cache is new and its marks are gone, so arm. PRESENT means
  the cache survived, so honour the stored deadline as it is -- including an
  expired one. The deadline is absolute, not a TTL, precisely so that an expired
  window is still a *present* sentinel and nothing re-arms it while the cache
  lives.

  Called per batch rather than from `init/1` because the cache and the
  dispatcher are independent children of a `:one_for_one` supervisor. A
  dedup-cache-only crash never runs `init/1`, so a deadline cached in dispatcher
  state would go stale in exactly the scenario this window exists for.

  Public because it is the unit under test: driving it directly is the only way
  to exercise a cache-only restart, which restarting the dispatcher cannot
  reach.
  """
  @spec arm_startup_grace() :: integer() | :never
  def arm_startup_grace do
    case Cachex.get(@dedup_cache, @startup_sentinel) do
      {:ok, nil} ->
        # The only `Env` read on this path, and it runs once per cache
        # lifetime, not once per batch -- so the once-per-batch config
        # constraint holds.
        arm_until =
          System.monotonic_time(:millisecond) + Env.discord_startup_grace_seconds() * 1000

        Cachex.put(@dedup_cache, @startup_sentinel, arm_until)
        # REQUIRED, not belt-and-braces. This cache is created with
        # `default_ttl: :timer.hours(24)` (`application.ex:150-154`), and
        # `Cachex.Actions.Put.execute/4` honours only an INTEGER `:ttl` --
        # `nil` falls back to the cache default. Without this the sentinel
        # would expire after a day of uptime and the window would spuriously
        # re-arm on a healthy cache that never lost a mark.
        Cachex.persist(@dedup_cache, @startup_sentinel)

        arm_until

      {:ok, arm_until} when is_integer(arm_until) ->
        arm_until

      _ ->
        :never
    end
  rescue
    # `Cachex.get/2` raises against an unstarted cache. Failing to read the
    # sentinel must leave the window CLOSED, not open: an unreadable cache is
    # not evidence that marks were lost, and arming on it would suppress real
    # killmails. Fail-open here means "do not suppress".
    _ -> :never
  end

  @doc """
  Whether a batch is inside the startup grace window.

  `:never` rather than a sentinel integer for the unarmed case: Erlang
  monotonic time may be negative, so no integer is reliably "in the past".
  """
  @spec within_startup_grace?(integer() | :never) :: boolean()
  def within_startup_grace?(:never), do: false

  def within_startup_grace?(arm_until) when is_integer(arm_until),
    do: System.monotonic_time(:millisecond) < arm_until

  # Clamped at zero: a batch can land microseconds after the deadline while
  # `startup?` was computed just before it, and a negative "seconds remaining"
  # in a log line reads as a bug in the window rather than a rounding artifact.
  defp startup_grace_remaining_ms(:never), do: 0

  defp startup_grace_remaining_ms(arm_until) when is_integer(arm_until),
    do: max(arm_until - System.monotonic_time(:millisecond), 0)

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
  runs once per killmail, and `do_dispatch/2` resolves it ONCE per batch — via
  `age_limits/0`, below its enablement gates — and passes it down explicitly.
  Reading `Env.discord_max_killmail_age_seconds/0`
  per kill would mean a misconfigured value (see `Env`'s own validation)
  re-logs its warning once per kill instead of once per batch. The default
  here exists only so this function stays directly callable with two
  arguments in tests; `do_dispatch/2` always supplies the third explicitly.

  During the startup grace window the caller passes
  `Env.discord_startup_max_killmail_age_seconds/0` instead. This function is
  unchanged by that: it already takes the maximum as an explicit argument, so
  both call paths flow through the same comparison.
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
