defmodule WandererApp.ExternalEvents.Discord.WorkerTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.ExternalEvents.Discord.{HttpStub, Worker, WorkerSupervisor}
  alias WandererAppWeb.Factory

  @system_url "https://discord.com/api/webhooks/123/tok"
  @character_url "https://discord.com/api/webhooks/456/tok-char"

  setup do
    HttpStub.start()
    HttpStub.reset()

    start_supervised!(WorkerSupervisor)

    map = Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{map_id: map.id, webhook_url: @system_url})

    %{map: map, notification: notification, system: system_webhook(notification)}
  end

  # `MapDiscordNotification.create/1` creates the parent and its `:system` child
  # in one transaction (Task 1), so the system webhook always exists here.
  defp system_webhook(notification) do
    {:ok, webhooks} = MapDiscordWebhook.by_notification(notification.id)
    Enum.find(webhooks, &(&1.role == :system))
  end

  defp character_webhook(notification, url \\ @character_url) do
    {:ok, webhook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: url
      })

    webhook
  end

  defp message, do: %{"embeds" => [%{"title" => "test"}]}

  defp wait_for_requests(count, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(count, deadline)
  end

  defp do_wait(count, deadline) do
    if length(HttpStub.requests()) >= count do
      HttpStub.requests()
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("expected #{count} requests, got #{length(HttpStub.requests())}")
      else
        Process.sleep(25)
        do_wait(count, deadline)
      end
    end
  end

  # Blocks until the worker has drained its mailbox up to this point. Cheaper
  # and far less flaky than sleeping, now that every attempt is scheduled.
  # Keyed by WEBHOOK id, not map id — that is the Registry key now.
  defp sync(webhook_id) do
    case Registry.lookup(WorkerSupervisor.registry(), webhook_id) do
      [{pid, _}] -> :sys.get_state(pid)
      [] -> :no_worker
    end
  end

  defp await_condition(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_condition(fun, deadline)
  end

  defp do_await_condition(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met before deadline")
        else
          Process.sleep(25)
          do_await_condition(fun, deadline)
        end
    end
  end

  defp reload(webhook_id) do
    {:ok, rec} = MapDiscordWebhook.by_id(webhook_id)
    rec
  end

  test "delivers a message to the configured url", %{system: w} do
    WorkerSupervisor.deliver(w.id, [message()])

    assert [{url, body}] = wait_for_requests(1)
    assert url == @system_url
    assert %{"embeds" => _} = body
  end

  test "records success on the webhook", %{system: w} do
    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    reloaded =
      await_condition(fn ->
        rec = reload(w.id)
        if rec.last_delivery_at, do: {:ok, rec}, else: :retry
      end)

    assert reloaded.consecutive_failures == 0
  end

  test "reloads the webhook, so a replaced url is not used", %{system: w} do
    # Change the URL after capturing the (now stale) struct the caller holds.
    {:ok, _} =
      MapDiscordWebhook.update(w, %{webhook_url: "https://discord.com/api/webhooks/999/newtok"})

    WorkerSupervisor.deliver(w.id, [message()])

    assert [{url, _body}] = wait_for_requests(1)
    assert url == "https://discord.com/api/webhooks/999/newtok"
  end

  test "drops the event when the webhook was deleted while queued", %{system: w} do
    id = w.id
    :ok = MapDiscordWebhook.destroy(w)

    WorkerSupervisor.deliver(id, [message()])
    # Two syncs, not a sleep: the first flushes the deliver cast, the second the
    # `:attempt` message that cast sends to itself. After both, the worker has
    # decided whether to post.
    sync(id)
    sync(id)

    assert HttpStub.requests() == []
  end

  test "drops the event when the webhook was disabled while queued", %{system: w} do
    {:ok, _} = MapDiscordWebhook.set_enabled(w, %{enabled?: false})

    WorkerSupervisor.deliver(w.id, [message()])
    sync(w.id)
    sync(w.id)

    assert HttpStub.requests() == []
  end

  test "sends multi-chunk events in order", %{system: w} do
    msgs = [
      %{"embeds" => [%{"title" => "one"}]},
      %{"embeds" => [%{"title" => "two"}]},
      %{"embeds" => [%{"title" => "three"}]}
    ]

    WorkerSupervisor.deliver(w.id, msgs)
    requests = wait_for_requests(3)

    titles =
      Enum.map(requests, fn {_url, body} ->
        body["embeds"] |> hd() |> Map.get("title")
      end)

    assert titles == ["one", "two", "three"]
  end

  test "retries after a 429 honoring retry_after", %{system: w} do
    HttpStub.set_responses([
      {:ok, 429, [{"retry-after", "0.05"}]},
      {:ok, 204, []}
    ])

    WorkerSupervisor.deliver(w.id, [message()])

    assert length(wait_for_requests(2)) == 2
  end

  test "does not block its mailbox while waiting to retry", %{system: w} do
    # A long retry-after must not stop the worker answering new casts: if the
    # send path slept, this :sys.get_state would time out.
    HttpStub.set_responses([{:ok, 429, [{"retry-after", "2"}]}, {:ok, 204, []}])

    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    assert %{} = sync(w.id)
  end

  test "drops the oldest event when the queue is full", %{system: w} do
    # Hold the worker on a long retry so nothing drains while we overfill.
    HttpStub.set_responses([{:ok, 429, [{"retry-after", "5"}]}])

    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    for i <- 1..120 do
      WorkerSupervisor.deliver(w.id, [%{"embeds" => [%{"title" => "q#{i}"}]}])
    end

    state = sync(w.id)

    assert state.queue_len == 100
    # Oldest were dropped, so the newest enqueued event survived.
    assert state.queue |> :queue.to_list() |> List.last() ==
             [%{"embeds" => [%{"title" => "q120"}]}]
  end

  test "does not retry a 403, but counts it as a failure", %{system: w} do
    HttpStub.set_responses([{:ok, 403, []}])

    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    reloaded =
      await_condition(fn ->
        rec = reload(w.id)
        if rec.consecutive_failures == 1, do: {:ok, rec}, else: :retry
      end)

    # One request only — 403 is permanent, no retry.
    assert length(HttpStub.requests()) == 1
    # But it does NOT disable on its own; the 10-failure threshold governs.
    assert reloaded.enabled? == true
    assert reloaded.last_error =~ "403"
  end

  test "a 401 increments failures without disabling", %{system: w} do
    HttpStub.set_responses([{:ok, 401, []}])

    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    reloaded =
      await_condition(fn ->
        rec = reload(w.id)
        if rec.consecutive_failures == 1, do: {:ok, rec}, else: :retry
      end)

    assert reloaded.enabled? == true
  end

  test "disables the webhook on 404", %{system: w} do
    HttpStub.set_responses([{:ok, 404, []}])

    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    reloaded =
      await_condition(fn ->
        rec = reload(w.id)
        if rec.enabled? == false, do: {:ok, rec}, else: :retry
      end)

    assert reloaded.last_error =~ "404"
  end

  test "disables after 10 consecutive failed events", %{system: w} do
    HttpStub.set_responses(for _ <- 1..10, do: {:ok, 403, []})

    for _ <- 1..10 do
      WorkerSupervisor.deliver(w.id, [message()])
    end

    reloaded =
      await_condition(
        fn ->
          rec = reload(w.id)
          if rec.consecutive_failures >= 10, do: {:ok, rec}, else: :retry
        end,
        5_000
      )

    assert reloaded.enabled? == false
  end

  test "a later failing chunk is not masked by an earlier success", %{system: w} do
    HttpStub.set_responses([
      {:ok, 204, []},
      {:ok, 500, []},
      {:ok, 500, []},
      {:ok, 500, []},
      {:ok, 500, []},
      {:ok, 500, []}
    ])

    WorkerSupervisor.deliver(w.id, [message(), message()])

    reloaded =
      await_condition(
        fn ->
          rec = reload(w.id)
          if rec.consecutive_failures == 1, do: {:ok, rec}, else: :retry
        end,
        20_000
      )

    assert reloaded.last_error != nil
    # Per-event semantics: the successful first chunk must not stamp a delivery.
    assert reloaded.last_delivery_at == nil
  end

  test "stop_worker terminates a running worker", %{system: w} do
    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    assert [{pid, _}] = Registry.lookup(WorkerSupervisor.registry(), w.id)
    ref = Process.monitor(pid)

    assert :ok = WorkerSupervisor.stop_worker(w.id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

    # Registry cleans up its entry asynchronously when the owner dies, so the
    # :DOWN can arrive before the key is released. Poll rather than sleep.
    await_condition(fn ->
      case Registry.lookup(WorkerSupervisor.registry(), w.id) do
        [] -> {:ok, []}
        _ -> :retry
      end
    end)
  end

  test "stop_worker is a no-op when no worker is running", %{system: w} do
    assert :ok = WorkerSupervisor.stop_worker(w.id)
  end

  test "deliver returns an error instead of raising when the supervisor is down", %{system: w} do
    # The kill-switch case: application.ex only starts WorkerSupervisor when
    # webhooks are enabled, so the registry may not exist at all. deliver/2 and
    # stop_worker/1 must be equally tolerant — a dispatcher call must not crash
    # just because the feature is off.
    stop_supervised!(WorkerSupervisor)
    refute Process.whereis(WorkerSupervisor.registry())

    assert {:error, :not_running} = WorkerSupervisor.deliver(w.id, [message()])
    assert :ok = WorkerSupervisor.stop_worker(w.id)
    assert HttpStub.requests() == []
  end

  test "shuts down when idle", %{system: w} do
    # Tiny idle timeout so this exercises the real shutdown path in ms.
    pid =
      start_supervised!(
        {Worker, webhook_id: w.id, registry: WorkerSupervisor.registry(), idle_timeout: 50},
        restart: :temporary
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "gives up on an event whose deadline has passed, without sending", %{system: w} do
    # A negative deadline is already expired when the first attempt runs, so
    # the event is abandoned before any request goes out.
    pid =
      start_supervised!(
        {Worker, webhook_id: w.id, registry: WorkerSupervisor.registry(), event_deadline_ms: -1},
        restart: :temporary
      )

    Worker.enqueue(pid, [message()])

    reloaded =
      await_condition(fn ->
        rec = reload(w.id)
        if rec.consecutive_failures == 1, do: {:ok, rec}, else: :retry
      end)

    assert HttpStub.requests() == []
    assert reloaded.last_error =~ "deadline"
    assert reloaded.last_delivery_at == nil
  end

  test "two webhooks on the same map deliver independently", %{
    notification: n,
    system: sys
  } do
    char = character_webhook(n)

    WorkerSupervisor.deliver(sys.id, [message()])
    WorkerSupervisor.deliver(char.id, [message()])

    wait_for_requests(2)

    assert length(HttpStub.requests_for(@system_url)) == 1
    assert length(HttpStub.requests_for(@character_url)) == 1

    # Two distinct workers, not one shared queue.
    assert [{sys_pid, _}] = Registry.lookup(WorkerSupervisor.registry(), sys.id)
    assert [{char_pid, _}] = Registry.lookup(WorkerSupervisor.registry(), char.id)
    assert sys_pid != char_pid
  end

  test "a 404 on one webhook disables only that webhook", %{notification: n, system: sys} do
    char = character_webhook(n)
    HttpStub.set_responses_for(@character_url, [{:ok, 404, []}])

    WorkerSupervisor.deliver(char.id, [message()])
    WorkerSupervisor.deliver(sys.id, [message()])

    wait_for_requests(2)

    disabled =
      await_condition(fn ->
        rec = reload(char.id)
        if rec.enabled? == false, do: {:ok, rec}, else: :retry
      end)

    assert disabled.last_error =~ "404"

    # The system webhook is untouched: this is the failure the split exists for.
    survivor =
      await_condition(fn ->
        rec = reload(sys.id)
        if rec.last_delivery_at, do: {:ok, rec}, else: :retry
      end)

    assert survivor.enabled? == true
    assert survivor.consecutive_failures == 0
  end

  test "a 429 on one webhook does not delay the other", %{notification: n, system: sys} do
    char = character_webhook(n)
    # 2s is far longer than the 1s budget asserted below, and is clamped to
    # @max_retry_after_ms (10s) so it stays a real wait.
    HttpStub.set_responses_for(@character_url, [{:ok, 429, [{"retry-after", "2"}]}])

    WorkerSupervisor.deliver(char.id, [message()])
    # Let the rate-limited worker take its 429 before the system kill is queued,
    # so a shared queue would genuinely be blocked behind it.
    await_condition(fn ->
      if HttpStub.requests_for(@character_url) != [], do: {:ok, :sent}, else: :retry
    end)

    started = System.monotonic_time(:millisecond)
    WorkerSupervisor.deliver(sys.id, [message()])

    await_condition(fn ->
      if HttpStub.requests_for(@system_url) != [], do: {:ok, :sent}, else: :retry
    end)

    elapsed = System.monotonic_time(:millisecond) - started
    # 1s, not the 500ms this first used: `await_condition/2` polls every 25ms
    # and a loaded CI runner adds scheduler and DB latency, so the tighter
    # budget failed on jitter while the two webhooks were in fact independent.
    # Still far below the 2s retry-after, so a genuinely shared queue fails.
    assert elapsed < 1_000, "system kill waited #{elapsed}ms behind the rate-limited webhook"

    # And the character webhook is still mid-retry, not failed.
    assert length(HttpStub.requests_for(@character_url)) == 1
  end

  test "stop_worker targets a single webhook", %{notification: n, system: sys} do
    char = character_webhook(n)

    WorkerSupervisor.deliver(sys.id, [message()])
    WorkerSupervisor.deliver(char.id, [message()])
    wait_for_requests(2)

    assert [{char_pid, _}] = Registry.lookup(WorkerSupervisor.registry(), char.id)
    ref = Process.monitor(char_pid)

    assert :ok = WorkerSupervisor.stop_worker(char.id)
    assert_receive {:DOWN, ^ref, :process, ^char_pid, _}, 1_000

    # The system worker is still registered and alive.
    assert [{sys_pid, _}] = Registry.lookup(WorkerSupervisor.registry(), sys.id)
    assert Process.alive?(sys_pid)
  end
end
