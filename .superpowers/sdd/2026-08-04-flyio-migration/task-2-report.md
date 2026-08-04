# Task 2 report: websocket transport that forwards socket options

## What changed and why

- **Created** `lib/wanderer_app/kills/transport/web_socket_client.ex` — a
  `Phoenix.Channels.GenSocketClient.Transport` shim (`WandererApp.Kills.Transport.WebSocketClient`)
  that splits transport options on `[:extra_headers, :ssl_verify, :socket_opts]`
  instead of upstream's `[:extra_headers, :ssl_verify]`, so `:socket_opts`
  (the key `:websocket_client` actually reads) reaches the socket instead of
  being silently absorbed into handler state.
- **Created** `test/unit/kills/transport/web_socket_client_test.exs` — 6 tests
  covering `split_opts/1` (the pure partitioning logic) and behaviour
  conformance (`start_link/2`, `push/2` both exported), transcribed verbatim
  from the brief.
- **Modified** `lib/wanderer_app/kills/client.ex:486-510` — replaced the dead
  `timeout` / `tcp_opts` (`connect_timeout`/`send_timeout`/`recv_timeout`)
  option block with `transport_opts: [socket_opts: socket_opts]`, where
  `socket_opts` is `[:inet6]` when `WandererApp.Env.wanderer_kills_ipv6?/0` is
  true, else `[]`. Pointed `GenSocketClient.start_link/4` at the new shim
  module instead of upstream's transport directly.
- **Modified** `lib/wanderer_app/env.ex:39` — added
  `wanderer_kills_ipv6?/0`, `get_key(:wanderer_kills_ipv6, false)`, following
  the exact style of the adjacent `wanderer_kills_service_enabled?/0`.
- **Modified** `config/runtime.exs` — added the `wanderer_kills_ipv6` variable
  (reads `WANDERER_KILLS_IPV6`, default `"false"`, via
  `get_var_from_path_or_env/3` + `String.to_existing_atom/1`, mirroring the
  `ECTO_IPV6` precedent at line ~387-389) immediately after the
  `wanderer_kills_base_url` assignment, and added
  `wanderer_kills_ipv6: wanderer_kills_ipv6,` to the `config :wanderer_app`
  block immediately after `wanderer_kills_base_url: wanderer_kills_base_url,`.
  (Actual line numbers in the checkout were ~66-72 and ~185-190 rather than
  the brief's 72-74/191-192 — Task 1's edits shifted them by a few lines. No
  semantic difference; inserted at the same logical position relative to the
  named anchors.)
- **Modified** `mix.exs:80` — pinned `phoenix_gen_socket_client` from
  `"~> 4.0"` to `"== 4.0.0"` with a comment explaining the shim's coupling to
  its private handler-state shape.

## Exact commands run, with real output

1. Created the test file, then ran it to confirm the expected failure:

```
$ DB_HOST=db mix test test/unit/kills/transport/web_socket_client_test.exs
```
Result: 6 tests, 6 failures, all `** (UndefinedFunctionError) function
WandererApp.Kills.Transport.WebSocketClient.split_opts/1 is undefined (module
WandererApp.Kills.Transport.WebSocketClient is not available)` (and the
analogous `function_exported?` false for the behaviour-conformance test).
Matches the brief's expected failure.

2. Implemented `web_socket_client.ex`, re-ran the same test:

```
$ DB_HOST=db mix test test/unit/kills/transport/web_socket_client_test.exs
```
Output:
```
Running ExUnit with seed: 230059, max_cases: 24
Excluding tags: [:pending, :integration]
......
Finished in 0.03 seconds (0.03s async, 0.00s sync)
6 tests, 0 failures
```

3. Verified Step 8's dead-config claims directly in the checkout before
   deleting the timeout options in `client.ex`:

```
$ grep -n 'keepalive\|transport_options' deps/phoenix_gen_socket_client/lib/gen_socket_client/transport/web_socket_client.ex
```
Confirmed: `init/1` (line 48) reads only `:keepalive` from `transport_options`
(`Keyword.get(transport_options, :keepalive, :timer.seconds(30))`), and the
split (line 30) uses `@websocket_client_opts` = `[:extra_headers, :ssl_verify]`
(line 18) — nothing else.

```
$ grep -n 'connect(Host, Port' deps/websocket_client/src/websocket_client.erl
```
Confirmed: line 275, `(T#transport.mod):connect(Host, Port, T#transport.opts, 6000)`
— the literal hardcoded `6000`.

Both matched the brief's claims exactly, so removing `timeout`/`tcp_opts` in
Step 6 was safe.

4. Made the remaining edits (env.ex, runtime.exs, client.ex, mix.exs), then:

```
$ mix deps.get
```
Output ended with `All dependencies are up to date` (plus unrelated
retired-package/security-advisory notices for other deps already present in
the lockfile — pre-existing, not caused by this change).

```
$ git diff mix.lock
```
No output — confirms the brief's expectation that 4.0.0 was already locked
and the pin caused no lockfile change.

5. Ran the kills test suite and a warnings-as-errors compile:

```
$ DB_HOST=db mix test test/unit/kills
```
```
Running ExUnit with seed: 737342, max_cases: 24
Excluding tags: [:pending, :integration]
..............................
Finished in 0.1 seconds (0.1s async, 0.00s sync)
30 tests, 0 failures
```

```
$ mix compile --force --warnings-as-errors
```
Compiled cleanly (302 files), no warnings emitted.

6. Ran the full unit suite to check for regressions:

```
$ DB_HOST=db mix test test/unit
```
```
Finished in 28.4 seconds (2.3s async, 26.1s sync)
933 tests, 6 failures, 22 skipped
```
The 6 failures are all in `WandererAppWeb.AuthControllerTest`
(`test/unit/controllers/auth_controller_test.exs:7,34,46,58,70,81`), all the
pre-existing `flash not fetched` failures the brief said to expect and ignore.
Confirmed by name/location — no new failures introduced.

7. Formatted the touched files:

```
$ mix format lib/wanderer_app/kills/transport/web_socket_client.ex \
    test/unit/kills/transport/web_socket_client_test.exs \
    lib/wanderer_app/kills/client.ex lib/wanderer_app/env.ex config/runtime.exs mix.exs
```
No diff produced by formatting (files were already correctly formatted as
written/edited).

8. Committed:

```
$ git commit -m "fix(kills): forward socket options to the websocket transport ..."
```
Commit `1ea46811`, 6 files changed, 129 insertions(+), 15 deletions(-).

## Deviations from the brief

- Line numbers in `config/runtime.exs` referenced by the brief (72-74,
  191-192) were off by a few lines in the actual checkout (66-72, 185-190) —
  presumably from Task 1's earlier edits to the same region. I re-read the
  file before editing (as Task 1's context note instructed) and inserted at
  the correct logical position (immediately after `wanderer_kills_base_url`
  in both the variable-assignment section and the `config :wanderer_app`
  block). No semantic deviation.
- Everything else — module content, test content, client.ex block, env.ex
  line, mix.exs pin, commit message — was transcribed verbatim from the
  brief.

## Concerns

None. `flyctl` was not invoked (not needed for this task — no `fly` commands
were called for). All new behavior is gated behind `WANDERER_KILLS_IPV6`,
default `"false"`, so non-Fly deployments get `socket_opts: []`, which is a
no-op passed to `:websocket_client.start_link/4` — behavior is unchanged
except that the previously-dead `timeout`/`tcp_opts` options are gone (they
never had any effect, confirmed above), so this is not an observable change
for existing deployments.

## Fix round 1

Review returned Approved with three findings routed to the plan owner. Rulings
received: ACCEPT NO CODE CHANGE on the `start_link/2` test-coverage gap,
NO CHANGE on the IPv6 failure-log improvement, DO THIS on documenting
`WANDERER_KILLS_IPV6` in `.env.example`. Only the third required action this
round.

### What changed

Added, in `.env.example`, immediately after line 14
(`export WANDERER_KILLS_BASE_URL=...`):

```
# Use IPv6 for the outbound WebSocket connection to wanderer-kills (optional, default false).
# Set to true only on Fly.io, whose private network (6PN) is IPv6-only.
# Leave unset everywhere else - on a host with no AAAA record the connection
# fails with :nxdomain and the client retries on its normal backoff.
# export WANDERER_KILLS_IPV6="true"
```

Commented out (matching the file's convention for optional flags whose
default is a non-default-triggering value, e.g. the
`WANDERER_DISCORD_MAX_KILLMAIL_AGE_SECONDS` block at lines 19-22), so
uncommenting it is a deliberate operator action.

### Consumption check

```
$ grep -rn "\.env\.example" --include='*.ex' --include='*.exs' --include='*.yml' \
    --include='*.yaml' --include='Dockerfile*' --include='*.sh' .
```
No output — `.env.example` is not read by any build, test, or container
config in the repo; it exists purely as a developer-facing template
(`README.md:71` tells operators to copy it to `.env`). Editing it carries no
build/test risk.

### Other documentation locations

```
$ grep -rln "WANDERER_KILLS_BASE_URL" . --exclude-dir=.git --exclude-dir=deps --exclude-dir=_build
```
Hits: `.env.example`, `config/dev.exs`, `config/runtime.exs`, and two spec/plan
docs under `docs/superpowers/`. Checked `.devcontainer/docker-compose.yml` and
`.devcontainer/docker-compose.override.yml.example` (no app env vars listed
there — only infra-level `environment:` blocks for unrelated services) and
`README.md` (no env-variable table, just the one-line pointer to
`.env.example` at line 71). No other operator-facing location lists
`WANDERER_KILLS_BASE_URL` or needs the new variable added. Changed nothing
beyond `.env.example`.

### Commit

```
$ git add .env.example
$ git commit -m "docs: document WANDERER_KILLS_IPV6 in .env.example"
```
Commit `<see below>`. No test run — not required for a `.env.example`-only
change, and confirmed above that nothing consumes the file programmatically.
