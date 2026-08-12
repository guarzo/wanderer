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

**Name the scout.** Credit the character whose system-add opened the route, with
their portrait in the embed's author line — attribution as the incentive to keep
labels accurate.

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

- **`added_at` is a dead column.** Declared in migration `20240523202445`,
  serialized to the frontend via `@derive Jason.Encoder` and the JSON:API
  `default_fields`, and **written by no code path in `lib/`**. It is always
  `nil`.
- **`inserted_at` records the first-ever add.** The `:upsert` action uses
  `upsert_identity :map_solar_system_id`, so re-adding a previously removed
  system updates the existing row rather than inserting a new one.
- **`updated_at` tracks any edit** — a rename, a drag, a status change — not the
  add.
- There is no character relationship on the resource. `owner_id` /
  `owner_ticker` are the zoo structure-owner fields (corp/alliance), unrelated.

The `:system_added` `UserActivity` row is the only record that carries the add
and its author together (`map_server_systems_impl.ex:976`). It is written with
`character_id`, and its `event_data` is
`Jason.encode!(%{solar_system_id: id})` — `SecurityAudit.track_map_event/2`
drops `character_id`, `user_id` and `map_id` before encoding, leaving a
deterministic single-key JSON string that can be matched exactly rather than
scanned with `LIKE`.

This collapses the lookup: the newest matching row identifies both the hop that
opened the route *and* the character to credit, in one query.

Fixing `added_at` is out of scope — it needs its own migration and a backfill
decision.

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
to `Route opened` when no scout resolves.

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

- Task in flight → `%{state | rerun?: true, settle_confirmed?: true,
  settle_ref: nil}`. The existing `land_result/2` `rerun?` branch discards the
  in-flight answer and restarts the solve; no new concurrency path is
  introduced.
- Otherwise → `start_evaluation(%{state | settle_confirmed?: true,
  settle_ref: nil})`.

`settle_confirmed?` is cleared on **every** transition that does not publish —
`:none`, `:unknown`, and the silent `{:qualifying, _old}` branch (route still
qualifies but at the same or a worse jump count). Otherwise a confirmed flag
would survive into a later, unrelated transition and let it publish without its
own hold. `start_evaluation/2`'s disable/config-change branch cancels
`settle_ref` and clears `settle_confirmed?` along with the existing state reset.

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

One `UserActivity` read, served by the existing
`[:entity_id, :event_type, :inserted_at]` index:

```
entity_id  == map_id
event_type == :system_added
event_data in  [Jason.encode!(%{solar_system_id: id}) || id <- path]
sort inserted_at desc, limit 1
```

then load `:character` for `name` and `eve_id`.

Returns `nil` on: no matching row; a row whose `character_id` is `nil` (systems
added through the API record no character — `SecurityAudit.track_map_event/2`
no-ops without both `character_id` and `user_id`); a missing or deleted
character; or any raised error, which is caught and logged at debug.

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
- `:shortened` transitions hold on the same rule.
- Disabling route alerts mid-hold cancels it.
- `RouteScout` returns the newest hop's character; returns `nil` for each
  fallback path.
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
