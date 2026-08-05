# Migrating self-hosted Wanderer from docker-compose to Fly.io

Date: 2026-08-02
Revised: 2026-08-04 — wanderer-kills brought into scope
Status: Design approved, not yet implemented

## Goal

Move a self-hosted Wanderer instance off a single VM running docker-compose
(wanderer + postgres + wanderer-kills + wanderer-notifier + caddy) onto Fly.io.

Drivers, in the operator's own priority: less ops burden, easier recovery from
bad deploys, and a better deploy workflow. Cost is explicitly not a driver.

## Scope

In scope: the `wanderer` app, its Postgres database, and `wanderer-kills`.

Also in scope: **an operator-facing deployment guide**, covering both a fresh Fly
install and the migration path, so other operators can reproduce this rather
than rediscovering it. It goes to `wanderer-industries/community-edition` — the
self-hosting repository this repo's README already points at — as a `fly-io/`
directory alongside the existing `reverse-proxy/` and `scripts/` topics, not
into this repository's `docs/`. The Fly-specific wanderer-kills material is
offered upstream for the same reason.

wanderer-kills is in scope because it is a hard dependency for the operator's
users — without it the map shows no kill data. Note the distinction that shapes
the plan below: it is a hard *product* dependency but a soft *runtime* one. The
websocket client degrades rather than crashing, which is what makes flexible
cutover ordering possible.

Out of scope, deliberately:

- Migrating wanderer-notifier. It becomes a sibling Fly app, but its migration
  is separate work. This design fixes only the interface contract.
- PromEx / Grafana metrics.
- Multi-region, multi-machine, or HA Postgres.
- Any behavioural change to the application.

## Repository evidence

Findings from inspecting the checkout, which constrain the design.

### Wanderer and its database

- `fly.toml` already exists (app `wanderer-test`, region `ams`), so a Fly path
  was started upstream but is not production-shaped.
- `config/runtime.exs` is already Fly-aware: it reads `FLY_APP_NAME` (line 16),
  and supports `DATABASE_URL`, `DATABASE_SSL_ENABLED`, and `ECTO_IPV6`.
- Map state is held in node-local Cachex tables; character trackers register in
  a node-local `Registry` (`WandererApp.Character.TrackerRegistry`); PubSub uses
  the PG2 adapter with no clustering configured. **The app is single-node.**
- `WandererApp.ConfigHelpers.get_var_from_path_or_env/3` falls back to
  `System.get_env` when `CONFIG_DIR` (default `/run/secrets`) is absent, so
  `fly secrets` work for every setting with no shimming.
- `rel/overlays/bin/migrate.sh` runs `WandererApp.Release.interweave_migrate`
  (`lib/wanderer_app/release.ex:72`), the correct Ash migration entry point. The
  existing `release_command` is sound.
- `WandererApp.Repo.installed_extensions/0` (`lib/wanderer_app/repo.ex:5-8`)
  returns only `["ash-functions"]` and no migration issues `CREATE EXTENSION`.
  There is no native-extension risk in the dump/restore.
  `min_pg_version/0` (`repo.ex:11-13`) requires PostgreSQL >= 15.
- The "Health Check Endpoints" scope at `lib/wanderer_app_web/router.ex:377-379`
  is empty. There is no health route.

### wanderer-kills

- It lives in a **separate upstream repository**
  (`wanderer-industries/wanderer-kills`), not in this one. There is no
  docker-compose file here and no build for it.
- **It is stateless.** Its `mix.exs` declares no `ecto`, `ecto_sql`, `postgrex`,
  or `redix` — storage is `cachex` in memory only. Its `docker-compose.yml`
  declares no volumes and no sidecar services. There is therefore no database to
  provision and nothing to dump or restore; it rebuilds from zKillboard and ESI
  on boot.
- It listens on a single port, **4004**, and already exposes `/health`.
- **It binds IPv4-only.** Upstream `config/config.exs` sets
  `http: [port: 4004, ip: {0, 0, 0, 0}]`, and upstream `config/runtime.exs`
  overrides only the port — there is no `ip:` key and no bind-address
  environment variable anywhere in it. Fly's 6PN `.internal` addresses are IPv6,
  and Fly requires the server to listen on the 6PN address (or on `::`) to
  receive them. **A client-side `:inet6` fix alone would therefore connect to an
  address with no listener.** See blocking change 3.
- No published container image exists; it builds from source.
- Wanderer reaches it over a websocket (`WandererApp.Kills.Client`) at
  `WANDERER_KILLS_BASE_URL`, defaulting to `ws://wanderer-kills:4004`
  (`config/runtime.exs:72-74`).
- `WANDERER_KILLS_SERVICE_ENABLED` defaults to **`"false"`**
  (`runtime.exs:67-70`). When false, neither `WandererApp.Kills.Supervisor` nor
  `WandererApp.Map.ZkbDataFetcher` starts at all
  (`lib/wanderer_app/application.ex:226-238`).
- **The dependency is one-directional.** Wanderer subscribes to kills and tells
  it which systems to watch; kills never calls back into wanderer. This is what
  allows the kills app to be deployed and warmed ahead of the cutover window.
- The client reconnects with exponential backoff (1s to a 60s ceiling, ~30%
  jitter) but `@max_retries 10` then **stops retrying automatically**, falling
  back to a 15-minute health-check cycle (`kills/client.ex:19-30`).

### The websocket transport cannot currently reach a Fly private address

This is the finding behind blocking change 2. Note it is necessary but not
sufficient on its own — blocking change 3 covers the server side. Traced through
three files:

1. `lib/wanderer_app/kills/client.ex:487-498` passes
   `transport_opts: [timeout:, tcp_opts: [...]]`.
2. `deps/phoenix_gen_socket_client/lib/gen_socket_client/transport/web_socket_client.ex:18`
   defines `@websocket_client_opts [:extra_headers, :ssl_verify]`. Line 30
   splits on **exactly those two keys**; everything else falls through into
   `transport_options`, which line 34 passes as the *handler state* argument —
   not as socket options.
3. `deps/websocket_client/src/websocket_client.erl:195` reads
   `socket_opts` from its options to build the transport. That is the key that
   would work, and it is precisely the key being filtered out at step 2.

Two consequences:

- The existing `connect_timeout`, `send_timeout`, and `recv_timeout` values are
  **already dead config today**. This is a pre-existing latent bug, independent
  of Fly.
- There is **no supported path to pass `:inet6`**. Fly's `.internal` 6PN
  addresses are IPv6-only, so `ws://wanderer-kills.internal:4004` would fail to
  resolve. Erlang's `gen_tcp` defaults to the `inet` (IPv4) family for hostname
  resolution.

## Decisions

### Postgres: Fly Managed Postgres in `iad`

Considered: Fly Managed Postgres, Supabase (already in use by the operator), and
an unmanaged `fly pg` app.

Chosen Fly MPG, co-located with the app in `iad`. Wanderer is chatty with the
database — tracker pools writing character locations every 10-30s, audit rows,
signature and connection updates — so per-query latency multiplies. MPG sits on
the same private network, and managed backups serve the "less ops burden" goal.

Supabase was a genuine contender since the operator already runs it, but it adds
a public-internet hop on every query, and its transaction-mode pooler requires
`prepare: :unnamed` in the Repo config, which `runtime.exs` has no option for
today — i.e. it would force a code change that MPG does not.

An unmanaged `fly pg` app was rejected: it keeps the operator as DBA, which
contradicts the primary driver.

### Exactly one machine, for both apps

`auto_stop_machines = off`, `min_machines_running = 1`, no autoscaling, and
`DNS_CLUSTER_QUERY` left unset.

For wanderer this is a hard constraint from the architecture, not a preference.
With node-local caches and registries and no clustering, two machines produce
two independent halves of the same map: trackers updating on one node, LiveView
sessions subscribed on the other, and updates that never meet.

The same applies to wanderer-kills for the same underlying reason — its cache is
node-local Cachex, so two machines would serve different answers depending on
which one a subscription landed on. Additionally, `auto_stop_machines` must be
off because a stopped machine drops the websocket.

Both fly.toml files carry a comment saying so.

Consequence: every wanderer deploy is a restart with a user-visible gap of
roughly 30-60s. This is acceptable — map servers rehydrate from Postgres and
LiveView clients reconnect — but it means recovery is "redeploy the previous
release", not a blue/green swap.

### wanderer-kills: private-only, no public IP

The kills app gets **no public IP address**. It is reachable only over 6PN at
`wanderer-kills.internal:4004`.

Plain `ws://` is correct here and no certificate work is needed: 6PN is a
WireGuard mesh, encrypted at the network layer. Operator access for debugging is
via `fly ssh console` and `fly proxy`.

Health checks run against its existing `/health` endpoint.

### wanderer-kills: configuration upstreamed, not forked

The `fly.toml` and the `BIND_IP` patch go upstream rather than being maintained
as a permanent divergence. This avoids carrying a second fork and rebasing it
indefinitely.

Mechanically this is a pull request from the existing `guarzo/wanderer-kills`
fork, not a direct push: `gh` reports read access on
`wanderer-industries/wanderer-kills` for the operator's current token. A fork
used purely as a PR staging area is not a maintained fork, so the decision is
unchanged — only the plumbing is. If the operator does in fact hold write access
(the token may simply be scoped narrowly, or the permission may come through a
team that the API does not surface here), a direct branch works equally well and
the pull request steps still apply.

Consequence: the upstreamed `fly.toml` must be **operator-agnostic**. It cannot
hard-code an app name; `app` is overridden at deploy time.

The same reasoning applies to the transport fix in *this* repository. It is a
strict improvement for any IPv6-only or Fly deployment and is not zoo-specific,
so it should go upstream rather than living in `guarzo/zoo`.

The deployment guide reaches `wanderer-industries/community-edition` the same
way, via `guarzo/community-edition`.

### Cutover ordering: both services in the same window

Considered: kills first as a low-risk rehearsal; both together; kills after the
wanderer cutover (the original plan before kills was in scope).

Chosen: **both in the same window**. The private 6PN link is therefore live from
day one, with no temporary public exposure of the kills service, and Phase 1
staging validates the exact production topology rather than an interim one.

The tradeoff accepted: this stacks a previously-unexercised build and deploy
path on top of the database cutover, and it makes the transport fix blocking for
cutover rather than deferrable.

That tradeoff is substantially mitigated by the one-directional dependency.
**The kills app can be deployed and left running to warm its cache hours before
the window opens**, because nothing consumes it until wanderer points at it. The
"same window" constraint applies only to the traffic switch, not to the deploy,
so this costs the outage window almost nothing.

### Sizing

Wanderer: `shared-cpu-2x`, 2 GB RAM, existing `swap_size_mb = 512`. Sized for a
private-corp instance with headroom; `fly scale vm` covers growth.

wanderer-kills: start at 2 GB. **This figure is a starting point, not a measured
one.** The service ingests EVE-wide killmails from RedisQ with a 24-hour TTL
(`lib/wanderer_app/kills/config.ex:38-40`), and the resident set could plausibly range
from a few hundred MB to over 1 GB. Phase 0 includes a measurement step.

## Target architecture

```
                 ┌────────────────────────────┐
   users ──TLS──►│ Fly edge (Anycast + cert)  │
                 └─────────────┬──────────────┘
                               │ :8080
   ┌───────────────────────────▼──────────────────────────┐
   │ app: wanderer  (iad)                                  │
   │ EXACTLY ONE machine — shared-cpu-2x, 2 GB, swap 512   │
   │ auto_stop_machines = off, min_machines_running = 1    │
   └───┬────────────────────┬─────────────────────┬────────┘
       │ 6PN ws://          │ public wss/https    │ DATABASE_URL (6PN)
       ▼                    ▼                     ▼
 ┌──────────────────────┐  wanderer-notifier   Fly Managed Postgres (iad)
 │ app: wanderer-kills  │  (still on the VM,     PostgreSQL >= 15
 │ (iad) NO PUBLIC IP   │   out of scope)
 │ ONE machine, 4004    │
 │ stateless — no DB    │
 └──────────────────────┘
```

The kills link above assumes Option A (direct 6PN). Under Option B it is
`ws://<app>.flycast:4004` through the Fly proxy instead; either way it is
private, IPv6, and carries no public IP.

Retired: Caddy, the VM's docker-compose wanderer and wanderer-kills containers,
and the host Postgres. The `WEB_EXTERNAL_SCHEME` / `HTTPS_PORT` / `/certs/*` branch
in `config/runtime.exs:429-443` becomes dead config on Fly but is left in place,
as it is upstream-shared code.

## Code changes required

### Blocking

1. **Custom domain support in `config/runtime.exs`.** Lines 16-38 currently
   hard-code `https://<FLY_APP_NAME>.fly.dev` whenever `FLY_APP_NAME` is set —
   which is always, on Fly — making `WEB_APP_URL` and `PHX_HOST` unreachable
   there. Both are gated on the same `app_name == "NOT_FLY_APP"` test: line 20
   reads `PHX_HOST` only on the true branch, and line 36 reads `WEB_APP_URL`
   only on the true branch. On Fly both fall to the else branch, so line 21
   forces the host to `"#{app_name}.fly.dev"` and line 37 forces
   `"https://#{host}"`, and **neither environment variable is read at all.**
   This forces the EVE OAuth `callback_url`
   (line 268) to the `.fly.dev` host, so neither the staging subdomain nor the
   production hostname can work. Change the `.fly.dev` derivation from an
   override into a fallback: prefer an explicitly-set `WEB_APP_URL`, else an
   explicitly-set `PHX_HOST`, else derive from `FLY_APP_NAME`. Behaviour is
   unchanged when neither is set, which keeps the diff rebase-friendly against
   upstream.

2. **A websocket transport that forwards socket options.** Without this, the
   kills websocket cannot reach `wanderer-kills.internal` at all — see the
   evidence section above. Add a thin transport module that reuses upstream's
   callbacks but widens the option split to include `socket_opts`:

   ```elixir
   defmodule WandererApp.Kills.Transport.WebSocketClient do
     @behaviour Phoenix.Channels.GenSocketClient.Transport
     @upstream Phoenix.Channels.GenSocketClient.Transport.WebSocketClient
     @ws_opts [:extra_headers, :ssl_verify, :socket_opts]

     def start_link(url, transport_options) do
       {ws_opts, rest} = Keyword.split(transport_options, @ws_opts)
       url |> to_charlist() |> :websocket_client.start_link(@upstream, [self(), rest], ws_opts)
     end

     defdelegate push(pid, frame), to: @upstream
   end
   ```

   Delegating the `:websocket_client` callbacks to `@upstream` is sound because
   its `init/1` expects exactly `[socket, transport_options]`
   (`web_socket_client.ex:48`). Point `client.ex:502` at this module and pass
   `socket_opts: [:inet6]`.

   Gate it on a new `WANDERER_KILLS_IPV6` variable, following the existing
   `ECTO_IPV6` precedent at `runtime.exs:389-392`, defaulting to `false` so
   non-Fly deployments are unaffected.

   **Known coupling:** this depends on an upstream private contract (the shape
   of the handler-state argument). Mitigations: pin the
   `phoenix_gen_socket_client` version, and submit the one-word fix
   (adding `:socket_opts` to `@websocket_client_opts`) upstream so the shim can
   eventually be deleted. The alternative — copying the ~100-line module
   outright — trades this coupling for a larger permanent diff and was rejected.

   Note what this does **not** fix. Only `socket_opts` reaches
   `:websocket_client`; `timeout` and `tcp_opts` remain handler state, and
   upstream's `init/1` reads only `:keepalive` from it
   (`web_socket_client.ex:48-51`). `websocket_client` 1.5.0 also hardcodes its
   connect timeout to 6000 ms (`websocket_client.erl:276`), so no option would
   change it. The `connect_timeout` / `send_timeout` / `recv_timeout` values in
   `client.ex` are dead before this change and dead after it — they should be
   removed rather than left looking adjustable.

3. **A 6PN-reachable listener on wanderer-kills.** The client fix above is
   necessary but **not sufficient**: the service binds `{0, 0, 0, 0}` and so has
   no IPv6 listener for a 6PN address to reach. Two ways to close this, and the
   choice is open — see "Open item: 6PN reachability" below.

   **Option A — configurable bind, upstreamed (recommended).** Add an `ip:`
   override to upstream's `runtime.exs`, read from an environment variable and
   **defaulting to `{0, 0, 0, 0}` so existing docker-compose deployments are
   unaffected**. Set it to `::` (or the `fly-local-6pn` address) on Fly. This
   mirrors the backward-compatible pattern used for `WANDERER_KILLS_IPV6` in
   wanderer, and it is the change that makes the service Fly-deployable for
   every operator, not just this one. Cost: it is a second upstream change that
   must be merged and released before cutover.

   **Option B — Flycast, no upstream change.** Reach the service at
   `<app>.flycast` through the Fly proxy instead of addressing the machine
   directly over 6PN. The proxy terminates the connection and forwards to the
   app's `internal_port` locally, so the existing `{0, 0, 0, 0}` bind keeps
   working. Requires allocating a private IPv6 address and defining
   `[[services]]`. Cost: an extra proxy hop, and it makes the fly.toml carry a
   service definition that Option A would not need.

   **The client-side `:inet6` change in blocking item 2 is required either
   way** — both the 6PN address and the Flycast address are IPv6.

### Non-blocking

4. **Health endpoint, on a dedicated pipeline.** Add a health route returning
   200 with app version and database reachability. Fly's health checks need a
   path; a TCP check would only prove the listener is up, not that the app can
   reach Postgres.

   **It must not use the existing empty scope at `router.ex:377-379`.** That
   scope is `pipe_through [:api]`, and the `:api` pipeline (`router.ex:171-175`)
   includes `WandererAppWeb.Plugs.CheckApiDisabled`, which halts with `403` when
   `WandererApp.Env.public_api_disabled?/0` is true. Chaining machine liveness
   to a product feature flag means that setting
   `WANDERER_PUBLIC_API_DISABLED=true` would make Fly consider the **sole**
   machine unhealthy and kill it — turning a config toggle into a total outage.

   Note the failure is latent, not immediate: `WANDERER_PUBLIC_API_DISABLED`
   defaults to `"false"` (`runtime.exs:57-59`), so this works on day one and
   breaks catastrophically much later, which is the worse shape of bug.

   Add a dedicated `:health` pipeline containing only `plug :accepts, ["json"]`,
   with no feature-flag plugs, and scope the route through that. Keep it free of
   authentication and rate limiting for the same reason.

5. **`fly.toml` rewrite (wanderer).** Real app name; `primary_region` `ams` ->
   `iad`; `[[vm]] size` `shared-cpu-1x` -> `shared-cpu-2x` with
   `memory = '2gb'`; drop the hard-coded `PHX_HOST = 'wanderer-test.fly.dev'`;
   add `min_machines_running = 1` with the single-machine comment; add the
   health check. Keep `release_command = '/app/bin/migrate.sh'`.

6. **Remove the `[[metrics]]` block** (`fly.toml:37-40`). It scrapes
   `:4021/metrics`, but `PROMEX_DISABLED` defaults to `"true"`
   (`runtime.exs:457-459`), so nothing listens and every scrape fails. Metrics
   are out of scope; the block is two lines to restore later.

7. **New `fly.toml` (wanderer-kills, upstream).** Generic app name,
   `internal_port = 4004`, one machine with `auto_stop_machines = off` and
   `min_machines_running = 1`, and a health check against `/health`.

   Under Option A (direct 6PN) no public IP is allocated and the health check
   should use Fly's **top-level `[checks]` section**, which does not require a
   public service definition. Under Option B (Flycast) a `[[services]]` block is
   required regardless. Confirm the exact TOML against current Fly documentation
   at implementation time rather than assuming it from this document.

Unchanged: secrets handling, the Dockerfile, and the Repo configuration.

## Migration and cutover

### Phase 0 — measure and prepare (no user impact)

- Measure the database:
  `SELECT pg_size_pretty(pg_database_size(current_database()))`, plus a timed
  rehearsal `pg_dump` / `pg_restore`. That timing *is* the outage window.
- Measure the kills service's resident memory on the VM
  (`docker stats wanderer-kills` over a representative period) to confirm or
  correct the 2 GB starting figure.
- Create both Fly apps and the MPG instance (PostgreSQL >= 15) in `iad`.
- Set all wanderer secrets: `SECRET_KEY_BASE`, `EVE_CLIENT_ID` /
  `EVE_CLIENT_SECRET` and any additional EVE client pairs in use,
  `WANDERER_ADMIN_PASSWORD`, `WEB_APP_URL`, plus whichever feature flags the VM
  currently sets. Include the three that are new or newly load-bearing:
  - `WANDERER_KILLS_SERVICE_ENABLED=true` — **it defaults to `false`, so
    omitting it silently disables kills with no error.**
  - `WANDERER_KILLS_BASE_URL=ws://wanderer-kills.internal:4004`
  - `WANDERER_KILLS_IPV6=true`

**Open item to confirm before Phase 1 — EVE SSO callbacks.** The EVE developer
portal is believed to allow a single callback URL per application. If so, the
staging subdomain and production hostname cannot share one EVE app, and a
**second EVE application** is needed for the staging period, with its own client
ID and secret set on the Fly app while it serves the staging subdomain — then
swapped back to the production EVE credentials at cutover step 6. If the portal
does allow multiple callback URLs, this reduces to adding one URL and no swap is
needed. The operator is to confirm; the rest of the plan is unaffected either
way.

Note this open item is no longer purely about hostnames: the staging-safe
configuration above depends on a **separate EVE application** so that staging
never refreshes a production character's token. If the portal turns out to allow
multiple callback URLs on one application, a second application is still wanted
for credential isolation.

**Open item: 6PN reachability — Option A or Option B.** Blocking change 3 offers
a configurable upstream bind (A) or Flycast (B). A is recommended and is the
better fix for every operator, but it depends on an upstream pull request being
merged and released before the cutover window. If that timeline is not
comfortable, B works today with no upstream change. Decide before Phase 1, since
it determines the shape of the kills `fly.toml`.

### Phase 1 — staging validation

Deploy the kills app first and leave it running; nothing consumes it yet.
Restore a throwaway copy of production data into MPG, deploy wanderer, point the
staging subdomain at Fly, and run the verification gates below. This copy is for
validation only and is discarded at cutover.

**This is one Fly app per service throughout, not two.** The wanderer app first
serves the staging subdomain, then has the production hostname added and the
staging one removed. The single kills app serves both periods — being stateless
and private, it needs no staging duplicate.

#### Staging-safe configuration (mandatory)

Staging runs a copy of production data **while production is still live**. That
data carries live credentials and live outbound integrations, so an unmodified
staging instance will reach into production's world. Configure the following
before the first boot against restored data, not after.

- **EVE refresh tokens are the sharpest edge.** `refresh_token/1`
  (`lib/wanderer_app/esi/api_client.ex:746`) reads a character's refresh token
  and persists the rotated result back via `WandererApp.Api.Character.update`.
  Because EVE rotates refresh tokens, a staging instance refreshing a character
  that production also tracks **invalidates production's token** — logging real
  users out of the live map. Use the separate staging EVE application (see the
  open item below) and do not track production characters from staging.
- **Disable outbound dispatchers.** `lib/wanderer_app/external_events/` contains
  `webhook_dispatcher.ex` and `discord_dispatcher.ex`; the restored dump carries
  `map_webhook_subscription`, `map_discord_webhook`, and
  `map_discord_notification` rows pointing at real endpoints. Left enabled,
  staging duplicates every notification your users receive. Turn the external
  events services off, and additionally **scrub the destination rows in the
  restored copy** so a misconfiguration cannot leak — belt and braces, because
  the blast radius is other people's Discord servers.
- Copy production feature flags only after auditing them for outbound effects.
  "Copy whatever the VM sets" is not safe as a blanket instruction.

This is the one place the plan deliberately does not validate production
behaviour faithfully. The tradeoff is accepted: a staging instance that mails
real users is worse than one that proves slightly less.

### Phase 2 — production cutover (planned outage)

Ordered so that nothing writes to two databases at once:

1. Lower the DNS TTL on the production hostname **at least a day ahead**, and
   **pre-provision the production certificate** (`fly certs add` with the DNS-01
   challenge, gated on `fly certs check` reporting Ready). Issuing inside the
   window would make an ACME delay into downtime.
2. Confirm the kills app is up and its cache warm. This is done *before* the
   window, not inside it.
3. Announce the window. Stop wanderer on the VM
   (`docker compose stop wanderer`). Writes cease here, which is what makes the
   dump consistent. Leave Postgres and the VM's kills container running.
4. **Scale the Fly wanderer app to zero and confirm no machine is running.**
   This step is mandatory and easy to overlook: after Phase 1 the Fly app is
   *live* against MPG, and its tracker pools write character locations every
   10-30s with no user interaction at all. Restoring into a database that still
   has an application attached risks `pg_restore` conflicts and, worse, silently
   interleaving staging-era background writes into the restored production data.
   The app stays stopped through steps 5, 6 and 7.
5. `pg_dump -Fc` the live VM database, then restore into MPG, replacing the
   staging copy.
6. Point the Fly app at the production hostname (set `WEB_APP_URL`; the
   certificate already exists from step 1); update the EVE callback if a second
   app was used for staging. Swap the staging-safe configuration from Phase 1
   back to production values — re-enable outbound dispatchers and restore the
   real EVE credentials.
7. **Run the migrations against the restored database.** The restore in step 5
   rolled MPG's schema back to the VM's version, discarding whatever Phase 1's
   deploy migrated forward. `fly scale count` does **not** run
   `[deploy].release_command` — Fly executes that only during a deploy — so
   scaling up would boot the new release against an outdated schema. Run
   `/app/bin/migrate.sh` explicitly in a one-off machine, or perform a
   controlled `fly deploy`. This does not affect rollback: it alters the MPG
   copy, not the VM's Postgres.
8. **Start the Fly app** with the production configuration now in place.
9. Flip DNS to Fly. Verify login, map load, tracking, and kill data against real
   data.
10. Only then stop the VM's kills container and the rest of the VM stack.

**wanderer-notifier during cutover:** it stays on the VM, reachable over the
public internet, and is migrated as separate work afterwards.

### Rollback

While the VM's Postgres is still the newer copy, rollback is "start wanderer on
the VM, flip DNS back."

**Rolling back requires restarting both VM containers, not just wanderer.**
Because the Fly kills app is private-only, a VM-resident wanderer cannot reach
it — so the VM's own kills container must come back up too. Keep the entire VM
stack intact but stopped, not just the wanderer service.

**The point of no return is the first background write on Fly, not the first
user write and not the DNS switch.** Tracker pools write character locations
every 10-30s from the moment the app boots, with no user interaction required,
so the window in which rollback is lossless closes within seconds of starting
the app in step 8 — before any user has logged in. Treat step 8, not step 9, as
the commit point. After it, rolling back loses whatever was written since.

Step 7's migrations are not part of this: they alter the MPG copy, not the VM's
Postgres, so rolling back after migrating but before starting is still lossless.

Keep the VM intact but stopped for roughly a week after cutover.

## Verification

All eight gates must pass on staging before Phase 2, and again on production
data after cutover.

1. **EVE OAuth round-trip** — log in with a real character and get redirected
   back. Most likely thing to break: it depends on the `runtime.exs` change, the
   `WEB_APP_URL` secret, and the EVE callback all agreeing.
2. **Map loads with real data** — systems, connections, and signatures render
   from the restored dump. Validates dump/restore, not just connectivity.
3. **Character tracking writes** — a tracked character's location updates.
   Exercises ESI egress from Fly, token refresh, tracker pools, and DB writes.
   **On staging this must use a dedicated test character**, registered against
   the staging EVE application and not tracked by production. Using a real
   user's character here would rotate their refresh token and log them out of
   the live map — see the staging-safe configuration above.
4. **Real-time updates arrive** — a change appears without a refresh. Proves the
   PubSub -> LiveView path survived.
5. **Kills websocket reaches `connected` over 6PN** — check
   `WandererApp.Kills.get_status/0`. This is the gate that proves the transport
   fix; it is the single most likely thing to fail, and it fails *silently*
   (see risks). Confirm explicitly rather than inferring from the absence of
   errors.
6. **Killmails render in the map UI** — kill data appears on a system with
   recent activity. Proves the full path: subscription, ingest, storage, and
   broadcast, not merely that a socket opened.
7. **Release migrations ran clean** — `interweave_migrate` completed with no
   pending migrations.
8. **Restart survivability** — `fly machine restart` on both apps, then confirm
   the map rehydrates from Postgres and the kills client reconnects. A deploy
   rehearsal.

Post-cutover, additionally confirm the notifier still delivers.

## Residual risks

- **Machine liveness must stay decoupled from product configuration.** The
  health-route decision above exists because the obvious placement would let
  `WANDERER_PUBLIC_API_DISABLED` kill the only machine. The general rule holds
  beyond that one flag: with `min_machines_running = 1` and no redundancy, any
  feature flag reachable from the health path is an outage waiting to happen.
  Re-check this whenever the health route or the `:health` pipeline changes.
- **Staging isolation is enforced by configuration, not by architecture.**
  Nothing in the code prevents a staging instance from mailing production
  Discord webhooks or rotating production EVE tokens — only the Phase 1
  checklist does. A missed step there has effects on real users that the
  migration's own rollback plan cannot undo.

- **Kills failure is silent and self-limiting.** After `@max_retries 10` the
  client stops retrying automatically and falls back to a 15-minute health-check
  cycle. A prolonged kills outage therefore presents as "kill data quietly
  stopped", not as an error or an alarm. Worth a monitoring follow-up, which is
  out of scope here.
- **The transport shim couples to an upstream private contract.** Mitigated by
  pinning the dependency version and upstreaming the proper fix. A
  `phoenix_gen_socket_client` upgrade should re-verify the handler-state shape.
- **Kills memory sizing is unmeasured.** 2 GB is a starting estimate; Phase 0
  measures it. Under-sizing presents as OOM restarts, which the one-directional
  dependency makes non-fatal to wanderer but which do drop kill data.
- **Deploys are user-visible** (~30-60s). Inherent to single-machine plus
  in-memory map state. Fixing it means making map state cluster-aware, a far
  larger project.
- **ESI rate limiting is per-source-IP.** Moving to Fly changes the egress IP,
  and now *two* services call ESI from the same Fly organisation. Not expected
  to matter at private-corp scale, but it is a changed variable and the kills
  service is the heavier ESI consumer of the two.
- **`runtime.exs` host handling is upstream-shared code**, so the change is a
  rebase-conflict candidate. Mitigated by keeping it minimal and
  backward-compatible.
