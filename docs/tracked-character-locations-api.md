# Tracked-character locations integrations

This feature assumes **one application process**, including the existing character tracker. The endpoint does not start tracking, call ESI, refresh credentials or write locations. It exports configured, currently permitted tracked characters and this process's latest confirmed locations.

## Enable and manage

The default is off. Set `WANDERER_MAP_INTEGRATIONS_ENABLED=true` in the existing runtime environment/config directory and restart normally. The ordinary global Public API and map subscription policies still apply. No additional EVE scopes or OAuth changes are required.

In **Maps → Settings → Public API**, map owners and current ACL administrators can create named integration tokens, list metadata, replace or revoke them. Each event rechecks permission and binds to the selected map. Plaintext is shown only immediately after successful creation/replacement; copy it to your integration's secret storage, then dismiss it. It is not recoverable from later reads or exports. Replacement invalidates the previous value immediately. Conflicting generations require refreshing the list. Revocation is permanent.

Ownership transfer and soft deletion revoke all map tokens in the same short map-row transaction as the lifecycle action. Hard deletion cascades. Restore, transfer back and duplication do not revive/copy tokens. The only new persistent data is `map_integration_tokens_v1`: private metadata plus a sensitive SHA-256 digest, never plaintext. The `wmi_v1_<UUID>_<base64url-secret>` credential cannot authorize ordinary REST, JSON:API, browser management or mutations, even alongside an owner session.

## Read

```http
GET /api/maps/{uuid-or-slug}/tracked-character-locations
Authorization: Bearer <integration-token>
Accept: application/json
X-Wanderer-Locations-Version: 1
```

The version header is optional in requests and always returned. Only one Bearer Authorization header is accepted. Cookies, sessions, query tokens, `X-API-Key` and legacy map keys do not authenticate this endpoint.

```json
{
  "data": [{
    "character_id": 90000001,
    "character_name": "Example Pilot",
    "tracked": true,
    "online": true,
    "solar_system_id": 30000142,
    "solar_system_name": "Jita",
    "display_name": "HOME",
    "map_system_visible": true,
    "location_observed_at": "2026-09-10T20:00:00.000000Z",
    "map_system_updated_at": "2026-09-10T19:30:00.000000Z"
  }],
  "observed_at": "2026-09-10T20:00:01.000000Z",
  "revision": "opaque-revision"
}
```

Records have exactly these ten keys and are sorted by numeric EVE character ID. Untracked, deleted or no-longer-permitted identities are excluded. Authorized tracked identities remain even without available location evidence.

A location is available only while a live local tracker is eligible, its persisted access-token fingerprint matches the observation, and the uncached successful upstream 200 confirmation is **less than 15 seconds old**. Existing scheduled location requests opt out of both Cachex and Req response caching when this feature is on. Stationary locations are confirmed before movement deduplication; there are no DB heartbeat writes. The existing poll cadence, online eligibility and refresh logic are unchanged. A refresh within the request can conservatively leave location unavailable until the next ordinary poll.

Unavailable records have null system ID, both names and both location/map timestamps, with `map_system_visible: false`. `online` is false if existing state establishes offline, otherwise null; a fresh eligible location is true. `observed_at` is snapshot assembly time, **not** renewed location evidence.

Fresh hidden/unmapped systems retain their numeric ID and authoritative static EVE name, if known, but never reveal map labels or map-system timestamps. Missing static names are null, never `System <id>`. Visible display precedence is temporary name → custom name → stored rename → raw name.

## Polling and errors

Poll every two seconds, sending the previous `ETag` in `If-None-Match`. The weak ETag/revision includes canonical record content, including actual confirmation timestamps and unavailable transitions, but excludes envelope `observed_at`. Every request, including a 304, reauthorizes and recomputes freshness. **304 does not renew a location's age.** Clients must use `location_observed_at`, clear stale locations locally at 15 seconds, and stop using data on authentication errors.

Success (200/304): `Cache-Control: private, no-cache, max-age=0, must-revalidate`, varying on Authorization, Accept and X-Wanderer-Locations-Version. Errors: `no-store`, no ETag, fixed `{ "error": "bounded message", "code": "machine_code" }`. 401 carries a Bearer challenge; scope/wrong-map denials carry `insufficient_scope`.

| Status | Meaning |
| --- | --- |
| 400 | Request/header/selector bounds exceeded |
| 401 | Missing, malformed, invalid, replaced or revoked token |
| 403 | Wrong map/scope, feature/API disabled, subscription required |
| 404 | Missing/deleted map |
| 406 | Unsupported media type or locations version |
| 429 | Token quota exhausted; honor Retry-After |
| 503 | Store/data service unavailable, repeated incompatible captures, malformed/oversized snapshot |

Limits: 2,000 configured tracked records (fail closed above that), 1 MiB encoded successful JSON, 2 KiB errors; names 255 Unicode codepoints/1,024 UTF-8 bytes; Authorization 512 bytes, conditional headers 1,024 bytes total, map selector 255 bytes. Overflow rejects, never truncates. In-process ExRated fixed windows allow 60 requests/minute/token and a burst of 10/second. Different consumers should have different named tokens.

OpenAPI: `GET /api/openapi` includes this dedicated Bearer security scheme and response schemas.

## Availability and rollback

The in-memory confirmation store starts empty on restart, rejects late results from old lifetimes/older requests, and retains only the freshness window. A healthy empty store returns unavailable tracked identities; a failed store returns 503. There is no history, distributed lease, HA state, readiness service or rollout adapter. If this installation ever becomes multi-process, revisit the architecture before enabling this endpoint across processes.

Before real enablement, observe stationary and moving real trackers against the fixed 15-second policy. Existing tracking/ESI delays can cause intermittent unavailable locations; do not stretch freshness to disguise them. Local verification uses fixture HTTP only and does not establish real ESI availability.

The supported feature rollback is **disabling the flag while retaining the additive token table and lifecycle hooks**. The disabled path preserves ordinary ESI cache/return behavior. Before downgrading to code that predates these hooks, revoke integration tokens: that older code cannot invalidate them when map ownership changes. Do not destructively roll back the schema or migrate/revoke existing EVE grants.
