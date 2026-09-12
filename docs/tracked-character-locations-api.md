# Tracked-character locations integrations

This feature assumes **one application process**, including the existing character tracker. The endpoint does not start tracking, call ESI, refresh credentials or write locations. It exports configured, currently permitted tracked characters and this process's latest confirmed locations.

## Enable and manage

The default is off. Set `WANDERER_MAP_INTEGRATIONS_ENABLED=true` in the existing runtime environment/config directory and restart normally. The ordinary global Public API and map subscription policies still apply. No additional EVE scopes or OAuth changes are required.

Open the existing **Map user settings** dialog inside a map. An administrator opts that map in under **Admin Settings**; its new `location_api_enabled` flag defaults to false. Every eligible user, including viewers, then manages their own token under **Location API**. There is one active token per user+map: Generate is idempotent, reopening retrieves the same token, Regenerate explicitly replaces its value, and Revoke permanently invalidates it. Regenerate and Revoke reject stale commands without affecting other users. If a stored credential cannot be decrypted or verified, retrieval reports it as unreadable and returns only its non-secret identifier and generation, so the owner can deliberately regenerate or revoke it; reads never rotate a credential on their own. A revoked credential never revives; later generation creates a new row. Administrators cannot retrieve another user's token.

Every operation uses the socket's user and map identity and fresh database permissions, not cached UI grants. Read eligibility is Wanderer's combined active-character ACL predicate followed by the ordinary map-owner override, requiring both `view_system` and `view_character`. This is independent of which tracked characters may be disclosed in the response. ACL ownership alone does not grant access. EVE corporation/alliance changes follow Wanderer's existing affiliation-refresh timing; this feature does not poll ESI or refresh OAuth/membership itself.

Map opt-out and global feature/API disable are **temporary kill switches**: they hide tokens and stop issuance/use without forcing every member to reconfigure. Genuine access loss still permanently revokes tokens while disabled. Soft deletion permanently revokes all map tokens; hard deletion cascades. Owner transfer and permission changes revoke only users who lose access, preserving still-eligible viewers and remaining alt grants. Restore, transfer back, and map duplication never revive or copy revoked credentials.

The private `map_integration_tokens_v1` resource stores the owning user, map, sensitive SHA-256 digest, and sensitive encrypted binary. Encryption uses the existing `WandererApp.Vault` and its existing key configuration. Plaintext never enters Ash changesets or default resource reads; only the authorized personal reply decrypts it, and checks the decrypted selector/digest before returning it. Keep the existing Vault keys secure and available: a decryption failure returns a bounded service error, never auto-rotates. Tokens are not stored in generic map/user settings, exports, socket assigns, or PubSub. The `wmi_v1_<UUID>_<base64url-secret>` namespace remains unusable on ordinary REST, JSON:API, browser management, or mutation endpoints, even alongside an owner session.

The new forward migration invalidates old map-only hash credentials once, preserving rows and historical digests. It adds the opt-in field, ciphertext/user fields, user FK, active user+map unique index, and an active-row ownership/ciphertext constraint. Previously applied migrations and snapshots remain unchanged. Existing integrations must opt in and generate a personal credential after upgrading.

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

A location is available only while a live local tracker is eligible, its persisted access-token fingerprint matches the observation, and the uncached successful upstream 200 confirmation is **less than 15 seconds old**. Existing scheduled location requests opt out of both Cachex and Req response caching only when this feature is on and one of the character's active maps is opted in and has a non-revoked personal token with the locations scope. Missing tokens or token-query failures preserve ordinary cached tracking. Stationary locations are confirmed before movement deduplication; there are no DB heartbeat writes. The existing poll cadence, online eligibility and refresh logic are unchanged. A refresh within the request can conservatively leave location unavailable until the next ordinary poll.

Unavailable records have null system ID, both names and both location/map timestamps, with `map_system_visible: false`. `online` is false if existing state establishes offline, otherwise null; a fresh eligible location is true. `observed_at` is snapshot assembly time, **not** renewed location evidence.

Fresh hidden/unmapped systems retain their numeric ID and authoritative static EVE name, if known, but never reveal map labels or map-system timestamps. Missing static names are null, never `System <id>`. Visible display precedence is temporary name → custom name → stored rename → raw name.

## Polling and errors

Poll every two seconds, sending the previous `ETag` in `If-None-Match`. The weak ETag/revision includes canonical record content, including actual confirmation timestamps and unavailable transitions, but excludes envelope `observed_at`. Every request, including a 304, reauthorizes and recomputes freshness. **304 does not renew a location's age.** Clients must use `location_observed_at`, clear stale locations locally at 15 seconds, and stop using data on authentication errors.

Success (200/304): `Cache-Control: private, no-cache, max-age=0, must-revalidate`, varying on Authorization, Accept and X-Wanderer-Locations-Version. Errors: `no-store`, no ETag, fixed `{ "error": "bounded message", "code": "machine_code" }`. 401 carries a Bearer challenge; scope/wrong-map denials carry `insufficient_scope`.

| Status | Meaning |
| --- | --- |
| 400 | Request/header/selector bounds exceeded |
| 401 | Missing, malformed, invalid, replaced or revoked token |
| 403 | Wrong map/scope, token-owner access loss, map/global/API disabled, subscription required |
| 404 | Missing/deleted map |
| 406 | Unsupported media type or locations version |
| 429 | Token quota exhausted; honor Retry-After |
| 503 | Store/data service unavailable, repeated incompatible captures, malformed/oversized snapshot |

Limits: 2,000 configured tracked records (fail closed above that), 1 MiB encoded successful JSON, 2 KiB errors; names 255 Unicode codepoints/1,024 UTF-8 bytes; Authorization 512 bytes, conditional headers 1,024 bytes total, map selector 255 bytes. Overflow rejects, never truncates. In-process ExRated fixed windows allow 60 requests/minute/token and a burst of 10/second. Different users have their own tokens; clients sharing one user's token also share its quota. Cheap digest authentication precedes quota checks. Fresh user/map authorization occurs after quota and again before returning either 200 or 304. Temporary service failures fail closed without revoking valid users.

OpenAPI: `GET /api/openapi` includes this dedicated Bearer security scheme and response schemas.

## Availability and rollback

The in-memory confirmation store starts empty on restart and rejects late results from old lifetimes/older requests. Confirmed locations retain only the 15-second freshness window; in-flight request tickets have a separate three-minute budget for the existing HTTP timeouts and one authentication retry. A healthy empty store returns unavailable tracked identities; a failed store returns 503. There is no history, distributed lease, HA state, readiness service or rollout adapter. If this installation ever becomes multi-process, revisit the architecture before enabling this endpoint across processes.

Before real enablement, observe stationary and moving real trackers against the fixed 15-second policy. Existing tracking/ESI delays can cause intermittent unavailable locations; do not stretch freshness to disguise them. Local verification uses fixture HTTP only and does not establish real ESI availability.

The supported feature rollback is **disabling the flag while retaining the additive token table and lifecycle hooks**. The disabled path preserves ordinary ESI cache/return behavior. Before downgrading to a version without user-bound token authorization, including the earlier map-only token version, revoke all integration tokens: that code cannot enforce personal membership revocation. Do not destructively roll back the schema or migrate/revoke existing EVE grants.

## Transaction boundaries and limits

Resource-level hooks cover ACL member creation/role/identity changes/deletion, standalone map ACL joins, ACL deletion cascades, map ACL replacement/ownership/deletion, and relevant character linking/reassignment/deletion/affiliation changes. They capture affected maps, lock their rows, execute the resource action, and revalidate existing token owners **inside the same transaction**. A revocation failure aborts the permission mutation. Parent ACL replacements are evaluated after their managed relationships finish, not on temporary detachments. Atomic bulk shortcuts are not supported for these changes; callers must use ordinary actions or streaming fallback.

This is not globally linearizable historical revocation. In particular, a concurrent first token issuance can race character-change affected-map discovery, and a concurrent new ACL attachment can race an ACL mutation's map discovery. Because affected-map discovery derives its maps from the tokens that already exist, a user holding no token yet is not covered by the mutation's map locks, so a token inserted inside that window can survive the permission change as an active row. Such a row is not usable: every data request re-authorizes against current permissions and permanently revokes the credential on the first denied use. The residual gap is therefore a delayed revocation record, not retained access. Multiple competing resource mutations can also contend or deadlock on row locks; PostgreSQL aborts the transaction rather than partially committing revocation. Fresh HTTP reads deny currently absent access, and persisted revoked rows never revive, but these checks cannot prove every historical removal across arbitrary concurrent transactions. Existing EVE-side affiliation refresh delays still apply. An access change immediately after the final authorization read may also race response delivery; there is no distributed permission coordinator or response-spanning lock.

The ten-client smoke uses ten different users with personal tokens on one opted-in map, 20 tracked records and 300 requests over 60 seconds. Measured authorization overhead is approximately 27 SQL queries/request; the regression ceiling is 9,000 total queries with zero snapshot-triggered ESI calls or writes. This is a fixture bound, not a production capacity guarantee.
