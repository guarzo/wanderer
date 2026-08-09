# Discord killmail notification fixes — design

Two production defects in the Discord killmail notification path, fixed
independently. They share no code and can land in either order.

1. Notifications fire for systems that are no longer on the map.
2. Already-posted killmails are posted again after an application restart.

## Defect 1 — kills for systems no longer on the map

### Root cause

Removing a system from a map is a **soft delete**. `MapSystemRepo.remove_from_map/2`
sets `visible: false` on the `MapSystem` row rather than destroying it
(`lib/wanderer_app/repositories/map_system_repo.ex:49-58`).

The fan-out that decides which maps receive a killmail is
`WandererApp.Kills.Subscription.SystemMapIndex`, an ETS index of
`system_id -> [map_id]`. It builds that index with `MapSystemRepo.get_all_by_map/1`,
which applies **no `visible` filter**
(`lib/wanderer_app/kills/subscription/system_map_index.ex:98`).

The index therefore maps every system a map has *ever* contained to that map,
permanently. `MapIntegration.broadcast_kill_to_maps/1` fans out on it
(`lib/wanderer_app/kills/subscription/map_integration.ex:164-188`), into both the
in-app `{:map_kill, …}` PubSub and `ExternalEvents.broadcast(map_id, :map_kill, …)`,
which reaches `DiscordDispatcher`.

Nothing downstream re-checks map membership. `Router.route/3` consults only
`excluded_systems` and `wh_only` (`lib/wanderer_app/external_events/discord/router.ex:75-98`).

Two pieces of evidence that the missing filter is an oversight rather than a
deliberate choice:

- The sibling function `MapIntegration.get_tracked_system_ids/0`, which decides
  which systems to subscribe to upstream, uses `get_visible_by_map/1`
  (`map_integration.ex:98`).
- `MapSystem` carries a partial index specifically for this filter:
  `index [:map_id], name: "map_system_v1_map_id_visible_index", where: "visible = true"`
  (`lib/wanderer_app/api/map_system.ex:44`).

Staleness is a **secondary** cause, and the refresh path is weaker than it
looks. `SystemMapIndex.refresh/0` is called only from the `:ok` branch of
`MapEventListener.do_update_subscriptions/1`
(`lib/wanderer_app/kills/map_event_listener.ex:177-183`) — that is, only after a
kills-client subscription update *succeeds*. While the client is connecting or
disconnected, the retry path replaces the refresh entirely
(`map_event_listener.ex:220-237`). Worse, the listener subscribes to individual
map topics only in its `:resubscribe_to_maps` handler, first fired 60 seconds
after init (`map_event_listener.ex:26-29`, `:111-133`), so a map started since
the last resubscribe emits system-removal events that nobody is listening for.

In those cases the only backstop is the index's 5-minute periodic refresh
(`system_map_index.ex:12`, `:127-129`). The exposure is therefore **up to five
minutes** of notifications for a system that was just removed — not the
sub-second window an earlier draft of this document assumed. That is the same
user-visible symptom as the permanent case, merely bounded, so it warrants a fix
of its own.

### Fix

Two parts. The first removes the permanent defect; the second bounds the
residual staleness window.

**1. Filter the index by visibility.** `SystemMapIndex.fetch_all_map_systems/0`
builds from `MapSystemRepo.get_visible_by_map/1` instead of `get_all_by_map/1`.

```elixir
# lib/wanderer_app/kills/subscription/system_map_index.ex:98
- case WandererApp.MapSystemRepo.get_all_by_map(map.id) do
+ case WandererApp.MapSystemRepo.get_visible_by_map(map.id) do
```

**2. A fail-open membership guard in the dispatcher.** A `:map_kill` batch
carries a single `solar_system_id`, so the `:map_kill` clause of `do_dispatch`
(`discord_dispatcher.ex:223`) checks that one id against
the live map cache before doing any other work. `WandererApp.Map.remove_system/2`
drops the system from that cache immediately (`lib/wanderer_app/map.ex:508-517`),
so it is strictly fresher than the index.

The guard is **fail-open**: it drops the batch only when the map cache read
*succeeds* and the system is absent from it. Any failure to read — the map not
being in `:map_cache`, the cache being unavailable — allows the batch through.

```elixir
# Drops only on a positive "this map does not have that system".
# `systems` is keyed by solar_system_id (`lib/wanderer_app/map.ex:20,486`).
defp system_on_map?(map_id, system_id) do
  case WandererApp.Map.get_map(map_id) do
    {:ok, %{systems: systems}} when is_map(systems) -> Map.has_key?(systems, system_id)
    _ -> true
  end
rescue
  # `Cachex.get/2` RAISES against an unstarted cache rather than returning an
  # error tuple — the same contract `Matcher.tracked_eve_ids/1` rescues
  # (`matcher.ex:53-60`). Without this the guard would not fail open, it would
  # crash the dispatcher and lose the whole batch.
  _ -> true
end
```

Fail-open is what makes this guard safe to add, and it is the reason an earlier
draft's objection to it no longer applies: a cold or unavailable cache cannot
silently drop a real kill, because an unreadable cache is not a positive finding
of absence. This is the same `:unknown`-is-not-`:not_involved` distinction that
`Matcher` and `Router` already turn on
(`lib/wanderer_app/external_events/discord/router.ex:18-28`).

Note the deliberate asymmetry between the two parts: the index fix affects the
in-app kills widget as well, while the guard is Discord-only. Bounding the
staleness window for the UI is not worth a second guard — nobody is looking at a
map they just removed a system from.

### Blast radius

The guard in part 2 is Discord-only. Part 1 changes the index, which has three
consumers:

| Consumer | Effect of the fix |
|---|---|
| `map_integration.ex:164-174` — in-app `{:map_kill, …}` PubSub to the map UI | Removed systems stop showing kills in the kills widget |
| `map_integration.ex:177-188` — `ExternalEvents.broadcast` → Discord | The defect being fixed |
| `kills/client.ex:868` — a log line attributing kills to maps | Log accuracy only |

The UI change is intentional and in the same direction: a system that was
removed from the map should not light up with kill activity. This is a behaviour
change beyond Discord and is accepted rather than worked around.

### Rejected alternatives

**Restricting the index to started maps.** `MapIntegration.get_tracked_system_ids/0`
builds from `Cache.lookup("started_maps", [])` — maps with a live GenServer —
while `SystemMapIndex` builds from every persisted map. Rejected: a map with no
running process would receive no Discord notifications at all, which is
precisely when notifications are most wanted, and `started_maps` is empty
immediately after a boot (`lib/wanderer_app/map/map_manager.ex:55`). It is a
separate behaviour change with its own risks, not a fix for this defect.

**Making `SystemMapIndex.refresh/0` unconditional** — moving it out of the `:ok`
branch of `do_update_subscriptions/1` so it also runs when the kills client is
disconnected. Tempting, and it would shrink the staleness window at the source.
Rejected for this change because the listener's subscription lifecycle is load-
bearing for the upstream subscription set, not just the index, and reworking it
is a larger change than either defect warrants. The fail-open guard bounds the
symptom without touching that lifecycle. Worth revisiting separately.

### Verification

A regression test against `SystemMapIndex`: a map with one visible system and
one `visible: false` system; `get_maps_for_system/1` returns the map id for the
first and `[]` for the second. Shaped so that a future refactor back to
`get_all_by_map/1` fails.

For the guard, three dispatcher tests: a batch whose system is on the map posts;
a batch whose system is absent from a readable map cache drops; and a batch for
a map that is **not** in `:map_cache` at all posts, pinning the fail-open
behaviour so a later "tidy-up" cannot quietly turn it fail-closed.

## Defect 2 — duplicate notifications after a restart

### Root cause

`DiscordDispatcher` deduplicates on `"#{map_id}:#{killmail_id}"` marks held in
`:discord_dedup_cache`, a plain in-memory Cachex instance
(`lib/wanderer_app/application.ex:151-154`). Every mark is lost on restart.

On reconnect the kills client re-joins `killmails:lobby` with its subscribed
system list (`lib/wanderer_app/kills/client.ex:686-692`) and the upstream service
replays recent killmails. The dispatcher's moduledoc already names this hazard —
"an upstream replay burst on reconnect" (`discord_dispatcher.ex:105`).

The existing guard is `kill_fresh?/3` against `Env.discord_max_killmail_age_seconds/0`,
which defaults to **3600** (`lib/wanderer_app/env.ex:100`). After a restart the
dedup marks are gone and the age filter admits an hour of history, so up to an
hour of already-posted killmails is posted a second time.

### Fix

For a grace period after the dedup marks are lost, the freshness filter uses a
much tighter maximum age. Replayed history is dropped because it is old; a
killmail that genuinely occurs during the window still posts.

**The window belongs to the dedup cache's lifecycle, not the dispatcher's.**
This is the part that is easy to get wrong. `:discord_dedup_cache` and
`DiscordDispatcher` are separate children of a `:one_for_one` supervisor
(`lib/wanderer_app/application.ex:150-154`, `:204-213`, `:270-298`), so their
restarts are independent, and only one of the two asymmetries is benign:

| Event | Marks | Window must |
|---|---|---|
| Full application restart | lost | arm |
| Dedup cache crashes alone | lost | **arm** |
| Dispatcher crashes alone | intact | not arm (harmless if it does) |
| Kills-client reconnect, no restart | intact | not arm |

Keying the window off `DiscordDispatcher.init/1` gets row 2 exactly backwards:
every mark is gone and the window never arms, which is precisely the
duplicate-post scenario this fix exists to prevent.

So the window is derived from the dedup cache itself, via a sentinel stored in
that cache:

- On dispatcher init, read the sentinel from `:discord_dedup_cache`.
  - **Absent** — the cache is new, so its marks are gone. Write
    `arm_until = System.monotonic_time(:millisecond) + grace_ms`, with no TTL.
  - **Present** — the cache survived. Honour the stored `arm_until` as it is.
- A batch is inside the window when `System.monotonic_time(:millisecond) < arm_until`.

The sentinel carries an absolute deadline rather than a TTL, so an expired
window is still a *present* sentinel and a dispatcher-only restart cannot re-arm
it. Monotonic time is safe here because the cache and the dispatcher share a VM,
and it makes the window immune to wall-clock adjustment.

Kills-client reconnects need no special handling: they do not restart either
component, the marks are intact, and ordinary dedup already covers the replay.

`do_dispatch/3` then resolves the maximum age **once per batch**:

```elixir
max_killmail_age_seconds =
  if within_startup_grace?(arm_until),
    do: Env.discord_startup_max_killmail_age_seconds(),
    else: Env.discord_max_killmail_age_seconds()
```

Mechanically that means `init/1`, which today returns a bare `%{}`
(`discord_dispatcher.ex:90`), stores the resolved `arm_until` in state, and
`handle_cast({:dispatch_event, …})` (`:212-216`) passes it into `do_dispatch`,
which gains a third argument. The existing two-argument clauses at `:285` and
`:303` gain it too, and ignore it.

This preserves the existing once-per-batch invariant that
`discord_dispatcher.ex:230-237` documents at length: resolving config per
killmail turns one misconfigured deployment into a warning-per-kill log flood.

`kill_fresh?/3` is unchanged. It already takes the maximum age as an explicit
third argument, so both call paths flow through the same comparison.

### Observability

A killmail dropped by the startup window currently leaves **no trace at all**:
the age filter falls out of the `with` chain into a catch-all `:ok`
(`discord_dispatcher.ex:223-269`), and telemetry is emitted only after delivery
or an enqueue failure (`:762-766`, `:794-800`). During an incident, "did we
suppress it, or did we never receive it?" would be unanswerable — the one
question this feature makes worth asking.

So the fix adds:

- A telemetry event `[:wanderer_app, :discord, :killmail_dropped]` with
  `%{count: n}` and metadata `%{reason: :startup_age | :age | :duplicate,
  map_id: map_id}`. Three reasons, because conflating them would defeat the
  purpose: `:startup_age` is the new suppression, `:age` is the pre-existing
  hour limit, and `:duplicate` is ordinary dedup.
- One `Logger.info` per batch when `:startup_age` drops anything, giving the
  count and the remaining window. At info, not debug: it fires at most once per
  batch for at most ten minutes after a restart, and it is the line an operator
  will search for.

### Configuration

Both keys join the existing `:external_events` keyword list. They do **not**
share a validator, and the difference is load-bearing:

| Key | Default | Validator | Meaning |
|---|---|---|---|
| `discord_startup_grace_seconds` | 600 | non-negative integer (new) | How long after the marks are lost the tighter age applies. `0` disables the window. |
| `discord_startup_max_killmail_age_seconds` | 120 | existing `validate_positive_integer/3` | Maximum killmail age during that window |

`validate_positive_integer/3` warns and substitutes the default for anything not
`> 0` (`lib/wanderer_app/env.ex:285-294`). That is right for the age — a zero or
negative maximum age would drop every real killmail, silently and invisibly,
which is exactly the failure it was written to catch. It is **wrong** for the
grace period, where `0` is a legitimate setting meaning "no startup window", and
routing it through that helper would turn "disabled" into "600 seconds plus a
warning" — the opposite of what the operator asked for, and the reason the test
configuration below could not otherwise work.

So `discord_startup_grace_seconds` gets a sibling validator,
`validate_non_negative_integer/3`, accepting `>= 0` and falling back with the
same warning on a negative or non-integer value. Both fall back loudly rather
than silently.

**Why a 10-minute default rather than 2.** A long window is nearly free, because
it only ever drops *old* killmails. The replay burst arrives when the kills
client joins the channel, which can be minutes after boot when the upstream
service is slow to accept the connection; a 2-minute window would miss it
entirely. Ten minutes covers that without ever silencing a kill that actually
just happened.

### Accepted cost

During the grace period, a genuinely delayed killmail — upstream lag exceeding
120 seconds — is dropped. This is the same trade the module already makes for
at-most-once dedup (`discord_dispatcher.ex:26-32`): a dropped kill remains
visible in the kills widget and on zKillboard, while a duplicate post in a chat
channel is irreversible.

### Rejected alternatives

**Blanket suppression for N minutes after boot.** Simpler to explain, but it
drops genuinely new killmails for the whole window, and a crash-looping node
would stay permanently silent. The tighter-freshness variant is the same amount
of code and has neither property.

**Persisting the dedup marks** to Postgres or a disk-backed cache. Strictly
correct — no killmail is lost, and it would also survive a replay longer than
any grace window. Rejected as disproportionate for this defect: it requires a
new table, a migration, and an expiry sweep, and puts a database write on the
per-killmail dispatch path.

### Verification

`config/test.exs` sets `discord_startup_grace_seconds` to `0`, which the
non-negative validator honours as "disabled". No existing dispatcher test is
then silently pulled inside the window — every test in
`test/unit/external_events/discord_dispatcher_test.exs` calls
`start_supervised!(DiscordDispatcher)` (`:86-110`) and would otherwise begin
inside a live 600-second grace period, quietly changing what the existing age
tests assert.

New tests set both keys explicitly and assert:

- A 5-minute-old killmail posts normally, but is dropped inside the window.
- A 30-second-old killmail posts in both cases.
- The window expires: past `discord_startup_grace_seconds`, the ordinary
  3600-second limit applies again.
- **Lifecycle**: restarting the dispatcher alone with the sentinel present does
  not re-arm the window; clearing the dedup cache and restarting the dispatcher
  does. These two are the point of the sentinel design and the case an earlier
  draft got backwards, so they are asserted directly rather than inferred.
- A `:startup_age` drop emits the telemetry event with that reason, and an
  ordinary age drop emits `:age` — pinning that the two stay distinguishable.
- Each new `Env` accessor returns its default when unset, returns a configured
  value when set, and falls back with a warning on an invalid value. For
  `discord_startup_grace_seconds` that explicitly includes `0` being **honoured**
  rather than replaced, matching the style of the existing coverage in
  `test/unit/external_events/discord_killmail_age_test.exs`.

## Out of scope

- Route alerts. Their state cache is deliberately TTL-less
  (`application.ex:155-161`) and neither defect touches that path.
- The `:discord_notification_cache` config cache and `Matcher`'s tracked-pilot
  cache. Both are correctly invalidated already.
- Any change to at-most-once delivery semantics.
