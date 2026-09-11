# Tracked-character locations API — single-process implementation

**Status:** Replacement design approved in conversation; implement straight through with focused tests and one final review.
**Baseline:** `8d382ef6` on `feat/tracked-character-locations-api`.
**Supersedes:** the entire 16-task plan at `4d723899`, including Task 1A and its operational gates. That historical document remains in git, not as pending requirements.

## Outcome and boundaries

Add a map-scoped read-only integration token and:

```http
GET /api/maps/{map_identifier}/tracked-character-locations
Authorization: Bearer <integration-token>
Accept: application/json
```

There is **one application process**, including the existing character tracker. This is an installation fact supplied by the user, not a condition to prove with leases, advisory locks, topology attestation or routing infrastructure. Restart loses in-memory locations; existing tracking repopulates them. No request starts tracking or calls ESI.

Keep the completed namespace-rejection implementation (`503aee77`, `8d382ef6`). Do not continue any other task from the old plan.

### Explicitly out of scope

- Distributed ownership, DB advisory locks, dedicated lock connections, owner-readiness endpoints, HA or tracker reconstruction.
- OAuth callbacks, refresh-token logic, generic ESI retry behavior, credential revisions, recovery schedulers or grant migrations.
- Credential quarantine, forced reauthorization, C1/F1 releases, retired-writer fencing or deployment adapters.
- Wingman implementation, location history, SSE delivery, unrelated repairs/dependency upgrades.

## Repository evidence and the one necessary addition

- `api/map_character_settings.ex`: `tracked_by_map_all` reads configured tracking consent.
- `character/tracker.ex`: `update_location/1` runs through existing tracking; `maybe_update_location/2` writes persisted location only when it changes. There is **no trustworthy existing last-confirmed timestamp** to serialize.
- `esi/api_client.ex`: `do_get/4` can return Cachex data; `do_get_request/4` also enables Req's cache. Receiving `{:ok, location}` alone does not establish a fresh network observation.
- `web/helpers/api_utils.ex`: REST name precedence is temporary → custom → renamed stored name → original. Its synthetic `System <id>` fallback is unsuitable as an authoritative raw EVE name.
- Existing map settings and permission helpers provide the management UI and owner/ACL-admin authorization seam.

Therefore add a small in-memory confirmation record beside existing tracking. Do not invent freshness from DB update time, HTTP snapshot time or local cache receipt.

## 1. Private read-only tokens

One new private Ash resource/table: `map_integration_tokens_v1`, with its migration and generated snapshot. No JSON:API exposure or location/credential schema additions.

- Fields: UUID selector, map FK (cascade on hard delete), name (1–64 characters), fixed scope `tracked_character_locations:read`, sensitive digest, generation and revoked timestamp; ordinary timestamps.
- Wire format retained: `wmi_v1_<UUID>_<base64url-32-random-bytes>`.
- Hash using SHA-256 with domain separator `wanderer:map-integration-token:v1`, selector and secret. Compare fixed-size digests in constant time. Never store/retrieve plaintext.
- Named create/list/replace/revoke in the existing admin-gated map-settings Public API area. Reveal plaintext only after successful creation/replacement; it is not returned by later reads or put in persistent sessions/logs/exports.
- Each management event rechecks current ordinary management permission and binds its token to the selected map. The integration principal itself has no management authority.
- Replacement invalidates the old value atomically; revocation cannot reactivate. Current-generation checks resolve conflicting management edits.
- Ownership transfer and deletion revoke tokens. Use normal short map-row transactions for lifecycle serialization, shared with issuance/replacement; **not an advisory lock or an ownership service**. Duplication does not copy tokens; restoring/transferring back does not revive revoked tokens.

Dedicated endpoint authentication accepts exactly one Bearer token, verifies stored scope/revocation on every request and binds it to the path-selected map. No cookie, legacy API-key or owner-impersonation fallback. Existing namespace guards deny this credential on ordinary HTTP/mutation paths.

## 2. Current locations and honest freshness

One supervised in-memory module holds the latest successful confirmation per character: numeric system ID, UTC confirmation time, request order and a non-secret access-token fingerprint. No DB heartbeat writes or location history.

- Feed it from the **existing scheduled location request**, without another poller or changing tracking cadence/online eligibility.
- When this feature is enabled, that location request bypasses both local Cachex and Req response caches and is unconditional. Mark only a validated real upstream 200 as confirmed. No reconstruction of 304 bodies or transport-wide observation protocol is needed.
- Implement this as a location-only opt-in through the existing ESI client. Ordinary calls and the disabled-feature path retain existing cache/return behavior. Existing OAuth/refresh logic remains untouched.
- Record confirmation even when the character stays in the same system, before movement deduplication can discard it.
- Capture the in-memory store lifetime and local request order before dispatch; discard late results targeting an old store or older request. These are local ordering checks, not distributed authority.
- Bind confirmation to the request's access-token fingerprint; export only when it matches the current persisted grant. A refresh inside the request may conservatively require the next normal poll. Do not redesign refresh to avoid that brief unavailability.
- Bound retention to the freshness window; restart starts empty. Do not seed from saved character or map locations.

The snapshot reads configured tracked characters and existing permission/tracker state. Exclude untracked characters and those no longer permitted on that map. Retain authorized tracked identity with unavailable location when the tracker/grant/confirmation is absent, offline or stale. Do not require new EVE scopes or alter login flows. Existing tracking limitations remain availability limitations.

A location is fresh for **less than 15 seconds**. At/after that boundary clear its location/name fields; never extend freshness to match a slower tracker. A store failure produces a service error, not an empty roster. A healthy empty store can return tracked identities with unavailable locations. Future timestamps reject the candidate rather than being clamped.

## 3. Snapshot and HTTP contract

Preserve the external Wingman envelope and ten record keys:

```json
{
  "data": [{
    "character_id": 90000001,
    "character_name": "Example Pilot",
    "tracked": true,
    "online": true,
    "solar_system_id": 31000001,
    "solar_system_name": "J100001",
    "display_name": "HOME",
    "map_system_visible": true,
    "location_observed_at": "2026-09-10T20:00:00.000000Z",
    "map_system_updated_at": "2026-09-10T19:30:00.000000Z"
  }],
  "observed_at": "2026-09-10T20:00:01.000000Z",
  "revision": "opaque-revision"
}
```

- EVE character IDs are integers, not Wanderer UUIDs; sort ascending and reject malformed identities.
- Unavailable location has null system/name/location-time/map-system-time fields and `map_system_visible: false`. `online` is false when existing state establishes offline, otherwise null when unavailable; a fresh eligible confirmation is true. Do not invent a new online-evidence subsystem.
- Fresh hidden/unmapped systems retain numeric ID and authoritative raw EVE name, with null display/map-system time and false visibility.
- Visible names use temporary → custom → stored rename → raw precedence. Missing static data gives null raw name, never a synthetic name. Preserve legacy serializers' behavior when sharing their helper.
- Bulk-read roster, current authorization and map systems; avoid one DB lookup per character per poll. Capture local observations once. Recheck token and relevant authorization before sending; retry snapshot assembly once on detected change, then fail rather than mix incompatible captures.
- Conditional two-second polling: weak ETag from version/map and canonical record content, including real confirmation timestamps and unavailable transitions. Exclude envelope `observed_at`. Reauthorize/recompute freshness before every 304; 304 never refreshes location age.
- Version header `X-Wanderer-Locations-Version: 1`; optional request version defaults to1. Unsupported media/version gets406.
- Successful cache policy: `private, no-cache, max-age=0, must-revalidate`, vary on Authorization/Accept/version. Errors use no-store, no ETag, fixed bounded error/code JSON; auth failures include a Bearer challenge. Never include exceptions or credentials.
- Preserve useful distinctions: missing/malformed/invalid token (401), scope/wrong-map/disabled/subscription denial (403), missing map (404), temporary service failure (503), request limit (429). There are no distributed-authority errors in this design.
- Bounds: 2,000 records, 1 MiB successful JSON, 2 KiB errors, names255 codepoints/1,024 UTF-8 bytes, Authorization512 bytes, conditional header1,024 bytes, selector255 bytes. Reject overflow, never silently truncate.
- Endpoint rate limit:60 requests/minute/token with burst10, using existing in-process rate-limit facilities; no distributed quota service.

## 4. Deployment and compatibility

One default-off flag: `WANDERER_MAP_INTEGRATIONS_ENABLED`, configured in runtime.exs and exposed through Env. Existing global API/subscription policy still applies. No additional topology mode or probe.

The endpoint reflects this application's tracker state. Existing deployment routes requests to this single application. No routing code, cluster tests or operational attestation. If the deployment ever becomes multi-process, revisit this documented assumption instead of pretending this cache is distributed.

The only new persistent data is integration tokens. Disabling the feature leaves their table and lifecycle hooks intact and ordinary API/OAuth behavior unchanged. No existing grants are migrated/revoked. Supported feature rollback disables the flag, not the schema. Before downgrading to code that predates token lifecycle hooks, revoke integration tokens; old code cannot invalidate them on map ownership changes. No compatibility-release machinery or destructive schema rollback.

## Four implementation tasks — no intermediate review gates

1. **Tokens and management:** private resource, generated migration/snapshot, lifecycle service/actions, existing-settings UI, retain/test namespace boundary.
2. **Tracker confirmation:** small supervised in-memory record and location-only uncached opt-in; test no-movement confirmation, cache exclusion, expiry, restart/late responses and unavailable states.
3. **Snapshot endpoint:** roster/permission/name join, dedicated token authentication, exact response/error/ETag behavior, limits and OpenAPI/operator documentation.
4. **Verification and finish:** focused integration tests, existing auth/name regressions, schema/codegen checks, modest polling exercise, formatter and changed-code lint; one independent final security/correctness review, fix concrete defects, commit and report actual evidence.

Use test-first implementation. Execute continuously; do not ask for approval between these tasks. Do not reopen architecture review over unrelated existing defects or library internals. Ask only for genuinely consequential new scope/security decisions.

## Verification and acceptance

- Actual issued token reads only its map's endpoint; revoked/replaced/wrong-map/legacy/alternative-transport credentials behave correctly. Keep actual mutation-denial controls and ordinary-session positives.
- Tracked/untracked, allowed/denied, fresh/stale/offline/absent, unchanged system, restart, late response, hidden/unmapped and name precedence.
- HTTP boundary fixture proves timestamps come from uncached successful location requests, not cache replay; no GET-triggered ESI or credential writes.
- Exact JSON keys/types, 200/304/expiry transitions and bounded error contracts.
- Modest repeatable polling test:10 independent clients, two-second polling,60seconds, seeded local/HTTP-boundary fixtures; verify stable responses, bounded queries and no upstream calls from snapshot GET. This is a smoke/load check, not a performance certification program.
- Preserve existing tests. Known baseline:14 original failures; latest13 were all within that set. Track them without skipping or repairing unrelated code.
- Before enabling for actual users, observe stationary and moving real trackers against the fixed15-second policy. If cadence is insufficient, report intermittent unavailable data; do not fabricate freshness or expand this feature into OAuth/tracker infrastructure. Live credentials are not required for local implementation tests.

The external Wingman design remains unchanged. Single-process topology and conservative unavailable handling supersede only the old infrastructure-heavy implementation choices.
