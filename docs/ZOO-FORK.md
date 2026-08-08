# Zoo Fork Documentation

**Branch:** `guarzo/zoo`
**Upstream baseline:** `wanderer-industries/wanderer` — `main` @ `b7ddbc486`, `develop` @ `35ea4e5f1`
**Divergence:** 58 commits / 312 files / ~43.5k insertions ahead; 0 commits behind either upstream branch
**Last Updated:** 2026-08-08

This document describes the zoo fork's extensions to upstream Wanderer: database schema
changes, backend subsystems, frontend themes, deployment, and which changes are candidates
for upstream contribution.

---

## Table of Contents

1. [Overview](#overview)
2. [Database Schema Extensions](#database-schema-extensions)
3. [Discord Notifications](#discord-notifications)
4. [Intel Sharing](#intel-sharing)
5. [Theme System](#theme-system)
6. [Label System](#label-system)
7. [Signature Cleanup](#signature-cleanup)
8. [Fleet Readiness](#fleet-readiness)
9. [Deployment (Fly.io)](#deployment-flyio)
10. [CI](#ci)
11. [Configuration Reference](#configuration-reference)
12. [Commit Convention](#commit-convention)
13. [Upstream PR Recommendations](#upstream-pr-recommendations)
14. [Key Files Reference](#key-files-reference)
15. [Maintenance Notes](#maintenance-notes)

---

## Overview

| Feature | Purpose | Upstream candidate? |
|---------|---------|---------------------|
| Discord kill notifications | Per-map killmail embeds to Discord webhooks | Yes — large, needs discussion |
| Discord route alerts | Alert when a kill lands within N jumps of home | With the above |
| Discord voice mentions | Mention users in the map's voice channel | With the above |
| Intel sharing between maps | Copy system intel from a source map to subscribers | Yes — Tier 2 |
| Zoo theme | Custom visual styling for wormhole mapping | No |
| Label semantics | EVE-specific label meanings (EOL, Crit, etc.) | No |
| System ownership | Track corp/alliance ownership of systems | No |
| Fleet readiness | Mark characters ready for fleet operations | Tier 2 (generalize first) |
| On-demand signature cleanup | Configurable automatic signature expiration | Yes |
| Connection loop type | Self-connecting wormhole support | No |
| Fly.io deployment | Config, IPv6 transports, `/health`, gated deploy | Partly — see Tier 1 |
| Parallel CI | 4-way partitioned test suite, fixed caches | Yes |
| Upstream bug fixes | See [Tier 1](#tier-1-strongly-recommend) | Yes |

---

## Database Schema Extensions

The fork adds 2 tables and 8 columns to upstream tables, across 15 migration files (13 new,
2 modified in place). A further 4 columns are added by later migrations to the fork's *own*
new tables — the three route-alert columns and `mention_targets` below — which is why the
tables above list more columns than the "8" here counts.

### New tables

#### `map_discord_notifications_v1`

Per-map Discord notification config. One row per map (unique index on `map_id`).

| Column | Type | Purpose |
|--------|------|---------|
| `enabled?` | boolean | Master switch for the map |
| `wh_only` | boolean | Restrict notifications to wormhole systems |
| `excluded_systems` | bigint[] | Solar system IDs to never notify on |
| `route_alerts_enabled?` | boolean | Enable proximity route alerts |
| `home_system_id` | bigint | Origin for route-alert jump distance |
| `route_max_jumps` | bigint | Alert threshold in jumps (default 5) |
| `last_delivery_at` / `last_error` / `last_error_at` / `consecutive_failures` | — | Delivery health |

`encrypted_webhook_url` existed on this table originally and was moved to the child table
by `20260803210357_split_discord_webhooks`.

#### `map_discord_webhooks_v1`

One webhook destination per `(notification_id, role)`. Roles split delivery so kills,
route alerts, and system events can target different channels.

| Column | Type | Purpose |
|--------|------|---------|
| `role` | text | Destination role (e.g. `system`) |
| `encrypted_webhook_url` | binary | AshCloak-encrypted webhook URL |
| `enabled?` | boolean | Per-destination switch |
| `mention_targets` | text[] | Roles/users to mention on delivery (`20260807203453`) |
| `last_delivery_at` / `last_error` / `last_error_at` / `consecutive_failures` | — | Delivery health |

> `20260803210357_split_discord_webhooks.exs` is **hand-edited** after generation: it copies
> existing rows into the new table rather than dropping them, and strips four unrelated
> resources the generator picked up from stale snapshots. Read its `@moduledoc` before
> touching it — the ciphertext-copy reasoning and the `enabled?` semantics are load-bearing.

### Added columns

#### `map_system_v1`

| Column | Type | Purpose | Migration |
|--------|------|---------|-----------|
| `custom_flags` | text | Arbitrary flags for zoo features | `20250122214138` |
| `owner_id` | text | Corporation or Alliance EVE ID | `20250204223853` |
| `owner_type` | text | Entity type: 'corp' or 'alliance' | `20250204223853` |
| `owner_ticker` | text | Display ticker [TICKER] | `20250307165740` |

#### `map_user_settings_v1`

| Column | Type | Purpose | Migration |
|--------|------|---------|-----------|
| `ready_characters` | text[] | Character EVE IDs marked as fleet-ready | `20250625024813` |

#### `maps_v1`

| Column | Type | Purpose | Migration |
|--------|------|---------|-----------|
| `intel_source_map_id` | uuid FK (self, `nilify_all`) | Map that provides intel to this one | `20260209100000` |

#### `map_system_comments_v1`, `map_system_structures_v1`

| Column | Type | Purpose | Migration |
|--------|------|---------|-----------|
| `inherited_from_map_id` | uuid | Marks rows copied in by intel sync | `20260209100001` |

### Migration files

```text
priv/repo/migrations/
├── 20250122214138_add_zoo_flags.exs
├── 20250204223853_add_system_owners.exs
├── 20250307165740_add_owner_ticker.exs
├── 20250625024813_add_fleet_readiness_ready_characters.exs
├── 20260209100000_add_intel_source_map_id.exs
├── 20260209100001_add_inherited_from_map_id.exs
├── 20260801200000_fix_maps_scopes_default.exs        # see warning below
├── 20260801234058_add_map_discord_notifications.exs
├── 20260803202833_create_map_discord_webhooks.exs
├── 20260803210357_split_discord_webhooks.exs         # hand-edited
├── 20260804180000_add_map_chain_locked_by_fkey.exs    # constraint only, no column
├── 20260807203452_add_route_alert_config.exs
└── 20260807203453_add_webhook_mention_targets.exs
```

`20260804180000_add_map_chain_locked_by_fkey.exs` adds **no column**. It creates the
`map_chain_v1_locked_by_id_fkey` constraint on the existing `locked_by_id` reference, which
`MapConnection`'s `belongs_to :locked_by` has always implied but no database has ever had.

Two upstream migrations are also **modified in place** — `20260331192521` and `20260406213852`
each change `default: '{wormholes}'` to `default: ~c"{wormholes}"` to silence the Elixir
single-quoted-charlist deprecation. The emitted DDL is identical, so this is cosmetic, but it
means those two files can conflict whenever upstream changes them, until the equivalent change
lands upstream.

> **⚠ `20260801200000_fix_maps_scopes_default.exs` is not an upstream migration.**
> Commit `1b4970ffb` (#122) describes it as "upstream's", but it exists on neither
> `upstream/main` nor `upstream/develop` — it came in via #118, which pulled from an
> unmerged upstream PR. The fork's own equivalent (`20260804190000`, from #102) was deleted
> to resolve an `Ecto.MigrationError: migration name fix_maps_scopes_default is duplicated`
> that aborted the entire migrator. **If upstream later merges that fix under a different
> timestamp, the duplicate-module-name collision returns.** Check for a
> `FixMapsScopesDefault` module on every upstream merge.

### Rollback SQL (if needed)

```sql
ALTER TABLE map_system_v1 DROP COLUMN IF EXISTS custom_flags;
ALTER TABLE map_system_v1 DROP COLUMN IF EXISTS owner_id;
ALTER TABLE map_system_v1 DROP COLUMN IF EXISTS owner_type;
ALTER TABLE map_system_v1 DROP COLUMN IF EXISTS owner_ticker;

ALTER TABLE map_user_settings_v1 DROP COLUMN IF EXISTS ready_characters;

ALTER TABLE maps_v1 DROP COLUMN IF EXISTS intel_source_map_id;
ALTER TABLE map_system_comments_v1 DROP COLUMN IF EXISTS inherited_from_map_id;
ALTER TABLE map_system_structures_v1 DROP COLUMN IF EXISTS inherited_from_map_id;

DROP TABLE IF EXISTS map_discord_webhooks_v1;
DROP TABLE IF EXISTS map_discord_notifications_v1;

ALTER TABLE map_chain_v1 DROP CONSTRAINT IF EXISTS map_chain_v1_locked_by_id_fkey;
```

---

## Discord Notifications

The largest fork subsystem (~4,600 lines under `lib/wanderer_app/external_events/discord/`
plus `discord_dispatcher.ex`). It sits alongside upstream's `webhook_dispatcher.ex` and
consumes the same external-events stream.

### Modules

| Module | Purpose |
|--------|---------|
| `discord_dispatcher.ex` | Entry point; owns delivery decisions and per-map state |
| `discord/worker.ex`, `worker_supervisor.ex` | Per-map delivery workers |
| `discord/router.ex` | Routes an event to the right webhook role |
| `discord/matcher.ex` | Decides whether a killmail concerns a given map |
| `discord/embed_formatter.ex` | Builds the Discord embed |
| `discord/notable_items.ex` | Enriches embeds with high-value dropped items (ESI, concurrent) |
| `discord/corp_tickers.ex` | Resolves missing corporation tickers from ESI |
| `discord/mentions.ex` | Mention budget and formatting |
| `discord/voice_gateway.ex`, `voice_participants.ex` | Nostrum gateway; mentions users in voice |
| `discord/route_watcher.ex`, `route_watcher_supervisor.ex` | Proximity route alerts |
| `discord/system_name.ex` | System name resolution for embeds |
| `discord/http_client.ex` | Webhook HTTP transport (dedicated Finch pool) |

### Voice mentions and Nostrum

`nostrum` is declared `runtime: false` in `mix.exs` and listed as `nostrum: :load` in the
release, so the code ships but does not auto-start. `VoiceGateway` starts it at boot **only**
when a bot token and guild ID are configured. `config/runtime.exs` never configures Nostrum
in `:test` — the suite must stay hermetic.

### Route alerts

`lib/wanderer_app/map/route_alert/evaluator.ex` computes jump distance from the map's
configured `home_system_id`; `route_watcher.ex` drives the per-map watch loop and posts to
the route-alert webhook role when a kill lands within `route_max_jumps`.

---

## Intel Sharing

`lib/wanderer_app/map/intel_sync.ex` copies intel from a source map to a subscriber map for
a given solar system, either on visibility or on a manual re-sync.

- **Wiring:** `maps_v1.intel_source_map_id` designates the source map.
- **Fields copied:** `custom_name`, `description`, `tag`, `temporary_name`, `labels`, `status`.
- **Also copied:** system comments and structures, tagged with `inherited_from_map_id`.
- **Flag:** `WANDERER_INTEL_SHARING_ENABLED` (default `false`). When off, `sync_system/3`
  returns `{:ok, :disabled}` without touching the database.

---

## Theme System

Zoo adds a `zoo` theme alongside `default`, `pathfinder`, and the accessible themes.

### Key Files

| File | Purpose |
|------|---------|
| `assets/js/hooks/Mapper/components/map/styles/zoo-theme.scss` | Zoo theme styles |
| `assets/js/hooks/Mapper/components/map/components/SolarSystemNode/SolarSystemNodeZoo.tsx` | Zoo node component |
| `assets/js/hooks/Mapper/components/map/components/SolarSystemNode/SolarSystemNodeZoo.module.scss` | Zoo node styles |
| `assets/js/hooks/Mapper/components/map/labelIconMap.tsx` | Label icons and mappings |

### Theme Characteristics

- **Node Style:** Custom node component with zoo-specific rendering
- **Connection Mode:** Strict (vs Loose for other themes)
- **Labels:** EVE wormhole-specific meanings (see Label System below)
- **Colors:** Custom color palette for wormhole states

### CSS Class Namespace

Zoo-specific CSS classes use the `eve-zoo-` prefix:

```scss
.eve-zoo-effect-color-has-eol { fill: #FF69B4; }
.eve-zoo-effect-color-has-gas { fill: #FFFDD0; }
.eve-zoo-effect-color-is-critical { fill: #8B0000; }
.eve-zoo-effect-color-is-dead-end { fill: #34495E; }
```

---

## Label System

The zoo fork repurposes upstream's generic labels (A/B/C/1/2/3) with EVE Online
wormhole-specific meanings.

### Label Mappings

`Key` is the value actually written to `system.labels`. `Enum` is the TypeScript member name
in `LABELS`, which never leaves the frontend. `Badge` is the `shortName` rendered on the node.

| Key | Enum | Upstream | Zoo Meaning | Badge | Icon (`react-icons`) | Use Case |
|-----|------|----------|-------------|-------|----------------------|----------|
| `de` | `la` | Label A | Dead End | `DE` | `MdOutlineBlock` | System with no exit wormholes |
| `gas` | `lb` | Label B | Gas Site | `GAS` | `FaIndustry` | System has harvestable gas sites |
| `eol` | `lc` | Label C | End of Life | `EOL` | `FaHourglassEnd` | Wormhole about to collapse (<4h) |
| `crit` | `l1` | Label 1 | Critical Mass | `CRIT` | `FaExclamationTriangle` | Wormhole at mass verge |
| `structure` | `l2` | Label 2 | Structure | `LP` | `MdLocalFireDepartment` | System has attackable structure |
| `steve` | `l3` | Label 3 | Steve/Danger | `DB` | `FaSkull` | High danger (historic name) |

The `LP` and `DB` badges are inherited oddities, not typos. `LP` is "low power" — the
`structure` label is commented as "Low Power Structure" in `labelIconMap.tsx`. `DB` has no
expansion anywhere in the source; treat it as historic. The `name` field in `LABELS_INFO`
("Structure", "Steve") is what the context menu shows; `shortName` is what the node badge
shows.

### Storage

Labels are stored as the **zoo keys** — `de`, `gas`, `eol`, `crit`, `structure`, `steve` —
not the upstream `la`/`lb`/`lc` keys. `LABELS` is a TypeScript enum whose *member names* are
`la`…`l3` but whose *values* are the zoo keys, and it is the value that
`LabelsManager.toggleLabel/1` stores and `LabelsManager.toString/0` serializes into the JSON
written to `system.labels`. Querying the database for `la` will not match anything.

The backend treats `labels` as an opaque string; the frontend is the only producer and
consumer of these keys.

### Files

- **Definition:** `assets/js/hooks/Mapper/components/map/labelIconMap.tsx` — `LABELS`,
  `LABELS_INFO`, `LABELS_ORDER`, `LABEL_ICON_MAP`
- **Zoo styles:** `assets/js/hooks/Mapper/components/map/zooConstants.ts` —
  `ZOO_BOOKMARK_STYLES` / `ZOO_TEXT_STYLES`, spread into `MARKER_BOOKMARK_BG_STYLES` by
  `constants.ts`. Note these cover `de`, `gas`, `eol` and `crit` only; `structure` and
  `steve` fall through to the upstream `wd-marker-bookmark-color-l2`/`-l3` classes.
- **Re-export:** `assets/js/hooks/Mapper/components/map/constants.ts` — merges the above
- **CSS:** `assets/js/hooks/Mapper/components/map/styles/zoo-theme.scss`
- **Serialization:** `assets/js/hooks/Mapper/utils/labelsManager.ts`
- **Render:** `SolarSystemNodeZoo.tsx` (node badges), `useLabelsMenu.ts` (context menu)

---

## Signature Cleanup

Zoo implements on-demand signature cleanup (`lib/wanderer_app/map/signature_cleanup.ex`,
driven from `map_signatures_event_handler.ex`) in addition to upstream's daily batch cleanup.

### Comparison

| Aspect | Upstream GarbageCollector | Zoo On-Demand Cleanup |
|--------|---------------------------|----------------------|
| **Location** | `map_garbage_collector.ex` | `signature_cleanup.ex` |
| **Trigger** | Daily via Quantum scheduler | When user views/updates signatures |
| **Scope** | All signatures globally | Per-system |
| **Wormhole Expiration** | 14 days (hardcoded) | 24 hours (configurable) |
| **Other Signatures** | 14 days (hardcoded) | 72 hours (configurable) |
| **Preserve Connected** | No | Yes (configurable) |

### How They Interact

1. Zoo cleanup runs first (on user interaction) with aggressive thresholds
2. Upstream cleanup runs daily as a safety net
3. No conflict: zoo deletes before upstream sees the signatures
4. Upstream catches signatures in never-accessed systems

The fork also hardened the upstream collector itself — see
[Tier 1](#tier-1-strongly-recommend).

---

## Fleet Readiness

Allows users to mark characters as "ready for fleet" operations.

### Features

- Mark/unmark characters as fleet-ready
- View list of ready characters with locations and ships
- Per-map user settings storage

### Implementation

| Component | Location |
|-----------|----------|
| UI Components | `assets/js/hooks/Mapper/components/mapRootContent/components/FleetReadiness/` |
| Event Handler | `lib/wanderer_app_web/live/map/event_handlers/map_characters_event_handler.ex` |
| Ash Resource | `lib/wanderer_app/api/map_user_settings.ex` (update_ready_characters action) |
| Repository | `lib/wanderer_app/repositories/map_user_settings_repo.ex` |

> **No feature flag.** Fleet readiness is unconditionally on. A
> `WANDERER_FLEET_READINESS_ENABLED` variable was parsed in `config/runtime.exs` and stored
> under `:wanderer_app, :fleet_readiness_enabled`, but no `Env` accessor or call site was ever
> written for it in any branch, so setting it had no effect. It was removed rather than wired
> up: gating it at the default of `false` would have switched the feature off for every
> existing deployment.

---

## Deployment (Fly.io)

The fork deploys to Fly.io; upstream's VM release pipeline was dropped (`ce58765b9`).

### Fly-specific behaviour

| Concern | Handling |
|---------|----------|
| Hostname | `ConfigHelpers.resolve_host/2` — `PHX_HOST` wins, `FLY_APP_NAME` is the fallback |
| Base URL | `ConfigHelpers.resolve_web_app_url/4` — `WEB_APP_URL` wins, https assumed on Fly |
| Route builder over 6PN | `RouteBuilderClient.connect_opts/0` sets `inet6: true` (IPv4 fallback retained) |
| Kills websocket over 6PN | `WANDERER_KILLS_IPV6` (default `false`), mirrors the `ECTO_IPV6` precedent |
| Health check | `GET /health` → `HealthController` |

> The `/health` route's **position in `router.ex` is load-bearing**: it must stay above
> `live "/:slug", MapLive, :index`, or the wildcard swallows it and returns a 302 to
> `/welcome`. Its pipeline is deliberately minimal — no `CheckApiDisabled`, no auth, no rate
> limiting — because Fly kills a machine that fails its health check and there is one machine.

### Gated deploy

`.github/workflows/zoo-deploy.yml` implements an approval-gated deploy for `guarzo/zoo`.
Design and plan: `docs/superpowers/specs/2026-08-07-deploy-approval-gate-design.md` and
`docs/superpowers/plans/2026-08-07-deploy-approval-gate.md`. The Fly credential is read from
`FLY_DEPLOY_TOKEN` (not `FLY_API_TOKEN`), and the release number is read from `.Version`.

---

## CI

`.github/workflows/test.yml` was restructured (`e815c2283`, #121) from upstream's single
monolithic job into:

- `setup` — one dependency install/compile, cached for the rest
- `tests` — 4-way `mix test --partitions` matrix (the `PARTITIONS` env var must match the
  `partition` matrix list; `config/test.exs` already suffixes the database name with
  `MIX_TEST_PARTITION`, which is upstream's default)
- `static` — format, warning count, Credo
- `dialyzer` — PLT build + run
- `coverage` — coverage report and PR comment

The workflows also run on `guarzo/zoo` pull requests (`2e6487a84`, #117).

---

## Configuration Reference

### Compile-time (`config/config.exs`)

```elixir
config :wanderer_app, :signatures,
  wormhole_expiration_hours: 24,
  default_expiration_hours: 72,
  preserve_connected: true

config :wanderer_app, :signature_cleanup, max_age_hours: 24
```

### Runtime environment variables (`config/runtime.exs`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `WANDERER_INTEL_SHARING_ENABLED` | `false` | Enable cross-map intel sync |
| `WANDERER_KILLS_IPV6` | `false` | Resolve the kills websocket host over IPv6 |
| `DISCORD_BOT_TOKEN` | — | Nostrum bot token; blank is treated as unset |
| `DISCORD_GUILD_ID` | — | Guild for voice-participant lookups |
| `WANDERER_DISCORD_MENTIONS_ENABLED` | `true` | Master switch for mentions |
| `WANDERER_DISCORD_MAX_KILLMAIL_AGE_SECONDS` | `3600` | Drop killmails older than this |
| `WANDERER_DISCORD_POOL_SIZE` | `10` | Finch pool size for webhook delivery |
| `WANDERER_NOTABLE_ITEMS_ENABLED` | `false` | Enrich embeds with high-value drops |
| `WANDERER_NOTABLE_ITEMS_THRESHOLD_ISK` | `50000000` | Minimum item value to list |
| `WANDERER_NOTABLE_ITEMS_LIMIT` | `5` | Max items per embed |
| `WANDERER_NOTABLE_ITEMS_TIMEOUT_MS` | `1500` | Per-batch ESI budget |
| `WANDERER_CORP_TICKERS_ENABLED` | `true` | Resolve missing corp tickers from ESI |
| `WANDERER_CORP_TICKERS_TIMEOUT_MS` | `1500` | Per-element ESI budget |
| `SIGNATURE_WORMHOLE_EXPIRATION_HOURS` | `24` | Hours until wormhole signatures expire (`0` disables) |
| `SIGNATURE_DEFAULT_EXPIRATION_HOURS` | `72` | Hours until other signatures expire (`0` disables) |

### Pinned dependencies

| Dependency | Constraint | Reason |
|------------|-----------|--------|
| `phoenix_gen_socket_client` | `== 4.0.0` | `Kills.Transport.WebSocketClient` depends on its private handler-state shape |
| `gettext` | `~> 0.26` | `WandererAppWeb.Gettext` uses `Gettext.Backend`, absent before 0.26 |
| `nostrum` | `~> 0.10`, `runtime: false` | Voice mentions only; `:load` in the release |

---

## Commit Convention

Fork-only work uses **`zoo(<type>): <summary>`**:

```text
zoo(feat): add voice-channel mentions to route alerts
zoo(fix): stop one slow static lookup from killing the whole request
zoo(chore): drop the dead fleet-readiness flag
zoo(docs): document the intel-sharing config surface
```

Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`.

### Why the type sits in the scope position

This inverts the Angular format in `.gitmessage`, which is `<type>(<scope>)`. That is
deliberate. The fork's dominant recurring question is *"which commits are ours?"* — every
upstream merge, every extraction for an upstream PR, and every `git blame` into a diverged
subsystem needs that answer. Putting `zoo` first makes it a prefix match:

```bash
git log --grep '^zoo(' upstream/main..HEAD      # everything fork-only
git log --grep -v '^zoo(' upstream/main..HEAD   # candidates to send upstream
```

With `feat(zoo):` the marker is buried mid-subject and the same query needs a regex that also
matches `fix(zoo)`, `chore(zoo)`, and so on.

### When *not* to use it

**Anything intended for upstream keeps the plain Angular format** — `fix(routes): …`,
`feat(api): …`. The `zoo(` prefix is the signal that a commit is *not* upstreamable, so
applying it to a commit you plan to send upstream defeats the whole mechanism and means the
message has to be rewritten at extraction time.

If a change is partly both, split it: the upstreamable part gets a plain-format commit, the
fork-specific remainder gets `zoo(…)`.

### Everything else from `.gitmessage` still applies

100-character wrapping, imperative present tense, and a body explaining *why* rather than
restating the diff. The body is mandatory except for `docs`, and at least 20 characters when
required.

### Enforcement

None currently — the repo has no commitlint or husky config, so this is convention only. A
`commit-msg` hook rejecting subjects that match neither `^zoo\((feat|fix|chore|docs|refactor|perf|test|build|ci)\):`
nor the plain Angular pattern would enforce it, at the cost of imposing a hook on every
contributor. Not added yet.

---

## Upstream PR Recommendations

### Tier 1: Strongly Recommend

Generic bug fixes and infrastructure with no zoo coupling. Each is independently PR-able.

#### 1. Route static-data lookups can kill the caller (crash fix)

`Task.async_stream/3` was used on default options in `map_routes.ex` and `routes_by.ex`.
The default is `on_timeout: :exit`, and `async_stream` links its tasks, so a single
`CachedInfo.get_system_static_info/1` overrunning the 5s default killed the **calling**
process. For `Routes.find/5` the caller is a plain `Task.async` linked to the LiveView,
which does not trap exits — so one slow lookup remounted the user's whole map session. The
`Enum.map(fn {:ok, val} -> val end)` collector also FunctionClauseErrors on `{:exit, _}`.

**Upstream still has both sites unfixed** (`map_routes.ex:59`, `routes_by.ex:165`).
**Scope:** `cached_info.ex`, `map_routes.ex`, `routes_by.ex`, new `route_static_data.ex`, tests.
**Commit:** `03454f669` (#127).

#### 2. ESI access-token checks raise on characters with no token

`is_access_token_expired?/1` did `{:ok, %{expires_at: expires_at}} = get_character(id)` and
then arithmetic on `expires_at`. `expires_at` is nullable, and `get_character/1` answers
`{:ok, nil}` / `{:error, :not_found}` — so unauthenticated or unknown characters raised
MatchError/ArithmeticError on **every** authenticated ESI call (location, online, ship,
wallet, search), not just the corporation search where it was noticed. `time_since_expiry/1`
had the same `DateTime.from_unix!(nil)` problem.

**Scope:** `lib/wanderer_app/esi/api_client.ex` + tests. **Commit:** within `cb2b8d024` (#103).

#### 3. GarbageCollector aborts on stale records

`Ash.bulk_destroy!` raises when a concurrently-deleted row turns up, killing the whole
scheduled cleanup. The fork switches to `Ash.bulk_destroy/4` with `return_errors?: true`,
filters `Ash.Error.Changes.StaleRecord`, and logs the rest.

**Scope:** `lib/wanderer_app/map/map_garbage_collector.ex`.
**Note:** a code comment references a tuple-matching `case` that only ever existed on zoo —
reword it before submitting.

#### 4. Map duplication copies non-acceptable attributes

`copy_single_system/2` and `copy_single_connection/3` built attribute maps by
`Map.from_struct |> Map.drop(denylist)`. Any attribute added to the resource and not added to
the denylist leaks into `create`. Replaced with an allowlist derived from what the target Ash
action actually accepts.

**Scope:** `lib/wanderer_app/map/operations/duplication.ex`.

#### 5. Parallel, correctly-cached CI

Upstream runs one job doing format + compile + test + coverage + Credo + Dialyzer serially.
The fork splits it into `setup` / 4-way partitioned `tests` / `static` / `dialyzer` /
`coverage` and fixes the dependency caches. This is a straight wall-clock win for upstream.

**Scope:** `.github/workflows/test.yml`, `config/test.exs` (partition count).
**Commit:** `e815c2283` (#121).

#### 6. Charlist deprecation in two migrations

`default: '{wormholes}'` → `default: ~c"{wormholes}"` in `20260331192521` and `20260406213852`.
Identical emitted DDL; removes a deprecation warning. Two-line PR that also removes a
permanent merge-conflict point for every fork.

#### 7. IPv6-reachable route builder

`RouteBuilderClient` sets `inet6: true` (Mint keeps `inet4: true`, so IPv4 hosts still work
after one failed resolution). Makes the route builder reachable on IPv6-only internal
networks. Frame the PR as "support IPv6 route-builder hosts", not as a Fly change.

**Scope:** `lib/wanderer_app/route_builder_client.ex`, `lib/wanderer_app/esi/api_client.ex`.

#### 8. On-demand signature cleanup

Configurable, complements the existing GarbageCollector rather than replacing it.

**Scope:** `signature_cleanup.ex`, `map_signatures_event_handler.ex`, `config/config.exs`.

#### 9. `GET /api/acls/:acl_id/members/:member_id`

The ACL member API supports create/update/delete but not read. The fork adds `show` with a
full OpenApiSpex schema covering the 404/409/500 branches `with_membership/4` can produce.

**Scope:** `access_list_member_api_controller.ex`, `router.ex`. Drop the `*_v1` alias
functions — those exist only for the fork's versioned router.

#### 10. `JsonApiFormatter` payload contract

`fix(json-api): correct JsonApiFormatter payload contract against real producers` (#105)
reworked ~575 lines of `external_events/json_api_formatter.ex` against what the actual event
producers emit. This is an upstream file with upstream consumers — worth a PR, but it needs
its own before/after write-up since it changes emitted payloads.

### Tier 2: Consider with Modifications

| Feature | Blocker |
|---------|---------|
| Discord notifications | ~4,600 lines, 2 tables, a new dependency, and a Nostrum gateway. Open a design issue before writing the PR; consider splitting delivery (worker/router/embed) from voice mentions and route alerts. |
| Intel sharing | Generally useful, but needs upstream buy-in on the `intel_source_map_id` model and the `inherited_from_map_id` marker before the schema lands. |
| Fleet readiness | Generalize to a "character tags" system first. |
| Configurable label system | Needs labels to become theme-aware; discussion issue first. |
| `/health` endpoint | Trivially useful, but the router-ordering constraint and the deliberately unprotected pipeline need to be explained, not just merged. |

### Tier 3: Keep Zoo-Only

| Feature | Reason |
|---------|--------|
| Zoo theme | Highly specific to EVE wormhole gameplay |
| System ownership | Specific to tracking wormhole space occupation |
| Custom flags | Generic "store anything" field lacks structure |
| Connection loop type | Niche EVE mechanic |
| Fly.io deployment / gated deploy workflow | Deployment-target specific |

---

## Key Files Reference

### Frontend (Zoo-Specific)

```text
assets/js/hooks/Mapper/
├── components/map/
│   ├── styles/zoo-theme.scss
│   ├── labelIconMap.tsx
│   ├── constants.ts (modified)
│   └── components/
│       ├── SolarSystemNode/SolarSystemNodeZoo.tsx
│       ├── SolarSystemNode/SolarSystemNodeZoo.module.scss
│       └── ZooIcons/
├── components/mapRootContent/components/FleetReadiness/
└── types/connection.ts (ConnectionType.loop added)
```

### Backend (Zoo-Specific)

```text
lib/wanderer_app/
├── external_events/
│   ├── discord_dispatcher.ex
│   └── discord/                       # 14 modules, see Discord Notifications
├── map/
│   ├── intel_sync.ex
│   ├── signature_cleanup.ex
│   ├── route_alert/evaluator.ex
│   └── route_static_data.ex           # extracted by the routes timeout fix
├── api/
│   ├── map_system.ex (owner_*, custom_flags attributes)
│   └── map_user_settings.ex (ready_characters attribute)
└── repositories/
    ├── map_system_repo.ex (update_owner function)
    └── map_user_settings_repo.ex (ready_characters functions)

lib/wanderer_app_web/
├── controllers/health_controller.ex
└── live/map/event_handlers/
    ├── map_systems_event_handler.ex (ticker fetching)
    ├── map_signatures_event_handler.ex (cleanup_expired_signatures)
    └── map_characters_event_handler.ex (fleet readiness)
```

### Design docs

```text
docs/superpowers/
├── specs/2026-08-02-flyio-migration-design.md
├── specs/2026-08-07-deploy-approval-gate-design.md
├── specs/2026-08-07-discord-route-alerts-design.md
├── specs/2026-08-07-discord-voice-mentions-design.md
└── plans/…                            # one plan per spec
```

---

## Maintenance Notes

### Merge Conflict Hotspots

When merging upstream, watch for conflicts in:

1. `priv/repo/migrations/` — especially any upstream `FixMapsScopesDefault`; see the warning above
2. `config/runtime.exs` — the fork adds ~65 lines at the tail and rewrites the host/URL block
3. `mix.exs` — pinned `phoenix_gen_socket_client`, `gettext` floor, `nostrum`, release applications
4. `lib/wanderer_app_web/router.ex` — the `/health` scope's position
5. `lib/wanderer_app/external_events/json_api_formatter.ex` — heavily rewritten
6. `assets/…/map/constants.ts` — label and bookmark style changes
7. `lib/wanderer_app/api/map_system.ex` — attribute additions
8. `priv/resource_snapshots/` — regenerate rather than merge

### Keeping the fork current

```bash
git fetch upstream --prune

# behind / ahead, against both upstream branches -- they diverge, so check each
for ref in upstream/main upstream/develop; do
  printf '%-18s ' "$ref"
  git rev-list --left-right --count "$ref"...origin/guarzo/zoo   # behind<TAB>ahead
done
```

The first column is how many commits the fork is **behind** that ref; the second is how many
it is **ahead**. As of this document the fork is 0 behind both `upstream/main` and
`upstream/develop`.

### Testing

```bash
# Test migration idempotency
MIX_ENV=test mix ecto.reset
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix ecto.migrate  # Should not fail

# Verify configuration loads
MIX_ENV=dev iex -S mix -e "IO.inspect(Application.get_env(:wanderer_app, :signatures))"

# Build frontend
cd assets && yarn build
```
