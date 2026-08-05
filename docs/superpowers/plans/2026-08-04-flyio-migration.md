# Fly.io Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move a self-hosted Wanderer instance and its hard dependency wanderer-kills off a single docker-compose VM onto Fly.io, with Postgres on Fly Managed Postgres.

**Architecture:** Two single-machine Fly apps in `iad` — `wanderer` (public, TLS at the Fly edge) and `wanderer-kills` (no public IP, reachable only over the private 6PN network). Both apps are pinned to exactly one machine because their state is node-local Cachex plus a node-local Registry, so a second machine would silently serve half the map. Postgres is Fly Managed Postgres on the same private network.

**Tech Stack:** Elixir 1.17.3-otp-26, Phoenix, Ash Framework, PostgreSQL >= 15, Fly.io (`flyctl`), `phoenix_gen_socket_client` 4.0.0, `websocket_client` 1.5.0.

**Source spec:** `docs/superpowers/specs/2026-08-02-flyio-migration-design.md`

## Global Constraints

- **Exactly one machine per app.** `auto_stop_machines = 'off'`, `min_machines_running = 1`, no autoscaling, `DNS_CLUSTER_QUERY` unset. Non-negotiable for both apps — see the spec's "Exactly one machine, for both apps".
- **Region `iad`** for both apps and for MPG.
- **PostgreSQL >= 15** (`WandererApp.Repo.min_pg_version/0`, `lib/wanderer_app/repo.ex:11-13`).
- **All code changes must be backward-compatible with non-Fly deployments.** Every new environment variable defaults to the current behaviour. These files are upstream-shared and the diff must stay rebase-friendly.
- **Machine liveness must never depend on a product feature flag.** The health route may not sit behind any pipeline that can halt on configuration.
- **No behavioural change to the application** beyond what these tasks specify.
- **`docs/` is listed in `/app/.git/info/exclude`.** That is a local convenience so scratch files stay out of `git status`; it does not mean `docs/` is untracked — `docs/ZOO-FORK.md` is committed. The spec and this plan have been force-added and are now tracked on this branch, so edits to them show up in `git status` normally and must be committed like any other file. Do not edit the exclude file. Code changes under `lib/`, `config/`, `test/`, and `fly.toml` are unaffected.

## Decision Log

Resolved during planning, recorded here because they shape task ordering:

- **6PN reachability: pursue Option A, keep Option B as a fallback.** Task 5 submits the upstream bind-address change; Task 7 is a go/no-go checkpoint that picks Task 8A (direct 6PN) or Task 8B (Flycast). The cutover date does not depend on someone else merging a pull request.
- Tasks 1-4 are pure code in this repository and can proceed immediately, in parallel with the upstream pull request.
- Tasks 9-13 are an operator runbook, not TDD. They are marked as such.

---

## File Structure

**This repository (`wanderer`):**

| File | Responsibility | Task |
|---|---|---|
| `lib/wanderer_app/helpers/config.ex` | Add two pure resolver functions for host and external URL. Pure so they are unit-testable; `config/runtime.exs` itself is not. | 1 |
| `test/unit/config_helpers_test.exs` | New. Covers both resolvers, including the backward-compatibility matrix. | 1 |
| `config/runtime.exs:16-38` | Call the resolvers instead of inlining the `case` expressions. | 1 |
| `lib/wanderer_app/kills/transport/web_socket_client.ex` | New. Thin transport shim that forwards `:socket_opts` to `:websocket_client`. Sole responsibility: widen the option split. | 2 |
| `test/unit/kills/transport/web_socket_client_test.exs` | New. Covers the option split. | 2 |
| `lib/wanderer_app/kills/client.ex:486-503` | Point at the shim; pass `socket_opts: [:inet6]` when configured. | 2 |
| `lib/wanderer_app/env.ex` | Add `wanderer_kills_ipv6?/0`. | 2 |
| `config/runtime.exs` (kills block) | Read `WANDERER_KILLS_IPV6`, default `"false"`. | 2 |
| `mix.exs:80` | Pin `phoenix_gen_socket_client` to `== 4.0.0` — the shim couples to a private contract. | 2 |
| `lib/wanderer_app_web/controllers/health_controller.ex` | New. Liveness, always 200 while the app is serving; database state reported in the body, never in the status code. No dependencies on product configuration. | 3 |
| `lib/wanderer_app_web/router.ex` | New `:health` pipeline and route. | 3 |
| `test/wanderer_app_web/controllers/health_controller_test.exs` | New. Includes the regression test that the route survives `public_api_disabled`. | 3 |
| `fly.toml` | Production-shaped rewrite. | 4 |

Nothing is added to this repository's `docs/` or `README.md`. The deployment
guide goes to the self-hosting repository instead — see Task 14.

**Upstream repository (`wanderer-industries/wanderer-kills`), separate clone:**

| File | Responsibility | Task |
|---|---|---|
| `config/runtime.exs` | Configurable bind address, defaulting to today's `{0, 0, 0, 0}`. | 5 |
| `fly.toml` | New. Operator-agnostic, one machine, port 4004, `/health` check. | 8A / 8B |

**Self-hosting repository (`wanderer-industries/community-edition`), separate clone:**

| File | Responsibility | Task |
|---|---|---|
| `fly-io/README.md` | New. Operator-facing guide: fresh Fly install and the docker-compose migration path. | 14 |
| `fly-io/fly.toml` | New. Wanderer app template, operator-agnostic. | 14 |
| `fly-io/fly-kills.toml` | New. wanderer-kills app template, operator-agnostic. | 14 |
| `README.md` | One link to `fly-io/`, alongside the existing `reverse-proxy/` and `scripts/` links. | 14 |

---

## Task 1: Host and external-URL resolution (blocking change 1)

**Why this is blocking:** on Fly, `FLY_APP_NAME` is always set, so `config/runtime.exs:19-21` forces `host` to `<app>.fly.dev` and `:36-38` forces `web_app_url` to `https://<that host>`. Both `PHX_HOST` and `WEB_APP_URL` are read **only** on the `app_name == "NOT_FLY_APP"` branch, so on Fly neither environment variable is read at all. That propagates into the EVE OAuth `callback_url` at `config/runtime.exs:268`, which means neither the staging subdomain nor the production hostname can complete a login. The fix turns the `.fly.dev` derivation from an override into a fallback.

**Files:**
- Modify: `lib/wanderer_app/helpers/config.ex`
- Modify: `config/runtime.exs:16-38`
- Test: `test/unit/config_helpers_test.exs` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `WandererApp.ConfigHelpers.resolve_host(phx_host :: String.t() | nil, fly_app_name :: String.t() | nil) :: String.t()`
  - `WandererApp.ConfigHelpers.resolve_web_app_url(web_app_url :: String.t() | nil, host :: String.t(), port :: integer(), fly_app_name :: String.t() | nil) :: String.t()`

- [ ] **Step 1: Write the failing test**

Create `test/unit/config_helpers_test.exs`:

```elixir
defmodule WandererApp.ConfigHelpersTest do
  # Pure functions: no app env, no cache, no process state.
  use ExUnit.Case, async: true

  alias WandererApp.ConfigHelpers

  # "NOT_FLY_APP" is the sentinel `runtime.exs` uses as the default for
  # FLY_APP_NAME, so it must be treated as "not on Fly", not as an app name.
  describe "resolve_host/2 off Fly" do
    test "uses PHX_HOST when set" do
      assert ConfigHelpers.resolve_host("map.example.com", "NOT_FLY_APP") ==
               "map.example.com"
    end

    test "falls back to localhost when PHX_HOST is unset" do
      assert ConfigHelpers.resolve_host(nil, "NOT_FLY_APP") == "localhost"
      assert ConfigHelpers.resolve_host("", "NOT_FLY_APP") == "localhost"
    end

    test "treats a missing FLY_APP_NAME the same as the sentinel" do
      assert ConfigHelpers.resolve_host(nil, nil) == "localhost"
      assert ConfigHelpers.resolve_host("map.example.com", nil) == "map.example.com"
    end
  end

  describe "resolve_host/2 on Fly" do
    test "derives from FLY_APP_NAME when PHX_HOST is unset" do
      assert ConfigHelpers.resolve_host(nil, "wanderer") == "wanderer.fly.dev"
      assert ConfigHelpers.resolve_host("", "wanderer") == "wanderer.fly.dev"
    end

    # This is the whole point of the change: on Fly, an explicitly-set
    # PHX_HOST must win, otherwise a custom domain is unreachable.
    test "prefers an explicitly-set PHX_HOST over the .fly.dev derivation" do
      assert ConfigHelpers.resolve_host("map.example.com", "wanderer") ==
               "map.example.com"
    end
  end

  describe "resolve_web_app_url/4 off Fly" do
    test "uses WEB_APP_URL when set" do
      assert ConfigHelpers.resolve_web_app_url(
               "https://map.example.com",
               "localhost",
               8000,
               "NOT_FLY_APP"
             ) == "https://map.example.com"
    end

    test "falls back to http://host:port when WEB_APP_URL is unset" do
      assert ConfigHelpers.resolve_web_app_url(nil, "localhost", 8000, "NOT_FLY_APP") ==
               "http://localhost:8000"
    end

    test "passes an explicitly-empty WEB_APP_URL through so the scheme check still raises" do
      # `WEB_APP_URL=` in a .env file yields "" rather than nil. Today that reaches
      # URI.parse/1, produces a nil scheme, and raises at boot with the variable named.
      # Treating "" as unset would replace that loud failure with a silently wrong
      # OAuth callback URL, so "" must pass through unchanged.
      assert ConfigHelpers.resolve_web_app_url("", "localhost", 8000, "NOT_FLY_APP") == ""
    end
  end

  describe "resolve_web_app_url/4 on Fly" do
    test "derives https from the resolved host when WEB_APP_URL is unset" do
      assert ConfigHelpers.resolve_web_app_url(nil, "wanderer.fly.dev", 8080, "wanderer") ==
               "https://wanderer.fly.dev"
    end

    test "prefers an explicitly-set WEB_APP_URL over the https derivation" do
      assert ConfigHelpers.resolve_web_app_url(
               "https://map.example.com",
               "map.example.com",
               8080,
               "wanderer"
             ) == "https://map.example.com"
    end

    # Composition check: the two resolvers must agree, because the EVE OAuth
    # callback_url (runtime.exs:268) is built from web_app_url.
    test "composes with resolve_host so a custom domain flows into the URL" do
      host = ConfigHelpers.resolve_host("map.example.com", "wanderer")
      assert ConfigHelpers.resolve_web_app_url(nil, host, 8080, "wanderer") ==
               "https://map.example.com"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/config_helpers_test.exs`
Expected: FAIL with `function WandererApp.ConfigHelpers.resolve_host/2 is undefined or private`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/wanderer_app/helpers/config.ex`, inside the module:

```elixir
  @fly_sentinel "NOT_FLY_APP"

  @doc """
  Resolves the external hostname.

  `FLY_APP_NAME` is a **fallback**, not an override. An operator who sets
  `PHX_HOST` explicitly gets it even on Fly, which is what makes a custom
  domain — and therefore a working EVE OAuth callback — possible. When
  `PHX_HOST` is unset the behaviour is unchanged from before this function
  existed.

  An explicitly-empty `PHX_HOST` is treated as unset. Before this function
  existed it produced `http://:8000`, which is not a usable URL for anyone;
  `localhost` is the same value an unset variable gives. Contrast
  `resolve_web_app_url/4`, where an empty string must pass through so the
  caller's scheme check still raises.
  """
  def resolve_host(phx_host, fly_app_name)

  def resolve_host(phx_host, _fly_app_name) when is_binary(phx_host) and phx_host != "",
    do: phx_host

  def resolve_host(_phx_host, fly_app_name)
      when is_binary(fly_app_name) and fly_app_name != "" and fly_app_name != @fly_sentinel,
      do: "#{fly_app_name}.fly.dev"

  def resolve_host(_phx_host, _fly_app_name), do: "localhost"

  @doc """
  Resolves the externally-visible base URL.

  Same rule as `resolve_host/2`: an explicit `WEB_APP_URL` always wins. On Fly
  without one, https is assumed because the Fly edge terminates TLS.

  Note the first clause matches **any** binary, including `""`. That is
  deliberate and differs from `resolve_host/2`. `WEB_APP_URL=` in a `.env` file
  yields `""`, not nil, and the caller parses the result and raises when the
  scheme is missing. Treating `""` as unset here would swap that named,
  at-boot error for an app that starts with a silently wrong OAuth callback.
  """
  def resolve_web_app_url(web_app_url, host, port, fly_app_name)

  def resolve_web_app_url(web_app_url, _host, _port, _fly_app_name)
      when is_binary(web_app_url),
      do: web_app_url

  def resolve_web_app_url(_web_app_url, host, _port, fly_app_name)
      when is_binary(fly_app_name) and fly_app_name != "" and fly_app_name != @fly_sentinel,
      do: "https://#{host}"

  def resolve_web_app_url(_web_app_url, host, port, _fly_app_name),
    do: "http://#{host}:#{port}"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/unit/config_helpers_test.exs`
Expected: PASS, 10 tests.

- [ ] **Step 5: Wire the resolvers into `config/runtime.exs`**

Replace `config/runtime.exs:18-22` (the `host = case ... end` expression) with:

```elixir
host = resolve_host(System.get_env("PHX_HOST"), app_name)
```

Replace `config/runtime.exs:34-38` (the `web_app_url = case ... end` expression) with:

```elixir
web_app_url =
  resolve_web_app_url(System.get_env("WEB_APP_URL"), host, web_port, app_name)
```

Leave line 16 (`app_name = System.get_env("FLY_APP_NAME", "NOT_FLY_APP")`) and the `web_port` block between them exactly as they are. `WandererApp.ConfigHelpers` is already imported at `config/runtime.exs:2`, so no new import is needed.

- [ ] **Step 6: Verify the config file still evaluates**

Run: `mix compile --force`
Expected: compiles clean. A `runtime.exs` syntax or arity error surfaces here.

Then confirm the non-Fly default is genuinely unchanged. `--no-start` evaluates `config/runtime.exs` without booting the supervision tree, so this needs no database:

Run: `mix run --no-start -e 'IO.inspect(Application.get_env(:wanderer_app, :web_app_url))'`
Expected: `"http://localhost:8000"` — the same value as before the change.

Then confirm the new override path works, which is the whole point of the task:

Run: `FLY_APP_NAME=wanderer PHX_HOST=map.example.com mix run --no-start -e 'IO.inspect(Application.get_env(:wanderer_app, :web_app_url))'`
Expected: `"https://map.example.com"`. Before this change it would have been `"https://wanderer.fly.dev"`.

- [ ] **Step 7: Run the full unit suite**

Run: `mix test test/unit`
Expected: PASS, no new failures.

- [ ] **Step 8: Format and commit**

```bash
mix format lib/wanderer_app/helpers/config.ex test/unit/config_helpers_test.exs config/runtime.exs
git add lib/wanderer_app/helpers/config.ex test/unit/config_helpers_test.exs config/runtime.exs
git commit -m "fix(config): let PHX_HOST and WEB_APP_URL override the .fly.dev derivation

On Fly, FLY_APP_NAME is always set, so both env vars sat on the dead branch of
their case expressions and were never read. That forced the EVE OAuth
callback_url to <app>.fly.dev, making a custom domain impossible.

Behaviour is unchanged when neither variable is set."
```

---

## Task 2: Websocket transport that forwards socket options (blocking change 2)

**Why this is blocking:** the kills websocket cannot reach a Fly private address without it. Traced through three files:

1. `lib/wanderer_app/kills/client.ex:486-498` passes `transport_opts: [timeout:, tcp_opts: [...]]`.
2. `deps/phoenix_gen_socket_client/lib/gen_socket_client/transport/web_socket_client.ex:18` defines `@websocket_client_opts [:extra_headers, :ssl_verify]`; line 30 splits on **exactly those two keys** and line 34 passes everything else as the *handler state*, not as socket options.
3. `deps/websocket_client/src/websocket_client.erl:195` reads `socket_opts` to build the transport — precisely the key filtered out at step 2.

Two consequences. First, the existing `connect_timeout` / `send_timeout` / `recv_timeout` values are **already dead config today**; this is a pre-existing latent bug independent of Fly. Second, there is no supported path to pass `:inet6`, and Erlang's `gen_tcp` defaults to IPv4 for hostname resolution, so `ws://wanderer-kills.internal:4004` would fail to resolve.

`GenSocketClient` passes `opts[:transport_opts]` verbatim to `transport_mod.start_link/2` (`gen_socket_client.ex:247` and `:385`), and the `Transport` behaviour has exactly two callbacks, `start_link/2` and `push/2` (`gen_socket_client/transport.ex:18,22`). A shim is therefore complete at ~15 lines.

**What this does *not* fix — read before touching the timeouts.** Only `:socket_opts` reaches `:websocket_client`. The `timeout` and `tcp_opts` keys in `client.ex` remain handler state, and upstream's `init/1` reads exactly one key from it, `:keepalive` (`web_socket_client.ex:48-51`). Worse, `websocket_client` 1.5.0 **hardcodes its connect timeout to 6000 ms** (`websocket_client.erl:276`, `(T#transport.mod):connect(Host, Port, T#transport.opts, 6000)`), so there is no option that would change it. `connect_timeout`, `send_timeout`, and `recv_timeout` are dead config before this change and dead config after it. Step 6 deletes them rather than leaving knobs that look adjustable and are not. The one option that genuinely reaches the handler is `:keepalive`, defaulting to 30s.

**Files:**
- Create: `lib/wanderer_app/kills/transport/web_socket_client.ex`
- Modify: `lib/wanderer_app/kills/client.ex:486-503`
- Modify: `lib/wanderer_app/env.ex` (add `wanderer_kills_ipv6?/0` beside `wanderer_kills_service_enabled?/0` at line 38)
- Modify: `config/runtime.exs` (kills block at lines 67-74; config assignment at lines 191-192)
- Modify: `mix.exs:80`
- Test: `test/unit/kills/transport/web_socket_client_test.exs` (create)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `WandererApp.Kills.Transport.WebSocketClient.split_opts(Keyword.t()) :: {Keyword.t(), Keyword.t()}`
  - `WandererApp.Kills.Transport.WebSocketClient.start_link(String.t(), Keyword.t()) :: {:ok, pid()} | {:error, term()}`
  - `WandererApp.Env.wanderer_kills_ipv6?() :: boolean()`
  - Application env key `:wanderer_kills_ipv6`

- [ ] **Step 1: Write the failing test**

Create `test/unit/kills/transport/web_socket_client_test.exs`:

```elixir
defmodule WandererApp.Kills.Transport.WebSocketClientTest do
  # `split_opts/1` is pure.
  use ExUnit.Case, async: true

  alias WandererApp.Kills.Transport.WebSocketClient

  describe "split_opts/1" do
    # The bug this module exists to fix: upstream splits on
    # [:extra_headers, :ssl_verify] only, so :socket_opts fell through into the
    # handler-state argument and never reached :websocket_client.
    test "routes :socket_opts to the websocket_client options" do
      {ws_opts, rest} = WebSocketClient.split_opts(socket_opts: [:inet6])

      assert ws_opts == [socket_opts: [:inet6]]
      assert rest == []
    end

    test "still routes the two options upstream already handled" do
      {ws_opts, rest} =
        WebSocketClient.split_opts(extra_headers: [{"x", "y"}], ssl_verify: :verify_none)

      assert Keyword.fetch!(ws_opts, :extra_headers) == [{"x", "y"}]
      assert Keyword.fetch!(ws_opts, :ssl_verify) == :verify_none
      assert rest == []
    end

    # Anything upstream treats as handler state must keep being handler state,
    # or the shim breaks GenSocketClient rather than fixing it.
    test "leaves unrecognised options in the handler-state half" do
      {ws_opts, rest} = WebSocketClient.split_opts(timeout: 10_000, tcp_opts: [x: 1])

      assert ws_opts == []
      assert Keyword.fetch!(rest, :timeout) == 10_000
      assert Keyword.fetch!(rest, :tcp_opts) == [x: 1]
    end

    test "partitions a mixed keyword list into both halves" do
      {ws_opts, rest} =
        WebSocketClient.split_opts(socket_opts: [:inet6], timeout: 10_000)

      assert ws_opts == [socket_opts: [:inet6]]
      assert rest == [timeout: 10_000]
    end

    test "handles an empty option list" do
      assert WebSocketClient.split_opts([]) == {[], []}
    end
  end

  describe "behaviour conformance" do
    # The shim delegates push/2 and implements start_link/2. If a
    # phoenix_gen_socket_client upgrade adds a callback, this test fails and
    # the handler-state coupling gets re-verified — which is the point.
    test "exports both Transport callbacks" do
      assert function_exported?(WebSocketClient, :start_link, 2)
      assert function_exported?(WebSocketClient, :push, 2)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/kills/transport/web_socket_client_test.exs`
Expected: FAIL with `module WandererApp.Kills.Transport.WebSocketClient is not available`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/wanderer_app/kills/transport/web_socket_client.ex`:

```elixir
defmodule WandererApp.Kills.Transport.WebSocketClient do
  @moduledoc """
  A thin wrapper around `Phoenix.Channels.GenSocketClient.Transport.WebSocketClient`
  that also forwards `:socket_opts` through to `:websocket_client`.

  Upstream splits transport options on exactly `[:extra_headers, :ssl_verify]`
  (`web_socket_client.ex:18`) and passes everything else through as the handler
  state, so `:socket_opts` — the key `:websocket_client` actually reads
  (`websocket_client.erl:195`) — never reaches the socket.

  Without this, `:inet6` cannot be set, and Fly's 6PN `.internal` addresses are
  IPv6-only while Erlang's `gen_tcp` resolves hostnames as IPv4 by default.

  This module couples to an upstream private contract: the handler-state
  argument is `[socket, transport_options]` (`web_socket_client.ex:48`).
  `phoenix_gen_socket_client` is pinned in `mix.exs` for that reason. Delete
  this module once `:socket_opts` is added to upstream's split list.
  """
  @behaviour Phoenix.Channels.GenSocketClient.Transport

  @upstream Phoenix.Channels.GenSocketClient.Transport.WebSocketClient
  @ws_opts [:extra_headers, :ssl_verify, :socket_opts]

  @doc """
  Partitions transport options into `{websocket_client_options, handler_state}`.

  Public only so it can be tested directly; not part of the behaviour.
  """
  def split_opts(transport_options), do: Keyword.split(transport_options, @ws_opts)

  @impl true
  def start_link(url, transport_options) do
    {ws_opts, rest} = split_opts(transport_options)

    url
    |> to_charlist()
    |> :websocket_client.start_link(@upstream, [self(), rest], ws_opts)
  end

  @impl true
  defdelegate push(pid, frame), to: @upstream
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/unit/kills/transport/web_socket_client_test.exs`
Expected: PASS, 6 tests.

- [ ] **Step 5: Add the `WANDERER_KILLS_IPV6` setting**

In `config/runtime.exs`, immediately after the `wanderer_kills_base_url` block (currently lines 72-74), add:

```elixir
# Fly's 6PN `.internal` and `.flycast` addresses are IPv6-only, and gen_tcp
# resolves hostnames as IPv4 by default. Mirrors the ECTO_IPV6 precedent below.
wanderer_kills_ipv6 =
  config_dir
  |> get_var_from_path_or_env("WANDERER_KILLS_IPV6", "false")
  |> String.to_existing_atom()
```

In the `config :wanderer_app, ...` block, immediately after `wanderer_kills_base_url: wanderer_kills_base_url,` (currently line 192), add:

```elixir
  wanderer_kills_ipv6: wanderer_kills_ipv6,
```

In `lib/wanderer_app/env.ex`, immediately after the `wanderer_kills_service_enabled?/0` definition (line 38), add:

```elixir
  def wanderer_kills_ipv6?(), do: get_key(:wanderer_kills_ipv6, false)
```

- [ ] **Step 6: Point the client at the shim**

In `lib/wanderer_app/kills/client.ex`, replace the `opts = [...]` block (currently lines 486-498) with:

```elixir
    # GenSocketClient passes :transport_opts verbatim to the transport's
    # start_link/2 (gen_socket_client.ex:247, :385).
    #
    # :socket_opts reaches the socket only via
    # WandererApp.Kills.Transport.WebSocketClient — upstream's transport filters
    # it out.
    #
    # The connect/send/recv timeouts that used to sit here were removed: they
    # never applied. Upstream's handler init/1 reads only :keepalive, and
    # websocket_client 1.5.0 hardcodes its connect timeout to 6000ms
    # (websocket_client.erl:276). They were adjustable-looking and inert.
    socket_opts = if WandererApp.Env.wanderer_kills_ipv6?(), do: [:inet6], else: []

    opts = [transport_opts: [socket_opts: socket_opts]]
```

Then, in the `GenSocketClient.start_link(...)` call immediately below, replace the transport module argument:

```elixir
    case GenSocketClient.start_link(
           __MODULE__.Handler,
           WandererApp.Kills.Transport.WebSocketClient,
           handler_state,
           opts
         ) do
```

- [ ] **Step 7: Pin the coupled dependency**

In `mix.exs`, change line 80 from `{:phoenix_gen_socket_client, "~> 4.0"},` to:

```elixir
      # Pinned: WandererApp.Kills.Transport.WebSocketClient depends on this
      # library's private handler-state shape. Re-verify that shim before
      # bumping.
      {:phoenix_gen_socket_client, "== 4.0.0"},
```

Run: `mix deps.get`
Expected: no change to `mix.lock` — 4.0.0 is already locked.

- [ ] **Step 8: Confirm the removed timeouts really were dead**

Do not take the plan's word for it — the whole reason this task exists is that an option silently failed to reach its destination. Verify in the checkout:

Run: `grep -n 'keepalive\|transport_options' deps/phoenix_gen_socket_client/lib/gen_socket_client/transport/web_socket_client.ex`
Expected: `init/1` reads `:keepalive` and nothing else from `transport_options`.

Run: `grep -n 'connect(Host, Port' deps/websocket_client/src/websocket_client.erl`
Expected: the literal `6000` as the fourth argument — a hardcoded connect timeout with no option behind it.

If either has changed in a newer version, the removal in Step 6 needs revisiting.

- [ ] **Step 9: Run the kills tests and compile with warnings as errors**

Run: `mix test test/unit/kills`
Expected: PASS, no new failures.

Run: `mix compile --force --warnings-as-errors`
Expected: no warnings. A `@impl true` on a non-callback, or an unused variable in the new client block, surfaces here.

- [ ] **Step 10: Format and commit**

```bash
mix format lib/wanderer_app/kills/transport/web_socket_client.ex \
  test/unit/kills/transport/web_socket_client_test.exs \
  lib/wanderer_app/kills/client.ex lib/wanderer_app/env.ex config/runtime.exs mix.exs
git add lib/wanderer_app/kills/transport/web_socket_client.ex \
  test/unit/kills/transport/web_socket_client_test.exs \
  lib/wanderer_app/kills/client.ex lib/wanderer_app/env.ex config/runtime.exs mix.exs
git commit -m "fix(kills): forward socket options to the websocket transport

phoenix_gen_socket_client splits transport options on [:extra_headers,
:ssl_verify] only, so :socket_opts fell through into the handler-state argument
and never reached :websocket_client. That made :inet6 unsettable, and Fly's 6PN
.internal addresses are IPv6-only.

Also removes the connect/send/recv timeouts from client.ex. They never applied:
upstream's handler init/1 reads only :keepalive, and websocket_client 1.5.0
hardcodes its connect timeout to 6000ms. They looked adjustable and were not.

Gated on WANDERER_KILLS_IPV6, default false, so non-Fly deployments are
unaffected. phoenix_gen_socket_client pinned because the shim depends on its
private handler-state shape."
```

---

## Task 3: Health endpoint on a dedicated pipeline (non-blocking change 4)

**Why the pipeline matters:** the obvious home is the empty "Health Check Endpoints" scope at `lib/wanderer_app_web/router.ex:374-379`, but that scope is `pipe_through [:api]`, and the `:api` pipeline (`router.ex:171-175`) includes `WandererAppWeb.Plugs.CheckApiDisabled`, which halts with `403` when `WandererApp.Env.public_api_disabled?/0` is true. With `min_machines_running = 1` and no redundancy, chaining machine liveness to a product feature flag means `WANDERER_PUBLIC_API_DISABLED=true` would make Fly kill the **sole** machine — a config toggle becoming a total outage.

The failure is latent, not immediate: `WANDERER_PUBLIC_API_DISABLED` defaults to `"false"` (`config/runtime.exs:57-59`), so it would work on day one and break catastrophically much later. That is the worse shape of bug, which is why the regression test in Step 1 is the important part of this task.

**Files:**
- Create: `lib/wanderer_app_web/controllers/health_controller.ex`
- Modify: `lib/wanderer_app_web/router.ex` (new pipeline near line 171; new scope near line 374)
- Test: `test/wanderer_app_web/controllers/health_controller_test.exs` (create)

**Interfaces:**
- Consumes: `WandererApp.Env.vsn/0` (`lib/wanderer_app/env.ex:14`).
- Produces: `GET /health` returning `200` with `%{"status" => "ok", "version" => String.t(), "database" => "ok" | "unreachable"}`.

**Why the database does not gate the status code.** An earlier draft returned
`503` when Postgres was unreachable. Under `min_machines_running = 1` that hands
Fly a kill signal for a fault Fly cannot repair: restarting the app does nothing
about an external Postgres outage, so a transient blip — a partition, pool
exhaustion, a slow migration — buys a window with zero machines serving traffic
while the database problem continues. The check answers "is this machine
serving?", which it is. Database state is still reported, in the body, where a
human or a dashboard can read it without it being wired to a restart.

- [ ] **Step 1: Write the failing test**

Create `test/wanderer_app_web/controllers/health_controller_test.exs`:

```elixir
defmodule WandererAppWeb.HealthControllerTest do
  use WandererAppWeb.ConnCase

  import WandererApp.EnvHelper

  test "GET /health returns 200 with status, version and database state", %{conn: conn} do
    conn = get(conn, "/health")

    assert %{"status" => "ok", "version" => version, "database" => database} =
             json_response(conn, 200)

    assert is_binary(version)
    assert database == "ok"
  end

  # The reason this route does not live in the :api scope. Fly kills an
  # unhealthy machine, and there is exactly one, so a 403 here is a total
  # outage triggered by a product feature flag. This test is the guard.
  test "GET /health still returns 200 when the public API is disabled", %{conn: conn} do
    with_env_override(:public_api_disabled, true) do
      conn = get(conn, "/health")
      assert %{"status" => "ok"} = json_response(conn, 200)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/wanderer_app_web/controllers/health_controller_test.exs`
Expected: FAIL. Not with `Phoenix.Router.NoRouteError` — `GET /health` currently matches the `live "/:slug", MapLive, :index` wildcard and returns a 302 to `/welcome`, so the failure is `json_response/2` receiving a 302 where it expected 200.

- [ ] **Step 3: Write minimal implementation**

Create `lib/wanderer_app_web/controllers/health_controller.ex`:

```elixir
defmodule WandererAppWeb.HealthController do
  @moduledoc """
  Machine liveness for Fly health checks.

  Answers one question: is this machine serving? It must never gain an
  authentication, rate-limiting, or feature-flag plug — see the `:health`
  pipeline in the router.

  Database reachability is reported in the body but deliberately does not change
  the status code. Fly kills a machine that fails its check, and under
  `min_machines_running = 1` that is the only machine; a restart cannot repair an
  external Postgres outage, so letting the database drive the status code would
  turn a transient blip into a self-inflicted outage.
  """
  use WandererAppWeb, :controller

  # Short on purpose. This endpoint is polled every few seconds; the Repo default
  # of 15s would let a saturated database hold each request open long enough for
  # polls to pile up on top of the problem.
  @db_check_timeout_ms 2_000

  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      version: to_string(WandererApp.Env.vsn()),
      database: if(database_reachable?(), do: "ok", else: "unreachable")
    })
  end

  defp database_reachable? do
    case Ecto.Adapters.SQL.query(WandererApp.Repo, "SELECT 1", [],
           timeout: @db_check_timeout_ms
         ) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    # Most query-level failures come back as an error tuple and are handled
    # above; this catches the ones that raise instead.
    _ -> false
  catch
    # `rescue` does not cover exits. If the connection pool is not alive, the
    # GenServer.call inside DBConnection exits with :noproc or :timeout, which
    # would otherwise crash the request into a 500 — the exact status this
    # endpoint exists to avoid returning for a database fault.
    :exit, _ -> false
  end
end
```

- [ ] **Step 4: Add the pipeline and route**

In `lib/wanderer_app_web/router.ex`, immediately after the `pipeline :api do ... end` block (currently ending at line 175), add:

```elixir
  # Deliberately minimal. Fly kills a machine that fails its health check and
  # there is exactly one machine, so nothing that can be switched off by
  # configuration may appear here — no CheckApiDisabled, no auth, no rate limit.
  pipeline :health do
    plug :accepts, ["json"]
  end
```

Then replace the empty scope at lines 374-379 with:

```elixir
  #
  # Health Check Endpoints
  # Used for monitoring, load balancer health checks, and deployment validation
  #
  # This scope's POSITION IN THE FILE IS LOAD-BEARING. It must stay above the
  # `live "/:slug", MapLive, :index` wildcard further down. Phoenix matches
  # routes in definition order, so below that line `/health` is swallowed by the
  # wildcard and answers 302 to /welcome instead of 200.
  scope "/", WandererAppWeb do
    pipe_through [:health]

    get "/health", HealthController, :index
  end
```

Note this drops the `/api` prefix along with the `:api` pipeline.

`/health` **does** collide with the root LiveView wildcard `live "/:slug", MapLive, :index`, which currently serves `GET /health` as a 302 to `/welcome`. Phoenix matches routes in definition order — there is no rule preferring literal segments over dynamic ones — so this new scope wins only because it is defined earlier in the file. That is why the comment above is there. The two existing tests do double duty as the regression guard: both assert a 200, so either would fail if someone moved this scope below the wildcard.

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/wanderer_app_web/controllers/health_controller_test.exs`
Expected: PASS, 2 tests.

- [ ] **Step 6: Confirm the route is where you think it is**

Run: `mix phx.routes | grep -i health`
Expected: one line, `GET  /health  WandererAppWeb.HealthController :index`.

- [ ] **Step 7: Run the web suite**

Run: `mix test test/wanderer_app_web`
Expected: PASS, no new failures.

- [ ] **Step 8: Format and commit**

```bash
mix format lib/wanderer_app_web/controllers/health_controller.ex \
  lib/wanderer_app_web/router.ex \
  test/wanderer_app_web/controllers/health_controller_test.exs
git add lib/wanderer_app_web/controllers/health_controller.ex \
  lib/wanderer_app_web/router.ex \
  test/wanderer_app_web/controllers/health_controller_test.exs
git commit -m "feat(web): add GET /health on a dedicated pipeline

Returns app version and database reachability, for Fly health checks.

Deliberately not in the :api scope: that pipeline includes CheckApiDisabled,
which halts 403 when WANDERER_PUBLIC_API_DISABLED is set. With
min_machines_running = 1, an unhealthy check kills the only machine, so a
feature flag would become a total outage. The flag defaults to false, so that
failure would have been latent."
```

---

## Task 4: Production-shaped `fly.toml` for wanderer (non-blocking changes 5 and 6)

The existing file is a 2024 scaffold for `wanderer-test` in `ams`. Four problems: wrong app and region, `min_machines_running = 0` (which contradicts the single-machine constraint from the other direction — zero machines means a cold map), a hard-coded `PHX_HOST` that Task 1 has now made load-bearing, and a `[[metrics]]` block scraping `:4021/metrics` when `PROMEX_DISABLED` defaults to `"true"` (`config/runtime.exs:457-459`), so every scrape fails.

**Files:**
- Modify: `fly.toml` (full rewrite)

**Interfaces:**
- Consumes: `GET /health` from Task 3; the `PHX_HOST` / `WEB_APP_URL` precedence from Task 1.
- Produces: the deployable wanderer app configuration.

- [ ] **Step 1: Replace `fly.toml` entirely**

Substitute the operator's real app name for `<WANDERER_APP_NAME>`:

```toml
# fly.toml — wanderer
#
# EXACTLY ONE MACHINE. This is an architectural constraint, not a preference.
# Map state lives in node-local Cachex tables and character trackers register in
# a node-local Registry (WandererApp.Character.TrackerRegistry); PubSub uses the
# PG2 adapter with no clustering configured. Two machines would produce two
# independent halves of the same map — trackers updating on one node, LiveView
# sessions subscribed on the other, and updates that never meet.
#
# Do not add autoscaling, do not raise min/max machines, and do not set
# DNS_CLUSTER_QUERY without first making map state cluster-aware.

app = '<WANDERER_APP_NAME>'
primary_region = 'iad'
kill_signal = 'SIGTERM'
swap_size_mb = 512

[build]

[deploy]
  release_command = '/app/bin/migrate.sh'

[env]
  PHX_SERVER = 'true'
  PORT = '8080'
  # PHX_HOST and WEB_APP_URL are set as secrets, not here: they change at
  # cutover when the staging subdomain is replaced by the production hostname.

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = 'off'
  auto_start_machines = false
  min_machines_running = 1
  processes = ['app']

  [http_service.concurrency]
    type = 'connections'
    hard_limit = 1000
    soft_limit = 1000

  [[http_service.checks]]
    grace_period = '30s'
    interval = '15s'
    method = 'GET'
    path = '/health'
    protocol = 'http'
    timeout = '5s'

[[vm]]
  size = 'shared-cpu-2x'
  memory = '2gb'
```

Note what was removed and why: `PHX_HOST = 'wanderer-test.fly.dev'` (Task 1 made it an override, so leaving it hard-coded would defeat the whole change), and the `[[metrics]]` block (nothing listens on `:4021`; metrics are out of scope and the block is four lines to restore).

The `grace_period` of `30s` is set against the spec's stated 30-60s restart gap. If boot regularly exceeds it, Fly will kill the machine mid-boot in a loop — raise it rather than lowering the check interval.

- [ ] **Step 2: Validate the file**

Run: `fly config validate --config fly.toml`
Expected: `Configuration is valid`.

If `flyctl` rejects `[[http_service.checks]]` or the `grace_period` format, check current Fly documentation rather than assuming this file is right — the schema has changed before.

- [ ] **Step 3: Commit**

```bash
git add fly.toml
git commit -m "chore(fly): production-shaped fly.toml

Real app name, iad, shared-cpu-2x/2gb, min_machines_running = 1 with the
single-machine rationale in a comment, /health check.

Drops the hard-coded PHX_HOST, which would defeat the custom-domain change, and
the [[metrics]] block, which scrapes :4021 while PROMEX_DISABLED defaults true
so every scrape fails."
```

- [ ] **Step 4: Open the pull request for Tasks 1-4**

These four changes are all upstream-suitable — none is zoo-specific — so target the upstream default branch, not `guarzo/zoo`.

```bash
git push -u origin HEAD
gh pr create --repo guarzo/wanderer --fill
```

Remember that a bare `gh pr` command resolves to `wanderer-industries`, not `guarzo`. Always pass `--repo`.

---

## Task 5: Configurable bind address, upstream wanderer-kills (blocking change 3, Option A)

**Why this is blocking:** the client-side `:inet6` fix from Task 2 is necessary but **not sufficient**. Upstream `config/config.exs` sets `http: [port: 4004, ip: {0, 0, 0, 0}]`, and upstream `config/runtime.exs` overrides only the port — there is no `ip:` key and no bind-address environment variable anywhere in it. Fly's 6PN addresses are IPv6 and Fly requires the server to listen on the 6PN address (or on `::`). Without this change, Task 2's fix would connect to an address with no listener.

Submit this early — Task 7 is a checkpoint on whether it landed, and Task 8B exists so the cutover date does not depend on the answer.

**Files (in a separate clone, not this repository):**
- Modify: `config/runtime.exs` in `wanderer-industries/wanderer-kills`

**Interfaces:**
- Produces: environment variable `BIND_IP`, default `"0.0.0.0"`, consumed by Task 8A.

- [ ] **Step 1: Clone your fork of the upstream repository**

You have read access to `wanderer-industries/wanderer-kills`, so this is a fork-and-pull-request. A fork already exists at `guarzo/wanderer-kills`; sync it before branching, since it may be behind.

```bash
git clone git@github.com:guarzo/wanderer-kills.git /tmp/wanderer-kills
git -C /tmp/wanderer-kills remote add upstream https://github.com/wanderer-industries/wanderer-kills.git
git -C /tmp/wanderer-kills fetch upstream
git -C /tmp/wanderer-kills checkout -b feat/configurable-bind-address upstream/main
```

Branching from `upstream/main` rather than the fork's `main` sidesteps a stale fork entirely — you never have to decide whether it needed syncing.

If the upstream default branch is not `main`, use whatever `git -C /tmp/wanderer-kills remote show upstream` reports as HEAD.

- [ ] **Step 2: Read the current endpoint configuration before changing it**

Read `config/config.exs` and `config/runtime.exs` in the clone. Confirm the `http: [port: 4004, ip: {0, 0, 0, 0}]` line and the `PORT`-only override. If either has changed since this plan was written, adapt — the repository is the territory.

- [ ] **Step 3: Add the bind-address override**

In the clone's `config/runtime.exs`, alongside the existing `PORT` handling, add:

```elixir
# Bind address. Defaults to 0.0.0.0 so existing docker-compose deployments are
# unaffected. Set to "::" on platforms whose private networking is IPv6-only —
# Fly.io's 6PN, for instance, where a 0.0.0.0 listener is unreachable from
# sibling apps.
bind_ip =
  System.get_env("BIND_IP", "0.0.0.0")
  |> String.to_charlist()
  |> :inet.parse_address()
  |> case do
    {:ok, address} -> address
    {:error, _} -> raise "BIND_IP must be a valid IP address. Got: #{System.get_env("BIND_IP")}"
  end
```

Then add `ip: bind_ip` to the endpoint's `http:` keyword list in the same file, alongside `port:`.

- [ ] **Step 4: Verify both the default and the override**

```bash
cd /tmp/wanderer-kills && mix deps.get && mix compile
```

Default path — must still bind IPv4:

```bash
cd /tmp/wanderer-kills && MIX_ENV=prod mix run --no-start -e '
  IO.inspect(Application.get_env(:wanderer_kills, WandererKillsWeb.Endpoint)[:http])'
```
Expected: includes `ip: {0, 0, 0, 0}`.

Override path:

```bash
cd /tmp/wanderer-kills && BIND_IP="::" MIX_ENV=prod mix run --no-start -e '
  IO.inspect(Application.get_env(:wanderer_kills, WandererKillsWeb.Endpoint)[:http])'
```
Expected: includes `ip: {0, 0, 0, 0, 0, 0, 0, 0}`.

Adjust the endpoint module name and OTP app atom to match what the clone actually uses.

Invalid path:

```bash
cd /tmp/wanderer-kills && BIND_IP="nonsense" MIX_ENV=prod mix run --no-start -e ':ok'
```
Expected: raises with the `BIND_IP must be a valid IP address` message. Failing loudly at boot beats silently binding IPv4 and leaving a 6PN address unreachable.

- [ ] **Step 5: Add a test if the repository has a config test convention**

Check for existing tests covering `runtime.exs` behaviour. If there is a pattern, follow it. If `runtime.exs` is untested there — likely, since it is not compiled — the Step 4 checks are the verification, and say so in the pull request body.

- [ ] **Step 6: Commit and open the pull request**

```bash
cd /tmp/wanderer-kills
git add config/runtime.exs
git commit -m "feat(config): make the HTTP bind address configurable via BIND_IP

Defaults to 0.0.0.0, so existing deployments are unaffected.

Platforms with IPv6-only private networking — Fly.io's 6PN, for instance —
require the listener to be on the private address or on ::, and a 0.0.0.0
listener is simply unreachable from sibling apps there. There is currently no
way to configure that without patching config/config.exs."
git push -u origin feat/configurable-bind-address
gh pr create --repo wanderer-industries/wanderer-kills \
  --head guarzo:feat/configurable-bind-address --fill
```

`origin` is your fork, so the push does not need upstream write access. `--repo` names the target and `--head <owner>:<branch>` names the source; without both, `gh` guesses from the remote configuration and can open the pull request against your own fork instead.

In the pull request body, note the deployment motivation and confirm the variable name with the maintainer — `BIND_IP` is this plan's proposal, not an established convention in that repository.

---

## Task 6: Provision the Fly apps and measure (Phase 0)

**Operator runbook, not TDD.** No user impact; nothing here is destructive to the running VM.

- [ ] **Step 1: Measure the database**

```bash
psql "$VM_DATABASE_URL" -c "SELECT pg_size_pretty(pg_database_size(current_database()));"
```

- [ ] **Step 2: Time a rehearsal dump *and restore***

```bash
time pg_dump -Fc "$VM_DATABASE_URL" -f /tmp/wanderer-rehearsal.dump
```

**Then time an actual restore into MPG, with the exact flags Task 11 step 5 uses.** Do this after step 4 has provisioned MPG — reorder these steps if necessary. The restore is usually the larger half of the window, and on managed Postgres over the network it can dominate:

```bash
time pg_restore -d "$MPG_DATABASE_URL" --clean --if-exists --no-owner --no-privileges \
  /tmp/wanderer-rehearsal.dump
```

**The two timings together are the outage window.** Timing only the dump advertises a window that excludes most of the work. Record the sum; Task 11 step 3 announces it to users.

This rehearsal restore also doubles as the staging restore in Task 10 step 1 — the data is the same, so there is no reason to do it twice.

- [ ] **Step 3: Measure the kills service's memory**

```bash
docker stats --no-stream wanderer-kills
```

Sample over a representative period, not once. The 2 GB figure in the spec is a starting estimate, not a measurement: the service ingests EVE-wide killmails with a 24-hour TTL, and the resident set could plausibly range from a few hundred MB to over 1 GB. Under-sizing presents as OOM restarts.

- [ ] **Step 4: Create both apps and the database**

```bash
fly apps create <WANDERER_APP_NAME>
fly apps create <KILLS_APP_NAME>
fly mpg create --region iad          # PostgreSQL >= 15
```

Confirm the MPG version is >= 15 before continuing — `WandererApp.Repo.min_pg_version/0` requires it and a lower version fails at migration time, not at provision time.

- [ ] **Step 5: Confirm the kills app has no public IP**

```bash
fly ips list --app <KILLS_APP_NAME>
```
Expected: empty. If `fly apps create` allocated one, release it. The service is private-only; plain `ws://` is correct because 6PN is a WireGuard mesh encrypted at the network layer.

- [ ] **Step 6: Set the wanderer secrets**

```bash
fly secrets set --app <WANDERER_APP_NAME> \
  SECRET_KEY_BASE=... \
  EVE_CLIENT_ID=... \
  EVE_CLIENT_SECRET=... \
  WANDERER_ADMIN_PASSWORD=... \
  WEB_APP_URL=https://<staging-subdomain> \
  DATABASE_URL=... \
  ECTO_IPV6=true \
  WANDERER_KILLS_SERVICE_ENABLED=true \
  WANDERER_KILLS_BASE_URL=ws://<KILLS_APP_NAME>.internal:4004 \
  WANDERER_KILLS_IPV6=true
```

Three of these are new or newly load-bearing:

- `WANDERER_KILLS_SERVICE_ENABLED` **defaults to `"false"`** (`config/runtime.exs:67-70`). Omit it and neither `WandererApp.Kills.Supervisor` nor `WandererApp.Map.ZkbDataFetcher` starts at all (`lib/wanderer_app/application.ex:226-238`) — kills are silently off with no error anywhere.
- `WANDERER_KILLS_BASE_URL` must be the `.internal` address under Option A, or `ws://<KILLS_APP_NAME>.flycast:4004` under Option B.
- `WANDERER_KILLS_IPV6=true` activates Task 2's change.

Add any additional EVE client pairs the VM uses. Do **not** blanket-copy the VM's remaining feature flags yet — Task 10 audits them for outbound effects first.

- [ ] **Step 7: Create the staging EVE application**

**RESOLVED 2026-08-05: an EVE application permits exactly one redirect URL.** A
second EVE application is therefore *required* for the staging period, not merely
preferred — staging cannot share production's application at any point.

That also happens to be the safer arrangement, for the reason Task 10 step 2a
gives: a staging instance that refreshes a production character's token
invalidates it and logs real users out of the live map. Separate applications
means separate client IDs, so this cannot happen by accident.

Create it now and record both credential pairs. Callback URLs, from
`config/config.exs:53` (`callback_path: "/auth/eve/callback"`):

- staging application → `https://<staging-subdomain>/auth/eve/callback`
- production application → `https://<production-hostname>/auth/eve/callback`, which
  is what it is already set to today

Note what this means for the cutover: the production hostname does not change
when DNS moves to Fly, so the production application's redirect URL needs **no
edit at any point in the migration**. Task 11 step 6 swaps the client ID and
secret secrets on the Fly app; nothing in the EVE developer portal is touched.

---

## Task 7: RESOLVED — Option A, deploying from the fork

**Decision gate, closed on 2026-08-05. No code.** This task no longer requires
a check; it records a decision already made.

**Original gate:** whether Task 5's `BIND_IP` change had merged upstream in time
for the cutover window. If not, Option B (Flycast) avoided needing `BIND_IP` at
all.

**What changed:** the kills app is deployed by building from a source checkout —
Task 8A's `fly.toml` has an empty `[build]` section and deploys with
`fly deploy --config .../fly.toml`, so Fly builds the Dockerfile from the working
tree. Nothing pulls a published upstream image. The upstream merge was therefore
never on the critical path for *deploying*; it only determined whether we carry a
local patch.

`guarzo/wanderer-kills` was already ahead of upstream (it carries the
Elixir 1.19.5 / OTP 28 dependency refresh, merged there as #6 and still pending
upstream as #8), so a fork-based deploy adds no new maintenance posture.
`feat/configurable-bind-address` was merged into that fork's `main` as `5756469`
— a clean merge, verified conflict-free with `git merge-tree` beforehand.

A third divergence landed on 2026-08-05: a fix for a nil telemetry measurement
that crash-loops the metrics GenServer and, past the supervisor's restart
intensity, shuts down the whole application tree. It is on the fork as PR #8 and
upstream as
[wanderer-industries/wanderer-kills#10](https://github.com/wanderer-industries/wanderer-kills/pull/10).
This one is a deploy prerequisite, not just hygiene — the crash is reachable in
production from any sustained burst of reserved-token consumption against
zKillboard, which is exactly what a cold-start backfill produces.

**Ruling: Option A. Deploy the kills app from `guarzo/wanderer-kills:main`.**
Task 8B is struck (see below). Upstream PR
[wanderer-industries/wanderer-kills#9](https://github.com/wanderer-industries/wanderer-kills/pull/9)
stays open; when it merges, this fork's divergence drops back toward zero and the
merge commit becomes a no-op. Nothing about the cutover date depends on it.

**Consequence to carry into Task 9:** the deploy source is the fork, not a
clone of upstream. Clone `https://github.com/guarzo/wanderer-kills.git` and
deploy from its `main`. Merging upstream's changes into that fork periodically is
now an ongoing obligation — the service ingests from zKillboard and ESI, so
upstream data-source fixes matter.

**Verification debt:** the `BIND_IP` IPv6-bind evidence was gathered on
ranch 2.2.0 / cowboy 2.13.0 / plug_cowboy 2.7.4 / phoenix 1.7.21. The fork's
refresh moves these to ranch 2.2.1 / cowboy 2.18.0 / plug_cowboy 2.9.0 /
phoenix 1.8.9. See `.superpowers/sdd/2026-08-04-flyio-migration/fork-verify-report.md`
for the re-verification on the merged tree, and note what it does and does not
cover — the CI container runs OTP 26 while the image builds on OTP 28.

---

## Task 8A: `fly.toml` for wanderer-kills — direct 6PN (Option A only)

Task 7 chose Option A, so this task runs. Task 8B is struck.

**Deploy source is the fork, not upstream.** Clone
`https://github.com/guarzo/wanderer-kills.git` and work from its `main`, which
carries `BIND_IP` as merge `5756469`.

Keep the file **operator-agnostic** anyway: no hard-coded app name, `app` supplied
at deploy time. The fork is a staging post, not the destination — this file should
stay upstreamable so it can go to `wanderer-industries` alongside PR #9 rather
than becoming fork-only drift.

**Files:**
- Create: `fly.toml` in the fork clone (paths below say `/tmp/wanderer-kills`;
  that clone is now on the fork's `main`)

**Interfaces:**
- Consumes: `BIND_IP` from Task 5.
- Produces: an app reachable at `<KILLS_APP_NAME>.internal:4004` over 6PN.

- [ ] **Step 1: Create the file**

```toml
# fly.toml — wanderer-kills
#
# Deploy with:  fly deploy --app <your-app-name>
# The app name is deliberately not set here: this file is shared upstream.
#
# EXACTLY ONE MACHINE. The service's cache is node-local Cachex, so two machines
# would serve different answers depending on which one a subscription landed on.
# auto_stop_machines must stay off because a stopped machine drops the websocket
# its consumers hold open.
#
# No public IP. Reachable only over 6PN at <app>.internal:4004. That is why
# BIND_IP is "::" — a 0.0.0.0 listener cannot receive a 6PN connection.

primary_region = 'iad'
kill_signal = 'SIGTERM'

[build]

[env]
  PORT = '4004'
  BIND_IP = '::'

[[vm]]
  size = 'shared-cpu-2x'
  memory = '2gb'          # starting figure — see Task 6 step 3

# Top-level [checks], not [[services.*.checks]]: this app has no public service
# definition, and top-level checks do not require one.
[checks]
  [checks.health]
    type = 'http'
    port = 4004
    path = '/health'
    interval = '15s'
    timeout = '5s'
    grace_period = '30s'
```

Note there is no `[http_service]` and no `[[services]]` block — that is what keeps the app off the public internet.

- [ ] **Step 2: Verify the TOML against current Fly documentation**

Run: `fly config validate --config /tmp/wanderer-kills/fly.toml --app <KILLS_APP_NAME>`
Expected: `Configuration is valid`.

Fly's schema for top-level `[checks]` has changed before, and the `min_machines_running` / `auto_stop_machines` keys live under a service block, which this app does not have. Confirm the current mechanism for pinning a service-less app to one always-on machine — it may be `fly scale count 1` plus `fly machine update --restart always` rather than a TOML key. **Do not assume this file is complete on the strength of this plan.**

- [ ] **Step 3: Deploy and confirm it is private**

```bash
fly deploy --config /tmp/wanderer-kills/fly.toml --app <KILLS_APP_NAME>
fly ips list --app <KILLS_APP_NAME>          # expected: empty
fly status --app <KILLS_APP_NAME>            # expected: exactly one machine, started
```

- [ ] **Step 4: Confirm the IPv6 listener exists**

This is the step that proves Task 5 worked. Do not skip it — an IPv4-only listener is invisible until the websocket silently fails.

```bash
fly ssh console --app <KILLS_APP_NAME> -C "ss -ltnp"
```
Expected: a listener on `[::]:4004` or on the machine's 6PN address, **not** `0.0.0.0:4004`.

- [ ] **Step 5: Confirm 6PN reachability from the wanderer app**

```bash
fly ssh console --app <WANDERER_APP_NAME> -C \
  "curl -sS -m 5 http://<KILLS_APP_NAME>.internal:4004/health"
```
Expected: a healthy response body.

- [ ] **Step 6: Commit the file to your fork**

```bash
cd /tmp/wanderer-kills
git add fly.toml
git commit -m "chore(fly): add an operator-agnostic fly.toml

One machine (node-local Cachex cache), no public IP, 6PN-only on 4004, health
check against the existing /health endpoint. App name is supplied at deploy
time so the file is usable by any operator."
git push
```

Still `origin`, still your fork — this is the same branch as Task 5, so `git push` with no arguments follows the upstream tracking set there. Fold it into the Task 5 pull request or open a second one from a fresh branch, as the maintainer prefers.

If you deployed from this clone before committing, confirm you are not also pushing local experiments: `git -C /tmp/wanderer-kills status --short` should show nothing but the file you just committed.

---

## Task 8B: STRUCK — Flycast fallback (not needed)

**Struck 2026-08-05. Do not execute.** This task existed only so the cutover
date would survive Task 5's `BIND_IP` change not landing upstream: Flycast routes
through the Fly proxy, which forwards to `internal_port` locally, so the
service's existing `{0, 0, 0, 0}` bind would have kept working without any
upstream change.

Task 7 resolved to **Option A** — the kills app deploys from
`guarzo/wanderer-kills:main`, which carries `BIND_IP` as merge `5756469`. The
contingency this task hedged against cannot occur, so building it would be dead
work: an extra proxy hop and a `[[services]]` block that Option A does not need.

The original steps remain in git history if Option B is ever revived (for
example, if the fork is abandoned in favour of an unpatched upstream image before
PR #9 merges). Retrieve them with:

```bash
git log --oneline -- docs/superpowers/plans/2026-08-04-flyio-migration.md
git show <commit-before-this-one>:docs/superpowers/plans/2026-08-04-flyio-migration.md
```

Note if you do revive it: the client-side `:inet6` change from Task 2 is required
under **both** options — the Flycast address is IPv6 too.
## Task 9: Deploy and warm the kills app (Phase 1, first half)

**Operator runbook, not TDD.**

The dependency is one-directional — wanderer subscribes to kills and tells it which systems to watch; kills never calls back. So this app can be deployed and left running to warm its cache **hours before** the cutover window opens, because nothing consumes it until wanderer points at it. The "same window" constraint applies only to the traffic switch, not to the deploy.

- [ ] **Step 1: Confirm the app is running and healthy**

```bash
fly status --app <KILLS_APP_NAME>
fly logs --app <KILLS_APP_NAME>
```
Expected: exactly one machine, started, `/health` passing.

- [ ] **Step 2: Leave it running**

Give it time to ingest from zKillboard and ESI. It is stateless and rebuilds from those sources on boot; there is no database to provision and nothing to dump or restore.

- [ ] **Step 3: Watch memory against the Task 6 measurement**

```bash
fly machine status <MACHINE_ID> --app <KILLS_APP_NAME>
```

If it approaches the 2 GB allocation, `fly scale vm` now rather than during the cutover window. OOM restarts do not take wanderer down — the client degrades rather than crashing — but they do drop kill data.

---

## Task 10: Staging validation with staging-safe configuration (Phase 1, second half)

**Operator runbook, not TDD.** This is the highest-risk task in the plan and the only one whose mistakes reach real users irreversibly.

Staging runs a copy of production data **while production is still live**. That data carries live credentials and live outbound integrations, so an unmodified staging instance reaches into production's world. **Configure everything in Step 2 before the first boot against restored data, not after.**

This is one Fly app throughout, not two: it first serves the staging subdomain, then has the production hostname added and the staging one removed. The single kills app serves both periods — being stateless and private, it needs no staging duplicate.

- [ ] **Step 1: Restore a throwaway copy of production data into MPG**

```bash
pg_dump -Fc "$VM_DATABASE_URL" -f /tmp/wanderer-staging.dump
pg_restore -d "$MPG_DATABASE_URL" --no-owner --no-privileges /tmp/wanderer-staging.dump
```

`WandererApp.Repo.installed_extensions/0` returns only `["ash-functions"]` and no migration issues `CREATE EXTENSION` (`lib/wanderer_app/repo.ex:5-8`), so there is no native-extension risk here.

This copy is for validation only and is discarded at cutover.

- [ ] **Step 2: Apply the staging-safe configuration — mandatory**

**a. Use the separate staging EVE application.** This is the sharpest edge in the whole migration. `refresh_token/1` (`lib/wanderer_app/esi/api_client.ex:746`) reads a character's refresh token and persists the rotated result back via `WandererApp.Api.Character.update`. Because EVE rotates refresh tokens, a staging instance refreshing a character that production also tracks **invalidates production's token and logs real users out of the live map**. Set the staging EVE client ID and secret created in Task 6 step 7, and do not track production characters from staging.

**b. Disable the outbound dispatchers.** `lib/wanderer_app/external_events/` contains `webhook_dispatcher.ex` and `discord_dispatcher.ex`, and the restored dump carries live destination rows. Left enabled, staging duplicates every notification your users receive. Turn the external events services off via configuration.

**c. Scrub the destination rows in the restored copy.** Belt and braces — the blast radius is other people's Discord servers, so configuration alone is not enough:

```sql
DELETE FROM map_webhook_subscriptions_v1;
DELETE FROM map_discord_webhooks_v1;
DELETE FROM map_discord_notifications_v1;
```

The table names are versioned and plural — they come from the `postgres do table(...) end` blocks in `lib/wanderer_app/api/map_webhook_subscription.ex:16`, `map_discord_webhook.ex:33`, and `map_discord_notification.ex:16`, which do not match the resource module names. Verify them against those files before running, because a typo here fails loudly *without* having removed anything, leaving you believing staging is scrubbed when it is not.

Run this against the **MPG copy**, never against the VM database. Confirm the connection string before pressing enter.

**d. Audit the remaining feature flags before copying them.** "Copy whatever the VM sets" is not safe as a blanket instruction; check each for outbound effects.

This is the one place the plan deliberately does not validate production behaviour faithfully. The tradeoff is accepted: a staging instance that mails real users is worse than one that proves slightly less.

- [ ] **Step 3: Deploy wanderer and point the staging subdomain at Fly**

**Pre-flight — read before the first `fly deploy` of wanderer.** This is the
first time `release_command` runs, and two independent failure modes live in
that window. Both were found by review, not by deploying.

*a. Secrets must exist before the first deploy, or the release step fails.*
`release_command = '/app/bin/migrate.sh'` runs in a separate temporary Machine.
`migrate.sh` calls `bin/wanderer_app eval`, which evaluates `config/runtime.exs`,
which raises without `SECRET_KEY_BASE` (`config/runtime.exs:409-414`). So
`SECRET_KEY_BASE` and `DATABASE_URL` must already be set with `fly secrets set`
before this command, not after. `release_command` also has a **default 5-minute
timeout** — if the migration set is large, raise it explicitly rather than
discovering the cap mid-deploy.

*b. If the app machine crashloops while migrations succeeded, suspect the release
script, not the app.* `release_command` runs `eval`, which passes **no**
distribution flags; the app machine starts with `--name`. On Fly,
`rel/env.sh.eex` builds `RELEASE_NODE` from the IPv6 `FLY_PRIVATE_IP`, so it
needs `-proto_dist inet6_tcp`. That flag was commented out in `ee15d90f9` and
restored (inside the Fly branch only) on this branch. If someone re-removes it,
the deploy gets **past** the release step and then crashloops at the health
check — migrations green, app dead. Do not debug the migration; check
`rel/env.sh.eex` first.

```bash
fly deploy --app <WANDERER_APP_NAME>
fly certs add <staging-subdomain> --app <WANDERER_APP_NAME>
```
Then create the DNS record and wait for the certificate to issue.

- [ ] **Step 4: Run all eight verification gates**

Every gate must pass here, and again on production data after cutover.

1. **EVE OAuth round-trip** — log in with a character and get redirected back. Most likely thing to break: it depends on Task 1, the `WEB_APP_URL` secret, and the EVE callback all agreeing.
2. **Map loads with real data** — systems, connections, and signatures render from the restored dump. Validates dump/restore, not just connectivity.
3. **Character tracking writes** — a tracked character's location updates. Exercises ESI egress from Fly, token refresh, tracker pools, and DB writes. **On staging this must use a dedicated test character**, registered against the staging EVE application and not tracked by production. Using a real user's character here rotates their refresh token and logs them out of the live map.
4. **Real-time updates arrive** — a change appears without a refresh. Proves the PubSub → LiveView path survived.
5. **Kills websocket reaches `connected`** — check `WandererApp.Kills.get_status/0` via `fly ssh console` and a remote IEx session. This is the gate that proves Tasks 2, 5, and 8; it is the single most likely thing to fail, and **it fails silently**. Confirm explicitly rather than inferring from the absence of errors: after `@max_retries 10` the client stops retrying and falls back to a 15-minute health-check cycle (`lib/wanderer_app/kills/client.ex:19-30`), so a broken link looks exactly like a quiet one.
6. **Killmails render in the map UI** — kill data appears on a system with recent activity. Proves subscription, ingest, storage, and broadcast, not merely that a socket opened.
7. **Release migrations ran clean** — `interweave_migrate` completed with no pending migrations. Check the release command output in `fly logs`.
8. **Restart survivability** — `fly machine restart` on **both** apps, then confirm the map rehydrates from Postgres and the kills client reconnects. This is the deploy rehearsal; every deploy is a restart with a 30-60s user-visible gap.

- [ ] **Step 5: Do not proceed until all eight pass**

Gate 5 in particular. A cutover with a silently broken kills link presents to users as "kill data stopped working", with no error and no alarm.

---

## Task 11: Production cutover (Phase 2)

**Operator runbook, not TDD. Planned outage.** Ordered so that nothing writes to two databases at once.

- [ ] **Step 1: Lower the DNS TTL and pre-provision the production certificate**

At least a day ahead. Not inside the window.

```bash
fly certs add <production-hostname> --app <WANDERER_APP_NAME>
fly certs show <production-hostname> --app <WANDERER_APP_NAME>
```

**Issue the certificate before any traffic is directed at Fly.** Fly supports this explicitly: use the DNS-01 challenge, adding the `_acme-challenge` CNAME that `fly certs show` prints, so the hostname can be validated while it still resolves to the VM. An HTTP-01 challenge would require the hostname to already point at Fly, which forces certificate issuance into the outage window — where an ACME delay or a DNS propagation lag becomes downtime with no way forward and no clean way back.

Gate on readiness before opening the window:

```bash
fly certs check <production-hostname> --app <WANDERER_APP_NAME>
```
Expected: the certificate reports as Ready / issued. **Do not start the cutover until it does.**

- [ ] **Step 2: Confirm the kills app is up and its cache warm**

Before the window, not inside it.

```bash
fly status --app <KILLS_APP_NAME>
```

- [ ] **Step 3: Announce the window, then stop wanderer on the VM**

```bash
docker compose stop wanderer
```

Writes cease here, which is what makes the dump consistent. **Leave Postgres and the VM's kills container running** — the kills container is part of the rollback path.

- [ ] **Step 4: Scale the Fly wanderer app to zero and confirm no machine is running**

```bash
fly scale count 0 --app <WANDERER_APP_NAME>
fly status --app <WANDERER_APP_NAME>          # expected: zero machines running
```

**Mandatory and easy to overlook.** After Task 10 the Fly app is *live* against MPG, and its tracker pools write character locations every 10-30s with no user interaction at all. Restoring into a database that still has an application attached risks `pg_restore` conflicts and, worse, silently interleaves staging-era background writes into the restored production data.

The app stays stopped through steps 5 and 6.

- [ ] **Step 5: Dump the live VM database and restore into MPG**

```bash
pg_dump -Fc "$VM_DATABASE_URL" -f /tmp/wanderer-cutover.dump
pg_restore -d "$MPG_DATABASE_URL" --clean --if-exists --no-owner --no-privileges \
  /tmp/wanderer-cutover.dump
```

This replaces the staging copy. Confirm the target connection string before pressing enter — `--clean` is destructive by design.

- [ ] **Step 6: Swap staging configuration for production configuration**

Still with the app stopped. The certificate was issued in step 1, so nothing here waits on ACME:

```bash
fly certs check <production-hostname> --app <WANDERER_APP_NAME>   # must still be Ready
fly secrets set --app <WANDERER_APP_NAME> \
  WEB_APP_URL=https://<production-hostname> \
  EVE_CLIENT_ID=<production> \
  EVE_CLIENT_SECRET=<production>
```

Re-enable the outbound dispatchers disabled in Task 10 step 2b. **No change is needed in the EVE developer portal** — the production application's redirect URL already points at the production hostname, which does not change when DNS moves to Fly. Staging used a separate application (Task 6 step 7), so its callback is irrelevant from here on.

Walk Task 10 step 2 in reverse, item by item. Anything left in its staging state is a production defect — notifications silently not sending is the likely shape.

- [ ] **Step 7: Run the migrations against the restored database — do not skip**

**The restore in step 5 rolled MPG's schema back to whatever the VM was running.** Task 10's staging deploy migrated MPG forward; `pg_restore --clean` erased that. If the release being deployed is newer than the VM's schema — which it is, since it carries Tasks 1-3 — production would otherwise boot against an outdated schema.

`fly scale count` does **not** run `[deploy].release_command`. Fly executes that only during a deploy. Scaling from zero to one starts the machine and nothing else, so the migration must be run explicitly.

Preferred — a one-off machine, so migrations are verifiable before anything starts serving:

```bash
fly machine run --app <WANDERER_APP_NAME> \
  --command "/app/bin/migrate.sh" \
  --rm \
  <IMAGE_REF>
```

Take `<IMAGE_REF>` from `fly releases --app <WANDERER_APP_NAME> --image`, or from the image the Task 10 deploy produced.

Acceptable alternative — a controlled deploy, which runs `release_command` in a temporary machine and then starts the app. This merges step 7 and step 8 into one command, so read step 8's warning before running it:

```bash
fly deploy --app <WANDERER_APP_NAME>
```

Either way, **confirm `interweave_migrate` completed with no pending migrations before continuing** (verification gate 7). Check the output directly; do not infer success from the absence of an error.

Note this does not affect the rollback story. Migrations alter the MPG copy, not the VM's Postgres, which remains the rollback target and is untouched.

- [ ] **Step 8: Start the Fly app — THIS IS THE COMMIT POINT**

```bash
fly scale count 1 --app <WANDERER_APP_NAME>
```

**The point of no return is here, not at the DNS switch.** Tracker pools write character locations every 10-30s from the moment the app boots, with no user interaction required, so the window in which rollback is lossless closes **within seconds of this command** — before any user has logged in. After this, rolling back loses whatever was written since.

Before running it, confirm steps 6 and 7 are both complete.

- [ ] **Step 9: Flip DNS to Fly, then re-run all eight gates**

Re-run the Task 10 step 4 gates against production data. Gate 3 now legitimately uses a real character; gates 5 and 6 are the ones that prove the kills link survived the configuration swap.

- [ ] **Step 10: Stop the rest of the VM stack**

Only after step 9 passes. Stop the VM's kills container and the remaining services, but **do not delete anything** — see Task 12.

wanderer-notifier stays on the VM, reachable over the public internet, and is migrated as separate work.

---

## Task 12: Rollback procedure (reference — execute only if needed)

**Not a step to perform. Read before Task 11 so it is familiar under pressure.**

While the VM's Postgres is still the newer copy — that is, before Task 11 step 8 — rollback is:

```bash
docker compose start wanderer wanderer-kills
# then flip DNS back
```

**Restart both containers, not just wanderer.** The Fly kills app is private-only, so a VM-resident wanderer cannot reach it. The VM's own kills container must come back up too. This is why Task 11 step 3 leaves it running and Task 11 step 10 only stops it at the very end.

After Task 11 step 8, rollback loses every write since that command. Treat step 8 as the commit point, not step 9.

Note that Task 11 step 7's migrations are **not** part of the point of no return: they alter the MPG copy, not the VM's Postgres. Rolling back after migrating but before starting is still lossless.

Keep the entire VM stack intact but stopped for roughly a week after cutover. Do not delete volumes.

---

## Task 13: Post-cutover follow-up

- [ ] **Step 1: Confirm the notifier still delivers**

It stayed on the VM and reaches the new host over the public internet.

- [ ] **Step 2: Watch the kills link for the first few days**

Kills failure is silent and self-limiting: after `@max_retries 10` the client stops retrying and falls back to a 15-minute health-check cycle. A prolonged outage presents as "kill data quietly stopped", not as an error. Check `WandererApp.Kills.get_status/0` periodically. Proper monitoring is a follow-up, out of scope here.

- [ ] **Step 3: Watch ESI rate limiting**

Rate limiting is per-source-IP, the egress IP has changed, and now *two* services call ESI from the same Fly organisation — the kills service being the heavier consumer. Not expected to matter at private-corp scale, but it is a changed variable.

- [ ] **Step 4: Right-size the kills machine**

Compare actual resident memory against the 2 GB allocation and adjust with `fly scale vm`.

- [ ] **Step 5: Retire the VM**

After roughly a week of clean operation. Caddy, the docker-compose wanderer and wanderer-kills containers, and the host Postgres all go. The `WEB_EXTERNAL_SCHEME` / `HTTPS_PORT` / `/certs/*` branch in `config/runtime.exs:429-443` becomes dead config on Fly but is left in place, as it is upstream-shared code.

- [ ] **Step 6: If Option B was chosen, revisit Option A**

Once the upstream `BIND_IP` pull request from Task 5 lands and releases, switching from Flycast to direct 6PN removes a proxy hop and the `[[services]]` block. Low priority, but it closes the loop.

- [ ] **Step 7: Delete the transport shim when upstream fixes it**

If `phoenix_gen_socket_client` adds `:socket_opts` to `@websocket_client_opts`, `WandererApp.Kills.Transport.WebSocketClient` can be deleted and `mix.exs` unpinned. Submit that one-word change upstream if it has not been already.

---

## Task 14: Write the deployment guide so other operators can reproduce this

**The guide does not live in this repository.** Self-hosting instructions live in `wanderer-industries/community-edition` — this repo's `README.md:29` already sends self-hosters there, and that repo describes itself as "Example Docker Compose setup for hosting Wanderer Community Edition". A Fly.io guide checked in here would be a second, competing home for the same audience, and the readers who need it are precisely the ones who never clone this repo.

That repo is organised as **one topic subdirectory per deployment concern, each with its own `README.md`** — `reverse-proxy/`, `scripts/`, `advanced/` — with `docker-compose.yml` and `wanderer-conf.env` at the root. Follow that convention exactly: a new `fly-io/` directory, its `README.md` as the guide, and the two `fly.toml` files beside it as copy-and-edit templates, the way `reverse-proxy/` ships working `nginx`, `apache2`, `caddy-gen`, and `traefik` configs rather than describing them.

**Repository:** `wanderer-industries/community-edition` (default branch `main`). You have read access, so this is a fork-and-pull-request, not a direct push. A fork already exists at `guarzo/community-edition`.

**Files (all in the community-edition clone):**
- Create: `fly-io/README.md`
- Create: `fly-io/fly.toml`
- Create: `fly-io/fly-kills.toml`
- Modify: `README.md` (one link, in the same list as the existing `reverse-proxy/` and `scripts/` entries)

Nothing in the `wanderer` repository changes in this task.

- [ ] **Step 1: Clone the fork and branch**

```bash
cd /tmp
git clone git@github.com:guarzo/community-edition.git
cd community-edition
git remote add upstream https://github.com/wanderer-industries/community-edition.git
git fetch upstream
git checkout -b feat/fly-io-deployment upstream/main
mkdir fly-io
```

Read `reverse-proxy/README.md` and `scripts/README.md` first and match their register — they are short, imperative, and assume a competent operator who has not read the source. This guide is longer because the migration path is longer, but the voice should not change.

- [ ] **Step 2: Add the two `fly.toml` templates**

Copy the final files from Task 4 (`fly.toml` → `fly-io/fly.toml`) and Task 8A or 8B, whichever the Task 7 checkpoint selected (kills `fly.toml` → `fly-io/fly-kills.toml`). Then make them operator-agnostic:

- `app` becomes `wanderer` and `wanderer-kills`.
- `primary_region` gets a comment saying to pick a region near your users and near your database, not to copy this one.
- Every comment justifying a value stays. The single-machine comment in particular is the reason the file is shaped this way, and a reader who deletes it will later delete the constraint.

Run: `grep -nE "wanderer-test|iad|ams" fly-io/fly.toml fly-io/fly-kills.toml`
Expected: region names appear only inside comments or as clearly-labelled examples; no `wanderer-test`.

- [ ] **Step 3: Write `fly-io/README.md`**

**Write this while Tasks 6-13 are fresh, not weeks later.** The value is in the details that only surface during a real run — the actual outage timings, the `flyctl` commands that turned out to need different flags, the step that was ambiguous at 2am. Draft as you go; finalise here.

Write it for someone who has never seen the `wanderer` source, has no access to your Fly organisation, and is not migrating from your VM. Strip every operator-specific value.

Cover, in this order:

1. **What you get** — two Fly apps and managed Postgres, replacing a docker-compose VM. State up front that this is a **single-machine** deployment and why, because that is the constraint most likely to be "optimised" away by a reader who skims. Point at `lib/wanderer_app/character/tracker_registry.ex` and the Cachex map state rather than asserting it.
2. **Prerequisites** — a Fly account, `flyctl`, a domain, EVE SSO application credentials, PostgreSQL >= 15.
3. **Environment variables** — a table of every variable the deployment needs, its default, and what breaks if it is wrong. Give `WANDERER_KILLS_SERVICE_ENABLED` its own callout: it defaults to `false`, and omitting it disables kills **silently, with no error anywhere**. That is the single most likely way a reader's deployment ends up quietly missing a feature.
4. **The two `fly.toml` files** — point at `fly.toml` and `fly-kills.toml` beside the README rather than pasting them inline, so there is one copy to keep correct. Explain what a reader must change in each (`app`, `primary_region`, memory) and what they must not (the single-machine settings).
5. **Private networking** — 6PN versus Flycast, why plain `ws://` is correct (WireGuard encrypts at the network layer), and the `BIND_IP` requirement. Include the `ss -ltnp` check from Task 8A step 4; a reader who binds IPv4-only gets a silent failure and no way to diagnose it from the logs.
6. **Fresh install** — the path for someone with no existing data. This is most readers, and it is much shorter: create apps, set secrets, deploy. It comes *before* the migration path for that reason.
7. **Migrating from docker-compose** — Tasks 6 and 9-13 generalised. Keep the ordering rationale, not just the commands: why the app scales to zero before the restore, why migrations must be run explicitly because `fly scale` does not run `release_command`, and why the commit point is starting the app rather than flipping DNS.
8. **Staging safely against a copy of production data** — Task 10 step 2 nearly verbatim. This is the section most likely to save a reader from harming their own users, particularly the EVE refresh-token rotation. Keep the reasoning; a bare checklist invites skipping.
9. **Verification** — the eight gates.
10. **Rollback.**
11. **Known limitations** — deploys are user-visible for 30-60s; kills failure is silent and self-limiting; single-machine means no HA.

- [ ] **Step 4: Scrub it for operator-specific values**

Run: `grep -nE '<WANDERER_APP_NAME>|<KILLS_APP_NAME>|fly\.dev|\.internal|\.flycast' fly-io/README.md`

Every match must be a placeholder or a generic example. Then check by eye for anything that leaked from your own run:

Run: `grep -rniE 'wanderer-test|[0-9]{1,3}(\.[0-9]{1,3}){3}' fly-io/`
Expected: no real hostnames, no real IPs, no real app names, no corporation names, no character names. This sweeps the two `fly.toml` files as well as the README — the templates are the likelier place for a leak, since they are copied from a working deployment rather than written from scratch.

This matters more here than it would in your own repository. `community-edition` is a public example repo that people copy verbatim; a leaked hostname becomes someone else's misconfiguration.

- [ ] **Step 5: Have someone follow it who did not write it**

The only real test of a deployment guide. A fresh install on a throwaway Fly app is enough — the migration path cannot be rehearsed by a third party, so mark that section as reviewed-not-executed rather than implying it was tested.

Every question they have to ask you is a defect in the document. Fix it rather than answering it.

- [ ] **Step 6: Link it from the community-edition README**

Add `fly-io/` to the same list that already points at `reverse-proxy/`, `scripts/`, and `advanced/`. Match the surrounding phrasing; read the existing entries before writing yours.

One sentence of framing earns its place: this is an alternative to the docker-compose setup the rest of the repository documents, not an addition to it. Readers arriving at that repo are there for docker-compose, and a link with no context reads as a supplementary step rather than a fork in the road.

- [ ] **Step 7: Commit and open the pull request**

```bash
git add fly-io/README.md fly-io/fly.toml fly-io/fly-kills.toml README.md
git commit -m "docs: add a Fly.io deployment option

Covers fresh installs and migration from docker-compose, templates for both
the wanderer and wanderer-kills apps, 6PN versus Flycast private networking,
and the staging-safety steps needed when validating against a copy of
production data.

Written from an actual migration, so the outage timings and the failure modes
are measured rather than estimated."
git push -u origin feat/fly-io-deployment
gh pr create --repo wanderer-industries/community-edition \
  --title "docs: add a Fly.io deployment option" \
  --body "Adds fly-io/ alongside reverse-proxy/ and scripts/, following the same one-directory-per-topic layout. Written from a real migration off docker-compose, so the timings and failure modes are measured."
```

`--repo` is not optional. A bare `gh pr create` in a fork resolves to the upstream repository in some configurations and to the fork in others; state the target explicitly rather than depending on which.

- [ ] **Step 8: Offer the wanderer-kills half upstream**

The Fly-specific parts of the kills setup — `BIND_IP`, the `fly.toml`, the 6PN and Flycast options — are useful to any operator of that service, not just Wanderer users. Offer them as a deployment section in the `wanderer-industries/wanderer-kills` README, alongside the Task 5 pull request.

Keep `fly-io/fly-kills.toml` in community-edition even if that lands. A Wanderer self-hoster should not have to visit a second repository to bring up a hard dependency, and the duplication is one small file.

## Open items

Both must be closed before the tasks that depend on them; neither blocks Tasks 1-4.

- **EVE SSO callbacks** — Task 6 step 7. Whether the developer portal allows multiple callback URLs per application determines whether a second EVE application is *required*. A second one is *wanted* regardless, for credential isolation during staging.
- **Kills memory sizing** — Task 6 step 3. The 2 GB figure in Tasks 8A and 8B is a starting estimate, not a measurement.
