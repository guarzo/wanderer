# Discord route alerts — design

Date: 2026-08-07
Status: approved for planning

## Intent

Post a Discord message when a change to a map's topology opens a short,
highsec-only route from the map's home system to Jita.

The user request: "notify when new systems are added to the map that make a
route from the home system to Jita in less than 6 jumps (that don't include
null-sec or low-sec)."

This is a sibling of the existing kill notification feature, reusing its
configuration table, its per-webhook delivery queue, and its embed formatter.

## Repository evidence

**Branch dependency.** Every claim below about the Discord stack
(`DiscordDispatcher`, `Discord.Router`, `Discord.WorkerSupervisor`,
`MapDiscordWebhook`, `MapDiscordNotification`) was inspected on **`guarzo/zoo`**,
where the kill-notification feature lives. None of it exists on `origin/main`.
This feature must be built on a branch derived from `guarzo/zoo`; a worktree cut
from `main` will not compile against this design. The route-solver claims
(`map_routes.ex`, `esi/api_client.ex`) were verified on both branches and are
identical.

Facts established by inspection, with the constraints each imposes.

| Evidence | Constraint it imposes |
|---|---|
| `MapEventRelay` forwards *every* event type to `DiscordDispatcher` (`map_event_relay.ex:164`); non-kill events fall into the catch-all `do_dispatch/2` clause | The hook point already exists. No relay change is needed. |
| `DiscordDispatcher` is a **singleton** GenServer whose moduledoc argues at length for bounding the two enrichment steps that block it | The route solver must never run on this process. |
| `Routes.find/5` is a blocking HTTP call to the route builder (30s receive timeout); every LiveView caller wraps it in `Task.async` (`map_routes_event_handler.ex:98`) | Evaluation runs in a supervised task with an explicit budget. |
| `Routes.find/5` caches on a hash of `params`, and `params` includes the *filtered connection list* (`map_routes.ex:203`, key built at `:225`) | A topology change misses the cache **only when it changes that list**. `:add_system` alone does not, so an add-then-link pair costs one round trip, not two. Debouncing is still worth having, but the cache — not the debounce — is what bounds solver load. |
| `Routes.find/5` swallows solver errors into `{:ok, %{routes: [], systems_static_data: []}}` (`map_routes.ex:75-77`), **and** falls back to `Esi.get_routes_eve/4` on a custom-route error (`map_routes.ex:249`), which is currently a stub returning `success: false` per hub inside `{:ok, ...}` (`esi/api_client.ex:76`) | `Routes.find/5` **cannot** distinguish outage from no-path. See "Distinguishing failure from no-route". |
| `do_find_routes/4` calls `String.to_integer/1` on both `origin` and each hub (`map_routes.ex:94-95`) | `origin` and `hubs` must be **strings**. Passing an integer `home_system_id` raises. |
| `MapDiscordWebhook.role` is stored as `:text` with an Ash `one_of` constraint (`map_discord_webhook.ex:199`) | Adding `:route` needs **no DB migration**. |
| `unique (notification_id, role)` identity (`map_discord_webhook.ex:229`) | One route webhook per map, enforced by the database. |
| `Router` moduledoc: the role reaching `SystemName.display_name/3` must be a literal matched atom, never a threaded variable, because that resolver is the map-local-names privacy boundary | A `:route` clause must be written explicitly, not passed through. |
| `SystemClass.wormhole_classes/0` is the canonical wormhole class list | Reuse it; do not restate class ids. |
| No "home system" concept exists anywhere in the codebase | It must be introduced. `Map.hubs` is a different, user-facing feature and is not reused. |

## Decisions

### 1. Trigger — any topology change, debounced

Re-evaluate on `:add_system`, `:connection_added`, and `:connection_updated`.

Adding a system never creates a route by itself: a system appears with no edges,
and the path only becomes reachable when the connection is added — usually
milliseconds later, sometimes much later when someone drags a link manually.
`:connection_updated` is included because an EOL or mass-crit flag change alters
which paths the solver will accept.

Triggering on `:add_system` alone would be the literal reading of the request and
would silently never fire for the common scan-then-link workflow.

### 2. Home system — a field on the Discord notification config

`home_system_id` lives on `MapDiscordNotification`, not on `Map`.

The Discord settings LiveView component already exists and can host the field,
so no new settings surface is needed. Scoping it to this feature also avoids
asserting a definition of "home" that the rest of the application would then
have to honour.

`Map.hubs` is deliberately not reused: it is an existing user-facing list with
different semantics, and reordering hubs for the routes widget would silently
change who gets alerted.

### 3. Jump counting — total hops in the full path

Every hop in the solver's path counts, wormhole and gate alike. A chain three
wormholes deep with a highsec exit two gates from Jita is five jumps.

This matches what the routes widget already shows the user, so the alert and the
UI agree. Counting only k-space gate jumps would report a nine-wormhole-deep
chain as "3 jumps".

### 4. Security rule — highsec k-space only, wormholes exempt

A path qualifies when every **non-wormhole** system on it has security >= 0.45.

- Wormhole systems (`SystemClass.wormhole_classes/0`) are exempt. J-space
  security is approximately -1.0, so a naive `security >= 0.5` filter would
  classify every wormhole in the map's own chain as nullsec and reject every
  route. The chain is how you get out; it is not part of the security claim.
- The threshold is **0.45, not 0.5**. EVE rounds 0.45 up to 0.5 for display, so
  0.5 would wrongly reject genuine highsec systems.
- Pochven/Triglavian and Edencom systems are excluded via solver settings
  (below). Zarzakh is already in `@default_avoid_systems` (`map_routes.ex:40`).
- The `security` value from `CachedInfo.get_system_static_info/1` is not reliably
  a float — `RouteBuilderClient.parse_security/1` handles float, integer, and
  binary forms. The Evaluator must parse the same three shapes, and an
  unparseable value disqualifies the route (see "Failure posture").

### 5. Threshold — `route_max_jumps`, inclusive, default 5

"Less than 6 jumps" literally means at most 5. The column is an **inclusive**
upper bound with a default of `5`, so the shipped behaviour matches the request
exactly and the UI reads honestly: "max jumps: 5" is the same set as "fewer than
6".

A default of `6` compared with `<` would make the stored number mean something
different from what it says. This is the one ambiguity in the request that was
resolved by decision rather than by asking, and it is recorded here for that
reason.

### 6. Destination — Jita hardcoded

`30000142`, a module constant. Only `route_max_jumps` is user-configurable.
Supporting other trade hubs is a later change, not a launch requirement.

### 7. Discord destination — new `:route` role, falling back to `:system`

`:route` joins the `MapDiscordWebhook` role enum. When no `:route` row exists,
route alerts go to the `:system` webhook — the same fallback pattern `Router`
already uses for `:character`.

Existing maps therefore need no configuration, and a separate logistics channel
is purely opt-in.

Disabled destinations **drop; they do not reroute**, matching the rule
`RouterTest` asserts deliberately today.

### 8. Solver settings — fixed server-side, tuned for hauling

There is no user in this code path, so settings are pinned rather than read from
any widget preference:

```elixir
%{
  include_eol: false,
  include_mass_crit: false,
  include_frig: false,
  include_cruise: true,
  avoid_pochven: true,
  avoid_edencom: true,
  avoid_triglavian: true,
  include_thera: false
}
```

`include_mass_crit: false` and `include_frig: false` differ from the module
defaults: the alert exists for logistics, and a crit or frigate-sized connection
will not pass a hauler.

`include_thera: false` is the non-obvious one. A Thera-based path can qualify
without anything on the map changing, so including it would attribute a
public-data route to whatever unrelated system someone happened to add. Keeping
it off means every alert is genuinely caused by the map's own chain.

## Architecture

### Components

| Module | Responsibility |
|---|---|
| `Discord.RouteWatcher` | GenServer, one per map. Owns the debounce timer, the last-known-route state, its `config_version`, and the solver task ref. Never blocks on the task. Nothing else touches route state. |
| `Discord.RouteWatcherSupervisor` | `DynamicSupervisor` + `Registry`, started only when webhooks are globally enabled. Mirrors `Discord.WorkerSupervisor`. Exposes `notify(map_id)`, starting the watcher on demand. |
| `Map.RouteAlert.Evaluator` | Pure function: solver output + settings -> `{:qualifying, %{jumps:, path:, exit_system:}}` \| `:none` \| `:unknown`. All security and jump-counting rules live here. Its three return values are exactly the watcher's three states, so the watcher does no translation. |
| `Map.MapRoutes.find_strict/5` | New sibling of `find/5` in an existing module. Identical params assembly and caching; returns `{:error, reason}` instead of falling back to the `get_routes_eve/4` stub. The only change to existing source. |
| `Discord.EmbedFormatter.format_route_alert/2` | New function on the existing formatter. |
| `Discord.Router.route_destination/1` | `:route` webhook, falling back to `:system`, with the existing disabled-drops rule. |

Keeping the Evaluator separate from the Watcher is the main structural call: it
means every rule in the request is verified with synthetic input, without
standing up a GenServer or mocking a route builder.

### Why a per-map GenServer

Considered and rejected:

- **Stateless tasks with Cachex debounce.** Least code, but cache-based
  check-then-set is racy: two events 50ms apart can both pass and produce two
  concurrent solver calls and two alerts for one change. Fixing it properly means
  reinventing a per-map serialization point, which is what the watcher already is.
- **Global dirty-set sweeper.** Coalescing is free and it is the one place to
  bound route-builder load instance-wide — a genuine advantage, since that service
  is shared. Traded away for up to 30s of latency and a single point of failure.
  **This is the documented escape hatch** if route-builder load becomes a problem:
  the watcher's internals barely change, only who calls it.

### Data flow

1. `map_server_systems_impl.ex:943` / `map_server_connections_impl.ex:779`
   broadcast the topology events (unchanged).
2. `MapEventRelay` fans them to `DiscordDispatcher` (unchanged).
3. A new `do_dispatch/2` clause matches the three topology types, checks the
   global gate and the **already-cached** notification config for
   `route_alerts_enabled?` and a non-nil `home_system_id`, then casts
   `RouteWatcherSupervisor.notify(map_id)`. No DB hit, no HTTP; the singleton
   never blocks.
4. The watcher arms a 10s debounce timer, re-arming on each notify, with a 60s
   ceiling so a continuously-scanned chain is still evaluated.
5. On fire: `Task.Supervisor.async_nolink` running

   ```elixir
   Routes.find_strict(
     map_id,
     [@jita_system_id_str],
     Integer.to_string(home_system_id),
     @solver_settings,
     false
   )
   ```

   **Both `origin` and `hubs` must be strings.** `do_find_routes/4` calls
   `String.to_integer/1` on each (`map_routes.ex:94-95`), so passing the integer
   `home_system_id` straight through raises on every evaluation. `@jita_system_id_str`
   is the constant `"30000142"`; the conversion of `home_system_id` happens at the
   call site, not in the schema — the column stays an integer.

   **The trailing `false` is `hubs_limit_reached?`, not "avoid wormholes".**
   `find/5`'s `true` clause (`map_routes.ex:80-91`) skips the solver entirely and
   fabricates a `success: false` placeholder per hub; its only callers pass
   `is_hubs_limit_reached` (`map_routes_event_handler.ex:96,105`). Route alerts
   always pass `false`. Reading it as "avoid wormholes" and passing `true` would
   silently disable the feature while looking like a security tightening.

6. **The watcher does not block on the task.** It stores `{task_ref, started_at}`
   in its state and returns immediately, handling the result in
   `handle_info({ref, result}, state)` and the failure in
   `handle_info({:DOWN, ref, ...}, state)`. A `Process.send_after/3` deadline
   message enforces the 20s budget and calls `Task.shutdown(task, :brutal_kill)`
   from the timeout handler.

   `Task.yield(20_000) || Task.shutdown(:brutal_kill)` — the idiom the enrichment
   steps in `DiscordDispatcher` use — is **wrong here**. It parks the watcher for
   up to 20 seconds, during which it cannot receive the notify messages that are
   supposed to set the re-run flag. Those messages would sit in the mailbox and be
   processed *after* the stale result was already published, so a connection
   closing mid-solve could still produce an "opened" alert. The dispatcher can
   afford to block because it is enriching a payload it already holds; the watcher
   cannot, because incoming events invalidate the work in flight.

   Notifies arriving mid-solve set a re-run flag rather than queuing timers; the
   result handler re-arms immediately when the flag is set, and **discards** the
   in-flight result rather than publishing it.

7. Evaluate, compare with previous state, and on a reportable transition format
   and call `WorkerSupervisor.deliver(webhook.id, [message])`, reusing the
   existing per-webhook rate-limited HTTP queue.

## Alert semantics

State per map is three-way, not a boolean:
`:unknown` (never successfully evaluated) | `:none` | `{:qualifying, jumps}`.

| Transition | Action |
|---|---|
| `:unknown` or `:none` -> qualifying | Post "opened" |
| qualifying(j) -> qualifying(k), k < j | Post "improved to k jumps" |
| qualifying(j) -> qualifying(k), k >= j | Silent; store k |
| qualifying -> none | Silent clear, so a reopen alerts again |

### Distinguishing failure from no-route

`Routes.find/5` returns `{:ok, ...}` even when the route builder fails. Reading
that as "no route" would silently clear state during an outage, and recovery
would re-announce a route that never closed.

**`Routes.find/5` as it stands cannot make this distinction, and the design
must not pretend otherwise.** On a custom-route error it falls back to
`Esi.get_routes_eve/4` (`map_routes.ex:249`), whose body is currently a stub: the
real per-destination call is commented out, and it fabricates one
`%{"success" => false}` entry per hub and wraps it in `{:ok, ...}`
unconditionally (`esi/api_client.ex:76`). An outage therefore produces a payload
**byte-identical** to a genuine no-path. Building the three-state model on top of
`Routes.find/5` would clear state during every outage and fire a false "route
opened" alert on recovery — the exact failure the three-state model exists to
prevent.

**Resolution: a strict variant.** Add `Routes.find_strict/5` alongside
`Routes.find/5` in `map_routes.ex` — same signature, same params assembly, same
cache key and TTL, but it does **not** fall back to `get_routes_eve/4`. On a
`get_routes_custom/3` error it returns `{:error, reason}`. Existing callers keep
`Routes.find/5` and their current behaviour; nothing else changes. This keeps the
connection filtering, avoid list, and static-data hydration in one place rather
than duplicating them into the watcher.

The watcher then reads:

- `{:error, _}` — solver unreachable or errored -> `:unknown`. Keep prior state,
  log, emit telemetry, do not alert and do not clear.
- `{:ok, %{routes: []}}` — no entries at all -> `:unknown`, same handling. The
  solver is not expected to return this for a valid request.
- `{:ok, %{routes: entries}}` where every entry carries `success: false` /
  `has_connection: false` -> `:none`. Genuine no-path. Clear.
- otherwise -> hand the entries to the Evaluator.

**Verify before implementing** whether `get_routes_eve/4` is stubbed on
`guarzo/zoo` as it is on `main`. If it has been restored to a real ESI call there,
the fallback becomes a legitimate degraded result rather than a fabricated one —
but the strict variant is still the right call, because an ESI-only path ignores
the map's wormhole connections and cannot answer this question at all.

### At-most-once, matching the dispatcher

State is written **before** delivery, matching the posture the dispatcher
moduledoc argues for: a delivery failure loses one alert rather than repeating
it. `{:error, :not_running}` reverts the write, exactly as
`handle_delivery_result/4` does today, since nothing was enqueued.

State is mirrored to Cachex on every write and rehydrated in `init/1`, so a
watcher that crashes and is restarted by its supervisor resumes against the
state it already had rather than re-announcing a still-open route.

That rehydration is **in-lifetime only**. `:discord_route_alert_cache` is a
plain in-memory Cachex instance with no disk warmer and no dump/load, and
watchers start lazily, so a node restart loses every entry: after a deploy the
first qualifying topology event on each configured map creates a fresh watcher
at `:unknown` and re-announces a route that was already open. The route is
genuinely open, so this is noise rather than a false alert, but on an instance
with many configured maps a deploy produces a burst of pings. Persisting the
state across restarts is deliberately left as follow-up work.

### State identity is versioned by config

Persisted state keyed on `map_id` alone is wrong, because the state's meaning
depends on the configuration that produced it. `{:qualifying, 4}` recorded
against home system A says nothing about home system B, and a threshold change
from 5 to 3 can leave a stored `{:qualifying, 4}` that now describes a route
which no longer qualifies.

Left unversioned, three concrete bugs follow:

- Changing `home_system_id` and gaining a qualifying route to the *new* home is
  compared against the *old* home's state and suppressed as "no change".
- Lowering `route_max_jumps` leaves a stored qualifying state that the next
  evaluation reads as a regression rather than a closure.
- Disabling and re-enabling route alerts resumes against pre-disable state, so a
  route that opened while disabled is silently attributed to whatever unrelated
  topology event fires next — and never announced.

**Resolution:** the stored value carries a `config_version` — a hash of
`{home_system_id, route_max_jumps, solver_settings_version}`. On rehydrate and on
every evaluation the watcher compares it against the current config; a mismatch
discards the stored state and resets to `:unknown` rather than to `:none`.
`:unknown` is the correct reset target: it means "we have never evaluated *this*
configuration", so the next qualifying result posts an "opened" alert, which is
the honest message after a config change.

The third bug is **not** covered by the version hash: the hash is deterministic,
so disabling and re-enabling reproduces exactly the value already stored. It is
covered by eviction instead — the notification's update hook calls
`RouteWatcherSupervisor.stop_watcher/1` whenever the record lands with route
alerts off, which stops the watcher and drops its cache entry, so re-enabling
starts from `:unknown`.

Disabling route alerts clears the state outright. Re-enabling therefore starts at
`:unknown` by the same rule, with no special case.

The config change itself does not trigger an evaluation — the watcher is
event-driven and will pick it up on the next topology event. Alerting on save
would mean a settings screen posts to Discord, which is surprising.

## Message, mentions, and privacy

### Embed

Green, titled `Highsec route to Jita — 4 jumps`. The path renders home -> ... ->
Jita, with map-local names for wormhole systems and security shown for k-space
ones. The exit system gets its own field.

### Role resolution is literal

An explicit `:route` clause resolves map-local names. The `:system` fallback
passes a literal `:system`. The role is never threaded through as a variable —
see the `Router` moduledoc for why that boundary matters and why a Discord post
cannot be recalled.

### The channel is trusted, not merely defaulted

A route alert *is* the chain topology; the path is the entire message. There is
no version of this that is safe in a public channel. The `:route` destination
must be documented as trusted in the UI helper text.

### Mentions

#### Why not `VoiceParticipants`

`Discord.VoiceParticipants` (shipped in PR #125) already pings people on kill
notifications, by resolving whoever is currently in a voice channel. **Route
alerts deliberately do not reuse it**, and this is the load-bearing decision in
this section.

The two features address opposite populations. Someone in voice is online, on
the map, and watching the chain change in real time — they will see a new highsec
route before any bot tells them. The audience for a route alert is precisely the
people who are **not** connected: the hauler who would undock if they knew a
five-jump highsec path to Jita existed right now. Pinging voice participants
would reliably notify the one group that does not need notifying, and at 04:00
with an empty voice channel it would notify nobody at all.

So the mention set must be *configured*, not *observed*. This is why
`mention_targets` exists as its own mechanism rather than as a call into
`VoiceParticipants`.

#### What is already built

Two mechanical constraints shape the delivery, and `VoiceParticipants` has
already solved both — **reuse it, do not reimplement**:

1. **Mentions inside embeds do not ping.** Discord only fires notifications for
   mentions in the top-level `content` field. A `<@&...>` in an embed renders as a
   blue chip and notifies nobody. `VoiceParticipants.prepend_to_messages/2`
   already puts a prefix into `content` on the first chunk and leaves embeds
   untouched; it is mention-source-agnostic and takes route alerts' prefix as
   readily as voice's.
2. **Handles do not work.** `@guarzo` in a webhook payload is plain text.
   Pinging requires the snowflake: `<@123...>` for a user, `<@&123...>` for a role.

`VoiceParticipants.mention_prefix/2` also already implements the character-budget
truncation. Whether route alerts share it or format their own short prefix is an
implementation detail for the plan, not a design decision.

#### Where configured targets live

Snowflake IDs are **guild-scoped**, which decides where they are stored. A role
id from one corp's Discord is meaningless in another's and renders as a broken
mention. Wanderer is multi-tenant; each map's webhook points at a different
guild. An instance-wide secret would put one guild's id into every guild's
channel.

`MapDiscordWebhook` *is* the guild binding, one row per destination. Mention
targets are stored there as an array column, each entry validated against
`^(user|role):\d{17,20}$` — parseable, renderable, and unable to hold a handle
that would silently fail. It generalizes for free: kill alerts on the `:system`
and `:character` rows can opt in later without a second mechanism.

A global `DISCORD_MENTIONS_ENABLED` env gate lets an operator stop all pings
instance-wide during an incident without editing per-map config. This is the
piece a Fly secret is genuinely right for, and it follows the existing `Env`
gate pattern.

**Ping on open only.** The "improved to N jumps" update posts with no `content`
field, keeping the ping meaningful on a chain that is being actively scanned.

### Mention injection is a real risk

`allowed_mentions` appears **nowhere in `lib/` or `test/`** on `guarzo/zoo` today.
That is currently a latent gap rather than a live vulnerability: the only three
writers of `"content"` are a static overflow string
(`embed_formatter.ex:133`), a static test message (`discord_dispatcher.ex:146`),
and voice mentions built from guild data. No user-controlled text reaches
`content`, and Discord does not fire notifications for mentions inside embeds, so
nothing is exploitable as shipped.

This design keeps it that way — system names, including user-supplied
`temporary_name` values, go in the **embed**, never in `content`. But the gap is
one careless formatter change away from mattering, and this feature is the one
adding a second `content` writer.

Every request therefore sends `allowed_mentions` with `parse: []` plus an
explicit allowlist of exactly the configured ids. This makes the mention set a
closed allowlist and neutralizes the injection class entirely. **This is required
even when no mentions are configured** — an empty allowlist with `parse: []` is
what makes an unconfigured map safe.

Adding `allowed_mentions` to the shared payload builder would also harden the
existing kill and voice paths. Whether to do that here or as a separate change is
a scoping call for the plan; this spec's requirement is only that the route-alert
path never posts `content` without it.

## Data model

Migration on `map_discord_notifications_v1`:

| Column | Type | Default | Notes |
|---|---|---|---|
| `route_alerts_enabled?` | boolean | `false`, not null | Separate from `enabled?`, which gates kills. Ships off. |
| `home_system_id` | integer | null | Required when `route_alerts_enabled?` is true (Ash validation). |
| `route_max_jumps` | integer | `5`, not null | Inclusive upper bound. See decision 5. |

Migration on `map_discord_webhooks_v1`:

| Column | Type | Default | Notes |
|---|---|---|---|
| `mention_targets` | text array | `{}`, not null | Each entry matches `^(user\|role):\d{17,20}$`. |

`:route` joins the `role` `one_of` constraint — an app-level change only.

Every new action needs a `define(...)` entry in `code_interface`, per project
convention. Config changes must invalidate the dispatcher's cache via the
existing `after_transaction` hooks — never `after_action`.

## Failure posture

**This feature fails closed**, which inverts the posture of every neighbouring
module and is a deliberate choice rather than an oversight.

Any system on the path whose static info will not resolve disqualifies the route.
Kills fail *open* because a parse regression that silences notifications looks
like a quiet map. Here the asymmetry runs the other way: announcing a highsec
route that is not one gets a freighter killed, while a missed alert costs nothing
but an alert.

Other failure paths:

- Watcher crash -> supervisor restart -> rehydrate from Cachex.
- Solver timeout or crash -> keep state, log, emit telemetry.
- Telemetry on `[:wanderer_app, :discord, :route_alert]` with an outcome tag,
  matching the existing enrichment telemetry shape.

## Testing

**Evaluator** carries the bulk, all with synthetic input and no HTTP:

- wormhole exemption (a J-space hop does not disqualify)
- the 0.45 boundary in both directions (0.45 qualifies, 0.4 does not)
- Pochven rejection
- unresolvable static info disqualifies (fail-closed)
- jump counting includes wormhole hops
- `{:error, _}` and `routes: []` -> `:unknown`, versus every entry `success: false`
  -> `:none`

**`Routes.find_strict/5`**: returns `{:error, _}` on a solver error rather than
falling back, and is otherwise byte-identical to `find/5` on the success path
(assert both against the same stubbed solver response, including the cache key).

**Router**: `:route` selection, `:system` fallback, and the
disabled-drops-never-reroutes assertion mirroring the existing `RouterTest`.

**Watcher**: debounce coalescing, all four transitions, solver-failure-keeps-state,
restart rehydration, and specifically:

- a notify delivered *while a solver task is in flight* is received and sets the
  re-run flag — the test that would fail under a blocking `Task.yield`
- an in-flight result is discarded, not published, when the re-run flag is set
- a stored state whose `config_version` no longer matches resets to `:unknown`,
  and the next qualifying result posts "opened" rather than being suppressed
- the 20s deadline fires and shuts the task down without killing the watcher

Requires `Routes.find_strict` behind a swappable impl, the way
`NotableItems.impl()` already does it.

**Dispatcher**: topology events notify the watcher only when configured; the kill
path is unaffected.

**Formatter**: embed shape, and `allowed_mentions` present with `parse: []` on
every request including the no-mentions case.

## Scope

**In scope, easy to forget:** `map_notifications_component.ex` needs the
home-system picker, the max-jumps field, a `:route` webhook row, and the
mention-targets input with helper text explaining that ids are required and the
channel is trusted.

**Changes to existing source in `map_routes.ex`.** The headline change is
`find_strict/5`, which is purely additive. Planning surfaced two supporting
changes to shared code that the design did not anticipate:

- **A swappable ESI seam.** `WandererApp.Esi.get_routes_custom/3` and
  `get_routes_eve/4` are called directly (`map_routes.ex:232,249`) with no
  `Application.get_env` seam, and `Esi.MockBehaviour` does not declare them, so
  the solver cannot be stubbed at all today. `find_strict/5` is untestable
  without this. The seam follows `CorpTickers.esi_client/0`
  (`corp_tickers.ex:172`) and defaults to the real module, so no existing caller
  changes behaviour.
- **`hydrate_static_data/1` extracted** from `find/5`'s body so `find_strict/5`
  reuses it rather than duplicating the static-info hydration.

Both touch the code path behind the live routes widget. `find/5`'s observable
behaviour must be unchanged, and the plan carries an explicit regression test
asserting the `get_routes_eve/4` fallback still happens for `find/5`. **This is
where a reviewer should look hardest.**

**Branch base:** this must be built on `guarzo/zoo`, not `origin/main`. See
"Repository evidence".

**Explicitly out:** no frontend map changes; no per-user route alerts; no "route
closed" message; destination stays Jita-only; no change to any kill path
behaviour; **no voice-participant mentions on route alerts** — see "Why not
`VoiceParticipants`", and treat any later PR that unifies the two mention sources
as a regression unless it argues against that reasoning directly.

## Assumptions that may change

- A webhook can ping a role that is not marked "mentionable" when the role id is
  in `allowed_mentions.roles`. Believed correct but **must be verified with a live
  test** before the UI promises it.
- The 10s debounce and 60s ceiling are guesses. Telemetry on
  `[:wanderer_app, :discord, :route_alert]` is what will tune them, exactly as the
  enrichment thresholds were left to be tuned.
- Route-builder load is acceptable at the expected number of enabled maps. The
  dirty-set sweeper above is the escape hatch if not.

## Verification performed

Dependency setup and a baseline test run were **not** executed at the time this
spec was written. They have since been established in this worktree, and the
implementation plan records them under "Baseline": `mix deps.get` (exit 0),
`MIX_ENV=test mix compile` (exit 0), and the Discord/API test subset (321 tests,
0 failures). `mix ecto.setup` is still required for the Ash migration in Task 3.

The worktree this spec was drafted in was initially cut from `origin/main`, which
does not contain the Discord stack. It has since been reset onto `guarzo/zoo`.
Any future worktree for this work must be based the same way.

## Review history

An independent review (Codex, read-only, against the repository) returned REVISE
with six findings. All six are folded into the text above:

| Finding | Where it landed |
|---|---|
| Discord stack absent from the checkout | "Repository evidence" branch-dependency note; artifact of the worktree base, now reset |
| Failure and no-route are not distinguishable via `Routes.find/5` | "Distinguishing failure from no-route" — rewritten around `find_strict/5` |
| Integer `home_system_id` crashes `String.to_integer/1` | Data flow step 5; evidence table row |
| Watcher state not versioned by config | New "State identity is versioned by config" |
| Blocking `Task.yield` defeats the re-run flag | Data flow step 6 — result handling is now asynchronous |
| "A topology change always misses the cache" is false | Evidence table cache row, corrected |
