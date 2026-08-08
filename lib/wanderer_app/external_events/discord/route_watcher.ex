defmodule WandererApp.ExternalEvents.Discord.RouteWatcher do
  @moduledoc """
  One GenServer per map: owns the debounce timer, the last-known route state,
  its `config_version`, and the in-flight solver task. Registry-addressed like
  `Discord.Worker` (`worker.ex`), keyed by `map_id` instead of `webhook_id`.

  ## Why the solver task never blocks this process

  `Task.yield(20_000) || Task.shutdown(:brutal_kill)` — the idiom
  `DiscordDispatcher`'s enrichment steps use — is wrong here. It parks this
  process for up to 20s, during which it cannot receive the `notify` casts that
  are supposed to set the re-run flag. Those casts would sit in the mailbox and
  be processed *after* the stale result was already published, so a connection
  closing mid-solve could still produce a false "opened" alert. The dispatcher
  can afford to block because it is enriching a payload it already holds; this
  process cannot, because incoming events invalidate the work in flight.

  So the task runs via `Task.Supervisor.async_nolink/2`, its ref (inside the
  `%Task{}` struct, not bare) is stored in state, and both `{ref, result}` and
  `{:DOWN, ref, ...}` are handled in `handle_info`. A `Process.send_after/3`
  deadline enforces the 20s budget from the timeout handler, calling
  `Task.shutdown(task, :brutal_kill)` — which itself drains the matching `:DOWN`
  or `{ref, result}` message, so no separate cleanup clause is needed for a
  self-inflicted shutdown.

  A notify arriving while a task is in flight only sets `rerun?: true`; the
  result handler discards the in-flight answer and starts a fresh evaluation
  immediately when it lands with `rerun?` set, rather than publishing a result
  that may already be stale.

  ## What `rehydrate/1` does and does not survive

  `persist/1` writes to `:discord_route_alert_cache`, a plain in-memory Cachex
  table with no TTL and no disk backing. Route-alert state therefore survives
  only a **watcher process restart** (a crash, or a supervisor restart) on a
  running node. It does NOT survive a node restart or a deployment — the cache
  starts empty, `rehydrate/1` finds nothing, and every watcher begins at
  `:unknown`.

  The visible consequence: a route that was already open before a restart is
  announced again as `:opened` on the first evaluation after it, because
  `:unknown -> {:qualifying, _}` is the "opened" transition. That is the
  deliberate trade — the alternative is persisting alert state to the database
  on every evaluation to suppress one duplicate message per map per deploy.
  """

  use GenServer, restart: :transient

  require Logger

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.ExternalEvents.Discord.{Router, WorkerSupervisor, EmbedFormatter}
  alias WandererApp.Map.RouteAlert.Evaluator

  @registry WandererApp.ExternalEvents.Discord.RouteWatcherRegistry
  @cache :discord_route_alert_cache

  @debounce_ms 10_000
  @ceiling_ms 60_000
  @task_timeout_ms 20_000

  def start_link(opts) do
    map_id = Keyword.fetch!(opts, :map_id)
    GenServer.start_link(__MODULE__, opts, name: via(map_id))
  end

  @doc "Queues a re-evaluation for this map. The watcher must already be running."
  @spec notify(binary()) :: :ok
  def notify(map_id) do
    GenServer.cast(via(map_id), :notify)
  end

  @doc "The Registry this module is addressed through. Owned here, read by RouteWatcherSupervisor."
  def registry, do: @registry

  defp via(map_id), do: {:via, Registry, {@registry, map_id}}

  @impl true
  def init(opts) do
    map_id = Keyword.fetch!(opts, :map_id)

    state = %{
      map_id: map_id,
      route_state: :unknown,
      config_version: nil,
      timer_ref: nil,
      first_notify_at: nil,
      task: nil,
      task_deadline_ref: nil,
      rerun?: false,
      pending_notification: nil,
      debounce_ms: Keyword.get(opts, :debounce_ms, @debounce_ms),
      ceiling_ms: Keyword.get(opts, :ceiling_ms, @ceiling_ms),
      task_timeout_ms: Keyword.get(opts, :task_timeout_ms, @task_timeout_ms)
    }

    {:ok, rehydrate(state)}
  end

  # Only the raw {route_state, config_version} pair is rehydrated here. The
  # config_version comparison against the map's CURRENT configuration happens
  # in start_evaluation/1 on the next notify, exactly as it does on every other
  # evaluation — deferring it avoids a DB read on every process start for
  # watchers that are started but never fire (e.g. a crash-restart loop).
  defp rehydrate(state) do
    case Cachex.get(@cache, state.map_id) do
      {:ok, %{route_state: rs, config_version: cv}} ->
        %{state | route_state: rs, config_version: cv}

      _ ->
        state
    end
  rescue
    # Cache not started in every test context; a fresh :unknown state is the
    # correct fallback, not a crash.
    _ -> state
  end

  @impl true
  def handle_cast(:notify, %{task: task} = state) when not is_nil(task) do
    {:noreply, %{state | rerun?: true}}
  end

  def handle_cast(:notify, state) do
    {:noreply, arm_timer(state)}
  end

  defp arm_timer(state) do
    now = System.monotonic_time(:millisecond)
    first_notify_at = state.first_notify_at || now

    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Re-armed to the full debounce on every notify, but never pushed past the
    # ceiling measured from the FIRST notify of this burst — otherwise a chain
    # under continuous scanning (a notify at least once every debounce_ms)
    # would never evaluate at all.
    remaining_to_ceiling = first_notify_at + state.ceiling_ms - now
    delay = min(state.debounce_ms, max(remaining_to_ceiling, 0))

    timer_ref = Process.send_after(self(), :evaluate, delay)
    %{state | timer_ref: timer_ref, first_notify_at: first_notify_at}
  end

  @impl true
  def handle_info(:evaluate, state) do
    state = %{state | timer_ref: nil, first_notify_at: nil}
    {:noreply, start_evaluation(state)}
  end

  # -- the result --------------------------------------------------------------

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    if state.task_deadline_ref, do: Process.cancel_timer(state.task_deadline_ref)
    state = %{state | task: nil, task_deadline_ref: nil}
    {:noreply, land_result(state, result)}
  end

  # The task crashed outright (not our own :brutal_kill — that path is handled
  # entirely inside Task.shutdown/2 in the timeout handler below and never
  # reaches here). Treated the same as a solver error: keep state, log, emit
  # telemetry, do not alert.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state)
      when is_reference(ref) do
    if state.task_deadline_ref, do: Process.cancel_timer(state.task_deadline_ref)
    state = %{state | task: nil, task_deadline_ref: nil}
    {:noreply, land_result(state, {:error, reason})}
  end

  # A late reply for a task we already shut down or whose deadline already
  # fired for a *different* in-flight task (map restarted evaluation).
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    {:noreply, state}
  end

  # -- the 20s solve deadline ---------------------------------------------------

  # Task.yield(20_000) || Task.shutdown(:brutal_kill) is deliberately NOT used
  # here — see the moduledoc. This handler is the alternative: a self-scheduled
  # message fires the deadline instead of a blocking wait, so the mailbox (and
  # therefore `notify/1`) stays live for the entire 20s.
  def handle_info({:task_timeout, ref}, %{task: %Task{ref: ref}} = state) do
    Task.shutdown(state.task, :brutal_kill)

    Logger.warning(
      "[Discord.RouteWatcher] route solve exceeded #{state.task_timeout_ms}ms for map #{state.map_id}; killed"
    )

    emit_telemetry(state, :timeout)
    state = %{state | task: nil, task_deadline_ref: nil}

    state =
      if state.rerun? do
        start_evaluation(%{state | rerun?: false})
      else
        state
      end

    {:noreply, state}
  end

  # A deadline message for a task that already finished or was already killed —
  # its :task_timeout was cancelled, but cancellation is not guaranteed to beat
  # a message already in the mailbox. Harmless no-op.
  def handle_info({:task_timeout, _stale_ref}, state), do: {:noreply, state}

  # Anything else (stray messages, unexpected sends) — log and keep running
  # rather than crashing this long-lived per-map process, mirroring
  # `Discord.Worker`'s own catch-all (`worker.ex:182-184`).
  def handle_info(msg, state) do
    Logger.debug("[Discord.RouteWatcher] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- launching a solve ------------------------------------------------------

  defp start_evaluation(state) do
    case load_notification(state.map_id) do
      {:ok, notification} -> start_evaluation(state, notification)
      :error -> state
    end
  end

  defp start_evaluation(state, notification) do
    cv = config_version(notification)

    # A config change discards stored state to :unknown rather than comparing
    # against a state that describes a different question ("State identity is
    # versioned by config" in the design doc).
    state =
      if cv != state.config_version do
        %{state | route_state: :unknown, config_version: cv} |> persist()
      else
        state
      end

    if notification.route_alerts_enabled? and not is_nil(notification.home_system_id) do
      launch_task(state, notification)
    else
      # Disabling clears outright. Re-enabling then starts from :none, which
      # the transition table treats identically to :unknown — the next
      # qualifying result posts "opened" either way, so no special case.
      %{state | route_state: :none, config_version: cv, pending_notification: nil}
      |> persist()
    end
  end

  defp launch_task(state, notification) do
    if Process.whereis(WandererApp.ExternalEvents.Discord.TaskSupervisor) do
      task =
        Task.Supervisor.async_nolink(
          WandererApp.ExternalEvents.Discord.TaskSupervisor,
          fn ->
            solver_impl().find_strict(
              notification.map_id,
              [Integer.to_string(Evaluator.jita_system_id())],
              Integer.to_string(notification.home_system_id),
              Evaluator.solver_settings(),
              false
            )
          end
        )

      deadline_ref = Process.send_after(self(), {:task_timeout, task.ref}, state.task_timeout_ms)

      %{
        state
        | task: task,
          task_deadline_ref: deadline_ref,
          rerun?: false,
          pending_notification: notification
      }
    else
      # `Discord.TaskSupervisor` is only started when webhooks are globally
      # enabled (see `application.ex`'s `maybe_start_external_events_services/0`),
      # so a route-alert-enabled map can still land here if that toggle is off
      # or the supervisor hasn't come up yet. Skip this cycle rather than
      # crashing on `Task.Supervisor.async_nolink/2`'s `:noproc` exit — the
      # next `notify/1` will retry via the normal debounce path.
      Logger.warning(
        "[Discord.RouteWatcher] Discord.TaskSupervisor not running; skipping route solve for map #{state.map_id}"
      )

      state
    end
  end

  defp solver_impl,
    do: Application.get_env(:wanderer_app, :route_alert_solver, WandererApp.Map.Routes)

  # Overridable the same way as solver_impl/0, so a test can script a delivery
  # failure (e.g. the general {:error, reason} branch below) without depending
  # on the real WorkerSupervisor's DynamicSupervisor rejecting a start for some
  # reason. Production always uses the real WorkerSupervisor.
  defp worker_supervisor_impl,
    do: Application.get_env(:wanderer_app, :route_alert_worker_supervisor, WorkerSupervisor)

  defp load_notification(map_id) do
    with {:ok, notification} when not is_nil(notification) <-
           MapDiscordNotification.by_map(map_id),
         {:ok, notification} <- Ash.load(notification, :webhooks) do
      {:ok, notification}
    else
      _ -> :error
    end
  end

  defp land_result(state, result) do
    if state.rerun? do
      # A topology change arrived mid-solve: this answer no longer describes
      # the current chain. Discard it and start a fresh solve immediately
      # rather than waiting out another debounce window — the coalescing
      # already happened via the flag.
      start_evaluation(%{state | rerun?: false})
    else
      notification = state.pending_notification
      outcome = Evaluator.evaluate(result, max_jumps: notification.route_max_jumps)
      state = %{state | pending_notification: nil}
      transition(state, notification, outcome)
    end
  end

  # -- the transition table -----------------------------------------------------

  defp transition(state, _notification, :unknown) do
    emit_telemetry(state, :unknown)
    persist(state)
  end

  defp transition(state, _notification, :none) do
    emit_telemetry(state, :none)
    persist(%{state | route_state: :none})
  end

  defp transition(%{route_state: prev} = state, notification, {:qualifying, %{jumps: jumps} = q}) do
    case prev do
      p when p in [:unknown, :none] -> alert(state, notification, :opened, q, jumps, nil)
      {:qualifying, old} when jumps < old -> alert(state, notification, :improved, q, jumps, old)
      {:qualifying, _old} -> persist(%{state | route_state: {:qualifying, jumps}})
    end
  end

  # State is written BEFORE delivery, matching DiscordDispatcher's
  # at-most-once posture (`handle_delivery_result/4`): a delivery failure loses
  # one alert rather than repeating it. `{:error, :not_running}` means nothing
  # was enqueued, so the write is reverted exactly as the dispatcher does.
  # `previous_jumps` is the jump count this route is improving on, and is nil
  # for `:opened` (there is no prior qualifying route to compare against). It
  # exists only so the embed can say "7 → 2 jumps" instead of "2 jumps": the
  # delta is what makes an `:improved` alert worth reading, and the transition
  # table above is the only place that still knows it.
  defp alert(state, notification, kind, qualifying, jumps, previous_jumps) do
    # `state` still carries the PREVIOUS route_state here — captured as
    # `prev_state` before the optimistic write, so a reverted delivery
    # restores exactly what was there before this transition, not the new
    # value we are about to persist.
    prev_state = state
    new_state = persist(%{state | route_state: {:qualifying, jumps}})

    case Router.route_destination(notification) do
      {:ok, webhook} ->
        deliver_alert(
          new_state,
          prev_state,
          notification,
          webhook,
          kind,
          qualifying,
          jumps,
          previous_jumps
        )

      # Also "nothing was enqueued", so it reverts exactly like
      # `deliver_alert/8`'s {:error, :not_running}. Keeping the optimistic
      # write here would mean the same route at the same jump count takes the
      # silent `{:qualifying, _old}` branch forever once the destination is
      # usable again, and is never announced.
      :drop ->
        persist(prev_state)
    end
  end

  defp deliver_alert(
         state,
         prev_state,
         notification,
         webhook,
         kind,
         qualifying,
         jumps,
         previous_jumps
       ) do
    alert = %{
      kind: kind,
      jumps: jumps,
      previous_jumps: previous_jumps,
      path: qualifying.path,
      exit_system: qualifying.exit_system,
      map_id: state.map_id,
      home_system_id: notification.home_system_id
    }

    messages = EmbedFormatter.format_route_alert(alert, mention_targets: webhook.mention_targets)

    case worker_supervisor_impl().deliver(webhook.id, messages) do
      :ok ->
        emit_telemetry(state, kind)
        state

      # Nothing was enqueued: revert the optimistic write to what it was
      # before this transition, mirroring `handle_delivery_result/4`'s
      # `{:error, :not_running}` clause in the dispatcher.
      {:error, :not_running} ->
        persist(%{state | route_state: prev_state.route_state})

      # Any other enqueue failure — mirrors `discord_dispatcher.ex:740`'s
      # catch-all: log and revert the same way, rather than raising a
      # `CaseClauseError` on a reason this `case` didn't anticipate.
      {:error, reason} ->
        Logger.warning(
          "[Discord.RouteWatcher] route alert delivery enqueue failed for map #{state.map_id}: #{inspect(reason)}"
        )

        persist(%{state | route_state: prev_state.route_state})
    end
  end

  defp emit_telemetry(state, outcome) do
    :telemetry.execute(
      [:wanderer_app, :discord, :route_alert],
      %{count: 1},
      %{map_id: state.map_id, outcome: outcome}
    )
  end

  defp persist(state) do
    Cachex.put(@cache, state.map_id, %{
      route_state: state.route_state,
      config_version: state.config_version
    })

    state
  rescue
    _ -> state
  end

  # -- config identity ---------------------------------------------------------

  @doc """
  Hashes the configuration that a stored route_state's meaning depends on.
  A mismatch on rehydrate or on any evaluation means the stored value describes
  a different question, and is discarded rather than compared
  ("State identity is versioned by config" in the design doc).
  """
  @spec config_version(struct()) :: binary()
  def config_version(%{home_system_id: home_system_id, route_max_jumps: route_max_jumps}) do
    {home_system_id, route_max_jumps, Evaluator.solver_settings()}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
