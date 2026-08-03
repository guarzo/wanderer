defmodule WandererApp.ExternalEvents.DiscordDispatcherTest do
  # `async: false` is mandatory: `HttpStub` keeps its state in a single named
  # Agent, and this file also mutates application env.
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.ExternalEvents.{DiscordDispatcher, Event}
  alias WandererApp.ExternalEvents.Discord.{EmbedFormatter, HttpStub, WorkerSupervisor}
  alias WandererAppWeb.Factory

  # A real wormhole system id (J-space) and a real known-space id (Jita).
  @wh_system 31_000_005
  @ks_system 30_000_142

  @system_url "https://discord.com/api/webhooks/123/tok"

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

    refute_delivery(nil)
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
    first_batch_size = length(EmbedFormatter.format_batch(kills, "X"))
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
end
