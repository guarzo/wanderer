# Map Cleanup Systems

## Overview

The application has two signature cleanup systems that operate in parallel:

### 1. Upstream GarbageCollector (Daily Batch)

- **Location:** `lib/wanderer_app/map/map_garbage_collector.ex`
- **Schedule:** Daily via Quantum (`@daily`)
- **Thresholds:** Chain passages: 7 days, Signatures: 14 days
- **Scope:** All signatures globally
- **Configuration:** Hardcoded (not configurable)

### 2. Zoo On-Demand Cleanup (User-Triggered)

- **Location:** `lib/wanderer_app_web/live/map/event_handlers/map_signatures_event_handler.ex`
- **Trigger:** When user views or updates signatures
- **Thresholds:** Wormholes: 24h, Other: 72h (configurable)
- **Scope:** Per-system
- **Configuration:** Environment variables

## Configuration (Zoo)

```elixir
# config/config.exs (defaults); env-var overrides are applied in config/runtime.exs
config :wanderer_app, :signatures,
  wormhole_expiration_hours: 24,   # SIGNATURE_WORMHOLE_EXPIRATION_HOURS
  default_expiration_hours: 72,    # SIGNATURE_DEFAULT_EXPIRATION_HOURS
  preserve_connected: true

config :wanderer_app, :signature_cleanup,
  max_age_hours: 24
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIGNATURE_WORMHOLE_EXPIRATION_HOURS` | 24 | Hours before wormhole signatures expire (0 = never) |
| `SIGNATURE_DEFAULT_EXPIRATION_HOURS` | 72 | Hours before non-wormhole signatures expire (0 = never) |

## How They Interact

- Zoo cleanup runs first (on user interaction) with aggressive thresholds
- Upstream cleanup runs daily and catches anything zoo missed
- No conflict risk: zoo deletes before upstream ever sees the signatures
- Upstream acts as a safety net for never-accessed systems

## Cleanup Logic (Zoo)

The zoo cleanup (`WandererApp.Map.SignatureCleanup.cleanup/1`, usually invoked
asynchronously via `cleanup_async/1`) works as follows:

1. Loads all signatures for the system
2. Calculates cutoff times based on signature type:
   - Wormhole signatures: `wormhole_expiration_hours` (default 24h)
   - Other signatures: `default_expiration_hours` (default 72h)
3. Optionally preserves connected signatures (`preserve_connected: true`)
4. Deletes expired signatures and broadcasts updates

When expiration is disabled (both hour settings are 0), the per-type windows are
skipped and a single `max_age_hours` sweep runs instead as a safety net.

## Disabling Options

To disable per-type expiration: set both expiration hours to 0

```bash
SIGNATURE_WORMHOLE_EXPIRATION_HOURS=0
SIGNATURE_DEFAULT_EXPIRATION_HOURS=0
```

This does **not** disable zoo cleanup. As described above, zero on both values
switches the sweep to the single `max_age_hours` backstop (24h by default), so
signatures older than that are still deleted. `max_age_hours` has no environment
variable — to widen or effectively disable the backstop, raise it in
`config/config.exs`:

```elixir
config :wanderer_app, :signature_cleanup, max_age_hours: 87_600
```

To disable upstream cleanup: Comment out scheduler jobs in `config/runtime.exs`:

```elixir
# {"@daily", {WandererApp.Map.GarbageCollector, :cleanup_chain_passages, []}},
# {"@daily", {WandererApp.Map.GarbageCollector, :cleanup_system_signatures, []}}
```
