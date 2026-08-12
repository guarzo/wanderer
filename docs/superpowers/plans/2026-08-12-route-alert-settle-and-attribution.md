# Route Alert Settle Delay and Scout Attribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hold a qualifying route alert for 2 minutes and re-solve before publishing, so user-entered connection labels have caught up before the embed's safety footer claims them — and credit the character whose recent add opened the route, with their portrait in the embed.

**Architecture:** The hold is a second timer in `Discord.RouteWatcher`'s existing state machine, placed at the transition point rather than in the debounce, plus an explicit restatement of the watcher's implicit one-solve-at-a-time invariant. Attribution is a new read-only module, `Discord.RouteScout`, that resolves a character from the `user_activity_v1` audit trail and hands it to `EmbedFormatter` through the alert map.

**Tech Stack:** Elixir/Phoenix, Ash Framework (AshPostgres), ExUnit, Cachex, Telemetry.

## Global Constraints

- Design doc: `docs/superpowers/specs/2026-08-12-route-alert-settle-and-attribution-design.md`. Read it before starting; it carries the reasoning this plan only cites.
- **Do not change `@route_guarantee`** in `embed_formatter.ex:72`, `route_guarantee_settings/0`, or anything in `WandererApp.Map.RouteAlert.Evaluator`. The footer wording is deliberately unchanged — the delay is what makes it true.
- **Do not bypass `UpdateCoordinator`** or add broadcasts. Nothing in this work writes map state.
- Use **Ash actions**, never raw Ecto queries. Every action callable from application code needs a `define(...)` entry in the resource's `code_interface` block.
- Attribution is **best-effort**: every failure path must fall back to the plain author line and still deliver the alert. An attribution failure must never raise into the watcher.
- Settle window: **2 minutes** (`@settle_ms 120_000`). Attribution window: **15 minutes** (`@attribution_window_ms 900_000`).
- Run `mix format` before every commit. Run `mix credo` before the final commit.
- Baseline before starting: `mix test test/unit/external_events/discord/ test/unit/map/route_alert/` → **345 tests, 0 failures**.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/wanderer_app/external_events/discord/route_watcher.ex` | Modify — adds the settle hold and the one-solve guard to the existing per-map GenServer. |
| `lib/wanderer_app/api/user_activity.ex` | Modify — adds one read action + `code_interface` entry for the attribution lookup. |
| `lib/wanderer_app/external_events/discord/route_scout.ex` | Create — resolves the crediting character from the audit trail. Read-only, total, no raising. |
| `lib/wanderer_app/external_events/discord/embed_formatter.ex` | Modify — author line gains the scout's name and portrait. |
| `test/unit/external_events/discord/route_watcher_test.exs` | Modify — harness gains `settle_ms`, `await_settled/1` waits through both cycles, plus new hold tests. |
| `test/unit/external_events/discord/route_scout_test.exs` | Create — attribution resolution and every fallback. |
| `test/unit/external_events/discord/embed_formatter_test.exs` | Modify — author line with and without a scout. |

Task order: the settle hold (Tasks 1–2) is the bug fix and ships alone. Attribution (Tasks 3–6) builds bottom-up behind it and is independently revertible.

---

### Task 1: Settle hold in `RouteWatcher`

**Files:**
- Modify: `lib/wanderer_app/external_events/discord/route_watcher.ex`
- Test: `test/unit/external_events/discord/route_watcher_test.exs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `RouteWatcher` accepts a `settle_ms: pos_integer()` option in `start_link/1` opts (alongside the existing `debounce_ms`, `ceiling_ms`, `task_timeout_ms`). State gains `settle_ref :: reference() | nil` and `settle_confirmed? :: boolean()`. A new telemetry outcome `:held` is emitted on `[:wanderer_app, :discord, :route_alert]`.

- [ ] **Step 1: Update the test harness so existing tests exercise the hold**

Two changes in `test/unit/external_events/discord/route_watcher_test.exs`.

Add `settle_ms: 20` to the defaults in `start_watcher/2` (currently line 109):

```elixir
  defp start_watcher(map_id, opts \\ []) do
    default = [
      map_id: map_id,
      debounce_ms: 30,
      ceiling_ms: 200,
      task_timeout_ms: 500,
      settle_ms: 20
    ]
```

Extend `await_settled/1` (currently line 83) to wait through **both** evaluation cycles, and replace its comment:

```elixir
  # A deterministic barrier for "every evaluation this notify will cause has
  # finished." A qualifying transition now runs TWO evaluations: the first
  # arms the settle timer and publishes nothing, the second (after the timer
  # fires) publishes. Waiting on `task: nil, timer_ref: nil` alone would
  # return in the gap between them, before the alert exists.
  #
  # The three-key predicate cannot be vacuously true mid-cycle: between the
  # two evaluations `settle_ref` is non-nil, and during the second `task` is
  # non-nil. A non-qualifying outcome arms no settle timer, so it still
  # settles after one cycle.
  defp await_settled(pid) do
    assert :ok =
             wait_until(fn ->
               match?(%{task: nil, timer_ref: nil, settle_ref: nil}, :sys.get_state(pid))
             end)
  end
```

- [ ] **Step 2: Write the failing tests for the hold**

Add this describe block to `test/unit/external_events/discord/route_watcher_test.exs`, immediately after the existing `describe "transitions"` block closes. It reuses that block's `qualifying_result/2` helper, which is a module-level `defp` and therefore in scope.

```elixir
  describe "settle hold" do
    setup %{map: map} do
      {:ok, pid} = start_watcher(map.id, settle_ms: 10_000)
      %{pid: pid}
    end

    test "a qualifying transition holds instead of publishing", %{map: map, pid: pid} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      RouteWatcher.notify(map.id)

      # The first evaluation lands, arms the hold, and publishes nothing.
      assert :ok =
               wait_until(fn ->
                 match?(%{task: nil, timer_ref: nil, settle_ref: r} when is_reference(r),
                   :sys.get_state(pid)
                 )
               end)

      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :held}}
      refute_receive {:route_alert_telemetry, _, %{outcome: :opened}}, 100

      # route_state is NOT optimistically advanced during the hold.
      assert %{route_state: :unknown, settle_confirmed?: false} = :sys.get_state(pid)
      assert HttpStub.requests_for(@route_url) == []
    end

    test "the held alert publishes when the window elapses", %{map: map} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      {:ok, pid} = start_watcher(map.id, settle_ms: 20)
      RouteWatcher.notify(map.id)
      await_settled(pid)

      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}
      assert %{route_state: {:qualifying, 4}, settle_confirmed?: false} = :sys.get_state(pid)

      assert :ok = wait_until(fn -> HttpStub.requests_for(@route_url) != [] end)
    end

    # The reported bug: a hole marked crit during the hold must cancel the
    # alert entirely, not publish a corrected one.
    test "a route that stops qualifying during the hold publishes nothing", %{map: map} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      {:ok, pid} = start_watcher(map.id, settle_ms: 100)
      RouteWatcher.notify(map.id)

      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :held}}

      # The label lands: the solver now disqualifies the route.
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        {:ok, %{routes: [%{has_connection: false, systems: [], origin: 30_000_001,
                           destination: @jita, success: false}],
                systems_static_data: []}}
      )

      await_settled(pid)

      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :none}}
      refute_receive {:route_alert_telemetry, _, %{outcome: :opened}}, 100
      assert HttpStub.requests_for(@route_url) == []
    end

    test "an improved transition holds on the same rule", %{map: map} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      {:ok, pid} = start_watcher(map.id, settle_ms: 20)
      RouteWatcher.notify(map.id)
      await_settled(pid)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}

      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(2, 30_000_001)
      )

      RouteWatcher.notify(map.id)

      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :held}}
      await_settled(pid)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :improved}}
    end

    # Re-arming on every notify would starve a continuously-scanned chain of
    # alerts entirely — the failure @ceiling_ms already exists to prevent.
    test "notifies during the hold neither publish early nor extend it", %{map: map} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      {:ok, pid} = start_watcher(map.id, settle_ms: 250)
      RouteWatcher.notify(map.id)

      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :held}}
      %{settle_ref: original} = :sys.get_state(pid)

      RouteWatcher.notify(map.id)
      assert :ok = wait_until(fn -> match?(%{task: nil, timer_ref: nil}, :sys.get_state(pid)) end)

      # Same timer, so the original deadline still governs.
      assert %{settle_ref: ^original} = :sys.get_state(pid)
      assert HttpStub.requests_for(@route_url) == []

      await_settled(pid)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}
    end

    # Losing a confirmation must re-hold, never publish unheld.
    test "disabling route alerts mid-hold cancels it", %{map: map, notification: notification} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      {:ok, pid} = start_watcher(map.id, settle_ms: 100)
      RouteWatcher.notify(map.id)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :held}}

      {:ok, _} = MapDiscordNotification.update(notification, %{route_alerts_enabled?: false})

      RouteWatcher.notify(map.id)
      await_settled(pid)

      assert %{settle_ref: nil, settle_confirmed?: false, route_state: :none} =
               :sys.get_state(pid)

      refute_receive {:route_alert_telemetry, _, %{outcome: :opened}}, 200
      assert HttpStub.requests_for(@route_url) == []
    end

    # The invariant "one solve at a time" was implicit; the settle timer is a
    # second path into start_evaluation/1 and must not break it.
    test "a notify landing just before the settle fires does not double-solve", %{map: map} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      {:ok, pid} = start_watcher(map.id, settle_ms: 60, debounce_ms: 50)
      RouteWatcher.notify(map.id)
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :held}}

      # Arms a debounce timer that would otherwise still be pending when
      # :settle fires and launches its own solve.
      RouteWatcher.notify(map.id)
      await_settled(pid)

      # Exactly one alert, and no orphaned timer left behind.
      assert_receive {:route_alert_telemetry, %{count: 1}, %{outcome: :opened}}
      refute_receive {:route_alert_telemetry, _, %{outcome: :opened}}, 200
      assert %{task: nil, timer_ref: nil, settle_ref: nil} = :sys.get_state(pid)
    end
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/unit/external_events/discord/route_watcher_test.exs`

Expected: FAIL. The new `describe "settle hold"` tests fail on the unknown `settle_ms` option and the missing `settle_ref` state key; several pre-existing tests may also fail once `await_settled/1` requires `settle_ref`, because that key does not exist yet.

- [ ] **Step 4: Add the state keys and the settle option**

In `lib/wanderer_app/external_events/discord/route_watcher.ex`, add the module attribute next to the existing timing constants (currently near line 58):

```elixir
  @debounce_ms 10_000
  @ceiling_ms 60_000
  @task_timeout_ms 20_000

  # How long a qualifying transition waits before it is re-solved and
  # published. The connection labels the embed's footer claims (crit, EOL,
  # frigate) are user-entered and default permissive, so an alert sent the
  # instant a route qualifies routinely promises "no crit" about a hole that
  # is seconds away from being marked crit. Waiting lets the label land; the
  # re-solve then drops the route and no alert is sent at all.
  #
  # This is NOT the debounce. @debounce_ms coalesces notifications; this waits
  # on a human. Lengthening the debounce instead would delay the solve and
  # still read stale labels when it ran.
  @settle_ms 120_000
```

Extend the state map in `init/1` (currently near line 84):

```elixir
      rerun?: false,
      pending_notification: nil,
      settle_ref: nil,
      settle_confirmed?: false,
      debounce_ms: Keyword.get(opts, :debounce_ms, @debounce_ms),
      ceiling_ms: Keyword.get(opts, :ceiling_ms, @ceiling_ms),
      settle_ms: Keyword.get(opts, :settle_ms, @settle_ms),
      task_timeout_ms: Keyword.get(opts, :task_timeout_ms, @task_timeout_ms)
```

- [ ] **Step 5: Add the `:settle` handler and the `:evaluate` guard**

Replace the existing `handle_info(:evaluate, state)` clause (currently line 146-149) with a guarded pair, and add the `:settle` handler directly after it:

```elixir
  # Guards the "one solve at a time" invariant explicitly. Today it holds
  # implicitly: `arm_timer/1` is only reachable from the `task == nil` clause
  # of `handle_cast(:notify, ...)`, so an :evaluate can never be pending while
  # a task runs. The settle timer is a SECOND path into `start_evaluation/1`,
  # so that reasoning no longer covers every case — without this clause a
  # notify shortly before :settle launches a second task, and `launch_task/2`
  # overwrites `task` and `task_deadline_ref`, orphaning the first.
  #
  # A no-op for today's behaviour, and deliberately mirrors what
  # `handle_cast(:notify, ...)` already does in the same situation.
  def handle_info(:evaluate, %{task: task} = state) when not is_nil(task) do
    {:noreply, %{state | timer_ref: nil, first_notify_at: nil, rerun?: true}}
  end

  def handle_info(:evaluate, state) do
    state = %{state | timer_ref: nil, first_notify_at: nil}
    {:noreply, start_evaluation(state)}
  end

  # The settle window has elapsed: re-solve, and let this evaluation publish.
  # Any pending debounce timer is cancelled first — its :evaluate would
  # otherwise fire mid-solve and be demoted to a rerun, which is correct but
  # wasteful, and leaves a stale `first_notify_at` skewing the next ceiling.
  def handle_info(:settle, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    state = %{
      state
      | settle_ref: nil,
        timer_ref: nil,
        first_notify_at: nil,
        settle_confirmed?: true
    }

    if state.task do
      {:noreply, %{state | rerun?: true}}
    else
      {:noreply, start_evaluation(state)}
    end
  end
```

- [ ] **Step 6: Route the qualifying transitions through the hold**

Replace the transition table's three clauses (currently lines 331-348) with:

```elixir
  defp transition(state, _notification, :unknown) do
    emit_telemetry(state, :unknown)
    persist(clear_settle(state))
  end

  defp transition(state, _notification, :none) do
    emit_telemetry(state, :none)
    persist(%{clear_settle(state) | route_state: :none})
  end

  defp transition(%{route_state: prev} = state, notification, {:qualifying, %{jumps: jumps} = q}) do
    case prev do
      p when p in [:unknown, :none] -> maybe_alert(state, notification, :opened, q, jumps, nil)
      {:qualifying, old} when jumps < old -> maybe_alert(state, notification, :improved, q, jumps, old)
      {:qualifying, _old} -> persist(%{clear_settle(state) | route_state: {:qualifying, jumps}})
    end
  end

  # The settle gate. An unconfirmed transition arms the hold and publishes
  # nothing — deliberately WITHOUT the optimistic `persist/1` that `alert/6`
  # does, so `route_state` keeps its previous value and there is nothing to
  # revert if the route stops qualifying before the window elapses.
  defp maybe_alert(%{settle_confirmed?: true} = state, notification, kind, q, jumps, previous) do
    alert(clear_settle(state), notification, kind, q, jumps, previous)
  end

  defp maybe_alert(state, _notification, _kind, _q, _jumps, _previous) do
    emit_telemetry(state, :held)
    arm_settle(state)
  end

  # Armed once per hold and never re-armed. Re-arming on each intervening
  # notify would starve a chain under continuous scanning of alerts entirely —
  # the same failure `@ceiling_ms` exists to prevent on the debounce.
  defp arm_settle(%{settle_ref: ref} = state) when not is_nil(ref), do: state

  defp arm_settle(state) do
    %{state | settle_ref: Process.send_after(self(), :settle, state.settle_ms)}
  end

  # Called on every path that consumes or abandons a hold without publishing.
  # A confirmation that survives into a later, unrelated transition would let
  # that one publish with no hold of its own — silently reintroducing the bug
  # this whole mechanism exists to fix.
  defp clear_settle(state) do
    if state.settle_ref, do: Process.cancel_timer(state.settle_ref)
    %{state | settle_ref: nil, settle_confirmed?: false}
  end
```

- [ ] **Step 7: Clear the flag on the three early-return paths**

These return before reaching `transition/3`, so the gate above never sees them.

In `start_evaluation/1` (currently line 221-226):

```elixir
  defp start_evaluation(state) do
    case load_notification(state.map_id) do
      {:ok, notification} -> start_evaluation(state, notification)
      # The confirmation is lost and the route is simply re-held on the next
      # notify: a late alert, never an unheld one.
      :error -> clear_settle(state)
    end
  end
```

In `start_evaluation/2`, the config-change and disabled branches (currently lines 232-247):

```elixir
    state =
      if cv != state.config_version do
        %{clear_settle(state) | route_state: :unknown, config_version: cv} |> persist()
      else
        state
      end

    if notification.route_alerts_enabled? and not is_nil(notification.home_system_id) do
      launch_task(state, notification)
    else
      %{clear_settle(state) | route_state: :none, config_version: cv, pending_notification: nil}
      |> persist()
    end
```

In `launch_task/2`'s missing-supervisor branch (currently line 272-281), change the trailing `state` to `clear_settle(state)`:

```elixir
      Logger.warning(
        "[Discord.RouteWatcher] Discord.TaskSupervisor not running; skipping route solve for map #{state.map_id}"
      )

      clear_settle(state)
```

In the `:task_timeout` handler (currently lines 187-205), replace the rerun branch:

```elixir
    state =
      if state.rerun? do
        start_evaluation(%{state | rerun?: false})
      else
        clear_settle(state)
      end
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `mix test test/unit/external_events/discord/route_watcher_test.exs`
Expected: PASS, all tests.

If a pre-existing transition test fails on a missing `:opened` telemetry event, the cause is almost certainly `await_settled/1` — confirm Step 1's three-key version was applied. Note that a preceding `:held` event does **not** break existing `assert_receive` calls, which scan the mailbox for a match rather than reading the next message.

- [ ] **Step 9: Run the full Discord and route-alert suites**

Run: `mix test test/unit/external_events/discord/ test/unit/map/route_alert/`
Expected: PASS, 0 failures. Test count is above the 345 baseline by the 7 tests added in Step 2.

- [ ] **Step 10: Format and commit**

```bash
mix format
git add lib/wanderer_app/external_events/discord/route_watcher.ex test/unit/external_events/discord/route_watcher_test.exs
git commit -m "fix(route-alerts): hold a qualifying route 2 minutes and re-solve before posting

The footer's crit/EOL/frigate guarantee describes user-entered labels with
permissive defaults, so an alert sent the instant a route qualifies routinely
promises 'no crit' about a hole nobody has assessed yet. Hold the transition,
re-solve, and publish only if it still qualifies."
```

---

### Task 2: `UserActivity` read action for attribution candidates

**Files:**
- Modify: `lib/wanderer_app/api/user_activity.ex`
- Test: `test/unit/external_events/discord/route_scout_test.exs` (created here, extended in Task 3)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `WandererApp.Api.UserActivity.read_route_attribution(%{map_id: binary(), since: DateTime.t(), system_event_data: [binary()], connection_event_data: [binary()]})` returning `{:ok, [%UserActivity{}]}` with at most one element, `:character` loaded.

- [ ] **Step 1: Write the failing test**

Create `test/unit/external_events/discord/route_scout_test.exs`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.RouteScoutTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.UserActivity
  alias WandererAppWeb.Factory

  @home 31_000_005
  @wh_hop 31_000_006
  @exit_system 30_002_053

  setup do
    user = Factory.insert(:user, %{})
    character = Factory.insert(:character, %{user_id: user.id, name: "Kraven Ordos"})
    map = Factory.insert(:map, %{})

    %{user: user, character: character, map: map}
  end

  # Written through the REAL tracker, not a hand-built event_data string.
  # `SecurityAudit.sanitize_metadata/1` stringifies keys before
  # `Jason.encode!/1`, so a hand-written fixture could agree with the lookup
  # while both disagree with production. Going through the tracker pins the
  # encoding end to end.
  defp track_system_added(map, character, user, solar_system_id) do
    {:ok, _} =
      WandererApp.User.ActivityTracker.track_map_event(:system_added, %{
        character_id: character.id,
        user_id: user.id,
        map_id: map.id,
        solar_system_id: solar_system_id
      })

    :ok
  end

  describe "read_route_attribution" do
    test "finds a system_added row for a system on the path", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @wh_hop)

      {:ok, [activity]} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), -900, :second),
          system_event_data: [Jason.encode!(%{"solar_system_id" => @wh_hop})],
          connection_event_data: []
        })

      assert activity.character.name == "Kraven Ordos"
    end

    test "ignores rows older than the since bound", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @wh_hop)

      {:ok, []} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), 60, :second),
          system_event_data: [Jason.encode!(%{"solar_system_id" => @wh_hop})],
          connection_event_data: []
        })
    end

    test "ignores rows belonging to another map", ctx do
      other_map = Factory.insert(:map, %{})
      :ok = track_system_added(other_map, ctx.character, ctx.user, @wh_hop)

      {:ok, []} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), -900, :second),
          system_event_data: [Jason.encode!(%{"solar_system_id" => @wh_hop})],
          connection_event_data: []
        })
    end

    test "returns only the newest of several candidates", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @home)
      Process.sleep(5)
      other = Factory.insert(:character, %{user_id: ctx.user.id, name: "Later Scout"})
      :ok = track_system_added(ctx.map, other, ctx.user, @exit_system)

      {:ok, [activity]} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), -900, :second),
          system_event_data: [
            Jason.encode!(%{"solar_system_id" => @home}),
            Jason.encode!(%{"solar_system_id" => @exit_system})
          ],
          connection_event_data: []
        })

      assert activity.character.name == "Later Scout"
    end

    # A one-system path produces no adjacent pairs. Ecto renders `in ^[]` as a
    # false literal rather than invalid `IN ()` SQL, and this pins that.
    test "tolerates an empty candidate list on either side", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @wh_hop)

      {:ok, [_]} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), -900, :second),
          system_event_data: [Jason.encode!(%{"solar_system_id" => @wh_hop})],
          connection_event_data: []
        })

      {:ok, []} =
        UserActivity.read_route_attribution(%{
          map_id: ctx.map.id,
          since: DateTime.add(DateTime.utc_now(), -900, :second),
          system_event_data: [],
          connection_event_data: []
        })
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord/route_scout_test.exs`
Expected: FAIL with `UndefinedFunctionError` for `UserActivity.read_route_attribution/1`.

- [ ] **Step 3: Add the read action**

In `lib/wanderer_app/api/user_activity.ex`, add to the `code_interface` block (after `define(:new, action: :new)`):

```elixir
    define(:read_route_attribution, action: :read_route_attribution)
```

And add the action to the `actions` block, after the existing `create :new`:

```elixir
    # Attribution lookup for Discord route alerts: the newest add event that
    # could have opened a given route, inside a recency window.
    #
    # Both add event types are candidates because a route can open without any
    # system being added — `DiscordDispatcher.do_dispatch/2` re-evaluates on
    # :connection_added and :connection_updated too, so crediting the newest
    # system on the path would regularly name someone who did nothing.
    #
    # `event_data` is matched exactly rather than with a LIKE: the encoding is
    # deterministic (`SecurityAudit.track_map_event/2` drops character_id,
    # user_id and map_id, then `sanitize_metadata/1` stringifies the remaining
    # keys before `Jason.encode!/1`), so callers can reproduce it byte for byte.
    #
    # No pagination, unlike the primary `:read` — this always wants exactly the
    # top row. The `entity_id, event_type` prefix of the
    # [:entity_id, :event_type, :inserted_at] index serves the filter.
    read :read_route_attribution do
      argument(:map_id, :string, allow_nil?: false)
      argument(:since, :utc_datetime_usec, allow_nil?: false)
      argument(:system_event_data, {:array, :string}, allow_nil?: false)
      argument(:connection_event_data, {:array, :string}, allow_nil?: false)

      filter(
        expr(
          entity_type == :map and entity_id == ^arg(:map_id) and
            inserted_at >= ^arg(:since) and
            ((event_type == :system_added and event_data in ^arg(:system_event_data)) or
               (event_type == :map_connection_added and
                  event_data in ^arg(:connection_event_data)))
        )
      )

      prepare(build(sort: [inserted_at: :desc], limit: 1, load: [:character]))
    end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord/route_scout_test.exs`
Expected: PASS, 5 tests.

If "finds a system_added row" fails while the others pass, the encoding assumption is wrong — inspect the stored value directly and correct the test's expected string plus Task 3's encoder to match:

```bash
mix run -e 'IO.inspect(Ash.read!(WandererApp.Api.UserActivity) |> Enum.map(& &1.event_data))'
```

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/wanderer_app/api/user_activity.ex test/unit/external_events/discord/route_scout_test.exs
git commit -m "feat(route-alerts): add UserActivity read action for route attribution"
```

---

### Task 3: `Discord.RouteScout`

**Files:**
- Create: `lib/wanderer_app/external_events/discord/route_scout.ex`
- Test: `test/unit/external_events/discord/route_scout_test.exs` (extend)

**Interfaces:**
- Consumes: `UserActivity.read_route_attribution/1` from Task 2.
- Produces: `WandererApp.ExternalEvents.Discord.RouteScout.resolve(map_id :: binary(), path :: [integer()]) :: %{name: String.t(), eve_id: String.t()} | nil`.

- [ ] **Step 1: Write the failing tests**

Append this describe block to `test/unit/external_events/discord/route_scout_test.exs`, and add `alias WandererApp.ExternalEvents.Discord.RouteScout` to the aliases at the top:

```elixir
  describe "resolve/2" do
    defp track_connection_added(map, character, user, source, target) do
      {:ok, _} =
        WandererApp.User.ActivityTracker.track_map_event(:map_connection_added, %{
          character_id: character.id,
          user_id: user.id,
          map_id: map.id,
          solar_system_source_id: source,
          solar_system_target_id: target
        })

      :ok
    end

    test "credits the character who added a system on the path", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @wh_hop)

      assert %{name: "Kraven Ordos", eve_id: eve_id} =
               RouteScout.resolve(ctx.map.id, [@home, @wh_hop, @exit_system])

      assert eve_id == ctx.character.eve_id
    end

    test "credits the character who added a connection on the path", ctx do
      :ok = track_connection_added(ctx.map, ctx.character, ctx.user, @home, @wh_hop)

      assert %{name: "Kraven Ordos"} =
               RouteScout.resolve(ctx.map.id, [@home, @wh_hop, @exit_system])
    end

    # The recorded source/target follow the direction the character jumped,
    # which need not match the direction the solved route runs.
    test "matches a connection recorded in the reverse orientation", ctx do
      :ok = track_connection_added(ctx.map, ctx.character, ctx.user, @wh_hop, @home)

      assert %{name: "Kraven Ordos"} =
               RouteScout.resolve(ctx.map.id, [@home, @wh_hop, @exit_system])
    end

    test "does not credit a non-adjacent pair", ctx do
      :ok = track_connection_added(ctx.map, ctx.character, ctx.user, @home, @exit_system)

      assert RouteScout.resolve(ctx.map.id, [@home, @wh_hop, @exit_system]) == nil
    end

    test "returns nil when nothing recent explains the route", ctx do
      # No activity at all: the transition came from a :connection_updated
      # label edit, which credits nobody.
      assert RouteScout.resolve(ctx.map.id, [@home, @wh_hop, @exit_system]) == nil
    end

    test "returns nil for an unknown map", ctx do
      :ok = track_system_added(ctx.map, ctx.character, ctx.user, @wh_hop)
      assert RouteScout.resolve(Ecto.UUID.generate(), [@home, @wh_hop]) == nil
    end

    test "returns nil for a degenerate path or bad map id", ctx do
      assert RouteScout.resolve(ctx.map.id, []) == nil
      assert RouteScout.resolve(nil, [@home, @wh_hop]) == nil
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/unit/external_events/discord/route_scout_test.exs`
Expected: FAIL with `UndefinedFunctionError` for `RouteScout.resolve/2`.

- [ ] **Step 3: Write the implementation**

Create `lib/wanderer_app/external_events/discord/route_scout.ex`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.RouteScout do
  @moduledoc """
  Resolves the character to credit on a route alert, from the map audit trail.

  ## Why the audit trail and not `MapSystem`

  `MapSystem` cannot answer "who added this, and when". `added_at` is written
  by nothing in `lib/` (and is in `default_accept`, so an API caller could set
  it to anything); `inserted_at` records the first-ever add, because `:upsert`
  reuses the row via `upsert_identity :map_solar_system_id`; `updated_at`
  tracks any edit at all; and there is no character relationship on the
  resource. The `user_activity_v1` rows are the only record carrying a map
  change and its author together.

  ## Why recency, and why both event types

  Route alerts are re-evaluated on five event types
  (`DiscordDispatcher.do_dispatch/2`), only two of which are adds. A route can
  open because someone cleared a crit label on an existing connection, or
  linked two systems mapped hours ago. Crediting "the newest system on the
  path" would then put a name and a portrait on work that person did not do,
  in a channel their corp reads — so the winning row must be an *add*, and it
  must be recent. Nothing recent enough means nobody is named.

  ## Best-effort by construction

  Every failure returns `nil` and the alert posts with its plain author line.
  This module must never raise into `RouteWatcher`: an attribution problem is
  not worth losing a delivery over.
  """

  require Logger

  alias WandererApp.Api.UserActivity

  @attribution_window_ms 15 * 60 * 1000

  @type scout :: %{name: String.t(), eve_id: String.t()}

  @spec attribution_window_ms() :: pos_integer()
  def attribution_window_ms, do: @attribution_window_ms

  @spec resolve(binary(), [integer()]) :: scout() | nil
  def resolve(map_id, path) when is_binary(map_id) and is_list(path) and path != [] do
    since = DateTime.add(DateTime.utc_now(), -@attribution_window_ms, :millisecond)

    case UserActivity.read_route_attribution(%{
           map_id: map_id,
           since: since,
           system_event_data: system_event_data(path),
           connection_event_data: connection_event_data(path)
         }) do
      {:ok, [%{character: %{name: name, eve_id: eve_id}}]}
      when is_binary(name) and is_binary(eve_id) ->
        %{name: name, eve_id: eve_id}

      # No row, a row whose character_id was nil (systems added through the API
      # record no character — `SecurityAudit.track_map_event/2` no-ops without
      # both character_id and user_id), or a deleted character.
      _ ->
        nil
    end
  rescue
    error ->
      Logger.debug(fn ->
        "[RouteScout] attribution lookup failed for map #{inspect(map_id)}: #{inspect(error)}"
      end)

      nil
  end

  def resolve(_map_id, _path), do: nil

  # String keys, matching what is actually stored: `sanitize_metadata/1`
  # stringifies every key before `Jason.encode!/1`. Two maps with identical key
  # sets encode to identical JSON, which is what makes an exact match sound.
  defp system_event_data(path) do
    Enum.map(path, &Jason.encode!(%{"solar_system_id" => &1}))
  end

  # Both orientations per adjacent pair: the recorded source/target follow the
  # direction the character jumped, not the direction the solved route runs.
  defp connection_event_data(path) do
    path
    |> Enum.zip(Enum.drop(path, 1))
    |> Enum.flat_map(fn {a, b} ->
      [
        Jason.encode!(%{"solar_system_source_id" => a, "solar_system_target_id" => b}),
        Jason.encode!(%{"solar_system_source_id" => b, "solar_system_target_id" => a})
      ]
    end)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/unit/external_events/discord/route_scout_test.exs`
Expected: PASS, 12 tests.

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/wanderer_app/external_events/discord/route_scout.ex test/unit/external_events/discord/route_scout_test.exs
git commit -m "feat(route-alerts): resolve the crediting character from the audit trail"
```

---

### Task 4: Scout in the embed author line

**Files:**
- Modify: `lib/wanderer_app/external_events/discord/embed_formatter.ex`
- Test: `test/unit/external_events/discord/embed_formatter_test.exs`

**Interfaces:**
- Consumes: the `%{name: String.t(), eve_id: String.t()}` shape produced by `RouteScout.resolve/2` (Task 3) — but only as data on the alert map, with no compile-time dependency.
- Produces: `format_route_alert/2` reads an optional `:scout` key on the alert map. Absent or `nil` renders today's plain author line.

- [ ] **Step 1: Write the failing tests**

Add to `test/unit/external_events/discord/embed_formatter_test.exs`, inside the existing `describe "format_route_alert/2"` block in `EmbedFormatterRouteAlertTest`:

```elixir
    test "an alert with no scout renders the plain author line", %{alert: alert} do
      [%{"embeds" => [embed]}] = EmbedFormatter.format_route_alert(alert, [])

      assert embed["author"] == %{"name" => "Route opened"}
    end

    test "a scouted alert names the character and shows their portrait", %{alert: alert} do
      scouted = Map.put(alert, :scout, %{name: "Kraven Ordos", eve_id: "2112625428"})

      [%{"embeds" => [embed]}] = EmbedFormatter.format_route_alert(scouted, [])

      assert embed["author"] == %{
               "name" => "Route opened · scouted by Kraven Ordos",
               "icon_url" =>
                 "https://images.evetech.net/characters/2112625428/portrait?size=64"
             }
    end

    test "a scouted shortened alert uses its own kind label", %{alert: alert} do
      scouted =
        alert
        |> Map.merge(%{kind: :improved, previous_jumps: 7})
        |> Map.put(:scout, %{name: "Kraven Ordos", eve_id: "2112625428"})

      [%{"embeds" => [embed]}] = EmbedFormatter.format_route_alert(scouted, [])

      assert embed["author"]["name"] == "Route shortened · scouted by Kraven Ordos"
    end

    test "an explicit nil scout renders the plain author line", %{alert: alert} do
      [%{"embeds" => [embed]}] =
        EmbedFormatter.format_route_alert(Map.put(alert, :scout, nil), [])

      assert embed["author"] == %{"name" => "Route opened"}
    end

    # Discord rejects an author name over 256 characters with a 400, which
    # counts as a delivery failure and can auto-disable the destination.
    # `Character.name` carries no length constraint here.
    test "a very long character name is truncated to Discord's author bound", %{alert: alert} do
      scouted =
        Map.put(alert, :scout, %{name: String.duplicate("a", 400), eve_id: "2112625428"})

      [%{"embeds" => [embed]}] = EmbedFormatter.format_route_alert(scouted, [])

      assert String.length(embed["author"]["name"]) == 256
      assert String.ends_with?(embed["author"]["name"], "…")
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`
Expected: FAIL — the scouted tests get `%{"name" => "Route opened"}` because `:scout` is ignored.

- [ ] **Step 3: Write the implementation**

In `lib/wanderer_app/external_events/discord/embed_formatter.ex`, add the bound next to the other Discord limits (after `@max_field_length`, near line 40):

```elixir
  # Discord's author-name bound. Reachable from ordinary input: the route
  # embed's author line embeds a `Character.name`, which carries no length
  # constraint, and exceeding this is a 400 — a delivery failure, not a
  # truncation.
  @max_author_length 256
```

Replace the `"author"` entry in `route_embed/1` (currently line 156):

```elixir
      "author" => route_author(alert),
```

Add these functions next to `route_kind_label/1` (currently near line 221):

```elixir
  # The scout's portrait rides in the author line rather than the thumbnail
  # slot: a 72px face would make a logistics alert louder than the kill embeds
  # sharing its channel, and would squeeze the path text on a long chain.
  #
  # `alert` may carry no `:scout` key at all — the watcher only adds one when
  # attribution resolved — so this reads defensively rather than matching.
  defp route_author(alert) do
    base = %{"name" => truncate(route_author_name(alert), @max_author_length)}

    case Map.get(alert, :scout) do
      %{eve_id: eve_id} when is_binary(eve_id) ->
        Map.put(base, "icon_url", "#{@image_base}/characters/#{eve_id}/portrait?size=64")

      _ ->
        base
    end
  end

  defp route_author_name(alert) do
    case Map.get(alert, :scout) do
      %{name: name} when is_binary(name) and name != "" ->
        "#{route_kind_label(alert.kind)} · scouted by #{name}"

      _ ->
        route_kind_label(alert.kind)
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`
Expected: PASS, including the pre-existing route-alert tests that assert `embed["author"] == %{"name" => "Route opened"}`.

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/wanderer_app/external_events/discord/embed_formatter.ex test/unit/external_events/discord/embed_formatter_test.exs
git commit -m "feat(route-alerts): name the scout and show their portrait in the embed"
```

---

### Task 5: Wire attribution into delivery

**Files:**
- Modify: `lib/wanderer_app/external_events/discord/route_watcher.ex`
- Test: `test/unit/external_events/discord/route_watcher_test.exs`

**Interfaces:**
- Consumes: `RouteScout.resolve/2` (Task 3) and the `:scout` key `EmbedFormatter` reads (Task 4).
- Produces: nothing new for later tasks. This is the last task.

- [ ] **Step 1: Write the failing test**

Add to the `describe "settle hold"` block in `test/unit/external_events/discord/route_watcher_test.exs`:

```elixir
    test "a published alert credits the character who added a path system", %{map: map} do
      user = Factory.insert(:user, %{})
      character = Factory.insert(:character, %{user_id: user.id, name: "Kraven Ordos"})

      # 30_000_002 is the first hop of qualifying_result(4, 30_000_001).
      {:ok, _} =
        WandererApp.User.ActivityTracker.track_map_event(:system_added, %{
          character_id: character.id,
          user_id: user.id,
          map_id: map.id,
          solar_system_id: 30_000_002
        })

      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      {:ok, pid} = start_watcher(map.id, settle_ms: 20)
      RouteWatcher.notify(map.id)
      await_settled(pid)

      assert :ok = wait_until(fn -> HttpStub.requests_for(@route_url) != [] end)

      [{_url, body}] = HttpStub.requests_for(@route_url)

      assert %{"embeds" => [%{"author" => author}]} = body
      assert author["name"] == "Route opened · scouted by Kraven Ordos"
      assert author["icon_url"] =~ "/characters/#{character.eve_id}/portrait"
    end

    test "an alert with no attributable add still posts", %{map: map} do
      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        qualifying_result(4, 30_000_001)
      )

      {:ok, pid} = start_watcher(map.id, settle_ms: 20)
      RouteWatcher.notify(map.id)
      await_settled(pid)

      assert :ok = wait_until(fn -> HttpStub.requests_for(@route_url) != [] end)

      [{_url, body}] = HttpStub.requests_for(@route_url)

      assert %{"embeds" => [%{"author" => author}]} = body
      assert author == %{"name" => "Route opened"}
    end
```

`HttpStub.requests_for/1` returns `{url, body}` tuples with `body` **already
decoded into a map** — see the existing assertion at
`route_watcher_test.exs:220`. Do not call `Jason.decode!/1` on it.

The second test doubles as the observable proof of the design doc's accepted
audit-collision lossiness: whatever the reason attribution resolves to `nil` —
no add, a stale add, a nil `character_id`, or a row lost to the unique index —
the alert still posts with the plain author line.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/unit/external_events/discord/route_watcher_test.exs`
Expected: FAIL — the crediting test gets `%{"name" => "Route opened"}` because nothing populates `:scout`. The second test should already pass.

- [ ] **Step 3: Populate `:scout` on the alert map**

In `lib/wanderer_app/external_events/discord/route_watcher.ex`, extend the alias line (currently line 51):

```elixir
  alias WandererApp.ExternalEvents.Discord.{Router, WorkerSupervisor, EmbedFormatter, RouteScout}
```

And add the key in `deliver_alert/8`'s alert map (currently near line 400):

```elixir
    alert = %{
      kind: kind,
      jumps: jumps,
      previous_jumps: previous_jumps,
      path: qualifying.path,
      exit_system: qualifying.exit_system,
      map_id: state.map_id,
      home_system_id: notification.home_system_id,
      # Resolved here rather than in the formatter so the lookup is testable
      # on its own and the formatter stays a pure rendering of what it is
      # handed. Synchronous DB work in this process matches what
      # `load_notification/1` already does; `resolve/2` is total and returns
      # nil rather than raising, so it cannot cost a delivery.
      scout: RouteScout.resolve(state.map_id, qualifying.path)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/unit/external_events/discord/route_watcher_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full affected suites**

Run: `mix test test/unit/external_events/discord/ test/unit/map/route_alert/`
Expected: PASS, 0 failures.

- [ ] **Step 6: Lint, format, and commit**

```bash
mix format
mix credo
git add lib/wanderer_app/external_events/discord/route_watcher.ex test/unit/external_events/discord/route_watcher_test.exs
git commit -m "feat(route-alerts): credit the scout on the published alert"
```

Resolve any `credo` finding in the code this plan touched. Pre-existing findings elsewhere are out of scope.

---

## Final Verification

- [ ] **Run the full test suite**

Run: `mix test`
Expected: 0 failures in `test/unit/external_events/discord/` and
`test/unit/map/route_alert/`.

This repo's full suite is large and touches the database; if failures appear in
files this work never touched, check them against the base commit in a scratch
worktree rather than assuming ownership:

```bash
git worktree add /tmp/route-alert-base 0cd13708
cd /tmp/route-alert-base && mix deps.get && mix test <the failing file>
```

Do **not** use `git stash` — the stash stack is shared across every worktree in
this repo and another session may pop your entry.

- [ ] **Inspect the complete diff**

Run: `git diff 0cd13708..HEAD -- lib test`

Confirm: `@route_guarantee` is byte-identical; `Evaluator` is untouched; no debug output, `IO.inspect`, or commented-out code; no `added_at` writes.

- [ ] **Confirm the observable behaviour changed as intended**

The two claims a reviewer will check first:

1. A qualifying route now waits `@settle_ms` and re-solves — proven by "a qualifying transition holds instead of publishing" plus "the held alert publishes when the window elapses".
2. A route that gets a crit label during the window sends nothing at all — proven by "a route that stops qualifying during the hold publishes nothing", which is the regression test for the reported bug.

## Out of Scope

- Rewording `@route_guarantee`.
- Writing or backfilling `MapSystem.added_at`.
- Per-region embed colours.
- Any change to `Evaluator`, its solver settings, or the mention mechanism.
- Changing the `user_activity_v1` unique index. Its microsecond-collision lossiness is accepted: `RouteScout` returns `nil` and the alert posts unattributed.
