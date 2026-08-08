# Zoo Fork Documentation

**Branch:** `guarzo/zoo`
**Last Updated:** 2025-11-30

This document describes the zoo fork's extensions to upstream Wanderer, including database schema changes, frontend themes, and features suitable for upstream contribution.

---

## Table of Contents

1. [Overview](#overview)
2. [Database Schema Extensions](#database-schema-extensions)
3. [Theme System](#theme-system)
4. [Label System](#label-system)
5. [Signature Cleanup](#signature-cleanup)
6. [Fleet Readiness](#fleet-readiness)
7. [Upstream PR Recommendations](#upstream-pr-recommendations)

---

## Overview

The zoo fork adds EVE Online wormhole-specific features to Wanderer:

| Feature | Purpose | Zoo-Only? |
|---------|---------|-----------|
| Zoo Theme | Custom visual styling for wormhole mapping | Yes |
| Label Semantics | EVE-specific label meanings (EOL, Crit, etc.) | Yes |
| System Ownership | Track corp/alliance ownership of systems | Yes |
| Fleet Readiness | Mark characters ready for fleet operations | Yes |
| On-Demand Signature Cleanup | Configurable automatic signature expiration | No (PR candidate) |
| Connection Loop Type | Self-connecting wormhole support | Yes |

---

## Database Schema Extensions

The zoo fork adds 5 columns across 2 tables:

### map_system_v1

| Column | Type | Purpose | Migration |
|--------|------|---------|-----------|
| `custom_flags` | text | Arbitrary flags for zoo features | `20250122214138` |
| `owner_id` | text | Corporation or Alliance EVE ID | `20250204223853` |
| `owner_type` | text | Entity type: 'corp' or 'alliance' | `20250204223853` |
| `owner_ticker` | text | Display ticker [TICKER] | `20250307165740` |

### map_user_settings_v1

| Column | Type | Purpose | Migration |
|--------|------|---------|-----------|
| `ready_characters` | text[] | Character EVE IDs marked as fleet-ready | `20250625024813` |

### Migration Files

```
priv/repo/migrations/
├── 20250122214138_add_zoo_flags.exs
├── 20250204223853_add_system_owners.exs
├── 20250307165740_add_owner_ticker.exs
└── 20250625024813_add_fleet_readiness_ready_characters.exs
```

### Rollback SQL (if needed)

```sql
-- Remove zoo columns from map_system_v1
ALTER TABLE map_system_v1 DROP COLUMN IF EXISTS custom_flags;
ALTER TABLE map_system_v1 DROP COLUMN IF EXISTS owner_id;
ALTER TABLE map_system_v1 DROP COLUMN IF EXISTS owner_type;
ALTER TABLE map_system_v1 DROP COLUMN IF EXISTS owner_ticker;

-- Remove zoo columns from map_user_settings_v1
ALTER TABLE map_user_settings_v1 DROP COLUMN IF EXISTS ready_characters;
```

---

## Theme System

Zoo adds a `zoo` theme alongside `default` and `pathfinder`.

### Key Files

| File | Purpose |
|------|---------|
| `assets/js/hooks/Mapper/components/map/styles/zoo-theme.scss` | Zoo theme styles |
| `assets/js/hooks/Mapper/components/map/components/SolarSystemNode/SolarSystemNodeZoo.tsx` | Zoo node component |
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

The zoo fork repurposes upstream's generic labels (A/B/C/1/2/3) with EVE Online wormhole-specific meanings.

### Label Mappings

| Key | Upstream | Zoo Meaning | Icon | Use Case |
|-----|----------|-------------|------|----------|
| `la`/`de` | Label A | Dead End | Block | System with no exit wormholes |
| `lb`/`gas` | Label B | Gas Site | Industry | System has harvestable gas sites |
| `lc`/`eol` | Label C | End of Life | Hourglass | Wormhole about to collapse (<4h) |
| `l1`/`crit` | Label 1 | Critical Mass | Fire | Wormhole at mass verge |
| `l2`/`structure` | Label 2 | Structure | Warning | System has attackable structure |
| `l3`/`steve` | Label 3 | Steve/Danger | Skull | High danger (historic name) |

### Storage

Labels are stored in the database using the original upstream keys (`la`, `lb`, etc.) but displayed with zoo-specific names and icons when the zoo theme is active.

### Files

- **Definition:** `assets/js/hooks/Mapper/components/map/labelIconMap.tsx`
- **Styles:** `assets/js/hooks/Mapper/components/map/constants.ts` (MARKER_BOOKMARK_BG_STYLES)
- **CSS:** `assets/js/hooks/Mapper/components/map/styles/zoo-theme.scss`

---

## Signature Cleanup

Zoo implements on-demand signature cleanup in addition to upstream's daily batch cleanup.

### Comparison

| Aspect | Upstream GarbageCollector | Zoo On-Demand Cleanup |
|--------|---------------------------|----------------------|
| **Location** | `map_garbage_collector.ex` | `map_signatures_event_handler.ex` |
| **Trigger** | Daily via Quantum scheduler | When user views/updates signatures |
| **Scope** | All signatures globally | Per-system |
| **Wormhole Expiration** | 14 days (hardcoded) | 24 hours (configurable) |
| **Other Signatures** | 14 days (hardcoded) | 72 hours (configurable) |
| **Preserve Connected** | No | Yes (configurable) |

### Configuration

```elixir
# config/config.exs
config :wanderer_app, :signatures,
  wormhole_expiration_hours: 24,   # env: SIGNATURE_WORMHOLE_EXPIRATION_HOURS
  default_expiration_hours: 72,    # env: SIGNATURE_DEFAULT_EXPIRATION_HOURS
  preserve_connected: true

config :wanderer_app, :signature_cleanup,
  max_age_hours: 24
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIGNATURE_WORMHOLE_EXPIRATION_HOURS` | 24 | Hours until wormhole signatures expire |
| `SIGNATURE_DEFAULT_EXPIRATION_HOURS` | 72 | Hours until non-wormhole signatures expire |

Set to `0` to disable automatic cleanup for that signature type.

### How They Interact

1. Zoo cleanup runs first (on user interaction) with aggressive thresholds
2. Upstream cleanup runs daily as a safety net
3. No conflict: zoo deletes before upstream sees the signatures
4. Upstream catches signatures in never-accessed systems

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

---

## Upstream PR Recommendations

### Tier 1: Strongly Recommend

These features are well-implemented, low-risk, and provide universal value:

#### 1. On-Demand Signature Cleanup

**Why:** All Wanderer users deal with signature clutter. This is configurable, disabled by default, and complements the existing GarbageCollector.

**Scope:**
- `map_signatures_event_handler.ex` (cleanup_expired_signatures/1 function)
- `config/config.exs` (signature cleanup configuration)
- ~80 lines of code, no breaking changes

**Suggested PR Title:** "feat: Add configurable on-demand signature cleanup"

#### 2. Corporation/Alliance Ticker Fetching

**Why:** Generic utility that any feature showing corp/alliance info could use. Minimal footprint, uses existing ESI infrastructure.

**Scope:**
- `map_systems_event_handler.ex` (get_corporation_ticker, get_alliance_ticker handlers)
- ~30 lines of code, no breaking changes

**Suggested PR Title:** "feat: Add corporation/alliance ticker lookup via UI events"

#### 3. Idempotent Migration Pattern

**Why:** Best practice documentation. Migrations should be safe to re-run.

**Scope:** Documentation PR only

**Pattern:**
```elixir
def up do
  execute("ALTER TABLE table_name ADD COLUMN IF NOT EXISTS col text")
end

def down do
  execute("ALTER TABLE table_name DROP COLUMN IF EXISTS col")
end
```

### Tier 2: Consider with Modifications

#### Configurable Label System

The pattern of theme-configurable labels is valuable, but requires refactoring to make labels theme-aware. Better suited for discussion issue first.

#### Fleet Readiness / Character Tagging

Could be generalized to a "character tags" system. Requires significant refactoring.

### Tier 3: Keep Zoo-Only

| Feature | Reason |
|---------|--------|
| Zoo Theme | Highly specific to EVE wormhole gameplay |
| System Ownership | Specific to tracking wormhole space occupation |
| Custom Flags | Generic "store anything" field lacks structure |
| Connection Loop Type | Niche EVE mechanic |

---

## Key Files Reference

### Frontend (Zoo-Specific)

```
assets/js/hooks/Mapper/
├── components/map/
│   ├── styles/zoo-theme.scss
│   ├── labelIconMap.tsx
│   ├── constants.ts (modified)
│   └── components/
│       ├── SolarSystemNode/SolarSystemNodeZoo.tsx
│       └── ZooIcons/
├── components/mapRootContent/components/FleetReadiness/
└── types/connection.ts (ConnectionType.loop added)
```

### Backend (Zoo-Specific)

```
lib/wanderer_app/
├── api/
│   ├── map_system.ex (owner_*, custom_flags attributes)
│   └── map_user_settings.ex (ready_characters attribute)
└── repositories/
    ├── map_system_repo.ex (update_owner function)
    └── map_user_settings_repo.ex (ready_characters functions)

lib/wanderer_app_web/live/map/event_handlers/
├── map_systems_event_handler.ex (ticker fetching)
├── map_signatures_event_handler.ex (cleanup_expired_signatures)
└── map_characters_event_handler.ex (fleet readiness)
```

### Migrations

```
priv/repo/migrations/
├── 20250122214138_add_zoo_flags.exs
├── 20250204223853_add_system_owners.exs
├── 20250307165740_add_owner_ticker.exs
└── 20250625024813_add_fleet_readiness_ready_characters.exs
```

### Configuration

```
config/config.exs (signature cleanup configuration, lines 149-159)
```

---

## Maintenance Notes

### Merge Conflict Hotspots

When merging upstream, watch for conflicts in:

1. `constants.ts` - Label and bookmark style changes
2. `map_system.ex` - Attribute additions
3. `config/config.exs` - Configuration additions

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
