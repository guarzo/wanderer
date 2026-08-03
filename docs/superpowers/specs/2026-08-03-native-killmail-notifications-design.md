# Native Killmail Notifications — Design

**Date:** 2026-08-03
**Branch:** `guarzo/native-killmail-notifications`
**Status:** Approved for planning

## Goal

Bring wanderer's built-in Discord kill notifier close enough to wanderer-notifier
that the separate service is no longer needed for killmail notifications, without
adopting a Discord bot or a second ingestion path.

Reference for the target capability set: `wanderer-notifier`, at
`docs/references/killmail-notification-capabilities.md` in that repository.

Intended outcome: a map owner configures one or two Discord webhooks on their map
and gets notifications equivalent in richness and routing to what wanderer-notifier
produces today.

## Scope

### In scope

1. Retain attacker character and corporation IDs through killmail flattening.
2. Per-map matching of tracked characters and focus corporations against victim
   and all attackers.
3. A second, character-role webhook per map, with per-webhook failure accounting.
4. Routing rules, including tracked-character carve-outs for the exclusion list
   and wormhole-only mode.
5. Richer embeds: semantic colour, author line, linked prose, relative timestamp,
   large ship render, killmail-ID footer.
6. Map-local system names on the system webhook only (privacy constraint, §7).
7. Jittered exponential reconnect backoff on the kills WebSocket client.
8. A maximum-age guard on killmails reaching the dispatcher.
9. Fix the `:map_kill` JSON:API attribute names, which currently emit `nil`.

### Explicitly deferred

Not built now; the design must not preclude them.

| Item | Why deferred |
|---|---|
| Preload/backfill on channel join, and its startup-suppression counterpart | wanderer restarts are rare; the value does not justify the flood risk it introduces |
| Upstream subscription by character ID (kills in untracked systems) | Roughly 4× the work of local matching; local matching covers every kill already visible in the map's kills widget |
| Notable loot with Janice appraisal | Self-contained, genuinely expensive, needs an ESI fetch path that does not exist yet |
| Priority systems | wanderer's `custom_flags` is a better home than a global env list; only useful once suppression rules exist |
| Periodic `[Killmail Status]` health line | Rejected — noisy in practice |
| HTTP fallback feed with circuit breaker | wanderer-kills shares wanderer's deployment; if it is down the kills widget is visibly dark, so the silent-failure case the notifier guards against does not exist here |
| Telemetry/connection-health expansion | Not needed |
| License-based degradation | Not applicable to wanderer |

## Repository evidence and constraints

Facts established by inspection, with sources. These constrain the design.

| Constraint | Source |
|---|---|
| Kills arrive only for systems tracked by some map; the upstream subscription is systems-only | `kills/client.ex:44-64`, `kills/subscription/manager.ex` |
| `MessageHandler` flattens each kill to victim + final-blow attacker, discarding the attacker list; only `attacker_count` and `npc` survive | `kills/message_handler.ex:259-346` |
| Fan-out to maps already exists and is system-indexed | `kills/subscription/map_integration.ex:159-190` |
| `map.characters` holds internal **uuid** character IDs, not EVE IDs; hydration is one `get_map_character!` per character | `map.ex:188-195, 262-268` |
| `Character.eve_id` is a **string**; killmail character IDs arrive as **integers** | `api/character.ex:180` |
| Delivery worker is keyed by `map_id` alone, and reads `notification.webhook_url` | `discord/worker.ex:83, 256` |
| Failure accounting (`consecutive_failures`, `enabled?`, `disable`) is per notification **row** | `api/map_discord_notification.ex:105-160` |
| `wh_only` defaults to `true`; `webhook_url` is `allow_nil? false` | `api/map_discord_notification.ex:167-176` |
| Dedup key is `"#{map_id}:#{killmail_id}"`, not role-scoped; dedup is at-most-once by choice | `discord_dispatcher.ex:20-39, 291` |
| Config cache TTL is 5 minutes; dedup cache is in-memory, 24h | `application.ex:133-139` |
| The external JSON:API formatter uses an **allowlist** for `:map_kill`, so internal payload additions do not leak to SSE or webhook subscribers | `json_api_formatter.ex:364-375` |
| `MapSystem` has both `custom_name` and `temporary_name`, with `by_map_id_and_solar_system_id` for lookup | `api/map_system.ex:15,18,82` |

## Design

### 1. Data model — split destinations from policy

The current single row cannot express two webhooks correctly: `record_failure`
increments one counter and disables the whole config at 10, and `disable` fires
immediately on a 404. With two URLs on one row, **deleting the character channel
in Discord would switch off system-kill notifications too** — the failure is not
attributable to the webhook that caused it.

Split the resource so the parent holds policy and each child holds one destination.

**`map_discord_notifications_v1`** (existing table, altered) — per-map policy:

- Keeps: `map_id`, `enabled?`, `wh_only`, `excluded_systems`.
- Adds: `focus_corp_ids` `{:array, :integer}`, default `[]`.
- Removes (moved to child): `webhook_url`, `last_delivery_at`, `last_error`,
  `last_error_at`, `consecutive_failures`.

**`map_discord_webhooks_v1`** (new) — one row per destination:

| Column | Notes |
|---|---|
| `id` | uuid primary key |
| `notification_id` | belongs_to, `on_delete: :delete` |
| `role` | `:system` or `:character` |
| `webhook_url` | encrypted via AshCloak, `allow_nil? false`, max 2000 |
| `enabled?` | boolean, default true |
| `last_delivery_at`, `last_error`, `last_error_at`, `consecutive_failures` | per-webhook failure state, moved verbatim |

Identity: unique on `[notification_id, role]`.

The `cloak` block, `valid_webhook_url?/1`, and the `@discord_hosts` allowlist move
to the child resource. `record_success`, `record_failure`, and `disable` move to
the child and otherwise keep their current semantics, including the
`@max_consecutive_failures 10` threshold and the 404-only immediate disable.

Rationale for a child table over parallel columns (`character_webhook_url`,
`character_consecutive_failures`, …): correctness by construction rather than by
discipline, and a third destination later costs a row rather than five columns.

### 2. Ingestion — retain attacker identity

`MessageHandler.adapt_nested_format_kill/1` gains two fields on the flattened kill:

- `attacker_char_ids` — integer list, nils rejected (NPC attackers have none)
- `attacker_corp_ids` — integer list, nils rejected, deduplicated

Everything else about the flattening is unchanged, including
`@required_output_fields` (the new fields are optional; an empty list is valid).

These stay internal. The external JSON:API formatter's allowlist means SSE and
generic-webhook subscribers are unaffected. Growth is confined to internal PubSub,
the 24h killmail cache, and the frontend kills widget — roughly 1–2 KB on a
100-attacker fight, and typical wormhole kills are far smaller.

`attacker_corp_ids` is retained even though focus-corp matching is the only
consumer, because collecting it costs one `Enum.map` over a list already in hand.

### 3. Matching — per-map, cached

The dispatcher receives an event already scoped to one `map_id`, so matching
happens there, alongside the config lookup it already performs. No reverse index
and no fan-out change.

**Tracked EVE ID set.** `Map.list_characters/1` hydrates every character on every
call, which is too expensive per killmail. Introduce a cached
`MapSet` of integer EVE IDs per map:

- Cache key `"map:#{map_id}:tracked_eve_ids"`.
- Built lazily from `Map.list_characters/1`, converting each `eve_id` **string** to
  an integer once at build time.
- Invalidated from `Map.add_character/2` and `Map.remove_character/2`.

The string-to-integer conversion is the single most likely source of a silent bug
here: a type mismatch matches nothing and looks exactly like "no tracked pilots
were involved." It gets an explicit test (§9).

**Involvement verdict.** For each kill and map:

```
victim char_id in tracked_eve_ids                  -> {:involved, :victim}
victim corp_id in focus_corp_ids                   -> {:involved, :victim}
any attacker char_id in tracked_eve_ids            -> {:involved, :attacker}
any attacker corp_id in focus_corp_ids             -> {:involved, :attacker}
otherwise                                          -> :not_involved
```

Victim checks precede attacker checks, so a kill where both sides are tracked
renders as a loss. This is deliberate: losses are the more urgent signal.

Corporation focus is implemented by widening "tracked" rather than as a separate
routing concept. It therefore earns the same colouring and the same carve-outs as
character tracking, at no additional routing complexity.

### 4. Routing

Evaluated in order. `involved?` is §3's verdict.

| # | Condition | Destination |
|---|---|---|
| 1 | System in `excluded_systems`, not involved | **drop** |
| 2 | `wh_only` on, system is not a wormhole, not involved | **drop** |
| 3 | Involved | character webhook |
| 4 | Otherwise | system webhook |

Notes:

- Rules 1 and 2 are the carve-outs: a kill involving your own pilots is always
  interesting, wherever it happened, so exclusion and wormhole-only filters do not
  apply to it.
- **The `:system` webhook is required; the `:character` webhook is optional.** The
  migration creates a `:system` row for every existing config, and creating a
  notification requires one.
- **Fallback:** when no `:character` webhook row exists, rule 3 resolves to the
  system webhook. Every existing single-webhook configuration therefore keeps
  working with no user action, and the character channel is purely opt-in.
- **Disabled destinations drop rather than reroute.** The parent's `enabled?` gates
  everything, as today. Beyond that, if the webhook a kill routes to is itself
  disabled — whether by the user or by the failure threshold — the kill is dropped
  rather than sent to the other channel. Disabling a channel must mean silence for
  that class of kill, not silent misdirection into a channel the user did not
  choose, which for a public character channel is also a privacy question (§7).
- Exactly one destination is chosen. The dedup key stays `"#{map_id}:#{killmail_id}"`.
  Should a future change ever post one kill to both channels, that key must gain
  the role or the second post will be suppressed.

### 5. Embeds

Replaces the current fixed-red, field-grid embed.

**Colour**

- Loss (`:victim`) — `0xE74C3C`
- Kill (`:attacker`) — `0x2ECC71`
- Not involved — ISK tiering: `>=5B 0xFF0000`, `>=1B 0xFF6600`,
  `>=100M 0xFFFF00`, `>=10M 0x00FF00`, else `0x808080`

The kill green and the 10M-tier green are distinct meanings sharing a hue; the
author line disambiguates.

**Author line** — `"Kill"` or `"Loss"` with the relevant corporation logo
(`https://images.evetech.net/corporations/{corp_id}/logo?size=64`): the victim's
corp on a loss, the final-blow pilot's corp on a kill. **Omitted entirely when not
involved**, since neither label would be true.

**Title** — `"{ship} destroyed in {system_display_name}"` (§7 governs the name).

**Description** — prose replacing the field grid, every name linked to zKillboard:

```
**[Pilot](zkill/character/id)** (**[TICKER](zkill/corporation/id)**) lost their
**Ship** to **[FinalBlow](…)** (**[TICKER](…)**), top damage by **[Other](…)**,
and N others.
```

Special cases: solo kills omit the "and N others" clause; top damage is named only
when it differs from the final blow; NPC attackers render as absent rather than as
a placeholder name.

**Fields** — `Value` (existing ISK formatter) and `When` (`<t:unix:R>`), both
inline. Everything else moves into the prose.

**Thumbnail** — 1024px ship render when `victim_ship_type_id` is present;
otherwise the character portrait when `victim_char_id` is present; otherwise
omitted. Note this is *not* a 404 fallback: Discord fetches the image, so a failed
fetch is not observable to us. Selection is on field presence only.

**Footer** — `"Killmail ID: {id}"`. The corp ticker moves into the prose.

Batching is unchanged: 10 embeds per message, `@max_kills_per_event 30`, and the
existing overflow line.

### 6. Delivery

- The worker Registry key becomes the **webhook id** instead of `map_id`, so each
  webhook gets its own queue. Discord rate-limits per webhook; sharing a queue
  would let a 429 on the character channel stall system kills.
- `WorkerSupervisor.deliver/3` takes a webhook id; the worker reloads the webhook
  row for its URL and records outcomes against that row.
- `after_destroy` on a webhook stops its worker. Destroying a notification cascades
  to its webhooks and stops all their workers.

Everything else about the worker — queue cap 100, 5 attempts, `retry-after`
parsing, 1s→8s backoff, scheduling via `send_after` rather than sleeping — is
unchanged.

### 7. Privacy constraint — map-local names

**Map-local system names (`temporary_name`, then `custom_name`) appear on the
system webhook only. The character webhook always shows the canonical EVE name.**

This is a privacy boundary, not a formatting preference. Corporations commonly keep
the character-kill channel public so members without map access can see kills and
losses. Map-local chain naming in that channel leaks the map's private naming to
people who were deliberately not granted map access, and a message posted to a
public channel cannot be recalled.

Resolution order on the system webhook: `temporary_name` → `custom_name` →
canonical name, looked up via
`MapSystem.by_map_id_and_solar_system_id/2`.

This rule looks like an inconsistency and will invite a "fix." It gets a regression
test named for the constraint, and this paragraph is the reason a reviewer should
find when they go looking.

### 8. Ingestion resilience and staleness

**Reconnect backoff.** Replace the fixed `[5s, 10s, 30s, 60s]` ladder
(`kills/client.ex:16`) with exponential backoff from 1s to a 60s ceiling, plus
~30% jitter. Without jitter, every instance restarting after an upstream blip
reconnects in lockstep.

**Maximum age.** Kills older than `discord_max_killmail_age_seconds` (default 3600)
are dropped at the dispatcher. This guards against upstream replay on reconnect,
and is the precondition that would make preload safe if it is ever added. Parsing
failure on `kill_time` **allows** the kill through — fail-open, consistent with the
dispatcher's existing posture.

### 9. Incidental fix — `:map_kill` JSON:API attributes

`json_api_formatter.ex:364-375` reads `payload["victim_character_name"]`,
`payload["victim_ship_type"]`, `payload["system_id"]`, and
`payload["killmail_time"]`, but `MessageHandler` produces `victim_char_name`,
`victim_ship_name`, `solar_system_id`, and `kill_time`. All four have been emitting
`nil` to every external subscriber.

Correct the key names. This is a behaviour change for external consumers — those
attributes go from always-`nil` to populated — and warrants a changelog line, since
a consumer may have coded around the nils.

## Migration and compatibility

**Schema migration** (`mix ash.codegen`, applied via `mix ash.migrate`):

1. Create `map_discord_webhooks_v1`.
2. For each `map_discord_notifications_v1` row, insert a child with
   `role = :system`, copying `webhook_url` and all four failure-state columns.
3. Drop the moved columns from the parent; add `focus_corp_ids` defaulting to `[]`.

**Ciphertext portability risk.** `webhook_url` is encrypted at rest through AshCloak.
Step 2 copies the ciphertext between tables. This is safe only if the vault's
encryption is not bound to the table or row identity. **This must be verified against
the configured `WandererApp.Vault` before the migration is written** — if the
binding does exist, the migration has to decrypt and re-encrypt through the
application rather than move ciphertext in SQL.

**Behaviour change on upgrade.** `wh_only` defaults to `true`, so most existing maps
have it on. The tracked-character carve-outs (§4, rules 1–2) mean kills involving
your pilots outside wormhole space, or in excluded systems, **will start posting
where they previously did not**. Nobody changes a setting; the channel simply gets
busier after the upgrade. This was accepted deliberately as the better default
rather than gated behind an opt-in flag. It needs a changelog entry.

**No change required of users.** Existing single-webhook configs migrate to a
single `:system` webhook and behave as before, aside from the carve-outs above and
the richer embeds.

## Failure behaviour

| Failure | Behaviour |
|---|---|
| `kill_time` unparseable | Kill allowed through (fail-open) |
| Tracked-EVE-ID cache miss or error | Rebuild from `list_characters/1`; on error treat as not involved and route to the system webhook rather than dropping |
| Character webhook absent | Rule 3 falls back to the system webhook |
| Chosen webhook disabled | Kill dropped, not rerouted (§4) |
| One webhook 404s | Only that webhook is disabled; the other keeps delivering |
| One webhook rate-limited | Only its own queue backs off; the other is unaffected |
| Worker tree not running | Dedup marks released, as today (`discord_dispatcher.ex:196-204`) |

Dedup remains at-most-once by choice: a kill lost to delivery failure is not
re-sent, because a duplicate post in a chat channel is irreversible while a dropped
kill is still visible in the kills widget and on zKillboard.

## Testing

Unit tests, `async: true` where no shared state is involved.

**Matching**

- EVE ID given as a string matches a killmail integer ID — the coercion regression.
- Victim tracked → `:victim`; attacker tracked → `:attacker`; both → `:victim`.
- Focus corp matches on victim corp and on attacker corp.
- No attackers, NPC-only attackers, and empty ID lists.

**Routing** — one test per table row in §4, plus the character-webhook fallback,
plus both carve-outs (excluded system with a tracked pilot; non-wormhole with a
tracked pilot).

**Privacy** — a test named for the constraint asserting that a system with a
`temporary_name` renders the canonical name on the character webhook and the
temporary name on the system webhook.

**Embeds** — colour selection across all three branches and every ISK tier
boundary; author line omitted when not involved; thumbnail selection across
present/absent ship type and character; solo kill; top damage equal to final blow;
overflow line preserved.

**Resource** — per-webhook failure isolation: failing one webhook to threshold
leaves the sibling enabled.

**Migration** — an existing single-webhook row becomes one `:system` child with
failure state intact and a decryptable URL.

**Environment note:** the Elixir toolchain is not installed on the WSL host
(`.tool-versions` pins Elixir 1.17.3-otp-26 / Erlang 26.2.5.5, both reported
missing by mise). Tests must be run in the devcontainer.

## Open risks

1. **Ciphertext portability across tables** — must be settled before writing the
   migration (see above). It is the only item that could force a materially
   different migration strategy.
2. **Cache invalidation coverage** — the tracked-EVE-ID cache is invalidated from
   `Map.add_character/2` and `remove_character/2`. If any other path mutates
   `map.characters`, the set goes stale and notifications route to the wrong
   channel. Worth a grep for writers of `:characters` during implementation.
3. **Payload growth in the kills cache** — bounded and small per kill, but it
   applies to every cached killmail for 24h, not only to those in flight.
