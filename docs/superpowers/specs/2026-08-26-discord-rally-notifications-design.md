# Discord rally-point notifications — design

Date: 2026-08-26
Status: awaiting review

## Intent

Post a Discord message when a pilot drops a rally point on a map, pinging a
configured role so the fleet sees it.

This capability existed until recently, but not in this application. It was
provided by `wanderer-notifier`, a separate Elixir app that followed the map
over SSE and posted to Discord itself. That app is deprecated, and it stopped
running when wanderer moved to Fly.io — which is how the gap surfaced: kill and
route notifications kept working because they are produced *inside* wanderer,
while rally notifications went silent.

The message users are accustomed to:

```text
@FLYGD Rally point created!
⚔️ Rally Point Created
Stealthbot has created a rally point in A22A
System          Created By
A22A            Stealthbot
Rally ID: eae7c5b4-2727-4a88-a041-3b5a5d4e5332 • 8/3/2026 2:05 AM
```

This is a sibling of route alerts, reusing the same configuration table,
per-webhook delivery queue, and embed formatter. It is materially smaller than
route alerts: a rally is a discrete user action that arrives with its full
payload, so there is no watcher, no solver, no debounce, and no persisted state.

## Repository evidence

**Branch dependency.** The whole Discord stack (`DiscordDispatcher`,
`Discord.Router`, `Discord.WorkerSupervisor`, `MapDiscordWebhook`,
`MapDiscordNotification`) lives on **`guarzo/zoo`** and does not exist on
`origin/main`. This must be built on a branch derived from `guarzo/zoo`.

| Evidence | Constraint it imposes |
|---|---|
| `MapEventRelay` forwards every event to `DiscordDispatcher` (`map_event_relay.ex:164`); `:rally_point_added` is already a registered event type (`event.ex:112-113`) and today lands in the catch-all `do_dispatch/2` clause (`discord_dispatcher.ex:313`) | The hook point exists. No relay or event-registry work. |
| `MapDiscordWebhook.role` is stored as plain `:text` (`20260803202833_create_map_discord_webhooks.exs:13`) with an Ash-only `one_of` constraint (`map_discord_webhook.ex:248-251`); the commit adding `:route` shipped migrations for its new *columns* only, never the role value | Adding `:rally` needs **no migration and no snapshot**. |
| `identity :unique_notification_role, [:notification_id, :role]` (`map_discord_webhook.ex:326`) | One rally destination per map, enforced by the database. |
| `mention_targets` already lives per webhook row (`map_discord_webhook.ex:309-312`), validated against `~r/\A(user\|role):(\d{17,20})\z/` (`mentions.ex:22`) | The role-to-ping is existing plumbing. Nothing new. |
| `allowed_mentions/1` always emits `"parse" => []` (`mentions.ex:62-74`), with a reattachment safety net in `worker.ex:288-294` | `@here`/`@everyone` is structurally impossible. But a formatter emitting `content` **must set `allowed_mentions` itself** or the ping is neutered. |
| `DiscordDispatcher` is a **singleton** GenServer for every map; the route-alert clause deliberately does nothing but gate and cast (`discord_dispatcher.ex:283-294`) | Rendering and posting must not run inline in `do_dispatch/2`. |
| `route_destination/1` resolves to the `:route` webhook and drops when absent, with the reasoning written into the moduledoc (`router.ex:46-63`, `:100-109`); `RouterTest` asserts it | Precedent for no-fallback. Note the 2026-08-07 route-alerts design doc's §7 heading still says "falling back to `:system`" — that is **stale**; the shipped code has no fallback. Verified directly. |
| `SystemName.display_name/3` has three clauses and no catch-all (`system_name.ex:35-47`); the role is always passed as a literal so the privacy boundary cannot leak via a threaded variable | A `:rally` clause must be added explicitly, or delivery raises `FunctionClauseError`. |
| `map_url/1` returns nil rather than a best-effort URL (`embed_formatter.ex:363-381`) because a malformed `url` is a Discord 400, which counts toward auto-disable | Reuse it. Do not build map links by hand. |
| Colours: green and yellow are claimed by kills and ISK tiers, blue by routes (`embed_formatter.ex:56-65, 81-92`) | The old notifier's rally orange `0xFF6B00` collides with the ISK-tier palette. Rally needs its own hue. |
| `:rally_point_added` fires only for `type == 1` (`map_server_pings_impl.ex:40`) and carries `rally_point_id`, `solar_system_id` (a **string**), `system_id`, `character_id`, `character_name`, `character_eve_id`, `system_name`, `message`, `created_at` | Everything the message needs is in the payload. |
| The 60-minute expiry in `MapManager` (`map_manager.ex:19-20, 111-143`) emits only the internal `:ping_cancelled`, never `:rally_point_removed`; orphan cleanup and FK cascades emit nothing | A "rally ended" message built on `:rally_point_removed` would be silent for the *normal* end of life. See decision 2. |
| One rally per map is enforced in the LiveView by a read-then-write with no lock (`map_pings_event_handler.ex:97-142`); there is no DB constraint and no rate limiter on the handler | Do not assume exactly-one. Assume near-always-one. |
| `:discord_notification_cache` declares `default_ttl:` (`application.ex:147`) but the project runs Cachex 3.6 (`mix.lock:12`), where that is a dead 2.x option | The config cache is evicted **only** by explicit invalidation. Not "within five minutes" — until restart. |

## Decisions

### 1. Destination — a new `:rally` role, no fallback

A fourth role on `MapDiscordWebhook`, giving rally its own webhook URL and its
own `mention_targets`. When no rally destination is configured, the event
drops; it does not spill into the kill or system channel.

The old notifier *did* fall back (`DISCORD_RALLY_CHANNEL_ID` defaulting to
`DISCORD_CHANNEL_ID`). We are not reproducing that. The repo's rule — set out
in `router.ex:36-63` for both disabled destinations and route alerts — is that a
destination the user did not choose must never receive a class of message by
default. Rally carries a map-local system name (decision 5), so a fallback would
hand a chain tag to a channel picked for killmails, with no user action and no
way to notice.

Cost: one line, the `one_of` list. No migration, no snapshot.

### 2. Creation only

`:rally_point_added` posts. `:rally_point_removed` is not wired.

This matches the old notifier, which ignored removals outright
(`event_processor.ex:252-255`). It also avoids a trap: rallies normally end by
the 60-minute expiry, and that path emits no external event at all, so a
"cancelled" message would fire for manual cancels and stay silent for the common
case — worse than no message, because its absence would read as "still active".

Wiring removals properly means first making expiry emit the event. Out of scope;
recorded under Assumptions.

### 3. No per-map toggle

Route alerts needed `route_alerts_enabled?` because they also need a
`home_system_id` and a watcher, and because they fire off ambient topology
changes the user never asked for individually.

A rally is a deliberate human action, and the destination row is itself the
opt-in — exactly as for `:system` and `:character` kills. **The presence of an
enabled `:rally` webhook is the switch.** No new attribute, and therefore still
no migration.

### 4. No throttling

One rally per map is already enforced in the UI, and creating one is deliberate.
The old app shipped dedup machinery for rallies and never called it; users
experienced every rally, every time.

The residual abuse shape is cancel → re-create in a loop, which id-keyed dedup
would not catch anyway (each create gets a fresh UUID). If it ever becomes real,
the control is a per-map cooldown, not dedup. Recorded under Assumptions.

### 5. Map-local system names

`SystemName.display_name(:rally, ...)` resolves `temporary_name → custom_name →
canonical`, the same as `:system` and `:route`.

The rally channel is the fleet's own channel and the tag *is* the name people
navigate by — `A22A` in the reference message is a map tag. The `:character`
role's canonical-only rule exists for channels that may be public; a rally
destination is not that.

The payload's own `system_name` field is the raw MapSystem name and bypasses
this resolver. Do not use it.

### 6. Embed in house style, corp/alliance dropped

Content line, then one embed:

- **Content**: `<@&ROLE> Rally point created!` with an explicit
  `allowed_mentions` allowlist. Omitted entirely when the destination has no
  `mention_targets`, or when `WANDERER_DISCORD_MENTIONS_ENABLED` is off
  (`embed_formatter.ex:406-416`).
- **Title**: `⚔️ Rally Point Created`, front-loaded — mobile push previews show
  the title only (`embed_formatter.ex:209-212`).
- **Author**: pilot name with portrait icon, `characters/<eve_id>/portrait?size=64`,
  matching `route_author/1` (`embed_formatter.ex:181-191`) rather than the old
  app's no-thumbnail layout.
- **URL**: the map, via `map_url/1`.
- **Description**: `**<pilot>** has created a rally point in **<system>**`, with
  `\n\n💬 <message>` appended when the pilot typed one.
- **Fields**: `System` and `Created By`, inline.
- **Footer**: `Rally ID: <uuid>`. **Timestamp**: the payload's `created_at`, not
  `DateTime.utc_now()` — the old formatter used now, which is wrong on any
  delivery retry.
- **Colour**: a new `@color_rally`, distinct from the kill/ISK and route hues.

Corporation and Alliance fields are **not** included. The old formatter declared
them but could never populate them, so no user has seen them; and the message
already names the pilot, whose corp the reader can look up. Adding them would
mean either widening a public event payload or an extra lookup per rally, for
information the message does not need.

## Architecture

No new processes.

```text
PingsImpl.add_ping/2  (map server GenServer)
  └─ ExternalEvents.broadcast(map_id, :rally_point_added, payload)
       └─ MapEventRelay.deliver_single_event/2
            └─ DiscordDispatcher.dispatch_event/2        (cast; singleton)
                 └─ do_dispatch(map_id, %{type: :rally_point_added})
                      ├─ enabled_globally?()             gate
                      ├─ fetch_config(map_id)            cached read
                      └─ Task under Discord.TaskSupervisor
                           ├─ Router.rally_destination/1   → :drop | {:ok, webhook}
                           ├─ EmbedFormatter.format_rally_ping/2
                           └─ WorkerSupervisor.deliver/2   → per-webhook queue
```

The dispatcher clause does only what the route-alert clause does: gate, then
hand off. Everything else runs off the singleton.

Delivery hardening is entirely inherited — bounded queue, five attempts,
exponential backoff, 429 `retry-after`, 404 → disable, ten consecutive failures
→ disable (`worker.ex:71-82, 374-400`).

## Failure posture

| Condition | Behavior |
|---|---|
| No `:rally` webhook configured | Drop. Silent by design (decision 1). |
| Rally webhook disabled, by user or failure threshold | Drop. Never reroutes. |
| `WANDERER_WEBHOOKS_ENABLED` off | Drop at `enabled_globally?/0`. |
| Mentions disabled globally | Embed posts; content line omitted. |
| `map_url/1` cannot resolve | Embed posts without a link, never with a malformed one. |
| Worker queue full / Discord 5xx | Existing retry and failure accounting. |
| Ping created with `type != 1` | No event is broadcast at all; unreachable today, since the UI only offers Rally. |

`WorkerSupervisor.deliver/2` returning `:ok` means *accepted for delivery*, not
delivered (`discord_dispatcher.ex:135-140`).

## Settings UI

One HEEx live_component, `map_notifications_component.ex`, in the maps-index
settings modal. There is no React involved — `grep -ril discord assets/js/`
returns nothing.

A rally row alongside the existing three: webhook URL, enable toggle, mention
chips, send-test. The hazard is that role enumeration is duplicated across at
least eight sites and derived from nothing, so a partial addition compiles
cleanly and fails at whichever site was missed:

`map_discord_webhook.ex:250` · `map_notifications_component.ex:88, 374,
721-725, 736-738, 1529` · `channel_info.ex:65, 76, 573` · `system_name.ex:26`

**`parse_role/1` defaults to `:system`** (`map_notifications_component.ex:725`).
Without a `"rally"` clause, a rally form submit silently writes the kill
channel's row. This is the single most damaging thing that can be missed.

## Testing

Following existing patterns; Discord rows are built through Ash directly, as
there is no factory support.

| Layer | Test |
|---|---|
| Resource | `:rally` accepted; unknown roles still rejected (`map_discord_webhook_test.exs:115-122` uses `:corporation`, so it stays valid) |
| Router | configured → `{:ok, webhook}`; disabled → `:drop`; absent → `:drop`, **no fallback to `:system`** |
| SystemName | `:rally` resolves map-local, matching `:system` |
| Formatter | embed shape, message appended when present and omitted when blank, content line present with targets and absent without, timestamp is `created_at` |
| Dispatcher | `:rally_point_added` reaches the destination; gated off when the global switch is off. Uses the app-env observer stand-in, **not Mox** — Mox does not work across `Discord.TaskSupervisor` (`discord_dispatcher_test.exs:1-5, 41`) |
| LiveView | rally row renders, saves, tests, removes; mention chips; missing-channel warning; role collisions |

`config/test.exs:33-46` sets `webhooks_enabled: false`; delivery tests must flip
it on in setup and restore the whole `:external_events` keyword list. Tests that
swap `:discord_http_client` must restore it in `on_exit`.

## Scope

**In:** the `:rally` role; `SystemName` clause; router resolver; embed formatter
and colour; dispatcher clause; settings UI row; the tests above.

**Out:** rally cancellation and expiry messages (decision 2, and expiry emits no
event); throttling (decision 4); corp/alliance fields (decision 6); any change
to the `:rally_point_added` payload or its JSON:API representation; fixing the
`rally_point_id` vs `id` asymmetry between the added and removed events; the
`type == 0` alert ping, which the UI does not expose.

## Assumptions that may change

1. **Rallies stay roughly one-per-map and infrequent.** If cancel/re-create
   churn shows up in practice, add a per-map cooldown — not id-keyed dedup,
   which cannot see it.
2. **Silence on expiry is acceptable.** If users want an "ended" message, the
   prerequisite is emitting `:rally_point_removed` from the `MapManager` expiry
   path, which is a behavior change to the event stream and needs its own
   review.
3. **The reference message is the target.** It was reconstructed from the
   deprecated `rally_formatter.ex` plus a user-supplied sample, not from a live
   capture.

## Verification performed

- `router.ex:100-109` and its moduledoc read directly to confirm `:route` has no
  fallback, contradicting the older design doc's stale heading.
- `map_discord_webhook.ex:248-251` and
  `20260803202833_create_map_discord_webhooks.exs:13` read to confirm `role` is
  plain text with an Ash-only constraint, and `git log -S` used to confirm the
  `:route` addition shipped no role migration.
- `map_server_pings_impl.ex:10-64` and `map_manager.ex:111-143` read to confirm
  the expiry path emits no external event.
- Live production state inspected via `fly ssh console` + `wanderer_app rpc`:
  three webhook rows (`character`, `system`, `route`), all enabled, zero
  consecutive failures, recent successful deliveries — confirming the delivery
  stack is healthy and the gap is specific to rally.
- `map_webhook_subscriptions_v1` confirmed empty in production, ruling out
  generic webhooks as the old delivery path.
