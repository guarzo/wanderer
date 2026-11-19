defmodule WandererApp.ExternalEvents.Discord.Worker do
  @moduledoc """
  Serializes Discord delivery for one webhook.

  Discord rate-limits a webhook to roughly 5 requests/second and answers 429
  with a `retry-after`. Everything for a webhook funnels through this process so
  concurrent kill batches cannot interleave and burst.

  A map has up to two destinations (system and character), and they get separate
  workers on purpose: a 429 or a dead URL on one channel must not stall or
  disable the other.

  ## Asynchronous: never blocks on the network

  Each request and each retry is scheduled with `Process.send_after/3` and
  handled in `handle_info`, so the process returns to its mailbox between
  attempts. This is deliberate: a worker that sleeps inside `handle_cast`
  cannot process incoming casts, which would make the 100-item queue bound
  meaningless — events would pile up unbounded in the mailbox instead of being
  dropped by the cap. (The existing `WebhookDispatcher` sleeps inside its retry
  loop at `webhook_dispatcher.ex:355,376`; it is not the model here.)

  The HTTP request itself runs in a monitored `Task` for the same reason: a
  synchronous call would block the process for up to the client's 15s receive
  timeout, and a queue bound the mailbox routes around is not a bound at all.

  The database calls are the deliberate exception, and the guarantee is
  specifically "never blocks on the *network*", not "never blocks". The
  notification reload in `attempt/1` is synchronous because it must be ordered
  before the send — the whole point is that no request goes out against a stale
  record, which an async reload could not guarantee. The status write shares
  that call's result. Under Ecto pool exhaustion (prod `queue_target` 5s) these
  can block, which is the same mailbox-accumulation failure mode via the DB
  rather than the socket; it is bounded by the pool timeout and accepted here.

  ## Ids, not records

  The queue holds messages only; the webhook id lives in state. The webhook row
  is reloaded from the database immediately before every send, so a URL the user
  has replaced or deleted is never used, and a stale `consecutive_failures`
  snapshot cannot corrupt the counter.

  If the reload finds the webhook deleted, or finds `enabled?` false, the queued
  event is dropped silently: no request, and no status write. There is nothing
  meaningful to record against a row the user removed, and writing a failure
  onto a row they deliberately disabled would be misleading.

  ## Per-event status

  Delivery status is tracked per *event*, not per request: a multi-chunk event
  is only a success once every chunk lands, and an early successful chunk never
  clears an error recorded by a later one.

  ## Limits

  An event gets at most 5 attempts per chunk and is subject to a ~60s deadline.
  The deadline is checked after any per-webhook or node-global cooldown, before
  dispatching an attempt, not while a request is in flight. A long cooldown can
  therefore defer that check well beyond 60s; this is a soft bound on *starting*
  new work, not a 75s wall-clock cap.

  Transport errors are retried, including uncertain outcomes where Discord
  accepted the request but its response was lost. Such retries can duplicate a
  post. Stopping a worker cancels its request task, but cannot retract a
  request already accepted remotely.

  ## Rate limits

  A 429 sets a per-webhook cooldown on this worker, and `HttpClient` shares a
  node-global cooldown across every worker when Discord reports the limit as
  global. A Retry-After within budget is honored and the event retried; one
  beyond it is not sent early and the event is recorded as a failure, while later
  queued events still wait out the cooldown.
  """

  use GenServer, restart: :transient

  require Logger

  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.ExternalEvents.Discord.HttpClient
  alias WandererApp.ExternalEvents.Discord.Mentions

  @idle_timeout :timer.seconds(60)
  @max_queue 100
  @max_attempts 5
  @event_deadline_ms 60_000
  # A 429's Retry-After above this is not honored early: repeatedly ignoring
  # Retry-After is the behaviour Discord/Cloudflare issue temporary IP bans for,
  # and that ban would take down every map on the instance, not just the
  # rate-limited one. See HttpClient.retry_after_ms/2.
  @retry_after_give_up_ms 10_000
  @backoff_base_ms 1_000
  @max_backoff_ms 8_000
  # Discord allows a webhook roughly 5 requests/second. A multi-chunk event
  # posted back-to-back would burst straight into a 429 and burn attempts, so
  # chunks are spaced just over that budget.
  @inter_chunk_delay_ms 250

  def start_link(opts) do
    webhook_id = Keyword.fetch!(opts, :webhook_id)
    registry = Keyword.fetch!(opts, :registry)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {registry, webhook_id}})
  end

  @doc """
  Queues one event's messages for delivery.

  No id argument: the worker IS the webhook now, so the queue holds messages
  alone and the id comes from state.
  """
  def enqueue(pid, messages) do
    GenServer.cast(pid, {:enqueue, messages})
  end

  @impl true
  def init(opts) do
    # Run terminate/2 on supervised shutdown to cancel any in-flight HTTP task.
    Process.flag(:trap_exit, true)

    # Both timeouts are overridable so tests can exercise idle shutdown and
    # deadline expiry without waiting a real minute. Production always uses the
    # module defaults.
    idle_timeout = Keyword.get(opts, :idle_timeout, @idle_timeout)

    {:ok,
     %{
       webhook_id: Keyword.fetch!(opts, :webhook_id),
       idle_timeout: idle_timeout,
       event_deadline_ms: Keyword.get(opts, :event_deadline_ms, @event_deadline_ms),
       queue: :queue.new(),
       queue_len: 0,
       retry_at: nil,
       # nil when idle, otherwise the event currently being delivered
       current: nil
     }, idle_timeout}
  end

  @impl true
  def handle_cast({:enqueue, messages}, state) do
    state =
      state
      |> push(messages)
      |> maybe_start_next()

    {:noreply, state, state.idle_timeout}
  end

  @impl true
  def handle_info(:attempt, %{current: nil} = state) do
    state = maybe_start_next(state)
    {:noreply, state, state.idle_timeout}
  end

  def handle_info(:attempt, state) do
    state = attempt(state)
    {:noreply, state, state.idle_timeout}
  end

  # Reply from the in-flight request task.
  def handle_info({ref, result}, %{current: %{task_ref: ref}} = state) when is_reference(ref) do
    # Demonitor first: the task is about to send its :DOWN, and we do not want
    # to treat normal completion as a crash.
    Process.demonitor(ref, [:flush])
    state = handle_post_result(state, result)
    {:noreply, state, state.idle_timeout}
  end

  # The request task crashed. Treat it as a transient failure and retry, rather
  # than losing the event. The worker traps exits from its linked task; only
  # this monitor path schedules a retry, never the accompanying EXIT.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current: %{task_ref: ref}} = state)
      when is_reference(ref) do
    state = put_current(state, %{state.current | task_ref: nil})

    state =
      schedule_retry(
        state,
        backoff_ms(state.current.attempt),
        "request crashed: #{inspect(reason)}"
      )

    {:noreply, state, state.idle_timeout}
  end

  # Linked task exits also arrive after normal results or DOWN. Do not retry
  # twice, or log an exit reason that could contain transport credentials.
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state, state.idle_timeout}
  end

  # A late reply or DOWN from a task we already gave up on — ignore it.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state, state.idle_timeout}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    {:noreply, state, state.idle_timeout}
  end

  def handle_info(:timeout, %{queue_len: 0, current: nil} = state) do
    # Stay up while a cooldown is active: stopping would forget the per-webhook
    # retry_at, and the next enqueue would send straight into the same 429.
    if cooldown_ms(state) > 0 do
      {:noreply, state, state.idle_timeout}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info(:timeout, state), do: {:noreply, state, state.idle_timeout}

  def handle_info(msg, state) do
    Logger.debug("[Discord.Worker] unexpected message: #{inspect(msg)}")
    {:noreply, state, state.idle_timeout}
  end

  @impl true
  def terminate(_reason, %{current: %{task_pid: pid}}) when is_pid(pid) do
    # Graceful shutdown waits for cancellation; the task link also handles a
    # forced worker death that bypasses this callback.
    Task.Supervisor.terminate_child(WandererApp.ExternalEvents.Discord.TaskSupervisor, pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- queue ----------------------------------------------------------------

  defp push(%{queue_len: len} = state, item) when len >= @max_queue do
    # Drop the oldest: a feed 100 messages behind has already failed its
    # purpose, and unbounded growth risks the VM. queue_len is unchanged
    # because one item leaves as one enters.
    {{:value, _dropped}, q} = :queue.out(state.queue)

    Logger.warning(
      "[Discord.Worker] queue full for webhook #{state.webhook_id}, dropping oldest event"
    )

    %{state | queue: :queue.in(item, q)}
  end

  defp push(state, item) do
    %{state | queue: :queue.in(item, state.queue), queue_len: state.queue_len + 1}
  end

  defp maybe_start_next(%{current: current} = state) when not is_nil(current), do: state

  defp maybe_start_next(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, messages}, rest} ->
        current = %{
          pending: messages,
          attempt: 1,
          task_ref: nil,
          task_pid: nil,
          # Most recently loaded record, reused for the status write so
          # finishing an event does not re-query what we just read.
          webhook: nil,
          # Ciphertext of the URL this event's chunks have been sent to. The
          # status write is filtered on it (see `MapDiscordWebhook`), so an
          # outcome for a replaced URL can never land on its replacement.
          sent_cipher: nil,
          deadline: System.monotonic_time(:millisecond) + state.event_deadline_ms
        }

        send(self(), :attempt)
        %{state | queue: rest, queue_len: state.queue_len - 1, current: current}
    end
  end

  # -- one attempt ----------------------------------------------------------

  defp attempt(%{current: %{pending: []}} = state), do: finish(state, :ok)

  defp attempt(%{current: current} = state) do
    cond do
      # The kill switch can be turned off while an event is retrying.
      not WandererApp.Env.webhooks_enabled?() ->
        drop_current(state)

      cooldown_ms(state) > 0 ->
        Process.send_after(self(), :attempt, min(cooldown_ms(state), @event_deadline_ms))
        state

      System.monotonic_time(:millisecond) > current.deadline ->
        finish(state, {:error, "delivery deadline exceeded", :count})

      current.attempt > @max_attempts ->
        finish(state, {:error, "gave up after #{@max_attempts} attempts", :count})

      true ->
        # Reload every time: the URL may have been replaced or the webhook
        # deleted since this event was queued. This reload is the one that
        # matters — nothing is sent against a stale record.
        case MapDiscordWebhook.for_delivery(state.webhook_id) do
          {:ok, webhook} ->
            cond do
              not webhook.enabled? ->
                # Disabled while queued — drop the event silently, no status write.
                drop_current(put_current(state, %{current | webhook: webhook}))

              url_replaced_mid_event?(current, webhook) ->
                # Earlier chunks went to the previous URL. Their outcome belongs
                # to that endpoint, not the replacement, and the rest of the
                # event was queued for the old destination: drop it, no write.
                Logger.debug("[Discord.Worker] webhook URL replaced mid-event, dropping event")
                drop_current(state)

              true ->
                state =
                  put_current(state, %{
                    current
                    | webhook: webhook,
                      sent_cipher: webhook.encrypted_webhook_url
                  })

                do_post(state, webhook)
            end

          _ ->
            Logger.debug("[Discord.Worker] webhook gone, dropping queued event")
            drop_current(state)
        end
    end
  end

  defp url_replaced_mid_event?(%{sent_cipher: nil}, _webhook), do: false

  defp url_replaced_mid_event?(%{sent_cipher: sent}, webhook),
    do: sent != webhook.encrypted_webhook_url

  # Runs the request in a monitored Task so the worker never blocks on the
  # socket. The HTTP client can take up to its 15s receive timeout; blocking
  # here would let casts pile up in the mailbox and silently defeat the
  # bounded state queue — the same defect as sleeping, just harder to see.
  defp do_post(%{current: current} = state, webhook) do
    [message | _rest] = current.pending
    message = attach_allowed_mentions(message)
    url = webhook.webhook_url

    task =
      Task.Supervisor.async(
        WandererApp.ExternalEvents.Discord.TaskSupervisor,
        fn -> HttpClient.post(url, message) end
      )

    put_current(state, %{current | task_ref: task.ref, task_pid: task.pid})
  end

  # Every message that carries `"content"` must also carry `allowed_mentions`,
  # or Discord defaults to parsing @everyone/@here/user/role mentions found in
  # the text — see the design doc's "Mention injection is a real risk". A
  # caller that already set one (Task 6's route alerts, with real configured
  # targets) is left untouched; this only fills the gap for callers that
  # never think about mentions at all (the static test message, the overflow
  # string, voice-mention prefixes).
  defp attach_allowed_mentions(message) do
    if Map.has_key?(message, "content") and not Map.has_key?(message, "allowed_mentions") do
      Map.put(message, "allowed_mentions", Mentions.allowed_mentions([]))
    else
      message
    end
  end

  defp handle_post_result(state, {:ok, 429, headers, body}) do
    handle_rate_limited(state, headers, body)
  end

  defp handle_post_result(state, result) do
    current = state.current
    [_sent | rest] = current.pending

    case result do
      {:ok, status, _headers} when status in 200..299 ->
        # Chunk delivered: move on with a fresh attempt budget, same deadline.
        state = put_current(state, %{current | pending: rest, attempt: 1, task_ref: nil})

        if rest == [] do
          finish(state, :ok)
        else
          # Spaced, not immediate: back-to-back chunks would trip the webhook's
          # own rate limit and turn a successful event into a run of 429s.
          Process.send_after(self(), :attempt, @inter_chunk_delay_ms)
          state
        end

      {:ok, 429, headers} ->
        handle_rate_limited(state, headers)

      {:ok, 404, _headers} ->
        # The only status that disables immediately: the webhook was deleted
        # upstream and will never recover.
        finish(state, {:error, "Discord returned 404 — webhook was deleted", :disable})

      {:ok, status, _headers} when status in 400..499 ->
        # 401/403 and any other 4xx are permanent for this event but do NOT
        # disable on their own — they feed the 10-consecutive-failure
        # threshold, so a single transient 403 cannot kill a map's feed.
        finish(state, {:error, "Discord returned #{status}", :count})

      {:ok, status, _headers} ->
        state = put_current(state, %{current | task_ref: nil})
        schedule_retry(state, backoff_ms(current.attempt), "Discord returned #{status}")

      {:error, {:encode_failed, reason}} ->
        # Never retried: a payload that will not encode cannot become encodable
        # by trying again. Permanent for this event, counted like any other 4xx.
        Logger.error("[Discord] payload encode failed: #{inspect(reason)}")
        finish(state, {:error, "invalid payload", :count})

      {:error, reason} ->
        Logger.warning("[Discord] request failed: #{inspect(reason)}")
        state = put_current(state, %{current | task_ref: nil})

        schedule_retry(
          state,
          backoff_ms(current.attempt),
          "request failed: #{http_error_message(reason)}"
        )
    end
  end

  # HttpClient strips credential-bearing transport terms at the boundary, so the
  # persisted, user-visible message carries nothing but a generic description.
  defp http_error_message(_reason), do: "connection error"

  # Schedules the next attempt instead of sleeping, so the mailbox keeps moving.
  defp schedule_retry(%{current: current} = state, delay_ms, reason) do
    next_attempt = current.attempt + 1

    if next_attempt > @max_attempts do
      finish(state, {:error, reason, :count})
    else
      Process.send_after(self(), :attempt, delay_ms)
      put_current(state, %{current | attempt: next_attempt})
    end
  end

  defp put_current(state, current), do: %{state | current: current}

  defp drop_current(state) do
    state |> put_current(nil) |> maybe_start_next()
  end

  # -- event completion -----------------------------------------------------

  # Reuses the record `attempt/1` loaded moments ago rather than re-querying.
  # That record is exactly what was sent to, which is the point: the resource
  # filters every outcome write on its encrypted URL, so if the user replaced
  # the URL in the meantime the write is rejected instead of landing on the
  # replacement. `record_failure` increments atomically in SQL, so a slightly
  # stale copy cannot corrupt the counter either.
  # Falls back to a query when no record was loaded (e.g. the deadline expired
  # before the first attempt).
  defp finish(%{current: current} = state, outcome) do
    case current.webhook do
      nil -> record_outcome(state.webhook_id, outcome)
      webhook -> apply_outcome(webhook, outcome)
    end

    drop_current(state)
  end

  defp record_outcome(webhook_id, outcome) do
    case MapDiscordWebhook.for_delivery(webhook_id) do
      {:ok, webhook} -> apply_outcome(webhook, outcome)
      _ -> :ok
    end
  end

  defp apply_outcome(webhook, :ok) do
    webhook |> MapDiscordWebhook.record_success() |> log_outcome_write(:record_success)
  end

  defp apply_outcome(webhook, {:error, reason, :disable}) do
    webhook |> MapDiscordWebhook.disable(to_string(reason)) |> log_outcome_write(:disable)
  end

  defp apply_outcome(webhook, {:error, reason, :count}) do
    # record_failure disables at @max_consecutive_failures on the resource side.
    webhook
    |> MapDiscordWebhook.record_failure(to_string(reason))
    |> log_outcome_write(:record_failure)
  end

  defp log_outcome_write({:ok, _}, _action), do: :ok

  defp log_outcome_write({:error, %Ash.Error.Invalid{errors: errors} = error}, action) do
    # A StaleRecord means the URL was replaced after we sent: the outcome
    # describes the old endpoint and is deliberately discarded.
    if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) do
      Logger.debug("[Discord] #{action} discarded: webhook URL was replaced during delivery")
    else
      Logger.warning("[Discord] #{action} failed: #{inspect(error)}")
    end

    :ok
  end

  defp log_outcome_write({:error, error}, action) do
    Logger.warning("[Discord] #{action} failed: #{inspect(error)}")
    :ok
  end

  # -- timing helpers -------------------------------------------------------

  # A Retry-After within budget is honored and the event retried; one beyond
  # @retry_after_give_up_ms is not sent early: the event is recorded as a failed
  # delivery instead. Later queued events still wait for the cooldown. This gives
  # up rather than retrying, because retrying anyway is what gets a webhook (and
  # the shared IP) rate-limited by Cloudflare.
  defp handle_rate_limited(state, headers, body \\ nil) do
    ms = HttpClient.retry_after_ms(headers, body)
    state = put_current(state, %{state.current | task_ref: nil})
    state = %{state | retry_at: System.monotonic_time(:millisecond) + ms}

    case ms do
      ms when ms > @retry_after_give_up_ms ->
        finish(
          state,
          {:error, "Discord returned 429 with retry-after #{ms}ms exceeding budget", :count}
        )

      ms ->
        schedule_retry(state, ms, "Discord returned 429 (rate limited)")
    end
  end

  defp cooldown_ms(state) do
    local =
      if is_integer(state.retry_at),
        do: max(state.retry_at - System.monotonic_time(:millisecond), 0),
        else: 0

    max(local, HttpClient.global_cooldown_ms())
  end

  defp backoff_ms(attempt) do
    (@backoff_base_ms * :math.pow(2, attempt - 1)) |> min(@max_backoff_ms) |> round()
  end
end
