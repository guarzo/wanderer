defmodule WandererApp.ExternalEvents.Discord.RouteWatcherTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.ExternalEvents.Discord.{HttpStub, RouteWatcher, WorkerSupervisor}
  alias WandererAppWeb.Factory

  @jita 30_000_142
  @route_url "https://discord.com/api/webhooks/2/route"

  setup do
    HttpStub.start()
    HttpStub.reset()

    start_supervised!(WorkerSupervisor)

    Application.put_env(
      :wanderer_app,
      :route_alert_solver,
      WandererApp.ExternalEvents.Discord.RouteWatcherTest.StubSolver
    )

    # `:route_alert_stub_result` is read (via Application.get_env, see
    # StubSolver below) from whichever process calls `find_strict/5` — the
    # spawned Task, not this test process — so it must be seeded through
    # Application env, not the test process dictionary, and cleaned up on
    # exit like `:route_alert_solver` or it leaks into the next test in this
    # (async: false) file.
    Application.put_env(
      :wanderer_app,
      :route_alert_stub_result,
      {:ok, %{routes: [], systems_static_data: []}}
    )

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :route_alert_solver)
      Application.delete_env(:wanderer_app, :route_alert_stub_result)
    end)

    attach_route_alert_telemetry()

    map = Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{
        map_id: map.id,
        webhook_url: "https://discord.com/api/webhooks/1/tok"
      })

    {:ok, notification} =
      MapDiscordNotification.update(notification, %{
        route_alerts_enabled?: true,
        home_system_id: 30_000_001,
        route_max_jumps: 5
      })

    # Required, not incidental: `Router.route_destination/1` has no `:system`
    # fallback, so without this row every alert here would take the `:drop`
    # branch and these transition tests would assert nothing.
    {:ok, _route_wh} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :route,
        webhook_url: @route_url
      })

    {:ok, notification} = MapDiscordNotification.by_id(notification.id)

    %{map: map, notification: notification}
  end

  # A deterministic barrier for "the debounce timer that was just armed has
  # fired and any task it launched has finished." `timer_ref` is guaranteed
  # non-nil immediately after `notify/1` returns (the cast is ordered ahead of
  # any subsequent call from this same test process, so it has always already
  # been processed — see the first test below, which asserts this directly),
  # so this predicate cannot be vacuously true before the real cycle runs: it
  # only becomes true once the timer has actually fired AND the resulting
  # task (if any) has actually completed. Checking `task: nil` alone would NOT
  # have this property, since `task` is already nil in the steady state before
  # a notify is even processed.
  defp await_settled(pid) do
    assert :ok = wait_until(fn -> match?(%{task: nil, timer_ref: nil}, :sys.get_state(pid)) end)
  end

  # Proves an alert was (or was not) actually posted, rather than merely
  # inferring it from `route_state` — `emit_telemetry/2` fires exactly once per
  # landed evaluation, tagged with the outcome (`:opened`, `:improved`,
  # `:none`, `:unknown`, or `:timeout`), so `assert_receive`/`refute_receive`
  # against a specific outcome is a direct proof, not a state-shape inference.
  defp attach_route_alert_telemetry do
    test_pid = self()
    handler_id = {:route_alert_telemetry, make_ref()}

    :telemetry.attach(
      handler_id,
      [:wanderer_app, :discord, :route_alert],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:route_alert_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp start_watcher(map_id, opts \\ []) do
    default = [map_id: map_id, debounce_ms: 30, ceiling_ms: 200, task_timeout_ms: 500]

    # start_supervised!/2 returns the child pid directly (not `{:ok, pid}`);
    # wrapped here so every call site can match `{:ok, pid} = start_watcher(...)`.
    # The id includes a fresh reference each call: a test that stops a watcher
    # with a raw `GenServer.stop/2` (rather than `stop_supervised!/1`) leaves its
    # entry registered under ExUnit's own supervisor, and starting a second
    # child for the same map under the SAME id then fails with `:already_present`.
    {:ok,
     start_supervised!({RouteWatcher, Keyword.merge(default, opts)},
       id: {RouteWatcher, map_id, make_ref()}
     )}
  end

  test "a single notify debounces then evaluates once", %{map: map} do
    {:ok, pid} = start_watcher(map.id)
    RouteWatcher.notify(map.id)

    # Immediately after notify the debounce timer is armed but no task has run.
    assert %{task: nil, timer_ref: ref} = :sys.get_state(pid)
    assert is_reference(ref)

    await_settled(pid)
    assert %{route_state: :unknown, timer_ref: nil} = :sys.get_state(pid)
  end

  describe "transitions" do
    setup %{map: map} do
      {:ok, pid} = start_watcher(map.id)
      %{pid: pid}
    end

    # `systems_static_data` must carry a highsec entry for every system on the
    # path — `Evaluator.evaluate/2` (Task 2) is fail-closed and disqualifies a
    # route to `:none` if any hop is missing from it, so an empty list here
    # would never let this stub actually qualify.
    defp qualifying_result(jumps, home) do
      path = [home | Enum.to_list((home + 1)..(home + jumps))]

      {:ok,
       %{
         routes: [
           %{
             has_connection: true,
             systems: Enum.to_list((home + 1)..(home + jumps)),
             origin: home,
             destination: @jita,
             success: true
           }
         ],
         systems_static_data:
           Enum.map(path, &%{solar_system_id: &1, security: 0.9, system_class: 0})
       }}
    end

    test "unknown -> qualifying posts opened", %{map: map, pid: pid} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)

      assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)

      # Proof the alert was actually posted, not just that route_state changed
      # shape: the telemetry event AND a real (stubbed) HTTP delivery both fire.
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}

      assert :ok =
               wait_until(fn ->
                 HttpStub.requests_for(@route_url) != []
               end)
    end

    test "qualifying(4) -> qualifying(2) posts improved", %{map: map, pid: pid} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}

      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(2, 30_000_001)
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)

      assert %{route_state: {:qualifying, 2}} = :sys.get_state(pid)

      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :improved}}

      assert :ok =
               wait_until(fn ->
                 length(HttpStub.requests_for(@route_url)) == 2
               end)
    end

    test "qualifying(2) -> qualifying(4) is silent but still stores 4", %{map: map, pid: pid} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(2, 30_000_001)
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}

      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)

      assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)

      # Silent means neither an :opened/:improved telemetry event nor a second
      # HTTP delivery fires for THIS transition — only the earlier :opened
      # event (already drained above) is on record.
      refute_receive {:route_alert_telemetry, _, %{outcome: :opened}}
      refute_receive {:route_alert_telemetry, _, %{outcome: :improved}}

      assert [_one_request] = HttpStub.requests_for(@route_url)
    end

    test "qualifying(4) -> qualifying(4) is silent", %{map: map, pid: pid} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}

      # Same jump count as before. This pins the equality boundary the
      # "greater" case above cannot: `jumps < old` and `jumps <= old` differ
      # only here, and reading 4 as an improvement over 4 would re-ping on
      # every topology event for as long as the route stays open.
      RouteWatcher.notify(map.id)
      await_settled(pid)

      assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)

      refute_receive {:route_alert_telemetry, _, %{outcome: :opened}}
      refute_receive {:route_alert_telemetry, _, %{outcome: :improved}}

      assert [_one_request] = HttpStub.requests_for(@route_url)
    end

    # A dropped destination is "nothing was enqueued", exactly like
    # `deliver_alert/7`'s {:error, :not_running}. If the optimistic
    # {:qualifying, N} write survives the drop, the SAME route at the SAME jump
    # count takes the silent `{:qualifying, _old}` branch forever after the
    # destination becomes usable again — it is never announced.
    test "a dropped destination does not silence the route once it is usable again",
         %{map: map, notification: notification, pid: pid} do
      {:ok, notification} = Ash.load(notification, :webhooks)
      webhook = Enum.find(notification.webhooks, &(&1.role == :route))
      {:ok, webhook} = WandererApp.Api.MapDiscordWebhook.update(webhook, %{enabled?: false})

      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)

      # Nothing was posted, and nothing was recorded as posted.
      assert [] = HttpStub.requests_for(@route_url)
      refute_receive {:route_alert_telemetry, _, %{outcome: :opened}}
      assert %{route_state: :unknown} = :sys.get_state(pid)

      {:ok, _webhook} = WandererApp.Api.MapDiscordWebhook.update(webhook, %{enabled?: true})

      # Same route, same jump count, same config_version — only the destination
      # changed. It must announce now.
      RouteWatcher.notify(map.id)
      await_settled(pid)

      assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}

      assert :ok =
               wait_until(fn ->
                 HttpStub.requests_for(@route_url) != []
               end)
    end

    test "qualifying -> none clears silently", %{map: map, pid: pid} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}

      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        {:ok,
         %{
           routes: [
             %{
               has_connection: false,
               systems: [],
               origin: 30_000_001,
               destination: @jita,
               success: false
             }
           ],
           systems_static_data: []
         }}
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)

      assert %{route_state: :none} = :sys.get_state(pid)

      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :none}}
      assert [_one_request] = HttpStub.requests_for(@route_url)
    end

    test "a solver error keeps prior state and does not alert", %{map: map, pid: pid} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)
      assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}

      Application.put_env(:wanderer_app, :route_alert_stub_result, {:error, :solver_unreachable})
      RouteWatcher.notify(map.id)
      await_settled(pid)

      assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)

      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :unknown}}
      assert [_one_request] = HttpStub.requests_for(@route_url)
    end

    test "a route_max_jumps change discards the stored state and the next qualifying result opens",
         %{map: map, notification: notification, pid: pid} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)
      assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}

      {:ok, _} = MapDiscordNotification.update(notification, %{route_max_jumps: 2})

      # A stored {:qualifying, 4} against the OLD threshold must not be compared
      # against the new one — it should reset, not silently suppress "opened".
      # `start_evaluation/2` resets AND re-solves in the same pass, so this
      # notify's still-cached 4-jump stub is re-evaluated immediately against
      # the NEW max_jumps of 2 and correctly disqualifies (:none) rather than
      # settling at a bare :unknown — the meaningful assertion is that it is
      # anything other than the stale {:qualifying, 4}.
      RouteWatcher.notify(map.id)
      await_settled(pid)
      assert %{route_state: :none} = :sys.get_state(pid)

      # A genuinely qualifying route under the NEW threshold (2 jumps) is what
      # proves "opened" fires fresh rather than being compared against the
      # discarded {:qualifying, 4}.
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(2, 30_000_001)
      )

      RouteWatcher.notify(map.id)
      await_settled(pid)
      assert %{route_state: {:qualifying, 2}} = :sys.get_state(pid)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}
    end

    test "a notify delivered while a solve is in flight sets rerun? and the stale result is discarded",
         %{map: map, pid: pid} do
      Application.put_env(
        :wanderer_app,
        :route_alert_solver,
        WandererApp.ExternalEvents.Discord.RouteWatcherTest.BlockingSolver
      )

      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      RouteWatcher.notify(map.id)

      # Wait for the debounce timer to fire and the (blocking) task to
      # actually launch — not vacuous, since `task` is nil in the steady state
      # before the debounce elapses, and `BlockingSolver` cannot return on its
      # own to clear it back to nil again.
      assert :ok = wait_until(fn -> match?(%{task: %Task{}}, :sys.get_state(pid)) end)
      assert %{task: %Task{}} = :sys.get_state(pid)

      # THE assertion that fails under Task.yield(20_000): a blocking watcher
      # cannot process this cast at all until the yield times out or returns.
      RouteWatcher.notify(map.id)
      assert %{rerun?: true} = :sys.get_state(pid)

      # Release the blocked task. Its answer must be discarded — a fresh solve
      # starts instead — so route_state must NOT become {:qualifying, 4} from
      # THIS answer. Assert indirectly: after release, a second answer of 2
      # jumps is what should land, proving the first was thrown away.
      Application.put_env(
        :wanderer_app,
        :route_alert_solver,
        WandererApp.ExternalEvents.Discord.RouteWatcherTest.StubSolver
      )

      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(2, 30_000_001)
      )

      %{task: task} = :sys.get_state(pid)
      send(task.pid, :release)

      await_settled(pid)
      assert %{route_state: {:qualifying, 2}, rerun?: false} = :sys.get_state(pid)
    end
  end

  test "the task deadline shuts the task down without crashing the watcher", %{map: map} do
    Application.put_env(
      :wanderer_app,
      :route_alert_solver,
      WandererApp.ExternalEvents.Discord.RouteWatcherTest.BlockingSolver
    )

    {:ok, pid} = start_watcher(map.id, task_timeout_ms: 30)

    RouteWatcher.notify(map.id)

    # debounce_ms (30) + task_timeout_ms (30) = 60ms until the deadline fires.
    # A fixed sleep timed against that sum is an exact tie with process
    # scheduling; `await_settled/1` polls actual state instead, blocking only
    # until the deadline has genuinely fired (checking `task: nil` alone would
    # be vacuously true immediately, since `task` is nil before the debounce
    # elapses too — `timer_ref` is what proves a real cycle actually ran).
    await_settled(pid)
    assert %{task: nil, task_deadline_ref: nil} = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "restart rehydrates from Cachex so a still-open route is not re-announced", %{map: map} do
    Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(4, 30_000_001))
    {:ok, pid} = start_watcher(map.id)
    RouteWatcher.notify(map.id)
    await_settled(pid)
    assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)

    GenServer.stop(pid, :normal)
    {:ok, pid2} = start_watcher(map.id)

    assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid2)
  end

  test "a general delivery failure reverts the optimistic write instead of crashing", %{map: map} do
    Application.put_env(
      :wanderer_app,
      :route_alert_worker_supervisor,
      WandererApp.ExternalEvents.Discord.RouteWatcherTest.FailingWorkerSupervisor
    )

    on_exit(fn -> Application.delete_env(:wanderer_app, :route_alert_worker_supervisor) end)

    Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(4, 30_000_001))
    {:ok, pid} = start_watcher(map.id)

    RouteWatcher.notify(map.id)
    await_settled(pid)

    # The `{:error, :some_other_reason}` catch-all (mirroring
    # `discord_dispatcher.ex:740`) must revert the optimistic write back to the
    # pre-transition state rather than raising a CaseClauseError or leaving the
    # optimistic {:qualifying, 4} write in place despite nothing being sent.
    assert %{route_state: :unknown} = :sys.get_state(pid)

    # No telemetry fires for a failed delivery — only the `:ok` branch of
    # `deliver_alert/7` emits it — so this proves the alert was never actually
    # posted, not merely that route_state reverted.
    refute_receive {:route_alert_telemetry, _, %{outcome: :opened}}
    refute_receive {:route_alert_telemetry, _, %{outcome: :improved}}

    assert Process.alive?(pid)
  end
end

defmodule WandererApp.ExternalEvents.Discord.RouteWatcherTest.StubSolver do
  @moduledoc """
  Stands in for `WandererApp.Map.Routes.find_strict/5`. Reads its canned answer
  from `Application.get_env/3` rather than the process dictionary: it runs
  inside the Task the watcher spawns, not the test process, so a
  process-dictionary value seeded by the test would not be visible here. Tests
  seed and mutate it with `Application.put_env/3` between phases of a single
  test; it is read once per call.
  """
  def find_strict(_map_id, _hubs, _origin, _settings, _hubs_limit_reached?) do
    Application.get_env(
      :wanderer_app,
      :route_alert_stub_result,
      {:ok, %{routes: [], systems_static_data: []}}
    )
  end
end

defmodule WandererApp.ExternalEvents.Discord.RouteWatcherTest.BlockingSolver do
  @moduledoc "Blocks until released via a message to the task's own pid, then returns the seeded result."
  def find_strict(map_id, hubs, origin, settings, hubs_limit_reached?) do
    receive do
      :release -> :ok
    end

    WandererApp.ExternalEvents.Discord.RouteWatcherTest.StubSolver.find_strict(
      map_id,
      hubs,
      origin,
      settings,
      hubs_limit_reached?
    )
  end
end

defmodule WandererApp.ExternalEvents.Discord.RouteWatcherTest.FailingWorkerSupervisor do
  @moduledoc """
  Stands in for `WorkerSupervisor` to script a delivery-enqueue failure whose
  reason is something other than `:not_running` — exercising `deliver_alert/7`'s
  general `{:error, reason}` catch-all, which the real `WorkerSupervisor` has no
  practical, deterministic way to trigger from a test (its only non-`:ok` return
  values are `:not_running` or a `DynamicSupervisor.start_child/2` failure that
  would otherwise require sabotaging the shared supervision tree).
  """
  def deliver(_webhook_id, _messages), do: {:error, :some_other_reason}
end
