# A stand-in for the real enricher. NOT Mox: the enricher runs inside a task
# spawned off `Discord.TaskSupervisor`, and a Mox expectation set in the test
# process is not visible from an unrelated process without global mode — which
# would in turn conflict with the timeout case, where the "enricher" never
# returns at all.
defmodule WandererApp.ExternalEvents.DiscordDispatcherTest.Enricher do
  @behaviour WandererApp.ExternalEvents.Discord.NotableItems

  @impl true
  def enrich(kills) do
    case Process.whereis(:notable_items_observer) do
      nil -> :ok
      pid -> send(pid, {:enrich_called, kills})
    end

    case Application.get_env(:wanderer_app, :test_notable_items_mode, %{}) do
      :timeout -> Process.sleep(:infinity)
      :crash -> raise "enricher boom"
      by_kill when is_map(by_kill) -> by_kill
    end
  end
end

defmodule WandererApp.ExternalEvents.DiscordDispatcherTest.TickerEnricher do
  @behaviour WandererApp.ExternalEvents.Discord.CorpTickers

  @impl true
  def enrich(kills) do
    case Process.whereis(:corp_tickers_observer) do
      nil -> :ok
      pid -> send(pid, {:tickers_called, kills})
    end

    case Application.get_env(:wanderer_app, :test_corp_tickers_mode, %{}) do
      :timeout -> Process.sleep(:infinity)
      :crash -> raise "ticker enricher boom"
      tickers when is_map(tickers) -> tickers
    end
  end
end

defmodule WandererApp.ExternalEvents.DiscordDispatcherTest.RouteWatcherObserver do
  @moduledoc "Stands in for RouteWatcherSupervisor.notify/1 so tests can assert it was called."
  def notify(map_id) do
    case Process.whereis(:route_watcher_observer) do
      nil -> :ok
      pid -> send(pid, {:route_notify, map_id})
    end

    :ok
  end
end

defmodule WandererApp.ExternalEvents.DiscordDispatcherTest do
  # `async: false` is mandatory: `HttpStub` keeps its state in a single named
  # Agent, and this file also mutates application env.
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.ExternalEvents.{DiscordDispatcher, Event}

  alias WandererApp.ExternalEvents.Discord.{
    EmbedFormatter,
    HttpStub,
    Matcher,
    WorkerSupervisor
  }

  alias WandererApp.ExternalEvents.DiscordDispatcherTest.Enricher
  alias WandererApp.ExternalEvents.DiscordDispatcherTest.TickerEnricher
  alias WandererAppWeb.Factory

  # Must match `DiscordDispatcher`'s own key: the cooldown tests clear it
  # between runs, and a private counter left behind would silently disable
  # enrichment for every later test in this file.
  @failure_key "discord-notable-items-failures"
  @ticker_failure_key "discord-corp-tickers-failures"

  # A real wormhole system id (J-space) and a real known-space id (Jita).
  @wh_system 31_000_005
  @ks_system 30_000_142

  @system_url "https://discord.com/api/webhooks/123/tok"
  @character_url "https://discord.com/api/webhooks/456/chr"

  setup do
    # `wh_only` filtering resolves the system class through
    # `CachedInfo.get_system_static_info/1`, which falls back to the
    # `map_solar_systems` table. That table is static import data and is NOT
    # populated by `mix test` on a clean database, so seed the cache directly —
    # the same approach `WandererApp.MapTestHelpers` uses.
    seed_static_info()

    # `config/test.exs:35` sets `external_events: [webhooks_enabled: false]`, and
    # the dispatcher checks `Env.webhooks_enabled?/0` at call time. Without this
    # override EVERY delivery assertion below would pass while sending nothing.
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, :webhooks_enabled, true)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)

    HttpStub.start()
    HttpStub.reset()
    start_supervised!(WorkerSupervisor)
    start_supervised!(DiscordDispatcher)

    map = Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{map_id: map.id, webhook_url: @system_url})

    DiscordDispatcher.invalidate_cache(map.id)

    %{map: map, notification: notification, system: system_webhook(notification)}
  end

  defp system_webhook(notification) do
    {:ok, webhooks} = MapDiscordWebhook.by_notification(notification.id)
    Enum.find(webhooks, &(&1.role == :system))
  end

  defp character_webhook(notification, url \\ @character_url) do
    {:ok, wh} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: url
      })

    wh
  end

  # `tracked_eve_ids/1` reads a cache keyed by map (Task 6). Seed it directly:
  # this file is about routing and batching, not about how the set is built.
  # The cache name MUST match the Matcher's — it reads
  # `:discord_notification_cache` under a namespaced key. Seeding a different
  # cache here would leave the tracked set empty, every kill would take the
  # `:not_involved` branch, and the routing tests would pass for the wrong
  # reason while asserting nothing.
  defp track(map_id, eve_ids) do
    Cachex.put(
      :discord_notification_cache,
      "map:#{map_id}:tracked_eve_ids",
      MapSet.new(eve_ids)
    )

    on_exit(fn -> Matcher.invalidate_tracked(map_id) end)
    :ok
  end

  defp killmail(id, overrides \\ %{}) do
    Factory.build(
      :killmail,
      Map.merge(
        %{
          "solar_system_id" => @wh_system,
          "killmail_id" => id,
          "victim_char_id" => 8000,
          "victim_corp_id" => 800_000,
          "attacker_char_ids" => [],
          "attacker_corp_ids" => []
        },
        overrides
      )
    )
  end

  # The formatter takes `{kill, verdict}` pairs. Tests that call it directly to
  # derive an expected message count pair every kill with `:not_involved`, which
  # only affects colour and author line, not the chunking they measure.
  defp entries(kills), do: Enum.map(kills, &{&1, :not_involved})

  # C3 for the J-space id, high-sec (class 0) for Jita, matching the shape
  # `MapTestHelpers.default_test_systems/0` stores.
  #
  # `:system_static_info_cache` is a GLOBAL Cachex table, not sandboxed per test,
  # so these entries must be removed again: `CommonAPIControllerTest` inserts its
  # own Jita row and reads it back through this same cache, and a partial entry
  # left behind here makes it fail on a missing `region_id`.
  defp seed_static_info do
    Cachex.put(:system_static_info_cache, @wh_system, %{
      solar_system_id: @wh_system,
      solar_system_name: "J115405",
      system_class: 3
    })

    Cachex.put(:system_static_info_cache, @ks_system, %{
      solar_system_id: @ks_system,
      solar_system_name: "Jita",
      system_class: 0
    })

    on_exit(fn ->
      Cachex.del(:system_static_info_cache, @wh_system)
      Cachex.del(:system_static_info_cache, @ks_system)
    end)

    :ok
  end

  defp disable_gate do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, :webhooks_enabled, false)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
  end

  defp kill_event(payload), do: %Event{map_id: nil, type: :map_kill, payload: payload}

  # Guild fixture for voice-mention tests: users 111/222 in a voice channel,
  # 333 in the AFK channel, channel 20 is text. Shapes mirror Nostrum structs.
  @voice_guild %{
    id: 999,
    afk_channel_id: 30,
    channels: %{
      10 => %{id: 10, type: 2},
      20 => %{id: 20, type: 0},
      30 => %{id: 30, type: 2}
    },
    voice_states: [
      %{user_id: 111, channel_id: 10},
      %{user_id: 222, channel_id: 10},
      %{user_id: 333, channel_id: 30}
    ]
  }

  defp enable_voice_mentions(fetcher \\ nil) do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      original
      |> Keyword.put(:discord_bot_token, "test-token")
      |> Keyword.put(:discord_guild_id, "999")
    )

    Application.put_env(
      :wanderer_app,
      :discord_voice_guild_fetcher,
      fetcher || fn 999 -> @voice_guild end
    )

    on_exit(fn ->
      Application.put_env(:wanderer_app, :external_events, original)
      Application.delete_env(:wanderer_app, :discord_voice_guild_fetcher)
    end)
  end

  # Derived from the dispatcher rather than spelled out here. A hardcoded key
  # would make every `refute marked?(...)` below pass vacuously if the key
  # format ever changed — the assertion that matters most in these tests.
  defp marked?(map_id, killmail_id) do
    Cachex.exists?(
      DiscordDispatcher.dedup_cache(),
      DiscordDispatcher.dedup_key(map_id, killmail_id)
    ) == {:ok, true}
  end

  # Dispatch is a cast and delivery is a second async hop, so tests synchronize
  # rather than guess: drain the dispatcher's mailbox, then the worker's.
  # Keyed by WEBHOOK id — that is the Registry key since Task 3.
  defp settle(webhook_id) do
    :sys.get_state(DiscordDispatcher)

    case Registry.lookup(WorkerSupervisor.registry(), webhook_id) do
      [{pid, _}] -> :sys.get_state(pid)
      [] -> :no_worker
    end
  end

  # Asserting "nothing was delivered" needs more than `settle/1`: the HTTP call
  # itself runs in a `Task.Supervisor.async_nolink` task, so a request can still
  # be in flight when the worker's mailbox is drained. Wait until the worker is
  # genuinely idle (no queued event, none in progress) before asserting, or the
  # assertion passes for the wrong reason. Mutating the seeded system class
  # confirms this: without the wait, marking Jita as wormhole space still leaves
  # "skips non-wormhole systems" green.
  #
  # `webhook_id` may be nil (a map with no configuration at all), in which case
  # there is no worker to wait on and the HTTP assertion is the whole check.
  defp refute_delivery(webhook_id, timeout \\ 2_000) do
    if webhook_id do
      settle(webhook_id)
      await_worker_idle(webhook_id, System.monotonic_time(:millisecond) + timeout)
    else
      :sys.get_state(DiscordDispatcher)
    end

    assert HttpStub.requests() == []
  end

  defp await_worker_idle(webhook_id, deadline) do
    case Registry.lookup(WorkerSupervisor.registry(), webhook_id) do
      [] ->
        :no_worker

      [{pid, _}] ->
        state = :sys.get_state(pid)

        cond do
          state.current == nil and state.queue_len == 0 ->
            :idle

          System.monotonic_time(:millisecond) >= deadline ->
            :timeout

          true ->
            Process.sleep(25)
            await_worker_idle(webhook_id, deadline)
        end
    end
  end

  defp wait_for_requests(count, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(count, deadline)
  end

  defp do_wait(count, deadline) do
    cond do
      length(HttpStub.requests()) >= count ->
        HttpStub.requests()

      System.monotonic_time(:millisecond) > deadline ->
        flunk("expected #{count} requests, got #{length(HttpStub.requests())}")

      true ->
        Process.sleep(25)
        do_wait(count, deadline)
    end
  end

  test "sends nothing when the global webhook gate is off", %{map: map, system: w} do
    # Covers the gate itself rather than assuming it. This is the failure mode
    # that would otherwise make every test in this file green but meaningless.
    disable_gate()

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  test "delivers a wormhole kill", %{map: map, system: w} do
    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)
    settle(w.id)

    assert [{url, _body}] = wait_for_requests(1)
    assert url == @system_url
  end

  # Seeds the live map cache the guard reads. `:map_cache` is a global Cachex
  # table, NOT sandboxed per test, so every seed must be torn down.
  defp seed_map_systems(map_id, solar_system_ids) do
    systems =
      Map.new(solar_system_ids, fn id -> {id, %{solar_system_id: id}} end)

    WandererApp.Map.update_map(map_id, %{systems: systems})
    on_exit(fn -> Cachex.del(:map_cache, map_id) end)
    :ok
  end

  test "delivers a kill for a system that is on the map", %{map: map, system: w} do
    seed_map_systems(map.id, [@wh_system])

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)
    settle(w.id)

    assert [{url, _body}] = wait_for_requests(1)
    assert url == @system_url
  end

  test "drops a kill for a system absent from a readable map cache", %{map: map, system: w} do
    # Readable, and positively does not contain @wh_system.
    seed_map_systems(map.id, [@ks_system])

    kill = killmail(4001, %{"solar_system_id" => @wh_system})

    event =
      kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [kill]}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)

    # The kill must NOT be marked: it was never attempted, so it stays eligible
    # if the same kill arrives again once the map cache says otherwise.
    refute marked?(map.id, 4001)
  end

  # The fail-open case, and the reason this guard is safe to add at all. A map
  # with no live GenServer has no `:map_cache` entry, and that is not evidence
  # the system was removed.
  test "delivers a kill when the map is not in the cache at all", %{map: map, system: w} do
    Cachex.del(:map_cache, map.id)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)
    settle(w.id)

    assert [{url, _body}] = wait_for_requests(1)
    assert url == @system_url
  end

  test "ignores kill_count events", %{map: map, system: w} do
    event = kill_event(Factory.build(:kill_count_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  # `track/2` with no ids is load-bearing, not decoration: the filters below
  # only apply to a verdict of `:not_involved`, and that requires a tracked set
  # we could actually read. Without the seed the map reads as `:unavailable`,
  # the verdict is `:unknown`, and the kill is deliberately delivered — which
  # would look like the filter is broken when it is the fixture that is.
  test "skips non-wormhole systems when wh_only is set", %{map: map, system: w} do
    track(map.id, [])

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @ks_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  test "delivers known-space kills when wh_only is off", %{map: map, notification: n, system: w} do
    {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
    DiscordDispatcher.invalidate_cache(map.id)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @ks_system}))

    DiscordDispatcher.dispatch_event(map.id, event)
    settle(w.id)

    assert length(wait_for_requests(1)) == 1
  end

  test "skips excluded systems", %{map: map, notification: n, system: w} do
    track(map.id, [])
    {:ok, _} = MapDiscordNotification.update(n, %{excluded_systems: [@wh_system]})
    DiscordDispatcher.invalidate_cache(map.id)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  test "skips when the notification is disabled", %{map: map, notification: n, system: w} do
    {:ok, _} = MapDiscordNotification.update(n, %{enabled?: false})
    DiscordDispatcher.invalidate_cache(map.id)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  # New in Task 4: enablement now lives on BOTH rows. The notification gates the
  # whole map's policy; the webhook gates one destination. A webhook disabled by
  # ten consecutive failures must drop here, before the dedup mark is burned —
  # the worker would drop it too, but only after the kill was marked attempted.
  test "skips when the system webhook is disabled", %{map: map, system: w} do
    {:ok, _} = MapDiscordWebhook.set_enabled(w, %{enabled?: false})
    DiscordDispatcher.invalidate_cache(map.id)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  test "no-ops for a map with no configuration" do
    other_map = Factory.insert(:map, %{})
    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(other_map.id, event)

    refute_delivery(nil)
  end

  # A notification whose webhooks were all destroyed is a no-op, not a crash:
  # `do_dispatch/2` must fall through its `with` rather than raise on an empty
  # webhook list.
  test "no-ops for a notification with no webhooks", %{map: map, system: w} do
    :ok = MapDiscordWebhook.destroy(w)
    DiscordDispatcher.invalidate_cache(map.id)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
    assert Process.alive?(Process.whereis(DiscordDispatcher))
  end

  test "deduplicates a replayed killmail", %{map: map, system: w} do
    kill = Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 777_777})
    payload = Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [kill]})

    DiscordDispatcher.dispatch_event(map.id, kill_event(payload))
    settle(w.id)
    wait_for_requests(1)

    DiscordDispatcher.dispatch_event(map.id, kill_event(payload))
    settle(w.id)

    assert length(HttpStub.requests()) == 1
  end

  test "delivers only the new kills in a partially-replayed batch", %{map: map, system: w} do
    old = Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 111})
    new = Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 222})

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [old]}))
    )

    settle(w.id)
    wait_for_requests(1)

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(
        Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [old, new]})
      )
    )

    settle(w.id)

    assert [{_, _}, {_, second_body}] = wait_for_requests(2)
    assert length(second_body["embeds"]) == 1
  end

  test "ignores non-kill event types", %{map: map, system: w} do
    event = %Event{map_id: map.id, type: :add_system, payload: %{}}

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  # Guards the carry-forward constraint: WorkerSupervisor.deliver/2 answers
  # {:error, :not_running} when the worker tree is down. The dispatcher must
  # neither crash nor treat that as delivered, and — since nothing was enqueued
  # — must release the dedup marks so the kill can still be sent later.
  test "survives the worker tree being down and does not burn the dedup mark", %{
    map: map,
    system: w
  } do
    kill = Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 999_111})
    payload = Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [kill]})

    :ok = stop_supervised(WorkerSupervisor)

    DiscordDispatcher.dispatch_event(map.id, kill_event(payload))
    :sys.get_state(DiscordDispatcher)

    assert HttpStub.requests() == []
    assert Process.alive?(Process.whereis(DiscordDispatcher))

    start_supervised!(WorkerSupervisor)

    DiscordDispatcher.dispatch_event(map.id, kill_event(payload))
    settle(w.id)

    assert length(wait_for_requests(1)) == 1
  end

  # Pins the dedup key as PER-MAP. Deleting `map_id` from `dedup_key/2` makes
  # every other test still pass, while the second map would silently stop
  # receiving any kill the first one already reported.
  test "dedup is per-map: two maps both receive the same killmail", %{
    map: map_a,
    system: w_a
  } do
    map_b = Factory.insert(:map, %{})
    url_b = "https://discord.com/api/webhooks/456/tok-b"

    {:ok, notification_b} =
      MapDiscordNotification.create(%{map_id: map_b.id, webhook_url: url_b})

    w_b = system_webhook(notification_b)
    DiscordDispatcher.invalidate_cache(map_b.id)

    kill = Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 555_555})
    payload = Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [kill]})

    DiscordDispatcher.dispatch_event(map_a.id, kill_event(payload))
    settle(w_a.id)
    wait_for_requests(1)

    DiscordDispatcher.dispatch_event(map_b.id, kill_event(payload))
    settle(w_b.id)

    requests = wait_for_requests(2)
    assert length(requests) == 2

    # Distinct webhook URLs prove both maps were served, not one map twice.
    urls = requests |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert urls == Enum.sort([@system_url, url_b])
  end

  # Kills past the formatter's per-event cap are never rendered into a message,
  # so they must not be marked attempted — otherwise they are burned for the
  # full dedup TTL without ever being sent.
  test "does not burn kills dropped by the formatter's per-event cap", %{map: map, system: w} do
    cap = EmbedFormatter.max_kills_per_event()

    kills =
      for i <- 1..(cap + 5) do
        Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 600_000 + i})
      end

    overflow = Enum.drop(kills, cap)
    assert length(overflow) == 5

    # The capped event spans several chunks, and the worker deliberately spaces
    # them. Derive how many messages to expect from the formatter itself rather
    # than assuming the first `wait_for_requests/1` catches all of them.
    first_batch_size = length(EmbedFormatter.format_batch(entries(kills), "X"))
    assert first_batch_size > 1

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: kills}))
    )

    settle(w.id)
    first_batch = wait_for_requests(first_batch_size)
    assert length(first_batch) == first_batch_size

    # The overflow kills arrive again on their own: they were never formatted,
    # so they are still eligible and must be delivered now.
    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: overflow}))
    )

    settle(w.id)

    later = wait_for_requests(first_batch_size + 1)
    [{_url, body} | _] = Enum.drop(later, first_batch_size)
    assert length(body["embeds"]) == 5
  end

  describe "voice mentions" do
    test "system-channel kills carry voice mentions in content", %{map: map, system: w} do
      enable_voice_mentions()

      event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
      DiscordDispatcher.dispatch_event(map.id, event)
      settle(w.id)

      assert [{@system_url, body}] = wait_for_requests(1)
      assert body["content"] == "<@111> <@222>"
      refute body["content"] =~ "<@333>", "AFK-channel user must not be pinged"
    end

    test "character-channel kills carry no mentions", %{map: map, notification: n} do
      enable_voice_mentions()
      character_webhook(n)
      track(map.id, [8000])

      event =
        kill_event(
          Factory.build(:kill_event, %{
            solar_system_id: @wh_system,
            killmails: [killmail(800_100, %{"victim_char_id" => 8000})]
          })
        )

      DiscordDispatcher.dispatch_event(map.id, event)

      assert [{@character_url, body}] = wait_for_requests(1)
      refute Map.has_key?(body, "content")
    end

    test "feature disabled leaves messages byte-identical", %{map: map, system: w} do
      # No enable_voice_mentions(): test env has no token/guild id.
      event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
      DiscordDispatcher.dispatch_event(map.id, event)
      settle(w.id)

      assert [{@system_url, body}] = wait_for_requests(1)
      refute Map.has_key?(body, "content")
    end

    # .env.example documents WANDERER_DISCORD_MENTIONS_ENABLED as silencing
    # "role and user pings on kill and route notifications" — it gated only the
    # route path until this was wired, so a fully-configured voice guild still
    # pinged on kills with the incident switch off.
    test "the instance-wide mentions kill switch silences configured voice mentions",
         %{map: map, system: w} do
      enable_voice_mentions()

      original = Application.get_env(:wanderer_app, :external_events, [])

      Application.put_env(
        :wanderer_app,
        :external_events,
        Keyword.put(original, :discord_mentions_enabled, false)
      )

      on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)

      event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
      DiscordDispatcher.dispatch_event(map.id, event)
      settle(w.id)

      assert [{@system_url, body}] = wait_for_requests(1)
      refute Map.has_key?(body, "content")
    end

    test "a raising guild fetch still delivers the kill, without mentions",
         %{map: map, system: w} do
      enable_voice_mentions(fn _guild_id -> raise "cache boom" end)

      event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
      DiscordDispatcher.dispatch_event(map.id, event)
      settle(w.id)

      assert [{@system_url, body}] = wait_for_requests(1)
      refute Map.has_key?(body, "content")
    end

    test "dispatch telemetry carries mention_count when enabled", %{map: map, system: w} do
      enable_voice_mentions()

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "voice-mention-count-#{inspect(ref)}",
        [:wanderer_app, :discord_dispatcher, :dispatched],
        fn _event, measurements, metadata, _config ->
          send(parent, {:dispatched, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("voice-mention-count-#{inspect(ref)}") end)

      event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
      DiscordDispatcher.dispatch_event(map.id, event)
      settle(w.id)
      wait_for_requests(1)

      assert_receive {:dispatched, ^ref, measurements, %{role: :system}}, 2_000
      assert measurements.mention_count == 2
    end

    test "multi-chunk event: mentions on the first chunk only, overflow line intact",
         %{map: map, system: w} do
      enable_voice_mentions()

      # 31 kills: 30 rendered, 1 overflow. NEVER hard-code the request count —
      # chunking depends on embed sizes, so derive it from the formatter, the
      # same way "does not burn kills dropped by the formatter's per-event cap"
      # does.
      kills = Enum.map(1..31, fn i -> killmail(20_000 + i) end)
      expected_count = length(EmbedFormatter.format_batch(entries(kills), "J115405"))
      assert expected_count > 1, "fixture must produce a multi-chunk event"

      event =
        kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: kills}))

      DiscordDispatcher.dispatch_event(map.id, event)
      settle(w.id)

      requests = wait_for_requests(expected_count)
      bodies = Enum.map(requests, fn {_url, body} -> body end)

      assert hd(bodies)["content"] == "<@111> <@222>"

      assert List.last(bodies)["content"] == "…and 1 more kills not shown.",
             "overflow line must not be disturbed by mention injection"

      for body <- bodies |> tl() |> Enum.drop(-1) do
        refute Map.has_key?(body, "content")
      end
    end

    test "enabled but nobody in voice: no content, telemetry mention_count 0",
         %{map: map, system: w} do
      enable_voice_mentions(fn 999 ->
        %{id: 999, afk_channel_id: nil, channels: %{}, voice_states: []}
      end)

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "voice-empty-#{inspect(ref)}",
        [:wanderer_app, :discord_dispatcher, :dispatched],
        fn _event, measurements, metadata, _config ->
          send(parent, {:dispatched, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("voice-empty-#{inspect(ref)}") end)

      event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
      DiscordDispatcher.dispatch_event(map.id, event)
      settle(w.id)

      assert [{@system_url, body}] = wait_for_requests(1)
      refute Map.has_key?(body, "content")

      assert_receive {:dispatched, ^ref, measurements, %{role: :system}}, 2_000
      assert measurements.mention_count == 0
    end

    test "disabled: dispatch telemetry carries no mention_count key", %{map: map, system: w} do
      # No enable_voice_mentions(): absent measurement is the "feature off"
      # signal, distinct from mention_count 0 ("enabled but nobody taggable").
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "voice-absent-#{inspect(ref)}",
        [:wanderer_app, :discord_dispatcher, :dispatched],
        fn _event, measurements, metadata, _config ->
          send(parent, {:dispatched, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("voice-absent-#{inspect(ref)}") end)

      event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
      DiscordDispatcher.dispatch_event(map.id, event)
      settle(w.id)
      wait_for_requests(1)

      assert_receive {:dispatched, ^ref, measurements, %{role: :system}}, 2_000
      refute Map.has_key?(measurements, :mention_count)
    end
  end

  describe "per-destination routing" do
    # The core assertion: one batch, three fates.
    test "a mixed batch splits across destinations and drops the rest", %{
      map: map,
      notification: n,
      system: system_wh
    } do
      character_wh = character_webhook(n)
      track(map.id, [1001])

      {:ok, _} =
        MapDiscordNotification.update(n, %{wh_only: false, excluded_systems: [@ks_system]})

      DiscordDispatcher.invalidate_cache(map.id)

      # Involved (tracked victim) in an EXCLUDED system: the carve-out applies,
      # so it still goes to the character channel.
      involved = killmail(700_001, %{"solar_system_id" => @ks_system, "victim_char_id" => 1001})

      # Uninvolved, allowed system: system channel.
      uninvolved = killmail(700_002, %{"solar_system_id" => @wh_system})

      # Uninvolved, excluded system: dropped.
      dropped = killmail(700_003, %{"solar_system_id" => @ks_system})

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(
          Factory.build(:kill_event, %{
            solar_system_id: @wh_system,
            killmails: [involved, uninvolved, dropped]
          })
        )
      )

      settle(system_wh.id)
      settle(character_wh.id)

      requests = wait_for_requests(2)
      by_url = Enum.group_by(requests, &elem(&1, 0), &elem(&1, 1))

      assert [system_body] = by_url[@system_url]
      assert [character_body] = by_url[@character_url]

      assert length(system_body["embeds"]) == 1
      assert length(character_body["embeds"]) == 1

      # Exactly two messages: the third kill went nowhere. This is a negative
      # assertion, so `settle/1` alone is not enough — a third request could
      # still be in flight in an async task. Wait until BOTH workers are
      # genuinely idle, or the count passes for the wrong reason.
      deadline = System.monotonic_time(:millisecond) + 2_000
      assert await_worker_idle(system_wh.id, deadline) in [:idle, :no_worker]
      assert await_worker_idle(character_wh.id, deadline) in [:idle, :no_worker]

      assert length(HttpStub.requests()) == 2
    end

    # End-to-end proof of the corporation filter's REPLACEMENT semantic, which
    # only shows up when all three pieces (Matcher, Router, dispatcher) agree.
    # One batch, three kills, three different answers:
    #
    #   * a filtered corporation in an EXCLUDED system  -> character channel
    #     (the carve-out follows the filter, not the tracked characters)
    #   * a TRACKED character in an allowed system      -> system channel
    #     (the filter took them out of the character channel)
    #   * a TRACKED character in an EXCLUDED system     -> dropped
    #     (no carve-out either, for the same reason)
    #
    # If the filter ever reverts to widening the tracked set, the last two land
    # in the character channel and this test fails on both counts.
    test "a corporation filter replaces tracked characters for character routing", %{
      map: map,
      notification: n,
      system: system_wh
    } do
      character_wh = character_webhook(n)
      track(map.id, [1001])

      {:ok, _} =
        MapDiscordNotification.update(n, %{
          wh_only: false,
          excluded_systems: [@ks_system],
          focus_corp_ids: [500_001]
        })

      DiscordDispatcher.invalidate_cache(map.id)

      filtered_corp =
        killmail(710_001, %{"solar_system_id" => @ks_system, "victim_corp_id" => 500_001})

      tracked_char =
        killmail(710_002, %{"solar_system_id" => @wh_system, "victim_char_id" => 1001})

      tracked_char_excluded =
        killmail(710_003, %{"solar_system_id" => @ks_system, "victim_char_id" => 1001})

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(
          Factory.build(:kill_event, %{
            solar_system_id: @wh_system,
            killmails: [filtered_corp, tracked_char, tracked_char_excluded]
          })
        )
      )

      settle(system_wh.id)
      settle(character_wh.id)

      requests = wait_for_requests(2)
      by_url = Enum.group_by(requests, &elem(&1, 0), &elem(&1, 1))

      assert [character_body] = by_url[@character_url]
      assert [%{"footer" => %{"text" => "Killmail ID: 710001"}}] = character_body["embeds"]

      assert [system_body] = by_url[@system_url]
      assert [%{"footer" => %{"text" => "Killmail ID: 710002"}}] = system_body["embeds"]

      deadline = System.monotonic_time(:millisecond) + 2_000
      assert await_worker_idle(system_wh.id, deadline) in [:idle, :no_worker]
      assert await_worker_idle(character_wh.id, deadline) in [:idle, :no_worker]

      assert length(HttpStub.requests()) == 2
    end

    # The exact bug the whole-partition rule prevents. If `deliver_to/5` passed
    # the pre-truncated list to `format_batch/2`, the overflow line disappears
    # and this fails with `contents == []`.
    test "the overflow line counts kills beyond the per-destination cap", %{
      map: map,
      notification: n,
      system: system_wh
    } do
      {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
      DiscordDispatcher.invalidate_cache(map.id)
      track(map.id, [])

      cap = EmbedFormatter.max_kills_per_event()
      kills = for i <- 1..(cap + 5), do: killmail(710_000 + i)

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: kills}))
      )

      settle(system_wh.id)

      expected = length(EmbedFormatter.format_batch(entries(kills), "X"))
      requests = wait_for_requests(expected)

      contents =
        requests |> Enum.map(fn {_url, body} -> body["content"] end) |> Enum.reject(&is_nil/1)

      assert ["…and 5 more kills not shown."] == contents
    end

    test "two destinations each get their own cap budget", %{
      map: map,
      notification: n,
      system: system_wh
    } do
      character_wh = character_webhook(n)
      track(map.id, [1001])

      {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
      DiscordDispatcher.invalidate_cache(map.id)

      cap = EmbedFormatter.max_kills_per_event()

      system_kills = for i <- 1..(cap + 5), do: killmail(720_000 + i)

      character_kills =
        for i <- 1..(cap + 5), do: killmail(730_000 + i, %{"victim_char_id" => 1001})

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(
          Factory.build(:kill_event, %{
            solar_system_id: @wh_system,
            killmails: system_kills ++ character_kills
          })
        )
      )

      settle(system_wh.id)
      settle(character_wh.id)

      per_destination = length(EmbedFormatter.format_batch(entries(system_kills), "X"))
      requests = wait_for_requests(per_destination * 2)
      by_url = Enum.group_by(requests, &elem(&1, 0), &elem(&1, 1))

      system_bodies = by_url[@system_url]
      character_bodies = by_url[@character_url]

      # Each destination renders a FULL cap of kills. A shared budget would give
      # one of them 30 and the other 0.
      assert Enum.sum(Enum.map(system_bodies, &length(&1["embeds"]))) == cap
      assert Enum.sum(Enum.map(character_bodies, &length(&1["embeds"]))) == cap

      # And each counts only its own overflow.
      assert Enum.any?(system_bodies, &(&1["content"] == "…and 5 more kills not shown."))
      assert Enum.any?(character_bodies, &(&1["content"] == "…and 5 more kills not shown."))
    end

    # A kill the router drops belongs to no partition, so it is never marked. If
    # it becomes routable later — the user removes the exclusion, or one of their
    # pilots turns up in it — it must still be deliverable.
    test "kills dropped by the router are not marked attempted", %{
      map: map,
      notification: n,
      system: system_wh
    } do
      # Bind the updated record: Ash diffs against the struct it is given, so a
      # second update from the stale `n` would see `excluded_systems` already
      # `[]` and change nothing.
      {:ok, excluded} =
        MapDiscordNotification.update(n, %{wh_only: false, excluded_systems: [@ks_system]})

      DiscordDispatcher.invalidate_cache(map.id)
      track(map.id, [])

      kill = killmail(740_001, %{"solar_system_id" => @ks_system})

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(Factory.build(:kill_event, %{solar_system_id: @ks_system, killmails: [kill]}))
      )

      refute_delivery(system_wh.id)

      # Lift the exclusion; the same killmail must now be delivered.
      {:ok, _} = MapDiscordNotification.update(excluded, %{excluded_systems: []})
      DiscordDispatcher.invalidate_cache(map.id)

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(Factory.build(:kill_event, %{solar_system_id: @ks_system, killmails: [kill]}))
      )

      settle(system_wh.id)

      assert [{_url, body}] = wait_for_requests(1)
      assert length(body["embeds"]) == 1
    end

    # DROP, NOT REROUTE. The Router unit test covers the decision; this covers
    # the wiring end to end, because a reroute would show up here as a message
    # on the system URL.
    test "a disabled character webhook drops rather than rerouting", %{
      map: map,
      notification: n,
      system: system_wh
    } do
      character_wh = character_webhook(n)
      {:ok, _} = MapDiscordWebhook.set_enabled(character_wh, %{enabled?: false})

      {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
      DiscordDispatcher.invalidate_cache(map.id)
      track(map.id, [1001])

      involved = killmail(750_001, %{"victim_char_id" => 1001})

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(
          Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [involved]})
        )
      )

      # Nothing anywhere — in particular, nothing on the system webhook.
      refute_delivery(system_wh.id)
    end

    # The mirror image, with BOTH roles configured: a disabled `:system`
    # destination must not spill its uninvolved kills into the character
    # channel.
    test "a disabled system webhook does not fall back to the character webhook", %{
      map: map,
      notification: n,
      system: system_wh
    } do
      character_wh = character_webhook(n)
      {:ok, _} = MapDiscordWebhook.set_enabled(system_wh, %{enabled?: false})

      {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
      DiscordDispatcher.invalidate_cache(map.id)
      track(map.id, [1001])

      uninvolved = killmail(755_001, %{"victim_char_id" => 4242})

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(
          Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [uninvolved]})
        )
      )

      refute_delivery(character_wh.id)
    end

    # Partition results are independent. Stopping the worker tree makes BOTH
    # partitions report `:not_running`, so both sets of marks must be released
    # and both kills must still be deliverable on the replay.
    test "not_running releases the marks of every failing partition", %{
      map: map,
      notification: n,
      system: system_wh
    } do
      character_wh = character_webhook(n)
      {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
      DiscordDispatcher.invalidate_cache(map.id)
      track(map.id, [1001])

      system_kill = killmail(760_001)
      character_kill = killmail(760_002, %{"victim_char_id" => 1001})

      :ok = stop_supervised(WorkerSupervisor)

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(
          Factory.build(:kill_event, %{
            solar_system_id: @wh_system,
            killmails: [system_kill, character_kill]
          })
        )
      )

      :sys.get_state(DiscordDispatcher)
      assert HttpStub.requests() == []
      assert Process.alive?(Process.whereis(DiscordDispatcher))

      start_supervised!(WorkerSupervisor)

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(
          Factory.build(:kill_event, %{
            solar_system_id: @wh_system,
            killmails: [system_kill, character_kill]
          })
        )
      )

      settle(system_wh.id)
      settle(character_wh.id)

      requests = wait_for_requests(2)
      by_url = Enum.group_by(requests, &elem(&1, 0), &elem(&1, 1))

      assert [system_body] = by_url[@system_url]
      assert [character_body] = by_url[@character_url]
      assert length(system_body["embeds"]) == 1
      assert length(character_body["embeds"]) == 1
    end

    test "telemetry is emitted per destination with the role", %{
      map: map,
      notification: n,
      system: system_wh
    } do
      character_wh = character_webhook(n)
      {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
      DiscordDispatcher.invalidate_cache(map.id)
      track(map.id, [1001])

      test_pid = self()
      handler_id = "discord-role-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:wanderer_app, :discord_dispatcher, :dispatched],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:dispatched, metadata[:role], measurements[:count]})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(
          Factory.build(:kill_event, %{
            solar_system_id: @wh_system,
            killmails: [killmail(770_001), killmail(770_002, %{"victim_char_id" => 1001})]
          })
        )
      )

      settle(system_wh.id)
      settle(character_wh.id)

      assert_receive {:dispatched, :system, 1}
      assert_receive {:dispatched, :character, 1}
    end

    # The privacy boundary, end to end. The map-local name is visible on the
    # system channel and MUST NOT appear on the character channel, which is
    # commonly public. A caller passing `:system` where it meant `:character`
    # is the leak path `SystemName` cannot defend against on its own.
    test "map-local system names reach the system channel only", %{
      map: map,
      notification: n,
      system: system_wh
    } do
      character_wh = character_webhook(n)

      {:ok, _} =
        WandererApp.Api.MapSystem.create(%{
          map_id: map.id,
          solar_system_id: @wh_system,
          name: "J115405",
          temporary_name: "HOME",
          position_x: 0,
          position_y: 0
        })

      {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
      DiscordDispatcher.invalidate_cache(map.id)
      track(map.id, [1001])

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(
          Factory.build(:kill_event, %{
            solar_system_id: @wh_system,
            killmails: [killmail(780_001), killmail(780_002, %{"victim_char_id" => 1001})]
          })
        )
      )

      settle(system_wh.id)
      settle(character_wh.id)

      by_url = wait_for_requests(2) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      assert [system_body] = by_url[@system_url]
      assert [character_body] = by_url[@character_url]

      assert hd(system_body["embeds"])["title"] =~ "HOME"
      refute hd(character_body["embeds"])["title"] =~ "HOME"
      assert hd(character_body["embeds"])["title"] =~ "J115405"
    end
  end

  test "send_test_message reports the global gate being off", %{system: w} do
    disable_gate()

    assert {:error, :notifications_disabled} = DiscordDispatcher.send_test_message(w.id)
    assert HttpStub.requests() == []
  end

  test "send_test_message goes through the worker", %{system: w} do
    assert :ok = DiscordDispatcher.send_test_message(w.id)

    assert [{url, body}] = wait_for_requests(1)
    assert url == @system_url
    assert body["content"] =~ "test message"
  end

  # `send_test_message/1` answers with THREE distinct atoms where it used to
  # answer `:not_configured` for all of them. These four tests exist to keep
  # them distinct: collapsing any one branch into another turns at least one of
  # them red, which a single "some error came back" assertion would not.
  test "send_test_message distinguishes an unknown webhook" do
    assert {:error, :webhook_not_found} =
             DiscordDispatcher.send_test_message(Ash.UUID.generate())
  end

  test "send_test_message distinguishes a saved but disabled webhook", %{system: w} do
    {:ok, _} = MapDiscordWebhook.set_enabled(w, %{enabled?: false})

    assert {:error, :webhook_disabled} = DiscordDispatcher.send_test_message(w.id)
    assert HttpStub.requests() == []
  end

  test "send_test_message distinguishes a row that decrypts to no URL", %{system: w} do
    blank_the_url!(w.id)

    assert {:error, :webhook_url_missing} = DiscordDispatcher.send_test_message(w.id)
    assert HttpStub.requests() == []
  end

  # Clause order, pinned: "disabled" wins over "no URL". This is what the
  # component used to decide for itself by checking its own assigns, and the
  # copy a user sees depends on it — swap the two clauses and this goes red
  # while the three tests above stay green.
  test "send_test_message reports a disabled URL-less webhook as disabled", %{system: w} do
    blank_the_url!(w.id)
    {:ok, _} = MapDiscordWebhook.set_enabled(w, %{enabled?: false})

    assert {:error, :webhook_disabled} = DiscordDispatcher.send_test_message(w.id)
  end

  # `webhook_url` is `allow_nil? false` and validated on write, so a URL-less row
  # cannot be created through Ash. It is still reachable in production through a
  # hand-repaired row or a half-finished migration, so build it the only way the
  # storage format allows: AshCloak stores `Base.encode64(encrypt(term_to_binary(value)))`,
  # so encrypting `nil` yields a row that reads back with `webhook_url: nil`.
  defp blank_the_url!(webhook_id) do
    {:ok, ciphertext} = WandererApp.Vault.encrypt(:erlang.term_to_binary(nil))

    {:ok, _} =
      WandererApp.Repo.query(
        "update map_discord_webhooks_v1 set encrypted_webhook_url = $1 where id = $2",
        [Base.encode64(ciphertext), Ecto.UUID.dump!(webhook_id)]
      )

    # Fail loudly here rather than letting the caller's assertion pass for the
    # wrong reason if the storage format ever changes.
    {:ok, reread} = MapDiscordWebhook.by_id(webhook_id)
    assert is_nil(reread.webhook_url)
    :ok
  end

  describe "maximum killmail age" do
    setup do
      original = Application.get_env(:wanderer_app, :external_events, [])

      Application.put_env(
        :wanderer_app,
        :external_events,
        Keyword.put(original, :discord_max_killmail_age_seconds, 3600)
      )

      on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
      :ok
    end

    test "a stale killmail is not delivered", %{map: map, system: w} do
      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

      DiscordDispatcher.dispatch_event(map.id, kill_event(@wh_system, [kill(9_001, stale)]))

      refute_delivery(w.id)
    end

    # The full round trip, now that the dispatcher formats and delivers again:
    # the stale kill leaves no dedup mark, so the SAME killmail arriving later
    # with a fresh timestamp is still delivered. This is the guard's actual job
    # — suppress the replay, not the killmail.
    test "a stale killmail is not marked, so a later fresh arrival still delivers",
         %{map: map, system: w} do
      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

      DiscordDispatcher.dispatch_event(map.id, kill_event(@wh_system, [kill(9_002, stale)]))

      refute_delivery(w.id)
      refute marked?(map.id, 9002)

      fresh = DateTime.utc_now() |> DateTime.to_iso8601()
      DiscordDispatcher.dispatch_event(map.id, kill_event(@wh_system, [kill(9_002, fresh)]))

      settle(w.id)

      assert [{_url, body}] = wait_for_requests(1)
      assert length(body["embeds"]) == 1
      assert hd(body["embeds"])["footer"]["text"] == "Killmail ID: 9002"
    end

    # A mixed batch is where dropping the `kill_fresh?/3` call site is most
    # easily missed: the fresh kill delivers either way, so the assertion that
    # bites is the embed COUNT and the id it carries.
    test "a mixed batch delivers only the fresh kill", %{map: map, system: w} do
      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()
      recent = DateTime.utc_now() |> DateTime.to_iso8601()

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(@wh_system, [kill(9_003, stale), kill(9_004, recent)])
      )

      settle(w.id)

      assert [{_url, body}] = wait_for_requests(1)
      assert length(body["embeds"]) == 1
      assert hd(body["embeds"])["footer"]["text"] == "Killmail ID: 9004"

      # And the stale one was never burned, unlike the delivered one.
      assert marked?(map.id, 9004)
      refute marked?(map.id, 9003)
    end

    # The guard must run ONCE, upstream of partitioning — never inside a
    # per-destination loop, and never after `mark_attempted/2`. With both roles
    # configured, the stale kill in EACH partition must be filtered out and left
    # unmarked while that partition's fresh kill still goes out.
    test "the age guard runs before marking in every partition", %{
      map: map,
      notification: n,
      system: system_wh
    } do
      character_wh = character_webhook(n)
      DiscordDispatcher.invalidate_cache(map.id)
      track(map.id, [1001])

      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()
      recent = DateTime.utc_now() |> DateTime.to_iso8601()

      kills = [
        killmail(9_201, %{"kill_time" => stale}),
        killmail(9_202, %{"kill_time" => recent}),
        killmail(9_203, %{"kill_time" => stale, "victim_char_id" => 1001}),
        killmail(9_204, %{"kill_time" => recent, "victim_char_id" => 1001})
      ]

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: kills}))
      )

      settle(system_wh.id)
      settle(character_wh.id)

      by_url = wait_for_requests(2) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      assert [system_body] = by_url[@system_url]
      assert [character_body] = by_url[@character_url]
      assert length(system_body["embeds"]) == 1
      assert length(character_body["embeds"]) == 1
      assert hd(system_body["embeds"])["footer"]["text"] == "Killmail ID: 9202"
      assert hd(character_body["embeds"])["footer"]["text"] == "Killmail ID: 9204"

      refute marked?(map.id, 9201)
      refute marked?(map.id, 9203)
    end

    # Pins the fix for the exact regression the reviewer caught: `kill_fresh?/3`
    # takes `max_age_seconds` as an argument rather than calling
    # `Env.discord_max_killmail_age_seconds/0` internally, so `do_dispatch/2`
    # resolves (and, on a misconfigured value, warns) ONCE per batch — not once
    # per kill. Before that fix this test fails with 3 warnings, one per kill.
    #
    # All three kills are stale regardless of whether `0` or its validated
    # fallback (3600) ends up in effect, so the whole batch is filtered before
    # partitioning and nothing is formatted or delivered.
    test "a misconfigured max age warns once per batch, not once per kill", %{map: map} do
      original = Application.get_env(:wanderer_app, :external_events, [])

      Application.put_env(
        :wanderer_app,
        :external_events,
        Keyword.put(original, :discord_max_killmail_age_seconds, 0)
      )

      on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)

      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

      kills = [kill(9_101, stale), kill(9_102, stale), kill(9_103, stale)]

      log =
        capture_log(fn ->
          DiscordDispatcher.dispatch_event(map.id, kill_event(@wh_system, kills))
          :sys.get_state(DiscordDispatcher)
        end)

      warning_count =
        log
        |> String.split("\n")
        |> Enum.count(&(&1 =~ "discord_max_killmail_age_seconds"))

      assert warning_count == 1
    end
  end

  describe "notable items" do
    setup do
      Process.register(self(), :notable_items_observer)
      Cachex.del(:api_cache, @failure_key)

      Application.put_env(:wanderer_app, :notable_items_enricher, Enricher)
      Application.put_env(:wanderer_app, :test_notable_items_mode, %{})

      on_exit(fn ->
        Application.delete_env(:wanderer_app, :notable_items_enricher)
        Application.delete_env(:wanderer_app, :test_notable_items_mode)
        Cachex.del(:api_cache, @failure_key)
      end)

      :ok
    end

    test "does not enrich when the feature is disabled", %{map: map, system: w} do
      # No `enable_notable_items/1` — the default is off, which is the shipping
      # configuration. This test is what makes "off means zero added latency"
      # an assertion rather than a claim.
      dispatch(map, [fresh_kill(9_201)])
      settle(w.id)

      refute_received {:enrich_called, _}
      assert [{_url, body}] = wait_for_requests(1)
      refute description(body) =~ "Notable Items"
    end

    test "renders the section for an enriched kill", %{map: map, system: w} do
      enable_notable_items()
      returns(%{9_202 => [notable("Damage Control II", 1, 100_000_000.0)]})

      dispatch(map, [fresh_kill(9_202)])
      settle(w.id)

      assert [{_url, body}] = wait_for_requests(1)
      assert description(body) =~ "**Notable Items:**"
      assert description(body) =~ "• Damage Control II (~100.0M ISK)"
    end

    test "leaves un-enriched kills in the same batch alone", %{map: map, system: w} do
      enable_notable_items()
      returns(%{9_203 => [notable("Damage Control II", 1, 100_000_000.0)]})

      dispatch(map, [fresh_kill(9_203), fresh_kill(9_204)])
      settle(w.id)

      assert [{_url, body}] = wait_for_requests(1)
      assert [enriched, plain] = body["embeds"]
      assert enriched["description"] =~ "Notable Items"
      refute plain["description"] =~ "Notable Items"
    end

    test "only offers kills that will actually be rendered", %{map: map, system: w} do
      # The cap is per destination and applied by the formatter. Enriching past
      # it spends ESI and market calls on kills nobody will ever see.
      enable_notable_items()
      over_cap = EmbedFormatter.max_kills_per_event() + 5
      kills = for id <- 1..over_cap, do: fresh_kill(9_300 + id)

      dispatch(map, kills)
      settle(w.id)

      assert_received {:enrich_called, candidates}
      assert length(candidates) == EmbedFormatter.max_kills_per_event()
    end

    test "delivers without the section when the enricher times out", %{map: map, system: w} do
      enable_notable_items(notable_items_timeout_ms: 50)
      returns(:timeout)

      dispatch(map, [fresh_kill(9_205)])
      settle(w.id)

      assert [{_url, body}] = wait_for_requests(1)
      refute description(body) =~ "Notable Items"
    end

    test "delivers without the section when the enricher crashes", %{map: map, system: w} do
      # The crash must not reach the dispatcher: `async_nolink` plus the
      # `{:exit, reason}` branch of `Task.yield/2`. If this ever regresses the
      # singleton dies and every map stops receiving kill notifications.
      enable_notable_items()
      returns(:crash)

      capture_log(fn -> dispatch(map, [fresh_kill(9_206)]) end)

      assert Process.alive?(Process.whereis(DiscordDispatcher))
      assert [{_url, body}] = wait_for_requests(1)
      refute description(body) =~ "Notable Items"
    end

    test "stops enriching after repeated failures", %{map: map, system: w} do
      enable_notable_items()
      returns(:crash)

      capture_log(fn ->
        for id <- 1..3 do
          dispatch(map, [fresh_kill(9_400 + id)])
          assert_received {:enrich_called, _}
        end
      end)

      # Threshold reached: the fourth batch skips enrichment outright rather
      # than paying the budget again during a sustained outage.
      dispatch(map, [fresh_kill(9_410)])
      refute_received {:enrich_called, _}

      settle(w.id)
      assert length(wait_for_requests(4)) == 4
    end

    test "a success clears the failure counter", %{map: map, system: w} do
      enable_notable_items()
      returns(:crash)

      capture_log(fn ->
        for id <- 1..2 do
          dispatch(map, [fresh_kill(9_500 + id)])
          assert_received {:enrich_called, _}
        end
      end)

      returns(%{})
      dispatch(map, [fresh_kill(9_510)])
      assert_received {:enrich_called, _}

      # Without the reset, two more failures would trip the cooldown.
      returns(:crash)

      capture_log(fn ->
        for id <- 1..2 do
          dispatch(map, [fresh_kill(9_520 + id)])
          assert_received {:enrich_called, _}
        end
      end)

      settle(w.id)
    end

    test "emits telemetry for each outcome", %{map: map, system: w} do
      handler = "notable-items-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:wanderer_app, :discord, :notable_items],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      dispatch(map, [fresh_kill(9_601)])
      assert_received {:telemetry, _, %{outcome: :disabled}}

      enable_notable_items()
      returns(%{9_602 => [notable("Damage Control II", 1, 100_000_000.0)]})
      dispatch(map, [fresh_kill(9_602)])

      assert_received {:telemetry, measurements, %{outcome: :ok}}
      assert measurements.kill_count == 1
      assert measurements.item_count == 1

      settle(w.id)
    end
  end

  describe "corporation tickers" do
    setup do
      Process.register(self(), :corp_tickers_observer)
      Cachex.del(:api_cache, @ticker_failure_key)

      Application.put_env(:wanderer_app, :corp_tickers_enricher, TickerEnricher)
      Application.put_env(:wanderer_app, :test_corp_tickers_mode, %{})

      on_exit(fn ->
        Application.delete_env(:wanderer_app, :corp_tickers_enricher)
        Application.delete_env(:wanderer_app, :test_corp_tickers_mode)
        Cachex.del(:api_cache, @ticker_failure_key)
      end)

      :ok
    end

    test "renders the corporation a payload arrived without", %{map: map, system: w} do
      # The reported bug: the ticker is absent, so the embed used to drop the
      # whole parenthetical and read as though the pilot had no corporation.
      returns_tickers(%{"98721938" => ".STEX"})

      dispatch(map, [corp_kill(9_701, victim_corp_id: 98_721_938)])
      settle(w.id)

      assert [{_url, body}] = wait_for_requests(1)
      assert description(body) =~ "(**[.STEX](https://zkillboard.com/corporation/98721938/)**)"
    end

    test "resolves the final blow's corporation too", %{map: map, system: w} do
      returns_tickers(%{"98832599" => "SKRPR"})

      kill =
        corp_kill(9_702,
          final_blow_corp_id: 98_832_599,
          extra: %{"final_blow_char_name" => "MiniNinja37"}
        )

      dispatch(map, [kill])
      settle(w.id)

      assert [{_url, body}] = wait_for_requests(1)
      assert description(body) =~ "to **MiniNinja37** (**[SKRPR]"
    end

    test "does not run at all when the payload already carried the tickers",
         %{map: map, system: w} do
      kill =
        corp_kill(9_703,
          victim_corp_id: 98_721_938,
          extra: %{"victim_corp_ticker" => "PAYLOAD"}
        )

      dispatch(map, [kill])
      settle(w.id)

      refute_received {:tickers_called, _}
      assert [{_url, body}] = wait_for_requests(1)
      assert description(body) =~ "(**[PAYLOAD]"
    end

    test "does not run when no kill carries a corporation id", %{map: map, system: w} do
      dispatch(map, [fresh_kill(9_704)])
      settle(w.id)

      refute_received {:tickers_called, _}
      assert [{_url, _body}] = wait_for_requests(1)
    end

    test "delivers without the corporation when the enricher times out",
         %{map: map, system: w} do
      corp_tickers_timeout(50)
      returns_tickers(:timeout)

      dispatch(map, [corp_kill(9_705, victim_corp_id: 98_721_938)])
      settle(w.id)

      assert [{_url, body}] = wait_for_requests(1)
      assert description(body) =~ "lost their **Rifter**"
      refute description(body) =~ "zkillboard.com/corporation"
    end

    test "delivers, and survives, when the enricher crashes", %{map: map} do
      returns_tickers(:crash)

      capture_log(fn -> dispatch(map, [corp_kill(9_706, victim_corp_id: 98_721_938)]) end)

      assert Process.alive?(Process.whereis(DiscordDispatcher))
      assert [{_url, body}] = wait_for_requests(1)
      refute description(body) =~ "zkillboard.com/corporation"
    end

    test "stops resolving after repeated failures", %{map: map, system: w} do
      returns_tickers(:crash)

      capture_log(fn ->
        for id <- 1..3 do
          dispatch(map, [corp_kill(9_710 + id, victim_corp_id: 98_721_938)])
          assert_received {:tickers_called, _}
        end
      end)

      dispatch(map, [corp_kill(9_720, victim_corp_id: 98_721_938)])
      refute_received {:tickers_called, _}

      settle(w.id)
      assert length(wait_for_requests(4)) == 4
    end

    test "warns only when most of the batch went unresolved", %{map: map, system: w} do
      # Three corporations owed across the batch. One permanently ticker-less
      # corporation among them must not warn — otherwise every batch carrying
      # that kill logs a fixed data condition as if it were ESI degradation.
      batch = [
        corp_kill(9_770,
          victim_corp_id: 98_721_938,
          final_blow_corp_id: 98_832_599,
          extra: %{"final_blow_char_name" => "MiniNinja37"}
        ),
        corp_kill(9_771, victim_corp_id: 98_900_001)
      ]

      returns_tickers(%{"98721938" => ".STEX", "98832599" => "SKRPR"})
      quiet = capture_log(fn -> dispatch(map, batch) end)
      refute quiet =~ "corp tickers resolved"

      # Two of three missing is degradation, and does warn.
      returns_tickers(%{"98721938" => ".STEX"})

      noisy =
        capture_log(fn ->
          dispatch(map, [
            corp_kill(9_772,
              victim_corp_id: 98_721_938,
              final_blow_corp_id: 98_832_599,
              extra: %{"final_blow_char_name" => "MiniNinja37"}
            ),
            corp_kill(9_773, victim_corp_id: 98_900_001)
          ])
        end)

      assert noisy =~ "corp tickers resolved 1 of 3 corporations"

      # One message per dispatched batch — both kills render into it.
      settle(w.id)
      assert length(wait_for_requests(2)) == 2
    end

    test "does not resolve at all when the incident switch is off", %{map: map, system: w} do
      original = Application.get_env(:wanderer_app, :external_events, [])

      Application.put_env(
        :wanderer_app,
        :external_events,
        Keyword.put(original, :corp_tickers_enabled, false)
      )

      on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)

      returns_tickers(%{"98721938" => ".STEX"})

      dispatch(map, [corp_kill(9_760, victim_corp_id: 98_721_938)])
      refute_received {:tickers_called, _}

      settle(w.id)
      assert [{_url, body}] = wait_for_requests(1)
      refute description(body) =~ "zkillboard.com/corporation"
    end

    test "counts a batch that resolved nothing as a failure, not a healthy no-op",
         %{map: map, system: w} do
      # Every id was asked for because its ticker was missing, so resolving none
      # of them means ESI answered nothing — an outage wearing the shape of the
      # original bug. It has to trip the cooldown rather than reset it, or we
      # keep paying the round trip on every batch for the length of the outage.
      returns_tickers(%{})

      log =
        capture_log(fn ->
          for id <- 1..3 do
            dispatch(map, [corp_kill(9_740 + id, victim_corp_id: 98_721_938)])
            assert_received {:tickers_called, _}
          end
        end)

      assert log =~ "resolved none of 1 corporations"

      dispatch(map, [corp_kill(9_750, victim_corp_id: 98_721_938)])
      refute_received {:tickers_called, _}

      settle(w.id)
      assert length(wait_for_requests(4)) == 4
    end

    test "emits telemetry carrying how much was owed and resolved",
         %{map: map, system: w} do
      handler = "corp-tickers-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:wanderer_app, :discord, :corp_tickers],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      returns_tickers(%{"98721938" => ".STEX"})
      dispatch(map, [corp_kill(9_730, victim_corp_id: 98_721_938)])

      assert_received {:telemetry, measurements, %{outcome: :ok}}
      assert measurements.corp_count == 1
      assert measurements.resolved_count == 1

      settle(w.id)
    end
  end

  describe "route alert dispatch" do
    setup %{map: map, notification: notification} do
      Application.put_env(
        :wanderer_app,
        :route_watcher_supervisor,
        WandererApp.ExternalEvents.DiscordDispatcherTest.RouteWatcherObserver
      )

      on_exit(fn -> Application.delete_env(:wanderer_app, :route_watcher_supervisor) end)

      Process.register(self(), :route_watcher_observer)

      # `on_exit/1` runs from a separate runner process, after the test
      # process (registered above) has already terminated — the VM
      # auto-deregisters a name when its owning process dies, so by the time
      # this callback fires the name is normally already gone. Guard instead
      # of unconditionally unregistering, or every test in this describe
      # block raises `ArgumentError` on exit.
      on_exit(fn ->
        if Process.whereis(:route_watcher_observer),
          do: Process.unregister(:route_watcher_observer)
      end)

      {:ok, notification} =
        MapDiscordNotification.update(notification, %{
          route_alerts_enabled?: true,
          home_system_id: 30_000_001
        })

      DiscordDispatcher.invalidate_cache(map.id)
      %{notification: notification}
    end

    # Removals are in this list too: without a notify on removal the watcher's
    # state stays {:qualifying, N} forever, so a route that closes and later
    # re-opens at the same or a worse jump count is never announced.
    for type <- [
          :add_system,
          :connection_added,
          :connection_updated,
          :connection_removed,
          :deleted_system
        ] do
      test "#{type} notifies the route watcher", %{map: map} do
        event = Event.new(map.id, unquote(type), %{})
        DiscordDispatcher.dispatch_event(map.id, event)

        assert_receive {:route_notify, map_id}, 500
        assert map_id == map.id
      end
    end

    test "no notify when webhooks are globally disabled", %{map: map} do
      original = Application.get_env(:wanderer_app, :external_events, [])

      Application.put_env(
        :wanderer_app,
        :external_events,
        Keyword.put(original, :webhooks_enabled, false)
      )

      on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)

      event = Event.new(map.id, :add_system, %{})
      DiscordDispatcher.dispatch_event(map.id, event)

      refute_receive {:route_notify, _}, 200
    end

    test "no notify when route_alerts_enabled? is false", %{map: map, notification: notification} do
      {:ok, _} = MapDiscordNotification.update(notification, %{route_alerts_enabled?: false})
      DiscordDispatcher.invalidate_cache(map.id)

      event = Event.new(map.id, :add_system, %{})
      DiscordDispatcher.dispatch_event(map.id, event)

      refute_receive {:route_notify, _}, 200
    end

    test "no notify when home_system_id is nil", %{map: map, notification: notification} do
      # Can't reach this state through `MapDiscordNotification.update/2`: Task
      # 3's validation (`map_discord_notification.ex:223-224`) rejects
      # `route_alerts_enabled?: true` with a nil `home_system_id` outright.
      # This clause's own nil-check is defense in depth against a stale cache
      # entry or a row shaped this way before that validation existed, so
      # reach the state directly in the DB, following the same
      # can't-go-through-the-action bypass `blank_the_url!/1` uses above.
      {:ok, _} =
        WandererApp.Repo.query(
          "update map_discord_notifications_v1 set home_system_id = NULL where id = $1",
          [Ecto.UUID.dump!(notification.id)]
        )

      DiscordDispatcher.invalidate_cache(map.id)

      event = Event.new(map.id, :add_system, %{})
      DiscordDispatcher.dispatch_event(map.id, event)

      refute_receive {:route_notify, _}, 200
    end

    test "no notify for a map with no Discord configuration at all" do
      map = Factory.insert(:map, %{})
      event = Event.new(map.id, :add_system, %{})
      DiscordDispatcher.dispatch_event(map.id, event)

      refute_receive {:route_notify, _}, 200
    end

    test "the kill path is unaffected", %{map: map} do
      # Regression guard, not new behaviour: re-run an existing kill-delivery
      # scenario inside this describe block to confirm the new clause
      # (inserted before the catch-all) does not shadow :map_kill.
      DiscordDispatcher.dispatch_event(
        map.id,
        Event.new(map.id, :map_kill, %{
          "type" => :killmail_update,
          "solar_system_id" => @wh_system,
          "killmails" => [killmail(1)]
        })
      )

      assert [_] = wait_for_requests(1)
    end
  end

  # -- corporation ticker helpers ---------------------------------------------

  defp returns_tickers(mode),
    do: Application.put_env(:wanderer_app, :test_corp_tickers_mode, mode)

  defp corp_tickers_timeout(ms) do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, :corp_tickers_timeout_ms, ms)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
  end

  # A kill carrying corporation ids but no tickers — the shape that reaches the
  # dispatcher when upstream has not enriched the killmail.
  defp corp_kill(id, opts) do
    extra = Keyword.get(opts, :extra, %{})

    [victim_corp_id: "victim_corp_id", final_blow_corp_id: "final_blow_corp_id"]
    |> Enum.reduce(fresh_kill(id), fn {opt, key}, kill ->
      case Keyword.get(opts, opt) do
        nil -> kill
        corp_id -> Map.put(kill, key, corp_id)
      end
    end)
    |> Map.merge(extra)
  end

  # -- notable items helpers --------------------------------------------------

  defp enable_notable_items(extra \\ []) do
    original = Application.get_env(:wanderer_app, :external_events, [])

    updated =
      original
      |> Keyword.put(:notable_items_enabled, true)
      |> Keyword.merge(extra)

    Application.put_env(:wanderer_app, :external_events, updated)
    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
  end

  defp returns(mode), do: Application.put_env(:wanderer_app, :test_notable_items_mode, mode)

  defp notable(name, quantity, value),
    do: %{name: name, quantity: quantity, value: value, abyssal?: false}

  defp fresh_kill(id), do: kill(id, DateTime.utc_now() |> DateTime.to_iso8601())

  defp dispatch(map, kills) do
    DiscordDispatcher.dispatch_event(map.id, kill_event(@wh_system, kills))
    :sys.get_state(DiscordDispatcher)
  end

  defp description(body), do: body["embeds"] |> hd() |> Map.get("description")

  # Minimal killmail and event builders matching what `extract_kills/1` expects.
  defp kill(id, kill_time) do
    %{
      "killmail_id" => id,
      "kill_time" => kill_time,
      "solar_system_id" => @wh_system,
      "victim_char_name" => "Pilot #{id}",
      "victim_ship_name" => "Rifter"
    }
  end

  defp kill_event(system_id, killmails) do
    %Event{
      type: :map_kill,
      payload: %{
        "type" => :killmail_update,
        "solar_system_id" => system_id,
        "killmails" => killmails
      }
    }
  end
end
