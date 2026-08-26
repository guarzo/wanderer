# Discord rally-point notifications — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Post a Discord message, pinging a configured role, when a pilot drops a rally point on a map.

**Architecture:** A fourth `:rally` role on the existing `MapDiscordWebhook` gives the feature its own webhook URL and mention targets. A new `do_dispatch/2` clause in `DiscordDispatcher` gates and hands off to a task; a small `Discord.RallyPing` module formats and enqueues onto the existing per-webhook delivery worker. No new processes, no migration, no per-map toggle.

**Tech Stack:** Elixir, Phoenix LiveView (HEEx), Ash Framework, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-26-discord-rally-notifications-design.md`

## Global Constraints

- **Branch base:** the entire Discord stack lives on `guarzo/zoo` and does not exist on `origin/main`. Work must branch from `guarzo/zoo`.
- **No migration, no snapshot.** `MapDiscordWebhook.role` is plain `:text` with an Ash-only `one_of` constraint. Do not run `mix ash.codegen` for this feature — this repo has a documented history of codegen sweeping unrelated resources into generated migrations.
- **Role atoms are passed as literals, never threaded through a variable.** `SystemName.display_name/3` is the map-local-names privacy boundary; a variable role defeats it.
- **`after_transaction`, never `after_action`** for any Ash hook. `:discord_notification_cache` declares a `default_ttl:` that Cachex 3.6 ignores, so a missed invalidation is silent until node restart — not for five minutes.
- **Never add a catch-all clause** to `SystemName.display_name/3` or `deliver_partition/4` "for safety". Their absence is the guard.
- Run `mix format` and `mix credo` before every commit.
- Delivery tests must enable `webhooks_enabled` in setup and restore the whole `:external_events` keyword list in `on_exit`.

---

### Task 1: The `:rally` role and its system-name resolution

**Files:**
- Modify: `lib/wanderer_app/api/map_discord_webhook.ex:248-251`
- Modify: `lib/wanderer_app/external_events/discord/system_name.ex:26`, `:35-47`
- Test: `test/unit/api/map_discord_webhook_test.exs`
- Test: `test/unit/external_events/discord/system_name_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `:rally` as a valid `MapDiscordWebhook.role` value; `SystemName.display_name(map_id, solar_system_id, :rally) :: String.t() | nil` resolving map-local first.

- [ ] **Step 1: Write the failing resource test**

In `test/unit/api/map_discord_webhook_test.exs`, beside the existing `"rejects an unknown role"` test:

```elixir
  test "accepts the :rally role", %{notification: notification} do
    assert {:ok, %{role: :rally}} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :rally,
               webhook_url: valid_url()
             })
  end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mix test test/unit/api/map_discord_webhook_test.exs -k "accepts the :rally role"`

Expected: FAIL — the changeset is invalid because `:rally` is not in the `one_of` constraint.

- [ ] **Step 3: Add `:rally` to the constraint**

In `lib/wanderer_app/api/map_discord_webhook.ex`, the `role` attribute:

```elixir
    attribute :role, :atom do
      allow_nil? false
      constraints one_of: [:system, :character, :route, :rally]
    end
```

Keep the existing surrounding options exactly as they are; only the `one_of` list changes. **Do not create a migration** — the column is plain `text` and the constraint is Ash-level only.

- [ ] **Step 4: Run the resource tests**

Run: `mix test test/unit/api/map_discord_webhook_test.exs`

Expected: PASS, including the pre-existing `"rejects an unknown role"` test, which uses `:corporation` and therefore stays valid.

- [ ] **Step 5: Write the failing SystemName test**

In `test/unit/external_events/discord/system_name_test.exs`, mirroring the existing `:route` tests:

```elixir
  describe "display_name/3 with :rally" do
    test "prefers the map's own name", %{map_id: map_id, system: system} do
      assert SystemName.display_name(map_id, system.solar_system_id, :rally) == "A22A"
    end

    test "falls back to the canonical name when the map has no name for it", %{map_id: map_id} do
      assert SystemName.display_name(map_id, 30_000_142, :rally) == "Jita"
    end
  end
```

Match the existing file's setup block for how `map_id` and a `temporary_name`-carrying `system` are built; do not invent a new fixture shape.

- [ ] **Step 6: Run it and watch it fail**

Run: `mix test test/unit/external_events/discord/system_name_test.exs -k rally`

Expected: FAIL with `FunctionClauseError` — `display_name/3` has no `:rally` clause and deliberately no catch-all.

- [ ] **Step 7: Add the `:rally` clause**

In `lib/wanderer_app/external_events/discord/system_name.ex`, widen the type and add a clause directly below the `:route` one:

```elixir
  @type role :: :system | :character | :route | :rally
```

```elixir
  # A rally destination is the fleet's own channel and the map tag is the name
  # people navigate by, so resolution matches :system and :route rather than
  # :character's canonical-only rule.
  def display_name(map_id, solar_system_id, :rally) do
    map_local_name(map_id, solar_system_id) || canonical_name(solar_system_id)
  end
```

- [ ] **Step 8: Run both test files**

Run: `mix test test/unit/api/map_discord_webhook_test.exs test/unit/external_events/discord/system_name_test.exs`

Expected: PASS.

- [ ] **Step 9: Format, lint, commit**

```bash
mix format
mix credo --strict lib/wanderer_app/api/map_discord_webhook.ex lib/wanderer_app/external_events/discord/system_name.ex
git add lib/wanderer_app/api/map_discord_webhook.ex lib/wanderer_app/external_events/discord/system_name.ex test/unit/api/map_discord_webhook_test.exs test/unit/external_events/discord/system_name_test.exs
git commit -m "feat(discord): add a :rally webhook role and its name resolution

The role column is plain text behind an Ash-only one_of constraint, so this
needs no migration. SystemName resolves :rally map-local-first, matching
:system and :route: the rally channel is the fleet's own and the map tag is
the name people navigate by."
```

---

### Task 2: Router resolves a rally destination, with no fallback

**Files:**
- Modify: `lib/wanderer_app/external_events/discord/router.ex` (moduledoc, and beside `route_destination/1` at `:100-109`)
- Test: `test/unit/external_events/discord/router_test.exs`

**Interfaces:**
- Consumes: `:rally` role from Task 1.
- Produces: `Router.rally_destination(notification) :: {:ok, struct()} | :drop`. `notification` must have `:webhooks` loaded.

- [ ] **Step 1: Write the failing tests**

In `test/unit/external_events/discord/router_test.exs`, a new describe block modelled on `"route_destination/1"`:

```elixir
  describe "rally_destination/1" do
    defp add_rally_webhook(notification) do
      {:ok, wh} =
        MapDiscordWebhook.create(%{
          notification_id: notification.id,
          role: :rally,
          webhook_url: "https://discord.com/api/webhooks/4/rally"
        })

      wh
    end

    test "a :rally webhook is selected when present and enabled", %{notification: n} do
      rally_wh = add_rally_webhook(n)

      assert {:ok, %{id: id}} = Router.rally_destination(with_webhooks(n))
      assert id == rally_wh.id
    end

    # NO fallback, deliberately. A rally embed names the system by its map-local
    # tag, so inheriting the :system webhook would hand a chain tag to a channel
    # chosen for killmails, with no user action and no way to notice.
    test "drops when no :rally row exists, rather than inheriting :system", %{notification: n} do
      assert Router.rally_destination(with_webhooks(n)) == :drop
    end

    test "a disabled :rally webhook drops rather than rerouting", %{notification: n} do
      rally_wh = add_rally_webhook(n)
      {:ok, _} = MapDiscordWebhook.set_enabled(rally_wh, %{enabled?: false})

      assert Router.rally_destination(with_webhooks(n)) == :drop
    end
  end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mix test test/unit/external_events/discord/router_test.exs -k rally_destination`

Expected: FAIL with `UndefinedFunctionError` — `Router.rally_destination/1` does not exist.

- [ ] **Step 3: Implement the resolver**

In `lib/wanderer_app/external_events/discord/router.ex`, directly below `route_destination/1`:

```elixir
  @doc """
  Resolves a rally ping to a destination. `notification` must have `:webhooks`
  loaded.

  No fallback: without a `:rally` webhook this drops. See the moduledoc.
  """
  @spec rally_destination(struct()) :: {:ok, struct()} | :drop
  def rally_destination(notification) do
    usable(webhook(notification, :rally))
  end
```

- [ ] **Step 4: Record the reasoning in the moduledoc**

Append to `router.ex`'s moduledoc, after the route-alerts section:

```elixir
  ## Rally pings have their own destination, and no fallback

  `rally_destination/1` resolves a rally ping to the `:rally` webhook and
  nothing else. A missing `:rally` row drops.

  The old external notifier did fall back — its rally channel defaulted to the
  primary channel — and we deliberately do not reproduce that. A rally embed
  names the system by the map's own tag (`SystemName.display_name/3` with
  `:rally` resolves map-local first), so a fallback would put a chain tag into a
  channel chosen for killmails, with no user action and no way to notice. Rally
  pings are opt-in by configuring a `:rally` webhook.
```

- [ ] **Step 5: Run the router tests**

Run: `mix test test/unit/external_events/discord/router_test.exs`

Expected: PASS, all describe blocks.

- [ ] **Step 6: Format, lint, commit**

```bash
mix format
mix credo --strict lib/wanderer_app/external_events/discord/router.ex
git add lib/wanderer_app/external_events/discord/router.ex test/unit/external_events/discord/router_test.exs
git commit -m "feat(discord): resolve rally pings to their own destination

No fallback to :system: the embed names the system by the map's own tag, so
inheriting the kill channel would leak a chain tag into a channel chosen for
something else."
```

---

### Task 3: The rally embed

**Files:**
- Modify: `lib/wanderer_app/external_events/discord/embed_formatter.ex` (colour constant near `:64-65`; public formatter beside `format_route_alert/2` at `:142`)
- Test: `test/unit/external_events/discord/embed_formatter_test.exs`

**Interfaces:**
- Consumes: `SystemName.display_name/3` with `:rally` (Task 1).
- Produces: `EmbedFormatter.format_rally_ping(rally, opts) :: [map()]`, where `rally` is a map carrying `:map_id`, `:rally_point_id`, `:solar_system_id`, `:character_name`, `:character_eve_id`, `:message`, `:created_at`, and `opts` accepts `:mention_targets`. Returns a single-element list of Discord message maps.

- [ ] **Step 1: Write the failing tests**

In `test/unit/external_events/discord/embed_formatter_test.exs` (`async: true`, it is pure):

```elixir
  describe "format_rally_ping/2" do
    setup do
      rally = %{
        map_id: "00000000-0000-0000-0000-000000000001",
        rally_point_id: "eae7c5b4-2727-4a88-a041-3b5a5d4e5332",
        solar_system_id: "31000005",
        character_name: "Stealthbot",
        character_eve_id: "2115754172",
        message: nil,
        created_at: ~N[2026-08-03 02:05:00]
      }

      %{rally: rally}
    end

    test "renders title, fields and footer", %{rally: rally} do
      [%{"embeds" => [embed]}] = EmbedFormatter.format_rally_ping(rally, [])

      assert embed["title"] == "⚔️ Rally Point Created"
      assert embed["footer"]["text"] == "Rally ID: eae7c5b4-2727-4a88-a041-3b5a5d4e5332"

      assert [
               %{"name" => "System", "inline" => true},
               %{"name" => "Created By", "value" => "Stealthbot", "inline" => true}
             ] = embed["fields"]
    end

    test "carries the pilot portrait in the author line", %{rally: rally} do
      [%{"embeds" => [embed]}] = EmbedFormatter.format_rally_ping(rally, [])

      assert embed["author"]["name"] == "Stealthbot"

      assert embed["author"]["icon_url"] ==
               "https://images.evetech.net/characters/2115754172/portrait?size=64"
    end

    test "timestamps from created_at, not from now", %{rally: rally} do
      [%{"embeds" => [embed]}] = EmbedFormatter.format_rally_ping(rally, [])

      assert embed["timestamp"] == "2026-08-03T02:05:00Z"
    end

    test "appends the pilot's message when there is one", %{rally: rally} do
      [%{"embeds" => [embed]}] =
        EmbedFormatter.format_rally_ping(%{rally | message: "form up"}, [])

      assert embed["description"] =~ "💬 form up"
    end

    test "omits the message section when blank", %{rally: rally} do
      [%{"embeds" => [embed]}] = EmbedFormatter.format_rally_ping(%{rally | message: ""}, [])

      refute embed["description"] =~ "💬"
    end

    test "no content line without mention targets", %{rally: rally} do
      [message] = EmbedFormatter.format_rally_ping(rally, [])

      refute Map.has_key?(message, "content")
    end

    test "pings the configured role and allowlists it", %{rally: rally} do
      [message] =
        EmbedFormatter.format_rally_ping(rally, mention_targets: ["role:123456789012345678"])

      assert message["content"] == "<@&123456789012345678> Rally point created!"
      assert message["allowed_mentions"]["parse"] == []
      assert message["allowed_mentions"]["roles"] == ["123456789012345678"]
    end
  end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs -k format_rally_ping`

Expected: FAIL with `UndefinedFunctionError` — `format_rally_ping/2` does not exist.

- [ ] **Step 3: Add the colour constant**

In `embed_formatter.ex`, below `@color_route_improved`:

```elixir
  # Rally pings share a channel with nothing by default, but the palette is
  # shared across the Discord surface and every other hue is spoken for: red,
  # green, yellow and orange by @color_loss, @color_kill and the @value_colors
  # tiers, blue by the route family. Purple is unclaimed, and reads as neither
  # combat nor logistics — which is what a rally is.
  #
  # Deliberately NOT the old external notifier's 0xFF6B00: that orange collides
  # with the 1B-ISK @value_colors tier.
  @color_rally 0x9B59B6
```

- [ ] **Step 4: Implement the formatter**

In `embed_formatter.ex`, beside `format_route_alert/2`:

```elixir
  @doc """
  A rally ping as a single Discord message.

  Unlike route alerts, there is no "quieter" variant: a rally point *is* the
  ping, so the mention fires whenever the destination has targets configured.
  """
  @spec format_rally_ping(map(), keyword()) :: [map()]
  def format_rally_ping(rally, opts) do
    embed = rally_embed(rally)
    mention_targets = Keyword.get(opts, :mention_targets, [])

    message =
      case rally_ping(mention_targets) do
        nil ->
          %{"embeds" => [embed]}

        {content, allowed_mentions} ->
          %{"embeds" => [embed], "content" => content, "allowed_mentions" => allowed_mentions}
      end

    [message]
  end

  defp rally_embed(rally) do
    system_name = rally_system_name(rally)

    %{
      "author" => rally_author(rally),
      "title" => truncate("⚔️ Rally Point Created", @max_title_length),
      "url" => map_url(rally.map_id),
      "color" => @color_rally,
      "description" => truncate(rally_description(rally, system_name), @max_description_length),
      "fields" => [
        %{"name" => "System", "value" => system_name, "inline" => true},
        %{"name" => "Created By", "value" => rally.character_name, "inline" => true}
      ],
      "footer" => %{"text" => "Rally ID: #{rally.rally_point_id}"},
      "timestamp" => rally_timestamp(rally)
    }
    |> drop_nils()
  end

  defp rally_author(%{character_name: name, character_eve_id: eve_id}) when is_binary(eve_id) do
    %{
      "name" => truncate(name, @max_author_length),
      "icon_url" => "#{@image_base}/characters/#{eve_id}/portrait?size=64"
    }
  end

  defp rally_author(%{character_name: name}) do
    %{"name" => truncate(name, @max_author_length)}
  end

  defp rally_description(rally, system_name) do
    base = "**#{rally.character_name}** has created a rally point in **#{system_name}**"

    case rally.message do
      message when is_binary(message) ->
        case String.trim(message) do
          "" -> base
          trimmed -> "#{base}\n\n💬 #{trimmed}"
        end

      _ ->
        base
    end
  end

  # Literal :rally, per SystemName's map-local-names privacy boundary — never
  # threaded through as a variable. The payload's own `system_name` field is the
  # raw MapSystem name and bypasses that boundary; do not use it.
  defp rally_system_name(%{map_id: map_id, solar_system_id: solar_system_id}) do
    with id when is_integer(id) <- to_solar_system_id(solar_system_id),
         name when is_binary(name) <- SystemName.display_name(map_id, id, :rally) do
      name
    else
      _ -> "Unknown system"
    end
  end

  defp to_solar_system_id(id) when is_integer(id), do: id

  defp to_solar_system_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp to_solar_system_id(_id), do: nil

  # The ping's own creation time, not `DateTime.utc_now/0`. The old external
  # formatter stamped "now", which misreports the time on any delivery retry —
  # and this queue retries up to five times with backoff. `inserted_at` arrives
  # as a zone-less NaiveDateTime, so the zone is attached here rather than
  # emitting an offset-free string Discord would read as local.
  defp rally_timestamp(%{created_at: %DateTime{} = created_at}),
    do: DateTime.to_iso8601(created_at)

  defp rally_timestamp(%{created_at: %NaiveDateTime{} = created_at}) do
    created_at
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp rally_timestamp(_rally), do: nil

  defp rally_ping([]), do: nil

  defp rally_ping(mention_targets) do
    if WandererApp.Env.discord_mentions_enabled?() do
      case Mentions.prefix(mention_targets) do
        nil -> nil
        content -> {"#{content} Rally point created!", Mentions.allowed_mentions(mention_targets)}
      end
    end
  end
```

- [ ] **Step 5: Run the formatter tests**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

Expected: PASS, including every pre-existing kill and route test.

- [ ] **Step 6: Format, lint, commit**

```bash
mix format
mix credo --strict lib/wanderer_app/external_events/discord/embed_formatter.ex
git add lib/wanderer_app/external_events/discord/embed_formatter.ex test/unit/external_events/discord/embed_formatter_test.exs
git commit -m "feat(discord): format the rally ping embed

House style rather than the old external formatter's: portrait in the author
line, map link, front-loaded title. Two deliberate departures from it — the
footer timestamps from the ping's created_at rather than now, which the retry
queue would otherwise misreport, and the colour avoids the ISK tier its old
orange collided with."
```

---

### Task 4: Dispatch and deliver

**Files:**
- Create: `lib/wanderer_app/external_events/discord/rally_ping.ex`
- Modify: `lib/wanderer_app/external_events/discord_dispatcher.ex` (new `do_dispatch/2` clause immediately above the catch-all at `:313`)
- Test: `test/unit/external_events/discord_dispatcher_test.exs`

**Interfaces:**
- Consumes: `Router.rally_destination/1` (Task 2), `EmbedFormatter.format_rally_ping/2` (Task 3).
- Produces: `RallyPing.deliver(map_id, webhook, payload) :: :ok`. Always returns `:ok`; failures are logged and counted, never raised.

- [ ] **Step 1: Write the failing dispatcher tests**

In `test/unit/external_events/discord_dispatcher_test.exs`, following the existing route-alert describe block's setup (which enables `webhooks_enabled` and restores `:external_events` in `on_exit`):

```elixir
  describe "rally ping dispatch" do
    test "enqueues a message to the rally destination", %{map_id: map_id, notification: n} do
      {:ok, webhook} =
        MapDiscordWebhook.create(%{
          notification_id: n.id,
          role: :rally,
          webhook_url: "https://discord.com/api/webhooks/9/rally"
        })

      DiscordDispatcher.dispatch_event(map_id, rally_event())

      assert_receive {:delivered, webhook_id, [message]}, 2_000
      assert webhook_id == webhook.id
      assert [%{"title" => "⚔️ Rally Point Created"}] = message["embeds"]
    end

    test "drops when the map has no rally destination", %{map_id: map_id} do
      DiscordDispatcher.dispatch_event(map_id, rally_event())

      refute_receive {:delivered, _webhook_id, _messages}, 500
    end

    test "drops when webhooks are globally disabled", %{map_id: map_id, notification: n} do
      {:ok, _} =
        MapDiscordWebhook.create(%{
          notification_id: n.id,
          role: :rally,
          webhook_url: "https://discord.com/api/webhooks/9/rally"
        })

      put_external_events(webhooks_enabled: false)

      DiscordDispatcher.dispatch_event(map_id, rally_event())

      refute_receive {:delivered, _webhook_id, _messages}, 500
    end
  end
```

Add the event helper beside the file's other builders:

```elixir
  defp rally_event do
    %WandererApp.ExternalEvents.Event{
      type: :rally_point_added,
      payload: %{
        rally_point_id: "eae7c5b4-2727-4a88-a041-3b5a5d4e5332",
        solar_system_id: "31000005",
        character_name: "Stealthbot",
        character_eve_id: "2115754172",
        message: nil,
        created_at: ~N[2026-08-03 02:05:00]
      }
    }
  end
```

Reuse the file's existing worker-supervisor stand-in pattern — a module swapped in via app env, **not Mox**, because this work runs off `Discord.TaskSupervisor` and Mox expectations do not cross that process boundary (see the comment at the top of the file). Rally reads `:rally_ping_worker_supervisor`, so the setup swaps that key and restores it in `on_exit`, exactly as the route-alert block does with `:route_alert_worker_supervisor`. Match how the route-alert tests obtain `%{map_id:, notification:}` from the shared setup; do not build a new fixture.

- [ ] **Step 2: Run them and watch them fail**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs -k "rally ping dispatch"`

Expected: FAIL — the first test times out on `assert_receive`, because `:rally_point_added` currently falls into the catch-all clause and nothing is enqueued.

- [ ] **Step 3: Create the delivery module**

Create `lib/wanderer_app/external_events/discord/rally_ping.ex`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.RallyPing do
  @moduledoc """
  Formats a rally point and hands it to the destination's delivery worker.

  Lives outside `DiscordDispatcher` because that process is a singleton shared
  by every map: it may gate and hand off, and nothing else. Everything here runs
  in a task, so it may render and enqueue.

  Creation only. `:rally_point_removed` is deliberately not handled — a rally
  normally ends by the 60-minute expiry in `WandererApp.Map.MapManager`, and
  that path emits no external event at all, so a cancellation message would fire
  for manual cancels and stay silent for the common case. Its absence would then
  read as "still active", which is worse than never posting one.
  """

  require Logger

  alias WandererApp.ExternalEvents.Discord.EmbedFormatter
  alias WandererApp.ExternalEvents.Discord.WorkerSupervisor

  @doc """
  Renders `payload` and enqueues it for `webhook`. Always returns `:ok`.
  """
  @spec deliver(String.t(), struct(), map()) :: :ok
  def deliver(map_id, webhook, payload) do
    messages =
      payload
      |> Map.put(:map_id, map_id)
      |> EmbedFormatter.format_rally_ping(mention_targets: webhook.mention_targets)

    case worker_supervisor_impl().deliver(webhook.id, messages) do
      :ok ->
        emit_telemetry(map_id, :delivered)

      # "Nothing was enqueued" — the Discord supervision tree is down. Mirrors
      # RouteWatcher's handling of the same result, minus the state revert:
      # a rally ping carries no persisted state to roll back.
      {:error, :not_running} ->
        emit_telemetry(map_id, :not_running)

      {:error, reason} ->
        Logger.warning(
          "[Discord.RallyPing] rally ping delivery enqueue failed for map #{map_id}: #{inspect(reason)}"
        )

        emit_telemetry(map_id, :error)
    end

    :ok
  end

  defp emit_telemetry(map_id, outcome) do
    :telemetry.execute(
      [:wanderer_app, :discord, :rally_ping],
      %{count: 1},
      %{map_id: map_id, outcome: outcome}
    )
  end

  defp worker_supervisor_impl,
    do: Application.get_env(:wanderer_app, :rally_ping_worker_supervisor, WorkerSupervisor)
end
```

The app-env key is feature-specific, matching `route_watcher.ex:377`'s
`:route_alert_worker_supervisor`. Do not collapse the two into a shared key —
each feature's tests swap their own seam independently.

- [ ] **Step 4: Add the dispatcher clause**

In `lib/wanderer_app/external_events/discord_dispatcher.ex`, immediately **above** the catch-all `defp do_dispatch(_map_id, _event), do: :ok`:

```elixir
  # Gate and hand off, nothing more — this process is a singleton for every map.
  # Rendering and enqueueing run in a task, like every other non-trivial step
  # here. Creation only; see `RallyPing`'s moduledoc for why removals are not
  # wired.
  defp do_dispatch(map_id, %{type: :rally_point_added, payload: payload}) do
    with true <- enabled_globally?(),
         {:ok, notification} <- fetch_config(map_id),
         {:ok, webhook} <- Router.rally_destination(notification) do
      start_task(fn -> RallyPing.deliver(map_id, webhook, payload) end)
    end

    :ok
  end
```

Add `alias WandererApp.ExternalEvents.Discord.RallyPing` to the module's alias block. Note `start_task/1` already returns `nil` and logs when the task supervisor is not running.

- [ ] **Step 5: Run the dispatcher tests**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs`

Expected: PASS, including the pre-existing kill and route-alert blocks.

- [ ] **Step 6: Run the whole Discord test surface**

Run: `mix test test/unit/external_events/`

Expected: PASS.

- [ ] **Step 7: Format, lint, commit**

```bash
mix format
mix credo --strict lib/wanderer_app/external_events/discord/rally_ping.ex lib/wanderer_app/external_events/discord_dispatcher.ex
git add lib/wanderer_app/external_events/discord/rally_ping.ex lib/wanderer_app/external_events/discord_dispatcher.ex test/unit/external_events/discord_dispatcher_test.exs
git commit -m "feat(discord): post rally points to their destination

The dispatcher clause gates and hands off; it is a singleton for every map, so
rendering and enqueueing run in a task. Creation only — the 60-minute expiry
emits no external event, so a cancellation message would be silent for how
rallies normally end."
```

---

### Task 5: The settings row

**Files:**
- Modify: `lib/wanderer_app_web/live/maps/components/map_notifications_component.ex` — `@roles` at `:88`, the `remove-webhook` role guard at `:374`, `parse_role/1` at `:721-725`, `role_label/1` at `:736-738`, `role_name/1` at `:1529`, and a new `webhook_row` call site beside the `:route` one at `:2428`
- Modify: `lib/wanderer_app/external_events/discord/channel_info.ex` — `@type role` at `:65`, `@roles` at `:76`
- Test: `test/wanderer_app_web/live/map_notifications_test.exs`

**Interfaces:**
- Consumes: the `:rally` role from Task 1.
- Produces: no new functions. A rally destination becomes configurable in the UI.

- [ ] **Step 1: Write the failing LiveView tests**

In `test/wanderer_app_web/live/map_notifications_test.exs` (`async: false`), modelled on the `"route alerts"` describe block:

```elixir
  describe "rally pings" do
    test "saves a rally webhook", %{conn: conn, map: map} do
      {:ok, view, _html} = live(conn, ~p"/maps?tab=notifications&map_id=#{map.id}")

      view
      |> form("#webhook-form-rally", %{
        "webhook" => %{"webhook_url" => "https://discord.com/api/webhooks/7/rallytoken"}
      })
      |> render_submit()

      assert render(view) =~ "Rally channel"
      assert {:ok, %{role: :rally}} = rally_webhook(map)
    end

    test "removing the rally channel does not raise", %{conn: conn, map: map} do
      {:ok, view, _html} = live(conn, ~p"/maps?tab=notifications&map_id=#{map.id}")
      create_rally_webhook(map)

      render_click(view, "remove-webhook", %{"role" => "rally"})

      assert render(view) =~ "Rally channel removed."
    end
  end
```

Match the existing block's helpers for building a map, a notification and a webhook; do not introduce new fixture functions if equivalents exist.

- [ ] **Step 2: Run them and watch them fail**

Run: `mix test test/wanderer_app_web/live/map_notifications_test.exs -k "rally pings"`

Expected: FAIL — there is no `#webhook-form-rally` in the rendered markup.

- [ ] **Step 3: Widen every role enumeration**

All six sites in `map_notifications_component.ex`:

```elixir
  @roles [:system, :character, :route, :rally]
```

```elixir
  defp parse_role("character"), do: :character
  defp parse_role(:character), do: :character
  defp parse_role("route"), do: :route
  defp parse_role(:route), do: :route
  defp parse_role("rally"), do: :rally
  defp parse_role(:rally), do: :rally
  defp parse_role(_), do: :system
```

**This clause is the most damaging omission available in this change.** `parse_role/1` falls through to `:system`, so without it a rally form submit silently overwrites the kill channel's webhook URL.

```elixir
  defp role_label(:system), do: "Kill channel"
  defp role_label(:character), do: "Character kill channel"
  defp role_label(:route), do: "Route alert channel"
  defp role_label(:rally), do: "Rally channel"
```

```elixir
  defp role_name(:system), do: "the system channel"
  defp role_name(:character), do: "the character channel"
  defp role_name(:route), do: "route alerts"
  defp role_name(:rally), do: "rally pings"
```

And the `remove-webhook` guard:

```elixir
      {role, %{} = webhook} when role in [:system, :character, :route, :rally] ->
```

In `channel_info.ex`:

```elixir
  @type role :: :system | :character | :route | :rally
```

```elixir
  @roles [:system, :character, :route, :rally]
```

- [ ] **Step 4: Add the row markup**

In `map_notifications_component.ex`, after the `:route` row's `collision_warning` and its mentions disclosure:

```heex
          <.webhook_row
            role={:rally}
            title="Rally channel"
            help="Where rally points are posted. The embed names the system by the map's own tag, so treat this channel as trusted."
            webhook={@webhooks[:rally]}
            channel_info={@channel_hints[:rally]}
            form={@webhook_forms[:rally]}
            replacing?={@replacing_url?[:rally]}
            removable?={true}
            empty_status_text="No rally pings delivered yet."
            myself={@myself}
          />
          <.collision_warning role={:rally} collisions={@collisions} />
```

Then copy the `:route` row's mentions disclosure block verbatim, substituting `:rally` for `:route` and giving the disclosure a unique `id` (`"rally-mentions-disclosure"`) — duplicate DOM ids break LiveView patching. The mention chips are how the role-to-ping is configured, so the row is not complete without them.

- [ ] **Step 5: Run the LiveView tests**

Run: `mix test test/wanderer_app_web/live/map_notifications_test.exs`

Expected: PASS, including the pre-existing collision and mention tests.

- [ ] **Step 6: Run the full suite**

Run: `mix test`

Expected: PASS. Investigate any failure before committing; do not adjust an unrelated test to go green.

- [ ] **Step 7: Format, lint, commit**

```bash
mix format
mix credo --strict
git add lib/wanderer_app_web/live/maps/components/map_notifications_component.ex lib/wanderer_app/external_events/discord/channel_info.ex test/wanderer_app_web/live/map_notifications_test.exs
git commit -m "feat(discord): configure the rally channel in map settings

Role enumeration is duplicated across eight sites and derived from nothing, so
a partial addition compiles and fails at whichever one was missed. parse_role/1
is the dangerous one: it falls through to :system, so without a rally clause a
rally submit overwrites the kill channel's URL."
```

---

## Manual verification

After Task 5, before opening a PR:

- [ ] Configure a rally webhook against a test Discord channel, add a role to its mention targets, and use **Send test** to confirm the destination works.
- [ ] Drop a rally point on a map and confirm the message posts: role pinged, title, pilot portrait, map-local system name, `Rally ID` footer, and the timestamp matching when the rally was created.
- [ ] Drop a rally with a message typed in, and confirm the `💬` section appears.
- [ ] Disable the rally destination and confirm a new rally posts **nothing at all** — in particular, nothing appears in the kill or route channel.
