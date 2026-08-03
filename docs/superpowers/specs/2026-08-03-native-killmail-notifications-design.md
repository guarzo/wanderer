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
9. Configuration UI for managing both destinations independently.
10. Fix the `:map_kill` JSON:API attribute names, which currently emit `nil`.

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
| `webhook_url` | AshCloak attribute; the physical column is `encrypted_webhook_url :binary`, matching the existing table (`priv/repo/migrations/20260801234058_add_map_discord_notifications.exs:38`) |
| `enabled?` | boolean, default true |
| `last_delivery_at`, `last_error`, `last_error_at`, `consecutive_failures` | per-webhook failure state, moved verbatim |

Identity: unique on `[notification_id, role]`.

**Enforcing "a system webhook always exists."** The unique identity gives *at most*
one webhook per role; it cannot give *at least* one. The invariant is enforced in
the create action instead:

- `MapDiscordNotification.create` takes a `webhook_url` argument and creates the
  parent and its `:system` child **in one transaction**
  (`Ash.Changeset.manage_relationship/4` with `type: :create`, or an explicit
  transaction). Either both rows exist or neither does; a failure on the child
  rolls the parent back rather than leaving a policy row with no destination.
- The `:character` webhook is added afterwards as an ordinary child create.
- Destroying the `:system` webhook directly is not offered. Removing kill
  notifications entirely means destroying the parent.

Because the invariant is transactional rather than declarative, it gets a test that
asserts no parent exists after a forced child-create failure.

**Cache invalidation from the child.** The dispatcher caches the config for five
minutes (`application.ex:133`), and today invalidation hangs off the parent
(`map_discord_notification.ex:197`). With destinations in a child table, **every
child create, update, destroy, and enable/disable must invalidate the parent's
cache entry too** — otherwise a newly added character webhook is ignored for up to
five minutes, and a removed one keeps being selected, dropping kills that should
have fallen back to the system webhook.

The child's `after_action` hooks resolve `map_id` by reading their
`notification_id` (one extra read, on a rare path) and then call
`DiscordDispatcher.invalidate_cache/1`, guarded by the same `rescue` the parent
uses so a missing cache never fails the write.

`MapDiscordNotification.by_map/1` must load the `:webhooks` relationship, since the
cached value is what routing reads.

The `cloak` block, `valid_webhook_url?/1`, and the `@discord_hosts` allowlist move
to the child resource. `record_success`, `record_failure`, and `disable` move to
the child and otherwise keep their current semantics, including the
`@max_consecutive_failures 10` threshold and the 404-only immediate disable.

Rationale for a child table over parallel columns (`character_webhook_url`,
`character_consecutive_failures`, …): correctness by construction rather than by
discipline, and a third destination later costs a row rather than five columns.

### 2. Ingestion — retain attacker identity

`MessageHandler.adapt_nested_format_kill/1` gains these fields on the flattened kill:

- `attacker_char_ids` — integer list, nils rejected (NPC attackers have none)
- `attacker_corp_ids` — integer list, nils rejected, deduplicated
- `top_damage_char_id`, `top_damage_char_name`, `top_damage_corp_id`,
  `top_damage_corp_ticker` — the attacker with the highest `damage_done`

The top-damage fields exist because §5's prose names and links that pilot; the ID
lists alone cannot render it. They are extracted by a `find_top_damage_attacker/1`
mirroring the existing `find_final_blow_attacker/1`
(`message_handler.ex:374-391`), and populated through the same
`add_final_blow_attacker_data/2`-style helper, so both attackers are resolved by
one shared code path. When the top-damage attacker *is* the final-blow attacker,
the fields are still populated; §5 decides whether to render them.

`@required_output_fields` is unchanged — all new fields are optional, and empty
lists and nils are valid (a kill with only NPC attackers has no top-damage pilot).

These stay internal. The external JSON:API formatter's allowlist means SSE and
generic-webhook subscribers are unaffected. Growth is confined to internal PubSub,
the 24h killmail cache, and the frontend kills widget — roughly 1–2 KB on a
100-attacker fight, and typical wormhole kills are far smaller.

`attacker_corp_ids` is retained even though focus-corp matching is the only
consumer, because collecting it costs one `Enum.map` over a list already in hand.

**The already-flat branch.** `adapt_kill_data/1` has a second supported input
shape: a payload that already carries `victim_char_id` is passed through
`validate_flat_format_kill/1`, which only checks three required fields and returns
the map otherwise unchanged (`message_handler.ex:187-197`, `243-255`). Such a
payload has no `attackers` list to extract from, so it arrives with none of the
new fields and would silently match nobody — the exact failure mode §3 warns
about, where "no tracked pilots involved" and "the data was never there" look
identical.

The design does **not** assume upstream stops sending flat payloads. Instead:

- Matching treats a **missing** attacker key as unknown, not as an empty list.
  `attacker_char_ids` absent ≠ `attacker_char_ids: []`. Victim matching still runs
  normally, since `victim_char_id` and `victim_corp_id` are present in both shapes.
- When the keys are absent and the victim does not match, the kill is routed to
  the system webhook (the same conservative destination as a matching-cache
  failure, per the failure table) rather than dropped or attributed.
- A flat payload that *does* carry the new keys — which is what upstream will send
  once it is the one producing them — is used as-is. The pass-through branch needs
  no change for that case.
- This divergence is logged once per occurrence at debug level with the killmail
  ID, so if flat payloads turn out to be common in production it is visible rather
  than inferred from missing notifications.

This is a compatibility behaviour, not a normalization: reconstructing attacker
arrays that were never sent is impossible, and pretending an empty list is
equivalent would be worse than admitting the data is unknown.

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
- Invalidated from every writer of `map.characters`: `Map.add_character/2`,
  `Map.remove_character/2`, and `Map.add_characters!/2` (`map.ex:235-258`), which
  is the bulk path used when a map initialises. Missing that third writer would
  leave the set stale exactly when a map starts up.

The string-to-integer conversion is the single most likely source of a silent bug
here: a type mismatch matches nothing and looks exactly like "no tracked pilots
were involved." It gets an explicit test (see Testing).

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
- Exactly one destination is chosen **per kill**. The dedup key stays
  `"#{map_id}:#{killmail_id}"`. Should a future change ever post one kill to both
  channels, that key must gain the role or the second post will be suppressed.

### 4.1 Batching across mixed destinations

A single `:map_kill` event carries a batch of killmails for one system, and the
current dispatcher formats and delivers that batch as a unit to one destination
(`discord_dispatcher.ex:148-180`). Routing is per-kill, so one batch can now
contain kills bound for different destinations, or bound for none.

The dispatch sequence becomes:

1. Reject duplicates, as today, producing `fresh`.
2. **Partition `fresh` per kill** into `%{system: [...], character: [...]}`,
   applying §4 in order. Kills that drop (rules 1 and 2, or a disabled
   destination) fall out here and belong to no partition.
3. **For each non-empty partition independently:**
   - Split the partition at `EmbedFormatter.max_kills_per_event()` into a
     *rendered* head and an overflow tail. **The cap is per destination, not per
     event** — it is a Discord message-size concern, so two destinations do not
     compete for one budget.
   - Mark exactly the rendered head as attempted, keyed by map and killmail as
     today. Kills beyond the cap are never rendered and so are never marked,
     preserving the existing rule that a kill lost to a *formatting* cap stays
     eligible.
   - **Pass the whole partition — not the truncated head — to the formatter**,
     which takes the cap itself and counts the remainder into its overflow line.
     This mirrors the current dispatcher exactly, where `formatted` is marked but
     `fresh` is what reaches `format_batch/2` (`discord_dispatcher.ex:165-172`);
     handing the formatter the pre-truncated list would silently delete the
     overflow line.
   - Format with that destination's system-name policy (§7) — this is why
     formatting happens per partition rather than once.
   - Deliver to that destination's webhook id.
4. Each partition's delivery result is handled independently. A
   `{:error, :not_running}` releases only that partition's marks.

Consequences worth stating: a kill dropped by §4 is never marked, so it stays
eligible if it arrives again. The overflow line ("…and N more kills not shown.")
is computed per destination and counts only that destination's overflow. Telemetry
counts are emitted per destination with the role in the metadata, rather than once
for the event.

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
- `after_destroy` on a webhook stops its worker.
- **Destroying a notification must stop its children's workers explicitly.** The
  child FK uses `on_delete: :delete`, which is a PostgreSQL cascade — the database
  removes the rows without Ash running the children's `after_destroy` hooks, so
  their workers would survive and keep posting to webhooks whose rows are gone.
  The parent's destroy therefore reads its child webhook ids in a `before_action`,
  stashes them in the changeset context, and stops those workers in its
  `after_action`. Reading them afterwards is too late: the rows are already gone.

  This mirrors the existing reason `after_destroy` stops the map's worker today
  (`map_discord_notification.ex:203-209`) — without it, queued messages keep
  posting to a webhook the user just removed.

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

The jitter must be injectable for testing — the delay calculation takes the random
source as an argument (or reads a module attribute overridable in test config) so a
test can pin it and assert exact values. A function that calls `:rand.uniform/1`
internally can only be tested by asserting a range, which would not catch a ceiling
applied before jitter instead of after.

**Maximum age.** Kills older than `discord_max_killmail_age_seconds` (default 3600)
are dropped at the dispatcher. This guards against upstream replay on reconnect,
and is the precondition that would make preload safe if it is ever added. Parsing
failure on `kill_time` **allows** the kill through — fail-open, consistent with the
dispatcher's existing posture.

**Configuration plumbing.** The new key follows the existing three-file pattern
used by `webhooks_enabled`, and all three must be touched or the default silently
becomes the only reachable value:

1. `config/runtime.exs` — add to the `:external_events` block alongside
   `webhook_timeout_ms` (`runtime.exs:495-500`), read via
   `get_int_from_path_or_env("WANDERER_DISCORD_MAX_KILLMAIL_AGE_SECONDS", 3600)`.
2. `lib/wanderer_app/env.ex` — a `discord_max_killmail_age_seconds/0` accessor
   mirroring `webhooks_enabled?/0` (`env.ex:92-95`), so the dispatcher never reads
   `Application.get_env` directly.
3. `.env.example` — document it next to `WANDERER_WEBHOOK_TIMEOUT_MS` (line 18).

### 9. Configuration UI

`map_notifications_component.ex` is single-destination throughout: `save` handles
one `webhook_url`, `replace-url` is a single boolean, `send-test` targets the map,
and status is read from the parent row. The stated outcome — an owner configures
one or two webhooks and their focus corporations — requires reworking it.

**Per destination** (`:system` and `:character`), the component offers:

| Action | Behaviour |
|---|---|
| Add | Only shown for `:character`; `:system` always exists (§1) |
| Replace URL | Per-destination `replacing_url?` state, replacing today's single boolean. The URL is still never rendered back in full. |
| Remove | `:character` only. `:system` cannot be removed; removing notifications entirely means deleting the parent. |
| Enable/disable | Per destination, independent of the parent's `enabled?` |
| Send test | Targets one webhook id, so an owner can verify each channel separately |
| Status | Per destination: `last_delivery_at`, `last_error`, `consecutive_failures`, and whether the failure threshold disabled it |

The system destination is presented first and described as required; the character
destination is presented as optional, with its fallback behaviour (§4) stated in
the UI so an owner understands that leaving it unset sends everything to the system
channel rather than dropping it.

**Focus corporations** reuse the `live_select` pattern already built for excluded
systems (`map_notifications_component.ex:85-110`): search by corporation name,
resolve to a corporation ID, render as removable chips. Add and remove are separate
events guarded the same way `add-excluded` and `remove-excluded` are — reachable
only from a rendered record.

Corporation search needs plumbing that does not exist yet, and this is the one part
of the UI that is not a straight copy of an existing pattern:

- **The component has no user.** `MapNotificationsComponent` is passed only
  `map_id` (`maps_live.html.heex:665-669`). It must also receive `current_user`,
  since ESI search is performed *as a character*.
- **The search itself is private to another handler.**
  `search_corporation_names/2` lives in `map_systems_event_handler.ex:629-660`; it
  takes the user's character list, requires a search string of at least three
  characters, calls `Character.search/2` with `categories: "corporation"`, then
  enriches each hit with a ticker via `Esi.get_corporation_info/1` to build a
  `[TICKER] Name` label. Extract it into a shared module both callers use rather
  than copying it — the ticker-enrichment and minimum-length rules are behaviour
  worth having in one place.
- **A user with no characters cannot search.** The function's first clause returns
  `{:ok, []}` for an empty character list. The UI must say so explicitly instead of
  showing an empty dropdown that looks like "no such corporation".
- **Stored IDs must resolve back to labels.** `focus_corp_ids` persists integers,
  so after a page reload the chips have to be rehydrated through
  `Esi.get_corporation_info/1`. When that call fails or the ESI is down, render the
  bare ID as the chip label rather than dropping the chip — a silently vanishing
  focus corporation would look like the setting was lost, and the user might re-add
  a duplicate. Removal must work from the ID-labelled chip too.

**Test-message semantics are unchanged and still weaker than they look.**
`send_test_message/1` returns `:ok` on *enqueue*, not on delivery
(`discord_dispatcher.ex:71-84`); the UI must keep saying "queued", not "sent".

### 10. Incidental fix — `:map_kill` JSON:API attributes

`json_api_formatter.ex:364-375` reads `payload["victim_character_name"]`,
`payload["victim_ship_type"]`, and `payload["system_id"]`, but `MessageHandler`
produces `victim_char_name`, `victim_ship_name`, and `solar_system_id`. Those three
have been emitting `nil` to every external subscriber.

`occurred_at` is a fourth, subtler case: it reads `payload["killmail_time"]` —
also never present — but falls back to `event.timestamp`
(`json_api_formatter.ex:373`). So it has been populated, with the time the event
was *broadcast* rather than the time of the kill. Correcting it to `kill_time`
changes its value rather than filling in a nil.

Correct all four key names. This is a behaviour change for external consumers —
three attributes go from always-`nil` to populated, and `occurred_at` changes
meaning — and warrants a changelog line, since a consumer may have coded around
the nils or be relying on the broadcast timestamp.

## Migration and compatibility

**Schema migration** (`mix ash.codegen`, applied via `mix ash.migrate`):

1. Create `map_discord_webhooks_v1`.
2. For each `map_discord_notifications_v1` row, insert a child with
   `role = :system`, copying `webhook_url`, all four failure-state columns, **and
   `enabled?`**.
3. Drop the moved columns from the parent; add `focus_corp_ids` defaulting to `[]`.

**Mapping `enabled?` across the split.** Today a single parent flag carries two
distinct meanings: the user switching notifications off, and `record_failure`
auto-disabling after ten consecutive failures
(`map_discord_notification.ex:128`). After the split those meanings separate —
the parent flag becomes purely the user's intent for the map, and each child's
flag is that destination's health.

The migration cannot tell the two apart retroactively, so it copies `enabled?` to
**both** rows. A row disabled by failure therefore migrates to parent-disabled
*and* child-disabled. That is the conservative direction: a map that was silent
before the upgrade stays silent after it, and no webhook starts posting because a
migration guessed generously. The cost is that a user re-enabling at the map level
also has to re-enable the destination — acceptable, and only for the small set of
maps that were disabled at migration time.

The parent must keep `enabled?` for exactly this reason: it is the user-facing
kill switch for the whole map and cannot be inferred from the children.

**Ciphertext portability — resolved, safe to copy in SQL.** `AshCloak.do_encrypt/2`
is `value |> :erlang.term_to_binary() |> vault.encrypt!() |> Base.encode64()`
(`deps/ash_cloak/lib/ash_cloak.ex:65-73`). The resource is used only to look up
which vault to use; neither the table nor the row identity enters the ciphertext,
and the vault's AES-GCM uses fixed AAD. Moving the `encrypted_webhook_url` column
value between tables therefore decrypts correctly, and step 2 can be plain SQL with
no decrypt/re-encrypt round trip through the application.

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
| Attacker keys absent (flat-format payload) | Treated as unknown, not empty; victim matching still runs, otherwise routed to the system webhook (§2) |
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
- **Absent vs. empty attacker keys** (§2): a flat-format payload with no
  `attacker_char_ids` key at all, and a non-matching victim, routes to the system
  webhook — distinct from a payload carrying `attacker_char_ids: []`, which is a
  genuine NPC kill. Plus: a flat payload whose victim *does* match still attributes
  correctly, and a flat payload that already carries the new keys is used as-is.

**Resilience (§8)**

- Max age: a kill exactly at the boundary, one second either side, a
  future-dated `kill_time`, and an unparseable `kill_time` (fail-open, allowed
  through).
- Backoff: with the random source pinned, the delay sequence is exactly the
  expected values; the ceiling holds after jitter is applied, not before, so no
  delay ever exceeds 60s; and the first retry is not zero.
- The env accessor returns the configured value, not only the default.

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

**Batch partitioning (§4.1)** — a single event carrying kills that route to
different destinations produces one message set per destination, each formatted
under that destination's name policy. Specifically:

- A mixed batch (one tracked-pilot kill, one bystander kill) delivers to both
  webhooks, and the character-webhook message shows the canonical system name
  while the system-webhook message shows the map-local one.
- The 30-kill cap applies **per destination**, not per event: 30 kills to each of
  two destinations all render, and the overflow line counts only that
  destination's excess.
- A 35-kill partition marks 30 and renders an overflow line reading 5 — proving
  the formatter received the full partition, not the truncated head.
- A batch whose kills all route to one destination produces exactly one delivery,
  matching today's behaviour.
- Delivery failure on one partition does not release or affect the dedup marks of
  the other.

**Resource** — per-webhook failure isolation: failing one webhook to threshold
leaves the sibling enabled. Creating a notification without a `:system` child is
rejected. Destroying the parent stops both workers. Creating, updating, or
destroying a child invalidates the parent map's config cache.

**Configuration UI (§9)** — LiveView tests: adding a character webhook, replacing
a URL without the stored value ever being rendered back, removing the character
webhook while the system webhook remains, the system webhook not being removable,
per-destination enable/disable, and the test message reporting "queued" rather
than "sent". Focus corps: a user with no characters gets an explicit message rather
than an empty dropdown, and a stored `focus_corp_ids` entry whose
`get_corporation_info/1` lookup fails renders as an ID-labelled chip that is still
removable.

**Migration** — an existing single-webhook row becomes one `:system` child with
failure state intact and a decryptable URL. Separately, a **failure-disabled row**
(`enabled?: false`, `consecutive_failures: 10`) migrates to parent-disabled *and*
child-disabled, and posts nothing until both are re-enabled.

**Environment note:** the Elixir toolchain is not installed on the WSL host
(`.tool-versions` pins Elixir 1.17.3-otp-26 / Erlang 26.2.5.5, both reported
missing by mise). Tests must be run in the devcontainer.

## Open risks

1. **Cache invalidation coverage** — the tracked-EVE-ID cache is invalidated from
   `Map.add_character/2`, `remove_character/2`, and `add_characters!/2`. If any
   other path mutates `map.characters`, the set goes stale and notifications route
   to the wrong channel. Worth re-running a grep for writers of `:characters`
   during implementation, since a missed writer fails silently.
2. **Payload growth in the kills cache** — bounded and small per kill, but it
   applies to every cached killmail for 24h, not only to those in flight.
3. **Channel volume after upgrade** — the carve-outs make busy maps noisier with
   no user action. Accepted deliberately (see Migration), but it is the change most
   likely to generate feedback.
