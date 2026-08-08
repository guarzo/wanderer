# Discord Route Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Post a Discord message when a change to a map's topology opens a short, highsec-only route from the map's configured home system to Jita.

**Architecture:** A new `do_dispatch/2` clause on the existing singleton `DiscordDispatcher` casts to a per-map `RouteWatcher` GenServer, which owns a debounce timer and the last-known route state and never blocks on the solver. The watcher runs `Routes.find_strict/5` — a new non-swallowing sibling of `Routes.find/5` — in a supervised, non-blocking task, hands the result to a pure `RouteAlert.Evaluator`, and on a reportable transition formats an embed and hands it to the existing per-webhook delivery queue. Every security and jump-counting rule lives in the Evaluator so it can be verified with synthetic input and no HTTP.

**Tech Stack:** Elixir 1.17 / OTP 26, Phoenix LiveView, Ash Framework 3.9, Cachex, Nostrum (already present), `Task.Supervisor`, `DynamicSupervisor` + `Registry`.

## Global Constraints

- **Branch base is `guarzo/zoo`, not `origin/main`.** The entire Discord stack (`DiscordDispatcher`, `Discord.Router`, `Discord.WorkerSupervisor`, `MapDiscordWebhook`, `MapDiscordNotification`) exists only on `guarzo/zoo`. A worktree cut from `main` will not compile against this plan.
- **Ash actions, never raw Ecto.** Every new or changed action needs a matching `define(...)` entry in the resource's `code_interface` block.
- **Cache invalidation goes in `after_transaction`, never `after_action`** — see the rationale comment at `map_discord_notification.ex:147-164`.
- **Migrations are generated, not hand-written:** `mix ash.codegen <name>`.
- **This feature fails closed.** Any system on the path whose static info will not resolve disqualifies the route. This inverts the fail-open posture of the neighbouring kill path and is deliberate: announcing a highsec route that is not one gets a freighter killed; a missed alert costs nothing.
- **Highsec threshold is `>= 0.45`**, matching EVE's display rounding. `route_builder_client.ex:136` uses `>= 0.5` — do not copy it. Wormhole systems are exempt from the security check entirely; the Evaluator already holds the system's `system_class`, so the check is `SystemClass.wormhole?(class)` (`system_class.ex:52`), not the id-taking `wormhole_system?/1`.
- **Jita is `30_000_142`.** Both `origin` and `hubs` passed to the solver must be **strings** — `do_find_routes` calls `String.to_integer/1` on each (`map_routes.ex:94-95`).
- **The `SystemName.display_name/3` role argument must be a literal matched atom**, never a threaded variable. That resolver is the map-local-names privacy boundary.
- **The disabled-drops-never-reroutes rule:** a configured-but-disabled webhook drops; it never falls through to another role. `RouterTest` asserts this deliberately.
- **Ship off:** `route_alerts_enabled?` defaults to `false`.
- Run `mix format` before every commit. Verification commands run from the worktree root.

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `lib/wanderer_app/map/route_alert/evaluator.ex` | Pure: solver output + settings -> `{:qualifying, ...}` \| `:none` \| `:unknown`. All security and jump-counting rules. |
| `lib/wanderer_app/external_events/discord/mentions.ex` | Mention target validation, `content` prefix, and `allowed_mentions` construction. |
| `lib/wanderer_app/external_events/discord/route_watcher.ex` | GenServer, one per map. Debounce timer, route state, `config_version`, solver task ref. |
| `lib/wanderer_app/external_events/discord/route_watcher_supervisor.ex` | `DynamicSupervisor` + `Registry`; `notify/1`, `stop_watcher/1`. |

**Modify:**

| File | Change |
|---|---|
| `lib/wanderer_app/map/map_routes.ex` | Add `find_strict/5`; extract `hydrate_static_data/1`; add a swappable ESI seam. `find/5`'s observable behaviour must not change — see "Review focus". |
| `lib/wanderer_app/api/map_discord_notification.ex` | Three new attributes, validation, `stop_watcher` on destroy. |
| `lib/wanderer_app/api/map_discord_webhook.ex` | `mention_targets` attribute; `:route` joins the `role` `one_of`. |
| `lib/wanderer_app/env.ex` | `discord_mentions_enabled?/0`. |
| `lib/wanderer_app/external_events/discord/router.ex` | `route_destination/1`. |
| `lib/wanderer_app/external_events/discord/embed_formatter.ex` | `format_route_alert/2`. |
| `lib/wanderer_app/external_events/discord/system_name.ex` | `:route` clause on `display_name/3` if absent. |
| `lib/wanderer_app/external_events/discord_dispatcher.ex` | Topology `do_dispatch/2` clause before the catch-all; `allowed_mentions` at the payload-assembly point. |
| `lib/wanderer_app/application.ex` | Start `RouteWatcherSupervisor` inside the `webhooks_enabled` list, before `DiscordDispatcher`. |
| `lib/wanderer_app_web/live/maps/map_notifications_component.ex` | Settings UI. |

## Baseline

Established in this worktree before planning:

```
mix deps.get                                    # exit 0
MIX_ENV=test mix compile                        # exit 0
mix test test/unit/external_events/ \
         test/unit/api/map_discord_notification_test.exs \
         test/unit/api/map_discord_webhook_test.exs   # 321 tests, 0 failures
```

If `mix deps.compile sleeplocks --force` is ever needed, that is a stale rebar artifact in the worktree's `_build`, not a code problem.

## Review focus

Three places where this plan touches code that is live in production today. The
rest of the plan is new modules that cannot regress anything.

1. **`map_routes.ex` (Task 1)** — the ESI seam and the `hydrate_static_data/1`
   extraction sit in the path behind the live routes widget. Task 1 carries a
   regression test asserting `find/5` still falls back to `get_routes_eve/4`;
   confirm it actually exercises the old path rather than the new one.
2. **`Worker.do_post/2` (Task 4)** — `allowed_mentions` is attached at the single
   funnel before `HttpClient.post`, which means kill notifications and voice
   mentions start carrying it too. This is a latent-gap hardening, not a fix for
   a live exploit: no user-controlled text reaches `content` today. Verify the
   existing kill and voice tests still pass.
3. **`DiscordDispatcher` (Task 9)** — a new `do_dispatch/2` clause on a singleton
   GenServer. It must do cache reads and a cast only; anything heavier blocks
   every Discord notification on the instance.

**Plan provenance:** the steps below were written from source inspection, not
from executing them. `Expected: FAIL with ...` strings are predictions to verify,
not observed output. Where a step's RED state depends on an earlier step in the
same task, the plan says so explicitly.

---

## Shared Interface Contract

Every task section must use these exact names, arities, and types. If your
section needs something not listed here, it belongs to another task — reference
it by the signature below rather than inventing a new one.

## Task 1 — `WandererApp.Map.Routes` (modify `lib/wanderer_app/map/map_routes.ex`)

```elixir
@spec find_strict(binary(), [binary()], binary(), map(), boolean()) ::
        {:ok, %{routes: [route_entry()], systems_static_data: [map()]}} | {:error, term()}
def find_strict(map_id, hubs, origin, routes_settings, hubs_limit_reached?)
```

**The 5th argument is `hubs_limit_reached?`, not "avoid wormholes".** Verified:
`find/5`'s `true` clause (`map_routes.ex:80-91`) skips the solver entirely and
fabricates a `success: false` placeholder per hub, and its only callers pass
`is_hubs_limit_reached` (`map_routes_event_handler.ex:96,105`). Route alerts
always pass `false`. A caller that read this as "avoid wormholes" would silently
skip the solver.

`route_entry()` is the existing shape produced by `map_route_info/1`
(`map_routes.ex:332-338`) — do not redefine it:

```elixir
%{
  has_connection: boolean(),
  systems: [integer()],   # hops AFTER origin, ending at destination; origin excluded
  origin: integer(),
  destination: integer(),
  success: boolean()
}
```

`systems_static_data` entries are `Map.take(system, @minimum_route_attrs)`
(`map_routes.ex:22-31`) and **may contain `nil`** (`map_routes.ex:62`).

## Task 2 — `WandererApp.Map.RouteAlert.Evaluator` (create)

```elixir
@type outcome ::
        {:qualifying, %{jumps: pos_integer(), path: [integer()], exit_system: integer() | nil}}
        | :none
        | :unknown

@spec evaluate({:ok, map()} | {:error, term()}, keyword()) :: outcome()
def evaluate(solver_result, opts)   # opts: [max_jumps: pos_integer()]

@spec solver_settings() :: map()
@spec jita_system_id() :: 30_000_142
@spec highsec_threshold() :: float()
```

`path` is `[origin | entry.systems]` — the full path including the home system.
`exit_system` is the first non-wormhole system on `path`, or `nil` if there is none.

## Task 3 — Ash resources

`WandererApp.Api.MapDiscordNotification` gains:

```elixir
attribute :route_alerts_enabled?, :boolean, default: false, allow_nil?: false
attribute :home_system_id, :integer            # nullable
attribute :route_max_jumps, :integer, default: 5, allow_nil?: false
```

`WandererApp.Api.MapDiscordWebhook` gains:

```elixir
attribute :mention_targets, {:array, :string} do
  default []
  allow_nil? false
end
```

and its `role` constraint becomes `one_of: [:system, :character, :route]`.

Mention target format: `"user:<17-20 digits>"` or `"role:<17-20 digits>"`.

## Task 4 — mentions

```elixir
@spec WandererApp.Env.discord_mentions_enabled?() :: boolean()

defmodule WandererApp.ExternalEvents.Discord.Mentions do
  @spec prefix([String.t()]) :: String.t() | nil
  @spec allowed_mentions([String.t()]) :: map()
  @spec valid_target?(String.t()) :: boolean()
end
```

`allowed_mentions/1` always returns a map containing `"parse" => []`, even for `[]`.

## Task 5 — `WandererApp.ExternalEvents.Discord.Router`

```elixir
@spec route_destination(struct()) :: {:ok, struct()} | :drop
def route_destination(notification)
```

## Task 6 — `WandererApp.ExternalEvents.Discord.EmbedFormatter`

```elixir
@spec format_route_alert(alert :: map(), opts :: keyword()) :: [map()]
```

`alert` is `%{kind: :opened | :improved, jumps: pos_integer(), path: [integer()],
exit_system: integer() | nil, map_id: binary(), home_system_id: integer()}`.
`opts`: `[mention_targets: [String.t()]]`. Returns Discord message chunks
(maps with `"embeds"`, and `"content"` / `"allowed_mentions"` when pinging).

## Task 7 — `WandererApp.ExternalEvents.Discord.RouteWatcher`

```elixir
@spec notify(binary()) :: :ok
@spec config_version(struct()) :: binary()   # hash of {home_system_id, route_max_jumps, settings}
```

## Task 8 — `WandererApp.ExternalEvents.Discord.RouteWatcherSupervisor`

```elixir
@spec notify(binary()) :: :ok       # starts the watcher on demand; :ok when not running
@spec stop_watcher(binary()) :: :ok
```

## Existing things you may rely on (verified in this worktree)

| Thing | Location |
|---|---|
| `Task.Supervisor` already started, named `WandererApp.ExternalEvents.Discord.TaskSupervisor` | `worker_supervisor.ex:34` |
| `WorkerSupervisor.deliver(webhook_id, messages)` -> `:ok \| {:error, :not_running}` | `worker_supervisor.ex:57` |
| `DiscordDispatcher.invalidate_cache(map_id)` | `discord_dispatcher.ex:202` |
| `DiscordDispatcher` catch-all `defp do_dispatch(_map_id, _event), do: :ok` | `discord_dispatcher.ex:272` |
| `fetch_config/1` reads the Cachex config cache | `discord_dispatcher.ex:758` |
| `Env.webhooks_enabled?()` | `env.ex:95` |
| `SystemClass.wormhole_classes/0`, `SystemClass.wormhole?/1` (takes a **class**), `SystemClass.wormhole_system?/1` (takes a **solar_system_id**) | `system_class.ex:49,52,60` |
| `VoiceParticipants.prepend_to_messages(messages, prefix)` | `voice_participants.ex:147` |
| Supervision list, gated on `webhooks_enabled` | `application.ex:265-282` |
| Topology events `:add_system`, `:connection_added`, `:connection_updated` are all external | `event.ex:94,101,103` |

---

## Part 1 — solver

### Task 1: `WandererApp.Map.Routes.find_strict/5`

**Files:**
- Modify: `lib/wanderer_app/map/map_routes.ex:223-252` (`get_all_routes/4`)
- Modify: `lib/wanderer_app/map/map_routes.ex:45-97` (`find/5`, `do_find_routes/4`)
- Modify: `test/support/mock_definitions.ex:127-141` (`WandererApp.Esi.MockBehaviour`)
- Test: `test/unit/map/map_routes_find_strict_test.exs`

**Interfaces:**
- Consumes: `WandererApp.Esi.get_routes_custom/3`, `WandererApp.Esi.get_routes_eve/4`
  (both routed through a new swappable seam), `WandererApp.CachedInfo.get_system_static_info/1`,
  `WandererApp.Cache.lookup/1`, `WandererApp.Cache.insert/3`.
- Produces (per `00-contract.md`, Task 1):
  ```elixir
  @spec find_strict(binary(), [binary()], binary(), map(), boolean()) ::
          {:ok, %{routes: [route_entry()], systems_static_data: [map()]}} | {:error, term()}
  def find_strict(map_id, hubs, origin, routes_settings, hubs_limit_reached?)
  ```

**Naming note carried into the code as a comment:** the 5th positional argument
is `hubs_limit_reached?`, not "avoid wormholes". Inspection of `find/5`'s two
clauses (`map_routes.ex:45,80`) and its only two callers
(`map_routes_event_handler.ex:100-106,142-151`) shows that when it is `true` the
solver is skipped entirely and a `success: false` placeholder is fabricated per
hub, regardless of wormhole avoidance. `find_strict/5` mirrors this exactly,
because it mirrors `find/5`. Document the meaning in the `@doc`: a caller
misreading it as "avoid wormholes" and passing `true` would silently disable the
feature while looking like a security tightening. (Wormhole avoidance is a
separate thing entirely — the `:avoid_wormholes` **key inside the
`routes_settings` map**, which is unrelated to this argument.)

- [ ] **Step 1: Extend the ESI mock behaviour — prerequisite for the seam**

`WandererApp.Esi.get_routes_custom/3` and `get_routes_eve/4` are called
directly as `WandererApp.Esi.xxx(...)` in `map_routes.ex` today
(`map_routes.ex:232,249`) — there is no `Application.get_env(:wanderer_app,
:esi_client, ...)` seam the way `CorpTickers.esi_client/0` has
(`lib/wanderer_app/external_events/discord/corp_tickers.ex:172`), and
`WandererApp.Esi.MockBehaviour` does not declare these two functions
(`test/support/mock_definitions.ex:127-141`), so `Mox.stub(WandererApp.Esi.Mock,
:get_routes_custom, ...)` raises today. This step only adds the missing
callbacks to the behaviour and mock; the production call sites are changed in
Step 3, once a test exists that requires them.

```elixir
  defmodule WandererApp.Esi.MockBehaviour do
    @callback get_character_info(binary()) :: {:ok, map()} | {:error, any()}
    @callback get_character_info(binary(), keyword()) :: {:ok, map()} | {:error, any()}
    @callback get_corporation_info(binary()) :: {:ok, map()} | {:error, any()}
    @callback get_corporation_info(binary(), keyword()) :: {:ok, map()} | {:error, any()}
    @callback get_alliance_info(binary()) :: {:ok, map()} | {:error, any()}
    @callback get_alliance_info(binary(), keyword()) :: {:ok, map()} | {:error, any()}
    @callback get_killmail(binary() | integer(), binary()) :: {:ok, map()} | {:error, any()}

    @callback get_killmail(binary() | integer(), binary(), keyword()) ::
                {:ok, map()} | {:error, any()}

    @callback get_type_info(binary() | integer()) :: {:ok, map()} | {:error, any()}
    @callback get_type_info(binary() | integer(), keyword()) :: {:ok, map()} | {:error, any()}

    @callback get_routes_custom([integer()], integer(), map()) :: {:ok, [map()]} | {:error, any()}
    @callback get_routes_eve([integer()], integer(), map(), keyword()) :: {:ok, [map()]}
  end
```

Run `mix compile` — it succeeds (the behaviour changed, nothing implements it
yet, `Mox.defmock` regenerates from the behaviour automatically).

- [ ] **Step 2: Write the failing tests**

One file, three tests: the regression test for `find/5`'s existing fallback,
the new `find_strict/5` error path, and the shared-cache-key assertion the
spec's Testing section calls for explicitly. `async: false` because the ESI
seam added in Step 3 is application env read inside a function body (same
reason `CorpTickersTest` is `async: false`).

```elixir
defmodule WandererApp.Map.RoutesFindStrictTest do
  use WandererApp.DataCase, async: false

  import Mox

  alias WandererApp.Map.Routes

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # `find/5` and `find_strict/5` share a cache key built from `{origin, hubs,
    # params}` (map_routes.ex:224-225). Trig-system data feeds `params.avoid`
    # (map_routes.ex:154-201), so priming it to `[]` keeps every test's params
    # identical without a real `MapSolarSystem` row for the trig query.
    WandererApp.Cache.insert(:trig_systems, [])
    on_exit(fn -> WandererApp.Cache.delete(:trig_systems) end)

    original_esi = Application.get_env(:wanderer_app, :esi_client)
    Application.put_env(:wanderer_app, :esi_client, WandererApp.Esi.Mock)
    on_exit(fn -> Application.put_env(:wanderer_app, :esi_client, original_esi) end)

    :ok
  end

  # `avoid_wormholes: true` in `routes_settings` skips the `MapConnection` read
  # and the Thera chain fetch entirely (map_routes.ex:100-152), so these tests
  # exercise the ESI seam without needing a real map's connections in the DB.
  @routes_settings %{avoid_wormholes: true}

  defp unique_system_id, do: 30_000_000 + System.unique_integer([:positive])

  # `get_system_static_info/1` reads `:system_static_info_cache` before falling
  # back to a full `MapSolarSystem` table scan (cached_info.ex:101-141), and
  # that fallback has no clause for `{:error, :not_found}` in `find/5`'s
  # `Task.async_stream` handler (map_routes.ex:61-67) — priming the cache
  # avoids both the DB round trip and that latent crash.
  defp stub_static_info(system_id) do
    Cachex.put(:system_static_info_cache, system_id, %{
      solar_system_id: system_id,
      security: "0.9",
      system_class: 7
    })

    on_exit(fn -> Cachex.del(:system_static_info_cache, system_id) end)
  end

  test "find/5 still falls back to get_routes_eve on a custom-route error" do
    hub = unique_system_id()
    origin = unique_system_id()
    stub_static_info(hub)
    stub_static_info(origin)

    stub(WandererApp.Esi.Mock, :get_routes_custom, fn _hubs, _origin, _params ->
      {:error, :solver_unreachable}
    end)

    stub(WandererApp.Esi.Mock, :get_routes_eve, fn hubs, origin, _params, _opts ->
      {:ok,
       Enum.map(hubs, fn hub ->
         %{"origin" => origin, "destination" => hub, "systems" => [], "success" => false}
       end)}
    end)

    assert {:ok, %{routes: [%{success: false}], systems_static_data: []}} =
             Routes.find(
               Ecto.UUID.generate(),
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )
  end

  test "find_strict/5 propagates {:error, reason} instead of falling back to get_routes_eve" do
    hub = unique_system_id()
    origin = unique_system_id()

    stub(WandererApp.Esi.Mock, :get_routes_custom, fn _hubs, _origin, _params ->
      {:error, :solver_unreachable}
    end)

    stub(WandererApp.Esi.Mock, :get_routes_eve, fn _hubs, _origin, _params, _opts ->
      flunk("find_strict/5 must not fall back to get_routes_eve on a solver error")
    end)

    assert {:error, :solver_unreachable} =
             Routes.find_strict(
               Ecto.UUID.generate(),
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )
  end

  test "find_strict/5 matches find/5 on the success path and shares its cache key" do
    hub = unique_system_id()
    origin = unique_system_id()
    stub_static_info(hub)
    stub_static_info(origin)
    map_id = Ecto.UUID.generate()

    # `expect ... 1` proves the shared cache key: if `find_strict/5` hashed its
    # params differently from `find/5`, the second call below would miss the
    # cache and this expectation would fail with "called 2 times".
    expect(WandererApp.Esi.Mock, :get_routes_custom, 1, fn hubs, origin, _params ->
      {:ok,
       Enum.map(hubs, fn hub ->
         %{
           "origin" => origin,
           "destination" => hub,
           "systems" => [hub],
           "success" => true
         }
       end)}
    end)

    assert {:ok, strict_result} =
             Routes.find_strict(
               map_id,
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )

    assert {:ok, find_result} =
             Routes.find(
               map_id,
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )

    assert strict_result == find_result
    assert [%{success: true, origin: ^origin, destination: ^hub}] = strict_result.routes
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/unit/map/map_routes_find_strict_test.exs`
Expected: FAIL on every test with
`** (UndefinedFunctionError) function WandererApp.Map.Routes.find_strict/5 is undefined or private`
(the first test, exercising only `find/5`, is expected to already pass —
confirm that in the output before continuing, since it is the regression
guard for this whole task).

- [ ] **Step 4: Add the swappable ESI seam**

Route both existing call sites through a private resolver, matching the
`esi_client/0` pattern in `corp_tickers.ex:172`. Defaults to the real
`WandererApp.Esi`, so every existing caller (nothing sets `:esi_client` outside
tests) is unaffected.

```elixir
  defp get_all_routes(hubs, origin, params, opts \\ []) do
    cache_key =
      "routes-#{origin}-#{hubs |> Enum.join("-")}-#{:crypto.hash(:sha, :erlang.term_to_binary(params))}"

    case WandererApp.Cache.lookup(cache_key) do
      {:ok, result} when not is_nil(result) ->
        {:ok, result}

      _ ->
        case esi_client().get_routes_custom(hubs, origin, params) do
          {:ok, result} ->
            WandererApp.Cache.insert(
              cache_key,
              result,
              ttl: @routes_ttl
            )

            {:ok, result}

          {:error, error} ->
            error_file_path = save_error_params(origin, hubs, params)

            @logger.error(
              "Error getting custom routes for #{inspect(origin)}: #{inspect(params)}. Params saved to: #{error_file_path}"
            )

            if Keyword.get(opts, :strict, false) do
              {:error, error}
            else
              esi_client().get_routes_eve(hubs, origin, params, opts)
            end
        end
    end
  end

  defp esi_client, do: Application.get_env(:wanderer_app, :esi_client, WandererApp.Esi)
```

This replaces the existing `get_all_routes/4` body in place (same function,
same clause count) and the `defp save_error_params` clause immediately below
it is untouched. `opts` already reached `get_routes_eve/4` unchanged before
this edit (`map_routes.ex:249`); it now also carries the `:strict` flag, which
`get_routes_eve/4` ignores (its param list is `_opts`), so nothing downstream
needs to change.

- [ ] **Step 5: Run test to verify the ESI seam is exercised**

Run: `mix test test/unit/map/map_routes_find_strict_test.exs`
Expected: the two tests naming `get_routes_custom`/`get_routes_eve` now reach
the stub, but `find_strict/5` is still undefined — FAIL with the same
`UndefinedFunctionError` as Step 3 on the two `find_strict` tests; the `find/5`
fallback regression test now PASSES (confirms the seam preserved existing
behavior before `find_strict/5` exists at all).

- [ ] **Step 6: Extract the static-data hydration and add `do_find_routes/5` and `find_strict/5`**

`find/5`'s hydration block (`map_routes.ex:53-77`) is identical to what
`find_strict/5` needs — the design's stated intent is "keeping ... static-data
hydration in one place rather than duplicating them into the watcher"
(spec, "Distinguishing failure from no-route"). Extract it once, call it from
both.

```elixir
  def find(map_id, hubs, origin, routes_settings, false) do
    case do_find_routes(map_id, origin, hubs, routes_settings) do
      {:ok, routes} ->
        {:ok, %{routes: routes, systems_static_data: hydrate_static_data(routes)}}

      _error ->
        {:ok, %{routes: [], systems_static_data: []}}
    end
  end

  def find(_map_id, hubs, origin, _routes_settings, true) do
    origin = origin |> String.to_integer()
    hubs = hubs |> Enum.map(&(&1 |> String.to_integer()))

    routes =
      hubs
      |> Enum.map(fn hub ->
        %{origin: origin, destination: hub, success: false, systems: [], has_connection: false}
      end)

    {:ok, %{routes: routes, systems_static_data: []}}
  end

  @doc """
  Sibling of `find/5` for callers that must distinguish a solver outage from a
  genuine no-path result (see the design doc, "Distinguishing failure from
  no-route"). Same params assembly, same cache key, same TTL — the only
  difference is that a `get_routes_custom/3` error is returned to the caller
  instead of falling back to the `get_routes_eve/4` stub.

  The final argument is named `hubs_limit_reached?`. It is *not* "avoid
  wormholes": as in `find/5`, `true` means "the hub count already exceeded the
  map's limit, skip the solver" — see `find/5`'s second clause
  (`map_routes.ex:80-91`) and its callers in `map_routes_event_handler.ex:96,105`.
  Route alerts always pass `false`.
  """
  @spec find_strict(binary(), [binary()], binary(), map(), boolean()) ::
          {:ok, %{routes: [map()], systems_static_data: [map() | nil]}} | {:error, term()}
  def find_strict(map_id, hubs, origin, routes_settings, false) do
    case do_find_routes(map_id, origin, hubs, routes_settings, strict: true) do
      {:ok, routes} ->
        {:ok, %{routes: routes, systems_static_data: hydrate_static_data(routes)}}

      {:error, _reason} = error ->
        error
    end
  end

  def find_strict(_map_id, hubs, origin, _routes_settings, true) do
    origin = origin |> String.to_integer()
    hubs = hubs |> Enum.map(&(&1 |> String.to_integer()))

    routes =
      hubs
      |> Enum.map(fn hub ->
        %{origin: origin, destination: hub, success: false, systems: [], has_connection: false}
      end)

    {:ok, %{routes: routes, systems_static_data: []}}
  end

  defp hydrate_static_data(routes) do
    routes
    |> Enum.map(fn route_info -> route_info.systems end)
    |> List.flatten()
    |> Enum.uniq()
    |> Task.async_stream(
      fn system_id ->
        case WandererApp.CachedInfo.get_system_static_info(system_id) do
          {:ok, nil} ->
            nil

          {:ok, system} ->
            system |> Map.take(@minimum_route_attrs)
        end
      end,
      max_concurrency: System.schedulers_online() * 4
    )
    |> Enum.map(fn {:ok, val} -> val end)
  end

  defp do_find_routes(map_id, origin, hubs, routes_settings, opts \\ []) do
    origin = origin |> String.to_integer()
    hubs = hubs |> Enum.map(&(&1 |> String.to_integer()))

    routes_settings = @default_routes_settings |> Map.merge(routes_settings)

    connections =
      case routes_settings.avoid_wormholes do
        false ->
          map_chains =
            routes_settings
            |> Map.take(@get_link_pairs_advanced_params)
            |> Map.put_new(:map_id, map_id)
            |> WandererApp.Api.MapConnection.get_link_pairs_advanced!()
            |> Enum.map(fn %{
                             solar_system_source: solar_system_source,
                             solar_system_target: solar_system_target
                           } ->
              %{
                first: solar_system_source,
                second: solar_system_target
              }
            end)
            |> Enum.uniq()

          {:ok, thera_chains} =
            case routes_settings.include_thera do
              true ->
                WandererApp.Server.TheraDataFetcher.get_chain_pairs(routes_settings)

              false ->
                {:ok, []}
            end

          chains = remove_intersection([map_chains | thera_chains] |> List.flatten())

          chains =
            case routes_settings.include_cruise do
              false ->
                {:ok, wh_class_a_systems} = WandererApp.CachedInfo.get_wh_class_a_systems()

                chains
                |> Enum.filter(fn x ->
                  not Enum.member?(wh_class_a_systems, x.first) and
                    not Enum.member?(wh_class_a_systems, x.second)
                end)

              _ ->
                chains
            end

          chains
          |> Enum.map(fn chain ->
            ["#{chain.first}|#{chain.second}", "#{chain.second}|#{chain.first}"]
          end)
          |> List.flatten()

        true ->
          []
      end

    {:ok, trig_systems} = WandererApp.CachedInfo.get_trig_systems()

    pochven_solar_systems =
      trig_systems
      |> Enum.filter(fn s -> s.triglavian_invasion_status == "Final" end)
      |> Enum.map(& &1.solar_system_id)

    triglavian_solar_systems =
      trig_systems
      |> Enum.filter(fn s -> s.triglavian_invasion_status == "Triglavian" end)
      |> Enum.map(& &1.solar_system_id)

    edencom_solar_systems =
      trig_systems
      |> Enum.filter(fn s -> s.triglavian_invasion_status == "Edencom" end)
      |> Enum.map(& &1.solar_system_id)

    avoidance_list =
      case routes_settings.avoid_edencom do
        true ->
          edencom_solar_systems

        false ->
          []
      end

    avoidance_list =
      case routes_settings.avoid_triglavian do
        true ->
          [avoidance_list | triglavian_solar_systems]

        false ->
          avoidance_list
      end

    avoidance_list =
      case routes_settings.avoid_pochven do
        true ->
          [avoidance_list | pochven_solar_systems]

        false ->
          avoidance_list
      end

    avoidance_list =
      (@default_avoid_systems ++ [routes_settings.avoid | avoidance_list])
      |> List.flatten()
      |> Enum.uniq()

    params =
      %{
        datasource: "tranquility",
        flag: routes_settings.path_type,
        connections: connections,
        avoid: avoidance_list
      }

    case get_all_routes(hubs, origin, params, opts) do
      {:ok, all_routes} ->
        routes =
          all_routes
          |> Enum.map(fn route_info ->
            map_route_info(route_info)
          end)
          |> Enum.filter(fn route_info -> not is_nil(route_info) end)

        {:ok, routes}

      {:error, _reason} = error ->
        error
    end
  end
```

This replaces `find/5` (both clauses), `do_find_routes/4`, and inserts
`find_strict/5` and `hydrate_static_data/1` immediately after. `do_find_routes/4`
becomes `do_find_routes/5` with a defaulted `opts \\ []`, so `find/5`'s
existing call `do_find_routes(map_id, origin, hubs, routes_settings)` still
compiles unchanged and still runs with `opts = []`, i.e. `strict: false` by
`Keyword.get/3`'s default in `get_all_routes/4` — `find/5`'s behavior is
provably identical to before this task.

- [ ] **Step 7: Run test to verify it passes**

Run: `mix test test/unit/map/map_routes_find_strict_test.exs`
Expected: `3 tests, 0 failures`.

- [ ] **Step 8: Run the broader map test suite for regressions**

Run: `mix test test/unit/map/`
Expected: no new failures relative to the pre-task baseline (there is no
pre-existing `map_routes_test.exs`, so this is purely a check that the edit
did not break `test/unit/map/*` tests that exercise adjacent code, e.g.
`test/unit/map/map_scopes_test.exs`'s shared `:system_static_info_cache`
Cachex entries).

- [ ] **Step 9: Format and commit**

```bash
mix format lib/wanderer_app/map/map_routes.ex test/support/mock_definitions.ex test/unit/map/map_routes_find_strict_test.exs
git add lib/wanderer_app/map/map_routes.ex test/support/mock_definitions.ex test/unit/map/map_routes_find_strict_test.exs
git commit -m "feat(routes): add find_strict/5, distinguishing solver outage from no-path"
```

---

### Task 2: `WandererApp.Map.RouteAlert.Evaluator`

**Files:**
- Create: `lib/wanderer_app/map/route_alert/evaluator.ex`
- Test: `test/unit/map/route_alert/evaluator_test.exs`

**Interfaces:**
- Consumes: the `{:ok, %{routes: [route_entry()], systems_static_data: [map() | nil]}} |
  {:error, term()}` shape `find_strict/5` produces (Task 1) — passed in directly
  as `solver_result`, never fetched by this module. No HTTP, no GenServer, no
  `CachedInfo` call: every system's `security` and `system_class` travel inside
  `systems_static_data`.
- Produces (per `00-contract.md`, Task 2):
  ```elixir
  @type outcome ::
          {:qualifying, %{jumps: pos_integer(), path: [integer()], exit_system: integer() | nil}}
          | :none
          | :unknown

  @spec evaluate({:ok, map()} | {:error, term()}, keyword()) :: outcome()
  def evaluate(solver_result, opts)   # opts: [max_jumps: pos_integer()]

  @spec solver_settings() :: map()
  @spec jita_system_id() :: 30_000_142
  @spec highsec_threshold() :: float()
  ```

- [ ] **Step 1: Write the failing tests**

All ten required cases in one file, since the module under test is pure and
the whole spec is small enough to write against a single fixture builder.

```elixir
defmodule WandererApp.Map.RouteAlert.EvaluatorTest do
  use ExUnit.Case, async: true

  alias WandererApp.Map.RouteAlert.Evaluator

  # 7 = k-space highsec (per `SystemClass`'s companion class ids in
  # `map_scopes_test.exs:14`); 1 = a C1 wormhole; not in
  # `SystemClass.wormhole_classes/0` is exactly what "non-wormhole" means here.
  @hs_class 7
  @wh_class 1

  defp static(id, security, class \\ @hs_class) do
    %{solar_system_id: id, security: security, system_class: class}
  end

  defp entry(origin, systems, success \\ true) do
    %{origin: origin, systems: systems, destination: 30_000_142, success: success, has_connection: systems != []}
  end

  defp solver_result(entries, static_data) do
    {:ok, %{routes: entries, systems_static_data: static_data}}
  end

  describe "evaluate/2 — failure and no-path" do
    test "{:error, _} is :unknown, regardless of opts" do
      assert Evaluator.evaluate({:error, :timeout}, max_jumps: 5) == :unknown
    end

    test "routes: [] is :unknown — the solver returning nothing is not a decision" do
      assert Evaluator.evaluate(solver_result([], []), max_jumps: 5) == :unknown
    end

    test "every entry success: false is :none — a genuine no-path" do
      result = solver_result([entry(1, [], false)], [])
      assert Evaluator.evaluate(result, max_jumps: 5) == :none
    end
  end

  describe "evaluate/2 — wormhole exemption" do
    test "a J-space hop at wormhole security does not disqualify the route" do
      origin = 31_000_001
      exit = 30_000_100

      static_data = [
        static(origin, -1.0, @wh_class),
        static(exit, 0.9)
      ]

      result = solver_result([entry(origin, [exit])], static_data)

      assert {:qualifying, %{jumps: 1, path: [^origin, ^exit], exit_system: ^exit}} =
               Evaluator.evaluate(result, max_jumps: 5)
    end
  end

  describe "evaluate/2 — the 0.45 boundary" do
    # `entry/3`'s `has_connection` derives from `systems != []`
    # (`map_route_info/1`, `map_routes.ex:333`), so every boundary case here
    # needs a real hop rather than an empty `systems` list — an empty list
    # would make the entry itself `unsuccessful?/1` for the wrong reason and
    # the test would pass without ever reaching the security check.
    test "0.45 qualifies" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), static(hop, 0.45)]
      result = solver_result([entry(origin, [hop])], static_data)

      assert {:qualifying, %{jumps: 1}} = Evaluator.evaluate(result, max_jumps: 5)
    end

    test "0.4 does not qualify" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), static(hop, 0.4)]
      result = solver_result([entry(origin, [hop])], static_data)

      assert Evaluator.evaluate(result, max_jumps: 5) == :none
    end
  end

  describe "evaluate/2 — fail-closed on unresolved statics" do
    test "a system missing from systems_static_data disqualifies the whole route" do
      origin = 30_000_001
      hop = 30_000_002
      # `hop`'s static entry is absent entirely.
      static_data = [static(origin, 0.9)]

      result = solver_result([entry(origin, [hop])], static_data)

      assert Evaluator.evaluate(result, max_jumps: 5) == :none
    end

    test "a nil entry in systems_static_data is treated as absent, not crashed on" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), nil, static(hop, 0.9)]

      result = solver_result([entry(origin, [hop])], static_data)

      assert {:qualifying, _} = Evaluator.evaluate(result, max_jumps: 5)
    end

    test "an unparseable security string disqualifies the route" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), static(hop, "not-a-number")]

      result = solver_result([entry(origin, [hop])], static_data)

      assert Evaluator.evaluate(result, max_jumps: 5) == :none
    end
  end

  describe "evaluate/2 — jump counting" do
    test "wormhole hops count toward the jump total" do
      origin = 31_000_001
      wh_hop = 31_000_002
      exit = 30_000_100

      static_data = [
        static(origin, -1.0, @wh_class),
        static(wh_hop, -1.0, @wh_class),
        static(exit, 0.9)
      ]

      result = solver_result([entry(origin, [wh_hop, exit])], static_data)

      assert {:qualifying, %{jumps: 2}} = Evaluator.evaluate(result, max_jumps: 5)
    end

    test "jumps == max_jumps qualifies" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), static(hop, 0.9)]

      result = solver_result([entry(origin, [hop])], static_data)

      assert {:qualifying, %{jumps: 1}} = Evaluator.evaluate(result, max_jumps: 1)
    end

    test "jumps == max_jumps + 1 does not qualify" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), static(hop, 0.9)]

      result = solver_result([entry(origin, [hop])], static_data)

      assert Evaluator.evaluate(result, max_jumps: 0) == :none
    end
  end

  describe "evaluate/2 — exit_system" do
    test "exit_system is the first non-wormhole system on the path" do
      origin = 31_000_001
      wh_hop = 31_000_002
      exit = 30_000_100
      hs_hop_after_exit = 30_000_101

      static_data = [
        static(origin, -1.0, @wh_class),
        static(wh_hop, -1.0, @wh_class),
        static(exit, 0.9),
        static(hs_hop_after_exit, 0.9)
      ]

      result = solver_result([entry(origin, [wh_hop, exit, hs_hop_after_exit])], static_data)

      assert {:qualifying, %{exit_system: ^exit}} = Evaluator.evaluate(result, max_jumps: 5)
    end
  end

  describe "solver_settings/0, jita_system_id/0, highsec_threshold/0" do
    test "returns the pinned settings from the design's decision 8" do
      assert Evaluator.solver_settings() == %{
               include_eol: false,
               include_mass_crit: false,
               include_frig: false,
               include_cruise: true,
               avoid_pochven: true,
               avoid_edencom: true,
               avoid_triglavian: true,
               include_thera: false
             }
    end

    test "jita_system_id/0 and highsec_threshold/0 are pinned constants" do
      assert Evaluator.jita_system_id() == 30_000_142
      assert Evaluator.highsec_threshold() == 0.45
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/map/route_alert/evaluator_test.exs`
Expected: FAIL with
`** (UndefinedFunctionError) function WandererApp.Map.RouteAlert.Evaluator.evaluate/2 is undefined (module WandererApp.Map.RouteAlert.Evaluator is not available)`
on every test (the module does not exist yet).

- [ ] **Step 3: Implement the Evaluator**

```elixir
defmodule WandererApp.Map.RouteAlert.Evaluator do
  @moduledoc """
  Pure decision function turning a `WandererApp.Map.Routes.find_strict/5`
  result into the three-state model the route-alert watcher acts on. No HTTP,
  no GenServer, no `CachedInfo` lookups — every system's security and class
  travel in `systems_static_data`, which `find_strict/5` already hydrates.

  See the design doc's "Alert semantics" and "Failure posture" sections for the
  rules this module encodes.
  """

  alias WandererApp.SystemClass

  @jita_system_id 30_000_142
  @highsec_threshold 0.45

  # Derived at compile time from the canonical list rather than restated, so
  # this cannot drift from `SystemClass`. A module attribute is required because
  # `system_qualifies?/2` matches on the class in a guard, and a guard cannot
  # call a remote function.
  @wormhole_classes SystemClass.wormhole_classes()

  # Pinned per the design's decision 8 — there is no user in this code path, so
  # settings are not read from any widget preference. `include_mass_crit:
  # false` and `include_frig: false` differ from `Routes`' own module defaults
  # because a crit or frigate-sized connection will not pass a hauler.
  # `include_thera: false` keeps every alert attributable to the map's own
  # chain rather than to public Thera connectivity.
  @solver_settings %{
    include_eol: false,
    include_mass_crit: false,
    include_frig: false,
    include_cruise: true,
    avoid_pochven: true,
    avoid_edencom: true,
    avoid_triglavian: true,
    include_thera: false
  }

  @type outcome ::
          {:qualifying, %{jumps: pos_integer(), path: [integer()], exit_system: integer() | nil}}
          | :none
          | :unknown

  @spec jita_system_id() :: 30_000_142
  def jita_system_id, do: @jita_system_id

  @spec highsec_threshold() :: float()
  def highsec_threshold, do: @highsec_threshold

  @spec solver_settings() :: map()
  def solver_settings, do: @solver_settings

  @doc """
  `opts` must include `max_jumps: pos_integer()`.

  Fails closed: any system on a route's path that is missing from
  `systems_static_data`, or whose `security` will not parse, disqualifies that
  route entirely (`:none`, not `:unknown`) — an unresolvable system is a route
  this module will not vouch for. See the design doc's "Failure posture".
  """
  @spec evaluate({:ok, map()} | {:error, term()}, keyword()) :: outcome()
  def evaluate({:error, _reason}, _opts), do: :unknown

  def evaluate({:ok, %{routes: []}}, _opts), do: :unknown

  def evaluate({:ok, %{routes: entries, systems_static_data: static_data}}, opts) do
    if Enum.all?(entries, &unsuccessful?/1) do
      :none
    else
      max_jumps = Keyword.fetch!(opts, :max_jumps)
      static_by_id = index_static_data(static_data)

      entries
      |> Enum.reject(&unsuccessful?/1)
      |> Enum.find_value(:none, &qualify(&1, static_by_id, max_jumps))
    end
  end

  defp unsuccessful?(%{success: false}), do: true
  defp unsuccessful?(%{has_connection: false}), do: true
  defp unsuccessful?(_entry), do: false

  defp qualify(entry, static_by_id, max_jumps) do
    path = [entry.origin | entry.systems]
    jumps = length(entry.systems)

    if jumps <= max_jumps and path_qualifies?(path, static_by_id) do
      {:qualifying,
       %{jumps: jumps, path: path, exit_system: find_exit_system(path, static_by_id)}}
    end
  end

  # `Enum.all?/2` short-circuits on the first disqualifying hop, which is also
  # the fail-closed behavior: an unresolvable or wormhole-failing hop stops the
  # check rather than being skipped.
  defp path_qualifies?(path, static_by_id) do
    Enum.all?(path, &system_qualifies?(&1, static_by_id))
  end

  defp system_qualifies?(system_id, static_by_id) do
    case Map.fetch(static_by_id, system_id) do
      :error ->
        false

      {:ok, %{system_class: class}} when class in @wormhole_classes ->
        true

      {:ok, %{security: security}} ->
        case parse_security(security) do
          {:ok, value} -> value >= @highsec_threshold
          {:error, _reason} -> false
        end
    end
  end

  defp find_exit_system(path, static_by_id) do
    Enum.find(path, fn system_id ->
      case Map.fetch(static_by_id, system_id) do
        {:ok, %{system_class: class}} -> not SystemClass.wormhole?(class)
        :error -> false
      end
    end)
  end

  defp index_static_data(static_data) do
    static_data
    |> Enum.reject(&is_nil/1)
    |> Map.new(&{&1.solar_system_id, &1})
  end

  # Duplicated from `RouteBuilderClient.parse_security/1` (`route_builder_client.ex:200-210`)
  # rather than reused: that function is private, and this module's threshold
  # deliberately diverges from it (0.45 here vs. 0.5 there — see
  # `highsec_threshold/0`'s moduledoc reference and the design doc's decision
  # 4), so sharing the parser without sharing the threshold would leave the one
  # place that says "0.5" sitting next to the one place that says "0.45" with
  # no visible link between them.
  defp parse_security(security) when is_float(security), do: {:ok, security}
  defp parse_security(security) when is_integer(security), do: {:ok, security * 1.0}

  defp parse_security(security) when is_binary(security) do
    case Float.parse(security) do
      {value, _rest} -> {:ok, value}
      :error -> {:error, :invalid_security}
    end
  end

  defp parse_security(_security), do: {:error, :invalid_security}
end
```

Two places test the wormhole exemption, and neither restates the class list.
`system_qualifies?/2` matches in a **guard**, which cannot call a remote
function, so it uses `@wormhole_classes` — a module attribute evaluated at
compile time from `SystemClass.wormhole_classes/0`. `find_exit_system/2` is not
guard-constrained and calls `SystemClass.wormhole?/1` directly. `SystemClass`
stays the single source of truth in both.

One consequence to know: because `@wormhole_classes` is resolved at compile
time, adding a class to `SystemClass` requires `Evaluator` to be recompiled.
Elixir's compiler tracks this dependency and does so automatically on a normal
`mix compile`; it matters only if someone hot-loads `SystemClass` alone.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/unit/map/route_alert/evaluator_test.exs`
Expected: `15 tests, 0 failures`.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/wanderer_app/map/route_alert/evaluator.ex test/unit/map/route_alert/evaluator_test.exs
git add lib/wanderer_app/map/route_alert/evaluator.ex test/unit/map/route_alert/evaluator_test.exs
git commit -m "feat(route-alert): add Evaluator, the pure jump/security decision function"
```

---

### Task 3: Ash schema — route alert config and mention targets

**Files:**
- Modify: `lib/wanderer_app/api/map_discord_notification.ex`
- Modify: `lib/wanderer_app/api/map_discord_webhook.ex`
- Test: `test/unit/api/map_discord_notification_test.exs`
- Test: `test/unit/api/map_discord_webhook_test.exs`
- Generated (via `mix ash.codegen`, inspect and commit): one migration under
  `priv/repo/migrations/` for `map_discord_notifications_v1`, one for
  `map_discord_webhooks_v1`

**Interfaces:**
- Consumes: nothing new — builds on the existing `MapDiscordNotification` /
  `MapDiscordWebhook` resources and their `after_transaction` invalidation
  hooks.
- Produces:
  - `MapDiscordNotification` attributes `route_alerts_enabled?`,
    `home_system_id`, `route_max_jumps` — the exact shape Task 7's
    `RouteWatcher` and Task 5's `Router` read.
  - `MapDiscordWebhook` attribute `mention_targets` and widened `role`
    `one_of: [:system, :character, :route]` — consumed by Task 5's
    `route_destination/1` and Task 6's `format_route_alert/2` (via
    `opts[:mention_targets]`).

Note on scope: `mention_targets` gets its own regex-matching validation
module here (`ValidateMentionTargets`), carrying its own copy of the
`^(user|role):\d{17,20}$` pattern so that this task does not depend on
Task 4's `Discord.Mentions` existing first. **This copy is temporary by
ruling:** Task 4's section 4.4 rewrites `ValidateMentionTargets` to delegate
to `Mentions.valid_target?/1` and deletes the literal here. Write it as shown
below anyway — Task 4 owns the fold, and the rejection tests you write in this
task are what prove the fold preserved behaviour.

---

#### 3.1 — `route_alerts_enabled?`, `home_system_id`, `route_max_jumps`

- [ ] **Step 1: Write the failing test**

Add to `test/unit/api/map_discord_notification_test.exs`, inside the existing
`describe`-less body (it has none — top-level `test`s), just before the final
`end`:

```elixir
  test "route alert fields default off with a 5-jump cap", %{map: map} do
    assert {:ok, rec} =
             MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert rec.route_alerts_enabled? == false
    assert rec.home_system_id == nil
    assert rec.route_max_jumps == 5
  end

  test "route alert config round-trips through update", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, updated} =
             MapDiscordNotification.update(rec, %{
               route_alerts_enabled?: true,
               home_system_id: 30_000_142,
               route_max_jumps: 3
             })

    assert updated.route_alerts_enabled? == true
    assert updated.home_system_id == 30_000_142
    assert updated.route_max_jumps == 3

    assert {:ok, reloaded} = MapDiscordNotification.by_map(map.id)
    assert reloaded.home_system_id == 30_000_142
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/api/map_discord_notification_test.exs -k "route alert fields default off"`
Expected: FAIL — `route_alerts_enabled?` is not accepted by `:create` (or the
key is dropped and `Map.get(rec, :route_alerts_enabled?)` raises
`KeyError`/`Ash.Error.Invalid` for unknown input), since the attribute does
not exist on the resource yet.

- [ ] **Step 3: Add the attributes and thread them through `accept`**

In `lib/wanderer_app/api/map_discord_notification.ex`:

```elixir
    default_accept [
      :map_id,
      :enabled?,
      :wh_only,
      :excluded_systems,
      :focus_corp_ids,
      :route_alerts_enabled?,
      :home_system_id,
      :route_max_jumps
    ]
```

```elixir
    update :update do
      primary? true
      require_atomic? false

      # Explicit, so `default_accept` cannot expose `:map_id`: re-parenting a
      # notification would move it and its webhook children to another map.
      # The three route fields ARE deliberately in this list — unlike
      # `:map_id` there is no re-parenting risk, and route alert config is
      # meant to be editable the same way the kill-switch fields are.
      accept [
        :enabled?,
        :wh_only,
        :excluded_systems,
        :focus_corp_ids,
        :route_alerts_enabled?,
        :home_system_id,
        :route_max_jumps
      ]

      change after_transaction(&__MODULE__.invalidate_cache/3)
    end
```

```elixir
  attributes do
    uuid_primary_key :id

    attribute :enabled?, :boolean, default: true, allow_nil?: false
    attribute :wh_only, :boolean, default: true, allow_nil?: false

    attribute :excluded_systems, {:array, :integer} do
      default []
      allow_nil? false
    end

    attribute :focus_corp_ids, {:array, :integer} do
      default []
      allow_nil? false
    end

    # Route alerts — separate switch from `enabled?`, which gates kills. Ships
    # off: an operator must opt a map in, not discover it firing unannounced.
    attribute :route_alerts_enabled?, :boolean, default: false, allow_nil?: false

    # No "home system" concept exists anywhere else in the codebase (see the
    # design doc's repository-evidence table) — this is where it is defined,
    # scoped to this feature. Nullable: a map with route alerts off need not
    # have one set, and `validate_home_system_required/2` below is what
    # enforces the combination that matters.
    attribute :home_system_id, :integer

    # Inclusive upper bound (design decision 5): "less than 6 jumps" means
    # "at most 5", so the stored number and the UI copy agree.
    attribute :route_max_jumps, :integer do
      default 5
      allow_nil? false
      # 1 is the trivial floor (a route of zero jumps is "already there", not
      # an alert). 20 is a generous ceiling: it is nowhere near a real hauling
      # route in this feature's wormhole-plus-highsec shape, but it stops a
      # typo (e.g. an extra digit) from asking the solver to treat every
      # multi-region path as "qualifying" and firing constantly.
      constraints min: 1, max: 20
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
```

- [ ] **Step 4: Generate and inspect the migration, then run it**

Run: `mix ash.codegen add_route_alert_config`
This writes a new file under `priv/repo/migrations/` (timestamp-prefixed,
e.g. `<ts>_add_route_alert_config.exs`). Open it and confirm it adds exactly
three columns to `map_discord_notifications_v1`:
`route_alerts_enabled? boolean not null default false`,
`home_system_id bigint` (nullable), `route_max_jumps bigint not null default 5`
— and nothing else. `route_max_jumps`'s `min`/`max` constraints are
Ash-side only; they do not appear as a DB `CHECK` constraint, so do not
expect one in the generated file.

Run: `mix ash.migrate`
Expected: migration applies cleanly against the dev/test database.

Run: `mix test test/unit/api/map_discord_notification_test.exs -k "route alert"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/wanderer_app/api/map_discord_notification.ex \
  test/unit/api/map_discord_notification_test.exs \
  priv/repo/migrations/*_add_route_alert_config.exs
git commit -m "feat(discord): add route alert config to MapDiscordNotification"
```

---

#### 3.2 — `home_system_id` required when `route_alerts_enabled?` is true

- [ ] **Step 1: Write the failing test**

```elixir
  test "route_alerts_enabled? without a home_system_id is rejected", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             MapDiscordNotification.update(rec, %{route_alerts_enabled?: true})

    assert Enum.any?(errors, fn e ->
             Map.get(e, :field) == :home_system_id and
               to_string(Map.get(e, :message, "")) =~ "required"
           end)
  end

  test "route_alerts_enabled? with a home_system_id already set is accepted", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    {:ok, rec} = MapDiscordNotification.update(rec, %{home_system_id: 30_000_142})

    assert {:ok, updated} = MapDiscordNotification.update(rec, %{route_alerts_enabled?: true})
    assert updated.route_alerts_enabled? == true
  end

  test "home_system_id can be set while route_alerts_enabled? stays false", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, updated} = MapDiscordNotification.update(rec, %{home_system_id: 30_000_142})
    assert updated.route_alerts_enabled? == false
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/api/map_discord_notification_test.exs -k "route_alerts_enabled?"`
Expected: FAIL on the first new test — the update currently succeeds with no
validation, so `{:error, ...}` is never returned.

- [ ] **Step 3: Add the validation**

```elixir
  validations do
    validate &__MODULE__.validate_home_system_required/2
  end
```

Placed after `code_interface do ... end` and before `actions do ... end`, or
directly after `actions do ... end` — either is valid Spark DSL ordering;
match the file's existing top-to-bottom order of `code_interface`, `actions`,
then this new `validations` block, then `attributes`.

```elixir
  @doc false
  def validate_home_system_required(changeset, _context) do
    # get_attribute/2 reads the value the changeset WOULD produce — the new
    # value if it is being set, otherwise the record's current one — so this
    # catches both "enable with no home system yet" and "clear the home
    # system while alerts are still on" in one check.
    enabled? = Ash.Changeset.get_attribute(changeset, :route_alerts_enabled?)
    home_system_id = Ash.Changeset.get_attribute(changeset, :home_system_id)

    if enabled? && is_nil(home_system_id) do
      {:error,
       field: :home_system_id,
       message: "is required when route alerts are enabled"}
    else
      :ok
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/unit/api/map_discord_notification_test.exs -k "route_alerts_enabled? OR home_system_id"`
Expected: PASS, all three.

- [ ] **Step 5: Commit**

```bash
git add lib/wanderer_app/api/map_discord_notification.ex \
  test/unit/api/map_discord_notification_test.exs
git commit -m "feat(discord): require home_system_id when route alerts are enabled"
```

---

#### 3.3 — `route_max_jumps` bounds

- [ ] **Step 1: Write the failing test**

```elixir
  test "route_max_jumps accepts the 1..20 boundary and rejects outside it", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, _} = MapDiscordNotification.update(rec, %{route_max_jumps: 1})
    assert {:ok, _} = MapDiscordNotification.update(rec, %{route_max_jumps: 20})
    assert {:error, _} = MapDiscordNotification.update(rec, %{route_max_jumps: 0})
    assert {:error, _} = MapDiscordNotification.update(rec, %{route_max_jumps: 21})
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/api/map_discord_notification_test.exs -k "route_max_jumps accepts"`
Expected: FAIL — this test is written against the `constraints min: 1, max: 20`
added in step 3.1's Step 3. If 3.1 has already landed, this passes
immediately; write and run it anyway as a standalone regression guard before
assuming so, since a future refactor of that attribute is exactly what this
guards against.

- [ ] **Step 3: Confirm or add the constraint**

No production change expected if 3.1 already added
`constraints min: 1, max: 20` to `route_max_jumps`. If this task is being
done out of order, add it now (see the attribute block in 3.1 Step 3).

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/unit/api/map_discord_notification_test.exs -k "route_max_jumps accepts"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/unit/api/map_discord_notification_test.exs
git commit -m "test(discord): pin route_max_jumps bounds at 1..20"
```

---

#### 3.4 — `MapDiscordWebhook`: `:route` role and `mention_targets`

- [ ] **Step 1: Write the failing test**

Add to `test/unit/api/map_discord_webhook_test.exs`, before the final `end`:

```elixir
  test "accepts the :route role", %{notification: notification} do
    assert {:ok, hook} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :route,
               webhook_url: valid_url()
             })

    assert hook.role == :route
    assert hook.mention_targets == []
  end

  test "mention_targets accepts well-formed user and role snowflakes", %{
    notification: notification
  } do
    assert {:ok, hook} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :route,
               webhook_url: valid_url(),
               mention_targets: ["user:123456789012345678", "role:98765432109876543"]
             })

    assert hook.mention_targets == ["user:123456789012345678", "role:98765432109876543"]
  end

  test "mention_targets rejects a handle, a bare id, and an out-of-range snowflake", %{
    notification: notification
  } do
    for bad <- ["@guarzo", "user:123", "role:123456789012345678901", "corp:123456789012345678"] do
      assert {:error, %Ash.Error.Invalid{}} =
               MapDiscordWebhook.create(%{
                 notification_id: notification.id,
                 role: :route,
                 webhook_url: valid_url(),
                 mention_targets: [bad]
               }),
             "expected #{inspect(bad)} to be rejected"
    end
  end

  test "mention_targets round-trips through update", %{notification: notification} do
    {:ok, hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :route,
        webhook_url: valid_url()
      })

    assert {:ok, updated} =
             MapDiscordWebhook.update(hook, %{mention_targets: ["role:112233445566778899"]})

    assert updated.mention_targets == ["role:112233445566778899"]
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/api/map_discord_webhook_test.exs -k "route OR mention_targets"`
Expected: FAIL — `:route` is rejected by the current `one_of` constraint, and
`mention_targets` is not a recognized input at all.

- [ ] **Step 3: Widen `role`, add `mention_targets`, wire the validation**

```elixir
    attribute :role, :atom do
      allow_nil? false
      constraints one_of: [:system, :character, :route]
    end
```

```elixir
    # Guild-scoped snowflakes to ping on this destination — see the design
    # doc's "Where configured targets live": these belong on the webhook row,
    # not anywhere map- or instance-wide, because a role/user id from one
    # guild is meaningless (and unrenderable) in another.
    attribute :mention_targets, {:array, :string} do
      default []
      allow_nil? false
    end
```

```elixir
    default_accept [:notification_id, :role, :webhook_url, :enabled?, :mention_targets]
```

```elixir
    create :create do
      primary? true
      validate {__MODULE__.ValidateWebhookUrl, []}
      validate {__MODULE__.ValidateMentionTargets, []}
      change after_transaction(&__MODULE__.invalidate_cache/3)
    end

    update :update do
      primary? true
      require_atomic? false
      # `mention_targets` is safe to add here unlike `notification_id`/`role`:
      # it carries no ownership semantics, only which snowflakes this
      # destination pings.
      accept [:webhook_url, :enabled?, :mention_targets]
      validate {__MODULE__.ValidateWebhookUrl, []}
      validate {__MODULE__.ValidateMentionTargets, []}
      change after_transaction(&__MODULE__.invalidate_cache/3)
    end
```

```elixir
  defmodule ValidateMentionTargets do
    @moduledoc false
    use Ash.Resource.Validation

    # Guild snowflakes are 17-20 decimal digits. Parseable, renderable
    # (`<@id>` / `<@&id>`), and unable to hold a handle that would silently
    # fail to ping — see the design doc's "Mentions" section.
    @target_regex ~r/^(user|role):\d{17,20}$/

    @impl true
    def validate(changeset, _opts, _context) do
      case Ash.Changeset.get_argument_or_attribute(changeset, :mention_targets) do
        nil ->
          :ok

        targets when is_list(targets) ->
          if Enum.all?(targets, &valid?/1) do
            :ok
          else
            {:error,
             field: :mention_targets,
             message: "each entry must match user:<id> or role:<id> (17-20 digit snowflake)"}
          end

        _ ->
          :ok
      end
    end

    defp valid?(target) when is_binary(target), do: Regex.match?(@target_regex, target)
    defp valid?(_), do: false
  end
```

Add `ValidateMentionTargets` as a sibling of `ValidateWebhookUrl`, after that
module's closing `end`.

- [ ] **Step 4: Generate and inspect the migration for `mention_targets`, then run it**

Run: `mix ash.codegen add_webhook_mention_targets`
Confirm the generated file under `priv/repo/migrations/` adds exactly one
column, `mention_targets text[] not null default '{}'`, to
`map_discord_webhooks_v1`. The `role` enum widening must produce **no**
migration — `role` is stored as `:text` (`map_discord_webhook.ex:199` before
this change), so `one_of` is an Ash-side constraint only. If the generated
diff includes anything touching `role`, stop and investigate before
committing; that would mean `role` is not actually a plain `:text` column in
this schema and the design's "no migration needed" claim was wrong.

Run: `mix ash.migrate`

Run: `mix test test/unit/api/map_discord_webhook_test.exs -k "route OR mention_targets"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/wanderer_app/api/map_discord_webhook.ex \
  test/unit/api/map_discord_webhook_test.exs \
  priv/repo/migrations/*_add_webhook_mention_targets.exs
git commit -m "feat(discord): add :route webhook role and mention_targets"
```

---

#### 3.5 — Config changes still invalidate the dispatcher cache

- [ ] **Step 1: Write the test**

```elixir
  test "updating route alert config invalidates the cache after the transaction, not inside it",
       %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, _rec} =
             rec
             |> Ash.Changeset.for_update(:update, %{
               route_alerts_enabled?: true,
               home_system_id: 30_000_142
             })
             |> cache_none_inside_transaction(map.id)
             |> Ash.update()

    assert Cachex.get(@cache, map.id) == {:ok, nil}
  end
```

Append this next to the existing "update invalidates the cache..." test,
reusing the file's `cache_none_inside_transaction/2` helper already defined
above it.

- [ ] **Step 2: Run test**

Run: `mix test test/unit/api/map_discord_notification_test.exs -k "route alert config invalidates"`
Expected: PASS immediately, with no production change — `:update` already
carries `change after_transaction(&__MODULE__.invalidate_cache/3)`
unconditionally, and 3.1's Step 3 only added attributes to that same
action's `accept` list. This test is a regression guard: it fails only if a
future change splits route-alert fields onto a separate action that forgets
the hook, exactly the mistake the moduledoc at `map_discord_notification.ex:147-164`
warns against.

- [ ] **Step 3: Commit**

```bash
git add test/unit/api/map_discord_notification_test.exs
git commit -m "test(discord): route alert config changes invalidate the dispatcher cache"
```

---

### Task 4: Mentions — env kill-switch, rendering, `allowed_mentions` hardening, and the regex fold

**Files:**
- Modify: `lib/wanderer_app/env.ex`
- Modify: `lib/wanderer_app/external_events/discord/worker.ex`
- Modify: `lib/wanderer_app/api/map_discord_webhook.ex` (section 4.4 only — rewrite `ValidateMentionTargets` to delegate; **do not** touch the accept lists, which Task 3 owns)
- Create: `lib/wanderer_app/external_events/discord/mentions.ex`
- Test: `test/unit/env_discord_mentions_test.exs` (new)
- Test: `test/unit/external_events/discord/mentions_test.exs` (new)
- Test: `test/unit/external_events/discord/worker_test.exs` (append)
- Test: `test/unit/api/map_discord_webhook_test.exs` (append, section 4.4 only)

**Interfaces:**
- Consumes: `MapDiscordWebhook.mention_targets` (Task 3), the existing
  `Worker`/`HttpClient` delivery path (`worker.ex`, `http_client.ex`).
- Produces:
  - `WandererApp.Env.discord_mentions_enabled?/0`
  - `WandererApp.ExternalEvents.Discord.Mentions.prefix/1`,
    `.allowed_mentions/1`, `.valid_target?/1` — consumed by Task 6's
    `format_route_alert/2` for the "ping on open only" `content` prefix, and
    by Task 3's `ValidateMentionTargets`, which section 4.4 below rewrites to
    delegate here (it ships with its own regex copy in Task 3 so that task can
    land standalone).
  - A hardened `Worker` that attaches `allowed_mentions` to any outgoing
    message carrying `"content"` that does not already have one.

Scope note, from the design doc's "Mention injection is a real risk": as of
this task, `allowed_mentions` appears **nowhere** in `lib/` or `test/`. That
is a latent gap, not a live vulnerability — the only three `"content"`
writers today are the static overflow string
(`embed_formatter.ex:133`), the static test message
(`discord_dispatcher.ex:146`), and `VoiceParticipants`-built mentions from
guild data. None of that is user-controlled text, and Discord does not fire
notifications for mentions inside embeds, so nothing is exploitable as
shipped. This task closes the gap anyway, because it is one careless
formatter change away from mattering and because Task 6 is about to add a
second, genuinely dynamic `"content"` writer (the route-alert ping prefix).

---

#### 4.1 — `Env.discord_mentions_enabled?/0`

- [ ] **Step 1: Write the failing test**

Create `test/unit/env_discord_mentions_test.exs`:

```elixir
defmodule WandererApp.EnvDiscordMentionsTest do
  # async: false — mutates the :external_events application env that other
  # test files also override.
  use ExUnit.Case, async: false

  alias WandererApp.Env

  setup do
    original = Application.get_env(:wanderer_app, :external_events, [])
    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
    %{original: original}
  end

  test "on by default", %{original: original} do
    Application.put_env(:wanderer_app, :external_events, original)
    assert Env.discord_mentions_enabled?()
  end

  test "can be switched off as an incident kill-switch", %{original: original} do
    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, :discord_mentions_enabled, false)
    )

    refute Env.discord_mentions_enabled?()
  end

  test "explicit true is still on", %{original: original} do
    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, :discord_mentions_enabled, true)
    )

    assert Env.discord_mentions_enabled?()
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/env_discord_mentions_test.exs`
Expected: FAIL with `UndefinedFunctionError` — `discord_mentions_enabled?/0`
does not exist yet.

- [ ] **Step 3: Add the function**

In `lib/wanderer_app/env.ex`, placed near `corp_tickers_enabled?/0` since it
follows the same shape:

```elixir
  @doc """
  Whether Discord messages may carry role/user pings via `allowed_mentions`.

  On by default, unlike `notable_items_enabled?/0`: mentions are already a
  per-map, per-webhook opt-in (`MapDiscordWebhook.mention_targets`), so an
  instance with nothing configured pings nobody regardless of this flag.
  This exists purely as an incident kill-switch — an operator who needs
  every mention silenced immediately (a runaway role ping, a compromised
  mention target) flips this without touching per-map config or waiting for
  a deploy.
  """
  def discord_mentions_enabled?() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:discord_mentions_enabled, true)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/unit/env_discord_mentions_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/wanderer_app/env.ex test/unit/env_discord_mentions_test.exs
git commit -m "feat(discord): add discord_mentions_enabled? incident kill-switch"
```

---

#### 4.2 — `Discord.Mentions`

- [ ] **Step 1: Write the failing test**

Create `test/unit/external_events/discord/mentions_test.exs`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.MentionsTest do
  use ExUnit.Case, async: true

  alias WandererApp.ExternalEvents.Discord.Mentions

  describe "prefix/1" do
    test "renders a user target" do
      assert Mentions.prefix(["user:123456789012345678"]) == "<@123456789012345678>"
    end

    test "renders a role target" do
      assert Mentions.prefix(["role:987654321098765432"]) == "<@&987654321098765432>"
    end

    test "joins multiple targets with a space, in order" do
      assert Mentions.prefix(["user:111111111111111111", "role:222222222222222222"]) ==
               "<@111111111111111111> <@&222222222222222222>"
    end

    test "empty list is nil" do
      assert Mentions.prefix([]) == nil
    end
  end

  describe "allowed_mentions/1" do
    test "empty targets still has parse: [] and empty lists" do
      assert Mentions.allowed_mentions([]) == %{"parse" => [], "users" => [], "roles" => []}
    end

    test "lists users and roles separately" do
      assert Mentions.allowed_mentions([
               "user:111111111111111111",
               "role:222222222222222222",
               "user:333333333333333333"
             ]) == %{
               "parse" => [],
               "users" => ["111111111111111111", "333333333333333333"],
               "roles" => ["222222222222222222"]
             }
    end
  end

  describe "valid_target?/1" do
    test "accepts well-formed user and role snowflakes" do
      assert Mentions.valid_target?("user:12345678901234567")
      assert Mentions.valid_target?("role:12345678901234567890")
    end

    test "rejects a handle, a bare id, an unknown prefix, and out-of-range lengths" do
      refute Mentions.valid_target?("@guarzo")
      refute Mentions.valid_target?("123456789012345678")
      refute Mentions.valid_target?("corp:123456789012345678")
      refute Mentions.valid_target?("user:123")
      refute Mentions.valid_target?("role:123456789012345678901")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/external_events/discord/mentions_test.exs`
Expected: FAIL — `WandererApp.ExternalEvents.Discord.Mentions` does not
exist.

- [ ] **Step 3: Create the module**

Create `lib/wanderer_app/external_events/discord/mentions.ex`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.Mentions do
  @moduledoc """
  Renders configured `MapDiscordWebhook.mention_targets` into Discord's two
  mention mechanisms: a `content` prefix that actually pings, and the
  `allowed_mentions` allowlist that makes doing so safe.

  Deliberately does not observe anything — no voice state, no map presence.
  Targets come only from what a map operator configured; see the design
  doc's "Why not VoiceParticipants".
  """

  # Guild snowflakes are 17-20 decimal digits — matches
  # `MapDiscordWebhook.ValidateMentionTargets`. Kept as a separate literal
  # here rather than a shared reference so this module has no compile-time
  # dependency on the Ash resource.
  @target_regex ~r/^(user|role):(\d{17,20})$/

  @doc """
  Whether `target` is a well-formed `"user:<id>"` or `"role:<id>"` mention
  target. Exposed so callers (and the resource-side validation) can check a
  single value without going through the list-shaped functions below.
  """
  @spec valid_target?(String.t()) :: boolean()
  def valid_target?(target) when is_binary(target), do: Regex.match?(@target_regex, target)
  def valid_target?(_), do: false

  @doc """
  Renders `targets` into a `content` prefix: `"user:123"` -> `"<@123>"`,
  `"role:456"` -> `"<@&456>"`, joined by spaces. `[]` -> `nil`, so callers can
  feed this straight to `VoiceParticipants.prepend_to_messages/2`, whose
  no-prefix case is also `nil`. Any entry that fails `valid_target?/1` is
  silently dropped rather than raising — malformed data should never turn
  into a delivery failure.
  """
  @spec prefix([String.t()]) :: String.t() | nil
  def prefix([]), do: nil

  def prefix(targets) do
    targets
    |> Enum.map(&render/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      rendered -> Enum.join(rendered, " ")
    end
  end

  @doc """
  Builds the `allowed_mentions` object for a Discord message body. ALWAYS
  includes `"parse" => []`, even for `[]` — an empty allowlist with no parse
  modes is what makes an unconfigured map safe to post to (see the design
  doc's "Mention injection is a real risk"). Invalid entries are dropped, the
  same as `prefix/1`.
  """
  @spec allowed_mentions([String.t()]) :: map()
  def allowed_mentions(targets) do
    {users, roles} =
      targets
      |> Enum.filter(&valid_target?/1)
      |> Enum.reduce({[], []}, fn target, {users, roles} ->
        case String.split(target, ":", parts: 2) do
          ["user", id] -> {[id | users], roles}
          ["role", id] -> {users, [id | roles]}
        end
      end)

    %{"parse" => [], "users" => Enum.reverse(users), "roles" => Enum.reverse(roles)}
  end

  defp render(target) do
    case Regex.run(@target_regex, target) do
      [_, "user", id] -> "<@#{id}>"
      [_, "role", id] -> "<@&#{id}>"
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/unit/external_events/discord/mentions_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/wanderer_app/external_events/discord/mentions.ex \
  test/unit/external_events/discord/mentions_test.exs
git commit -m "feat(discord): add Discord.Mentions rendering module"
```

---

#### 4.3 — Harden `Worker` so every `content`-carrying message ships `allowed_mentions`

- [ ] **Step 1: Write the failing test**

Append to `test/unit/external_events/discord/worker_test.exs`, near the other
delivery tests (it already has `message/0`, `HttpStub`, `wait_for_requests/1`
in scope):

```elixir
  describe "allowed_mentions hardening" do
    test "a message with content but no allowed_mentions gets a safe default attached", %{
      system: w
    } do
      WorkerSupervisor.deliver(w.id, [%{"content" => "test message"}])

      assert [{_url, body}] = wait_for_requests(1)
      assert body["allowed_mentions"] == %{"parse" => [], "users" => [], "roles" => []}
    end

    test "an explicit allowed_mentions is left untouched", %{system: w} do
      explicit = %{"parse" => [], "users" => ["111111111111111111"], "roles" => []}

      WorkerSupervisor.deliver(w.id, [
        %{"content" => "<@111111111111111111> route opened", "allowed_mentions" => explicit}
      ])

      assert [{_url, body}] = wait_for_requests(1)
      assert body["allowed_mentions"] == explicit
    end

    test "an embed-only message with no content is left without allowed_mentions", %{system: w} do
      WorkerSupervisor.deliver(w.id, [message()])

      assert [{_url, body}] = wait_for_requests(1)
      refute Map.has_key?(body, "allowed_mentions")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/external_events/discord/worker_test.exs -k "allowed_mentions hardening"`
Expected: FAIL — the first test fails because no `allowed_mentions` key is
added today; the other two currently pass by coincidence (nothing strips or
touches the key), so run them anyway to make sure they still hold once the
fix lands.

- [ ] **Step 3: Attach `allowed_mentions` at the single send point**

`worker.ex`'s `do_post/2` is the one place every outgoing message reaches
`HttpClient.post/2`, regardless of which caller built it — the test message,
the kill embeds, a voice-mention prefix, or (once Task 6 lands) a route
alert. Fixing it here hardens all of them at once, per the design doc's
"Mentions" section.

In `lib/wanderer_app/external_events/discord/worker.ex`:

```elixir
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.ExternalEvents.Discord.HttpClient
  alias WandererApp.ExternalEvents.Discord.Mentions
```

```elixir
  defp do_post(%{current: current} = state, webhook) do
    [message | _rest] = current.pending
    message = attach_allowed_mentions(message)
    url = webhook.webhook_url

    task =
      Task.Supervisor.async_nolink(
        WandererApp.ExternalEvents.Discord.TaskSupervisor,
        fn -> HttpClient.post(url, message) end
      )

    put_current(state, %{current | task_ref: task.ref})
  end

  # Every message that carries `"content"` must also carry `allowed_mentions`,
  # or Discord defaults to parsing @everyone/@here/user/role mentions found in
  # the text — see the design doc's "Mention injection is a real risk". A
  # caller that already set one (Task 6's route alerts, with real configured
  # targets) is left untouched; this only fills the gap for callers that
  # never think about mentions at all (the static test message, the overflow
  # string, voice-mention prefixes).
  defp attach_allowed_mentions(message) do
    if Map.has_key?(message, "content") and not Map.has_key?(message, "allowed_mentions") do
      Map.put(message, "allowed_mentions", Mentions.allowed_mentions([]))
    else
      message
    end
  end
```

- [ ] **Step 4: Run test to verify it passes, then run the wider Discord suite**

Run: `mix test test/unit/external_events/discord/worker_test.exs`
Expected: PASS, all cases including the pre-existing ones (payload shape is
unchanged for embed-only messages).

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs test/unit/external_events/discord/`
Expected: PASS — this payload change is defensive-only (adds a key, never
removes or renames one), so the existing kill and voice-mention assertions
on `body["content"]` must be unaffected. If any assertion there breaks, it
is asserting on the literal message map rather than the delivered body and
needs updating to account for the new key — do not weaken
`attach_allowed_mentions/1` to make a wrong assertion pass.

- [ ] **Step 5: Commit**

```bash
git add lib/wanderer_app/external_events/discord/worker.ex \
  test/unit/external_events/discord/worker_test.exs
git commit -m "fix(discord): attach allowed_mentions to every content-carrying message"
```

---

#### 4.4 — Fold Task 3's duplicated regex into `Mentions`

Task 3 shipped `MapDiscordWebhook.ValidateMentionTargets` with its own copy of
`~r/^(user|role):\d{17,20}$/` so that it could land before `Mentions` existed.
`Mentions` now exists, so the copy goes away and `Mentions.valid_target?/1`
becomes the single definition. This step is a **human-partner ruling made
before execution**, not an optional cleanup — do not skip it.

The direction of the dependency matters: the Ash resource depends on
`Mentions`, never the reverse. `Mentions` must keep its own regex literal and
gain no reference to the resource.

- [ ] **Step 1: Write the failing test**

Add to `test/unit/api/map_discord_webhook_test.exs`:

```elixir
  test "mention_targets validation rejects a malformed target via Mentions.valid_target?/1" do
    # Same rejection as before the fold — this asserts the behaviour survives
    # the delegation, and the assertion below pins that there is now exactly
    # one regex literal for mention targets in lib/.
    assert WandererApp.ExternalEvents.Discord.Mentions.valid_target?("role:123456789012345678")
    refute WandererApp.ExternalEvents.Discord.Mentions.valid_target?("role:123")

    resource_source =
      File.read!("lib/wanderer_app/api/map_discord_webhook.ex")

    refute resource_source =~ ~S{~r/^(user|role):},
           "ValidateMentionTargets must delegate to Mentions.valid_target?/1, not carry its own regex"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/api/map_discord_webhook_test.exs -k "malformed target via Mentions"`

If `-k` is not supported by this project's ExUnit invocation, run the file and
read the one failure.
Expected: FAIL on the `refute resource_source =~` assertion — Task 3's regex
literal is still in the resource. The two `valid_target?/1` assertions pass
already; they are there to prove the delegation target behaves identically.

- [ ] **Step 3: Delegate the validation**

In `lib/wanderer_app/api/map_discord_webhook.ex`, replace
`ValidateMentionTargets`'s `@target_regex` and `valid?/1` with a call into
`Mentions`. The `validate/3` body is unchanged.

```elixir
  defmodule ValidateMentionTargets do
    @moduledoc false
    use Ash.Resource.Validation

    alias WandererApp.ExternalEvents.Discord.Mentions

    @impl true
    def validate(changeset, _opts, _context) do
      case Ash.Changeset.get_argument_or_attribute(changeset, :mention_targets) do
        nil ->
          :ok

        targets when is_list(targets) ->
          if Enum.all?(targets, &Mentions.valid_target?/1) do
            :ok
          else
            {:error,
             field: :mention_targets,
             message: "each entry must match user:<id> or role:<id> (17-20 digit snowflake)"}
          end

        _ ->
          :ok
      end
    end
  end
```

Then update the comment above `@target_regex` in
`lib/wanderer_app/external_events/discord/mentions.ex` — it currently says
"matches `MapDiscordWebhook.ValidateMentionTargets`. Kept as a separate literal
here…", which is now backwards:

```elixir
  # Guild snowflakes are 17-20 decimal digits. This is the single definition of
  # a well-formed mention target; `MapDiscordWebhook.ValidateMentionTargets`
  # delegates here. The dependency runs resource -> Mentions and must not be
  # reversed: this module stays free of any Ash compile-time dependency.
  @target_regex ~r/^(user|role):(\d{17,20})$/
```

- [ ] **Step 4: Run the tests**

Run: `mix test test/unit/api/map_discord_webhook_test.exs test/unit/external_events/discord/mentions_test.exs`
Expected: PASS, including every `mention_targets` rejection case Task 3 wrote.
Those tests are the real proof of the fold — they were written against the
deleted regex and must pass unchanged against the delegated one.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/wanderer_app/api/map_discord_webhook.ex \
  lib/wanderer_app/external_events/discord/mentions.ex \
  test/unit/api/map_discord_webhook_test.exs
git add lib/wanderer_app/api/map_discord_webhook.ex \
  lib/wanderer_app/external_events/discord/mentions.ex \
  test/unit/api/map_discord_webhook_test.exs
git commit -m "refactor(discord): single source of truth for the mention-target pattern"
```

---

# Part 03 — Router destination and the route-alert embed

Depends on Task 3 (`:route` role, `mention_targets`) and Task 4 (`Mentions`
module) for compilation; both tasks below are otherwise self-contained per the
[shared contract](#shared-interface-contract).

### Task 5: `Router.route_destination/1`

**Files:**
- Modify: `lib/wanderer_app/external_events/discord/router.ex:1-94`
- Test: `test/unit/external_events/discord/router_test.exs`

**Interfaces:**
- Consumes: `notification.webhooks` (must be loaded, same convention as `route/3`), the private `webhook/2` and `usable/1` helpers already defined at `router.ex:85-93`.
- Produces: `@spec route_destination(struct()) :: {:ok, struct()} | :drop` (contract Task 5).

- [ ] **Step 1: Write the failing tests**

Append to `test/unit/external_events/discord/router_test.exs`, inside a new
`describe "route_destination/1"` block (add `alias WandererApp.SystemClass` is
already present; no new aliases needed):

```elixir
  describe "route_destination/1" do
    defp add_route_webhook(notification) do
      {:ok, wh} =
        MapDiscordWebhook.create(%{
          notification_id: notification.id,
          role: :route,
          webhook_url: "https://discord.com/api/webhooks/3/route"
        })

      wh
    end

    test "a :route webhook is selected when present and enabled", %{notification: n} do
      route_wh = add_route_webhook(n)

      assert {:ok, %{id: id}} = Router.route_destination(with_webhooks(n))
      assert id == route_wh.id
    end

    # Compatibility guarantee, mirroring rule 3's fallback: every map with only
    # a :system webhook keeps working with no user action once route alerts
    # ship.
    test "falls back to the system webhook when no :route row exists", %{
      notification: n,
      system_wh: system_wh
    } do
      assert {:ok, %{id: id}} = Router.route_destination(with_webhooks(n))
      assert id == system_wh.id
    end

    # DROP, NOT REROUTE — the same rule `RouterTest` asserts for the character
    # webhook in "a disabled character webhook drops rather than rerouting".
    # A route alert *is* the chain topology (see the Router moduledoc); posting
    # it to a channel the user did not choose for this purpose is a privacy
    # violation, not a convenience.
    test "a disabled :route webhook drops rather than falling back to :system", %{
      notification: n
    } do
      route_wh = add_route_webhook(n)
      {:ok, _} = MapDiscordWebhook.set_enabled(route_wh, %{enabled?: false})

      assert Router.route_destination(with_webhooks(n)) == :drop
    end

    test "drops when neither :route nor :system exists" do
      # `MapDiscordNotification.create/1` always seeds a :system webhook
      # (see the module setup), so simulate "neither configured" the same way
      # the unloaded-relationship test does: a notification struct whose
      # webhooks list is empty rather than absent.
      empty = %{webhooks: []}

      assert Router.route_destination(empty) == :drop
    end

    test "an unloaded :webhooks relationship drops instead of raising", %{notification: n} do
      {:ok, unloaded} = MapDiscordNotification.by_id(n.id)
      assert %Ash.NotLoaded{} = unloaded.webhooks

      assert Router.route_destination(unloaded) == :drop
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/unit/external_events/discord/router_test.exs`
Expected: FAIL with `UndefinedFunctionError` — `Router.route_destination/1` is
undefined.

- [ ] **Step 3: Extend the Router moduledoc**

Insert a new section into the moduledoc at `router.ex`, directly after the
existing "## Disabled destinations drop; they do not reroute" section (so it
reads as a sibling rule, not a footnote):

```elixir
  ## Route alerts have their own destination

  `route_destination/1` resolves a route alert to the `:route` webhook,
  falling back to the `:system` webhook when no `:route` row exists — the same
  fallback pattern rule 3 uses for `:character`. Existing maps therefore need
  no configuration change to keep receiving route alerts once the feature is
  enabled.

  A route alert *is* the chain topology: the path field names every system a
  scout has found, in order, from the map's home system to Jita. There is no
  redacted version of that message. A configured-but-disabled `:route` webhook
  therefore drops rather than falling back to `:system` — the same
  disabled-drops-never-reroutes rule above, for the same reason: silence must
  mean silence, not misdirection into a channel the user did not pick for a
  message this sensitive.
```

- [ ] **Step 4: Implement `route_destination/1`**

```elixir
  @doc """
  Resolves a route alert to a destination. `notification` must have
  `:webhooks` loaded.
  """
  @spec route_destination(struct()) :: {:ok, struct()} | :drop
  def route_destination(notification) do
    usable(webhook(notification, :route) || webhook(notification, :system))
  end
```

Place it directly after `route/3` and before the `webhook/2` private helpers,
so both public functions sit above the helpers they share. No changes to
`webhook/2` or `usable/1` — they are reused as-is.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/unit/external_events/discord/router_test.exs`
Expected: PASS, all tests including the pre-existing rule 1-4 tests.

- [ ] **Step 6: Format and lint**

Run: `mix format lib/wanderer_app/external_events/discord/router.ex test/unit/external_events/discord/router_test.exs`
Run: `mix credo lib/wanderer_app/external_events/discord/router.ex`
Expected: clean.

- [ ] **Step 7: Commit**
```bash
git add lib/wanderer_app/external_events/discord/router.ex test/unit/external_events/discord/router_test.exs
git commit -m "feat(discord): add route_destination/1 to Router

Resolves route alerts to the :route webhook, falling back to :system
when no :route row exists. A disabled :route webhook drops rather than
falling back, matching the existing disabled-drops-never-reroutes rule."
```

---

### Task 6: `EmbedFormatter.format_route_alert/2`

**Files:**
- Modify: `lib/wanderer_app/external_events/discord/embed_formatter.ex`
- Modify: `lib/wanderer_app/external_events/discord/system_name.ex`
- Test: `test/unit/external_events/discord/embed_formatter_test.exs`
- Test: `test/unit/external_events/discord/system_name_test.exs`

**Interfaces:**
- Consumes:
  - `alert :: %{kind: :opened | :improved, jumps: pos_integer(), path: [integer()], exit_system: integer() | nil, map_id: binary(), home_system_id: integer()}` (contract Task 2 / Task 6).
  - `opts :: [mention_targets: [String.t()]]`.
  - `WandererApp.ExternalEvents.Discord.SystemName.display_name/3`, extended with a literal `:route` clause (this task).
  - `WandererApp.ExternalEvents.Discord.Mentions.prefix/1` and `Mentions.allowed_mentions/1` (Task 4 — consumed, not reimplemented).
  - `WandererApp.Env.discord_mentions_enabled?/0` (Task 4).
- Produces: `@spec format_route_alert(alert :: map(), opts :: keyword()) :: [map()]` (contract Task 6). Each returned chunk is a map with `"embeds"`, and `"content"` / `"allowed_mentions"` together when pinging.

- [ ] **Step 1: Add the `:route` clause to `SystemName`, with its own failing test first**

Append to `test/unit/external_events/discord/system_name_test.exs`, in a new
`describe` block:

```elixir
  describe "display_name/3 for :route" do
    # Route alerts render the map's own chain, so they carry the same privacy
    # boundary as the :system webhook — map-local names are the point, not a
    # leak. This is why the Router passes the atom :route literally rather
    # than threading a variable: see the Router moduledoc's "Role resolution
    # is literal" note.
    test "resolves map-local names, same as :system", %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @wh_system,
        name: "J115405",
        temporary_name: "HOME"
      })

      assert SystemName.display_name(map.id, @wh_system, :route) == "HOME"
    end

    test "falls through to the canonical name when no map-local name is set", %{map: map} do
      assert SystemName.display_name(map.id, @ks_system, :route) == "Jita"
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord/system_name_test.exs`
Expected: FAIL — `FunctionClauseError` on `display_name/3`, no clause matching `:route`.

- [ ] **Step 3: Implement the `:route` clause**

```elixir
  @type role :: :system | :character | :route

  @doc """
  The system name to render for `role`.

  Returns `nil` when no name can be resolved at all; the formatter renders
  "Unknown system" in that case rather than guessing.
  """
  @spec display_name(String.t(), integer(), role()) :: String.t() | nil
  def display_name(_map_id, solar_system_id, :character), do: canonical_name(solar_system_id)

  def display_name(map_id, solar_system_id, :system) do
    map_local_name(map_id, solar_system_id) || canonical_name(solar_system_id)
  end

  # Route alerts carry the same map-local-names privacy boundary as :system:
  # the whole message is the map's own chain, so the resolution order matches
  # :system exactly rather than falling through to :character's canonical-only
  # behavior.
  def display_name(map_id, solar_system_id, :route) do
    map_local_name(map_id, solar_system_id) || canonical_name(solar_system_id)
  end
```

Update the moduledoc's `@type role` line implicitly via the typespec above;
no prose change needed since the existing moduledoc already frames this as a
"per destination role" resolver.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord/system_name_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the failing formatter tests — shape, title, and the improved variant**

Append to `test/unit/external_events/discord/embed_formatter_test.exs`. This
describe block needs real system names, so it seeds
`:system_static_info_cache` and switches the file's test to `WandererApp.DataCase`
semantics for this block only via a nested module, OR (simpler, matching how
`SystemNameTest` already does it) the whole file's `use` clause changes. Since
`format_route_alert/2` calls `SystemName.display_name/3`, which hits Cachex and
the DB, `EmbedFormatterTest` must change its `use` from `ExUnit.Case` to
`WandererApp.DataCase, async: false` — every existing test in this file is a
pure function over a killmail map and is unaffected by that switch.

```elixir
defmodule WandererApp.ExternalEvents.Discord.EmbedFormatterTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.ExternalEvents.Discord.EmbedFormatter
  alias WandererAppWeb.Factory
```

(Remove the old `use ExUnit.Case, async: true` line.)

Then add:

```elixir
  describe "format_route_alert/2" do
    @home 31_000_005
    @wh_hop 31_000_006
    @exit_system 30_002_053
    @jita 30_000_142

    setup do
      Cachex.put(:system_static_info_cache, @home, %{
        solar_system_id: @home,
        solar_system_name: "J115405",
        system_class: 3
      })

      Cachex.put(:system_static_info_cache, @wh_hop, %{
        solar_system_id: @wh_hop,
        solar_system_name: "J132412",
        system_class: 3
      })

      Cachex.put(:system_static_info_cache, @exit_system, %{
        solar_system_id: @exit_system,
        solar_system_name: "Amarr",
        system_class: 0
      })

      Cachex.put(:system_static_info_cache, @jita, %{
        solar_system_id: @jita,
        solar_system_name: "Jita",
        system_class: 0
      })

      on_exit(fn ->
        Enum.each(
          [@home, @wh_hop, @exit_system, @jita],
          &Cachex.del(:system_static_info_cache, &1)
        )
      end)

      map = Factory.insert(:map, %{})

      alert = %{
        kind: :opened,
        jumps: 4,
        path: [@home, @wh_hop, @exit_system, @jita],
        exit_system: @exit_system,
        map_id: map.id,
        home_system_id: @home
      }

      %{alert: alert}
    end

    test "an opened alert is a single green embed titled with the jump count", %{alert: alert} do
      assert [%{"embeds" => [embed]}] = EmbedFormatter.format_route_alert(alert, [])

      assert embed["title"] == "Highsec route to Jita — 4 jumps"
      assert embed["color"] == 0x2ECC71
    end

    test "the path renders home through Jita using map-local names for wormhole hops", %{
      alert: alert
    } do
      [%{"embeds" => [embed]}] = EmbedFormatter.format_route_alert(alert, [])

      path_field = Enum.find(embed["fields"], &(&1["name"] == "Path"))
      assert path_field["value"] == "J115405 → J132412 → Amarr → Jita"
    end

    test "the exit system gets its own field", %{alert: alert} do
      [%{"embeds" => [embed]}] = EmbedFormatter.format_route_alert(alert, [])

      exit_field = Enum.find(embed["fields"], &(&1["name"] == "Exit system"))
      assert exit_field["value"] == "Amarr"
    end

    test "an improved alert titles with 'improved' and carries no content", %{alert: alert} do
      improved = %{alert | kind: :improved, jumps: 3}

      assert [%{"embeds" => [embed]} = message] = EmbedFormatter.format_route_alert(improved, [])
      assert embed["title"] == "Highsec route to Jita improved — 3 jumps"
      refute Map.has_key?(message, "content")
    end
  end
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`
Expected: FAIL with `UndefinedFunctionError` for `format_route_alert/2`.

- [ ] **Step 7: Implement `format_route_alert/2` (no mentions yet)**

Add to `embed_formatter.ex`, near `format_batch/2`:

```elixir
  alias WandererApp.ExternalEvents.Discord.SystemName

  @color_route 0x2ECC71

  @doc """
  Formats a route-alert transition (design §"Message, mentions, and privacy")
  into Discord message chunks. `opts[:mention_targets]` are guild-scoped
  snowflake strings (`"user:123"` / `"role:456"`); pinging is gated on
  `WandererApp.Env.discord_mentions_enabled?/0` and fires only for `:opened`
  (design: "Ping on open only" — an "improved" update posts with no `content`,
  keeping the ping meaningful on a chain under active scanning).
  """
  @spec format_route_alert(map(), keyword()) :: [map()]
  def format_route_alert(alert, opts) do
    embed = route_embed(alert)
    mention_targets = Keyword.get(opts, :mention_targets, [])

    message =
      case route_ping(alert.kind, mention_targets) do
        nil ->
          %{"embeds" => [embed]}

        {content, allowed_mentions} ->
          %{"embeds" => [embed], "content" => content, "allowed_mentions" => allowed_mentions}
      end

    [message]
  end

  defp route_embed(alert) do
    %{
      "title" => route_title(alert),
      "color" => @color_route,
      "fields" => [
        %{"name" => "Path", "value" => route_path_text(alert), "inline" => false},
        %{
          "name" => "Exit system",
          "value" => route_system_name(alert, alert.exit_system),
          "inline" => true
        }
      ]
    }
    |> drop_nils()
  end

  defp route_title(%{kind: :opened, jumps: jumps}),
    do: "Highsec route to Jita — #{jumps} jumps"

  defp route_title(%{kind: :improved, jumps: jumps}),
    do: "Highsec route to Jita improved — #{jumps} jumps"

  defp route_path_text(alert) do
    alert.path
    |> Enum.map(&route_system_name(alert, &1))
    |> Enum.join(" → ")
  end

  # Literal :route, per SystemName's map-local-names privacy boundary — never
  # threaded through as a variable. See the Router moduledoc's "Role
  # resolution is literal" note and SystemName's own moduledoc.
  defp route_system_name(_alert, nil), do: "Unknown system"

  defp route_system_name(alert, solar_system_id) do
    SystemName.display_name(alert.map_id, solar_system_id, :route) || "Unknown system"
  end
```

Note: the destination is hardcoded to Jita (design decision 6), so the title
says "Jita" literally and no system-id constant is needed here.

- [ ] **Step 8: Run tests to verify the shape/title/path/exit-system tests pass**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs --only describe:"format_route_alert/2"`

(If `--only describe:` tag filtering is unavailable in this test's ExUnit
config, run the whole file instead:
`mix test test/unit/external_events/discord/embed_formatter_test.exs`.)

Expected: shape/title/path/exit-system/improved-no-content tests PASS.
Mention-related tests below still fail (not yet written) — this step only
confirms the embed itself.

- [ ] **Step 9: Write the failing mention tests**

Append to the same `describe "format_route_alert/2"` block:

```elixir
    test "an opened alert with configured targets carries a content ping and allowed_mentions", %{
      alert: alert
    } do
      put_discord_mentions_enabled(true)
      on_exit(fn -> Application.delete_env(:wanderer_app, :discord_mentions_enabled) end)

      [message] =
        EmbedFormatter.format_route_alert(alert, mention_targets: ["role:123456789012345678"])

      assert message["content"] =~ "<@&123456789012345678>"
      assert message["allowed_mentions"] ==
               %{"parse" => [], "users" => [], "roles" => ["123456789012345678"]}
    end

    test "no content when no mention targets are configured", %{alert: alert} do
      put_discord_mentions_enabled(true)
      on_exit(fn -> Application.delete_env(:wanderer_app, :discord_mentions_enabled) end)

      [message] = EmbedFormatter.format_route_alert(alert, mention_targets: [])

      refute Map.has_key?(message, "content")
      refute Map.has_key?(message, "allowed_mentions")
    end

    test "no content when the mentions env gate is off, even with targets configured", %{
      alert: alert
    } do
      put_discord_mentions_enabled(false)
      on_exit(fn -> Application.delete_env(:wanderer_app, :discord_mentions_enabled) end)

      [message] =
        EmbedFormatter.format_route_alert(alert, mention_targets: ["role:123456789012345678"])

      refute Map.has_key?(message, "content")
    end

    test "an improved alert never carries content, even with targets configured", %{alert: alert} do
      put_discord_mentions_enabled(true)
      on_exit(fn -> Application.delete_env(:wanderer_app, :discord_mentions_enabled) end)

      improved = %{alert | kind: :improved}

      [message] =
        EmbedFormatter.format_route_alert(improved, mention_targets: ["role:123456789012345678"])

      refute Map.has_key?(message, "content")
      refute Map.has_key?(message, "allowed_mentions")
    end

    # Mention injection guard (design: "Mention injection is a real risk").
    # A system's temporary_name is user-supplied and goes in the EMBED only;
    # it must never reach `content`, and `allowed_mentions` must stay a closed
    # allowlist regardless of what the embed renders.
    test "a system named @everyone does not inject into content", %{alert: alert} do
      put_discord_mentions_enabled(true)
      on_exit(fn -> Application.delete_env(:wanderer_app, :discord_mentions_enabled) end)

      Factory.insert(:map_system, %{
        map_id: alert.map_id,
        solar_system_id: @home,
        name: "J115405",
        temporary_name: "@everyone"
      })

      [message] =
        EmbedFormatter.format_route_alert(alert, mention_targets: ["role:123456789012345678"])

      refute message["content"] =~ "@everyone"
      assert message["allowed_mentions"] ==
               %{"parse" => [], "users" => [], "roles" => ["123456789012345678"]}

      [%{"embeds" => [embed]}] = [message]

      assert embed["fields"] |> Enum.find(&(&1["name"] == "Path")) |> Map.get("value") =~
               "@everyone"
    end

    # `Env.discord_mentions_enabled?/0` reads a `:discord_mentions_enabled` key
    # NESTED inside the `:external_events` keyword list (`env.ex:274-276`), not a
    # top-level app env key. Setting the top-level key would leave the gate at its
    # `true` default and the gate-off test would fail. Mirrors the shape used by
    # `test/unit/env_discord_mentions_test.exs`.
    defp put_discord_mentions_enabled(enabled?) do
      original = Application.get_env(:wanderer_app, :external_events, [])

      Application.put_env(
        :wanderer_app,
        :external_events,
        Keyword.put(original, :discord_mentions_enabled, enabled?)
      )

      on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
    end
```

- [ ] **Step 10: Run tests to verify they fail**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`
Expected: FAIL — `route_ping/2` undefined (compile error) or mention
assertions failing, since `format_route_alert/2` currently ignores
`mention_targets` and the mentions gate entirely.

- [ ] **Step 11: Implement mention gating, consuming `Mentions` (Task 4) — do not reimplement prefix/allowlist logic**

```elixir
  alias WandererApp.ExternalEvents.Discord.Mentions

  defp route_ping(:improved, _mention_targets), do: nil
  defp route_ping(:opened, []), do: nil

  defp route_ping(:opened, mention_targets) do
    if WandererApp.Env.discord_mentions_enabled?() do
      case Mentions.prefix(mention_targets) do
        nil -> nil
        content -> {content, Mentions.allowed_mentions(mention_targets)}
      end
    end
  end
```

- [ ] **Step 12: Run all tests to verify they pass**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs test/unit/external_events/discord/system_name_test.exs`
Expected: PASS, full file including every pre-existing kill-embed test (the
`use` clause change to `DataCase, async: false` must not break them — they are
pure functions and take no dependency on the case template beyond running
inside it).

- [ ] **Step 13: Format and lint**

Run: `mix format lib/wanderer_app/external_events/discord/embed_formatter.ex lib/wanderer_app/external_events/discord/system_name.ex test/unit/external_events/discord/embed_formatter_test.exs test/unit/external_events/discord/system_name_test.exs`
Run: `mix credo lib/wanderer_app/external_events/discord/embed_formatter.ex lib/wanderer_app/external_events/discord/system_name.ex`
Expected: clean.

- [ ] **Step 14: Commit**
```bash
git add lib/wanderer_app/external_events/discord/embed_formatter.ex \
        lib/wanderer_app/external_events/discord/system_name.ex \
        test/unit/external_events/discord/embed_formatter_test.exs \
        test/unit/external_events/discord/system_name_test.exs
git commit -m "feat(discord): add format_route_alert/2 to EmbedFormatter

Green embed with the full home-to-Jita path (map-local names via a
literal :route SystemName clause) and its own exit-system field. Pings
on :opened only, gated on the mentions env flag, and always pairs
content with a closed allowed_mentions allowlist so a user-supplied
system name can never inject a live mention."
```

---

### Task 7: `Discord.RouteWatcher`

**Files:**
- Create: `lib/wanderer_app/external_events/discord/route_watcher.ex`
- Test: `test/unit/external_events/discord/route_watcher_test.exs`

**Interfaces:**
- Consumes: `WandererApp.Api.MapDiscordNotification.by_map/1` (+ `Ash.load(:webhooks)`),
  `WandererApp.Map.RouteAlert.Evaluator.evaluate/2`, `.solver_settings/0`,
  `.jita_system_id/0` (Task 2); `WandererApp.Map.Routes.find_strict/5` (Task 1,
  behind a swappable impl — see Step 2); `WandererApp.ExternalEvents.Discord.Router.route_destination/1`
  (Task 5); `WandererApp.ExternalEvents.Discord.EmbedFormatter.format_route_alert/2`
  (Task 6); `WandererApp.ExternalEvents.Discord.WorkerSupervisor.deliver/2`
  (existing); `Task.Supervisor` named `WandererApp.ExternalEvents.Discord.TaskSupervisor`
  (existing, `worker_supervisor.ex:34`).
- Produces: `notify(binary()) :: :ok`, `config_version(struct()) :: binary()`,
  `registry/0` (consumed by Task 8), telemetry
  `[:wanderer_app, :discord, :route_alert]` with an `:outcome` tag.

One GenServer per map, Registry-addressed exactly like `Discord.Worker`
(`worker.ex:84-88`), except keyed by `map_id` instead of `webhook_id`, and it
owns its own Registry name rather than receiving one — `RouteWatcherSupervisor`
(Task 8) asks `RouteWatcher.registry/0` for it, so there is exactly one place
the atom is defined.

State shape:

```elixir
%{
  map_id: binary(),
  route_state: :unknown | :none | {:qualifying, pos_integer()},
  config_version: binary() | nil,
  timer_ref: reference() | nil,
  first_notify_at: integer() | nil,
  task: Task.t() | nil,
  task_deadline_ref: reference() | nil,
  rerun?: boolean(),
  pending_notification: struct() | nil,
  debounce_ms: pos_integer(),
  ceiling_ms: pos_integer(),
  task_timeout_ms: pos_integer()
}
```

`debounce_ms` / `ceiling_ms` / `task_timeout_ms` are overridable `start_link`
opts, mirroring `Worker`'s `idle_timeout` override (`worker.ex:105`), so tests
exercise the 10s/60s/20s behaviour in milliseconds instead of real seconds.

- [ ] **Step 1: Failing test — first notify arms the debounce and evaluates once**

```elixir
defmodule WandererApp.ExternalEvents.Discord.RouteWatcherTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.ExternalEvents.Discord.{RouteWatcher, WorkerSupervisor}
  alias WandererAppWeb.Factory

  @jita 30_000_142

  setup do
    start_supervised!(WorkerSupervisor)
    Application.put_env(:wanderer_app, :route_alert_solver, WandererApp.ExternalEvents.Discord.RouteWatcherTest.StubSolver)
    Process.put(:route_alert_stub_result, {:ok, %{routes: [], systems_static_data: []}})

    on_exit(fn -> Application.delete_env(:wanderer_app, :route_alert_solver) end)

    map = Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{map_id: map.id, webhook_url: "https://discord.com/api/webhooks/1/tok"})

    {:ok, notification} =
      MapDiscordNotification.update(notification, %{
        route_alerts_enabled?: true,
        home_system_id: 30_000_001,
        route_max_jumps: 5
      })

    %{map: map, notification: notification}
  end

  defp start_watcher(map_id, opts \\ []) do
    default = [map_id: map_id, debounce_ms: 30, ceiling_ms: 200, task_timeout_ms: 500]
    start_supervised!({RouteWatcher, Keyword.merge(default, opts)}, id: {RouteWatcher, map_id})
  end

  defp sync(map_id) do
    case Registry.lookup(RouteWatcher.registry(), map_id) do
      [{pid, _}] -> :sys.get_state(pid)
      [] -> flunk("no watcher registered for map #{map_id}")
    end
  end

  test "a single notify debounces then evaluates once", %{map: map} do
    {:ok, pid} = start_watcher(map.id)
    RouteWatcher.notify(map.id)

    # Immediately after notify the debounce timer is armed but no task has run.
    assert %{task: nil, timer_ref: ref} = :sys.get_state(pid)
    assert is_reference(ref)

    Process.sleep(60)
    assert %{route_state: :unknown, timer_ref: nil} = :sys.get_state(pid)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**
Run: `mix test test/unit/external_events/discord/route_watcher_test.exs`
Expected: FAIL — `module WandererApp.ExternalEvents.Discord.RouteWatcher is not available`
(the stub solver module referenced in `setup` does not exist yet either; add it
as a private module at the bottom of the test file once the real module compiles
— see Step 3).

- [ ] **Step 3: Minimal GenServer — registry, init, debounce timer, no solve yet**

```elixir
defmodule WandererApp.ExternalEvents.Discord.RouteWatcher do
  @moduledoc """
  One GenServer per map: owns the debounce timer, the last-known route state,
  its `config_version`, and the in-flight solver task. Registry-addressed like
  `Discord.Worker` (`worker.ex`), keyed by `map_id` instead of `webhook_id`.

  ## Why the solver task never blocks this process

  `Task.yield(20_000) || Task.shutdown(:brutal_kill)` — the idiom
  `DiscordDispatcher`'s enrichment steps use — is wrong here. It parks this
  process for up to 20s, during which it cannot receive the `notify` casts that
  are supposed to set the re-run flag. Those casts would sit in the mailbox and
  be processed *after* the stale result was already published, so a connection
  closing mid-solve could still produce a false "opened" alert. The dispatcher
  can afford to block because it is enriching a payload it already holds; this
  process cannot, because incoming events invalidate the work in flight.

  So the task runs via `Task.Supervisor.async_nolink/2`, its ref (inside the
  `%Task{}` struct, not bare) is stored in state, and both `{ref, result}` and
  `{:DOWN, ref, ...}` are handled in `handle_info`. A `Process.send_after/3`
  deadline enforces the 20s budget from the timeout handler, calling
  `Task.shutdown(task, :brutal_kill)` — which itself drains the matching `:DOWN`
  or `{ref, result}` message, so no separate cleanup clause is needed for a
  self-inflicted shutdown.

  A notify arriving while a task is in flight only sets `rerun?: true`; the
  result handler discards the in-flight answer and starts a fresh evaluation
  immediately when it lands with `rerun?` set, rather than publishing a result
  that may already be stale.
  """

  use GenServer, restart: :transient

  require Logger

  @registry WandererApp.ExternalEvents.Discord.RouteWatcherRegistry
  @cache :discord_route_alert_cache

  @debounce_ms 10_000
  @ceiling_ms 60_000
  @task_timeout_ms 20_000

  def start_link(opts) do
    map_id = Keyword.fetch!(opts, :map_id)
    GenServer.start_link(__MODULE__, opts, name: via(map_id))
  end

  @doc "Queues a re-evaluation for this map. The watcher must already be running."
  @spec notify(binary()) :: :ok
  def notify(map_id) do
    GenServer.cast(via(map_id), :notify)
  end

  @doc "The Registry this module is addressed through. Owned here, read by RouteWatcherSupervisor."
  def registry, do: @registry

  defp via(map_id), do: {:via, Registry, {@registry, map_id}}

  @impl true
  def init(opts) do
    map_id = Keyword.fetch!(opts, :map_id)

    state = %{
      map_id: map_id,
      route_state: :unknown,
      config_version: nil,
      timer_ref: nil,
      first_notify_at: nil,
      task: nil,
      task_deadline_ref: nil,
      rerun?: false,
      pending_notification: nil,
      debounce_ms: Keyword.get(opts, :debounce_ms, @debounce_ms),
      ceiling_ms: Keyword.get(opts, :ceiling_ms, @ceiling_ms),
      task_timeout_ms: Keyword.get(opts, :task_timeout_ms, @task_timeout_ms)
    }

    {:ok, rehydrate(state)}
  end

  # Only the raw {route_state, config_version} pair is rehydrated here. The
  # config_version comparison against the map's CURRENT configuration happens
  # in start_evaluation/1 on the next notify, exactly as it does on every other
  # evaluation — deferring it avoids a DB read on every process start for
  # watchers that are started but never fire (e.g. a crash-restart loop).
  defp rehydrate(state) do
    case Cachex.get(@cache, state.map_id) do
      {:ok, %{route_state: rs, config_version: cv}} ->
        %{state | route_state: rs, config_version: cv}

      _ ->
        state
    end
  rescue
    # Cache not started in every test context; a fresh :unknown state is the
    # correct fallback, not a crash.
    _ -> state
  end

  @impl true
  def handle_cast(:notify, %{task: task} = state) when not is_nil(task) do
    {:noreply, %{state | rerun?: true}}
  end

  def handle_cast(:notify, state) do
    {:noreply, arm_timer(state)}
  end

  defp arm_timer(state) do
    now = System.monotonic_time(:millisecond)
    first_notify_at = state.first_notify_at || now

    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Re-armed to the full debounce on every notify, but never pushed past the
    # ceiling measured from the FIRST notify of this burst — otherwise a chain
    # under continuous scanning (a notify at least once every debounce_ms)
    # would never evaluate at all.
    remaining_to_ceiling = first_notify_at + state.ceiling_ms - now
    delay = min(state.debounce_ms, max(remaining_to_ceiling, 0))

    timer_ref = Process.send_after(self(), :evaluate, delay)
    %{state | timer_ref: timer_ref, first_notify_at: first_notify_at}
  end

  @impl true
  def handle_info(:evaluate, state) do
    {:noreply, %{state | timer_ref: nil, first_notify_at: nil}}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**
Run: `mix test test/unit/external_events/discord/route_watcher_test.exs`
Expected: PASS (the `:evaluate` handler above only clears the timer; the
`route_state` stays `:unknown` by construction, matching the assertion).

- [ ] **Step 5: Commit**
```bash
git add lib/wanderer_app/external_events/discord/route_watcher.ex test/unit/external_events/discord/route_watcher_test.exs
git commit -m "feat(discord): scaffold RouteWatcher debounce timer"
```

- [ ] **Step 6: Failing test — the solve runs off-process and the four transitions**

Add a private stub solver at the bottom of the test file (referenced from Step
1's `setup`) and the four-transition test:

```elixir
defmodule WandererApp.ExternalEvents.Discord.RouteWatcherTest.StubSolver do
  @moduledoc """
  Stands in for `WandererApp.Map.Routes.find_strict/5`. Reads its canned answer
  from the process dictionary of whichever process calls it — that process is
  the Task the watcher spawns, not the test process, so the value is seeded via
  `Application.put_env/3` instead (read once per call, mutated between phases
  of a single test).
  """
  def find_strict(_map_id, _hubs, _origin, _settings, _hubs_limit_reached?) do
    Application.get_env(:wanderer_app, :route_alert_stub_result, {:ok, %{routes: [], systems_static_data: []}})
  end
end
```

```elixir
  describe "transitions" do
    setup %{map: map} do
      {:ok, pid} = start_watcher(map.id)
      %{pid: pid}
    end

    # `Evaluator` is fail-closed: a system absent from `systems_static_data`
    # disqualifies the whole route to `:none` (`evaluator.ex:63-64`, and
    # `system_qualifies?/2`'s `:error -> false` clause). An empty list here
    # would make every "qualifying" test below assert against `:none` and
    # silently stop testing the transition logic — so the origin AND every hop
    # must be present and highsec.
    defp qualifying_result(jumps, home) do
      path = [home | Enum.to_list((home + 1)..(home + jumps))]

      {:ok,
       %{
         routes: [
           %{
             has_connection: true,
             systems: Enum.to_list((home + 1)..(home + jumps)),
             origin: home,
             destination: @jita,
             success: true
           }
         ],
         systems_static_data:
           Enum.map(path, &%{solar_system_id: &1, security: "0.9", system_class: 7})
       }}
    end

    test "unknown -> qualifying posts opened", %{map: map, pid: pid} do
      Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(4, 30_000_001))

      RouteWatcher.notify(map.id)
      Process.sleep(60)

      assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)
    end

    test "qualifying(4) -> qualifying(2) posts improved", %{map: map, pid: pid} do
      Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(4, 30_000_001))
      RouteWatcher.notify(map.id)
      Process.sleep(60)

      Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(2, 30_000_001))
      RouteWatcher.notify(map.id)
      Process.sleep(60)

      assert %{route_state: {:qualifying, 2}} = :sys.get_state(pid)
    end

    test "qualifying(2) -> qualifying(4) is silent but still stores 4", %{map: map, pid: pid} do
      Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(2, 30_000_001))
      RouteWatcher.notify(map.id)
      Process.sleep(60)

      Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(4, 30_000_001))
      RouteWatcher.notify(map.id)
      Process.sleep(60)

      assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)
    end

    test "qualifying -> none clears silently", %{map: map, pid: pid} do
      Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(4, 30_000_001))
      RouteWatcher.notify(map.id)
      Process.sleep(60)

      Application.put_env(
        :wanderer_app,
        :route_alert_stub_result,
        {:ok, %{routes: [%{has_connection: false, systems: [], origin: 30_000_001, destination: @jita, success: false}], systems_static_data: []}}
      )

      RouteWatcher.notify(map.id)
      Process.sleep(60)

      assert %{route_state: :none} = :sys.get_state(pid)
    end
  end
```

- [ ] **Step 7: Run test to verify it fails**
Run: `mix test test/unit/external_events/discord/route_watcher_test.exs`
Expected: FAIL — `route_state` stays `:unknown` in every case; `:evaluate` does
not yet launch a task or call the Evaluator.

- [ ] **Step 8: Implement the solve, the Evaluator hand-off, and the four-way transition**

```elixir
  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.ExternalEvents.Discord.{Router, WorkerSupervisor, EmbedFormatter}
  alias WandererApp.Map.RouteAlert.Evaluator

  def handle_info(:evaluate, state) do
    state = %{state | timer_ref: nil, first_notify_at: nil}
    {:noreply, start_evaluation(state)}
  end

  # -- launching a solve ------------------------------------------------------

  defp start_evaluation(state) do
    case load_notification(state.map_id) do
      {:ok, notification} -> start_evaluation(state, notification)
      :error -> state
    end
  end

  defp start_evaluation(state, notification) do
    cv = config_version(notification)

    # A config change discards stored state to :unknown rather than comparing
    # against a state that describes a different question ("State identity is
    # versioned by config" in the design doc).
    state =
      if cv != state.config_version do
        %{state | route_state: :unknown, config_version: cv} |> persist()
      else
        state
      end

    if notification.route_alerts_enabled? and not is_nil(notification.home_system_id) do
      launch_task(state, notification)
    else
      # Disabling clears outright. Re-enabling then starts from :none, which
      # the transition table treats identically to :unknown — the next
      # qualifying result posts "opened" either way, so no special case.
      %{state | route_state: :none, config_version: cv, pending_notification: nil}
      |> persist()
    end
  end

  defp launch_task(state, notification) do
    task =
      Task.Supervisor.async_nolink(
        WandererApp.ExternalEvents.Discord.TaskSupervisor,
        fn -> solver_impl().find_strict(
          notification.map_id,
          [Integer.to_string(Evaluator.jita_system_id())],
          Integer.to_string(notification.home_system_id),
          Evaluator.solver_settings(),
          false
        ) end
      )

    deadline_ref = Process.send_after(self(), {:task_timeout, task.ref}, state.task_timeout_ms)

    %{
      state
      | task: task,
        task_deadline_ref: deadline_ref,
        rerun?: false,
        pending_notification: notification
    }
  end

  defp solver_impl,
    do: Application.get_env(:wanderer_app, :route_alert_solver, WandererApp.Map.Routes)

  defp load_notification(map_id) do
    with {:ok, notification} when not is_nil(notification) <- MapDiscordNotification.by_map(map_id),
         {:ok, notification} <- Ash.load(notification, :webhooks) do
      {:ok, notification}
    else
      _ -> :error
    end
  end

  # -- the result --------------------------------------------------------------

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    if state.task_deadline_ref, do: Process.cancel_timer(state.task_deadline_ref)
    state = %{state | task: nil, task_deadline_ref: nil}
    {:noreply, land_result(state, result)}
  end

  # The task crashed outright (not our own :brutal_kill — that path is handled
  # entirely inside Task.shutdown/2 in the timeout handler below and never
  # reaches here). Treated the same as a solver error: keep state, log, emit
  # telemetry, do not alert.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state)
      when is_reference(ref) do
    if state.task_deadline_ref, do: Process.cancel_timer(state.task_deadline_ref)
    state = %{state | task: nil, task_deadline_ref: nil}
    {:noreply, land_result(state, {:error, reason})}
  end

  # A late reply for a task we already shut down or whose deadline already
  # fired for a *different* in-flight task (map restarted evaluation).
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    {:noreply, state}
  end

  defp land_result(state, result) do
    if state.rerun? do
      # A topology change arrived mid-solve: this answer no longer describes
      # the current chain. Discard it and start a fresh solve immediately
      # rather than waiting out another debounce window — the coalescing
      # already happened via the flag.
      start_evaluation(%{state | rerun?: false})
    else
      notification = state.pending_notification
      outcome = Evaluator.evaluate(result, max_jumps: notification.route_max_jumps)
      state = %{state | pending_notification: nil}
      transition(state, notification, outcome)
    end
  end

  # -- the transition table -----------------------------------------------------

  defp transition(state, _notification, :unknown) do
    emit_telemetry(state, :unknown)
    persist(state)
  end

  defp transition(state, _notification, :none) do
    emit_telemetry(state, :none)
    persist(%{state | route_state: :none})
  end

  defp transition(%{route_state: prev} = state, notification, {:qualifying, %{jumps: jumps} = q}) do
    case prev do
      p when p in [:unknown, :none] -> alert(state, notification, :opened, q, jumps)
      {:qualifying, old} when jumps < old -> alert(state, notification, :improved, q, jumps)
      {:qualifying, _old} -> persist(%{state | route_state: {:qualifying, jumps}})
    end
  end

  # State is written BEFORE delivery, matching DiscordDispatcher's
  # at-most-once posture (`handle_delivery_result/4`): a delivery failure loses
  # one alert rather than repeating it. `{:error, :not_running}` means nothing
  # was enqueued, so the write is reverted exactly as the dispatcher does.
  defp alert(state, notification, kind, qualifying, jumps) do
    # `state` still carries the PREVIOUS route_state here — captured as
    # `prev_state` before the optimistic write, so a reverted delivery
    # restores exactly what was there before this transition, not the new
    # value we are about to persist.
    prev_state = state
    new_state = persist(%{state | route_state: {:qualifying, jumps}})

    case Router.route_destination(notification) do
      {:ok, webhook} ->
        deliver_alert(new_state, prev_state, notification, webhook, kind, qualifying, jumps)

      :drop ->
        new_state
    end
  end

  defp deliver_alert(state, prev_state, notification, webhook, kind, qualifying, jumps) do
    alert = %{
      kind: kind,
      jumps: jumps,
      path: qualifying.path,
      exit_system: qualifying.exit_system,
      map_id: state.map_id,
      home_system_id: notification.home_system_id
    }

    messages = EmbedFormatter.format_route_alert(alert, mention_targets: webhook.mention_targets)

    case WorkerSupervisor.deliver(webhook.id, messages) do
      :ok ->
        emit_telemetry(state, kind)
        state

      # Nothing was enqueued: revert the optimistic write to what it was
      # before this transition, mirroring `handle_delivery_result/4`'s
      # `{:error, :not_running}` clause in the dispatcher.
      {:error, :not_running} ->
        persist(%{state | route_state: prev_state.route_state})
    end
  end

  defp emit_telemetry(state, outcome) do
    :telemetry.execute(
      [:wanderer_app, :discord, :route_alert],
      %{count: 1},
      %{map_id: state.map_id, outcome: outcome}
    )
  end

  defp persist(state) do
    Cachex.put(@cache, state.map_id, %{route_state: state.route_state, config_version: state.config_version})
    state
  rescue
    _ -> state
  end

  # -- config identity ---------------------------------------------------------

  @doc """
  Hashes the configuration that a stored route_state's meaning depends on.
  A mismatch on rehydrate or on any evaluation means the stored value describes
  a different question, and is discarded rather than compared
  ("State identity is versioned by config" in the design doc).
  """
  @spec config_version(struct()) :: binary()
  def config_version(%{home_system_id: home_system_id, route_max_jumps: route_max_jumps}) do
    {home_system_id, route_max_jumps, Evaluator.solver_settings()}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # -- the 20s solve deadline ---------------------------------------------------

  # Task.yield(20_000) || Task.shutdown(:brutal_kill) is deliberately NOT used
  # here — see the moduledoc. This handler is the alternative: a self-scheduled
  # message fires the deadline instead of a blocking wait, so the mailbox (and
  # therefore `notify/1`) stays live for the entire 20s.
  def handle_info({:task_timeout, ref}, %{task: %Task{ref: ref}} = state) do
    Task.shutdown(state.task, :brutal_kill)

    Logger.warning(
      "[Discord.RouteWatcher] route solve exceeded #{state.task_timeout_ms}ms for map #{state.map_id}; killed"
    )

    emit_telemetry(state, :timeout)
    state = %{state | task: nil, task_deadline_ref: nil}

    state =
      if state.rerun? do
        start_evaluation(%{state | rerun?: false})
      else
        state
      end

    {:noreply, state}
  end

  # A deadline message for a task that already finished or was already killed —
  # its :task_timeout was cancelled, but cancellation is not guaranteed to beat
  # a message already in the mailbox. Harmless no-op.
  def handle_info({:task_timeout, _stale_ref}, state), do: {:noreply, state}
end
```

- [ ] **Step 9: Run test to verify it passes**
Run: `mix test test/unit/external_events/discord/route_watcher_test.exs`
Expected: PASS — all four transition tests and the Step-1 debounce test green.

- [ ] **Step 10: Commit**
```bash
git add lib/wanderer_app/external_events/discord/route_watcher.ex test/unit/external_events/discord/route_watcher_test.exs
git commit -m "feat(discord): RouteWatcher solves off-process and applies the transition table"
```

- [ ] **Step 11: Failing test — solver error keeps state, and config_version mismatch resets to :unknown**

```elixir
  test "a solver error keeps prior state and does not alert", %{map: map, pid: pid} do
    Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(4, 30_000_001))
    RouteWatcher.notify(map.id)
    Process.sleep(60)
    assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)

    Application.put_env(:wanderer_app, :route_alert_stub_result, {:error, :solver_unreachable})
    RouteWatcher.notify(map.id)
    Process.sleep(60)

    assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)
  end

  test "a route_max_jumps change resets to :unknown and the next qualifying result opens",
       %{map: map, notification: notification, pid: pid} do
    Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(4, 30_000_001))
    RouteWatcher.notify(map.id)
    Process.sleep(60)
    assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)

    {:ok, _} = MapDiscordNotification.update(notification, %{route_max_jumps: 2})

    # A stored {:qualifying, 4} against the OLD threshold must not be compared
    # against the new one — it should reset, not silently suppress "opened".
    RouteWatcher.notify(map.id)
    Process.sleep(60)
    # NOT `:unknown`: `start_evaluation/2` resets AND re-solves in the same
    # pass, so this notify's still-cached 4-jump stub is re-evaluated
    # immediately against the NEW max_jumps of 2 and disqualifies. The
    # meaningful assertion is that it is anything other than the stale
    # {:qualifying, 4}.
    assert %{route_state: :none} = :sys.get_state(pid)

    # The stub must now be a route that qualifies under the NEW threshold.
    # Leaving it at 4 jumps would be unreachable: `Evaluator` disqualifies
    # jumps(4) > max_jumps(2), so the state could only ever reach `:none` and
    # the "a fresh qualifying route still opens" half of this test would be
    # asserting something that cannot happen.
    Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(2, 30_000_001))

    RouteWatcher.notify(map.id)
    Process.sleep(60)
    assert %{route_state: {:qualifying, 2}} = :sys.get_state(pid)
  end
```

- [ ] **Step 12: Run the test — this step is verification-only, not RED/GREEN**
Run: `mix test test/unit/external_events/discord/route_watcher_test.exs`

Both assertions are expected to **PASS** without new production code: the
solver-error case is correct by construction (`transition/3`'s `:unknown` clause
never touches `route_state`), and the config-version reset was implemented in
Step 8. This step exists to prove those two paths are actually covered by tests
rather than only by inspection.

If either assertion fails, that is a real defect in Step 8's version check —
fix `start_evaluation/2`, not the test.

- [ ] **Step 13: Commit**
```bash
git add test/unit/external_events/discord/route_watcher_test.exs
git commit -m "test(discord): cover solver-error and config-version-mismatch state handling"
```

- [ ] **Step 14: Failing test — a notify mid-solve is received and sets rerun?, and the stale result is discarded**

This is the test that fails under a blocking `Task.yield` — see the design
doc's "Data flow" step 6. It needs a solver stub that blocks until told to
proceed, so the test can notify while a task is provably in flight:

```elixir
defmodule WandererApp.ExternalEvents.Discord.RouteWatcherTest.BlockingSolver do
  @moduledoc "Blocks until released via a message to the task's own pid, then returns the seeded result."
  def find_strict(map_id, hubs, origin, settings, hubs_limit_reached?) do
    receive do
      :release -> :ok
    end

    WandererApp.ExternalEvents.Discord.RouteWatcherTest.StubSolver.find_strict(
      map_id,
      hubs,
      origin,
      settings,
      hubs_limit_reached?
    )
  end
end
```

```elixir
  test "a notify delivered while a solve is in flight sets rerun? and the stale result is discarded",
       %{map: map, pid: pid} do
    Application.put_env(
      :wanderer_app,
      :route_alert_solver,
      WandererApp.ExternalEvents.Discord.RouteWatcherTest.BlockingSolver
    )

    Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(4, 30_000_001))

    RouteWatcher.notify(map.id)
    # Give the task time to start and block inside `receive`, but not to finish.
    Process.sleep(30)
    assert %{task: %Task{}} = :sys.get_state(pid)

    # THE assertion that fails under Task.yield(20_000): a blocking watcher
    # cannot process this cast at all until the yield times out or returns.
    RouteWatcher.notify(map.id)
    assert %{rerun?: true} = :sys.get_state(pid)

    # Release the blocked task. Its answer must be discarded — a fresh solve
    # starts instead — so route_state must NOT become {:qualifying, 4} from
    # THIS answer. Assert indirectly: after release, a second answer of 2
    # jumps is what should land, proving the first was thrown away.
    Application.put_env(
      :wanderer_app,
      :route_alert_solver,
      WandererApp.ExternalEvents.Discord.RouteWatcherTest.StubSolver
    )

    Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(2, 30_000_001))

    %{task: task} = :sys.get_state(pid)
    send(task.pid, :release)

    Process.sleep(60)
    assert %{route_state: {:qualifying, 2}, rerun?: false} = :sys.get_state(pid)
  end
```

- [ ] **Step 15: Run test to verify it fails**
Run: `mix test test/unit/external_events/discord/route_watcher_test.exs`
Expected: the `rerun?: true` assertion should already PASS from Step 3's
`handle_cast(:notify, %{task: task} = state) when not is_nil(task)` clause —
this step's actual new coverage is the discard-and-restart path. If the final
`route_state` assertion FAILS, confirm `land_result/2`'s `rerun?` branch calls
`start_evaluation/1` rather than `transition/3` (Step 8); fix and re-run.

- [ ] **Step 16: Commit**
```bash
git add lib/wanderer_app/external_events/discord/route_watcher.ex test/unit/external_events/discord/route_watcher_test.exs
git commit -m "test(discord): a notify mid-solve sets rerun and discards the stale result"
```

- [ ] **Step 17: Failing test — the 20s deadline shuts the task down without crashing the watcher, and restart rehydration**

```elixir
  test "the task deadline shuts the task down without crashing the watcher", %{map: map} do
    Application.put_env(
      :wanderer_app,
      :route_alert_solver,
      WandererApp.ExternalEvents.Discord.RouteWatcherTest.BlockingSolver
    )

    {:ok, pid} = start_watcher(map.id, task_timeout_ms: 30)

    RouteWatcher.notify(map.id)
    Process.sleep(60)

    assert Process.alive?(pid)
    assert %{task: nil, task_deadline_ref: nil} = :sys.get_state(pid)
  end

  test "restart rehydrates from Cachex so a still-open route is not re-announced", %{map: map} do
    Application.put_env(:wanderer_app, :route_alert_stub_result, qualifying_result(4, 30_000_001))
    {:ok, pid} = start_watcher(map.id)
    RouteWatcher.notify(map.id)
    Process.sleep(60)
    assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid)

    GenServer.stop(pid, :normal)
    {:ok, pid2} = start_watcher(map.id)

    assert %{route_state: {:qualifying, 4}} = :sys.get_state(pid2)
  end
```

- [ ] **Step 18: Run test to verify it passes**
Run: `mix test test/unit/external_events/discord/route_watcher_test.exs`
Expected: PASS for both if Steps 3–8 were implemented as written (the deadline
handler and `rehydrate/1` already exist); if the deadline test fails, confirm
`Task.shutdown/2` is called with the `%Task{}` struct held in `state.task`, not
a bare reference — `Task.shutdown/2` requires the struct, not the ref.

- [ ] **Step 19: Commit**
```bash
git add test/unit/external_events/discord/route_watcher_test.exs
git commit -m "test(discord): cover the 20s solve deadline and restart rehydration"
```

- [ ] **Step 20: Run the full test file and the project checks**
Run: `mix test test/unit/external_events/discord/route_watcher_test.exs && mix format --check-formatted lib/wanderer_app/external_events/discord/route_watcher.ex && mix credo lib/wanderer_app/external_events/discord/route_watcher.ex`
Expected: all green. Fix any formatting or Credo findings and commit as a
follow-up `style:` commit before moving to Task 8.

---

### Task 8: `Discord.RouteWatcherSupervisor` + application wiring

**Files:**
- Create: `lib/wanderer_app/external_events/discord/route_watcher_supervisor.ex`
- Modify: `lib/wanderer_app/application.ex:141-154` (new Cachex worker),
  `lib/wanderer_app/application.ex:265-282` (webhooks_enabled service list)
- Modify: `lib/wanderer_app/api/map_discord_notification.ex:178-193` (`after_destroy`)
- Test: `test/unit/external_events/discord/route_watcher_supervisor_test.exs`

**Interfaces:**
- Consumes: `Discord.RouteWatcher.registry/0`, `Discord.RouteWatcher.start_link/1`
  (Task 7).
- Produces: `notify(binary()) :: :ok`, `stop_watcher(binary()) :: :ok`.

Mirrors `Discord.WorkerSupervisor` closely (`worker_supervisor.ex`): a
`Registry` plus a `DynamicSupervisor` under `:rest_for_one`, for the identical
reason stated in that module's comment (`worker_supervisor.ex:38-42`) — a
Registry crash would leave running watchers alive but unreachable, and the
next `notify/1` would start a second watcher for the same map racing the
orphan; restarting the dynamic supervisor after the Registry clears that. No
`Task.Supervisor` child here: `Discord.RouteWatcher` reuses the one
`WorkerSupervisor` already starts (`worker_supervisor.ex:34`), since it is a
shared, unbounded task pool, not a per-feature resource.

`notify/1` guards `Process.whereis(@registry)` exactly as
`WorkerSupervisor.ensure_worker/1` does (`worker_supervisor.ex:112-120`): a
no-op, not a crash, when webhooks are globally disabled and this supervisor
was never started — `DiscordDispatcher`'s new topology clause (Task 9) must be
able to call this unconditionally.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule WandererApp.ExternalEvents.Discord.RouteWatcherSupervisorTest do
  use ExUnit.Case, async: false

  alias WandererApp.ExternalEvents.Discord.{RouteWatcher, RouteWatcherSupervisor}

  setup do
    start_supervised!(RouteWatcherSupervisor)
    :ok
  end

  test "notify starts a watcher on demand" do
    map_id = Ecto.UUID.generate()
    assert :ok = RouteWatcherSupervisor.notify(map_id)
    assert [{_pid, _}] = Registry.lookup(RouteWatcher.registry(), map_id)
  end

  test "two notifies for one map reuse one watcher" do
    map_id = Ecto.UUID.generate()
    RouteWatcherSupervisor.notify(map_id)
    [{pid1, _}] = Registry.lookup(RouteWatcher.registry(), map_id)

    RouteWatcherSupervisor.notify(map_id)
    [{pid2, _}] = Registry.lookup(RouteWatcher.registry(), map_id)

    assert pid1 == pid2
  end

  test "stop_watcher removes the running watcher" do
    map_id = Ecto.UUID.generate()
    RouteWatcherSupervisor.notify(map_id)
    assert [{pid, _}] = Registry.lookup(RouteWatcher.registry(), map_id)

    assert :ok = RouteWatcherSupervisor.stop_watcher(map_id)
    refute Process.alive?(pid)
    assert [] = Registry.lookup(RouteWatcher.registry(), map_id)
  end

  test "notify is a no-op when the supervisor tree is not running" do
    stop_supervised!(RouteWatcherSupervisor)
    map_id = Ecto.UUID.generate()
    assert :ok = RouteWatcherSupervisor.notify(map_id)
  end

  test "stop_watcher is a no-op when the supervisor tree is not running" do
    stop_supervised!(RouteWatcherSupervisor)
    assert :ok = RouteWatcherSupervisor.stop_watcher(Ecto.UUID.generate())
  end
end
```

- [ ] **Step 2: Run test to verify it fails**
Run: `mix test test/unit/external_events/discord/route_watcher_supervisor_test.exs`
Expected: FAIL — `module WandererApp.ExternalEvents.Discord.RouteWatcherSupervisor is not available`.

- [ ] **Step 3: Implement**

```elixir
defmodule WandererApp.ExternalEvents.Discord.RouteWatcherSupervisor do
  @moduledoc """
  Starts one `Discord.RouteWatcher` per map on demand, addressed through the
  Registry `RouteWatcher` owns (`RouteWatcher.registry/0`). Mirrors
  `Discord.WorkerSupervisor` closely; see that module's moduledoc for the
  `:rest_for_one` reasoning, which applies identically here.

  Only started when webhooks are globally enabled (`application.ex`), so
  `notify/1` and `stop_watcher/1` guard `Process.whereis/1` exactly as
  `WorkerSupervisor` does — a no-op when this tree is not running, never a
  crash, so callers on the dispatch and resource-destroy paths do not need to
  know whether the feature is enabled.
  """

  use Supervisor

  alias WandererApp.ExternalEvents.Discord.RouteWatcher

  @dyn_sup WandererApp.ExternalEvents.Discord.RouteWatcherDynamicSupervisor
  @stop_timeout_ms 5_000

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: RouteWatcher.registry()},
      {DynamicSupervisor, name: @dyn_sup, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Starts the map's watcher if needed, then forwards the notify."
  @spec notify(binary()) :: :ok
  def notify(map_id) do
    case Process.whereis(RouteWatcher.registry()) do
      nil ->
        :ok

      _ ->
        with {:ok, _pid} <- ensure_watcher(map_id) do
          RouteWatcher.notify(map_id)
        end

        :ok
    end
  end

  @doc "Stops the map's watcher if one is running, discarding its state."
  @spec stop_watcher(binary()) :: :ok
  def stop_watcher(map_id) do
    case Process.whereis(RouteWatcher.registry()) do
      nil ->
        :ok

      _ ->
        case Registry.lookup(RouteWatcher.registry(), map_id) do
          [{pid, _}] -> try_stop(pid)
          [] -> :ok
        end

        :ok
    end
  end

  defp try_stop(pid) do
    GenServer.stop(pid, :normal, @stop_timeout_ms)
  catch
    :exit, _ -> :ok
  end

  defp ensure_watcher(map_id) do
    case Registry.lookup(RouteWatcher.registry(), map_id) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: start_watcher(map_id)

      [] ->
        start_watcher(map_id)
    end
  end

  defp start_watcher(map_id) do
    spec = {RouteWatcher, map_id: map_id}

    case DynamicSupervisor.start_child(@dyn_sup, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**
Run: `mix test test/unit/external_events/discord/route_watcher_supervisor_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/wanderer_app/external_events/discord/route_watcher_supervisor.ex test/unit/external_events/discord/route_watcher_supervisor_test.exs
git commit -m "feat(discord): add RouteWatcherSupervisor"
```

- [ ] **Step 6: Wire the Cachex worker and the supervisor into `application.ex`**

`route_watcher.ex` persists to `:discord_route_alert_cache`, which does not
exist yet — add it next to `:discord_dedup_cache` (both are Discord-feature
caches, started unconditionally like every other Cachex worker in this list,
since a watcher can be started and stopped independently of the rest of the
Discord supervision tree during tests):

```elixir
      # Route-alert state per map: {route_state, config_version}. No TTL —
      # unlike the dedup cache this is not a replay window, it is the last
      # known state of an ongoing situation, and must survive as long as the
      # map's route-alert configuration does.
      Supervisor.child_spec(
        {Cachex, name: :discord_route_alert_cache},
        id: :discord_route_alert_cache_worker
      ),
```

placed immediately after the `:discord_dedup_cache` entry
(`application.ex:150-153`). Then insert the supervisor into the gated list,
BEFORE `DiscordDispatcher` — it reads route-alert config synchronously
(`fetch_config/1`) but must never find the watcher tree missing when it calls
`RouteWatcherSupervisor.notify/1`:

```elixir
          [
            WandererApp.ExternalEvents.WebhookDispatcher,
            WandererApp.ExternalEvents.Discord.VoiceGateway,
            WandererApp.ExternalEvents.Discord.WorkerSupervisor,
            # Route-alert watchers post through WorkerSupervisor, so this
            # comes after it. Before DiscordDispatcher, whose new topology
            # clause (Task 9) calls RouteWatcherSupervisor.notify/1 and must
            # never find the tree missing.
            WandererApp.ExternalEvents.Discord.RouteWatcherSupervisor,
            WandererApp.ExternalEvents.DiscordDispatcher
          ]
```

This step has no isolated test of its own — Task 9's dispatcher tests and any
existing application-boot smoke test are the verification. Confirm the app
still boots:

Run: `mix compile --warnings-as-errors`
Expected: clean compile, no warnings.

- [ ] **Step 7: Commit**
```bash
git add lib/wanderer_app/application.ex
git commit -m "feat(discord): wire RouteWatcherSupervisor and its Cachex worker into the app tree"
```

- [ ] **Step 8: Failing test — the notification's destroy stops its map's watcher**

```elixir
  test "destroying the notification stops its map's route watcher", %{map: map, notification: notification} do
    start_supervised!(RouteWatcherSupervisor)
    RouteWatcherSupervisor.notify(map.id)
    assert [{pid, _}] = Registry.lookup(RouteWatcher.registry(), map.id)

    :ok = MapDiscordNotification.destroy(notification)

    refute Process.alive?(pid)
  end
```

Add this to `test/unit/external_events/discord/route_watcher_supervisor_test.exs`
in a `describe "resource integration"` block with its own `setup` inserting a
`Factory.insert(:map, %{})` and `MapDiscordNotification.create/1` (mirroring
the fixtures already used in `worker_test.exs:16-22`).

- [ ] **Step 9: Run test to verify it fails**
Run: `mix test test/unit/external_events/discord/route_watcher_supervisor_test.exs`
Expected: FAIL — the watcher process is still alive after destroy; `after_destroy/3` does not yet call `stop_watcher/1`.

- [ ] **Step 10: Wire `stop_watcher/1` into the notification's destroy path**

```elixir
  @doc false
  def after_destroy(changeset, {:ok, record}, _context) do
    WandererApp.ExternalEvents.DiscordDispatcher.invalidate_cache(record.map_id)

    changeset.context
    |> Map.get(:webhook_ids, [])
    |> Enum.each(fn id ->
      WandererApp.ExternalEvents.Discord.WorkerSupervisor.stop_worker(id)
    end)

    # Stops the map's route-alert watcher too: without this a deleted
    # notification's watcher keeps its debounce timer and Cachex-persisted
    # state alive indefinitely, and a later `MapDiscordNotification.create/1`
    # for the same map would resume against stale route_state instead of
    # starting fresh at :unknown.
    WandererApp.ExternalEvents.Discord.RouteWatcherSupervisor.stop_watcher(record.map_id)

    {:ok, record}
  end
```

Modify `lib/wanderer_app/api/map_discord_notification.ex:178-193` — the single
line above the closing `{:ok, record}`.

- [ ] **Step 11: Run test to verify it passes**
Run: `mix test test/unit/external_events/discord/route_watcher_supervisor_test.exs`
Expected: PASS.

- [ ] **Step 12: Run the existing notification resource tests to confirm no regression**
Run: `mix test test/unit/api/map_discord_notification_test.exs` (adjust path if
the actual test file differs — confirm with `git grep -l MapDiscordNotification test/`
before running)
Expected: PASS, unchanged.

- [ ] **Step 13: Commit**
```bash
git add lib/wanderer_app/api/map_discord_notification.ex test/unit/external_events/discord/route_watcher_supervisor_test.exs
git commit -m "fix(discord): stop a map's route watcher when its notification is destroyed"
```

---

### Task 9: `DiscordDispatcher` topology clause

**Files:**
- Modify: `lib/wanderer_app/external_events/discord_dispatcher.ex:272` (new
  clause, inserted immediately before the catch-all)
- Test: `test/unit/external_events/discord_dispatcher_test.exs` (new `describe`
  block; existing file, do not restructure the rest of it)

**Interfaces:**
- Consumes: `WandererApp.ExternalEvents.Discord.RouteWatcherSupervisor.notify/1`
  (Task 8), the existing `enabled_globally?/0` and `fetch_config/1` private
  helpers (`discord_dispatcher.ex:756-772`).
- Produces: nothing new — this is a private `do_dispatch/2` clause.

`DiscordDispatcher` is a singleton GenServer; every map's kill batches funnel
through this one process (see its moduledoc and the enrichment budget
comments at `discord_dispatcher.ex:299-315`). This clause must do **no DB and
no HTTP work** of its own: `fetch_config/1` reads the already-warm
`:discord_notification_cache` (a cache miss here is one Ecto query, same cost
the kill path already pays on every cache-cold map, not a new class of cost),
and `RouteWatcherSupervisor.notify/1` is a cast into a different process. Any
heavier work — the solve, the embed, the HTTP post — belongs entirely to
`Discord.RouteWatcher` (Task 7), which is one GenServer per *map*, not the one
singleton every map shares. Adding synchronous or per-event work to this
clause would reintroduce exactly the head-of-line blocking the enrichment
budget comment warns about, for every map's kill notifications, not just
route alerts.

Event types confirmed against `event.ex:94,101,103`: `:add_system`,
`:connection_added`, `:connection_updated` (`:connection_removed` is
deliberately excluded — removing a connection cannot open a new route, only
close one, and a closed route already clears silently per the transition
table; evaluating on it would be pure wasted solver load).

- [ ] **Step 1: Write the failing tests**

Add to `test/unit/external_events/discord_dispatcher_test.exs`, in a new
`describe "route alert dispatch" do ... end` block. Needs a stand-in for
`RouteWatcherSupervisor.notify/1` observable from the test process, following
the same pattern `Enricher`/`TickerEnricher` use at the top of the file (a
named process receiving a message, not Mox — `notify/1` would run from the
dispatcher's own process, and a plain function call cannot be asserted on
directly without either a mock or an observer):

```elixir
defmodule WandererApp.ExternalEvents.DiscordDispatcherTest.RouteWatcherObserver do
  @moduledoc "Stands in for RouteWatcherSupervisor.notify/1 so tests can assert it was called."
  def notify(map_id) do
    case Process.whereis(:route_watcher_observer) do
      nil -> :ok
      pid -> send(pid, {:route_notify, map_id})
    end

    :ok
  end
end
```

```elixir
  describe "route alert dispatch" do
    setup %{map: map, notification: notification} do
      Application.put_env(
        :wanderer_app,
        :route_watcher_supervisor,
        WandererApp.ExternalEvents.DiscordDispatcherTest.RouteWatcherObserver
      )

      on_exit(fn -> Application.delete_env(:wanderer_app, :route_watcher_supervisor) end)

      Process.register(self(), :route_watcher_observer)
      on_exit(fn -> Process.unregister(:route_watcher_observer) end)

      {:ok, notification} =
        MapDiscordNotification.update(notification, %{
          route_alerts_enabled?: true,
          home_system_id: 30_000_001
        })

      DiscordDispatcher.invalidate_cache(map.id)
      %{notification: notification}
    end

    for type <- [:add_system, :connection_added, :connection_updated] do
      test "#{type} notifies the route watcher", %{map: map} do
        event = Event.new(map.id, unquote(type), %{})
        DiscordDispatcher.dispatch_event(map.id, event)

        assert_receive {:route_notify, map_id}, 500
        assert map_id == map.id
      end
    end

    test "no notify when webhooks are globally disabled", %{map: map} do
      original = Application.get_env(:wanderer_app, :external_events, [])

      Application.put_env(
        :wanderer_app,
        :external_events,
        Keyword.put(original, :webhooks_enabled, false)
      )

      on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)

      event = Event.new(map.id, :add_system, %{})
      DiscordDispatcher.dispatch_event(map.id, event)

      refute_receive {:route_notify, _}, 200
    end

    test "no notify when route_alerts_enabled? is false", %{map: map, notification: notification} do
      {:ok, _} = MapDiscordNotification.update(notification, %{route_alerts_enabled?: false})
      DiscordDispatcher.invalidate_cache(map.id)

      event = Event.new(map.id, :add_system, %{})
      DiscordDispatcher.dispatch_event(map.id, event)

      refute_receive {:route_notify, _}, 200
    end

    test "no notify when home_system_id is nil", %{map: map, notification: notification} do
      {:ok, _} = MapDiscordNotification.update(notification, %{home_system_id: nil})
      DiscordDispatcher.invalidate_cache(map.id)

      event = Event.new(map.id, :add_system, %{})
      DiscordDispatcher.dispatch_event(map.id, event)

      refute_receive {:route_notify, _}, 200
    end

    test "no notify for a map with no Discord configuration at all" do
      map = Factory.insert(:map, %{})
      event = Event.new(map.id, :add_system, %{})
      DiscordDispatcher.dispatch_event(map.id, event)

      refute_receive {:route_notify, _}, 200
    end

    test "the kill path is unaffected", %{map: map, system: w} do
      # Regression guard, not new behaviour: re-run an existing kill-delivery
      # scenario inside this describe block to confirm the new clause
      # (inserted before the catch-all) does not shadow :map_kill. Use the
      # file's own killmail/2 and wait_for_requests/1 helpers — confirm their
      # exact names with
      # `grep -n "defp wait_for\|defp killmail" test/unit/external_events/discord_dispatcher_test.exs`
      # before writing this test, since the plan's names here are best-effort.
      DiscordDispatcher.dispatch_event(
        map.id,
        Event.new(map.id, :map_kill, %{
          "type" => :killmail_update,
          "solar_system_id" => 30_000_142,
          "killmails" => [killmail(1)]
        })
      )

      assert [_] = wait_for_requests(1)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**
Run: `mix test test/unit/external_events/discord_dispatcher_test.exs`
Expected: FAIL on every `assert_receive {:route_notify, ...}` — `do_dispatch/2`
still falls through to the catch-all for all three topology event types.

- [ ] **Step 3: Implement the clause**

```elixir
  # No DB or HTTP work of its own: fetch_config/1 reads the already-cached
  # notification (a cache miss costs one Ecto query, same as the kill path
  # pays on any cache-cold map), and RouteWatcherSupervisor.notify/1 is a cast
  # into a different process. This dispatcher is a SINGLETON shared by every
  # map's kill batches — the solve, the embed, and the HTTP post all belong to
  # Discord.RouteWatcher, one GenServer per map, never to this clause.
  defp do_dispatch(map_id, %{type: type})
       when type in [:add_system, :connection_added, :connection_updated] do
    with true <- enabled_globally?(),
         {:ok, notification} <- fetch_config(map_id),
         true <- notification.route_alerts_enabled?,
         home_system_id when not is_nil(home_system_id) <- notification.home_system_id do
      route_watcher_supervisor().notify(map_id)
    end

    :ok
  end

  defp route_watcher_supervisor,
    do:
      Application.get_env(
        :wanderer_app,
        :route_watcher_supervisor,
        WandererApp.ExternalEvents.Discord.RouteWatcherSupervisor
      )
```

Insert this clause immediately before `defp do_dispatch(_map_id, _event), do: :ok`
at `discord_dispatcher.ex:272` — clause order matters, since Elixir matches
top-down and the catch-all would otherwise swallow these three event types
first.

- [ ] **Step 4: Run test to verify it passes**
Run: `mix test test/unit/external_events/discord_dispatcher_test.exs`
Expected: PASS — all six new assertions and every pre-existing test in the
file (in particular the kill-path regression test).

- [ ] **Step 5: Run the full dispatcher and route-watcher suites together**
Run: `mix test test/unit/external_events/discord_dispatcher_test.exs test/unit/external_events/discord/route_watcher_test.exs test/unit/external_events/discord/route_watcher_supervisor_test.exs`
Expected: all green.

- [ ] **Step 6: Format and static checks**
Run: `mix format --check-formatted lib/wanderer_app/external_events/discord_dispatcher.ex && mix credo lib/wanderer_app/external_events/discord_dispatcher.ex`
Expected: clean. Fix and re-run if not.

- [ ] **Step 7: Commit**
```bash
git add lib/wanderer_app/external_events/discord_dispatcher.ex test/unit/external_events/discord_dispatcher_test.exs
git commit -m "feat(discord): dispatch topology events to RouteWatcherSupervisor"
```

---

# Part 05 — Settings UI for route alerts

Depends on Task 3 (`route_alerts_enabled?`, `home_system_id`, `route_max_jumps`
on `MapDiscordNotification`; `mention_targets` and the `:route` role on
`MapDiscordWebhook`) and Task 4 (`Mentions.valid_target?/1`) landing first —
this task cannot compile or pass a single test before both exist. It is purely
additive to `MapNotificationsComponent`; nothing here changes kill-notification
behaviour for the `:system` or `:character` rows.

**Cross-task accept-list note.** Task 3 owns both resources' `accept` lists;
this task only *verifies* them (Step 4) and never edits them. Two tasks editing
the same list risks one silently clobbering `MapDiscordNotification`'s explicit
`:update` accept list, which exists specifically to stop `:map_id` being
re-parented.

### Task 10: Route-alert fields, home system, and mention targets on the notifications settings tab

**Files:**
- Modify: `lib/wanderer_app_web/live/maps/components/map_notifications_component.ex:1-921`
- Test: `test/wanderer_app_web/live/map_notifications_test.exs`

(Both Ash resources are read-only here — their accept lists belong to Task 3.)

**Interfaces:**
- Consumes:
  - `WandererApp.Api.MapDiscordNotification.update/2` (existing code interface, extended attrs).
  - `WandererApp.Api.MapDiscordWebhook.create/1`, `.update/2` (existing code interfaces, extended attrs — contract Task 3).
  - `WandererApp.ExternalEvents.Discord.Mentions.valid_target?/1` (contract Task 4) — the *only* mention-format check this task performs; it must not reimplement the regex.
- Produces: no new public interface. Purely a LiveView settings surface over the Task 3 schema.

**Documented simplifications (read before implementing):**

1. **`home_system_id` is a plain number input, not a name-search picker.** This
   file already has a system picker (`live_select` + `search_systems/2` for
   "excluded systems"), but that picker's whole interaction model is
   *add-to-a-list* — pick one, it appends, the field clears for the next pick.
   Home system is a single replace-on-select value, which is a different
   interaction the existing picker was not built for, and building that
   variant is out of scope here. The field is a numeric solar-system-id input
   with placeholder text; no name is resolved or displayed next to it. If a
   future task adds a single-value system picker (e.g. for `Map.hubs`), this
   field should switch to it.
2. **Fields are hidden with a CSS class, never `disabled` or `:if`-removed.**
   A native `disabled` input, and a `:if`-removed one, are both **excluded
   from the submitted form params entirely**. If `home_system_id` were hidden
   that way while the toggle is off, every save would submit no value for it
   at all — losing whatever the user typed the moment they unchecked the box,
   and (worse) making it impossible for the Ash "home system required when
   enabled" validation to ever see a submitted value on the very save that
   turns the toggle on, because the field would not exist in the DOM until
   *after* that save round-trips. A CSS-hidden field keeps posting its value
   regardless of visibility, so toggling is purely cosmetic and never eats
   data.
3. **The mention-targets input is rendered on every webhook row, not only
   `:route`**, but visually hidden via the same CSS-class technique for
   `:system` and `:character` — again so its param key is always present and
   `save_webhook/4` needs only one code path rather than one that
   conditionally omits the key. Neither of those two roles has ever had a way
   to set `mention_targets` before this task, so a hidden, always-empty input
   for them is inert, not a regression.
4. **The "inline error" for an invalid mention target reuses this component's
   existing single error banner** (`@error`, rendered once above the main
   form) rather than inventing a new per-field error slot. Every other
   validation failure in this file — a bad webhook URL, a non-numeric
   corporation id, a stale record — already reports through that one banner,
   and adding a second, differently-styled error mechanism for just this one
   field would be the inconsistency, not the fix. "Inline" in the task
   description is read here as "reported to the user in the same request,
   distinct per bad entry" (as opposed to silently dropping invalid entries
   from the list), which the banner satisfies.
5. **`route_max_jumps`'s 1–20 bound is enforced only as HTML `min`/`max`
   here.** The contract's Task 3 attribute snippet does not show a
   `constraints: [min: 1, max: 20]` on the column. If Task 3 lands without
   that constraint, this UI's bound is cosmetic only — a hand-crafted form
   post (or a future API caller) could still set 0 or 500. Flagging this
   explicitly rather than assuming Task 3 covers it: **whoever lands last
   between Task 3 and this task should confirm the Ash-level constraint
   exists**; if not, add `constraints: [min: 1, max: 20]` to the attribute in
   `map_discord_notification.ex` as a one-line follow-up, not silently skip it.

- [ ] **Step 1: Confirm the Task 3 / Task 4 prerequisites are actually present**

Run: `mix compile` and `grep -n "route_alerts_enabled?\|home_system_id\|route_max_jumps" lib/wanderer_app/api/map_discord_notification.ex`
Expected: the three attributes exist, and `grep -n "mention_targets\|:route" lib/wanderer_app/api/map_discord_webhook.ex` shows the new column and the extended `one_of`. If any is missing, stop — this task cannot proceed until Task 3 lands.

- [ ] **Step 2: Write the failing LiveView tests**

Append to `test/wanderer_app_web/live/map_notifications_test.exs`, in a new
`describe` block (uses the file's existing `open_notifications/2`,
`notification_with_webhooks/2`, `system_webhook/1` helpers as-is):

```elixir
  describe "route alerts" do
    test "enabling route alerts without a home system surfaces the Ash validation error", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      html =
        view
        |> form("#discord-notification-form", %{
          "notification" => %{
            "enabled" => "true",
            "wh_only" => "true",
            "route_alerts_enabled" => "true",
            "home_system_id" => "",
            "route_max_jumps" => "5"
          }
        })
        |> render_submit()

      # Exact wording is Task 3's to define; this asserts on it because a
      # substring match loose enough to survive any wording would also survive
      # the validation being silently removed. If Task 3 ships different
      # copy, update this one line to match it — do not weaken the match.
      assert html =~ "Home system is required to enable route alerts."

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      refute rec.route_alerts_enabled?
      assert rec.home_system_id == nil
    end

    test "saving valid route settings persists the toggle, home system, and max jumps", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> form("#discord-notification-form", %{
        "notification" => %{
          "enabled" => "true",
          "wh_only" => "true",
          "route_alerts_enabled" => "true",
          "home_system_id" => "30000142",
          "route_max_jumps" => "3"
        }
      })
      |> render_submit()

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      assert rec.route_alerts_enabled? == true
      assert rec.home_system_id == 30_000_142
      assert rec.route_max_jumps == 3
    end

    test "the route fields are hidden while the toggle is off, not removed from the form", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      # Off by default (route_alerts_enabled? defaults to false per Task 3) —
      # the wrapper carries the "hidden" class, and the inputs are still
      # present in the DOM so their values still post on save.
      assert has_element?(view, "div.hidden input[name='notification[home_system_id]']")

      view
      |> element("input[name='notification[route_alerts_enabled]'][type='checkbox']")
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      refute has_element?(view, "div.hidden input[name='notification[home_system_id]']")
    end

    test "the route webhook url can be added", %{conn: conn, map: map} do
      rec = notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> form("#webhook-form-route", %{
        "webhook" => %{"webhook_url" => "https://discord.com/api/webhooks/999/routetok"}
      })
      |> render_submit()

      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
      assert %{role: :route, enabled?: true} = Enum.find(webhooks, &(&1.role == :route))
      assert has_element?(view, "#webhook-row-route button[phx-click='remove-webhook']")
    end

    test "an invalid mention target shows an inline error and does not persist the webhook", %{
      conn: conn,
      map: map
    } do
      rec = notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      html =
        view
        |> form("#webhook-form-route", %{
          "webhook" => %{
            "webhook_url" => "https://discord.com/api/webhooks/999/routetok",
            "mention_targets" => "role:123456789012345678, not-a-target"
          }
        })
        |> render_submit()

      assert html =~ "not-a-target"
      assert html =~ "not a valid mention target"

      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
      refute Enum.any?(webhooks, &(&1.role == :route))
    end

    test "valid mention targets are saved, comma-separated and trimmed", %{conn: conn, map: map} do
      rec = notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> form("#webhook-form-route", %{
        "webhook" => %{
          "webhook_url" => "https://discord.com/api/webhooks/999/routetok",
          "mention_targets" => "role:123456789012345678,  user:234567890123456789 "
        }
      })
      |> render_submit()

      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
      route_wh = Enum.find(webhooks, &(&1.role == :route))
      assert route_wh.mention_targets == ["role:123456789012345678", "user:234567890123456789"]
    end
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/wanderer_app_web/live/map_notifications_test.exs`
Expected: every test in the new `describe "route alerts"` block FAILs — either
a `KeyError`/`ArgumentError` from `.input field={f[:route_alerts_enabled]}`
not existing on the form, or (once the template compiles) a `NoSuchInput`
Ash error, since the component does not yet build or accept any of these
attrs. Every pre-existing test in the file must still PASS unmodified — this
step also serves as the regression baseline.

- [ ] **Step 4: Verify Task 3 already whitelisted the new attributes — do not re-edit**

Task 3 owns both resources' accept lists. Its plan section adds the three new
`MapDiscordNotification` attributes to `default_accept` and to the explicit
`:update` accept list, and adds `:mention_targets` to `MapDiscordWebhook`'s
`default_accept` and `:update` accept list. Confirm rather than duplicate:

```bash
grep -A9 'default_accept' lib/wanderer_app/api/map_discord_notification.ex
grep -A9 'accept \[' lib/wanderer_app/api/map_discord_notification.ex
grep -n 'default_accept\|accept \[' lib/wanderer_app/api/map_discord_webhook.ex
```

Expected: `:route_alerts_enabled?`, `:home_system_id`, `:route_max_jumps` in
**both** `MapDiscordNotification` lists, and `:mention_targets` in **both**
`MapDiscordWebhook` lists.

If any are missing, Task 3 is incomplete — go fix it there and re-run Task 3's
tests. Do not patch the accept lists from this task: two tasks editing the same
list is how one of them silently loses the explicit `:update` list that exists
to stop `:map_id` being re-parented.

- [ ] **Step 6: Extend the roles and role parsing**

```elixir
  @roles [:system, :character, :route]
```

```elixir
  defp parse_role("character"), do: :character
  defp parse_role(:character), do: :character
  defp parse_role("route"), do: :route
  defp parse_role(:route), do: :route
  defp parse_role(_), do: :system
```

Extend `remove-webhook`'s guard — `:route` is removable the same way
`:character` is, since a removed `:route` destination simply falls back to
`:system` per the design's Router rule, exactly like today's `:character`
removal has no fallback of its own to break:

```elixir
  def handle_event("remove-webhook", %{"role" => role}, socket) do
    role = parse_role(role)

    case {role, socket.assigns.webhooks[role]} do
      {role, %{} = webhook} when role in [:character, :route] ->
        case MapDiscordWebhook.destroy(webhook) do
          :ok ->
            {:noreply,
             socket
             |> assign_notification(reload_notification(socket.assigns.map_id))
             |> assign(:error, nil)
             |> assign(:flash_message, "#{role_label(role)} destination removed.")}

          {:error, error} ->
            {:noreply,
             socket |> assign(:error, humanize_error(error)) |> assign(:flash_message, nil)}
        end

      _ ->
        {:noreply, assign(socket, :error, "The system destination cannot be removed.")}
    end
  end
```

```elixir
  defp role_label(:character), do: "Character"
  defp role_label(:route), do: "Route"
```

- [ ] **Step 7: Add the `toggle-route-alerts` event handler**

Placed next to `handle_event("replace-url", ...)`, since both are
display-state-only handlers that never touch the database:

```elixir
  # Purely client-display state: which fields are visually shown, driven by
  # the CHECKBOX's own `phx-change` (not the whole form's) so ticking or
  # unticking this one box is the only thing that round-trips — typing in the
  # numeric fields below it does not. Nothing here is persisted; the actual
  # value is only ever written by "save", same as every other field on this
  # form.
  def handle_event("toggle-route-alerts", %{"notification" => params}, socket) do
    {:noreply, assign(socket, :route_toggle, checked?(params["route_alerts_enabled"]))}
  end
```

- [ ] **Step 8: Extend `handle_event("save", ...)`'s attrs and add the parsers**

```elixir
  def handle_event("save", %{"notification" => params}, socket) do
    attrs = %{
      wh_only: checked?(params["wh_only"]),
      enabled?: checked?(params["enabled"]),
      route_alerts_enabled?: checked?(params["route_alerts_enabled"]),
      home_system_id: parse_home_system_id(params["home_system_id"]),
      route_max_jumps: parse_route_max_jumps(params["route_max_jumps"])
    }

    # ... unchanged create/update dispatch below this line
```

```elixir
  # Blank or non-numeric input clears the home system rather than raising —
  # the Ash "required when enabled" validation is what reports that, not this
  # parse step, matching how `add-excluded`/`add-focus-corp` already leave
  # rejection to a later stage rather than crashing on bad input here.
  defp parse_home_system_id(raw) do
    case Integer.parse(to_string(raw || "")) do
      {id, ""} -> id
      _ -> nil
    end
  end

  # Falls back to the column default (5) on blank/non-numeric input rather
  # than sending `nil` into an `allow_nil?: false` attribute, which Ash would
  # reject outright.
  defp parse_route_max_jumps(raw) do
    case Integer.parse(to_string(raw || "")) do
      {n, ""} -> n
      _ -> 5
    end
  end
```

- [ ] **Step 9: Extend `notification_form/1` and `assign_notification/2`**

```elixir
  defp notification_form(notification) do
    to_form(
      %{
        "webhook_url" => "",
        "wh_only" => is_nil(notification) or notification.wh_only,
        "enabled" => is_nil(notification) or notification.enabled?,
        # Unlike wh_only/enabled, this one defaults OFF (Task 3: `default:
        # false`) — `is_nil(notification) or ...` would default it ON, which
        # is backwards for this field.
        "route_alerts_enabled" => !is_nil(notification) and notification.route_alerts_enabled?,
        "home_system_id" => home_system_id_value(notification),
        "route_max_jumps" => route_max_jumps_value(notification)
      },
      as: :notification
    )
  end

  defp home_system_id_value(nil), do: ""
  defp home_system_id_value(%{home_system_id: nil}), do: ""
  defp home_system_id_value(%{home_system_id: id}), do: to_string(id)

  defp route_max_jumps_value(nil), do: 5
  defp route_max_jumps_value(%{route_max_jumps: n}), do: n
```

In `assign_notification/2`, add the client-display toggle so it survives every
re-render (a webhook save, an excluded-system add, etc. must not silently
snap the route fields back to hidden while the user is mid-edit on something
else):

```elixir
  defp assign_notification(socket, notification) do
    webhooks = load_webhooks(notification)

    socket
    |> assign(:notification, notification)
    |> assign(:webhooks, webhooks)
    |> assign(:route_toggle, !is_nil(notification) and notification.route_alerts_enabled?)
    |> assign(:excluded_systems, excluded_system_labels(notification))
    # ... rest unchanged
```

- [ ] **Step 10: Extend `webhook_forms/1` with `mention_targets`**

```elixir
  defp webhook_forms(webhooks) do
    Map.new(@roles, fn role ->
      webhook = Map.get(webhooks, role)

      form =
        to_form(
          %{
            "webhook_url" => "",
            "enabled" => is_nil(webhook) or webhook.enabled?,
            "mention_targets" => mention_targets_value(webhook)
          },
          as: :webhook
        )

      {role, form}
    end)
  end

  defp mention_targets_value(nil), do: ""
  defp mention_targets_value(%{mention_targets: targets}), do: Enum.join(targets, ", ")
```

- [ ] **Step 11: Parse and validate mention targets in `save_webhook/4`, consuming `Mentions.valid_target?/1`**

```elixir
  alias WandererApp.ExternalEvents.Discord.Mentions
```

```elixir
  defp save_webhook(rec, nil, role, %{"webhook_url" => url} = params)
       when is_binary(url) and url != "" do
    with {:ok, targets} <- parse_mention_targets(params["mention_targets"]) do
      MapDiscordWebhook.create(%{
        notification_id: rec.id,
        role: role,
        webhook_url: url,
        mention_targets: targets
      })
    end
  end

  defp save_webhook(_rec, nil, _role, _params), do: {:error, "Enter a webhook URL first."}

  defp save_webhook(_rec, webhook, _role, %{"webhook_url" => url} = params)
       when is_binary(url) and url != "" do
    with {:ok, targets} <- parse_mention_targets(params["mention_targets"]) do
      MapDiscordWebhook.update(webhook, %{
        webhook_url: url,
        enabled?: checked?(params["enabled"]),
        mention_targets: targets
      })
    end
  end

  # This branch used to call `MapDiscordWebhook.set_enabled/2`, whose accept
  # list is `[:enabled?]` only. Now that this row can also carry
  # `mention_targets`, it goes through the general `update` action instead so
  # a mention-only edit (no URL change) still saves — `set_enabled` itself is
  # untouched and still used by other callers (see `router_test.exs`,
  # `worker_test.exs`, etc.), this is only this handler's own dispatch.
  defp save_webhook(_rec, webhook, _role, params) do
    with {:ok, targets} <- parse_mention_targets(params["mention_targets"]) do
      MapDiscordWebhook.update(webhook, %{
        enabled?: checked?(params["enabled"]),
        mention_targets: targets
      })
    end
  end

  # Empty/whitespace entries are dropped silently — that is not "the silent
  # drop" the task warns against, which is about a MALFORMED entry (one that
  # does not match `Mentions.valid_target?/1`) disappearing without telling
  # the user. A blank entry from "role:123, " trailing-comma typing is not
  # malformed input, it is nothing.
  defp parse_mention_targets(raw) when is_binary(raw) do
    targets =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.find(targets, &(not Mentions.valid_target?(&1))) do
      nil ->
        {:ok, targets}

      bad ->
        {:error,
         "\"#{bad}\" is not a valid mention target. Use user:<id> or role:<id> with the " <>
           "Discord id (17-20 digits) — handles like @name do not work here."}
    end
  end

  defp parse_mention_targets(_), do: {:ok, []}
```

`handle_event("save-webhook", ...)`'s existing `with %{} = rec <- ...,
{:ok, _} <- save_webhook(...)` clause already routes a `{:error, message}`
return from `save_webhook/4` into `humanize_error/1` unchanged — a plain
binary error hits `humanize_error/1`'s first clause and renders verbatim, the
same path the existing "Enter a webhook URL first." message already takes. No
change needed to `handle_event("save-webhook", ...)` itself.

- [ ] **Step 12: Template — route toggle, home system, max jumps on the main form**

Insert directly after the existing `wh_only`/`enabled` inputs in
`discord-notification-form`:

```heex
        <.input field={f[:wh_only]} type="checkbox" label="Only wormhole kills" />
        <.input field={f[:enabled]} type="checkbox" label="Enabled for this map" />

        <.input
          field={f[:route_alerts_enabled]}
          type="checkbox"
          label="Route alerts (highsec route to Jita)"
          phx-change="toggle-route-alerts"
        />

        <div class={if @route_toggle, do: "flex flex-col gap-2", else: "hidden"}>
          <.input
            field={f[:home_system_id]}
            type="number"
            label="Home system (solar system ID)"
            placeholder="e.g. 31000005"
          />
          <.input
            field={f[:route_max_jumps]}
            type="number"
            min="1"
            max="20"
            label="Max jumps to Jita (inclusive)"
          />
          <p class="text-xs opacity-70">
            Posts when a highsec-only route this length or shorter opens from
            the home system to Jita. Wormhole hops on the way don't count
            against "highsec" — only k-space systems on the path do. Enter the
            home system's numeric solar system ID; there is no name search for
            this field yet.
          </p>
        </div>

        <.button type="submit" class="self-start">Save</.button>
```

- [ ] **Step 13: Template — the `:route` webhook row and its mention field**

Add a third `<.webhook_row>` call, after the existing `:character` one:

```heex
      <.webhook_row
        :if={@notification}
        role={:route}
        title="Route alert channel (optional)"
        help={
          "Receives an alert when a highsec-only route opens from the home system to Jita. " <>
            "This message names every system on the route in order — treat this channel as " <>
            "trusted, there is no redacted version of it. Leave it unset and route alerts go " <>
            "to the system channel instead."
        }
        webhook={@webhooks[:route]}
        form={@webhook_forms[:route]}
        replacing?={@replacing_url?[:route]}
        removable?={true}
        show_mentions?={true}
        myself={@myself}
      />
```

Add the new attr and the mention field to the `webhook_row` component:

```elixir
  attr :role, :atom, required: true
  attr :title, :string, required: true
  attr :help, :string, required: true
  attr :webhook, :any, required: true
  attr :form, :any, required: true
  attr :replacing?, :boolean, required: true
  attr :removable?, :boolean, required: true
  attr :show_mentions?, :boolean, default: false
  attr :myself, :any, required: true
```

Inside the row's `<.form>`, directly after the `enabled` checkbox and before
the submit button:

```heex
        <.input :if={@webhook} field={wf[:enabled]} type="checkbox" label="Enabled" />

        <div class={if @show_mentions?, do: "flex flex-col gap-1", else: "hidden"}>
          <.input
            field={wf[:mention_targets]}
            type="text"
            label="Mentions (optional)"
            placeholder="role:123456789012345678, user:234567890123456789"
          />
          <p class="text-xs opacity-70">
            Comma-separated <code>user:&lt;id&gt;</code> or
            <code>role:&lt;id&gt;</code> Discord snowflakes to ping when a route
            opens. Handles like <code>@name</code> do not work — Discord
            requires the numeric id. Leave empty to post with no ping.
          </p>
        </div>

        <.button type="submit" class="self-start">{if @webhook, do: "Save", else: "Add"}</.button>
```

- [ ] **Step 14: Run the tests to verify they pass**

Run: `mix test test/wanderer_app_web/live/map_notifications_test.exs`
Expected: PASS, the whole file — every pre-existing test plus the six new
`describe "route alerts"` tests. If the toggle test in Step 2 fails on the
`render_change` payload shape, check that the checkbox's rendered `name`
attribute is `notification[route_alerts_enabled]` (it inherits this from
`f[:route_alerts_enabled]`) and adjust the test's nested map key to match —
this is a test-only fix, not a template change.

- [ ] **Step 15: Format and lint**

Run: `mix format lib/wanderer_app_web/live/maps/components/map_notifications_component.ex lib/wanderer_app/api/map_discord_notification.ex lib/wanderer_app/api/map_discord_webhook.ex test/wanderer_app_web/live/map_notifications_test.exs`
Run: `mix credo lib/wanderer_app_web/live/maps/components/map_notifications_component.ex`
Expected: clean.

- [ ] **Step 16: Commit**
```bash
git add lib/wanderer_app_web/live/maps/components/map_notifications_component.ex \
        lib/wanderer_app/api/map_discord_notification.ex \
        lib/wanderer_app/api/map_discord_webhook.ex \
        test/wanderer_app_web/live/map_notifications_test.exs
git commit -m "feat(discord): add route alert settings to the notifications tab

Adds the route-alerts toggle, home system, and max-jumps fields to the
map's Discord notification form, plus a :route webhook row with a
mention-targets editor validated against Mentions.valid_target?/1. Home
system uses a plain numeric input rather than a name-search picker —
the existing live_select picker in this file is add-to-a-list, not
select-one-and-replace, and building that variant is out of scope
here. Route fields hide via CSS rather than disabled/:if so their
values keep posting while the toggle is off."
```
