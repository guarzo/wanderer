defmodule WandererApp.ExternalEvents.Discord.WorkerTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.ExternalEvents.Discord.{HttpStub, Worker, WorkerSupervisor}
  alias WandererAppWeb.Factory

  @system_url "https://discord.com/api/webhooks/123/tok"
  @character_url "https://discord.com/api/webhooks/456/tok-char"

  setup do
    # The worker re-checks the global kill switch on every attempt, and
    # config/test.exs ships it off.
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
  #
  # Raises rather than returning a sentinel when no worker is registered: as a
  # no-op this stopped being a barrier at all, and the assertion that follows it
  # would then race and pass for the wrong reason.
  defp sync(webhook_id) do
    case Registry.lookup(WorkerSupervisor.registry(), webhook_id) do
      [{pid, _}] ->
        :sys.get_state(pid)

      [] ->
        flunk(
          "no worker registered for webhook #{inspect(webhook_id)} — sync/1 cannot synchronize"
        )
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

  test "an outcome for a replaced url never lands on the replacement", %{system: w} do
    parent = self()

    HttpStub.set_responses([
      fn _url, _body ->
        send(parent, {:in_flight, self()})

        receive do
          :release -> {:ok, 403, []}
        end
      end
    ])

    WorkerSupervisor.deliver(w.id, [message()])
    assert_receive {:in_flight, request_pid}, 2_000

    replacement = "https://discord.com/api/webhooks/777/replacement-tok"
    {:ok, _} = MapDiscordWebhook.update(reload(w.id), %{webhook_url: replacement})

    # The 403 is for the OLD endpoint; it must not count against the new one.
    send(request_pid, :release)
    sync(w.id)

    after_outcome = reload(w.id)
    assert after_outcome.webhook_url == replacement
    assert after_outcome.consecutive_failures == 0
    assert after_outcome.last_error == nil
    assert after_outcome.enabled?
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

  describe "allowed_mentions hardening" do
    test "a message with content but no allowed_mentions gets a safe default attached", %{
      system: w
    } do
      WorkerSupervisor.deliver(w.id, [%{"content" => "test message"}])

      assert [{_url, body}] = wait_for_requests(1)
      assert body["allowed_mentions"] == %{"parse" => [], "users" => [], "roles" => []}
    end

    test "an explicit allowed_mentions is left untouched", %{system: w} do
      explicit = %{"parse" => [], "users" => ["111111111111111111"], "roles" => []}

      WorkerSupervisor.deliver(w.id, [
        %{"content" => "<@111111111111111111> route opened", "allowed_mentions" => explicit}
      ])

      assert [{_url, body}] = wait_for_requests(1)
      assert body["allowed_mentions"] == explicit
    end

    test "an embed-only message with no content is left without allowed_mentions", %{system: w} do
      WorkerSupervisor.deliver(w.id, [message()])

      assert [{_url, body}] = wait_for_requests(1)
      refute Map.has_key?(body, "allowed_mentions")
    end
  end

  # Adapted from upstream 38b773e9's per-map worker tests: the fork keys workers
  # by webhook id, so "another map's worker" becomes "another webhook's worker".
  describe "rate limits and hardening (upstream 38b773e9)" do
    test "honors numeric retry_after in Discord's JSON body", %{system: w} do
      HttpStub.set_responses([{:ok, 429, [], ~s({"retry_after":20.0,"global":false})}])
      WorkerSupervisor.deliver(w.id, [message()])

      reloaded =
        await_condition(fn ->
          rec = reload(w.id)
          if rec.consecutive_failures == 1, do: {:ok, rec}, else: :retry
        end)

      assert reloaded.last_error =~ "429"
      assert reloaded.last_error =~ "20000ms"
      assert length(HttpStub.requests()) == 1
    end

    test "a global 429 delays another webhook's worker without sending early", %{
      notification: n,
      system: w
    } do
      other = character_webhook(n)
      parent = self()

      probe = fn url, _ ->
        send(parent, {:network, url, System.monotonic_time(:millisecond)})
        {:ok, 204, []}
      end

      HttpStub.set_responses([
        fn _, _ ->
          send(parent, {:limited_at, System.monotonic_time(:millisecond)})
          {:ok, 429, [{"retry-after", "0.6"}, {"X-RateLimit-Global", "true"}], ""}
        end,
        probe,
        probe
      ])

      WorkerSupervisor.deliver(w.id, [message()])
      assert_receive {:limited_at, limited_at}, 1_000

      await_condition(fn ->
        if is_integer(sync(w.id).retry_at), do: {:ok, :limited}, else: :retry
      end)

      WorkerSupervisor.deliver(other.id, [message()])
      sync(other.id)
      refute_receive {:network, _, _}, 100
      assert_receive {:network, @character_url, posted_at}, 1_500
      assert posted_at - limited_at >= 600
    end

    test "a long global cooldown is shared and never sent early", %{notification: n, system: w} do
      other = character_webhook(n)

      HttpStub.set_responses([
        {:ok, 429, [{"retry-after", "20"}, {"x-ratelimit-global", "true"}],
         ~s({"retry_after":20.0,"global":true})}
      ])

      WorkerSupervisor.deliver(w.id, [message()])

      await_condition(fn ->
        if is_integer(sync(w.id).retry_at), do: {:ok, :limited}, else: :retry
      end)

      WorkerSupervisor.deliver(other.id, [message()])
      sync(other.id)
      Process.sleep(100)
      assert length(HttpStub.requests()) == 1
    end

    test "a webhook-only cooldown stays local to its webhook", %{notification: n, system: w} do
      HttpStub.set_responses([
        {:ok, 429, [{"retry-after", "20"}, {"x-ratelimit-scope", "shared"}],
         ~s({"retry_after":20.0,"global":false})}
      ])

      WorkerSupervisor.deliver(w.id, [message()])

      await_condition(fn ->
        if is_integer(sync(w.id).retry_at), do: {:ok, :limited}, else: :retry
      end)

      other = character_webhook(n)
      WorkerSupervisor.deliver(other.id, [message()])
      assert length(wait_for_requests(2)) == 2
    end

    test "honors a long 429 cooldown for the next queued event", %{system: w} do
      HttpStub.set_responses([{:ok, 429, [{"retry-after", "20"}]}])
      WorkerSupervisor.deliver(w.id, [message()])

      await_condition(fn ->
        rec = reload(w.id)
        if rec.consecutive_failures == 1, do: {:ok, rec}, else: :retry
      end)

      WorkerSupervisor.deliver(w.id, [message()])
      sync(w.id)
      Process.sleep(100)
      assert length(HttpStub.requests()) == 1
    end

    test "retries a linked request task crash once without crashing the worker", %{system: w} do
      HttpStub.set_responses([fn _, _ -> Process.exit(self(), :kill) end, {:ok, 204, []}])
      WorkerSupervisor.deliver(w.id, [message()])
      wait_for_requests(1)
      [{pid, _}] = Registry.lookup(WorkerSupervisor.registry(), w.id)

      await_condition(fn ->
        if reload(w.id).last_delivery_at, do: {:ok, :delivered}, else: :retry
      end)

      assert Process.alive?(pid)
      assert length(HttpStub.requests()) == 2
      assert reload(w.id).consecutive_failures == 0
    end

    test "stop_worker removes a busy worker and cancels its request task", %{system: w} do
      parent = self()

      HttpStub.set_responses([
        fn _, _ ->
          send(parent, {:pending_request, self()})

          receive do
            :release ->
              send(parent, :late_effect)
              {:ok, 204, []}
          end
        end
      ])

      WorkerSupervisor.deliver(w.id, [message()])
      assert_receive {:pending_request, task}, 1_000
      task_ref = Process.monitor(task)
      on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)

      [{pid, _}] = Registry.lookup(WorkerSupervisor.registry(), w.id)

      # Model a blocked DB call: this also blocks system messages, so
      # GenServer.stop alone would time out without killing the worker.
      Task.start(fn ->
        try do
          :sys.replace_state(pid, fn state ->
            send(parent, :worker_blocked)

            receive do
              :release -> state
            end
          end)
        catch
          :exit, _ -> :ok
        end
      end)

      assert_receive :worker_blocked
      on_exit(fn -> send(pid, :release) end)
      assert :ok = WorkerSupervisor.stop_worker(w.id)
      refute Process.alive?(pid)
      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
      send(task, :release)
      refute_receive :late_effect

      assert [] ==
               DynamicSupervisor.which_children(
                 WandererApp.ExternalEvents.Discord.DynamicSupervisor
               )
    end

    test "stops retrying when the global webhook switch turns off", %{system: w} do
      HttpStub.set_responses([{:ok, 429, [{"retry-after", "0.05"}]}])
      WorkerSupervisor.deliver(w.id, [message()])
      wait_for_requests(1)
      original = Application.get_env(:wanderer_app, :external_events, [])

      Application.put_env(
        :wanderer_app,
        :external_events,
        Keyword.put(original, :webhooks_enabled, false)
      )

      await_condition(fn ->
        if sync(w.id).current == nil, do: {:ok, :idle}, else: :retry
      end)

      assert length(HttpStub.requests()) == 1
      assert reload(w.id).last_delivery_at == nil
      assert reload(w.id).consecutive_failures == 0
    end

    test "redacts credential-bearing transport errors and exceptions", %{system: w} do
      secret = "synthetic-webhook-token"
      url = "https://discord.com/api/webhooks/123/#{secret}"
      {:ok, _} = MapDiscordWebhook.update(reload(w.id), %{webhook_url: url})

      for response <- [
            {:error, %RuntimeError{message: "request failed for #{url}"}},
            fn _, _ -> raise "request failed for #{url}" end
          ] do
        HttpStub.set_responses(
          List.duplicate({:ok, 429, [{"retry-after", "0.05"}]}, 4) ++ [response]
        )

        previous = reload(w.id).consecutive_failures

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            WorkerSupervisor.deliver(w.id, [message()])

            await_condition(fn ->
              rec = reload(w.id)
              if rec.consecutive_failures > previous, do: {:ok, rec}, else: :retry
            end)
          end)

        refute log =~ secret
        refute reload(w.id).last_error =~ secret
        assert reload(w.id).last_error =~ "connection error"
      end
    end

    test "does not retry an encode failure, but counts it", %{system: w} do
      HttpStub.set_responses([{:error, {:encode_failed, :bad_term}}])

      WorkerSupervisor.deliver(w.id, [message()])
      wait_for_requests(1)

      reloaded =
        await_condition(fn ->
          rec = reload(w.id)
          if rec.consecutive_failures == 1, do: {:ok, rec}, else: :retry
        end)

      assert length(HttpStub.requests()) == 1
      assert reloaded.enabled? == true
      assert reloaded.last_error =~ "invalid payload"
    end
  end
end
