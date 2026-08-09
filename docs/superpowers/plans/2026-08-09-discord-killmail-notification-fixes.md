# Discord Killmail Notification Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Discord kill notifications firing for systems removed from a map, and stop already-posted killmails being posted again after a restart.

**Architecture:** Two independent fixes. Defect 1 adds the missing `visible` filter to the kill fan-out index and backs it with a fail-open membership guard in the Discord dispatcher. Defect 2 tightens the freshness filter for a grace window after the dedup cache loses its marks, armed from a sentinel stored in that cache so the window tracks the cache's lifecycle rather than the dispatcher's.

**Tech Stack:** Elixir, Ash Framework, Cachex, `:telemetry`, ExUnit.

**Source spec:** `docs/superpowers/specs/2026-08-09-discord-killmail-notification-fixes-design.md`

## Global Constraints

- **Never resolve config per killmail.** `Env` accessors log a warning on a bad value; reading one inside a per-kill loop turns a single misconfigured deployment into a warning-per-kill log flood. Every config read stays once-per-batch. This is documented at `lib/wanderer_app/external_events/discord_dispatcher.ex:230-237` and `:922-928`, and both comments must survive.
- **Fail open, always.** Every new guard in the Discord path drops a killmail only on a positive finding. Any failure to read state (missing cache entry, unstarted cache, raised exception) lets the batch through. This is the existing `:unknown`-is-not-`:not_involved` posture (`lib/wanderer_app/external_events/discord/router.ex:18-28`).
- **`Cachex.get/2` raises against an unstarted cache** rather than returning an error tuple. Any new Cachex read outside the dispatcher's supervised lifetime needs a `rescue`, following `Matcher.tracked_eve_ids/1` (`lib/wanderer_app/external_events/discord/matcher.ex:53-60`).
- **At-most-once delivery is unchanged.** No task in this plan may make delivery at-least-once, add a persistence layer for dedup marks, or move the dedup mark after delivery confirmation.
- **Test config keys are restored wholesale.** Every test that mutates `:external_events` reads the whole keyword list, `Keyword.put`s onto it, and restores the original list in `on_exit` — never `Application.put_env` with a fresh list. Pattern: `discord_killmail_age_test.exs:13-24`.
- Run `mix format` before every commit. The final gate checks formatting.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `lib/wanderer_app/kills/subscription/system_map_index.ex` | Fan-out index build query | 1 |
| `test/unit/kills/subscription/system_map_index_test.exs` | **New.** Index visibility regression | 1 |
| `lib/wanderer_app/external_events/discord_dispatcher.ex` | Membership guard, startup window, drop telemetry | 2, 4, 5 |
| `lib/wanderer_app/env.ex` | Two new config accessors + non-negative validator | 3 |
| `config/test.exs` | Disable the startup window under test | 3 |
| `test/unit/external_events/discord_dispatcher_test.exs` | Guard behaviour | 2 |
| `test/unit/external_events/discord_killmail_age_test.exs` | New `Env` accessor coverage | 3 |
| `test/unit/external_events/discord_startup_window_test.exs` | **New.** Window behaviour, lifecycle, telemetry | 4, 5 |

---

## Deviations from the spec

Three, all discovered by reading the code while writing this plan. Each is deliberate; do not "correct" them back.

1. **Telemetry event name.** The spec names `[:wanderer_app, :discord, :killmail_dropped]`. This plan uses **`[:wanderer_app, :discord_dispatcher, :killmail_dropped]`**. The `:discord` prefix in this module is used for *enrichment* events (`:notable_items`, `:corp_tickers` — `discord_dispatcher.ex:521,671`), while dispatch-outcome events use `:discord_dispatcher` (`:dispatched`, `:not_delivered` — `:762,795`). A drop is a dispatch outcome and shares their `%{count: n}` measurement shape and `map_id` metadata.

2. **The sentinel needs two Cachex calls, not one.** The spec says the sentinel is written "with no TTL". `:discord_dedup_cache` is created with `default_ttl: :timer.hours(24)` (`lib/wanderer_app/application.ex:150-154`), and `Cachex.Actions.Put` only honours an **integer** `:ttl` — anything else, `nil` included, falls back to the cache default (`deps/cachex/lib/cachex/actions/put.ex:29-30`, `deps/cachex/lib/cachex/services/janitor.ex:43-47`). So `Cachex.put/3` cannot write a never-expiring entry here. The fix is `Cachex.put/3` followed by `Cachex.persist/2`, which clears the expiration. Without the `persist`, the sentinel would silently expire after 24 hours of uptime and a later dispatcher-only restart would spuriously re-arm the window.

3. **Line numbers.** The spec cites `system_map_index.ex:98` for the unfiltered query; it is actually **line 103**. The spec's `map_integration.ex` citations are likewise a few lines off. Trust this plan's line numbers, which were re-read from the working tree.

---

## Task 1: Filter the fan-out index by system visibility

Removing a system from a map is a soft delete — `MapSystemRepo.remove_from_map/2` sets `visible: false` (`lib/wanderer_app/repositories/map_system_repo.ex:49-58`). `SystemMapIndex` builds its `system_id -> [map_ids]` index with `get_all_by_map/1`, which has no `visible` filter, so every system a map has ever contained maps to that map permanently.

**Files:**
- Modify: `lib/wanderer_app/kills/subscription/system_map_index.ex:103`
- Test: `test/unit/kills/subscription/system_map_index_test.exs` (create)

**Interfaces:**
- Consumes: `WandererApp.MapSystemRepo.get_visible_by_map/1`, which already exists (`map_system_repo.ex:45-47`) and delegates to the `:read_visible_by_map` Ash action (`lib/wanderer_app/api/map_system.ex:251-254`).
- Produces: no signature change. `SystemMapIndex.get_maps_for_system/1` keeps returning `[String.t()]`.

- [ ] **Step 1: Write the failing test**

Create `test/unit/kills/subscription/system_map_index_test.exs`:

```elixir
defmodule WandererApp.Kills.Subscription.SystemMapIndexTest do
  # `async: false`: the index owns a NAMED ETS table and a named GenServer, so
  # two of these running concurrently would fight over both.
  use WandererApp.DataCase, async: false

  alias WandererApp.Kills.Subscription.SystemMapIndex
  alias WandererAppWeb.Factory

  @visible_system 31_000_005
  @removed_system 31_000_006

  # A real removal, through the repo function the map server calls, rather than
  # writing `visible: false` directly — so this test fails if removal ever stops
  # being a soft delete and starts destroying the row.
  test "a system removed from the map is dropped from the index" do
    map = Factory.insert(:map, %{})

    Factory.insert(:map_system, %{map_id: map.id, solar_system_id: @visible_system})
    Factory.insert(:map_system, %{map_id: map.id, solar_system_id: @removed_system})

    {:ok, _} = WandererApp.MapSystemRepo.remove_from_map(map.id, @removed_system)

    start_supervised!(SystemMapIndex)
    # `init/1` sends itself `:build_index`; a system message is appended behind
    # it, so this returns only once the build has run.
    :sys.get_state(SystemMapIndex)

    assert SystemMapIndex.get_maps_for_system(@visible_system) == [map.id]
    assert SystemMapIndex.get_maps_for_system(@removed_system) == []
  end
end
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `mix test test/unit/kills/subscription/system_map_index_test.exs`

Expected: FAIL. The second assertion reports `[<map id>] == []` — the removed system is still indexed.

If the FIRST assertion fails instead, stop: the fixture is wrong, not the code. Check that `Factory.insert(:map_system, ...)` accepted `solar_system_id`.

- [ ] **Step 3: Apply the one-line fix**

In `lib/wanderer_app/kills/subscription/system_map_index.ex`, at line 103, change the repo call inside `fetch_all_map_systems/0`:

```elixir
          # Visible systems ONLY. Removal from a map is a soft delete
          # (`MapSystemRepo.remove_from_map/2` sets `visible: false`), so
          # `get_all_by_map/1` here indexed every system the map had ever
          # contained and kills kept broadcasting for removed systems forever.
          # The sibling `MapIntegration.get_tracked_system_ids/0` already uses
          # this variant, and `MapSystem` carries a partial index for exactly
          # this filter (`api/map_system.ex:44`).
          case WandererApp.MapSystemRepo.get_visible_by_map(map.id) do
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `mix test test/unit/kills/subscription/system_map_index_test.exs`

Expected: PASS.

- [ ] **Step 5: Run the broader kills suite for regressions**

Run: `mix test test/unit/kills/`

Expected: PASS. This fix changes the in-app kills widget too — a system removed from a map stops showing kill activity. That is intended (see the spec's blast-radius table). If a test asserts the old behaviour, it is asserting the bug; read it carefully before changing it, and say so in the commit body.

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/wanderer_app/kills/subscription/system_map_index.ex test/unit/kills/subscription/system_map_index_test.exs
git commit -m "fix(kills): index only visible systems for kill fan-out

Removing a system from a map is a soft delete, but SystemMapIndex built
its system->maps index with get_all_by_map/1, which has no visible
filter. Every system a map had ever contained mapped to that map
permanently, so kills kept broadcasting for removed systems -- to the
in-app kills widget and to Discord.

Affects the kills widget as well as Discord, in the same direction: a
system that was removed should not light up with kill activity."
```

---

## Task 2: Fail-open map-membership guard in the dispatcher

Task 1 fixes persistent membership. It does not close the staleness window: `SystemMapIndex.refresh/0` runs only on the `:ok` branch of `MapEventListener.do_update_subscriptions/1` (`lib/wanderer_app/kills/map_event_listener.ex:177-183`), the retry path replaces it while the kills client is disconnected (`:220-237`), and per-map topics are not subscribed until the first `:resubscribe_to_maps`, 60 seconds after init (`:26-29`, `:111-133`). The backstop is the index's 5-minute periodic refresh (`system_map_index.ex:12,127-129`), so exposure is up to five minutes.

The live map cache is strictly fresher: `WandererApp.Map.remove_system/2` drops the system immediately (`lib/wanderer_app/map.ex:507-521`). The guard consults it, and drops the batch **only** on a positive "this map does not have that system".

**Files:**
- Modify: `lib/wanderer_app/external_events/discord_dispatcher.ex:223-270`
- Test: `test/unit/external_events/discord_dispatcher_test.exs`

**Interfaces:**
- Consumes: `WandererApp.Map.get_map/1` → `{:ok, %WandererApp.Map{systems: %{integer => map()}}} | {:error, :not_found}` (`lib/wanderer_app/map.ex:59-67`). The `systems` map is keyed by `solar_system_id` (`map.ex:20`, and `add_system/2` at `:480`).
- Consumes: `extract_kills/1` already yields `{:ok, system_id, killmails}` with `system_id` an integer — `MapIntegration.broadcast_kill_to_maps/1` guards `is_integer(system_id)` before broadcasting at all (`lib/wanderer_app/kills/subscription/map_integration.ex:161-162`), so no type coercion is needed here.
- Produces: private `system_on_map?/2`. Nothing outside this module consumes it.

- [ ] **Step 1: Write the three failing tests**

Append to `test/unit/external_events/discord_dispatcher_test.exs`, inside the main `WandererApp.ExternalEvents.DiscordDispatcherTest` module (after the existing `test "delivers a wormhole kill"`).

Note the deliberate asymmetry in the fixtures: the third test seeds nothing, because the *existing* tests in this file seed nothing either. That is what keeps them all green.

```elixir
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
```

- [ ] **Step 2: Run the tests and confirm the right one fails**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs`

Expected: the **"drops a kill for a system absent"** test FAILS (a request was delivered, and `marked?` is true). The other two PASS — they describe behaviour that already holds. That is the correct starting state: two of the three are regression pins for behaviour this task must not break.

- [ ] **Step 3: Add the guard to the `:map_kill` clause**

In `lib/wanderer_app/external_events/discord_dispatcher.ex`, add `system_on_map?/2` next to the other private helpers (put it directly above `defp enabled_globally?` at line 802):

```elixir
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
  defp system_on_map?(map_id, system_id) do
    case WandererApp.Map.get_map(map_id) do
      {:ok, %{systems: systems}} when is_map(systems) -> Map.has_key?(systems, system_id)
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
```

Then add one clause to the `with` chain in `do_dispatch/2`, immediately after `extract_kills/1` — it must sit **before** the age filter and dedup, so a kill for a removed system is never marked as attempted:

```elixir
         {:ok, system_id, killmails} <- extract_kills(payload),
         # Before the age filter and dedup on purpose: a kill dropped here was
         # never marked attempted, so it stays eligible if the same batch
         # arrives again once the map cache says the system is present.
         true <- system_on_map?(map_id, system_id),
```

- [ ] **Step 4: Run the tests and confirm all three pass**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs`

Expected: PASS, all three, and every pre-existing test in the file still green. The pre-existing tests never seed `:map_cache`, so they take the fail-open branch.

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/wanderer_app/external_events/discord_dispatcher.ex test/unit/external_events/discord_dispatcher_test.exs
git commit -m "fix(discord): drop kills for systems no longer on the map

Task 1 fixes persistent index membership but not staleness: the index
refreshes only after a successful kills-client subscription update, and
otherwise on a 5-minute timer, so a removed system keeps producing kill
broadcasts for up to five minutes.

This guard consults the live map cache, which remove_system/2 updates
immediately. It is fail-open -- it drops a batch only when the map cache
reads successfully AND positively lacks the system. An unreadable or
absent cache entry lets the batch through, because a map with no live
GenServer is not evidence that a system was removed.

Placed before the age filter and dedup, so a dropped kill is never
marked attempted and stays eligible on a later arrival."
```

---

## Task 3: Configuration for the startup window

Two new keys in the `:external_events` keyword list. They do **not** share a validator, and the difference is load-bearing: `validate_positive_integer/3` rejects `0` and substitutes the default (`lib/wanderer_app/env.ex:285-295`). That is right for a maximum age — `0` would drop every real killmail, silently. It is wrong for the grace period, where `0` is a legitimate "no startup window", and routing it through that helper would turn "disabled" into "600 seconds plus a warning".

**Files:**
- Modify: `lib/wanderer_app/env.ex` (add two accessors + one validator, after `discord_max_killmail_age_seconds/0` at `:120-127`)
- Modify: `config/test.exs:36`
- Test: `test/unit/external_events/discord_killmail_age_test.exs`

**Interfaces:**
- Produces: `WandererApp.Env.discord_startup_grace_seconds/0` → `non_neg_integer()`, default `600`.
- Produces: `WandererApp.Env.discord_startup_max_killmail_age_seconds/0` → `pos_integer()`, default `120`.
- Both are read by Task 4. Neither is cached, matching `discord_max_killmail_age_seconds/0`.

- [ ] **Step 1: Write the failing tests**

Append a new `describe` block to `test/unit/external_events/discord_killmail_age_test.exs`. The existing `put_max_age/1` helper hardcodes one key, so add a general one beside it (place it directly after `put_max_age/1` at line 24):

```elixir
  defp put_key(key, value) do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, key, value)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
    :ok
  end

  defp delete_key(key) do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.delete(original, key)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
    :ok
  end
```

Then the tests:

```elixir
  describe "Env.discord_startup_grace_seconds/0" do
    test "defaults to 600 when the key is absent" do
      delete_key(:discord_startup_grace_seconds)

      assert Env.discord_startup_grace_seconds() == 600
    end

    test "returns the configured value, not only the default" do
      put_key(:discord_startup_grace_seconds, 90)

      assert Env.discord_startup_grace_seconds() == 90
    end

    # THE test for this key. `0` means "no startup window" and must be honoured
    # rather than treated as a misconfiguration. Routing this key through
    # `validate_positive_integer/3` would return 600 here and turn an operator's
    # "disabled" into ten minutes of tightened freshness -- and would break
    # config/test.exs, which uses exactly this value.
    test "honours zero as 'window disabled' rather than falling back" do
      put_key(:discord_startup_grace_seconds, 0)

      log =
        capture_log(fn ->
          assert Env.discord_startup_grace_seconds() == 0
        end)

      refute log =~ "discord_startup_grace_seconds"
    end

    test "falls back to the default and warns when configured as negative" do
      put_key(:discord_startup_grace_seconds, -1)

      log =
        capture_log(fn ->
          assert Env.discord_startup_grace_seconds() == 600
        end)

      assert log =~ "discord_startup_grace_seconds"
    end

    test "falls back to the default and warns when configured as a non-integer" do
      put_key(:discord_startup_grace_seconds, "ten minutes")

      log =
        capture_log(fn ->
          assert Env.discord_startup_grace_seconds() == 600
        end)

      assert log =~ "discord_startup_grace_seconds"
    end
  end

  describe "Env.discord_startup_max_killmail_age_seconds/0" do
    test "defaults to 120 when the key is absent" do
      delete_key(:discord_startup_max_killmail_age_seconds)

      assert Env.discord_startup_max_killmail_age_seconds() == 120
    end

    test "returns the configured value, not only the default" do
      put_key(:discord_startup_max_killmail_age_seconds, 45)

      assert Env.discord_startup_max_killmail_age_seconds() == 45
    end

    # The opposite of the grace key: here `0` IS a misconfiguration, because a
    # kill that has already happened always has a non-negative age and the guard
    # keeps a kill only when `age <= max`.
    test "falls back to the default and warns when configured as zero" do
      put_key(:discord_startup_max_killmail_age_seconds, 0)

      log =
        capture_log(fn ->
          assert Env.discord_startup_max_killmail_age_seconds() == 120
        end)

      assert log =~ "discord_startup_max_killmail_age_seconds"
    end

    test "falls back to the default and warns when configured as a non-integer" do
      put_key(:discord_startup_max_killmail_age_seconds, :soon)

      log =
        capture_log(fn ->
          assert Env.discord_startup_max_killmail_age_seconds() == 120
        end)

      assert log =~ "discord_startup_max_killmail_age_seconds"
    end
  end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `mix test test/unit/external_events/discord_killmail_age_test.exs`

Expected: FAIL with `UndefinedFunctionError` on `WandererApp.Env.discord_startup_grace_seconds/0`.

- [ ] **Step 3: Add the accessors and the new validator**

In `lib/wanderer_app/env.ex`, after `discord_max_killmail_age_seconds/0` (line 127):

```elixir
  @default_discord_startup_grace_seconds 600
  @default_discord_startup_max_killmail_age_seconds 120

  @doc """
  How long after the Discord dedup marks are lost the tighter startup maximum
  age applies, in seconds. `0` disables the window.

  The marks live in `:discord_dedup_cache`, which is memory-only, so a restart
  loses every one of them. The kills client then rejoins its channel and the
  upstream service replays recent killmails, which the ordinary 3600-second
  freshness limit happily admits — an hour of already-posted kills, posted
  again. During this window `discord_startup_max_killmail_age_seconds/0`
  applies instead.

  Ten minutes rather than two because a long window is nearly free: it only
  ever drops *old* killmails. The replay burst arrives when the kills client
  joins the channel, which can be minutes after boot when the upstream service
  is slow to accept the connection, and a short window would miss it.

  Validated as NON-NEGATIVE, unlike its sibling below. `0` is a legitimate
  setting meaning "no startup window", and `validate_positive_integer/3` would
  turn an operator's "disabled" into #{@default_discord_startup_grace_seconds}
  seconds plus a warning — the opposite of what they asked for.
  """
  def discord_startup_grace_seconds() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:discord_startup_grace_seconds, @default_discord_startup_grace_seconds)
    |> validate_non_negative_integer(
      :discord_startup_grace_seconds,
      @default_discord_startup_grace_seconds
    )
  end

  @doc """
  Maximum killmail age, in seconds, while the startup window is armed.

  Validated as POSITIVE, like `discord_max_killmail_age_seconds/0` and for the
  same reason: a kill that has already happened always has a non-negative age
  and the guard keeps a kill only when `age <= max`, so `0` or a negative value
  would silently and invisibly suppress every notification.

  The accepted cost of the tighter limit is that a genuinely delayed killmail —
  upstream lag beyond this many seconds — is dropped during the window. That is
  the same trade the dispatcher already makes for at-most-once dedup: a dropped
  kill stays visible in the kills widget and on zKillboard, while a duplicate
  post in a chat channel is irreversible.
  """
  def discord_startup_max_killmail_age_seconds() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(
      :discord_startup_max_killmail_age_seconds,
      @default_discord_startup_max_killmail_age_seconds
    )
    |> validate_positive_integer(
      :discord_startup_max_killmail_age_seconds,
      @default_discord_startup_max_killmail_age_seconds
    )
  end
```

And add the validator beside `validate_positive_integer/3` (after line 295):

```elixir
  # Sibling of `validate_positive_integer/3` for settings where `0` is a
  # legitimate value meaning "off" rather than a misconfiguration. Both fall
  # back loudly rather than silently.
  defp validate_non_negative_integer(value, _key, _default)
       when is_integer(value) and value >= 0,
       do: value

  defp validate_non_negative_integer(value, key, default) do
    Logger.warning(
      "[Discord] #{key} must be a non-negative integer, " <>
        "got #{inspect(value)}; falling back to #{default}"
    )

    default
  end
```

- [ ] **Step 4: Disable the window under test**

In `config/test.exs`, change line 36:

```elixir
  external_events: [
    webhooks_enabled: false,
    # `0` disables the startup window, which the non-negative validator honours.
    # Without this, every test calling `start_supervised!(DiscordDispatcher)`
    # (discord_dispatcher_test.exs:110) would begin inside a live 600-second
    # grace period, and the existing age assertions in
    # discord_killmail_age_test.exs would quietly start measuring against 120
    # seconds instead of 3600. Tests that exercise the window set it explicitly.
    discord_startup_grace_seconds: 0
  ],
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `mix test test/unit/external_events/discord_killmail_age_test.exs`

Expected: PASS, including the pre-existing `discord_max_killmail_age_seconds/0` tests.

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/wanderer_app/env.ex config/test.exs test/unit/external_events/discord_killmail_age_test.exs
git commit -m "feat(discord): config for the killmail startup grace window

Two keys, deliberately not sharing a validator.

discord_startup_grace_seconds (default 600) is non-negative: 0 is a
legitimate 'no startup window', and the positive-integer validator would
turn that into 600 seconds plus a warning.

discord_startup_max_killmail_age_seconds (default 120) keeps the
positive-integer validator, for the same reason the ordinary max age
does: 0 would silently suppress every notification.

config/test.exs sets the grace to 0 so existing dispatcher tests are not
silently pulled inside a live window."
```

---

## Task 4: Arm the startup window from a dedup-cache sentinel

**The window belongs to the dedup cache's lifecycle, not the dispatcher's.** `:discord_dedup_cache` and `DiscordDispatcher` are separate children of a `:one_for_one` supervisor (`lib/wanderer_app/application.ex:150-154`, `:270-298`), so their restarts are independent:

| Event | Marks | Window must |
|---|---|---|
| Full application restart | lost | arm |
| Dedup cache crashes alone | lost | **arm** |
| Dispatcher crashes alone | intact | not arm (harmless if it does) |
| Kills-client reconnect, no restart | intact | not arm |

Keying the window off `DiscordDispatcher.init/1` gets row 2 exactly backwards: every mark is gone and the window never arms — precisely the duplicate-post scenario this exists to prevent. So the window is derived from a sentinel stored **in the dedup cache itself**: absent means the cache is new, so its marks are gone.

The sentinel carries an **absolute deadline**, not a TTL. An expired window is still a *present* sentinel, so a dispatcher-only restart cannot re-arm it. Monotonic time, because the cache and the dispatcher share a VM and it is immune to wall-clock adjustment.

**Files:**
- Modify: `lib/wanderer_app/external_events/discord_dispatcher.ex` (`init/1` at `:90`, `handle_cast/2` at `:212-215`, all three `do_dispatch` clauses at `:223`, `:285`, `:303`)
- Test: `test/unit/external_events/discord_startup_window_test.exs` (create)

**Interfaces:**
- Consumes: `Env.discord_startup_grace_seconds/0` and `Env.discord_startup_max_killmail_age_seconds/0` from Task 3.
- Consumes: `Cachex.persist/2`, which clears an entry's expiration (`deps/cachex/lib/cachex.ex:990-991`). Required — see Deviation 2 above.
- Produces: `DiscordDispatcher.startup_sentinel_key/0` → `String.t()`, public so tests derive the key instead of hardcoding it, matching `dedup_key/2` and `dedup_cache/0` (`discord_dispatcher.ex:899-905`).
- Produces: dispatcher state changes from `%{}` to `%{startup_arm_until: integer() | :never}`.
- Produces: `do_dispatch/3` — all three clauses gain a third argument. The two non-`:map_kill` clauses ignore it.

- [ ] **Step 1: Write the failing tests**

Create `test/unit/external_events/discord_startup_window_test.exs`. This file owns the window's behaviour end-to-end; it does not reuse `discord_dispatcher_test.exs` because that file's setup deliberately runs with the window disabled.

```elixir
defmodule WandererApp.ExternalEvents.DiscordStartupWindowTest do
  # `async: false` is mandatory: this file mutates application env and shares
  # the global `:discord_dedup_cache` with every other test.
  use WandererApp.DataCase, async: false

  alias WandererApp.ExternalEvents.DiscordDispatcher

  # Restores the whole `:external_events` list, per the global constraint.
  defp put_keys(pairs) do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Enum.reduce(pairs, original, fn {k, v}, acc -> Keyword.put(acc, k, v) end)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
    :ok
  end

  # `:discord_dedup_cache` is global and NOT sandboxed, so the sentinel written
  # by any earlier test in the run is still there. Clearing it is what "the
  # dedup cache is new" means, and every test here must start from a known
  # state or it silently asserts nothing.
  defp clear_sentinel do
    Cachex.del(DiscordDispatcher.dedup_cache(), DiscordDispatcher.startup_sentinel_key())

    on_exit(fn ->
      Cachex.del(DiscordDispatcher.dedup_cache(), DiscordDispatcher.startup_sentinel_key())
    end)

    :ok
  end

  defp arm_until do
    :sys.get_state(DiscordDispatcher).startup_arm_until
  end

  describe "arming" do
    test "arms when the dedup cache carries no sentinel" do
      put_keys(discord_startup_grace_seconds: 600)
      clear_sentinel()

      start_supervised!(DiscordDispatcher)

      assert is_integer(arm_until())
      assert arm_until() > System.monotonic_time(:millisecond)
    end

    # Row 3 of the lifecycle table, and the case an earlier draft of the design
    # got backwards. The marks survived a dispatcher-only crash, so the window
    # must NOT re-arm -- otherwise every dispatcher restart silently tightens
    # freshness for ten minutes with no duplicates to prevent.
    test "does not re-arm when the sentinel is already present" do
      put_keys(discord_startup_grace_seconds: 600)
      clear_sentinel()

      start_supervised!(DiscordDispatcher)
      first = arm_until()

      :ok = stop_supervised!(DiscordDispatcher)
      start_supervised!(DiscordDispatcher)

      assert arm_until() == first
    end

    # Row 2: the dedup cache crashed alone, taking every mark with it. The
    # dispatcher never restarted, but the next one to start must arm.
    test "re-arms after the sentinel is cleared" do
      put_keys(discord_startup_grace_seconds: 600)
      clear_sentinel()

      start_supervised!(DiscordDispatcher)
      first = arm_until()

      :ok = stop_supervised!(DiscordDispatcher)
      Cachex.del(DiscordDispatcher.dedup_cache(), DiscordDispatcher.startup_sentinel_key())
      start_supervised!(DiscordDispatcher)

      refute arm_until() == first
    end

    test "a zero grace period leaves the window closed immediately" do
      put_keys(discord_startup_grace_seconds: 0)
      clear_sentinel()

      start_supervised!(DiscordDispatcher)

      refute DiscordDispatcher.within_startup_grace?(arm_until())
    end

    # Guards Deviation 2: `:discord_dedup_cache` has a 24h default_ttl, and
    # `Cachex.put/4` honours only an integer `:ttl`, so a bare put would leave
    # the sentinel expiring after a day -- after which a dispatcher-only
    # restart would spuriously re-arm.
    test "the sentinel never expires" do
      put_keys(discord_startup_grace_seconds: 600)
      clear_sentinel()

      start_supervised!(DiscordDispatcher)

      assert Cachex.ttl(
               DiscordDispatcher.dedup_cache(),
               DiscordDispatcher.startup_sentinel_key()
             ) == {:ok, nil}
    end
  end

  describe "within_startup_grace?/1" do
    test "an armed deadline in the future is inside the window" do
      assert DiscordDispatcher.within_startup_grace?(System.monotonic_time(:millisecond) + 60_000)
    end

    test "a deadline in the past is outside the window" do
      refute DiscordDispatcher.within_startup_grace?(System.monotonic_time(:millisecond) - 1)
    end

    # The value the dispatcher falls back to when the sentinel is unreadable.
    # A plain integer would be wrong here: Erlang monotonic time may be
    # negative, so `0` is not reliably "in the past".
    test "an unarmed window is never inside it" do
      refute DiscordDispatcher.within_startup_grace?(:never)
    end
  end
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `mix test test/unit/external_events/discord_startup_window_test.exs`

Expected: FAIL with `UndefinedFunctionError` on `DiscordDispatcher.startup_sentinel_key/0`.

- [ ] **Step 3: Add the sentinel and the window predicate**

In `lib/wanderer_app/external_events/discord_dispatcher.ex`, add the attribute next to `@dedup_ttl` (after line 70):

```elixir
  # Lives in the dedup cache rather than the dispatcher's own state ON PURPOSE:
  # the window exists because the dedup MARKS are gone, and those marks belong
  # to that cache. The two are separate children of a `:one_for_one` supervisor,
  # so a dedup-cache-only crash loses every mark while the dispatcher keeps
  # running -- exactly the case a dispatcher-lifecycle window would miss.
  #
  # Cannot collide with a dedup key: those are `"\#{map_id}:\#{killmail_id}"`
  # with a UUID map_id, and this contains no colon.
  @startup_sentinel "discord-startup-grace-until"
```

Add the public accessors and the predicate beside `dedup_cache/0` (after line 905):

```elixir
  @doc "Name of the startup-window sentinel key, so tests do not hardcode it."
  @spec startup_sentinel_key() :: String.t()
  def startup_sentinel_key, do: @startup_sentinel

  @doc """
  Whether a batch is inside the startup grace window.

  `:never` rather than a sentinel integer for the unarmed case: Erlang
  monotonic time may be negative, so no integer is reliably "in the past".
  """
  @spec within_startup_grace?(integer() | :never) :: boolean()
  def within_startup_grace?(:never), do: false

  def within_startup_grace?(arm_until) when is_integer(arm_until),
    do: System.monotonic_time(:millisecond) < arm_until
```

Add the arming function beside the other private helpers (above `defp enabled_globally?`):

```elixir
  # Reads the sentinel from the dedup cache, writing one if it is absent.
  #
  # ABSENT means the cache is new and its marks are gone, so arm. PRESENT means
  # the cache survived, so honour the stored deadline as it is -- including an
  # expired one. The deadline is absolute, not a TTL, precisely so that an
  # expired window is still a *present* sentinel and a dispatcher-only restart
  # cannot re-arm it.
  defp arm_startup_grace do
    case Cachex.get(@dedup_cache, @startup_sentinel) do
      {:ok, nil} ->
        arm_until =
          System.monotonic_time(:millisecond) + Env.discord_startup_grace_seconds() * 1000

        Cachex.put(@dedup_cache, @startup_sentinel, arm_until)
        # REQUIRED, not belt-and-braces. This cache is created with
        # `default_ttl: :timer.hours(24)` (`application.ex:150-154`), and
        # `Cachex.Actions.Put` honours only an INTEGER `:ttl` -- `nil` falls
        # back to the cache default. Without this the sentinel would expire
        # after a day of uptime and a later dispatcher-only restart would
        # spuriously re-arm the window.
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
```

- [ ] **Step 4: Thread the deadline through state and dispatch**

Change `init/1` (line 90):

```elixir
  @impl true
  def init(_opts), do: {:ok, %{startup_arm_until: arm_startup_grace()}}
```

Change `handle_cast/2` (lines 211-215):

```elixir
  @impl true
  def handle_cast({:dispatch_event, map_id, event}, state) do
    do_dispatch(map_id, event, state.startup_arm_until)
    {:noreply, state}
  end
```

In the `:map_kill` clause, take the third argument and use it where the max age is resolved. Replace the head:

```elixir
  defp do_dispatch(map_id, %{type: :map_kill, payload: payload}, startup_arm_until) do
```

Then **move** the `max_killmail_age_seconds` binding out of the `with` chain and above it, alongside `now`. It has to move rather than change in place: a multi-line `if/do/end` cannot be a `with` clause, and neither can the one-line `if cond, do: a, else: b` — the trailing comma that separates `with` clauses is swallowed by the `if`'s keyword list, and the compiler rejects it with *"unexpected expression after keyword list"*. Both forms were verified against `elixir 1.17.3`. Neither depends on anything the `with` binds, so hoisting is free.

Delete the `max_killmail_age_seconds = Env.discord_max_killmail_age_seconds(),` clause (line 237) but **keep the long comment above it** — move it up with the binding. The result, replacing `now = DateTime.utc_now()` at line 224:

```elixir
    now = DateTime.utc_now()
    startup? = within_startup_grace?(startup_arm_until)

    # Resolved ONCE per batch, not per kill: `kill_fresh?/3` runs once per
    # killmail below, and re-reading (and re-validating) config on every one of
    # potentially dozens of kills would turn a single misconfigured deployment
    # into a warning-per-kill log flood. This binding, and the explicit third
    # argument to `kill_fresh?/3` below, must survive any rewrite of this
    # `with` chain -- dropping either silently reopens that flood. Filtering
    # for age happens ONCE, before partitioning: moving it inside the
    # per-destination loop reintroduces the flood.
    #
    # The branch picks WHICH accessor to call. It does not move the call
    # per-kill, and it is deliberately outside the `with` chain -- an `if`
    # cannot be a `with` clause in either its block or its keyword form.
    max_killmail_age_seconds =
      if startup? do
        Env.discord_startup_max_killmail_age_seconds()
      else
        Env.discord_max_killmail_age_seconds()
      end
```

Trim the surviving in-chain comment above `recent` so it no longer refers to a binding that is not there — it keeps only the "filtered BEFORE dedup" paragraph, which is still about the clause it sits on.

Give the other two clauses the argument and ignore it (lines 285 and 303):

```elixir
  defp do_dispatch(map_id, %{type: type}, _startup_arm_until)
```

```elixir
  defp do_dispatch(_map_id, _event, _startup_arm_until), do: :ok
```

Finally, update the two moduledoc/`@doc` references to `do_dispatch/2` at lines 923 and 928 to read `do_dispatch/3`, and add one line to `kill_fresh?/3`'s doc after the `max_age_seconds` paragraph:

```elixir
  During the startup grace window the caller passes
  `Env.discord_startup_max_killmail_age_seconds/0` instead. This function is
  unchanged by that: it already takes the maximum as an explicit argument, so
  both call paths flow through the same comparison.
```

- [ ] **Step 5: Run the new tests and confirm they pass**

Run: `mix test test/unit/external_events/discord_startup_window_test.exs`

Expected: PASS.

- [ ] **Step 6: Run the full Discord suite for regressions**

Run: `mix test test/unit/external_events/`

Expected: PASS. `config/test.exs` sets the grace to `0`, so every pre-existing test resolves `Env.discord_max_killmail_age_seconds/0` exactly as before.

If `discord_dispatcher_test.exs` fails with kills unexpectedly dropped, the cause is almost certainly a leaked sentinel: an earlier test in the same run armed a live window and `config/test.exs` was not picked up. Check the grace value actually in effect rather than loosening an assertion.

- [ ] **Step 7: Format and commit**

```bash
mix format
git add lib/wanderer_app/external_events/discord_dispatcher.ex test/unit/external_events/discord_startup_window_test.exs
git commit -m "fix(discord): suppress replayed killmails after a restart

The dedup marks live in an in-memory Cachex, so a restart loses every
one. The kills client then rejoins its channel, the upstream service
replays recent killmails, and the ordinary 3600-second freshness limit
admits an hour of already-posted kills.

For a grace window after the marks are lost, the freshness filter uses a
much tighter maximum age instead. Replayed history is dropped because it
is old; a killmail that genuinely occurs during the window still posts.

The window is armed from a sentinel in the dedup cache, not from the
dispatcher's own lifecycle. The two are separate children of a
one_for_one supervisor: a dedup-cache-only crash loses every mark while
the dispatcher keeps running, and a dispatcher-lifecycle window would
miss exactly that case. The sentinel holds an absolute monotonic
deadline rather than a TTL, so an expired window is still a present
sentinel and a dispatcher-only restart cannot re-arm it."
```

---

## Task 5: Make dropped killmails visible

A killmail dropped by the startup window currently leaves **no trace at all**: the age filter falls out of the `with` chain into a catch-all `:ok` (`discord_dispatcher.ex:267-269`), and telemetry is emitted only after delivery or an enqueue failure (`:762-766`, `:794-800`). During an incident, "did we suppress it, or did we never receive it?" would be unanswerable — the one question this feature makes worth asking.

Three reasons, not one: conflating them defeats the purpose. `:startup_age` is the new suppression, `:age` is the pre-existing hour limit, `:duplicate` is ordinary dedup.

**Files:**
- Modify: `lib/wanderer_app/external_events/discord_dispatcher.ex` (the `:map_kill` clause, and near `reject_duplicates/2` at `:854-873`)
- Test: `test/unit/external_events/discord_startup_window_test.exs`

**Interfaces:**
- Consumes: `startup_arm_until` and the `startup?` binding from Task 4.
- Produces: telemetry event `[:wanderer_app, :discord_dispatcher, :killmail_dropped]`, measurements `%{count: pos_integer()}`, metadata `%{map_id: String.t(), reason: :startup_age | :age | :duplicate}`. Emitted only when `count > 0`.
- Note the event prefix is `:discord_dispatcher`, matching `:dispatched` and `:not_delivered` — see Deviation 1.
- Produces: one `Logger.info` per batch when `:startup_age` drops anything, carrying the count and the **remaining** window in seconds. Not asserted by the tests below — the telemetry event is the contract; the log line is for a human reading a boot log.

- [ ] **Step 1: Write the failing tests**

Append to `test/unit/external_events/discord_startup_window_test.exs`. This needs the dispatcher's full delivery fixture, so bring in the setup pieces it depends on from `discord_dispatcher_test.exs`.

ExUnit forbids `def`/`defp` inside a `describe` block, so every helper below goes at module level, above the `describe`. Add these aliases to the ones already at the top of the file from Task 4:

```elixir
  alias WandererApp.ExternalEvents.Event
  alias WandererApp.ExternalEvents.Discord.{HttpStub, WorkerSupervisor}
  alias WandererAppWeb.Factory
```

Module-level helpers:

```elixir
  # Mirrors discord_dispatcher_test.exs:185-204. `wh_only` filtering resolves
  # the system class through this cache, and the table behind it is static
  # import data that `mix test` does not populate.
  defp seed_static_info do
    Cachex.put(:system_static_info_cache, 31_000_005, %{
      solar_system_id: 31_000_005,
      solar_system_name: "J115405",
      system_class: 3
    })

    on_exit(fn -> Cachex.del(:system_static_info_cache, 31_000_005) end)
    :ok
  end

  # Restarts the dispatcher with the window closed. The sentinel must be
  # deleted as well as the grace period zeroed: a present sentinel would make
  # the restart reuse the ALREADY-ARMED 600s deadline from `setup` and the
  # config change would do nothing.
  defp restart_with_window_closed do
    put_keys(discord_startup_grace_seconds: 0)
    :ok = stop_supervised!(DiscordDispatcher)
    Cachex.del(DiscordDispatcher.dedup_cache(), DiscordDispatcher.startup_sentinel_key())
    start_supervised!(DiscordDispatcher)
    :ok
  end

  # Collects every drop event raised while `fun` runs, as {reason, count}.
  # Dispatch is a cast, so drain the dispatcher's mailbox before reading.
  defp capture_drops(fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:wanderer_app, :discord_dispatcher, :killmail_dropped],
      fn _event, measurements, metadata, _config ->
        Agent.update(agent, &[{metadata.reason, measurements.count} | &1])
      end,
      nil
    )

    try do
      fun.()
      :sys.get_state(DiscordDispatcher)
      Agent.get(agent, &Enum.reverse/1)
    after
      :telemetry.detach(handler_id)
      Agent.stop(agent)
    end
  end

  defp aged_kill(id, seconds_ago) do
    Factory.build(:killmail, %{
      "killmail_id" => id,
      "solar_system_id" => 31_000_005,
      "kill_time" =>
        DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.to_iso8601()
    })
  end

  defp dispatch(map_id, kills) do
    payload = Factory.build(:kill_event, %{solar_system_id: 31_000_005, killmails: kills})

    DiscordDispatcher.dispatch_event(map_id, %Event{
      map_id: nil,
      type: :map_kill,
      payload: payload
    })
  end
```

The tests:

```elixir
  describe "drop telemetry" do
    setup do
      seed_static_info()

      # `config/test.exs` sets `webhooks_enabled: false` and the dispatcher
      # reads it at call time, so without this override every assertion below
      # would pass while dispatching nothing.
      put_keys(webhooks_enabled: true, discord_startup_grace_seconds: 600)
      clear_sentinel()

      HttpStub.start()
      HttpStub.reset()
      start_supervised!(WorkerSupervisor)
      start_supervised!(DiscordDispatcher)

      map = Factory.insert(:map, %{})

      {:ok, _notification} =
        WandererApp.Api.MapDiscordNotification.create(%{
          map_id: map.id,
          webhook_url: "https://discord.com/api/webhooks/123/tok"
        })

      DiscordDispatcher.invalidate_cache(map.id)

      %{map: map}
    end

    # 5 minutes old: inside the ordinary 3600s limit, outside the 120s startup
    # limit. This is the exact killmail the window exists to suppress.
    test "a kill dropped by the startup window reports :startup_age", %{map: map} do
      drops = capture_drops(fn -> dispatch(map.id, [aged_kill(5001, 300)]) end)

      assert drops == [{:startup_age, 1}]
    end

    # The same kill, with the window closed, is delivered -- proving the drop
    # above is the window's doing and not the ordinary limit.
    test "the same kill is not dropped once the window has closed", %{map: map} do
      restart_with_window_closed()

      drops = capture_drops(fn -> dispatch(map.id, [aged_kill(5002, 300)]) end)

      assert drops == []
    end

    # Two hours old: outside BOTH limits. The reason must stay `:age`, or the
    # two become indistinguishable and the telemetry cannot answer the question
    # it exists for.
    test "a kill older than the ordinary limit reports :age, not :startup_age", %{map: map} do
      restart_with_window_closed()

      drops = capture_drops(fn -> dispatch(map.id, [aged_kill(5003, 7200)]) end)

      assert drops == [{:age, 1}]
    end

    test "a repeated kill reports :duplicate", %{map: map} do
      restart_with_window_closed()
      kill = aged_kill(5004, 10)

      on_exit(fn ->
        Cachex.del(DiscordDispatcher.dedup_cache(), DiscordDispatcher.dedup_key(map.id, 5004))
      end)

      capture_drops(fn -> dispatch(map.id, [kill]) end)
      drops = capture_drops(fn -> dispatch(map.id, [kill]) end)

      assert drops == [{:duplicate, 1}]
    end

    # No event at all when nothing is dropped: a counter that fires with
    # `count: 0` on every healthy batch is noise that buries the real signal.
    test "a fresh kill emits no drop event", %{map: map} do
      restart_with_window_closed()

      drops = capture_drops(fn -> dispatch(map.id, [aged_kill(5005, 10)]) end)

      assert drops == []
    end
  end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `mix test test/unit/external_events/discord_startup_window_test.exs`

Expected: exactly three FAIL — `:startup_age`, `:age`, and `:duplicate` each assert an event where nothing is emitted yet.

The two that assert `drops == []` PASS at this stage, trivially: nothing emits anything. They are regression pins, not drivers, and their passing now is expected — do not "fix" them.

- [ ] **Step 3: Extract the two filters and emit**

In `lib/wanderer_app/external_events/discord_dispatcher.ex`, both filters sit inline in the `with` chain. Move each behind a helper that counts what it removed.

First, beside `startup?` above the `with` (added in Task 4), bind what the log needs. The spec asks the log line to carry the **remaining** window, not the configured maximum — "how much longer will this keep happening?" is the operator's actual next question — and that is only derivable from the deadline:

```elixir
    window = {startup?, startup_grace_remaining_ms(startup_arm_until)}
```

Then change the two filter clauses in the chain:

```elixir
         [_ | _] = recent <-
           filter_fresh(map_id, killmails, now, max_killmail_age_seconds, window),
         [_ | _] = fresh <- reject_duplicates_counted(map_id, recent) do
```

Add the remaining-time helper beside `within_startup_grace?/1`:

```elixir
  # Clamped at zero: a batch can land microseconds after the deadline while
  # `startup?` was computed just before it, and a negative "seconds remaining"
  # in a log line reads as a bug in the window rather than a rounding artifact.
  defp startup_grace_remaining_ms(:never), do: 0

  defp startup_grace_remaining_ms(arm_until) when is_integer(arm_until),
    do: max(arm_until - System.monotonic_time(:millisecond), 0)
```

Add the two wrappers and the emitter beside `reject_duplicates/2` (after line 873):

```elixir
  # Wraps the age filter purely so the drop is counted. A kill dropped for age
  # otherwise falls out of the `with` chain into its catch-all `:ok` and leaves
  # no trace whatsoever, which makes "did we suppress it, or did we never
  # receive it?" unanswerable during an incident.
  defp filter_fresh(map_id, killmails, now, max_age_seconds, {startup?, remaining_ms}) do
    kept = Enum.filter(killmails, &kill_fresh?(&1, now, max_age_seconds))
    dropped = length(killmails) - length(kept)

    emit_dropped(map_id, dropped, if(startup?, do: :startup_age, else: :age))

    # At info, not debug: this fires at most once per batch, only while the
    # startup window is armed, and it is the line an operator searches for when
    # a restart looks too quiet. Ordinary age and dedup drops stay
    # telemetry-only -- they are steady-state behaviour, not an event.
    if startup? and dropped > 0 do
      Logger.info(fn ->
        "[Discord] startup grace window suppressed #{dropped} replayed killmail(s); " <>
          "#{div(remaining_ms, 1000)}s of the window remain"
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
```

Leave `reject_duplicates/2` itself untouched — its `seen` accumulator logic is load-bearing and this task must not disturb it.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix test test/unit/external_events/discord_startup_window_test.exs`

Expected: PASS.

- [ ] **Step 5: Run the full Discord suite**

Run: `mix test test/unit/external_events/`

Expected: PASS.

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/wanderer_app/external_events/discord_dispatcher.ex test/unit/external_events/discord_startup_window_test.exs
git commit -m "feat(discord): report why a killmail was not posted

A killmail dropped for age or as a duplicate left no trace at all: the
filters fall out of the with chain into a catch-all :ok, and telemetry
fired only after delivery or an enqueue failure. That made 'did we
suppress it, or did we never receive it?' unanswerable -- the one
question the new startup window makes worth asking.

Emits [:wanderer_app, :discord_dispatcher, :killmail_dropped] with
%{count: n} and a reason of :startup_age, :age, or :duplicate. Three
reasons rather than one, because conflating the new suppression with the
pre-existing hour limit would defeat the point. Silent when nothing was
dropped.

Prefix is :discord_dispatcher, matching :dispatched and :not_delivered
-- a drop is a dispatch outcome. The :discord prefix in this module
belongs to the enrichment events.

One throttled Logger.info per batch for :startup_age only."
```

---

## Final gate

Run after all five tasks land, before opening a PR.

- [ ] **Step 1: Full test suite**

Run: `mix test`

Expected: PASS. If something outside `external_events/` and `kills/` fails, suspect Task 1's blast radius first — the index change affects the in-app kills widget.

- [ ] **Step 2: Formatting, compile warnings, static analysis**

```bash
mix format --check-formatted
mix compile --warnings-as-errors --force
mix credo --strict
mix dialyzer
```

Expected: clean. Dialyzer matters here specifically: `do_dispatch/2` became `do_dispatch/3` across three clauses, and a missed clause is exactly the kind of arity mismatch it catches.

- [ ] **Step 3: Confirm the invariants survived**

Read the final diff of `discord_dispatcher.ex` and check by eye:

- No `Env.` call sits inside a per-killmail loop. The once-per-batch comments at `:230-237` and in `kill_fresh?/3`'s doc are intact and still accurate.
- `system_on_map?/2` and `arm_startup_grace/0` both still have their `rescue`, and both still fail in the *permissive* direction.
- `reject_duplicates/2`'s `seen` accumulator is unchanged.
- Nothing moved a dedup mark to after delivery confirmation.

- [ ] **Step 4: Document the new configuration**

Check whether `.env.example`, `README.md`, or `docs/` document `DISCORD_MAX_KILLMAIL_AGE_SECONDS` or the `:external_events` keys:

```bash
grep -rn "discord_max_killmail_age_seconds\|DISCORD_MAX_KILLMAIL_AGE" --include=*.md --include=*.exs --include=.env.example .
```

If the existing key is documented anywhere, add the two new ones alongside it in the same style, with their defaults and the meaning of `0` for the grace period. If it is documented nowhere, skip this step — do not start a new convention as a side effect of a bug fix.

- [ ] **Step 5: Final commit**

```bash
mix format
git add -A
git commit -m "chore(discord): document the startup grace configuration"
```

Skip this commit entirely if Step 4 found nothing to document.
