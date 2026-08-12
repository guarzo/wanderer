# Route alerts: settle delay and scout attribution

**Date:** 2026-08-12
**Status:** Design approved, pending implementation
**Touches:** `Discord.RouteWatcher`, `Discord.EmbedFormatter`, new `Discord.RouteScout`

## Problem

Two independent complaints about the same message.

### 1. The footer's safety guarantee is frequently false

`EmbedFormatter` stamps every route alert with:

```
highsec only · no EOL · no crit · no frigate holes
```

pinned by `route_guarantee_settings/0` to `Evaluator`'s solver settings
(`include_eol: false`, `include_mass_crit: false`, `include_frig: false`).

Those three filters read `mass_status`, `time_status` and `ship_size_type` on
`map_chain_v1`. All three are **user-entered labels with permissive defaults**
(`map_connection.ex`: `mass_status` default `0`, `time_status` default `0`,
`ship_size_type` default `2` = Large). A connection nobody has assessed yet
therefore passes all three filters.

The alert fires the instant a route qualifies — which is typically the moment a
scout adds the connection, seconds before they label it. So the message
routinely promises "no crit" about a hole that is about to be marked crit.

Only "highsec only" is a real claim; it derives from static system data
(`Evaluator.system_qualifies?/2`), not from user input.

### 2. The embed is plain, and nothing rewards accurate labelling

The embed is text-only. Nobody is named in it, so there is no personal stake in
whether the chain data behind it is correct.

## Approach

**Wait, then re-solve.** Hold a qualifying transition for 2 minutes, re-run the
solver, and publish only if the route still qualifies. A hole marked crit
during the window disqualifies the route and the alert is never sent.

This fixes the bug at its source rather than hedging the wording: the footer
stays as written, and becomes true far more often because the labels have
caught up by the time the claim is made.

**Name the scout.** Credit the character whose recent system-add or
connection-add opened the route, with their portrait in the Discord embed's
author line — attribution as the incentive to keep labels accurate. When no
recent add explains the route, nobody is named.

## Decisions

### D1. Hold for 2 minutes, then re-solve — not reword, not suppress

Considered and rejected:

- **Reword the footer** to a claim about labels ("nothing *marked* EOL, crit or
  frigate"). Honest and free, but leaves the alert itself just as misleading in
  practice — the reader still has to scout a route the message implied was safe.
- **Per-hop freshness gate**: hold only until the youngest wormhole connection
  on the path is 2 minutes old, publishing immediately when every hop is older.
  More precise, but the transition that fires an alert is nearly always *caused*
  by a just-added connection, so the extra precision buys little for the cost of
  threading connection rows and age arithmetic into the watcher.

2 minutes, not 5: labelling happens almost immediately when it happens at all,
and a route alert is perishable — the chain it runs through can roll within the
hour.

**Accepted cost:** every alert is up to 2 minutes later than today, including
alerts through chains mapped hours ago.

**Residual risk (accepted):** the footer remains a claim about labels, not about
reality. A hole nobody ever marks still produces a "no crit" alert. The delay
raises the probability the claim is true; it does not make it a guarantee.

### D2. The hold lives at the transition point, not in the debounce

`RouteWatcher` already has a 10s debounce with a 60s ceiling
(`@debounce_ms` / `@ceiling_ms`). That mechanism coalesces *notifications*; this
one waits for *human labelling*. They are different clocks and must not be
conflated — lengthening the debounce would delay the solve, not the decision,
and would still read stale labels when it finally ran.

So the hold goes where `transition/3` currently calls `alert/6`.

### D3. Attribution resolves through the audit trail, not `MapSystem`

`MapSystem` cannot answer "who added this system, and when":

- **`added_at` is written by nothing in `lib/`.** Declared in migration
  `20240523202445` and serialized to the frontend via `@derive Jason.Encoder`.
  It is *not* in the JSON:API `default_fields` (`map_system.ex:53`), but it
  **is** in `default_accept` and the `:create` accept list
  (`map_system.ex:147`) — alongside the zoo fields marked "for map
  duplication" — so an external JSON:API caller can set it. "Always nil" is
  therefore the observed state, not an invariant, which makes it unsafe to
  order by even if it were populated.
- **`inserted_at` records the first-ever add.** The `:upsert` action uses
  `upsert_identity :map_solar_system_id`, so re-adding a previously removed
  system updates the existing row rather than inserting a new one.
- **`updated_at` tracks any edit** — a rename, a drag, a status change — not the
  add.
- There is no character relationship on the resource. `owner_id` /
  `owner_ticker` are the zoo structure-owner fields (corp/alliance), unrelated.

The `UserActivity` audit rows are the only records carrying a map change and its
author together, and `SecurityAudit.track_map_event/2` drops `character_id`,
`user_id` and `map_id` before encoding `event_data`, leaving deterministic JSON
that can be matched exactly rather than scanned with `LIKE`:

- `:system_added` → `Jason.encode!(%{solar_system_id: id})`
  (`map_server_systems_impl.ex:976`)
- `:map_connection_added` → `Jason.encode!(%{solar_system_source_id: s,
  solar_system_target_id: t})` (`map_server_connections_impl.ex:789`)

Fixing `added_at` is out of scope — it needs its own migration and a backfill
decision.

### D3a. Attribute the *cause*, not the newest system on the path

Crediting "the newest `:system_added` row for any system on the path" conflates
recency with causality, and would regularly name the wrong person.

`DiscordDispatcher.do_dispatch/2` re-evaluates route alerts on **five** event
types (`discord_dispatcher.ex:295`):

```
:add_system, :connection_added, :connection_updated,
:connection_removed, :deleted_system
```

So a route can open with no system add anywhere near it — someone clears a crit
label on an existing connection (`:connection_updated`), or links two systems
that were mapped hours ago (`:connection_added`). The newest `:system_added` row
on that path could then be days old, and the alert would put a name and a
portrait on work that person did not do, in a channel their corp reads.

Two constraints follow:

1. **Both add events are candidates.** The query considers `:system_added` rows
   for systems on the path *and* `:map_connection_added` rows whose source and
   target are an adjacent pair on the path. The newest of the union wins.
2. **The winner must be recent.** It must fall within `@attribution_window`
   (15 minutes) of the moment of attribution. Nothing recent enough means **no
   attribution** — the alert sends with the plain author line.

The window is generous relative to the 2-minute settle hold, so an ordinary
scan-add-label-alert sequence always attributes, while a route that opens
because of a label edit — an event that credits nobody, since
`:connection_updated` is not an add — falls through to no attribution rather
than to a stale name.

**Accepted limitation:** a route opened purely by a `:connection_updated` label
edit gets no attribution, even though a real person caused it. Crediting label
edits would mean naming whoever marked a hole *non*-crit, which is a different
and weaker claim than "scouted"; the author line says `scouted by`, and it
should stay true.


### D4. Portrait in the author line

Discord embeds offer three image slots: the left colour stripe, a 72px
thumbnail, and a full-width bottom image. Chosen: a 24px `author.icon_url`.

- A 72px thumbnail plus a "Scouted by" field makes the face the loudest element
  of a logistics alert and squeezes the path text on a long chain.
- The bottom `image` slot would make every route alert taller than the kill
  embeds sharing its channel, pushing the footer off a phone screen.

There is no per-region background tint available; the colour stripe is already
carrying the opened/shortened distinction (`@color_route_opened` /
`@color_route_improved`) and is not reused for region.

### D5. Attribution is best-effort and never costs a delivery

Every failure path falls back to today's plain author line and still sends the
alert.

## Behaviour

### Before

A qualifying route posts within one debounce window (~10s, ceiling 60s) of the
change that created it. Author line reads `Route opened` / `Route shortened`.

### After

A qualifying transition is held 2 minutes and re-solved. If it still qualifies,
it posts; if it does not, nothing is sent. The author line reads
`Route opened · scouted by Kraven Ordos` with the scout's portrait, falling back
to `Route opened` whenever no recent add explains the route (see D3a).

Title, description (path), exit field, colours, footer, timestamp, mention
behaviour: unchanged.

## Implementation

### `RouteWatcher` — the settle hold

New state keys: `settle_ref` (timer reference or `nil`) and `settle_confirmed?`
(boolean, default `false`).

`transition/3`, qualifying branch:

- `settle_confirmed?: false` → arm `Process.send_after(self(), :settle, @settle_ms)`
  **only if `settle_ref` is nil**, emit `:held` telemetry, return state
  unchanged. Deliberately **no** optimistic `persist/1`: `route_state` keeps its
  previous value, so nothing needs reverting and the existing
  revert-on-delivery-failure logic in `alert/6` and `deliver_alert/8` is
  untouched.
- `settle_confirmed?: true` → publish through `alert/6` exactly as today, then
  clear both `settle_confirmed?` and `settle_ref`.

`handle_info(:settle, state)`:

- Cancel any pending debounce timer first (`settle_ref: nil`, and
  `timer_ref: nil` after `Process.cancel_timer/1`) — see "One solve at a time"
  below.
- Task in flight → `%{state | rerun?: true, settle_confirmed?: true}`. The
  existing `land_result/2` `rerun?` branch discards the in-flight answer and
  restarts the solve.
- Otherwise → `start_evaluation(%{state | settle_confirmed?: true})`.

#### One solve at a time

Today the watcher never runs two solves concurrently, but the invariant is
implicit: `arm_timer/1` is only reachable from `handle_cast(:notify, ...)`'s
`task == nil` clause (`route_watcher.ex:124`), so an `:evaluate` message can
never be pending while a task is in flight, and `handle_info(:evaluate, ...)`
(`route_watcher.ex:146`) therefore needs no guard of its own.

Adding a second timer that can call `start_evaluation/1` breaks that. A notify
at T−1s arms `:evaluate` for T+9s; `:settle` fires at T and launches a solve;
the `:evaluate` at T+9s calls `launch_task/2` again, which overwrites
`state.task` and `state.task_deadline_ref` (`route_watcher.ex:254`). The first
task is orphaned — its result falls through to the "late reply" clause and is
discarded, and its deadline message is never cancelled.

Two changes restore the invariant explicitly:

1. `:settle` cancels any pending `timer_ref` before evaluating, as above.
2. `handle_info(:evaluate, ...)` guards on `state.task`: if a task is already
   in flight, set `rerun?: true` instead of launching, matching what
   `handle_cast(:notify, ...)` already does in the same situation.

Change 2 is a no-op for today's behaviour — it makes an existing implicit
invariant explicit — and it is what keeps the guarantee from depending on the
exact interleaving of two timers.

#### Clearing `settle_confirmed?`

The flag must be cleared on **every** path that consumes a confirmation without
publishing. Otherwise it survives into a later, unrelated transition and lets
that one publish with no hold of its own — silently reintroducing the bug this
design exists to fix.

Transitions that do not publish:

- `:none` and `:unknown`.
- The silent `{:qualifying, _old}` branch (route still qualifies, at the same or
  a worse jump count).

Paths that return early without reaching `transition/3` at all — each must clear
the flag too:

- `start_evaluation/1` when `load_notification/1` returns `:error`
  (`route_watcher.ex:223`).
- `launch_task/2` when `Discord.TaskSupervisor` is not running
  (`route_watcher.ex:279`).
- `handle_info({:task_timeout, ref}, ...)` when the killed task was the
  settle-confirmation solve and `rerun?` is false (`route_watcher.ex:188`).

In all three the confirmation is lost and the route is simply re-held on the
next notify, which is the conservative direction: a late alert, never an
unheld one.

`start_evaluation/2`'s disable/config-change branch cancels `settle_ref` and
clears `settle_confirmed?` along with the existing state reset.


**The timer is armed once per hold and never re-armed.** Re-arming on each
intervening notify would starve a chain under continuous scanning of alerts
entirely — the same failure `@ceiling_ms` already exists to prevent.

`@settle_ms 120_000`, overridable via `start_link` opts like `@debounce_ms` and
`@ceiling_ms`, so tests do not wait two minutes.

### `Discord.RouteScout` — new module

```elixir
@spec resolve(map_id :: binary(), path :: [integer()]) ::
        %{name: String.t(), eve_id: String.t()} | nil
```

Per D3a the candidates span two event types. Both are served by the existing
`[:entity_id, :event_type, :inserted_at]` index, whose `entity_id, event_type`
prefix is what the filter uses:

```
entity_id  == map_id
inserted_at >= now - @attribution_window
( event_type == :system_added
    and event_data in [Jason.encode!(%{solar_system_id: id}) || id <- path] )
  or
( event_type == :map_connection_added
    and event_data in [encoded pair || {s, t} <- Enum.zip(path, tl(path))] )
sort inserted_at desc, limit 1
```

Connection pairs are encoded in both orientations —
`%{solar_system_source_id: s, solar_system_target_id: t}` and the reverse —
because the recorded source/target follow the direction the character jumped,
not the direction the solved route runs.

Then load `:character` for `name` and `eve_id`.

`@attribution_window 15 * 60 * 1000`.

Returns `nil` on: no row inside the window; a row whose `character_id` is `nil`
(systems added through the API record no character —
`SecurityAudit.track_map_event/2` no-ops without both `character_id` and
`user_id`); a missing or deleted character; or any raised error, which is
caught and logged at debug.

**Accepted lossiness.** `user_activity_v1` has a unique index on
`[:entity_id, :event_type, :inserted_at]` (`user_activity.ex:24`) that covers
neither `event_data` nor `character_id`, so two same-type events on one map
sharing an `inserted_at` microsecond collide. `SecurityAudit.track_map_event/2`
logs the insert failure and `ActivityTracker.track_map_event/2` converts it to
`{:ok, nil}` (`security_audit.ex:229`, `user_activity_tracker.ex:17`), so the
losing row is silently absent from this lookup. The consequence here is a
missing or differently-attributed scout on a bulk add, never a wrong delivery —
`resolve/2` returns `nil` and the alert sends with the plain author line. Not
worth changing the audit schema for; it gets a test asserting the fallback, not
a fix.

Called from `deliver_alert/8` and passed into the alert map as `:scout`.
Synchronous DB work in the watcher process matches existing practice there
(`load_notification/1`, and `EmbedFormatter.map_url/1`'s own lookup).

Requires a new `read` action on `WandererApp.Api.UserActivity` plus its
`code_interface` `define` entry, per the repo's Ash conventions.

### `EmbedFormatter`

`route_embed/1`'s author map gains `icon_url` when `alert[:scout]` is present:

```elixir
%{
  "name" => truncate(route_author_name(alert), @max_author_length),
  "icon_url" => "#{@image_base}/characters/#{scout.eve_id}/portrait?size=64"
}
```

with `route_author_name/1` producing `"#{route_kind_label(kind)} · scouted by
#{scout.name}"` when a scout is present and `route_kind_label(kind)` otherwise.

New `@max_author_length 256` (Discord's author-name bound). Author text already
counts toward `@max_message_text` in `embed_text_length/1`, so no change there.

`format_route_alert/2` must tolerate an alert map with no `:scout` key, so
existing callers and tests keep working.

## Verification

New tests:

- A qualifying transition sends nothing immediately, and sends after the settle
  window elapses.
- A route that stops qualifying during the window sends **nothing** — the
  regression test for the reported bug.
- Notifies during the window neither publish early nor extend the deadline.
- A confirmed hold that lands on the silent `{:qualifying, _old}` branch clears
  the flag rather than arming a later transition to publish unheld.
- Each early-return path clears `settle_confirmed?`: `load_notification/1`
  failure, absent `Discord.TaskSupervisor`, and a settle-confirmation solve
  killed by `:task_timeout` with `rerun?` false. In each case the *next*
  qualifying transition must hold again rather than publish immediately.
- A notify landing just before `:settle` does not produce two concurrent solver
  tasks — the pending debounce timer is cancelled, and `:evaluate` arriving with
  a task in flight sets `rerun?` instead of launching.
- `:shortened` transitions hold on the same rule.
- Disabling route alerts mid-hold cancels it.
- `RouteScout` attributes a route opened by `:map_connection_added` to the
  character who added that connection, in either source/target orientation.
- `RouteScout` returns `nil` — and the alert still sends with the plain author
  line — when the only candidate row is older than `@attribution_window`, when
  the route opened via `:connection_updated` with no add behind it, when
  `character_id` is nil, and when the audit row was lost to a unique-index
  collision.
- The embed renders the portrait and the attributed author line, and renders the
  plain author line when `:scout` is absent.

Existing suites that must stay green: `route_watcher_test.exs`,
`embed_formatter` route-alert cases, and the `route_guarantee_settings/0`
drift test (unchanged — the footer string and solver settings are not touched).

Baseline before implementation: 345 tests, 0 failures across
`test/unit/external_events/discord/` and `test/unit/map/route_alert/`.

Also run: `mix format`, `mix credo`.

## Out of scope

- Rewording `@route_guarantee`.
- Writing or backfilling `MapSystem.added_at`.
- Per-region embed colours.
- Any change to `Evaluator`, its solver settings, or the mention mechanism.
