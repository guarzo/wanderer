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

  alias WandererAppWeb.Factory

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

  test "ignores kill_count events", %{map: map, system: w} do
    event = kill_event(Factory.build(:kill_count_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  test "skips non-wormhole systems when wh_only is set", %{map: map, system: w} do
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

      # Exactly two messages: the third kill went nowhere.
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

  # send_test_message now takes a WEBHOOK id, so "not configured" means "no such
  # webhook row" rather than "no config for this map".
  test "send_test_message reports an unknown webhook" do
    assert {:error, :not_configured} =
             DiscordDispatcher.send_test_message(Ash.UUID.generate())
  end

  test "send_test_message reports a disabled webhook", %{system: w} do
    {:ok, _} = MapDiscordWebhook.set_enabled(w, %{enabled?: false})

    assert {:error, :not_configured} = DiscordDispatcher.send_test_message(w.id)
    assert HttpStub.requests() == []
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
      assert Cachex.exists?(:discord_dedup_cache, "#{map.id}:9002") == {:ok, false}

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
      assert Cachex.exists?(:discord_dedup_cache, "#{map.id}:9004") == {:ok, true}
      assert Cachex.exists?(:discord_dedup_cache, "#{map.id}:9003") == {:ok, false}
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

      assert Cachex.exists?(:discord_dedup_cache, "#{map.id}:9201") == {:ok, false}
      assert Cachex.exists?(:discord_dedup_cache, "#{map.id}:9203") == {:ok, false}
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
