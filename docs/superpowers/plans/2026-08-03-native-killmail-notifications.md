# Native Killmail Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring wanderer's built-in Discord kill notifier to parity with the standalone `wanderer-notifier` service — per-map character/corporation matching, a second character-role webhook, richer embeds, and routing rules — so the separate service is no longer needed.

**Architecture:** The single `MapDiscordNotification` row is split into a policy parent and up to two `MapDiscordWebhook` children (`role: :system`, `role: :character`), so failure accounting and rate-limit backoff become per-destination. Killmail flattening is extended to retain the full attacker character/corporation ID lists, which a cached per-map tracked-EVE-ID set is matched against to produce an involvement verdict; a routing table turns that verdict plus the map's policy into exactly one destination webhook, or a drop. Delivery workers are rekeyed from `map_id` to `webhook_id`.

**Tech Stack:** Elixir 1.17.3 / OTP 26, Phoenix + LiveView, Ash Framework with AshPostgres and AshCloak (encrypted webhook URLs), Cachex, Phoenix Channels WebSocket client (`wanderer-kills` upstream), Discord webhook HTTP API.

**Source spec:** `docs/superpowers/specs/2026-08-03-native-killmail-notifications-design.md`. Where this plan and the spec disagree, the spec wins — stop and reconcile rather than guessing.

## Global Constraints

- **Map-local system names (`temporary_name` / `custom_name`) may appear on the `:system` webhook ONLY.** The `:character` webhook always uses the canonical EVE system name. Rationale, which must be preserved in the `SystemName` moduledoc: many corporations keep their character-kill channel public, so people deliberately not granted map access can read it, and a Discord post cannot be recalled. This looks like an inconsistency and will invite a "fix" — it is a privacy boundary.
- **Webhook URLs are credentials.** Encrypted at rest via AshCloak, never rendered back in full in the UI (masked hint plus a replace flow only), never logged.
- **A disabled destination drops the kill; it never reroutes to the other webhook.** Silently redirecting into a channel the user did not choose is a privacy problem, not a convenience.
- **Delivery is at-most-once by choice.** A kill lost to delivery failure is not re-sent: a duplicate chat post is irreversible, while a dropped kill remains visible in the kills widget and on zKillboard. Do not "fix" this into at-least-once.
- **Absent ≠ empty.** Flat-format payloads may omit `attacker_char_ids` entirely. Use `Map.has_key?/2`; never `Map.get(key, [])`, which would silently convert "unknown attackers" into "no attackers" and defeat all attacker matching.
- **Fail-open at the dispatcher.** An unparseable `kill_time` lets the kill through; a tracked-EVE-ID cache error routes to the system webhook rather than dropping. This matches the dispatcher's existing posture.
- **Ash actions only.** Never raw Ecto against these tables; every new action needs `code_interface` `define` coverage. Actions that read state before writing need `require_atomic? false`.
- `Character.eve_id` is a **string**; killmail character IDs arrive as **integers**. Every comparison must coerce explicitly, in one place.
- Tests touching application env, global caches, or the worker supervision tree use `use WandererApp.DataCase, async: false` and must restore any `Application.put_env` override in `on_exit`. `config/test.exs:35` sets `webhooks_enabled` to `false`, so dispatcher tests must override it.
- **The Elixir toolchain is not installed on the authoring host.** Every `mix` command in this plan must be run in the devcontainer. No step in this plan has been executed or verified by running it.

## File Structure

**New modules**

| File | Responsibility |
|---|---|
| `lib/wanderer_app/api/map_discord_webhook.ex` | One Discord destination: URL (encrypted), role, enable flag, failure accounting |
| `lib/wanderer_app/external_events/discord/matcher.ex` | Cached per-map tracked-EVE-ID set; victim/attacker involvement verdict |
| `lib/wanderer_app/external_events/discord/router.ex` | Verdict + map policy → exactly one webhook, or `:drop` |
| `lib/wanderer_app/external_events/discord/system_name.ex` | Role-aware system display name; enforces the privacy constraint |
| `lib/wanderer_app/esi/corporation_search.ex` | ESI corporation search and label resolution, shared by the map UI and the notifications UI |

**Substantially modified**

| File | Change |
|---|---|
| `lib/wanderer_app/api/map_discord_notification.ex` | Becomes policy-only: `enabled?`, `wh_only`, `excluded_systems`, `focus_corp_ids`, `webhooks` relationship |
| `lib/wanderer_app/kills/message_handler.ex` | Retain attacker char/corp ID lists and top-damage attacker through flattening |
| `lib/wanderer_app/external_events/discord_dispatcher.ex` | Match → route → partition per destination; max-age guard |
| `lib/wanderer_app/external_events/discord/worker.ex` | Rekeyed from `map_id` to `webhook_id` |
| `lib/wanderer_app/external_events/discord/worker_supervisor.ex` | `deliver/2` and `stop_worker/1` keyed by webhook id |
| `lib/wanderer_app/external_events/discord/embed_formatter.ex` | Rich embeds; takes the verdict and a pre-resolved system name |
| `lib/wanderer_app/kills/client.ex` | Jittered exponential reconnect backoff with an injectable random source |
| `lib/wanderer_app_web/live/maps/components/map_notifications_component.ex` | Two destinations, per-row status and test, focus corporations |
| `lib/wanderer_app/external_events/json_api_formatter.ex` | Correct the `:map_kill` attribute names |

**Phase order.** A: schema split (Tasks 1–4) — lands and is verified before anything is built on it, with Task 4 as the seam that keeps the suite green. B: ingestion and matching (5–8). C: embeds and the privacy constraint (9–10). D: resilience and config (11–12). E: UI and public surface (13–15).

---

## Phase A — Schema split (Tasks 1–4)

Splits Discord destinations out of the policy row so failure accounting becomes per-destination. Task 4 is the seam: at the end of this phase behaviour is byte-for-byte what it is today, single-destination, and the whole suite is green. Nothing in Phase B may be started early inside these tasks.

**Known cross-task wrinkle:** Task 1's `after_destroy` calls `WorkerSupervisor.stop_worker(record.id)` with the webhook id, which is the final contract, but Task 3 is what rekeys the supervisor from map id to webhook id. The arity is unchanged so it compiles, and between Task 1 and Task 3 that call is pointed at the wrong key. Do not add a shim — land Task 3.

### Task 1: Create the `MapDiscordWebhook` child resource

Splits the destination (a webhook URL plus its delivery health) out of the per-map
policy row. Today `record_failure` increments one counter and disables the whole
config at 10 consecutive failures (`lib/wanderer_app/api/map_discord_notification.ex:105-136`),
so a second URL on the same row would mean a dead character channel switching off
system-kill notifications too. After this task, failure state is per destination.

**Files:**
- Create: `lib/wanderer_app/api/map_discord_webhook.ex`
- Modify: `lib/wanderer_app/api.ex:41` (register the new resource in the domain)
- Test: `test/unit/api/map_discord_webhook_test.exs`

**Interfaces:**
- Consumes: `WandererApp.Api.MapDiscordNotification` (parent, unchanged in this task —
  it still carries `webhook_url` and the failure columns; Task 2 removes them)
- Produces:
  - `MapDiscordWebhook.create(%{notification_id:, role:, webhook_url:})`
  - `MapDiscordWebhook.by_id(id)`
  - `MapDiscordWebhook.by_notification(notification_id)` (read, returns a list)
  - `MapDiscordWebhook.update(record, attrs)`, `MapDiscordWebhook.destroy(record)`
  - `MapDiscordWebhook.record_success(record)`, `MapDiscordWebhook.record_failure(record, error)`
  - `MapDiscordWebhook.disable(record, error)`
  - `MapDiscordWebhook.set_enabled(record, %{enabled?: bool})`
  - `MapDiscordWebhook.valid_webhook_url?(url)`

---

- [ ] **Step 1: Write the first failing test file — create, defaults, and URL validation**

Create `test/unit/api/map_discord_webhook_test.exs`:

```elixir
defmodule WandererApp.Api.MapDiscordWebhookTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererAppWeb.Factory

  defp valid_url, do: "https://discord.com/api/webhooks/123456789/abcdefTOKEN"

  setup do
    map = Factory.insert(:map, %{})
    {:ok, notification} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})
    %{map: map, notification: notification}
  end

  test "creates with valid discord url and defaults", %{notification: notification} do
    assert {:ok, hook} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: valid_url()
             })

    assert hook.role == :character
    assert hook.webhook_url == valid_url()
    assert hook.enabled? == true
    assert hook.consecutive_failures == 0
    assert hook.last_error == nil
    assert hook.last_error_at == nil
    assert hook.last_delivery_at == nil
  end

  test "accepts discordapp.com host", %{notification: notification} do
    url = "https://discordapp.com/api/webhooks/123/tok"

    assert {:ok, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })
  end

  test "accepts a versioned webhook path", %{notification: notification} do
    url = "https://canary.discord.com/api/v10/webhooks/999/newtok"

    assert {:ok, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })
  end

  test "rejects non-https scheme", %{notification: notification} do
    url = "http://discord.com/api/webhooks/123/tok"

    assert {:error, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })
  end

  test "rejects non-discord host", %{notification: notification} do
    url = "https://evil.example.com/api/webhooks/123/tok"

    # Assert on the specific validation message, not a bare {:error, _}. A
    # blanket-reject regression (e.g. reading the AshCloak attribute instead of
    # the argument, which yields %Ash.NotLoaded{}) would satisfy {:error, _}
    # while rejecting valid URLs too.
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })

    assert Enum.any?(errors, fn e ->
             Map.get(e, :field) == :webhook_url and
               to_string(Map.get(e, :message, "")) =~ "Discord webhook URL"
           end)
  end

  test "rejects host that merely contains discord.com", %{notification: notification} do
    url = "https://discord.com.evil.example/api/webhooks/123/tok"

    assert {:error, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })
  end

  test "rejects malformed webhook path", %{notification: notification} do
    url = "https://discord.com/api/not-webhooks/123/tok"

    assert {:error, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })
  end

  test "rejects an unknown role", %{notification: notification} do
    assert {:error, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :corporation,
               webhook_url: valid_url()
             })
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/api/map_discord_webhook_test.exs`
Expected: FAIL with `** (UndefinedFunctionError) function WandererApp.Api.MapDiscordWebhook.create/1 is undefined (module WandererApp.Api.MapDiscordWebhook is not available)`

- [ ] **Step 3: Create the resource module — postgres, cloak, attributes, relationships, identities**

Create `lib/wanderer_app/api/map_discord_webhook.ex`. The physical column for the
encrypted attribute is `encrypted_webhook_url :binary`, matching the parent table
(`priv/repo/migrations/20260801234058_add_map_discord_notifications.exs:38`);
AshCloak derives that name, you do not declare it.

```elixir
defmodule WandererApp.Api.MapDiscordWebhook do
  @moduledoc """
  One Discord destination belonging to a `MapDiscordNotification`.

  The parent row holds per-map policy; each child row holds one webhook URL and
  that destination's delivery health. Splitting them means a dead character
  channel disables only itself — before the split, a single `consecutive_failures`
  counter on the parent would have switched off system-kill notifications too.

  The webhook URL is a credential — anyone holding it can post arbitrary messages
  to the channel — so it is encrypted at rest and never rendered back in full.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak]

  @discord_hosts ["discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com"]

  # Mirrors `WebhookDispatcher`'s threshold (webhook_dispatcher.ex:32): a run of
  # 10 consecutive failures disables this destination. Only a 404 bypasses this.
  @max_consecutive_failures 10

  # Matches the :last_error attribute's max_length constraint, so an
  # unexpectedly long error message is truncated rather than rejected.
  @max_error_length 500

  postgres do
    repo(WandererApp.Repo)
    table("map_discord_webhooks_v1")

    references do
      reference :notification, on_delete: :delete
    end
  end

  cloak do
    vault(WandererApp.Vault)
    attributes([:webhook_url])
    decrypt_by_default([:webhook_url])
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      constraints one_of: [:system, :character]
    end

    attribute :webhook_url, :string do
      allow_nil? false
      sensitive? true
      constraints max_length: 2000
    end

    attribute :enabled?, :boolean, default: true, allow_nil?: false

    attribute :last_delivery_at, :utc_datetime
    attribute :last_error, :string, constraints: [max_length: 500]
    attribute :last_error_at, :utc_datetime
    attribute :consecutive_failures, :integer, default: 0, allow_nil?: false

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :notification, WandererApp.Api.MapDiscordNotification do
      attribute_writable? true
      allow_nil? false
    end
  end

  identities do
    identity :unique_notification_role, [:notification_id, :role]
  end
end
```

- [ ] **Step 4: Add the URL validation helpers and the `ValidateWebhookUrl` validation**

Append inside the same module, after the `identities do` block:

```elixir
  @doc """
  Returns true when the URL is a syntactically valid Discord webhook endpoint.
  Exposed so the LiveView form can validate before submitting.
  """
  def valid_webhook_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: path} when is_binary(host) and is_binary(path) ->
        host in @discord_hosts and valid_webhook_path?(path)

      _ ->
        false
    end
  end

  def valid_webhook_url?(_), do: false

  defp valid_webhook_path?(path) do
    case String.split(path, "/", trim: true) do
      ["api", "webhooks", id, token] ->
        id != "" and token != ""

      ["api", version, "webhooks", id, token] ->
        String.starts_with?(version, "v") and id != "" and token != ""

      _ ->
        false
    end
  end

  defmodule ValidateWebhookUrl do
    @moduledoc false
    use Ash.Resource.Validation

    @impl true
    def validate(changeset, _opts, _context) do
      # AshCloak rewrites the encrypted field into a changeset *argument* (the
      # stored attribute is `encrypted_webhook_url`, and `webhook_url` becomes a
      # calculation). Reading only the attribute yields `%Ash.NotLoaded{}` — not
      # nil — which fails every validity check and rejects even valid URLs.
      # Read the argument first so the value being written is what gets checked.
      case Ash.Changeset.get_argument_or_attribute(changeset, :webhook_url) do
        nil ->
          :ok

        url ->
          if WandererApp.Api.MapDiscordWebhook.valid_webhook_url?(url) do
            :ok
          else
            {:error,
             field: :webhook_url,
             message:
               "must be a Discord webhook URL, e.g. https://discord.com/api/webhooks/{id}/{token}"}
          end
      end
    end
  end
```

- [ ] **Step 5: Add the `code_interface` and the create/read/update/destroy actions**

Insert these two blocks between the `cloak do` block and `attributes do`:

```elixir
  code_interface do
    define(:create, action: :create)
    define(:update, action: :update)
    define(:destroy, action: :destroy)
    define(:by_id, get_by: [:id], action: :read)
    define(:by_notification, action: :by_notification, args: [:notification_id])
    define(:set_enabled, action: :set_enabled)
    define(:record_success, action: :record_success)
    define(:record_failure, action: :record_failure, args: [:error])
    define(:disable, action: :disable, args: [:error])
  end

  actions do
    default_accept [:notification_id, :role, :webhook_url, :enabled?]

    defaults [:read]

    create :create do
      primary? true
      validate {__MODULE__.ValidateWebhookUrl, []}
      change after_action(&__MODULE__.invalidate_cache/3)
    end

    update :update do
      primary? true
      require_atomic? false
      validate {__MODULE__.ValidateWebhookUrl, []}
      change after_action(&__MODULE__.invalidate_cache/3)
    end

    # Custom destroy, following map_discord_notification.ex:59-64. The default
    # destroy would leave a stale cache entry AND leave this destination's
    # delivery worker draining its queue into a webhook the user just removed.
    destroy :destroy do
      primary? true
      require_atomic? false

      change after_action(&__MODULE__.after_destroy/3)
    end

    read :by_notification do
      argument :notification_id, :uuid, allow_nil?: false
      filter expr(notification_id == ^arg(:notification_id))
    end

    update :set_enabled do
      require_atomic? false
      accept [:enabled?]

      change after_action(&__MODULE__.invalidate_cache/3)
    end
  end
```

- [ ] **Step 6: Add the cache-invalidation and destroy hooks**

The dispatcher caches the parent config for five minutes
(`lib/wanderer_app/application.ex:133`), and invalidation is keyed by `map_id`.
The child does not carry `map_id`, so it resolves one by reading its parent. Every
child write must invalidate, or a newly added character webhook is ignored for up
to five minutes and a removed one keeps being selected. The `rescue` mirrors the
parent's tolerance for a cache that is not running (the parent's destroy test at
`test/unit/api/map_discord_notification_test.exs:157-164` depends on that
tolerance).

Append these to the module, next to `valid_webhook_url?/1`:

```elixir
  @doc false
  def invalidate_cache(_changeset, record, _context) do
    do_invalidate(record)
    {:ok, record}
  end

  @doc false
  def after_destroy(_changeset, record, _context) do
    do_invalidate(record)
    # Stop this destination's delivery worker too: without this, anything already
    # queued keeps posting to a webhook the user has just removed.
    WandererApp.ExternalEvents.Discord.WorkerSupervisor.stop_worker(record.id)
    {:ok, record}
  end

  defp do_invalidate(record) do
    case Ash.get(WandererApp.Api.MapDiscordNotification, record.notification_id) do
      {:ok, notification} ->
        WandererApp.ExternalEvents.DiscordDispatcher.invalidate_cache(notification.map_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
```

Note for the implementer: `WorkerSupervisor.stop_worker/1` becomes webhook-keyed in
Task 3 (see CONTRACT.md). Until Task 3 lands it is still map-keyed; the arity is
unchanged, so this compiles and the call is simply pointed at the wrong key for one
task. Do not add a shim.

- [ ] **Step 7: Register the resource in the Ash domain**

In `lib/wanderer_app/api.ex`, immediately after line 41
(`resource WandererApp.Api.MapDiscordNotification`), add:

```elixir
    resource WandererApp.Api.MapDiscordWebhook
```

- [ ] **Step 8: Generate and apply the migration for the new table**

Run: `mix ash.codegen create_map_discord_webhooks`
Then: `mix ash.migrate`

Verify the generated file creates `map_discord_webhooks_v1` with an
`encrypted_webhook_url :binary` column (not `webhook_url`), a
`references(:map_discord_notifications_v1, ..., on_delete: :delete_all)` foreign
key, and a unique index on `[:notification_id, :role]`. If `encrypted_webhook_url`
is missing, the `cloak` block is misplaced — fix the resource and re-run codegen
rather than hand-editing the migration.

- [ ] **Step 9: Run the test to verify it passes**

Run: `mix test test/unit/api/map_discord_webhook_test.exs`
Expected: all 8 tests pass.

- [ ] **Step 10: Commit**

`git commit -m "Add MapDiscordWebhook resource with per-destination webhook URL"`

- [ ] **Step 11: Write the failing tests for identity, cascade, and update validation**

Append to `test/unit/api/map_discord_webhook_test.exs`:

```elixir
  test "enforces one webhook per (notification, role)", %{notification: notification} do
    {:ok, _} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :system,
        webhook_url: valid_url()
      })

    assert {:error, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :system,
               webhook_url: "https://discord.com/api/webhooks/222/othertok"
             })
  end

  test "allows both roles under the same notification", %{notification: notification} do
    {:ok, _} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :system,
        webhook_url: valid_url()
      })

    assert {:ok, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: "https://discord.com/api/webhooks/222/othertok"
             })

    assert {:ok, hooks} = MapDiscordWebhook.by_notification(notification.id)
    assert Enum.map(hooks, & &1.role) |> Enum.sort() == [:character, :system]
  end

  test "rejects invalid url on UPDATE as well as create", %{notification: notification} do
    {:ok, hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: valid_url()
      })

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             MapDiscordWebhook.update(hook, %{webhook_url: "https://evil.example.com/x"})

    assert Enum.any?(errors, fn e ->
             Map.get(e, :field) == :webhook_url and
               to_string(Map.get(e, :message, "")) =~ "Discord webhook URL"
           end)

    # The rejected value must not have been persisted.
    {:ok, reloaded} = MapDiscordWebhook.by_id(hook.id)
    assert reloaded.webhook_url == valid_url()
  end

  test "accepts a valid replacement url on UPDATE", %{notification: notification} do
    # Guards against a blanket-reject regression: replacement must still work.
    {:ok, hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: valid_url()
      })

    replacement = "https://canary.discord.com/api/v10/webhooks/999/newtok"

    assert {:ok, updated} = MapDiscordWebhook.update(hook, %{webhook_url: replacement})
    assert updated.webhook_url == replacement
  end

  test "set_enabled toggles only this webhook", %{notification: notification} do
    {:ok, sys} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :system,
        webhook_url: valid_url()
      })

    {:ok, char} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: "https://discord.com/api/webhooks/222/othertok"
      })

    assert {:ok, char} = MapDiscordWebhook.set_enabled(char, %{enabled?: false})
    assert char.enabled? == false

    assert {:ok, sys} = MapDiscordWebhook.by_id(sys.id)
    assert sys.enabled? == true
  end

  test "destroying the notification cascades the webhooks away", %{notification: notification} do
    {:ok, hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: valid_url()
      })

    :ok = MapDiscordNotification.destroy(notification)

    assert {:error, _} = MapDiscordWebhook.by_id(hook.id)
  end

  test "destroy tolerates a cache and worker registry that are not running", %{
    notification: notification
  } do
    {:ok, hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: valid_url()
      })

    assert :ok = MapDiscordWebhook.destroy(hook)
    assert {:error, _} = MapDiscordWebhook.by_id(hook.id)
  end
```

- [ ] **Step 12: Run the tests to verify they pass**

Run: `mix test test/unit/api/map_discord_webhook_test.exs`
Expected: all pass. If "enforces one webhook per (notification, role)" fails, the
identity did not reach the database — re-check the unique index in the generated
migration. If the cascade test fails, the `references do reference :notification,
on_delete: :delete end` block is missing or was not picked up by codegen.

- [ ] **Step 13: Commit**

`git commit -m "Test MapDiscordWebhook identity, cascade, and update validation"`

- [ ] **Step 14: Write the failing tests for failure accounting**

Append to `test/unit/api/map_discord_webhook_test.exs`:

```elixir
  defp character_hook(notification) do
    {:ok, hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: valid_url()
      })

    hook
  end

  test "record_failure increments and does not disable before the threshold", %{
    notification: notification
  } do
    hook = character_hook(notification)

    hook =
      Enum.reduce(1..9, hook, fn _, acc ->
        {:ok, updated} = MapDiscordWebhook.record_failure(acc, "boom")
        updated
      end)

    assert hook.consecutive_failures == 9
    assert hook.enabled? == true
    assert hook.last_error == "boom"
    assert hook.last_error_at != nil
  end

  test "record_failure disables at 10 consecutive failures", %{notification: notification} do
    hook = character_hook(notification)

    hook =
      Enum.reduce(1..10, hook, fn _, acc ->
        {:ok, updated} = MapDiscordWebhook.record_failure(acc, "boom")
        updated
      end)

    assert hook.consecutive_failures == 10
    assert hook.enabled? == false
  end

  test "record_failure disables only the failing webhook", %{notification: notification} do
    # This is the entire point of the split: before it, ten failures on the
    # character channel would have silenced system kills too.
    {:ok, sys} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :system,
        webhook_url: valid_url()
      })

    {:ok, char} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: "https://discord.com/api/webhooks/222/othertok"
      })

    Enum.reduce(1..10, char, fn _, acc ->
      {:ok, updated} = MapDiscordWebhook.record_failure(acc, "boom")
      updated
    end)

    assert {:ok, sys} = MapDiscordWebhook.by_id(sys.id)
    assert sys.enabled? == true
    assert sys.consecutive_failures == 0
  end

  test "record_failure re-reads the counter rather than trusting a stale copy", %{
    notification: notification
  } do
    stale = character_hook(notification)

    # Advance the stored counter behind the back of the `stale` struct.
    {:ok, _} = MapDiscordWebhook.record_failure(stale, "first")

    {:ok, updated} = MapDiscordWebhook.record_failure(stale, "second")

    assert updated.consecutive_failures == 2
    assert updated.last_error == "second"
  end

  test "record_failure truncates an overlong error", %{notification: notification} do
    hook = character_hook(notification)

    {:ok, hook} = MapDiscordWebhook.record_failure(hook, String.duplicate("x", 900))

    assert String.length(hook.last_error) == 500
  end

  test "record_success clears the failure state", %{notification: notification} do
    hook = character_hook(notification)
    {:ok, hook} = MapDiscordWebhook.record_failure(hook, "boom")

    {:ok, hook} = MapDiscordWebhook.record_success(hook)

    assert hook.consecutive_failures == 0
    assert hook.last_error == nil
    assert hook.last_error_at == nil
    assert hook.last_delivery_at != nil
  end

  test "disable switches the webhook off immediately", %{notification: notification} do
    hook = character_hook(notification)

    {:ok, hook} = MapDiscordWebhook.disable(hook, "404 Not Found")

    assert hook.enabled? == false
    assert hook.last_error == "404 Not Found"
    assert hook.last_error_at != nil
  end
```

- [ ] **Step 15: Run the tests to verify they fail**

Run: `mix test test/unit/api/map_discord_webhook_test.exs`
Expected: FAIL with `function WandererApp.Api.MapDiscordWebhook.record_failure/2 is undefined or private`
(the `code_interface` defines it, but the actions do not exist yet — the actual
error will be a compile-time `No such action :record_failure`).

- [ ] **Step 16: Add the `record_success`, `record_failure`, and `disable` actions**

These are moved verbatim from `lib/wanderer_app/api/map_discord_notification.ex:85-157`,
retargeted at this module. Add them inside `actions do`, after `set_enabled`:

```elixir
    update :record_success do
      require_atomic? false
      accept []

      change set_attribute(:last_delivery_at, &DateTime.utc_now/0)
      change set_attribute(:consecutive_failures, 0)
      change set_attribute(:last_error, nil)
      change set_attribute(:last_error_at, nil)
    end

    # Increments the counter from the value re-read inside the change rather
    # than from a possibly-stale in-memory copy, and disables this destination
    # once the run reaches @max_consecutive_failures.
    #
    # This read-then-write is NOT atomic across nodes: two concurrent deliveries
    # on separate nodes could each read N and write N+1, losing an increment.
    # That is safe under the single-delivery-node assumption documented in the
    # spec (one worker per webhook, one node), and the failure mode is benign — a
    # webhook disables slightly later than it should. If the app is ever
    # clustered, replace this with an atomic SQL increment.
    update :record_failure do
      require_atomic? false
      accept []
      argument :error, :string, allow_nil?: false

      change fn changeset, _ctx ->
        current =
          case Ash.get(__MODULE__, changeset.data.id) do
            {:ok, fresh} -> fresh.consecutive_failures || 0
            _ -> Ash.Changeset.get_data(changeset, :consecutive_failures) || 0
          end

        next = current + 1

        changeset =
          changeset
          |> Ash.Changeset.change_attribute(:consecutive_failures, next)
          |> Ash.Changeset.change_attribute(
            :last_error,
            changeset |> Ash.Changeset.get_argument(:error) |> String.slice(0, @max_error_length)
          )
          |> Ash.Changeset.change_attribute(:last_error_at, DateTime.utc_now())

        if next >= @max_consecutive_failures do
          Ash.Changeset.change_attribute(changeset, :enabled?, false)
        else
          changeset
        end
      end

      change after_action(&__MODULE__.invalidate_cache/3)
    end

    # Immediate disable, used only for a 404 (webhook deleted upstream, will
    # never recover). Everything else goes through record_failure's threshold.
    update :disable do
      require_atomic? false
      accept []
      argument :error, :string, allow_nil?: false

      change set_attribute(:enabled?, false)
      change set_attribute(:last_error_at, &DateTime.utc_now/0)

      change fn changeset, _ctx ->
        Ash.Changeset.change_attribute(
          changeset,
          :last_error,
          changeset |> Ash.Changeset.get_argument(:error) |> String.slice(0, @max_error_length)
        )
      end

      change after_action(&__MODULE__.invalidate_cache/3)
    end
```

- [ ] **Step 17: Run the tests to verify they pass**

Run: `mix test test/unit/api/map_discord_webhook_test.exs`
Expected: all pass.

- [ ] **Step 18: Commit**

`git commit -m "Move Discord webhook failure accounting to the child resource"`

---

### Task 2: Make `MapDiscordNotification` policy-only and migrate existing rows

The parent stops being a destination. It keeps the per-map policy — `enabled?`,
`wh_only`, `excluded_systems` — gains `focus_corp_ids`, and hands `webhook_url`
plus the four failure-state columns to its children.

**Files:**
- Modify: `lib/wanderer_app/api/map_discord_notification.ex:34-38` (drop the `cloak` block),
  `:40-49` (code interface), `:51-158` (actions), `:160-184` (attributes),
  `:186-191` (relationships), `:197-210` (hooks), `:212-267` (URL validation — delete,
  it now lives on the child)
- Modify: the migration generated by `mix ash.codegen` (hand-add the data-copy step)
- Test: `test/unit/api/map_discord_notification_test.exs` (rewrite),
  `test/unit/repo/migrations/discord_webhook_split_test.exs` (new)

**Interfaces:**
- Consumes: `MapDiscordWebhook.create/1`, `MapDiscordWebhook.by_notification/1`,
  `MapDiscordWebhook.valid_webhook_url?/1` (Task 1),
  `WorkerSupervisor.stop_worker(webhook_id)` — **arity 1, webhook-keyed** (CONTRACT.md;
  the signature change itself is Task 3's job)
- Produces:
  - `MapDiscordNotification.create(%{map_id:, webhook_url:})` — creates the parent and
    its `:system` child in one transaction
  - `MapDiscordNotification.by_map(map_id)` — returns the record with `:webhooks` loaded
  - `notification.webhooks` — list of `%MapDiscordWebhook{}`
  - `notification.focus_corp_ids` — `[integer]`, default `[]`

---

- [ ] **Step 1: Write the failing test for `focus_corp_ids` and the removed attributes**

Replace the body of `test/unit/api/map_discord_notification_test.exs` (keep the
module name and the `setup` block at lines 9-12). The URL-validation tests at lines
14-84 move to the child's test file in Task 1 and are deleted here; the failure
accounting tests at lines 108-155 likewise. What remains, plus new tests:

```elixir
defmodule WandererApp.Api.MapDiscordNotificationTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererAppWeb.Factory

  defp valid_url, do: "https://discord.com/api/webhooks/123456789/abcdefTOKEN"

  setup do
    map = Factory.insert(:map, %{})
    %{map: map}
  end

  test "creates with policy defaults", %{map: map} do
    assert {:ok, rec} =
             MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert rec.enabled? == true
    assert rec.wh_only == true
    assert rec.excluded_systems == []
    assert rec.focus_corp_ids == []
  end

  test "no longer carries webhook_url or failure state", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    refute Map.has_key?(rec, :webhook_url)
    refute Map.has_key?(rec, :consecutive_failures)
    refute Map.has_key?(rec, :last_error)
    refute Map.has_key?(rec, :last_error_at)
    refute Map.has_key?(rec, :last_delivery_at)
  end

  test "focus_corp_ids round-trips", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, rec} = MapDiscordNotification.update(rec, %{focus_corp_ids: [98_000_001, 98_000_002]})
    assert rec.focus_corp_ids == [98_000_001, 98_000_002]

    assert {:ok, reloaded} = MapDiscordNotification.by_map(map.id)
    assert reloaded.focus_corp_ids == [98_000_001, 98_000_002]
  end

  test "create makes the parent and its :system webhook in one transaction", %{map: map} do
    assert {:ok, rec} =
             MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, [hook]} = MapDiscordWebhook.by_notification(rec.id)
    assert hook.role == :system
    assert hook.webhook_url == valid_url()
  end

  test "a rejected webhook url leaves no parent row behind", %{map: map} do
    # The invariant "a system webhook always exists" is transactional, not
    # declarative — the unique identity gives at most one webhook per role, never
    # at least one. If the child create fails the parent must roll back, or the
    # map is left with a policy row and nowhere to deliver.
    assert {:error, _} =
             MapDiscordNotification.create(%{
               map_id: map.id,
               webhook_url: "https://evil.example.com/api/webhooks/1/tok"
             })

    assert {:error, _} = MapDiscordNotification.by_map(map.id)
  end

  test "by_map loads the webhooks relationship", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    {:ok, _} =
      MapDiscordWebhook.create(%{
        notification_id: rec.id,
        role: :character,
        webhook_url: "https://discord.com/api/webhooks/222/othertok"
      })

    assert {:ok, found} = MapDiscordNotification.by_map(map.id)
    refute match?(%Ash.NotLoaded{}, found.webhooks)
    assert Enum.map(found.webhooks, & &1.role) |> Enum.sort() == [:character, :system]
  end

  test "enforces one notification per map", %{map: map} do
    {:ok, _} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:error, _} =
             MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})
  end

  test "deleting the map cascades the notification and its webhooks away", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})
    {:ok, [hook]} = MapDiscordWebhook.by_notification(rec.id)

    Ash.destroy!(map)

    assert {:error, _} = MapDiscordNotification.by_id(rec.id)
    assert {:error, _} = MapDiscordWebhook.by_id(hook.id)
  end

  test "destroy invalidates the cache and stops each webhook's worker", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    # Neither the cache nor the worker registry is running in this test; the
    # custom destroy must tolerate that rather than crash.
    assert :ok = MapDiscordNotification.destroy(rec)
    assert {:error, _} = MapDiscordNotification.by_map(map.id)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/api/map_discord_notification_test.exs`
Expected: FAIL — "creates with policy defaults" fails with
`key :focus_corp_ids not found`, and "no longer carries webhook_url or failure state"
fails because `webhook_url` is still present.

- [ ] **Step 3: Rewrite the parent resource's attributes and relationships**

In `lib/wanderer_app/api/map_discord_notification.ex`:

Delete the `cloak do ... end` block at lines 34-38 (moved to the child in Task 1).

Replace the `attributes do` block (lines 160-184) with:

```elixir
  attributes do
    uuid_primary_key :id

    # The user-facing kill switch for the whole map. This stays on the parent
    # even though each webhook now has its own enabled? flag: the two mean
    # different things — this one is intent, the child's is destination health —
    # and map-level intent cannot be inferred from the children.
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

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
```

Replace the `relationships do` block (lines 186-191) with:

```elixir
  relationships do
    belongs_to :map, WandererApp.Api.Map do
      attribute_writable? true
      allow_nil? false
    end

    has_many :webhooks, WandererApp.Api.MapDiscordWebhook do
      destination_attribute :notification_id
    end
  end
```

Delete `valid_webhook_url?/1`, `valid_webhook_path?/1`, and the
`ValidateWebhookUrl` submodule (lines 212-267) — they now live on the child.

Update the `@moduledoc` (lines 2-8) to:

```elixir
  @moduledoc """
  Per-map Discord kill-notification policy.

  Exactly one row per map. Destinations live in `MapDiscordWebhook` children —
  this row holds only what applies to the map as a whole: the kill switch,
  wormhole-only filtering, excluded systems, and focus corporations.
  """
```

Delete the now-unused `@discord_hosts`, `@max_consecutive_failures`, and
`@max_error_length` module attributes (lines 15-23).

- [ ] **Step 4: Rewrite the parent's actions and code interface**

Replace the `code_interface do` block (lines 40-49) with:

```elixir
  code_interface do
    define(:create, action: :create)
    define(:update, action: :update)
    define(:destroy, action: :destroy)
    define(:by_id, get_by: [:id], action: :read)
    define(:by_map, action: :by_map, args: [:map_id])
  end
```

Replace the `actions do` block (lines 51-158) with:

```elixir
  actions do
    default_accept [:map_id, :enabled?, :wh_only, :excluded_systems, :focus_corp_ids]

    defaults [:read]

    # Custom destroy, following map_webhook_subscription.ex:51-58. The default
    # destroy would leave a stale cache entry AND leave the delivery workers
    # draining their queues into webhooks the user just removed.
    destroy :destroy do
      primary? true
      require_atomic? false

      change after_action(&__MODULE__.after_destroy/3)
    end

    # Creates the policy row and its :system destination in one transaction.
    # The "a system webhook always exists" invariant cannot be declared — the
    # child's unique identity gives at most one webhook per role, not at least
    # one — so it is enforced here: either both rows exist or neither does.
    create :create do
      primary? true
      argument :webhook_url, :string, allow_nil?: false

      change manage_relationship(:webhook_url, :webhooks,
               type: :create,
               value_is_key: :webhook_url,
               transform: fn url -> %{webhook_url: url, role: :system} end
             )

      change after_action(&__MODULE__.invalidate_cache/3)
    end

    update :update do
      primary? true
      require_atomic? false

      change after_action(&__MODULE__.invalidate_cache/3)
    end

    read :by_map do
      argument :map_id, :uuid, allow_nil?: false
      get? true
      filter expr(map_id == ^arg(:map_id))

      # Routing reads the cached value, and the cache stores whatever by_map
      # returned — so the webhooks must be loaded here or routing sees
      # %Ash.NotLoaded{} instead of destinations.
      prepare build(load: [:webhooks])
    end
  end
```

Note on `manage_relationship`: if the `transform:` form does not fit the installed
Ash version, use the equivalent explicit form instead — a `change fn changeset, _ctx`
that calls `Ash.Changeset.manage_relationship(changeset, :webhooks, [%{webhook_url:
Ash.Changeset.get_argument(changeset, :webhook_url), role: :system}], type: :create)`.
Either is acceptable; what matters is that both rows are written in one transaction,
which the test at Step 1 ("a rejected webhook url leaves no parent row behind")
verifies.

- [ ] **Step 5: Update the parent's destroy hook to stop each webhook's worker**

`after_destroy/3` (lines 204-210) currently stops one worker keyed by `map_id`.
Workers are now per-webhook (`WorkerSupervisor.stop_worker(webhook_id)`, arity 1 —
see CONTRACT.md; the supervisor-side change is Task 3). Replace lines 197-210 with:

```elixir
  @doc false
  def invalidate_cache(_changeset, record, _context) do
    WandererApp.ExternalEvents.DiscordDispatcher.invalidate_cache(record.map_id)
    {:ok, record}
  end

  @doc false
  def after_destroy(_changeset, record, _context) do
    WandererApp.ExternalEvents.DiscordDispatcher.invalidate_cache(record.map_id)

    # Stop every destination's delivery worker: without this, anything already
    # queued keeps posting to webhooks the user has just removed. The children
    # are cascade-deleted by the FK, which fires no application hooks, so the
    # parent has to do this for all of them.
    case Ash.load(record, :webhooks) do
      {:ok, %{webhooks: webhooks}} when is_list(webhooks) ->
        Enum.each(webhooks, fn hook ->
          WandererApp.ExternalEvents.Discord.WorkerSupervisor.stop_worker(hook.id)
        end)

      _ ->
        :ok
    end

    {:ok, record}
  end
```

Implementer note: `Ash.load/2` on a just-destroyed record still resolves the
children inside the enclosing transaction, before the FK cascade commits. If it
returns an empty list in practice, load `:webhooks` in the destroy's `before_action`
and stash the ids in the changeset context instead — do not silently drop the
worker-stop.

- [ ] **Step 6: Generate the schema migration**

Run: `mix ash.codegen split_discord_webhooks`

The generated migration will drop `encrypted_webhook_url`, `last_delivery_at`,
`last_error`, `last_error_at`, and `consecutive_failures` from
`map_discord_notifications_v1`, and add `focus_corp_ids {:array, :bigint}` with
default `[]`. **Do not run `mix ash.migrate` yet** — the generated file drops the
data before anything copies it.

- [ ] **Step 7: Hand-edit the generated migration to insert the data-copy step**

Open the file `mix ash.codegen` just wrote in `priv/repo/migrations/`. In `up/0`,
insert this **before** any `remove` calls, and add the matching `execute` to `down/0`.

Codegen never writes data steps; this one is yours.

```elixir
    # Data step: give every existing notification a :system webhook carrying the
    # URL and failure state it used to hold itself.
    #
    # The ciphertext is copied verbatim, no decrypt/re-encrypt round trip.
    # AshCloak.do_encrypt/2 is
    #   value |> :erlang.term_to_binary() |> vault.encrypt!() |> Base.encode64()
    # (deps/ash_cloak/lib/ash_cloak.ex:65-73). The resource is used only to pick
    # a vault; neither the table nor the row identity enters the ciphertext, and
    # the vault's AES-GCM uses fixed AAD. The bytes therefore decrypt correctly
    # from the new table. Do not replace this with an application-level migration.
    #
    # `enabled?` is copied to BOTH rows. The old single flag conflated two
    # meanings — the user switching notifications off, and record_failure
    # auto-disabling after ten consecutive failures — and the migration cannot
    # tell them apart retroactively. Copying it down is the conservative
    # direction: a map that was silent before the upgrade stays silent after it,
    # and no webhook starts posting because a migration guessed generously. The
    # cost is that re-enabling a previously-disabled map also needs the
    # destination re-enabled. Do NOT "simplify" this to enabled? = true.
    execute("""
    INSERT INTO map_discord_webhooks_v1 (
      id, notification_id, role, encrypted_webhook_url, enabled?,
      last_delivery_at, last_error, last_error_at, consecutive_failures,
      inserted_at, updated_at
    )
    SELECT
      gen_random_uuid(), n.id, 'system', n.encrypted_webhook_url, n.enabled?,
      n.last_delivery_at, n.last_error, n.last_error_at, n.consecutive_failures,
      (now() AT TIME ZONE 'utc'), (now() AT TIME ZONE 'utc')
    FROM map_discord_notifications_v1 n
    """)
```

And in `down/0`, before the columns are re-added is too late — the reverse copy
needs the columns back first, so place it **after** the `add` calls that restore
them:

```elixir
    execute("""
    UPDATE map_discord_notifications_v1 n
    SET encrypted_webhook_url = w.encrypted_webhook_url,
        enabled? = w.enabled?,
        last_delivery_at = w.last_delivery_at,
        last_error = w.last_error,
        last_error_at = w.last_error_at,
        consecutive_failures = w.consecutive_failures
    FROM map_discord_webhooks_v1 w
    WHERE w.notification_id = n.id AND w.role = 'system'
    """)
```

Check the generated column type for `role` in Task 1's migration: if codegen wrote
it as a Postgres enum rather than `text`, change `'system'` to `'system'::<enum_name>`
in both statements.

- [ ] **Step 8: Verify the migration ordering by reading the file**

Confirm `up/0` runs in exactly this order:
1. (Task 1's migration, already applied) create `map_discord_webhooks_v1`
2. the `INSERT ... SELECT` above
3. `remove :encrypted_webhook_url`, `remove :last_delivery_at`, `remove :last_error`,
   `remove :last_error_at`, `remove :consecutive_failures`, and
   `add :focus_corp_ids, {:array, :bigint}, null: false, default: []`

If codegen placed the `remove` calls above your `execute`, move the `execute` up.
Getting this backwards silently destroys every configured webhook URL in production.

- [ ] **Step 9: Write the failing migration test**

Create `test/unit/repo/migrations/discord_webhook_split_test.exs`. The migration has
already run against the test database, so this test recreates a pre-split row by
writing the parent through Ash and then asserting the shape the migration produces —
plus a direct check that ciphertext written for one table decrypts from the other,
which is the assumption the SQL copy rests on.

```elixir
defmodule WandererApp.Repo.Migrations.DiscordWebhookSplitTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererAppWeb.Factory

  defp valid_url, do: "https://discord.com/api/webhooks/123456789/abcdefTOKEN"

  test "a pre-split row migrates to exactly one :system child with its state intact" do
    map = Factory.insert(:map, %{})
    {:ok, notification} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    # Reproduce a pre-split row: failure state and enabled? on the parent, with
    # the child not yet existing. Raw SQL, because these columns no longer exist
    # on the resource — this is the only place in the suite that bypasses Ash.
    {:ok, [system_hook]} = MapDiscordWebhook.by_notification(notification.id)
    ciphertext = fetch_ciphertext(system_hook.id)
    :ok = MapDiscordWebhook.destroy(system_hook)

    {:ok, _} =
      WandererApp.Repo.query(
        """
        ALTER TABLE map_discord_notifications_v1
          ADD COLUMN IF NOT EXISTS encrypted_webhook_url bytea,
          ADD COLUMN IF NOT EXISTS last_delivery_at timestamp,
          ADD COLUMN IF NOT EXISTS last_error text,
          ADD COLUMN IF NOT EXISTS last_error_at timestamp,
          ADD COLUMN IF NOT EXISTS consecutive_failures bigint DEFAULT 0
        """,
        []
      )

    {:ok, _} =
      WandererApp.Repo.query(
        """
        UPDATE map_discord_notifications_v1
        SET encrypted_webhook_url = $1,
            enabled? = false,
            last_error = 'boom',
            last_error_at = now() AT TIME ZONE 'utc',
            consecutive_failures = 10
        WHERE id = $2
        """,
        [ciphertext, Ecto.UUID.dump!(notification.id)]
      )

    # The migration's data step, verbatim.
    {:ok, _} =
      WandererApp.Repo.query(
        """
        INSERT INTO map_discord_webhooks_v1 (
          id, notification_id, role, encrypted_webhook_url, enabled?,
          last_delivery_at, last_error, last_error_at, consecutive_failures,
          inserted_at, updated_at
        )
        SELECT
          gen_random_uuid(), n.id, 'system', n.encrypted_webhook_url, n.enabled?,
          n.last_delivery_at, n.last_error, n.last_error_at, n.consecutive_failures,
          (now() AT TIME ZONE 'utc'), (now() AT TIME ZONE 'utc')
        FROM map_discord_notifications_v1 n
        WHERE n.id = $1
        """,
        [Ecto.UUID.dump!(notification.id)]
      )

    assert {:ok, [migrated]} = MapDiscordWebhook.by_notification(notification.id)
    assert migrated.role == :system

    # Ciphertext copied between tables still decrypts — the assumption the SQL
    # data step rests on (AshCloak binds neither table nor row into the cipher).
    assert migrated.webhook_url == valid_url()

    # Failure state moved down verbatim.
    assert migrated.consecutive_failures == 10
    assert migrated.last_error == "boom"
    assert migrated.last_error_at != nil

    # enabled? is copied to BOTH rows: the migration cannot distinguish a
    # user-disable from a failure-auto-disable, and staying silent is the
    # conservative direction.
    assert migrated.enabled? == false
    assert fetch_parent_enabled(notification.id) == false
  end

  defp fetch_ciphertext(webhook_id) do
    {:ok, %{rows: [[ciphertext]]}} =
      WandererApp.Repo.query(
        "SELECT encrypted_webhook_url FROM map_discord_webhooks_v1 WHERE id = $1",
        [Ecto.UUID.dump!(webhook_id)]
      )

    ciphertext
  end

  defp fetch_parent_enabled(notification_id) do
    {:ok, %{rows: [[enabled]]}} =
      WandererApp.Repo.query(
        "SELECT enabled? FROM map_discord_notifications_v1 WHERE id = $1",
        [Ecto.UUID.dump!(notification_id)]
      )

    enabled
  end
end
```

- [ ] **Step 10: Run the migration and both test files**

Run: `mix ash.migrate`
Then: `mix test test/unit/repo/migrations/discord_webhook_split_test.exs test/unit/api/map_discord_notification_test.exs test/unit/api/map_discord_webhook_test.exs`
Expected: all pass. If `migrated.webhook_url` comes back as `nil` or raises, the
ciphertext-portability assumption is wrong for this vault configuration — stop and
report it, because the whole SQL data step depends on it.

- [ ] **Step 11: Verify the migration is reversible**

Run: `mix ecto.rollback -r WandererApp.Repo` then `mix ash.migrate`
Expected: both succeed. Then re-run the three test files from Step 10 to confirm the
round trip left the schema intact.

- [ ] **Step 12: Commit**

`git commit -m "Split Discord destinations out of the notification policy row"`

### Task 3: Rekey the delivery worker from map_id to webhook_id

Today one worker serves a whole map and reads its URL off the notification row
(`worker.ex:81, 232, 255`). Phase A gives a map two destinations, so the key must
become the **webhook id**: each destination gets its own queue, its own attempt
counter, its own deadline, and its own rate-limit backoff.

This is what makes "one webhook 404s, the other keeps delivering" true. With a
shared worker, a 429 on the character channel would sit in the single queue and
stall system kills behind it, and a 404 from either URL would disable the map's
whole feed.

**Preserve every resilience property verbatim.** Read them off `worker.ex` and do
not "simplify" any of them away:

| Property | Constant / mechanism | Line |
|---|---|---|
| Queue cap, drop oldest | `@max_queue 100` | `worker.ex:68, 179-186` |
| Attempts per chunk | `@max_attempts 5` | `worker.ex:69, 225, 314` |
| Per-event deadline | `@event_deadline_ms 60_000` | `worker.ex:69, 222` |
| `retry-after` clamp | `min(10_000)` then `max(50)`, default `1_000` | `worker.ex:70-72, 394-404` |
| Backoff | `1_000 * 2^(attempt-1)`, capped at `8_000` → 1s, 2s, 4s, 8s, 8s | `worker.ex:73-74, 407-409` |
| Inter-chunk spacing | `@inter_chunk_delay_ms 250` | `worker.ex:78, 281` |
| Idle shutdown | `@idle_timeout 60s`, `{:stop, :normal, …}` | `worker.ex:66, 166-168` |
| Never blocks on the socket | `Task.Supervisor.async_nolink` | `worker.ex:259-262` |
| Never sleeps to retry | `Process.send_after(self(), :attempt, …)` | `worker.ex:281, 317` |

The last two are the load-bearing pair: a `Process.sleep` in the retry path would
stop the worker answering casts, so events would pile up in the *mailbox* instead
of being dropped by the 100-item cap, and the cap would become decorative. Same
for a synchronous HTTP call, which can block for the client's 15s receive timeout.

Also unchanged: `WorkerSupervisor`'s `:rest_for_one` strategy
(`worker_supervisor.ex:36`). Workers register in the Registry, so if the Registry
crashed under `:one_for_one` the workers would survive but be unreachable, and the
next `deliver/2` would start a **second** worker for the same webhook and
double-post. `:rest_for_one` takes the workers down with the Registry.

**Files:**
- Modify: `lib/wanderer_app/external_events/discord/worker.ex:32-46, 63, 80-88, 92-108, 111-118, 179-214, 218-265, 267-269, 324-372`
- Modify: `lib/wanderer_app/external_events/discord/worker_supervisor.ex:2-8, 39-67, 69-92, 102-132`
- Modify: `test/support/discord_http_stub.ex:14-39`
- Test: `test/unit/external_events/discord/worker_test.exs` (rewritten)

**Interfaces:**
- Consumes (Task 1): `MapDiscordWebhook.by_id/1`, `.by_notification/1`, `.create/1`,
  `.record_success/1`, `.record_failure/2`, `.disable/2`, `.set_enabled/2`
- Consumes (Task 2): `MapDiscordNotification.create/1` (creates parent + `:system` child),
  `has_many :webhooks`
- Produces: `WorkerSupervisor.deliver(webhook_id, messages)`,
  `WorkerSupervisor.stop_worker(webhook_id)`,
  `Worker.start_link(webhook_id:, registry:)`, `Worker.enqueue(pid, messages)`

---

- [ ] **Step 1: Give `HttpStub` per-URL response queues**

Two webhooks now post concurrently, and the stub's single ordered response queue
(`test/support/discord_http_stub.ex:24, 34-37`) cannot express "429 the character
URL, 204 everything else" — whichever request happens to arrive first consumes the
429. Add per-URL queues, keeping the existing global queue as the fallback so no
existing test changes.

Replace the body of `test/support/discord_http_stub.ex` from `def start do`
(line 14) through the end of `post/2` (line 39) with:

```elixir
  def start do
    case Agent.start_link(fn -> new_state() end, name: @agent) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> reset() && {:ok, pid}
    end
  end

  def reset, do: Agent.update(@agent, fn _ -> new_state() end) == :ok

  defp new_state, do: %{responses: [], by_url: %{}, requests: []}

  @doc "Queues responses for ANY url, consumed in order. Each is {:ok, status, headers} or {:error, term}."
  def set_responses(responses), do: Agent.update(@agent, &%{&1 | responses: responses})

  @doc """
  Queues responses for ONE url, consumed in order and checked before the global
  queue. Needed once a map has two webhooks: with a single global queue the two
  destinations race for the scripted reply, so "404 the character webhook" would
  land on whichever request happened to arrive first.
  """
  def set_responses_for(url, responses),
    do: Agent.update(@agent, &%{&1 | by_url: Map.put(&1.by_url, url, responses)})

  @doc "Returns {url, body} tuples in the order they were sent."
  def requests, do: Agent.get(@agent, & &1.requests) |> Enum.reverse()

  @doc "Returns the {url, body} tuples sent to one url, in order."
  def requests_for(url), do: Enum.filter(requests(), fn {u, _body} -> u == url end)

  @impl true
  def post(url, body) do
    Agent.get_and_update(@agent, fn state ->
      state = %{state | requests: [{url, body} | state.requests]}

      case Map.get(state.by_url, url) do
        [resp | rest] ->
          {resp, %{state | by_url: Map.put(state.by_url, url, rest)}}

        _ ->
          case state.responses do
            [] -> {{:ok, 204, []}, state}
            [resp | rest] -> {resp, %{state | responses: rest}}
          end
      end
    end)
  end
```

- [ ] **Step 2: Run the existing stub test to confirm the fallback still works**

Run: `mix test test/wanderer_app/external_events/discord/http_stub_test.exs`
Expected: PASS — `set_responses/1` and `requests/0` behave exactly as before.

- [ ] **Step 3: Commit the stub change**

```
test: add per-url response scripting to Discord HttpStub
```

- [ ] **Step 4: Rewrite the worker test setup for two webhooks**

Replace `test/unit/external_events/discord/worker_test.exs:1-77` (the header,
`setup`, and helpers) with the block below. The `map`/`notification` setup mirrors
the existing file; `system_webhook/1` and `character_webhook/1` are new, and
`reload/1` now reads a **webhook**, not the notification.

```elixir
defmodule WandererApp.ExternalEvents.Discord.WorkerTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.ExternalEvents.Discord.{HttpStub, Worker, WorkerSupervisor}
  alias WandererAppWeb.Factory

  @system_url "https://discord.com/api/webhooks/123/tok"
  @character_url "https://discord.com/api/webhooks/456/tok-char"

  setup do
    HttpStub.start()
    HttpStub.reset()

    start_supervised!(WorkerSupervisor)

    map = Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{map_id: map.id, webhook_url: @system_url})

    %{map: map, notification: notification, system: system_webhook(notification)}
  end

  # `MapDiscordNotification.create/1` creates the parent and its `:system` child
  # in one transaction (Task 1), so the system webhook always exists here.
  defp system_webhook(notification) do
    {:ok, webhooks} = MapDiscordWebhook.by_notification(notification.id)
    Enum.find(webhooks, &(&1.role == :system))
  end

  defp character_webhook(notification, url \\ @character_url) do
    {:ok, webhook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: url
      })

    webhook
  end

  defp message, do: %{"embeds" => [%{"title" => "test"}]}

  defp wait_for_requests(count, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(count, deadline)
  end

  defp do_wait(count, deadline) do
    if length(HttpStub.requests()) >= count do
      HttpStub.requests()
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("expected #{count} requests, got #{length(HttpStub.requests())}")
      else
        Process.sleep(25)
        do_wait(count, deadline)
      end
    end
  end

  # Blocks until the worker has drained its mailbox up to this point. Cheaper
  # and far less flaky than sleeping, now that every attempt is scheduled.
  # Keyed by WEBHOOK id, not map id — that is the Registry key now.
  defp sync(webhook_id) do
    case Registry.lookup(WorkerSupervisor.registry(), webhook_id) do
      [{pid, _}] -> :sys.get_state(pid)
      [] -> :no_worker
    end
  end

  defp await_condition(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_condition(fun, deadline)
  end

  defp do_await_condition(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met before deadline")
        else
          Process.sleep(25)
          do_await_condition(fun, deadline)
        end
    end
  end

  defp reload(webhook_id) do
    {:ok, rec} = MapDiscordWebhook.by_id(webhook_id)
    rec
  end
```

- [ ] **Step 5: Rewrite the existing worker tests for the new arities**

Replace `test/unit/external_events/discord/worker_test.exs:79-371` (every test in
the file) with the block below. Same coverage as today — the constants and
semantics are unchanged — rekeyed to webhook ids and asserting failure state on
the webhook row.

```elixir
  test "delivers a message to the configured url", %{system: w} do
    WorkerSupervisor.deliver(w.id, [message()])

    assert [{url, body}] = wait_for_requests(1)
    assert url == @system_url
    assert %{"embeds" => _} = body
  end

  test "records success on the webhook", %{system: w} do
    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    reloaded =
      await_condition(fn ->
        rec = reload(w.id)
        if rec.last_delivery_at, do: {:ok, rec}, else: :retry
      end)

    assert reloaded.consecutive_failures == 0
  end

  test "reloads the webhook, so a replaced url is not used", %{system: w} do
    # Change the URL after capturing the (now stale) struct the caller holds.
    {:ok, _} =
      MapDiscordWebhook.update(w, %{webhook_url: "https://discord.com/api/webhooks/999/newtok"})

    WorkerSupervisor.deliver(w.id, [message()])

    assert [{url, _body}] = wait_for_requests(1)
    assert url == "https://discord.com/api/webhooks/999/newtok"
  end

  test "drops the event when the webhook was deleted while queued", %{system: w} do
    id = w.id
    :ok = MapDiscordWebhook.destroy(w)

    WorkerSupervisor.deliver(id, [message()])
    # Two syncs, not a sleep: the first flushes the deliver cast, the second the
    # `:attempt` message that cast sends to itself. After both, the worker has
    # decided whether to post.
    sync(id)
    sync(id)

    assert HttpStub.requests() == []
  end

  test "drops the event when the webhook was disabled while queued", %{system: w} do
    {:ok, _} = MapDiscordWebhook.set_enabled(w, %{enabled?: false})

    WorkerSupervisor.deliver(w.id, [message()])
    sync(w.id)
    sync(w.id)

    assert HttpStub.requests() == []
  end

  test "sends multi-chunk events in order", %{system: w} do
    msgs = [
      %{"embeds" => [%{"title" => "one"}]},
      %{"embeds" => [%{"title" => "two"}]},
      %{"embeds" => [%{"title" => "three"}]}
    ]

    WorkerSupervisor.deliver(w.id, msgs)
    requests = wait_for_requests(3)

    titles =
      Enum.map(requests, fn {_url, body} ->
        body["embeds"] |> hd() |> Map.get("title")
      end)

    assert titles == ["one", "two", "three"]
  end

  test "retries after a 429 honoring retry_after", %{system: w} do
    HttpStub.set_responses([
      {:ok, 429, [{"retry-after", "0.05"}]},
      {:ok, 204, []}
    ])

    WorkerSupervisor.deliver(w.id, [message()])

    assert length(wait_for_requests(2)) == 2
  end

  test "does not block its mailbox while waiting to retry", %{system: w} do
    # A long retry-after must not stop the worker answering new casts: if the
    # send path slept, this :sys.get_state would time out.
    HttpStub.set_responses([{:ok, 429, [{"retry-after", "2"}]}, {:ok, 204, []}])

    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    assert %{} = sync(w.id)
  end

  test "drops the oldest event when the queue is full", %{system: w} do
    # Hold the worker on a long retry so nothing drains while we overfill.
    HttpStub.set_responses([{:ok, 429, [{"retry-after", "5"}]}])

    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    for i <- 1..120 do
      WorkerSupervisor.deliver(w.id, [%{"embeds" => [%{"title" => "q#{i}"}]}])
    end

    state = sync(w.id)

    assert state.queue_len == 100
    # Oldest were dropped, so the newest enqueued event survived.
    assert state.queue |> :queue.to_list() |> List.last() ==
             [%{"embeds" => [%{"title" => "q120"}]}]
  end

  test "does not retry a 403, but counts it as a failure", %{system: w} do
    HttpStub.set_responses([{:ok, 403, []}])

    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    reloaded =
      await_condition(fn ->
        rec = reload(w.id)
        if rec.consecutive_failures == 1, do: {:ok, rec}, else: :retry
      end)

    # One request only — 403 is permanent, no retry.
    assert length(HttpStub.requests()) == 1
    # But it does NOT disable on its own; the 10-failure threshold governs.
    assert reloaded.enabled? == true
    assert reloaded.last_error =~ "403"
  end

  test "a 401 increments failures without disabling", %{system: w} do
    HttpStub.set_responses([{:ok, 401, []}])

    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    reloaded =
      await_condition(fn ->
        rec = reload(w.id)
        if rec.consecutive_failures == 1, do: {:ok, rec}, else: :retry
      end)

    assert reloaded.enabled? == true
  end

  test "disables the webhook on 404", %{system: w} do
    HttpStub.set_responses([{:ok, 404, []}])

    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    reloaded =
      await_condition(fn ->
        rec = reload(w.id)
        if rec.enabled? == false, do: {:ok, rec}, else: :retry
      end)

    assert reloaded.last_error =~ "404"
  end

  test "disables after 10 consecutive failed events", %{system: w} do
    HttpStub.set_responses(for _ <- 1..10, do: {:ok, 403, []})

    for _ <- 1..10 do
      WorkerSupervisor.deliver(w.id, [message()])
    end

    reloaded =
      await_condition(
        fn ->
          rec = reload(w.id)
          if rec.consecutive_failures >= 10, do: {:ok, rec}, else: :retry
        end,
        5_000
      )

    assert reloaded.enabled? == false
  end

  test "a later failing chunk is not masked by an earlier success", %{system: w} do
    HttpStub.set_responses([
      {:ok, 204, []},
      {:ok, 500, []},
      {:ok, 500, []},
      {:ok, 500, []},
      {:ok, 500, []},
      {:ok, 500, []}
    ])

    WorkerSupervisor.deliver(w.id, [message(), message()])

    reloaded =
      await_condition(
        fn ->
          rec = reload(w.id)
          if rec.consecutive_failures == 1, do: {:ok, rec}, else: :retry
        end,
        20_000
      )

    assert reloaded.last_error != nil
    # Per-event semantics: the successful first chunk must not stamp a delivery.
    assert reloaded.last_delivery_at == nil
  end

  test "stop_worker terminates a running worker", %{system: w} do
    WorkerSupervisor.deliver(w.id, [message()])
    wait_for_requests(1)

    assert [{pid, _}] = Registry.lookup(WorkerSupervisor.registry(), w.id)
    ref = Process.monitor(pid)

    assert :ok = WorkerSupervisor.stop_worker(w.id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

    # Registry cleans up its entry asynchronously when the owner dies, so the
    # :DOWN can arrive before the key is released. Poll rather than sleep.
    await_condition(fn ->
      case Registry.lookup(WorkerSupervisor.registry(), w.id) do
        [] -> {:ok, []}
        _ -> :retry
      end
    end)
  end

  test "stop_worker is a no-op when no worker is running", %{system: w} do
    assert :ok = WorkerSupervisor.stop_worker(w.id)
  end

  test "deliver returns an error instead of raising when the supervisor is down", %{system: w} do
    # The kill-switch case: application.ex only starts WorkerSupervisor when
    # webhooks are enabled, so the registry may not exist at all. deliver/2 and
    # stop_worker/1 must be equally tolerant — a dispatcher call must not crash
    # just because the feature is off.
    stop_supervised!(WorkerSupervisor)
    refute Process.whereis(WorkerSupervisor.registry())

    assert {:error, :not_running} = WorkerSupervisor.deliver(w.id, [message()])
    assert :ok = WorkerSupervisor.stop_worker(w.id)
    assert HttpStub.requests() == []
  end

  test "shuts down when idle", %{system: w} do
    # Tiny idle timeout so this exercises the real shutdown path in ms.
    pid =
      start_supervised!(
        {Worker, webhook_id: w.id, registry: WorkerSupervisor.registry(), idle_timeout: 50},
        restart: :temporary
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "gives up on an event whose deadline has passed, without sending", %{system: w} do
    # A negative deadline is already expired when the first attempt runs, so
    # the event is abandoned before any request goes out.
    pid =
      start_supervised!(
        {Worker, webhook_id: w.id, registry: WorkerSupervisor.registry(), event_deadline_ms: -1},
        restart: :temporary
      )

    Worker.enqueue(pid, [message()])

    reloaded =
      await_condition(fn ->
        rec = reload(w.id)
        if rec.consecutive_failures == 1, do: {:ok, rec}, else: :retry
      end)

    assert HttpStub.requests() == []
    assert reloaded.last_error =~ "deadline"
    assert reloaded.last_delivery_at == nil
  end
end
```

- [ ] **Step 6: Add the four isolation tests that justify the rekey**

Append these before the closing `end` of the module. These are the tests that a
`map_id`-keyed worker cannot pass — they are the point of the whole task.

```elixir
  test "two webhooks on the same map deliver independently", %{
    notification: n,
    system: sys
  } do
    char = character_webhook(n)

    WorkerSupervisor.deliver(sys.id, [message()])
    WorkerSupervisor.deliver(char.id, [message()])

    wait_for_requests(2)

    assert length(HttpStub.requests_for(@system_url)) == 1
    assert length(HttpStub.requests_for(@character_url)) == 1

    # Two distinct workers, not one shared queue.
    assert [{sys_pid, _}] = Registry.lookup(WorkerSupervisor.registry(), sys.id)
    assert [{char_pid, _}] = Registry.lookup(WorkerSupervisor.registry(), char.id)
    assert sys_pid != char_pid
  end

  test "a 404 on one webhook disables only that webhook", %{notification: n, system: sys} do
    char = character_webhook(n)
    HttpStub.set_responses_for(@character_url, [{:ok, 404, []}])

    WorkerSupervisor.deliver(char.id, [message()])
    WorkerSupervisor.deliver(sys.id, [message()])

    wait_for_requests(2)

    disabled =
      await_condition(fn ->
        rec = reload(char.id)
        if rec.enabled? == false, do: {:ok, rec}, else: :retry
      end)

    assert disabled.last_error =~ "404"

    # The system webhook is untouched: this is the failure the split exists for.
    survivor =
      await_condition(fn ->
        rec = reload(sys.id)
        if rec.last_delivery_at, do: {:ok, rec}, else: :retry
      end)

    assert survivor.enabled? == true
    assert survivor.consecutive_failures == 0
  end

  test "a 429 on one webhook does not delay the other", %{notification: n, system: sys} do
    char = character_webhook(n)
    # 2s is far longer than the 500ms budget asserted below, and is clamped to
    # @max_retry_after_ms (10s) so it stays a real wait.
    HttpStub.set_responses_for(@character_url, [{:ok, 429, [{"retry-after", "2"}]}])

    WorkerSupervisor.deliver(char.id, [message()])
    # Let the rate-limited worker take its 429 before the system kill is queued,
    # so a shared queue would genuinely be blocked behind it.
    await_condition(fn ->
      if HttpStub.requests_for(@character_url) != [], do: {:ok, :sent}, else: :retry
    end)

    started = System.monotonic_time(:millisecond)
    WorkerSupervisor.deliver(sys.id, [message()])

    await_condition(fn ->
      if HttpStub.requests_for(@system_url) != [], do: {:ok, :sent}, else: :retry
    end)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 500, "system kill waited #{elapsed}ms behind the rate-limited webhook"

    # And the character webhook is still mid-retry, not failed.
    assert length(HttpStub.requests_for(@character_url)) == 1
  end

  test "stop_worker targets a single webhook", %{notification: n, system: sys} do
    char = character_webhook(n)

    WorkerSupervisor.deliver(sys.id, [message()])
    WorkerSupervisor.deliver(char.id, [message()])
    wait_for_requests(2)

    assert [{char_pid, _}] = Registry.lookup(WorkerSupervisor.registry(), char.id)
    ref = Process.monitor(char_pid)

    assert :ok = WorkerSupervisor.stop_worker(char.id)
    assert_receive {:DOWN, ^ref, :process, ^char_pid, _}, 1_000

    # The system worker is still registered and alive.
    assert [{sys_pid, _}] = Registry.lookup(WorkerSupervisor.registry(), sys.id)
    assert Process.alive?(sys_pid)
  end
```

- [ ] **Step 7: Run the worker tests to verify they fail**

Run: `mix test test/unit/external_events/discord/worker_test.exs`
Expected: FAIL — compile error / `UndefinedFunctionError` for
`WorkerSupervisor.deliver/2` and `Worker.enqueue/2` (only `/3` exist), and
`KeyError` for `:webhook_id` in `Worker.start_link/1`.

- [ ] **Step 8: Rekey the worker's identity and queue**

In `lib/wanderer_app/external_events/discord/worker.ex`, replace the alias at
line 63:

```elixir
  alias WandererApp.Api.MapDiscordWebhook
```

Replace `start_link/1` and `enqueue/3` (lines 80-88):

```elixir
  def start_link(opts) do
    webhook_id = Keyword.fetch!(opts, :webhook_id)
    registry = Keyword.fetch!(opts, :registry)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {registry, webhook_id}})
  end

  @doc """
  Queues one event's messages for delivery.

  No id argument: the worker IS the webhook now, so the queue holds messages
  alone and the id comes from state.
  """
  def enqueue(pid, messages) do
    GenServer.cast(pid, {:enqueue, messages})
  end
```

Replace the `init/1` state map key at line 100:

```elixir
       webhook_id: Keyword.fetch!(opts, :webhook_id),
```

Replace `handle_cast/2` (lines 110-118):

```elixir
  @impl true
  def handle_cast({:enqueue, messages}, state) do
    state =
      state
      |> push(messages)
      |> maybe_start_next()

    {:noreply, state, state.idle_timeout}
  end
```

Replace the `push/2` log line at line 184:

```elixir
    Logger.warning(
      "[Discord.Worker] queue full for webhook #{state.webhook_id}, dropping oldest event"
    )
```

Replace `maybe_start_next/1`'s queue-out clause (lines 199-213):

```elixir
      {{:value, messages}, rest} ->
        current = %{
          pending: messages,
          attempt: 1,
          task_ref: nil,
          # Most recently loaded record, reused for the status write so
          # finishing an event does not re-query what we just read.
          webhook: nil,
          deadline: System.monotonic_time(:millisecond) + state.event_deadline_ms
        }

        send(self(), :attempt)
        %{state | queue: rest, queue_len: state.queue_len - 1, current: current}
```

- [ ] **Step 9: Point the reload and the status writes at the webhook row**

Still in `worker.ex`, replace `attempt/1`'s reload branch (lines 228-246):

```elixir
      true ->
        # Reload every time: the URL may have been replaced or the webhook
        # deleted since this event was queued. This reload is the one that
        # matters — nothing is sent against a stale record.
        case MapDiscordWebhook.by_id(state.webhook_id) do
          {:ok, webhook} ->
            state = put_current(state, %{current | webhook: webhook})

            if webhook.enabled? do
              do_post(state, webhook)
            else
              # Disabled while queued — drop the event silently, no status write.
              drop_current(state)
            end

          _ ->
            Logger.debug("[Discord.Worker] webhook gone, dropping queued event")
            drop_current(state)
        end
```

Replace `do_post/2`'s head and URL read (lines 254-256):

```elixir
  defp do_post(%{current: current} = state, webhook) do
    [message | _rest] = current.pending
    url = webhook.webhook_url
```

Replace the completion block (lines 336-372):

```elixir
  defp finish(%{current: current} = state, outcome) do
    case current.webhook do
      nil -> record_outcome(state.webhook_id, outcome)
      webhook -> apply_outcome(webhook, outcome)
    end

    drop_current(state)
  end

  defp record_outcome(webhook_id, outcome) do
    case MapDiscordWebhook.by_id(webhook_id) do
      {:ok, webhook} -> apply_outcome(webhook, outcome)
      _ -> :ok
    end
  end

  defp apply_outcome(webhook, :ok) do
    case MapDiscordWebhook.record_success(webhook) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[Discord] record_success failed: #{inspect(reason)}")
    end
  end

  defp apply_outcome(webhook, {:error, reason, :disable}) do
    case MapDiscordWebhook.disable(webhook, to_string(reason)) do
      {:ok, _} -> :ok
      {:error, err} -> Logger.warning("[Discord] disable failed: #{inspect(err)}")
    end
  end

  defp apply_outcome(webhook, {:error, reason, :count}) do
    # record_failure disables at @max_consecutive_failures on the resource side.
    case MapDiscordWebhook.record_failure(webhook, to_string(reason)) do
      {:ok, _} -> :ok
      {:error, err} -> Logger.warning("[Discord] record_failure failed: #{inspect(err)}")
    end
  end
```

- [ ] **Step 10: Update the worker moduledoc to describe per-webhook serialization**

Replace `worker.ex:3-7` and the "Ids, not records" section at lines 32-46:

```elixir
  Serializes Discord delivery for one webhook.

  Discord rate-limits a webhook to roughly 5 requests/second and answers 429
  with a `retry-after`. Everything for a webhook funnels through this process so
  concurrent kill batches cannot interleave and burst.

  A map has up to two destinations (system and character), and they get separate
  workers on purpose: a 429 or a dead URL on one channel must not stall or
  disable the other.
```

```elixir
  ## Ids, not records

  The queue holds messages only; the webhook id lives in state. The webhook row
  is reloaded from the database immediately before every send, so a URL the user
  has replaced or deleted is never used, and a stale `consecutive_failures`
  snapshot cannot corrupt the counter.

  If the reload finds the webhook deleted, or finds `enabled?` false, the queued
  event is dropped silently: no request, and no status write. There is nothing
  meaningful to record against a row the user removed, and writing a failure
  onto a row they deliberately disabled would be misleading.
```

- [ ] **Step 11: Rekey the supervisor**

In `lib/wanderer_app/external_events/discord/worker_supervisor.ex`, replace the
moduledoc (lines 2-8):

```elixir
  @moduledoc """
  Starts one delivery worker per Discord webhook on demand, addressed through a
  Registry keyed by webhook id.

  Per webhook, not per map: Discord's rate limits are per webhook, and a failure
  must be attributable to the destination that caused it. Sharing a worker
  between a map's system and character channels would let a 429 on one stall the
  other, and a 404 on one disable both.

  Workers are transient: they own an in-memory queue, shut down when idle, and
  are not restarted with their queue intact. Losing a queued notification on
  crash is acceptable; duplicating a delivered one is not.
  """
```

Replace the `:rest_for_one` comment at lines 31-35 so it names the right key:

```elixir
    # :rest_for_one, not :one_for_one — workers register in the Registry, so a
    # Registry crash would leave them running but unreachable, and the next
    # deliver/2 would start a *second* worker for the same webhook and
    # double-post. Restarting everything after the Registry clears those orphans.
```

Replace `deliver/3` (lines 39-67) with `deliver/2`:

```elixir
  @doc """
  Enqueues messages for one webhook, starting its worker if it is not running.

  Takes the webhook *id*, never the record: the worker reloads it just before
  each send so a replaced or deleted webhook is not used, and so a stale
  `consecutive_failures` snapshot cannot corrupt the counter.

  Returns `{:error, :not_running}` when the worker infrastructure is not
  started (e.g. webhooks globally disabled), mirroring `stop_worker/1`'s
  tolerance of the same condition. Callers on the dispatch path must not crash
  just because the kill-switch is off.
  """
  def deliver(_webhook_id, []), do: :ok

  def deliver(webhook_id, messages) do
    case ensure_worker(webhook_id) do
      {:ok, pid} ->
        Worker.enqueue(pid, messages)

      {:error, :not_running} ->
        # Not an error worth logging on every event: the kill-switch being off
        # is a normal configuration, not a failure.
        {:error, :not_running}

      {:error, reason} ->
        Logger.warning("[Discord] could not start worker for webhook #{webhook_id}: #{inspect(reason)}")

        {:error, reason}
    end
  end
```

Replace `stop_worker/1` and the private helpers (lines 69-132), renaming the
parameter throughout:

```elixir
  @doc """
  Stops one webhook's delivery worker if one is running, discarding its queue.

  Called from the webhook resource's destroy, and from the parent notification's
  destroy for each of its children: without it, a removed webhook keeps
  receiving whatever was already queued. A no-op when the worker infrastructure
  is not running at all (e.g. webhooks globally disabled, or in tests that do
  not start this supervisor).
  """
  def stop_worker(webhook_id) do
    case Process.whereis(@registry) do
      nil ->
        :ok

      _ ->
        case Registry.lookup(@registry, webhook_id) do
          # The worker may have idled out or crashed between the lookup and the
          # stop; either way the post-condition (no worker running) holds.
          [{pid, _}] -> try_stop(pid)
          [] -> :ok
        end

        :ok
    end
  end

  defp try_stop(pid) do
    GenServer.stop(pid, :normal, @stop_timeout_ms)
  catch
    # Already gone, or did not terminate within the timeout — in the latter case
    # GenServer.stop/3 has already killed it. Either way there is no worker left.
    :exit, _ -> :ok
  end

  defp ensure_worker(webhook_id) do
    # Guard exactly as stop_worker/1 does: Registry.lookup on an unregistered
    # name raises ArgumentError, which would crash the dispatcher whenever
    # webhooks are globally disabled and this supervisor was never started.
    case Process.whereis(@registry) do
      nil -> {:error, :not_running}
      _ -> lookup_or_start(webhook_id)
    end
  end

  defp lookup_or_start(webhook_id) do
    case Registry.lookup(@registry, webhook_id) do
      # Registry releases a dead owner's key asynchronously, so a lookup can
      # still return a pid that has just exited (idle shutdown or stop_worker).
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: start_worker(webhook_id)

      [] ->
        start_worker(webhook_id)
    end
  end

  defp start_worker(webhook_id) do
    spec = {Worker, webhook_id: webhook_id, registry: @registry}

    case DynamicSupervisor.start_child(@dyn_sup, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def registry, do: @registry
end
```

- [ ] **Step 12: Run the worker tests to verify they pass**

Run: `mix test test/unit/external_events/discord/worker_test.exs`
Expected: PASS, all tests including the four isolation tests.

Note: the dispatcher still calls `deliver/3` at this point and will not compile
its call site — that is Task 4. Run `mix compile --warnings-as-errors` only after
Task 4.

- [ ] **Step 13: Commit**

```
feat(discord): key the delivery worker by webhook id

One worker per destination, so each webhook gets its own queue, retry
budget and rate-limit backoff. A 404 on the character channel no longer
disables system kills, and a 429 on one no longer stalls the other.
```

---

### Task 4: Adapt the dispatcher to webhook ids, still single-destination

**This task is the seam, and its only job is to keep the suite green at the end of
Phase A.** The dispatcher resolves the map's `:system` webhook and delivers to it
by webhook id. That is all.

**Explicitly NOT in this task:**
- No involvement matching (Phase B / Task 7).
- No routing between system and character webhooks (Task 8).
- No second destination — a character webhook may exist in the database after
  Task 3's tests, but the dispatcher must ignore it entirely.
- No rework of `map_notifications_component.ex` beyond the one-line call-site fix
  below. The full component rework is Task 14.

Observable behaviour after this task must be **identical to today** for every
existing test: same kills delivered, same kills skipped, same single request per
event, same dedup. An implementer who starts wiring character-webhook routing here
produces a phase that cannot be reviewed, because a reviewer can no longer tell a
regression from an intended change.

**The dedup key stays `"#{map_id}:#{killmail_id}"` and is NOT role-scoped**
(`discord_dispatcher.ex:291`). This is deliberate and survives into Phase C: a kill
that involves your pilot *and* happened in a tracked system posts **once**, to one
channel — not once per destination. Routing (Task 8) is what collapses the two
candidate destinations into a single choice; the dedup key is what guarantees the
choice is only acted on once. Making the key role-scoped would silently double-post
exactly the kills users care about most.

**Files:**
- Modify: `lib/wanderer_app/external_events/discord_dispatcher.ex:46-47, 71-119, 148-180, 237-249`
- Modify: `lib/wanderer_app_web/live/maps/components/map_notifications_component.ex:114-115`
- Test: `test/unit/external_events/discord_dispatcher_test.exs`

**Interfaces:**
- Consumes: `WorkerSupervisor.deliver(webhook_id, messages)` (Task 3),
  `MapDiscordWebhook.by_id/1`, `.by_notification/1`, `.set_enabled/2` (Task 1),
  `MapDiscordNotification.by_map/1` with `has_many :webhooks` (Task 2)
- Produces: `DiscordDispatcher.send_test_message(webhook_id)`; a cached
  notification struct with `:webhooks` loaded, which Task 8's `Router.route/3`
  consumes unchanged

---

- [ ] **Step 1: Update the dispatcher test setup to resolve the system webhook**

Replace `test/unit/external_events/discord_dispatcher_test.exs:1-52` with the
block below. The setup is the existing one verbatim — `seed_static_info/0`, the
app-env override of `webhooks_enabled` restored in `on_exit`, `HttpStub.start()` /
`reset()`, `start_supervised!(WorkerSupervisor)`, `start_supervised!(DiscordDispatcher)`
— plus the system webhook in the returned context.

```elixir
defmodule WandererApp.ExternalEvents.DiscordDispatcherTest do
  # `async: false` is mandatory: `HttpStub` keeps its state in a single named
  # Agent, and this file also mutates application env.
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.ExternalEvents.{DiscordDispatcher, Event}
  alias WandererApp.ExternalEvents.Discord.{EmbedFormatter, HttpStub, WorkerSupervisor}
  alias WandererAppWeb.Factory

  # A real wormhole system id (J-space) and a real known-space id (Jita).
  @wh_system 31_000_005
  @ks_system 30_000_142

  @system_url "https://discord.com/api/webhooks/123/tok"

  setup do
    # `wh_only` filtering resolves the system class through
    # `CachedInfo.get_system_static_info/1`, which falls back to the
    # `map_solar_systems` table. That table is static import data and is NOT
    # populated by `mix test` on a clean database, so seed the cache directly —
    # the same approach `WandererApp.MapTestHelpers` uses.
    seed_static_info()

    # `config/test.exs:35` sets `external_events: [webhooks_enabled: false]`, and
    # the dispatcher checks `Env.webhooks_enabled?/0` at call time. Without this
    # override EVERY delivery assertion below would pass while sending nothing.
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, :webhooks_enabled, true)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)

    HttpStub.start()
    HttpStub.reset()
    start_supervised!(WorkerSupervisor)
    start_supervised!(DiscordDispatcher)

    map = Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{map_id: map.id, webhook_url: @system_url})

    DiscordDispatcher.invalidate_cache(map.id)

    %{map: map, notification: notification, system: system_webhook(notification)}
  end

  defp system_webhook(notification) do
    {:ok, webhooks} = MapDiscordWebhook.by_notification(notification.id)
    Enum.find(webhooks, &(&1.role == :system))
  end
```

- [ ] **Step 2: Rekey the test's worker-synchronization helpers to webhook ids**

The Registry key changed in Task 3, so `settle/1`, `refute_delivery/1` and
`await_worker_idle/2` must look up by webhook id. Replace
`discord_dispatcher_test.exs:98-140` with:

```elixir
  # Dispatch is a cast and delivery is a second async hop, so tests synchronize
  # rather than guess: drain the dispatcher's mailbox, then the worker's.
  # Keyed by WEBHOOK id — that is the Registry key since Task 3.
  defp settle(webhook_id) do
    :sys.get_state(DiscordDispatcher)

    case Registry.lookup(WorkerSupervisor.registry(), webhook_id) do
      [{pid, _}] -> :sys.get_state(pid)
      [] -> :no_worker
    end
  end

  # Asserting "nothing was delivered" needs more than `settle/1`: the HTTP call
  # itself runs in a `Task.Supervisor.async_nolink` task, so a request can still
  # be in flight when the worker's mailbox is drained. Wait until the worker is
  # genuinely idle (no queued event, none in progress) before asserting, or the
  # assertion passes for the wrong reason. Mutating the seeded system class
  # confirms this: without the wait, marking Jita as wormhole space still leaves
  # "skips non-wormhole systems" green.
  #
  # `webhook_id` may be nil (a map with no configuration at all), in which case
  # there is no worker to wait on and the HTTP assertion is the whole check.
  defp refute_delivery(webhook_id, timeout \\ 2_000) do
    if webhook_id do
      settle(webhook_id)
      await_worker_idle(webhook_id, System.monotonic_time(:millisecond) + timeout)
    else
      :sys.get_state(DiscordDispatcher)
    end

    assert HttpStub.requests() == []
  end

  defp await_worker_idle(webhook_id, deadline) do
    case Registry.lookup(WorkerSupervisor.registry(), webhook_id) do
      [] ->
        :no_worker

      [{pid, _}] ->
        state = :sys.get_state(pid)

        cond do
          state.current == nil and state.queue_len == 0 ->
            :idle

          System.monotonic_time(:millisecond) >= deadline ->
            :timeout

          true ->
            Process.sleep(25)
            await_worker_idle(webhook_id, deadline)
        end
    end
  end
```

- [ ] **Step 3: Rekey the existing dispatcher tests**

Replace `discord_dispatcher_test.exs:161-338` (from `test "sends nothing when the
global webhook gate is off"` through the end of the per-map dedup test) with:

```elixir
  test "sends nothing when the global webhook gate is off", %{map: map, system: w} do
    # Covers the gate itself rather than assuming it. This is the failure mode
    # that would otherwise make every test in this file green but meaningless.
    disable_gate()

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  test "delivers a wormhole kill", %{map: map, system: w} do
    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)
    settle(w.id)

    assert [{url, _body}] = wait_for_requests(1)
    assert url == @system_url
  end

  test "ignores kill_count events", %{map: map, system: w} do
    event = kill_event(Factory.build(:kill_count_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  test "skips non-wormhole systems when wh_only is set", %{map: map, system: w} do
    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @ks_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  test "delivers known-space kills when wh_only is off", %{map: map, notification: n, system: w} do
    {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
    DiscordDispatcher.invalidate_cache(map.id)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @ks_system}))

    DiscordDispatcher.dispatch_event(map.id, event)
    settle(w.id)

    assert length(wait_for_requests(1)) == 1
  end

  test "skips excluded systems", %{map: map, notification: n, system: w} do
    {:ok, _} = MapDiscordNotification.update(n, %{excluded_systems: [@wh_system]})
    DiscordDispatcher.invalidate_cache(map.id)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  test "skips when the notification is disabled", %{map: map, notification: n, system: w} do
    {:ok, _} = MapDiscordNotification.update(n, %{enabled?: false})
    DiscordDispatcher.invalidate_cache(map.id)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  # New in Task 4: enablement now lives on BOTH rows. The notification gates the
  # whole map's policy; the webhook gates one destination. A webhook disabled by
  # ten consecutive failures must drop here, before the dedup mark is burned —
  # the worker would drop it too, but only after the kill was marked attempted.
  test "skips when the system webhook is disabled", %{map: map, system: w} do
    {:ok, _} = MapDiscordWebhook.set_enabled(w, %{enabled?: false})
    DiscordDispatcher.invalidate_cache(map.id)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  test "no-ops for a map with no configuration" do
    other_map = Factory.insert(:map, %{})
    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(other_map.id, event)

    refute_delivery(nil)
  end

  # A notification whose webhooks were all destroyed is a no-op, not a crash:
  # `do_dispatch/2` must fall through its `with` rather than raise on an empty
  # webhook list.
  test "no-ops for a notification with no webhooks", %{map: map, system: w} do
    :ok = MapDiscordWebhook.destroy(w)
    DiscordDispatcher.invalidate_cache(map.id)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(nil)
    assert Process.alive?(Process.whereis(DiscordDispatcher))
  end

  test "deduplicates a replayed killmail", %{map: map, system: w} do
    kill = Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 777_777})
    payload = Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [kill]})

    DiscordDispatcher.dispatch_event(map.id, kill_event(payload))
    settle(w.id)
    wait_for_requests(1)

    DiscordDispatcher.dispatch_event(map.id, kill_event(payload))
    settle(w.id)

    assert length(HttpStub.requests()) == 1
  end

  test "delivers only the new kills in a partially-replayed batch", %{map: map, system: w} do
    old = Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 111})
    new = Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 222})

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [old]}))
    )

    settle(w.id)
    wait_for_requests(1)

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(
        Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [old, new]})
      )
    )

    settle(w.id)

    assert [{_, _}, {_, second_body}] = wait_for_requests(2)
    assert length(second_body["embeds"]) == 1
  end

  test "ignores non-kill event types", %{map: map, system: w} do
    event = %Event{map_id: map.id, type: :add_system, payload: %{}}

    DiscordDispatcher.dispatch_event(map.id, event)

    refute_delivery(w.id)
  end

  # Guards the carry-forward constraint: WorkerSupervisor.deliver/2 answers
  # {:error, :not_running} when the worker tree is down. The dispatcher must
  # neither crash nor treat that as delivered, and — since nothing was enqueued
  # — must release the dedup marks so the kill can still be sent later.
  test "survives the worker tree being down and does not burn the dedup mark", %{
    map: map,
    system: w
  } do
    kill = Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 999_111})
    payload = Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [kill]})

    :ok = stop_supervised(WorkerSupervisor)

    DiscordDispatcher.dispatch_event(map.id, kill_event(payload))
    :sys.get_state(DiscordDispatcher)

    assert HttpStub.requests() == []
    assert Process.alive?(Process.whereis(DiscordDispatcher))

    start_supervised!(WorkerSupervisor)

    DiscordDispatcher.dispatch_event(map.id, kill_event(payload))
    settle(w.id)

    assert length(wait_for_requests(1)) == 1
  end

  # Pins the dedup key as PER-MAP. Deleting `map_id` from `dedup_key/2` makes
  # every other test still pass, while the second map would silently stop
  # receiving any kill the first one already reported.
  test "dedup is per-map: two maps both receive the same killmail", %{
    map: map_a,
    system: w_a
  } do
    map_b = Factory.insert(:map, %{})
    url_b = "https://discord.com/api/webhooks/456/tok-b"

    {:ok, notification_b} =
      MapDiscordNotification.create(%{map_id: map_b.id, webhook_url: url_b})

    w_b = system_webhook(notification_b)
    DiscordDispatcher.invalidate_cache(map_b.id)

    kill = Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 555_555})
    payload = Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [kill]})

    DiscordDispatcher.dispatch_event(map_a.id, kill_event(payload))
    settle(w_a.id)
    wait_for_requests(1)

    DiscordDispatcher.dispatch_event(map_b.id, kill_event(payload))
    settle(w_b.id)

    requests = wait_for_requests(2)
    assert length(requests) == 2

    # Distinct webhook URLs prove both maps were served, not one map twice.
    urls = requests |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert urls == Enum.sort([@system_url, url_b])
  end
```

- [ ] **Step 4: Rekey the remaining two tests**

Replace `discord_dispatcher_test.exs:343-402` (the formatter-cap test and the
three `send_test_message` tests) with:

```elixir
  # Kills past the formatter's per-event cap are never rendered into a message,
  # so they must not be marked attempted — otherwise they are burned for the
  # full dedup TTL without ever being sent.
  test "does not burn kills dropped by the formatter's per-event cap", %{map: map, system: w} do
    cap = EmbedFormatter.max_kills_per_event()

    kills =
      for i <- 1..(cap + 5) do
        Factory.build(:killmail, %{solar_system_id: @wh_system, killmail_id: 600_000 + i})
      end

    overflow = Enum.drop(kills, cap)
    assert length(overflow) == 5

    # The capped event spans several chunks, and the worker deliberately spaces
    # them. Derive how many messages to expect from the formatter itself rather
    # than assuming the first `wait_for_requests/1` catches all of them.
    first_batch_size = length(EmbedFormatter.format_batch(kills, "X"))
    assert first_batch_size > 1

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: kills}))
    )

    settle(w.id)
    first_batch = wait_for_requests(first_batch_size)
    assert length(first_batch) == first_batch_size

    # The overflow kills arrive again on their own: they were never formatted,
    # so they are still eligible and must be delivered now.
    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: overflow}))
    )

    settle(w.id)

    later = wait_for_requests(first_batch_size + 1)
    [{_url, body} | _] = Enum.drop(later, first_batch_size)
    assert length(body["embeds"]) == 5
  end

  test "send_test_message reports the global gate being off", %{system: w} do
    disable_gate()

    assert {:error, :notifications_disabled} = DiscordDispatcher.send_test_message(w.id)
    assert HttpStub.requests() == []
  end

  test "send_test_message goes through the worker", %{system: w} do
    assert :ok = DiscordDispatcher.send_test_message(w.id)

    assert [{url, body}] = wait_for_requests(1)
    assert url == @system_url
    assert body["content"] =~ "test message"
  end

  # send_test_message now takes a WEBHOOK id, so "not configured" means "no such
  # webhook row" rather than "no config for this map".
  test "send_test_message reports an unknown webhook" do
    assert {:error, :not_configured} =
             DiscordDispatcher.send_test_message(Ash.UUID.generate())
  end

  test "send_test_message reports a disabled webhook", %{system: w} do
    {:ok, _} = MapDiscordWebhook.set_enabled(w, %{enabled?: false})

    assert {:error, :not_configured} = DiscordDispatcher.send_test_message(w.id)
    assert HttpStub.requests() == []
  end
end
```

- [ ] **Step 5: Run the dispatcher tests to verify they fail**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs`
Expected: FAIL — `UndefinedFunctionError` / `FunctionClauseError` for
`WorkerSupervisor.deliver/3` (now `/2`), and `send_test_message/1` still resolving
a map id, so `{:error, :not_configured}` is returned for a valid webhook id.

- [ ] **Step 6: Load `:webhooks` with the cached config**

In `lib/wanderer_app/external_events/discord_dispatcher.ex`, replace the alias
block (lines 46-47):

```elixir
  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.ExternalEvents.Discord.{EmbedFormatter, WorkerSupervisor}
```

Replace `load_and_cache/1` (lines 237-249):

```elixir
  defp load_and_cache(map_id) do
    # `:webhooks` is loaded here, once, and rides along in the cached struct: the
    # dispatch path must not query the destination table per killmail. Every
    # child create/update/destroy invalidates this entry (Task 1), so a newly
    # added or removed webhook is picked up immediately rather than after the
    # 5-minute TTL.
    with {:ok, notification} when not is_nil(notification) <-
           MapDiscordNotification.by_map(map_id),
         {:ok, notification} <- Ash.load(notification, :webhooks) do
      Cachex.put(@cache, map_id, notification)
      {:ok, notification}
    else
      _ ->
        # Cache the negative result too, so busy unconfigured maps do not
        # hit the database on every killmail.
        Cachex.put(@cache, map_id, :none)
        {:error, :not_configured}
    end
  end
```

- [ ] **Step 7: Resolve the system webhook on the dispatch path**

Replace `do_dispatch/2`'s `with` head and delivery call
(`discord_dispatcher.ex:148-180`). Only two lines of behaviour are new — finding
the `:system` webhook and passing its id — everything else is the existing body
unchanged.

```elixir
  defp do_dispatch(map_id, %{type: :map_kill, payload: payload}) do
    with true <- enabled_globally?(),
         {:ok, notification} <- fetch_config(map_id),
         true <- notification.enabled?,
         # Phase A resolves ONE destination. Routing between the system and
         # character webhooks arrives with the Router; until then the system
         # webhook is the only destination, exactly as before the split.
         {:ok, webhook} <- system_webhook(notification),
         {:ok, system_id, killmails} <- extract_kills(payload),
         true <- system_allowed?(notification, system_id),
         [_ | _] = fresh <- reject_duplicates(map_id, killmails) do
      system_name = system_name(system_id)

      # Only the kills the formatter will actually render are marked. Kills past
      # its per-event cap are never turned into a message, so marking them would
      # burn them for the full dedup TTL without ever sending them — a loss to a
      # formatting cap, which the at-most-once rationale does not cover. Derived
      # from the formatter's own constant so the two cannot drift apart.
      #
      # `fresh` (not `formatted`) is still handed to format_batch/2 so it can
      # count the overflow and append its "…and N more kills not shown." line.
      formatted = Enum.take(fresh, EmbedFormatter.max_kills_per_event())

      # Marked before delivery: see the moduledoc — this is at-most-once by
      # choice, not an oversight.
      mark_attempted(map_id, formatted)

      fresh
      |> EmbedFormatter.format_batch(system_name)
      |> then(&WorkerSupervisor.deliver(webhook.id, &1))
      |> handle_delivery_result(map_id, formatted)

      :ok
    else
      _ -> :ok
    end
  end

  defp do_dispatch(_map_id, _event), do: :ok

  # A notification always has a `:system` child (the create action makes both in
  # one transaction), but the list can still be empty if the row was removed out
  # of band — return an error rather than raising on the dispatch path.
  # A disabled destination is dropped HERE, before `mark_attempted/2`: the worker
  # would drop it too, but only after the kill had been burned for the dedup TTL.
  defp system_webhook(notification) do
    case Enum.find(notification.webhooks, &(&1.role == :system and &1.enabled?)) do
      nil -> {:error, :not_configured}
      webhook -> {:ok, webhook}
    end
  end
```

- [ ] **Step 8: Point `send_test_message/1` at a webhook id**

Replace `discord_dispatcher.ex:71-119`:

```elixir
  @doc """
  Posts a fixed sample message to ONE webhook so a user can confirm it works.
  Routed through the same worker so it cannot jump the queue.

  Takes a webhook id, not a map id: a map can have two destinations and the
  user tests them separately.

  Reports *configuration* errors synchronously: the global kill-switch being
  off (`:notifications_disabled`) and the webhook being missing or disabled
  (`:not_configured`) are both resolved before returning.

  Delivery success is **not** awaited. The final hop is `Worker.enqueue/2`, a
  cast, so `:ok` means "accepted for delivery", not "Discord accepted it" — a
  dead or revoked webhook URL still returns `:ok` here and surfaces later as a
  failure recorded on the webhook record (`last_error`, `consecutive_failures`).
  UI built on this must not promise the user that the message arrived.
  """
  @spec send_test_message(webhook_id :: String.t()) ::
          :ok | {:error, :notifications_disabled | :not_configured | term()}
  def send_test_message(webhook_id) do
    # Checked here rather than inside the worker: when the gate is off the
    # worker supervisor and its Registry are not running at all, so calling
    # into them would crash the caller (the LiveView).
    if enabled_globally?() do
      case MapDiscordWebhook.by_id(webhook_id) do
        {:ok, %{enabled?: true} = webhook} ->
          message = %{
            "content" => "Wanderer test message — Discord kill notifications are configured."
          }

          case WorkerSupervisor.deliver(webhook.id, [message]) do
            :ok ->
              :ok

            # The gate read as on, but the worker tree is not up (e.g. the app
            # was started with webhooks disabled and the config flipped since).
            # Report it rather than claiming the test message was sent.
            {:error, :not_running} ->
              {:error, :notifications_disabled}

            {:error, reason} ->
              {:error, reason}
          end

        _ ->
          {:error, :not_configured}
      end
    else
      {:error, :notifications_disabled}
    end
  end
```

- [ ] **Step 9: Update the dispatcher moduledoc's dedup paragraph**

Replace `discord_dispatcher.ex:20-22` so the per-map (not per-role) key is stated
where the next phase will look for it:

```elixir
  ## Deduplication is at-most-once, by choice

  The dedup key is `"#{map_id}:#{killmail_id}"` and is deliberately NOT scoped by
  webhook role. A kill posts once per map, to one destination — routing chooses
  which. Scoping the key by role would double-post any kill eligible for both.

  Killmails are marked as *attempted* before delivery is confirmed, so an event
```

- [ ] **Step 10: Fix the one LiveView call site**

`lib/wanderer_app_web/live/maps/components/map_notifications_component.ex:115`
passes `socket.assigns.map_id`. Minimal change only — the component's full
two-webhook rework is Task 14. Replace lines 114-115:

```elixir
  def handle_event("send-test", _params, socket) do
    # Task 14 gives this component a per-webhook test button. Until then it
    # tests the system webhook, which is the only destination the dispatcher
    # uses in Phase A.
    result =
      with %{} = rec <- socket.assigns.notification,
           {:ok, webhooks} <- WandererApp.Api.MapDiscordWebhook.by_notification(rec.id),
           %{} = webhook <- Enum.find(webhooks, &(&1.role == :system)) do
        WandererApp.ExternalEvents.DiscordDispatcher.send_test_message(webhook.id)
      else
        _ -> {:error, :not_configured}
      end

    case result do
```

- [ ] **Step 11: Run the dispatcher tests to verify they pass**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs`
Expected: PASS.

- [ ] **Step 12: Compile cleanly and run the whole Discord suite**

Run: `mix compile --warnings-as-errors`
Expected: no warnings — Task 3 left `deliver/3` callers dangling and this step is
where that is proven closed.

Run: `mix test test/unit/external_events/ test/wanderer_app/external_events/`
Expected: PASS. Behaviour is identical to before Phase A for every pre-existing
test; the only new assertions are the disabled-webhook and no-webhooks cases.

- [ ] **Step 13: Commit**

```
feat(discord): dispatch to the system webhook by id

The dispatcher resolves the map's :system webhook and delivers by webhook
id. Single destination, no routing yet — behaviour is unchanged. The dedup
key stays per-map, not per-role, so a kill posts once regardless of how
many destinations a map has.
```

## Phase B — Ingestion and matching (Tasks 5–8)

Retains attacker identity through flattening, then matches it against a cached per-map tracked-EVE-ID set to produce a routing decision.

**Ordering:** Task 8 consumes `Env.discord_max_killmail_age_seconds/0`, which Task 11 introduces. Land Task 11 before Task 8, or land Task 8's guard call and Task 11's accessor together.

### Task 5: Retain attacker identity through flattening

**Files:**
- Modify: `lib/wanderer_app/kills/message_handler.ex:180-182` (make `adapt_kill_data/1` public for testing)
- Modify: `lib/wanderer_app/kills/message_handler.ex:260-289` (`adapt_nested_format_kill/1` — add the new pipeline stage)
- Modify: `lib/wanderer_app/kills/message_handler.ex:322-347` (`add_final_blow_attacker_data/2`, `add_kill_statistics/3`)
- Modify: `lib/wanderer_app/kills/message_handler.ex:374-391` (add `find_top_damage_attacker/1` next to `find_final_blow_attacker/1`)
- Test: `test/unit/kills/message_handler_attackers_test.exs` (new file — no `message_handler` test file exists today; `test/unit/kills_storage_test.exs` is the nearest sibling)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: six new **optional** string keys on the flattened kill map, consumed by Task 7 (`Matcher.involvement/3`) and by Phase C's `EmbedFormatter`:
  - `"attacker_char_ids" :: [integer()]` — nils rejected
  - `"attacker_corp_ids" :: [integer()]` — nils rejected, deduplicated, order of first appearance
  - `"top_damage_char_id" :: integer() | nil`
  - `"top_damage_char_name" :: String.t() | nil`
  - `"top_damage_corp_id" :: integer() | nil`
  - `"top_damage_corp_ticker" :: String.t() | nil`
- Also produces: `MessageHandler.adapt_kill_data/1` becomes public (`@doc false`), returning `{:ok, map()} | {:error, atom()}`. Only tests call it directly; production callers keep going through `process_killmail_update/1`.

**Critical constraints — read before writing any code:**

1. **`@required_output_fields` (line 350-357) is UNCHANGED.** Every field added by this task is optional. An empty list is a valid value for `attacker_char_ids` and `attacker_corp_ids`, and `nil` is a valid value for all four `top_damage_*` fields — a kill whose attackers are all NPCs has no top-damage *pilot*. Adding any of these to `@required_output_fields` would make `validate_required_output_fields/1` reject perfectly valid kills, and `adapt_nested_format_kill/1` returns `%{}` on failure, which `adapt_kill_data/1` turns into `{:error, :invalid_data}` — i.e. the kill would be silently dropped from the map entirely. Do not add them.

2. **Do NOT touch the already-flat branch at lines 187-197.** That branch handles a payload that already carries `victim_char_id`; it has no `"attackers"` list, so there is nothing to extract from. Reconstructing attacker arrays that were never sent is impossible. Do **not** "helpfully" default the new keys to `[]` there — Task 7 distinguishes an *absent* key (data unknown → route to the system webhook) from an *empty* list (genuinely no attackers matched → drop). Defaulting to `[]` here is a single-line edit that would silently defeat all attacker matching downstream and be indistinguishable from "no tracked pilots were involved."

3. **Where the extraction hooks in.** `add_kill_statistics/3` (line 340-347) already receives `attackers_list` but uses only its `length/1`, discarding the identities. Do not extend it — it is about aggregate statistics. Add a *separate* pipeline stage, `add_attacker_identity_data/2`, appended after `add_kill_statistics/3` in the `adapt_nested_format_kill/1` pipeline (line 270-275). Both stages take the same `attackers_list` value that is already computed at line 267.

4. **Both attackers resolve by one shared code path.** `find_top_damage_attacker/1` mirrors `find_final_blow_attacker/1` and its result is fed through the *same* field-extraction helper (`add_prefixed_attacker_data/3`, refactored out of `add_final_blow_attacker_data/2`), so the two attackers can never drift in how names, tickers and IDs are read. When the top-damage attacker *is* the final-blow attacker, the `top_damage_*` fields are still populated — deciding whether to render them twice is the embed's job (Phase C), not the flattener's.

---

- [ ] **Step 1: Make `adapt_kill_data/1` publicly callable from tests**

`adapt_kill_data/1` is currently `defp` (line 182, 188, 200, 235). The flattening behaviour is what this task changes, and driving it through `process_killmail_update/1` would drag in Cachex storage and PubSub. Promote the clause heads to `def` with `@doc false` — production callers are unchanged.

Change line 180-182 from:

```elixir
  @spec adapt_kill_data(any()) :: adapter_result()
  # Pattern match on zkillboard format - not supported
  defp adapt_kill_data(%{"killID" => kill_id}) do
```

to:

```elixir
  @doc false
  # Public only so the flattening logic can be tested directly; production
  # callers go through `process_killmail_update/1`.
  @spec adapt_kill_data(any()) :: adapter_result()
  # Pattern match on zkillboard format - not supported
  def adapt_kill_data(%{"killID" => kill_id}) do
```

Then change the three remaining `defp adapt_kill_data(` occurrences (lines 188, 200, 235) to `def adapt_kill_data(`. All four clause heads must change together or the compiler errors with "def adapt_kill_data/1 defaults conflicts" / mixed visibility.

- [ ] **Step 2: Verify it still compiles and existing tests pass**

Run: `mix compile --warnings-as-errors && mix test test/unit/`
Expected: PASS, no warnings. (A `defp` → `def` promotion can surface an "unused function" warning disappearing, never appearing.)

- [ ] **Step 3: Commit the visibility change**

```
git commit -am "kills: expose MessageHandler.adapt_kill_data/1 for testing"
```

- [ ] **Step 4: Write the failing test for attacker ID lists**

Create `test/unit/kills/message_handler_attackers_test.exs`. Pure flattening, no Cachex, no GenServer — `async: true` is safe.

```elixir
defmodule WandererApp.Kills.MessageHandlerAttackersTest do
  use ExUnit.Case, async: true

  alias WandererApp.Kills.MessageHandler

  # A realistic nested killmail: one NPC attacker (no character_id, no
  # corporation_id), two pilots from the same corporation (so corp
  # deduplication is exercised), and a third pilot from another corp who lands
  # the final blow while a *different* pilot deals the most damage.
  defp nested_kill do
    %{
      "killmail_id" => 120_345_678,
      "kill_time" => "2026-08-03T14:22:31Z",
      "solar_system_id" => 31_000_005,
      "victim" => %{
        "character_id" => 95_465_499,
        "character_name" => "Victim Pilot",
        "corporation_id" => 98_000_001,
        "corporation_ticker" => "VCTM",
        "corporation_name" => "Victim Corp",
        "alliance_id" => 99_000_001,
        "alliance_ticker" => "VALL",
        "alliance_name" => "Victim Alliance",
        "ship_type_id" => 670,
        "ship_name" => "Capsule"
      },
      "attackers" => [
        %{
          "character_id" => nil,
          "corporation_id" => nil,
          "damage_done" => 120,
          "final_blow" => false,
          "ship_type_id" => 30_889,
          "ship_name" => "Sleepless Sentinel"
        },
        %{
          "character_id" => 91_000_001,
          "character_name" => "Top Damage Pilot",
          "corporation_id" => 98_100_001,
          "corporation_ticker" => "TDMG",
          "corporation_name" => "Top Damage Corp",
          "alliance_id" => 99_100_001,
          "alliance_ticker" => "TALL",
          "alliance_name" => "Top Alliance",
          "damage_done" => 9_500,
          "final_blow" => false,
          "ship_type_id" => 11_567,
          "ship_name" => "Avatar"
        },
        %{
          "character_id" => 91_000_002,
          "character_name" => "Same Corp Pilot",
          "corporation_id" => 98_100_001,
          "corporation_ticker" => "TDMG",
          "corporation_name" => "Top Damage Corp",
          "damage_done" => 400,
          "final_blow" => false,
          "ship_type_id" => 587,
          "ship_name" => "Rifter"
        },
        %{
          "character_id" => 91_000_003,
          "character_name" => "Final Blow Pilot",
          "corporation_id" => 98_100_002,
          "corporation_ticker" => "FBLW",
          "corporation_name" => "Final Blow Corp",
          "damage_done" => 1_200,
          "final_blow" => true,
          "ship_type_id" => 621,
          "ship_name" => "Caracal"
        }
      ],
      "zkb" => %{"total_value" => 1_234_567.0, "npc" => false}
    }
  end

  describe "attacker id lists" do
    test "collects attacker character ids, rejecting NPC nils" do
      assert {:ok, kill} = MessageHandler.adapt_kill_data(nested_kill())

      assert kill["attacker_char_ids"] == [91_000_001, 91_000_002, 91_000_003]
    end

    test "collects attacker corporation ids, rejecting nils and deduplicating" do
      assert {:ok, kill} = MessageHandler.adapt_kill_data(nested_kill())

      assert kill["attacker_corp_ids"] == [98_100_001, 98_100_002]
    end

    test "an all-NPC kill yields empty lists rather than missing keys" do
      npc_kill =
        Map.put(nested_kill(), "attackers", [
          %{"character_id" => nil, "corporation_id" => nil, "damage_done" => 500,
            "final_blow" => true, "ship_type_id" => 30_889}
        ])

      assert {:ok, kill} = MessageHandler.adapt_kill_data(npc_kill)

      assert kill["attacker_char_ids"] == []
      assert kill["attacker_corp_ids"] == []
    end

    test "attacker_count still reflects every attacker, NPCs included" do
      assert {:ok, kill} = MessageHandler.adapt_kill_data(nested_kill())

      assert kill["attacker_count"] == 4
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `mix test test/unit/kills/message_handler_attackers_test.exs`
Expected: FAIL — the first three tests fail with `Assertion with == failed ... right: nil` because `attacker_char_ids` / `attacker_corp_ids` do not exist yet. `attacker_count` already passes.

- [ ] **Step 6: Implement the ID list extraction**

Add a new pipeline stage. In `adapt_nested_format_kill/1`, change lines 270-275 from:

```elixir
    adapted_kill =
      %{}
      |> add_core_kill_data(kill, zkb)
      |> add_victim_data(victim)
      |> add_final_blow_attacker_data(final_blow_attacker)
      |> add_kill_statistics(attackers_list, zkb)
```

to:

```elixir
    adapted_kill =
      %{}
      |> add_core_kill_data(kill, zkb)
      |> add_victim_data(victim)
      |> add_final_blow_attacker_data(final_blow_attacker)
      |> add_kill_statistics(attackers_list, zkb)
      |> add_attacker_identity_data(attackers_list)
```

Then add the new helper immediately after `add_kill_statistics/3` (i.e. after line 347):

```elixir
  # Attacker identity, retained for Discord involvement matching. Deliberately
  # separate from `add_kill_statistics/3`, which is about aggregates and
  # discards the attacker list after taking its length.
  #
  # Every field produced here is OPTIONAL: `@required_output_fields` must not
  # grow. Empty lists are a valid result (an all-NPC kill has no pilots).
  @spec add_attacker_identity_data(map(), list()) :: map()
  defp add_attacker_identity_data(acc, attackers_list) do
    Map.merge(acc, %{
      "attacker_char_ids" => collect_ids(attackers_list, "character_id"),
      "attacker_corp_ids" => collect_ids(attackers_list, "corporation_id")
    })
  end

  # NPC attackers carry no character or corporation id, so nils are dropped
  # rather than retained as a nil member that could never match anything.
  @spec collect_ids(list(), String.t()) :: [integer()]
  defp collect_ids(attackers_list, key) do
    attackers_list
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
```

`Enum.uniq/1` is applied to both lists. Character ids are already unique per killmail in practice; applying it uniformly costs nothing and keeps the two branches identical.

- [ ] **Step 7: Run the test to verify it passes**

Run: `mix test test/unit/kills/message_handler_attackers_test.exs`
Expected: PASS, 4 tests.

- [ ] **Step 8: Commit**

```
git commit -am "kills: retain attacker character and corporation ids when flattening"
```

- [ ] **Step 9: Write the failing test for top-damage attacker fields**

Append this `describe` block to `test/unit/kills/message_handler_attackers_test.exs`, before the final `end`:

```elixir
  describe "top damage attacker" do
    test "selects the highest-damage attacker when it differs from the final blow" do
      assert {:ok, kill} = MessageHandler.adapt_kill_data(nested_kill())

      # Top damage: 9_500. Final blow: a different pilot with 1_200.
      assert kill["top_damage_char_id"] == 91_000_001
      assert kill["top_damage_char_name"] == "Top Damage Pilot"
      assert kill["top_damage_corp_id"] == 98_100_001
      assert kill["top_damage_corp_ticker"] == "TDMG"

      assert kill["final_blow_char_id"] == 91_000_003
    end

    test "still populates the fields when top damage is the final blow attacker" do
      solo =
        Map.put(nested_kill(), "attackers", [
          %{
            "character_id" => 91_000_003,
            "character_name" => "Final Blow Pilot",
            "corporation_id" => 98_100_002,
            "corporation_ticker" => "FBLW",
            "corporation_name" => "Final Blow Corp",
            "damage_done" => 8_000,
            "final_blow" => true,
            "ship_type_id" => 621,
            "ship_name" => "Caracal"
          }
        ])

      assert {:ok, kill} = MessageHandler.adapt_kill_data(solo)

      assert kill["top_damage_char_id"] == 91_000_003
      assert kill["top_damage_char_name"] == "Final Blow Pilot"
      assert kill["final_blow_char_id"] == 91_000_003
    end

    test "an all-NPC kill has nil top damage pilot fields but is still valid" do
      npc_kill =
        Map.put(nested_kill(), "attackers", [
          %{"character_id" => nil, "corporation_id" => nil, "damage_done" => 500,
            "final_blow" => true, "ship_type_id" => 30_889}
        ])

      assert {:ok, kill} = MessageHandler.adapt_kill_data(npc_kill)

      assert kill["top_damage_char_id"] == nil
      assert kill["top_damage_char_name"] == nil
      assert kill["top_damage_corp_id"] == nil
      assert kill["top_damage_corp_ticker"] == nil
    end

    test "attackers with no damage_done key do not crash selection" do
      no_damage =
        Map.put(nested_kill(), "attackers", [
          %{"character_id" => 91_000_010, "character_name" => "No Damage Key",
            "corporation_id" => 98_100_010, "corporation_ticker" => "NDMG",
            "final_blow" => true, "ship_type_id" => 587}
        ])

      assert {:ok, kill} = MessageHandler.adapt_kill_data(no_damage)

      assert kill["top_damage_char_id"] == 91_000_010
    end
  end

  describe "already-flat payloads" do
    test "pass through without the new keys — absent, not empty" do
      flat = %{
        "killmail_id" => 120_345_679,
        "kill_time" => "2026-08-03T14:25:00Z",
        "solar_system_id" => 31_000_005,
        "victim_char_id" => 95_465_499,
        "victim_corp_id" => 98_000_001,
        "victim_ship_type_id" => 670,
        "attacker_count" => 4,
        "total_value" => 1_234_567.0
      }

      assert {:ok, kill} = MessageHandler.adapt_kill_data(flat)

      # Task 7 relies on absence meaning "unknown". Defaulting these to []
      # here would silently disable all attacker matching for flat payloads.
      refute Map.has_key?(kill, "attacker_char_ids")
      refute Map.has_key?(kill, "attacker_corp_ids")
      refute Map.has_key?(kill, "top_damage_char_id")
      refute Map.has_key?(kill, "top_damage_corp_id")
    end

    test "a flat payload that already carries the new keys keeps them" do
      flat = %{
        "killmail_id" => 120_345_680,
        "kill_time" => "2026-08-03T14:26:00Z",
        "solar_system_id" => 31_000_005,
        "victim_char_id" => 95_465_499,
        "victim_corp_id" => 98_000_001,
        "attacker_char_ids" => [91_000_001],
        "attacker_corp_ids" => [98_100_001]
      }

      assert {:ok, kill} = MessageHandler.adapt_kill_data(flat)

      assert kill["attacker_char_ids"] == [91_000_001]
      assert kill["attacker_corp_ids"] == [98_100_001]
    end
  end
```

- [ ] **Step 10: Run the test to verify it fails**

Run: `mix test test/unit/kills/message_handler_attackers_test.exs`
Expected: FAIL — the four `top damage attacker` tests fail (`left: nil, right: 91_000_001` etc.). The two `already-flat payloads` tests should already PASS; if either fails, the flat branch was modified and must be reverted.

- [ ] **Step 11: Refactor `add_final_blow_attacker_data/2` onto a shared prefixed extractor**

Replace lines 322-338 with a prefix-parameterised helper so the final-blow and top-damage attackers are read by identical code:

```elixir
  @spec add_final_blow_attacker_data(map(), map()) :: map()
  defp add_final_blow_attacker_data(acc, attacker),
    do: add_prefixed_attacker_data(acc, attacker, "final_blow")

  # Shared by the final-blow and top-damage attackers so the two can never
  # drift in how names, tickers and ids are read from an attacker map.
  @spec add_prefixed_attacker_data(map(), map(), String.t()) :: map()
  defp add_prefixed_attacker_data(acc, attacker, prefix) do
    attacker_data = %{
      "#{prefix}_char_id" => attacker["character_id"],
      "#{prefix}_char_name" => get_character_name(attacker),
      "#{prefix}_corp_id" => attacker["corporation_id"],
      "#{prefix}_corp_ticker" => get_corp_ticker(attacker),
      "#{prefix}_corp_name" => get_corp_name(attacker),
      "#{prefix}_alliance_id" => attacker["alliance_id"],
      "#{prefix}_alliance_ticker" => get_alliance_ticker(attacker),
      "#{prefix}_alliance_name" => get_alliance_name(attacker),
      "#{prefix}_ship_type_id" => attacker["ship_type_id"],
      "#{prefix}_ship_name" => get_ship_name(attacker)
    }

    Map.merge(acc, attacker_data)
  end
```

This produces exactly the same `final_blow_*` keys as before — verify by re-running the suite in Step 14. It also produces `top_damage_corp_name`, `top_damage_alliance_*` and `top_damage_ship_*` as a side effect of the shared path; those are harmless extras that the embed may use, and keeping one code path is worth more than trimming them.

- [ ] **Step 12: Add `find_top_damage_attacker/1`**

Insert immediately after `find_final_blow_attacker/1`'s catch-all clause (after line 391):

```elixir
  # Mirrors `find_final_blow_attacker/1`: returns `%{}` when there is nothing
  # to pick, so the downstream extractor yields nils rather than crashing.
  @spec find_top_damage_attacker(list(map()) | any()) :: map()
  defp find_top_damage_attacker([]), do: %{}

  defp find_top_damage_attacker(attackers) when is_list(attackers) do
    attackers
    |> Enum.filter(&is_map/1)
    |> Enum.max_by(&damage_done/1, fn -> %{} end)
  end

  defp find_top_damage_attacker(_), do: %{}

  # `damage_done` is occasionally absent or non-numeric in upstream payloads;
  # treat those attackers as having dealt no damage rather than crashing the
  # whole killmail's adaptation.
  @spec damage_done(map()) :: number()
  defp damage_done(%{"damage_done" => damage}) when is_number(damage), do: damage
  defp damage_done(_), do: 0
```

`Enum.max_by/3` on a single-element list returns that element regardless of its damage value, which is why the "no `damage_done` key" test passes.

- [ ] **Step 13: Populate the top-damage fields**

Extend `add_attacker_identity_data/2` (added in Step 6) to also resolve the top-damage attacker through the shared extractor:

```elixir
  @spec add_attacker_identity_data(map(), list()) :: map()
  defp add_attacker_identity_data(acc, attackers_list) do
    top_damage_attacker = find_top_damage_attacker(attackers_list)

    acc
    |> Map.merge(%{
      "attacker_char_ids" => collect_ids(attackers_list, "character_id"),
      "attacker_corp_ids" => collect_ids(attackers_list, "corporation_id")
    })
    |> add_prefixed_attacker_data(top_damage_attacker, "top_damage")
  end
```

When the top-damage attacker is also the final-blow attacker, both key sets are populated with the same pilot. That is intentional; Phase C's embed decides whether to render the line twice.

- [ ] **Step 14: Run the full kills test suite to verify nothing regressed**

Run: `mix test test/unit/kills/message_handler_attackers_test.exs test/unit/kills_storage_test.exs`
Expected: PASS. Then `mix compile --warnings-as-errors` — expected: no warnings (in particular no "function `find_top_damage_attacker/1` is unused").

- [ ] **Step 15: Confirm `@required_output_fields` was not modified**

Run: `git diff lib/wanderer_app/kills/message_handler.ex | grep -A 10 "required_output_fields"`
Expected: NO output. If the list appears in the diff, revert that hunk — the new fields are optional.

- [ ] **Step 16: Commit**

```
git commit -am "kills: extract top-damage attacker alongside final blow"
```

---

### Task 6: Cached per-map tracked EVE ID set

**Files:**
- Create: `lib/wanderer_app/external_events/discord/matcher.ex`
- Modify: `lib/wanderer_app/map.ex:235-260` (`add_characters!/2` — bulk path used at map initialisation)
- Modify: `lib/wanderer_app/map.ex:262-280` (`add_character/2`)
- Modify: `lib/wanderer_app/map.ex:291-304` (`remove_character/2`)
- Test: `test/wanderer_app/external_events/discord/matcher_test.exs`

**Interfaces:**
- Consumes: `WandererApp.Map.list_characters/1` (`map.ex:189-196`) — returns a list of hydrated map-character structs, each with a `:eve_id` field. `WandererApp.Api.Character`'s `eve_id` attribute is `:string` (`character.ex:180-182`).
- Produces (per `CONTRACT.md`):
  - `WandererApp.ExternalEvents.Discord.Matcher.tracked_eve_ids(map_id) :: MapSet.t(integer())`
  - `WandererApp.ExternalEvents.Discord.Matcher.invalidate_tracked(map_id) :: :ok`
- **`involvement/3` is Task 7. Do not write it in this task.**

**Critical constraints — read before writing any code:**

1. **`Character.eve_id` is a STRING; killmail character ids are INTEGERS.** `character.ex:180` declares `attribute :eve_id, :string`. Task 5's `attacker_char_ids` and the existing `victim_char_id` come straight off the wire as integers. The conversion happens **once, here, at set-build time** — never at comparison time, and never in Task 7. This is the single most likely source of a silent bug in the whole feature: a `MapSet` of strings compared against integers matches nothing, and "nothing matched" is indistinguishable from "no tracked pilots were involved." It gets its own explicit test asserting the set contains integers.

2. **Cache choice.** Use the existing `:discord_notification_cache` (`application.ex:132-135`, 5-minute default TTL). No new Cachex child is needed. `DiscordDispatcher` caches under a raw `map_id` key (`discord_dispatcher.ex:222-246`); the namespaced key `"map:#{map_id}:tracked_eve_ids"` cannot collide with it. The 5-minute TTL is a backstop, not the invalidation mechanism — a missed explicit invalidation self-heals within five minutes instead of persisting for the life of the node.

3. **Error contract: return an empty `MapSet`, never raise.** `list_characters/1` calls `get_map!/1`, which raises when the map is not in the map cache (not yet started, or shut down). `tracked_eve_ids/1` must catch that and return `MapSet.new()` after logging a warning, and must **not** cache the empty result — otherwise a transient miss would be pinned for five minutes. Task 7's caller then sees "not involved" and, per the spec's failure table, routes the kill to the system webhook rather than dropping it. Raising here would kill the dispatcher instead.

---

- [ ] **Step 1: Write the failing test for the module's existence and integer contract**

Create `test/wanderer_app/external_events/discord/matcher_test.exs`. This touches Cachex and the map GenServer, so `async: false` is mandatory.

```elixir
defmodule WandererApp.ExternalEvents.Discord.MatcherTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.ExternalEvents.Discord.Matcher

  setup do
    map = WandererAppWeb.Factory.insert(:map, %{})
    Matcher.invalidate_tracked(map.id)
    on_exit(fn -> Matcher.invalidate_tracked(map.id) end)
    %{map: map}
  end

  describe "tracked_eve_ids/1" do
    test "returns a MapSet of INTEGER eve ids, not strings", %{map: map} do
      start_map_with_characters(map, ["95465499", "91000001"])

      ids = Matcher.tracked_eve_ids(map.id)

      assert %MapSet{} = ids
      assert MapSet.member?(ids, 95_465_499)
      assert MapSet.member?(ids, 91_000_001)

      # The whole point of this task: a string-keyed set would satisfy the
      # `member?` calls above only if the caller also passed strings, which it
      # never does. Assert the element type directly.
      assert Enum.all?(ids, &is_integer/1)
      refute MapSet.member?(ids, "95465499")
    end

    test "a character whose eve_id is a numeric string is found by integer id", %{map: map} do
      start_map_with_characters(map, ["2117994022"])

      assert MapSet.member?(Matcher.tracked_eve_ids(map.id), 2_117_994_022)
    end

    test "returns an empty MapSet for a map that is not running" do
      unknown_map_id = Ecto.UUID.generate()

      assert Matcher.tracked_eve_ids(unknown_map_id) == MapSet.new()
    end

    test "does not cache the empty result of a failed lookup" do
      unknown_map_id = Ecto.UUID.generate()

      assert Matcher.tracked_eve_ids(unknown_map_id) == MapSet.new()

      assert {:ok, nil} =
               Cachex.get(:discord_notification_cache, "map:#{unknown_map_id}:tracked_eve_ids")
    end
  end
end
```

`start_map_with_characters/2` is written in Step 5 — the test will not compile until then. That is expected; Step 2 confirms the module itself is missing first.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/wanderer_app/external_events/discord/matcher_test.exs`
Expected: FAIL at compile time with `module WandererApp.ExternalEvents.Discord.Matcher is not available` (and `undefined function start_map_with_characters/2`).

- [ ] **Step 3: Create the Matcher module**

Create `lib/wanderer_app/external_events/discord/matcher.ex`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.Matcher do
  @moduledoc """
  Decides whether a killmail involves a map's tracked pilots.

  The tracked-pilot set is cached per map because `WandererApp.Map.list_characters/1`
  hydrates every character on every call, which is far too expensive to run once
  per killmail.
  """

  require Logger

  @cache :discord_notification_cache
  # A backstop only: correctness comes from `invalidate_tracked/1`, fired by
  # every writer of `map.characters`. The TTL bounds the damage of a missed
  # invalidation to five minutes rather than the lifetime of the node.
  @ttl :timer.minutes(5)

  @doc """
  The EVE character ids tracked on `map_id`, as **integers**.

  `WandererApp.Api.Character`'s `eve_id` is a string; killmail payloads carry
  integers. The conversion happens here, once per cache build, so that no
  comparison site anywhere else has to think about it.

  Returns an empty `MapSet` if the map cannot be read (e.g. its server is not
  running). Callers must treat that as "no tracked pilots" and fall back to
  their conservative destination — this function never raises.
  """
  @spec tracked_eve_ids(String.t()) :: MapSet.t(integer())
  def tracked_eve_ids(map_id) do
    case Cachex.get(@cache, cache_key(map_id)) do
      {:ok, %MapSet{} = ids} ->
        ids

      _ ->
        build_and_cache(map_id)
    end
  end

  @doc """
  Drops the cached set for `map_id`. Must be called by every writer of
  `map.characters`.
  """
  @spec invalidate_tracked(String.t()) :: :ok
  def invalidate_tracked(map_id) do
    Cachex.del(@cache, cache_key(map_id))
    :ok
  end

  defp build_and_cache(map_id) do
    case build(map_id) do
      {:ok, ids} ->
        Cachex.put(@cache, cache_key(map_id), ids, ttl: @ttl)
        ids

      :error ->
        # Deliberately NOT cached: a transient failure must not be pinned for
        # the TTL, or every kill on this map is misrouted for five minutes.
        MapSet.new()
    end
  end

  defp build(map_id) do
    ids =
      map_id
      |> WandererApp.Map.list_characters()
      |> Enum.map(& &1.eve_id)
      |> Enum.map(&parse_eve_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {:ok, ids}
  rescue
    error ->
      Logger.warning(
        "[Discord.Matcher] Failed to build tracked set for map #{map_id}: #{inspect(error)}"
      )

      :error
  end

  defp parse_eve_id(eve_id) when is_integer(eve_id), do: eve_id

  defp parse_eve_id(eve_id) when is_binary(eve_id) do
    case Integer.parse(eve_id) do
      {id, ""} ->
        id

      _ ->
        Logger.warning("[Discord.Matcher] Non-numeric eve_id skipped: #{inspect(eve_id)}")
        nil
    end
  end

  defp parse_eve_id(_), do: nil

  defp cache_key(map_id), do: "map:#{map_id}:tracked_eve_ids"
end
```

The `is_integer/1` clause of `parse_eve_id/1` exists so the function stays correct if `eve_id` is ever migrated to an integer column; it is not dead defensive code for the current schema, it is the migration seam.

- [ ] **Step 4: Run the test to verify the module compiles and the failure case passes**

Run: `mix test test/wanderer_app/external_events/discord/matcher_test.exs`
Expected: still FAIL on `undefined function start_map_with_characters/2`, but the `module ... is not available` error is gone.

- [ ] **Step 5: Add the test helper that starts a map with characters**

Add to `test/wanderer_app/external_events/discord/matcher_test.exs`, at the bottom of the module (before the final `end`):

```elixir
  # Starts the map server and registers characters on it via the same public
  # writer production uses, so the test exercises the real invalidation path.
  defp start_map_with_characters(map, eve_ids) do
    {:ok, _pid} = WandererApp.Map.Server.start_map(map.id)

    characters =
      Enum.map(eve_ids, fn eve_id ->
        {:ok, character} =
          WandererApp.Api.Character.create(%{
            eve_id: eve_id,
            name: "Pilot #{eve_id}"
          })

        WandererApp.Map.add_character(map.id, character)
        character
      end)

    Matcher.invalidate_tracked(map.id)
    characters
  end
```

If `WandererApp.Api.Character.create/1` requires additional attributes in this codebase, add exactly those — do **not** switch to raw Ecto inserts. Confirm the required set with `grep -n "create" lib/wanderer_app/api/character.ex` before writing this step's code, and adjust the attrs map accordingly.

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/wanderer_app/external_events/discord/matcher_test.exs`
Expected: PASS, 4 tests. In particular `assert Enum.all?(ids, &is_integer/1)` must pass — if it fails, `parse_eve_id/1` is not being applied.

- [ ] **Step 7: Commit**

```
git commit -am "discord: cached per-map tracked EVE id set"
```

- [ ] **Step 8: Write the failing invalidation tests**

Append to `test/wanderer_app/external_events/discord/matcher_test.exs`, before the helper:

```elixir
  describe "invalidation" do
    test "add_character/2 invalidates the cached set", %{map: map} do
      start_map_with_characters(map, ["95465499"])
      assert MapSet.size(Matcher.tracked_eve_ids(map.id)) == 1

      {:ok, newcomer} =
        WandererApp.Api.Character.create(%{eve_id: "91000005", name: "Newcomer"})

      WandererApp.Map.add_character(map.id, newcomer)

      ids = Matcher.tracked_eve_ids(map.id)
      assert MapSet.member?(ids, 91_000_005)
      assert MapSet.size(ids) == 2
    end

    test "remove_character/2 invalidates the cached set", %{map: map} do
      [first | _] = start_map_with_characters(map, ["95465499", "91000001"])
      assert MapSet.size(Matcher.tracked_eve_ids(map.id)) == 2

      WandererApp.Map.remove_character(map.id, first.id)

      ids = Matcher.tracked_eve_ids(map.id)
      refute MapSet.member?(ids, 95_465_499)
      assert MapSet.size(ids) == 1
    end

    test "add_characters!/2 (the bulk startup path) invalidates the cached set", %{map: map} do
      start_map_with_characters(map, ["95465499"])
      # Warm the cache so a missing invalidation is observable.
      assert MapSet.size(Matcher.tracked_eve_ids(map.id)) == 1

      {:ok, bulk_one} =
        WandererApp.Api.Character.create(%{eve_id: "91000006", name: "Bulk One"})

      {:ok, bulk_two} =
        WandererApp.Api.Character.create(%{eve_id: "91000007", name: "Bulk Two"})

      map.id
      |> WandererApp.Map.get_map!()
      |> WandererApp.Map.add_characters!([
        %{character_id: bulk_one.id},
        %{character_id: bulk_two.id}
      ])

      ids = Matcher.tracked_eve_ids(map.id)
      assert MapSet.member?(ids, 91_000_006)
      assert MapSet.member?(ids, 91_000_007)
    end

    test "invalidate_tracked/1 is idempotent and safe on a cold cache", %{map: map} do
      assert Matcher.invalidate_tracked(map.id) == :ok
      assert Matcher.invalidate_tracked(map.id) == :ok
    end
  end
```

- [ ] **Step 9: Run the tests to verify they fail**

Run: `mix test test/wanderer_app/external_events/discord/matcher_test.exs`
Expected: the three writer tests FAIL — the cache was warmed and never invalidated, so `tracked_eve_ids/1` returns the stale set (`MapSet.size == 1`, `refute MapSet.member?` fails). `invalidate_tracked/1 is idempotent` PASSES already.

- [ ] **Step 10: Invalidate from `add_characters!/2`**

`map.ex:235-260`. This is the bulk path used when a map initialises; missing it leaves the set stale exactly when a map starts up — the worst possible moment, because every pilot on the map is new. Note the early return at line 249-251 (`new_character_ids == []`): nothing changed there, so no invalidation is needed on that branch.

Change lines 252-259 from:

```elixir
      case update_map(map_id, %{characters: new_character_ids ++ current_characters}) do
        {:commit, map} ->
          map

        _ ->
          map
      end
```

to:

```elixir
      case update_map(map_id, %{characters: new_character_ids ++ current_characters}) do
        {:commit, map} ->
          WandererApp.ExternalEvents.Discord.Matcher.invalidate_tracked(map_id)
          map

        _ ->
          map
      end
```

Invalidation happens only on `{:commit, _}` — the other branch did not change the character list.

- [ ] **Step 11: Invalidate from `add_character/2`**

`map.ex:262-280`. Change the `true ->` branch (lines 271-275) from:

```elixir
      true ->
        map_id
        |> update_map(%{characters: [character_id | characters]})

        :ok
```

to:

```elixir
      true ->
        map_id
        |> update_map(%{characters: [character_id | characters]})

        WandererApp.ExternalEvents.Discord.Matcher.invalidate_tracked(map_id)

        :ok
```

The `_ ->` branch is the "already a member" case and needs no invalidation.

- [ ] **Step 12: Invalidate from `remove_character/2`**

`map.ex:291-304`. Change the `true ->` branch (lines 295-299) from:

```elixir
      true ->
        map_id
        |> update_map(%{characters: characters |> Enum.reject(fn id -> id == character_id end)})

        :ok
```

to:

```elixir
      true ->
        map_id
        |> update_map(%{characters: characters |> Enum.reject(fn id -> id == character_id end)})

        WandererApp.ExternalEvents.Discord.Matcher.invalidate_tracked(map_id)

        :ok
```

- [ ] **Step 13: Confirm all three writers are covered**

Run: `grep -n "characters:" lib/wanderer_app/map.ex`
Expected: exactly three `update_map(... %{characters: ...})` call sites — inside `add_characters!/2`, `add_character/2` and `remove_character/2`. If a fourth appears, it is a writer this plan missed; add an `invalidate_tracked/1` call to it and note it in the commit message.

- [ ] **Step 14: Run the tests to verify they pass**

Run: `mix test test/wanderer_app/external_events/discord/matcher_test.exs`
Expected: PASS, 8 tests.

- [ ] **Step 15: Run the wider map suite for regressions**

Run: `mix test test/wanderer_app/ && mix compile --warnings-as-errors`
Expected: PASS, no warnings. `WandererApp.Map` now references `WandererApp.ExternalEvents.Discord.Matcher`; confirm no compile-time cycle warning appears (there is none — `Matcher` calls `Map` at runtime only, through a plain function call, not a macro).

- [ ] **Step 16: Commit**

```
git commit -am "map: invalidate the Discord tracked-pilot set from all three character writers"
```

### Task 7: Involvement verdict

**Files:**
- Modify: `lib/wanderer_app/external_events/discord/matcher.ex` (created in Task 6; add `involvement/3`)
- Test: `test/unit/external_events/discord/matcher_involvement_test.exs`

**Interfaces:**
- Consumes: `WandererApp.ExternalEvents.Discord.Matcher.tracked_eve_ids(map_id) :: MapSet.t(integer())` (Task 6). Consumes the flattened-kill keys added in Task 5: `attacker_char_ids`, `attacker_corp_ids` (integer lists), and the pre-existing `victim_char_id` / `victim_corp_id`.
- Produces: `Matcher.involvement(kill, tracked_set, focus_corp_ids) :: {:involved, :victim} | {:involved, :attacker} | :not_involved` — consumed by `Router.route/3` (Task 8), by the dispatcher partition step (Task 8), and by `EmbedFormatter.format_batch([{kill, verdict}], system_name)` (Task 9).

Evaluation order is fixed by spec §3 (`docs/superpowers/specs/2026-08-03-native-killmail-notifications-design.md:223-238`):

```
victim char_id in tracked_eve_ids       -> {:involved, :victim}
victim corp_id in focus_corp_ids        -> {:involved, :victim}
any attacker char_id in tracked_eve_ids -> {:involved, :attacker}
any attacker corp_id in focus_corp_ids  -> {:involved, :attacker}
otherwise                               -> :not_involved
```

Victim checks run **before** attacker checks, so a kill where both sides are tracked renders as a LOSS. Losses are the more urgent signal. Corp focus widens "tracked" rather than being a separate routing concept, so it earns the same colouring (Task 9) and the same carve-outs (Task 8) at no extra routing complexity.

**ABSENT ≠ EMPTY.** A flat-format payload omits the attacker keys entirely; a nested-format payload (Task 5) always supplies them, possibly as `[]`. `Map.get(kill, "attacker_char_ids", [])` would collapse those two cases into one and quietly assert "there were no attackers", which is a false statement about the world. Use `Map.has_key?/2`.

- [ ] **Step 1: Write the failing test**

Create `test/unit/external_events/discord/matcher_involvement_test.exs`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.MatcherInvolvementTest do
  # `involvement/3` is pure: no database, no cache, no application env.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias WandererApp.ExternalEvents.Discord.Matcher

  @tracked MapSet.new([1001, 1002])
  @focus [500_001]

  # A nested-format kill: Task 5 guarantees the attacker keys are present, even
  # when the lists are empty.
  defp nested(overrides) do
    Map.merge(
      %{
        "killmail_id" => 900_001,
        "solar_system_id" => 31_000_005,
        "victim_char_id" => 7000,
        "victim_corp_id" => 700_000,
        "attacker_char_ids" => [],
        "attacker_corp_ids" => []
      },
      overrides
    )
  end

  # A flat-format kill: the attacker keys are ABSENT, not empty.
  defp flat(overrides) do
    Map.merge(
      %{
        "killmail_id" => 900_002,
        "solar_system_id" => 31_000_005,
        "victim_char_id" => 7000,
        "victim_corp_id" => 700_000
      },
      overrides
    )
  end

  test "a tracked victim character is a loss" do
    kill = nested(%{"victim_char_id" => 1001})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :victim}
  end

  test "a victim in a focused corporation is a loss" do
    kill = nested(%{"victim_corp_id" => 500_001})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :victim}
  end

  test "a tracked attacker character is a kill" do
    kill = nested(%{"attacker_char_ids" => [4242, 1002]})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :attacker}
  end

  test "an attacker in a focused corporation is a kill" do
    kill = nested(%{"attacker_corp_ids" => [999_999, 500_001]})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :attacker}
  end

  test "an untouched kill is not involved" do
    kill = nested(%{"attacker_char_ids" => [4242], "attacker_corp_ids" => [999_999]})

    assert Matcher.involvement(kill, @tracked, @focus) == :not_involved
  end

  # Pins the ordering from spec section 3. Reversing the two blocks leaves every
  # other test in this file green while turning every self-inflicted loss into a
  # green "kill" embed in the channel.
  test "the victim check wins when both sides are tracked" do
    kill = nested(%{"victim_char_id" => 1001, "attacker_char_ids" => [1002]})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :victim}
  end

  test "a flat payload with a tracked victim is still a loss" do
    kill = flat(%{"victim_char_id" => 1001})

    assert Matcher.involvement(kill, @tracked, @focus) == {:involved, :victim}
  end

  test "a flat payload with no victim match is not involved and logs the divergence" do
    kill = flat(%{"killmail_id" => 900_777})

    log =
      capture_log([level: :debug], fn ->
        assert Matcher.involvement(kill, @tracked, @focus) == :not_involved
      end)

    assert log =~ "900777"
    assert log =~ "attacker data absent"
  end

  # THE case that distinguishes absent from empty. `Map.get(k, [])` in the
  # implementation makes this test pass and the previous one fail; this one
  # exists so nobody "fixes" that by silencing the log unconditionally.
  test "present-but-empty attacker lists are not a divergence" do
    kill = nested(%{"attacker_char_ids" => [], "attacker_corp_ids" => []})

    log =
      capture_log([level: :debug], fn ->
        assert Matcher.involvement(kill, @tracked, @focus) == :not_involved
      end)

    refute log =~ "attacker data absent"
  end

  test "an empty focus list never matches" do
    kill = nested(%{"victim_corp_id" => 500_001, "attacker_corp_ids" => [500_001]})

    assert Matcher.involvement(kill, @tracked, []) == :not_involved
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord/matcher_involvement_test.exs`
Expected: FAIL with `function WandererApp.ExternalEvents.Discord.Matcher.involvement/3 is undefined or private`.

- [ ] **Step 3: Add the verdict function to `Matcher`**

Append to `lib/wanderer_app/external_events/discord/matcher.ex`, inside the module (Task 6 already added `require Logger`; add it if absent):

```elixir
  @type verdict :: {:involved, :victim} | {:involved, :attacker} | :not_involved

  @doc """
  Decides whether a killmail involves this map's own pilots.

  Order is load-bearing (spec section 3): victim checks precede attacker checks,
  so a kill where both sides are tracked renders as a *loss*. Losses are the
  more urgent signal.

  `focus_corp_ids` widens "tracked" rather than acting as a separate routing
  concept, so corporation focus earns the same colouring and the same routing
  carve-outs as character tracking.
  """
  @spec involvement(map(), MapSet.t(integer()), [integer()]) :: verdict()
  def involvement(kill, tracked_eve_ids, focus_corp_ids) do
    cond do
      MapSet.member?(tracked_eve_ids, kill["victim_char_id"]) -> {:involved, :victim}
      kill["victim_corp_id"] in focus_corp_ids -> {:involved, :victim}
      attacker_match?(kill, tracked_eve_ids, focus_corp_ids) -> {:involved, :attacker}
      true -> :not_involved
    end
  end

  # ABSENT is not EMPTY. Nested-format payloads always carry the attacker keys
  # (possibly as empty lists); flat-format payloads omit them entirely. Treating
  # a missing key as `[]` would assert "there were no tracked attackers", which
  # we do not know. This is a compatibility behaviour for a payload shape we
  # cannot enrich, not a normalization: admitting the data is unknown is better
  # than pretending it is empty.
  #
  # Victim matching still runs normally either way — `victim_char_id` and
  # `victim_corp_id` exist in both shapes. When the victim does not match and
  # the attacker data is unknown, the verdict is `:not_involved`, which routes
  # to the system webhook: the same conservative destination a matching-cache
  # failure produces.
  defp attacker_match?(kill, tracked_eve_ids, focus_corp_ids) do
    if Map.has_key?(kill, "attacker_char_ids") or Map.has_key?(kill, "attacker_corp_ids") do
      Enum.any?(kill["attacker_char_ids"] || [], &MapSet.member?(tracked_eve_ids, &1)) or
        Enum.any?(kill["attacker_corp_ids"] || [], &(&1 in focus_corp_ids))
    else
      log_attacker_divergence(kill)
      false
    end
  end

  # Logged once per occurrence, at debug, with the killmail id. If flat-format
  # payloads turn out to be common in production this is visible in the logs
  # rather than inferred from notifications that never arrived.
  defp log_attacker_divergence(kill) do
    Logger.debug(fn ->
      "[Discord] killmail #{kill["killmail_id"]}: attacker data absent from payload; " <>
        "involvement decided on the victim alone"
    end)
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord/matcher_involvement_test.exs`
Expected: 10 tests, 0 failures.

- [ ] **Step 5: Commit**

Run: `git add lib/wanderer_app/external_events/discord/matcher.ex test/unit/external_events/discord/matcher_involvement_test.exs && git commit -m "Add involvement verdict to Discord matcher"`

---

### Task 8: Routing and per-destination batch partitioning

**Files:**
- Create: `lib/wanderer_app/external_events/discord/router.ex`
- Create: `test/unit/external_events/discord/router_test.exs`
- Modify: `lib/wanderer_app/external_events/discord_dispatcher.ex:36-39` (moduledoc), `:46-47` (aliases), `:148-180` (the dispatch block), `:184-217` (delivery-result handling), `:262-268` (delete `system_allowed?/2`), `:291` (dedup key comment), `:293-298` (delete `system_name/1`)
- Test: `test/unit/external_events/discord_dispatcher_test.exs` (add cases; keep the existing setup block verbatim)

**Interfaces:**
- Consumes: `Matcher.tracked_eve_ids(map_id) :: MapSet.t(integer())` (Task 6); `Matcher.involvement(kill, tracked_set, focus_corp_ids) :: verdict` (Task 7); `WandererApp.Api.MapDiscordWebhook` rows with `id`, `role` (`:system` | `:character`), `enabled?` (Tasks 1-4); `MapDiscordNotification` with `enabled?`, `wh_only`, `excluded_systems`, `focus_corp_ids`, `has_many :webhooks` (Tasks 1-4); `WorkerSupervisor.deliver(webhook_id, messages)` — **arity 2** (Task 4); `EmbedFormatter.format_batch([{kill, verdict}], system_name) :: [message]` and `EmbedFormatter.max_kills_per_event() :: pos_integer()` (Task 9); `SystemName.display_name(map_id, solar_system_id, role) :: String.t() | nil` (Task 10); `WandererApp.Env.discord_max_killmail_age_seconds() :: pos_integer()` (Task 11 — the age guard slots into `do_dispatch/2` as a rejection step immediately before `reject_duplicates/2`, so stale kills are never marked; Task 11 owns that edit and this task must not pre-empt it).
- Produces: `WandererApp.ExternalEvents.Discord.Router.route(kill, notification, verdict) :: {:ok, %MapDiscordWebhook{}} | :drop` (`notification` has `:webhooks` loaded).

Routing rules, evaluated **in order** (spec §4, `…-design.md:240-270`):

| # | Condition | Destination |
|---|---|---|
| 1 | System in `excluded_systems`, **not** involved | drop |
| 2 | `wh_only` on, system is not a wormhole, **not** involved | drop |
| 3 | Involved | character webhook |
| 4 | Otherwise | system webhook |

Rules 1 and 2 are the carve-outs: a kill involving your own pilots is always interesting, wherever it happened, so exclusion and wormhole-only filters do not apply to it.

**FALLBACK:** when no `:character` webhook row exists, rule 3 resolves to the **system** webhook. This is the single thing that keeps every existing single-webhook configuration working with no user action; the character channel is purely opt-in.

> ### DISABLED DESTINATIONS DROP. THEY DO NOT REROUTE.
>
> If the webhook a kill routes to is itself disabled — by the user, or by the consecutive-failure threshold — the kill is **dropped**. It is *not* sent to the other channel. Disabling a channel must mean silence for that class of kill, not silent misdirection into a channel the user did not choose. For a public character channel that is a privacy question, not merely a preference: a user who disables the character webhook has not consented to those kills appearing in the system channel instead.
>
> This is the rule most likely to be "improved" into a reroute by a well-meaning reader who sees a dropped kill and assumes it is a bug. It is not a bug. The test `"a disabled character webhook drops rather than rerouting"` exists to fail loudly if anyone does.

- [ ] **Step 1: Write the failing Router test**

Create `test/unit/external_events/discord/router_test.exs`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.RouterTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.ExternalEvents.Discord.Router
  alias WandererAppWeb.Factory

  @wh_system 31_000_005
  @ks_system 30_000_142

  setup do
    Cachex.put(:system_static_info_cache, @wh_system, %{
      solar_system_id: @wh_system,
      solar_system_name: "J115405",
      system_class: 3
    })

    Cachex.put(:system_static_info_cache, @ks_system, %{
      solar_system_id: @ks_system,
      solar_system_name: "Jita",
      system_class: 0
    })

    on_exit(fn ->
      Cachex.del(:system_static_info_cache, @wh_system)
      Cachex.del(:system_static_info_cache, @ks_system)
    end)

    map = Factory.insert(:map, %{})

    # Task 2's `create` takes `webhook_url` as a required argument and seeds the
    # `:system` child through `manage_relationship` in the same transaction, so
    # the system webhook already exists here. Creating a second `:system` row
    # would violate the (notification_id, role) identity from Task 1.
    {:ok, notification} =
      MapDiscordNotification.create(%{
        map_id: map.id,
        webhook_url: "https://discord.com/api/webhooks/1/sys"
      })

    notification = Ash.load!(notification, :webhooks)
    system_wh = Enum.find(notification.webhooks, &(&1.role == :system))

    %{map: map, notification: notification, system_wh: system_wh}
  end

  defp with_webhooks(notification), do: Ash.load!(notification, :webhooks)

  defp add_character_webhook(notification) do
    {:ok, wh} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: "https://discord.com/api/webhooks/2/chr"
      })

    wh
  end

  defp kill(system_id), do: %{"killmail_id" => 1, "solar_system_id" => system_id}

  test "rule 4: an uninvolved kill goes to the system webhook", %{
    notification: n,
    system_wh: system_wh
  } do
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    assert {:ok, %{id: id}} = Router.route(kill(@ks_system), with_webhooks(n), :not_involved)
    assert id == system_wh.id
  end

  test "rule 3: an involved kill goes to the character webhook", %{notification: n} do
    character_wh = add_character_webhook(n)
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    assert {:ok, %{id: id}} =
             Router.route(kill(@ks_system), with_webhooks(n), {:involved, :victim})

    assert id == character_wh.id
  end

  # The compatibility guarantee: every existing single-webhook config keeps
  # working untouched.
  test "rule 3 falls back to the system webhook when no character row exists", %{
    notification: n,
    system_wh: system_wh
  } do
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    assert {:ok, %{id: id}} =
             Router.route(kill(@ks_system), with_webhooks(n), {:involved, :attacker})

    assert id == system_wh.id
  end

  test "rule 1: an excluded system drops when not involved", %{notification: n} do
    {:ok, n} =
      MapDiscordNotification.update(n, %{wh_only: false, excluded_systems: [@ks_system]})

    assert Router.route(kill(@ks_system), with_webhooks(n), :not_involved) == :drop
  end

  test "rule 1 does not apply to an involved kill", %{notification: n} do
    character_wh = add_character_webhook(n)

    {:ok, n} =
      MapDiscordNotification.update(n, %{wh_only: false, excluded_systems: [@ks_system]})

    assert {:ok, %{id: id}} =
             Router.route(kill(@ks_system), with_webhooks(n), {:involved, :victim})

    assert id == character_wh.id
  end

  test "rule 2: wh_only drops known space when not involved", %{notification: n} do
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: true})

    assert Router.route(kill(@ks_system), with_webhooks(n), :not_involved) == :drop
  end

  test "rule 2 does not apply to an involved kill", %{notification: n} do
    character_wh = add_character_webhook(n)
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: true})

    assert {:ok, %{id: id}} =
             Router.route(kill(@ks_system), with_webhooks(n), {:involved, :attacker})

    assert id == character_wh.id
  end

  test "wh_only still delivers wormhole kills", %{notification: n, system_wh: system_wh} do
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: true})

    assert {:ok, %{id: id}} = Router.route(kill(@wh_system), with_webhooks(n), :not_involved)
    assert id == system_wh.id
  end

  # DROP, NOT REROUTE. Turning this into `{:ok, system_wh}` would post kills
  # involving the user's own pilots into a channel they did not choose.
  test "a disabled character webhook drops rather than rerouting", %{notification: n} do
    character_wh = add_character_webhook(n)
    {:ok, _} = MapDiscordWebhook.set_enabled(character_wh, %{enabled?: false})
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    assert Router.route(kill(@ks_system), with_webhooks(n), {:involved, :victim}) == :drop
  end

  test "a disabled system webhook drops rather than rerouting", %{
    notification: n,
    system_wh: system_wh
  } do
    _character_wh = add_character_webhook(n)
    {:ok, _} = MapDiscordWebhook.set_enabled(system_wh, %{enabled?: false})
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    assert Router.route(kill(@ks_system), with_webhooks(n), :not_involved) == :drop
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord/router_test.exs`
Expected: FAIL with `module WandererApp.ExternalEvents.Discord.Router is not available`.

- [ ] **Step 3: Create the Router**

Create `lib/wanderer_app/external_events/discord/router.ex`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.Router do
  @moduledoc """
  Chooses the destination webhook for a single killmail.

  Rules, evaluated in order (design section 4):

  | # | Condition                                          | Destination       |
  |---|----------------------------------------------------|-------------------|
  | 1 | System in `excluded_systems`, **not** involved     | drop              |
  | 2 | `wh_only` on, system not a wormhole, not involved  | drop              |
  | 3 | Involved                                           | character webhook |
  | 4 | Otherwise                                          | system webhook    |

  Rules 1 and 2 are carve-outs: a kill involving your own pilots is always
  interesting, wherever it happened, so the exclusion and wormhole-only filters
  do not apply to it.

  ## Fallback

  When no `:character` webhook row exists, rule 3 resolves to the **system**
  webhook. Every existing single-webhook configuration therefore keeps working
  with no user action, and the character channel is purely opt-in.

  ## Disabled destinations drop; they do not reroute

  If the webhook a kill routes to is itself disabled — by the user or by the
  consecutive-failure threshold — the kill is dropped, **not** sent to the other
  channel. Disabling a channel must mean silence for that class of kill, not
  silent misdirection into a channel the user did not choose. For a public
  character channel that is a privacy question, not just a preference.

  Do not "fix" this into a reroute. `RouterTest` asserts it deliberately.
  """

  alias WandererApp.SystemClass

  @type verdict :: WandererApp.ExternalEvents.Discord.Matcher.verdict()

  @doc """
  Resolves one killmail to a destination. `notification` must have `:webhooks`
  loaded.
  """
  @spec route(map(), struct(), verdict()) :: {:ok, struct()} | :drop
  def route(kill, notification, verdict) do
    involved? = match?({:involved, _}, verdict)
    system_id = kill["solar_system_id"]

    cond do
      not involved? and system_id in (notification.excluded_systems || []) ->
        :drop

      not involved? and notification.wh_only and not SystemClass.wormhole_system?(system_id) ->
        :drop

      involved? ->
        # Fallback to the system webhook when the character channel is not
        # configured at all. `nil` here means "not configured"; a configured but
        # disabled row is a different thing and is handled by `usable/1`.
        usable(webhook(notification, :character) || webhook(notification, :system))

      true ->
        usable(webhook(notification, :system))
    end
  end

  defp webhook(notification, role) do
    notification.webhooks
    |> List.wrap()
    |> Enum.find(&(&1.role == role))
  end

  defp usable(nil), do: :drop
  defp usable(%{enabled?: false}), do: :drop
  defp usable(webhook), do: {:ok, webhook}
end
```

- [ ] **Step 4: Run the Router test to verify it passes**

Run: `mix test test/unit/external_events/discord/router_test.exs`
Expected: 10 tests, 0 failures.

- [ ] **Step 5: Commit the Router**

Run: `git add lib/wanderer_app/external_events/discord/router.ex test/unit/external_events/discord/router_test.exs && git commit -m "Add Discord destination router"`

- [ ] **Step 6: Update the dispatcher test setup for the split schema**

The existing setup at `test/unit/external_events/discord_dispatcher_test.exs:15-52` creates the notification with a `webhook_url`. After Tasks 1-4 the URL lives on a child row. Replace **only** lines 41-51 of that block (the map/notification/invalidate section); keep `seed_static_info()`, the app-env override with its `on_exit`, `HttpStub.start()`, `HttpStub.reset()`, `start_supervised!(WorkerSupervisor)` and `start_supervised!(DiscordDispatcher)` exactly as they are, and keep the `@wh_system 31_000_005` / `@ks_system 30_000_142` constants at lines 12-13:

```elixir
    map = Factory.insert(:map, %{})

    # See the note in Task 8's first setup block: `create` seeds the `:system`
    # child itself, so read it back rather than creating a second one.
    {:ok, notification} =
      MapDiscordNotification.create(%{
        map_id: map.id,
        webhook_url: "https://discord.com/api/webhooks/123/tok"
      })

    notification = Ash.load!(notification, :webhooks)
    system_wh = Enum.find(notification.webhooks, &(&1.role == :system))

    DiscordDispatcher.invalidate_cache(map.id)

    %{map: map, notification: notification, system_wh: system_wh}
```

Add `MapDiscordWebhook` to the alias at line 6:

```elixir
  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
```

- [ ] **Step 7: Update `settle/1` and `refute_delivery/2` to look up workers by webhook id**

`WorkerSupervisor` is now keyed by webhook id (Task 4), so the helpers at lines 98-140 must look up the registry by webhook id, not map id. Change the two `Registry.lookup(WorkerSupervisor.registry(), map_id)` calls to take a webhook id, and update the three helper signatures:

```elixir
  # Dispatch is a cast and delivery is a second async hop, so tests synchronize
  # rather than guess: drain the dispatcher's mailbox, then the worker's.
  defp settle(webhook_id) do
    :sys.get_state(DiscordDispatcher)

    case Registry.lookup(WorkerSupervisor.registry(), webhook_id) do
      [{pid, _}] -> :sys.get_state(pid)
      [] -> :no_worker
    end
  end

  defp refute_delivery(webhook_id, timeout \\ 2_000) do
    settle(webhook_id)
    await_worker_idle(webhook_id, System.monotonic_time(:millisecond) + timeout)
    assert HttpStub.requests() == []
  end

  defp await_worker_idle(webhook_id, deadline) do
    case Registry.lookup(WorkerSupervisor.registry(), webhook_id) do
      [] ->
        :no_worker

      [{pid, _}] ->
        state = :sys.get_state(pid)

        cond do
          state.current == nil and state.queue_len == 0 ->
            :idle

          System.monotonic_time(:millisecond) >= deadline ->
            :timeout

          true ->
            Process.sleep(25)
            await_worker_idle(webhook_id, deadline)
        end
    end
  end
```

Then update every existing call site in the file to pass `system_wh.id` instead of `map.id`, destructuring `%{map: map, system_wh: system_wh}` in the tests that need it. The "no configuration" and "dedup is per-map" tests create their own maps and must create their own `:system` webhook rows the same way the setup does.

- [ ] **Step 8: Write the failing mixed-destination partition test**

Add to `test/unit/external_events/discord_dispatcher_test.exs`. This is the core §4.1 assertion: one batch, three fates.

```elixir
  defp character_webhook(notification, url \\ "https://discord.com/api/webhooks/456/chr") do
    {:ok, wh} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: url
      })

    wh
  end

  # `tracked_eve_ids/1` reads a cache keyed by map (Task 6). Seed it directly:
  # this file is about routing and batching, not about how the set is built.
  # The cache name MUST match Task 6's — Matcher reads
  # `:discord_notification_cache` under a namespaced key. Seeding a different
  # cache here would leave the tracked set empty, every kill would take the
  # `:not_involved` branch, and the routing tests would pass for the wrong
  # reason while asserting nothing.
  defp track(map_id, eve_ids) do
    Cachex.put(
      :discord_notification_cache,
      "map:#{map_id}:tracked_eve_ids",
      MapSet.new(eve_ids)
    )

    on_exit(fn -> WandererApp.ExternalEvents.Discord.Matcher.invalidate_tracked(map_id) end)
    :ok
  end

  defp killmail(id, overrides \\ %{}) do
    Factory.build(
      :killmail,
      Map.merge(
        %{
          solar_system_id: @wh_system,
          killmail_id: id,
          "victim_char_id" => 8000,
          "victim_corp_id" => 800_000,
          "attacker_char_ids" => [],
          "attacker_corp_ids" => []
        },
        overrides
      )
    )
  end

  test "a mixed batch splits across destinations and drops the rest", %{
    map: map,
    notification: n,
    system_wh: system_wh
  } do
    character_wh = character_webhook(n)
    track(map.id, [1001])

    {:ok, _} =
      MapDiscordNotification.update(n, %{wh_only: false, excluded_systems: [@ks_system]})

    DiscordDispatcher.invalidate_cache(map.id)

    # Involved (tracked victim) in an EXCLUDED system: the carve-out applies, so
    # it still goes to the character channel.
    involved =
      killmail(700_001, %{solar_system_id: @ks_system, "victim_char_id" => 1001})

    # Uninvolved, allowed system: system channel.
    uninvolved = killmail(700_002, %{solar_system_id: @wh_system})

    # Uninvolved, excluded system: dropped.
    dropped = killmail(700_003, %{solar_system_id: @ks_system})

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(
        Factory.build(:kill_event, %{
          solar_system_id: @wh_system,
          killmails: [involved, uninvolved, dropped]
        })
      )
    )

    settle(system_wh.id)
    settle(character_wh.id)

    requests = wait_for_requests(2)
    by_url = Enum.group_by(requests, &elem(&1, 0), &elem(&1, 1))

    assert [system_body] = by_url["https://discord.com/api/webhooks/123/tok"]
    assert [character_body] = by_url["https://discord.com/api/webhooks/456/chr"]

    assert length(system_body["embeds"]) == 1
    assert length(character_body["embeds"]) == 1

    # Exactly two messages: the third kill went nowhere.
    assert length(HttpStub.requests()) == 2
  end
```

- [ ] **Step 9: Run it to verify it fails**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs -k "a mixed batch splits across destinations"`
Expected: FAIL — only one request is made, to the system URL, because the dispatcher still formats and delivers the batch as a single unit.

- [ ] **Step 10: Rewrite the dispatcher's aliases and dispatch block**

Replace `lib/wanderer_app/external_events/discord_dispatcher.ex:46-48`:

```elixir
  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.ExternalEvents.Discord.{EmbedFormatter, Matcher, Router, SystemName}
  alias WandererApp.ExternalEvents.Discord.WorkerSupervisor
```

Replace `do_dispatch/2` at lines 148-180 with:

```elixir
  defp do_dispatch(map_id, %{type: :map_kill, payload: payload}) do
    with true <- enabled_globally?(),
         {:ok, notification} <- fetch_config(map_id),
         true <- notification.enabled?,
         {:ok, system_id, killmails} <- extract_kills(payload),
         [_ | _] = fresh <- reject_duplicates(map_id, killmails) do
      # System-level filtering used to happen here for the whole batch. It now
      # lives in `Router.route/3`, because `excluded_systems` and `wh_only` have
      # per-kill carve-outs for kills involving this map's own pilots.
      fresh
      |> partition(map_id, notification)
      |> Enum.each(fn {webhook, entries} ->
        deliver_partition(map_id, system_id, webhook, entries)
      end)

      :ok
    else
      _ -> :ok
    end
  end
```

- [ ] **Step 11: Add the partition step**

Add below `do_dispatch/2`:

```elixir
  # Routing is per kill, so a single `:map_kill` batch can now contain kills
  # bound for different destinations, or for none. Kills that drop belong to no
  # partition and are NEVER MARKED, so they stay eligible if they arrive again.
  #
  # Each entry keeps its verdict alongside the kill: the formatter needs it for
  # colouring and title (loss vs kill).
  defp partition(kills, map_id, notification) do
    tracked = Matcher.tracked_eve_ids(map_id)
    focus = notification.focus_corp_ids || []

    kills
    |> Enum.reduce(%{}, fn kill, acc ->
      verdict = Matcher.involvement(kill, tracked, focus)

      case Router.route(kill, notification, verdict) do
        {:ok, webhook} -> Map.update(acc, webhook, [{kill, verdict}], &[{kill, verdict} | &1])
        :drop -> acc
      end
    end)
    # Reduce prepends; restore the batch's original order per destination.
    |> Map.new(fn {webhook, entries} -> {webhook, Enum.reverse(entries)} end)
  end
```

- [ ] **Step 12: Add the per-partition delivery step**

Add below `partition/3`. Read the two marked comments before editing this function — the split here is the subtlest part of the whole change:

```elixir
  # Each non-empty partition is formatted and delivered independently.
  defp deliver_partition(map_id, system_id, webhook, entries) do
    # THE CAP IS PER DESTINATION, NOT PER EVENT. It is a Discord message-size
    # concern, so two destinations do not compete for one 30-kill budget.
    rendered = Enum.take(entries, EmbedFormatter.max_kills_per_event())
    marked = Enum.map(rendered, fn {kill, _verdict} -> kill end)

    # Marked before delivery: see the moduledoc — this is at-most-once by
    # choice, not an oversight. Only the kills the formatter will actually
    # render are marked; kills past the cap are never turned into a message, so
    # marking them would burn them for the full dedup TTL without ever sending
    # them.
    mark_attempted(map_id, marked)

    # Per-destination system-name policy is WHY formatting happens per partition
    # rather than once for the event.
    system_name = SystemName.display_name(map_id, system_id, webhook.role)

    # PASS THE WHOLE PARTITION, NOT `rendered`. The formatter applies the cap
    # itself and counts the remainder into its "…and N more kills not shown."
    # line. This mirrors the pre-split dispatcher exactly, where `formatted` was
    # marked but `fresh` was what reached `format_batch/2`. Handing the
    # formatter the pre-truncated list compiles, passes most tests, and silently
    # deletes the overflow line.
    entries
    |> EmbedFormatter.format_batch(system_name)
    |> then(&WorkerSupervisor.deliver(webhook.id, &1))
    |> handle_delivery_result(map_id, webhook.role, marked)
  end
```

- [ ] **Step 13: Make delivery-result handling per destination**

Replace lines 184-217 (`handle_delivery_result/3` and `emit_not_delivered/3`) with role-aware arity-4 versions. Telemetry counts are now emitted per destination with the role in the metadata, rather than once for the event. `{:error, :not_running}` releases only *this* partition's marks:

```elixir
  defp handle_delivery_result(:ok, map_id, role, kills) do
    :telemetry.execute(
      [:wanderer_app, :discord_dispatcher, :dispatched],
      %{count: length(kills)},
      %{map_id: map_id, role: role}
    )
  end

  # Nothing was enqueued, so no duplicate is possible: release this partition's
  # dedup marks so a later event carrying these kills can still be delivered
  # once the worker tree is up. Other partitions in the same event are
  # unaffected — their marks stand or fall on their own delivery result.
  defp handle_delivery_result({:error, :not_running}, map_id, role, kills) do
    unmark(map_id, kills)

    Logger.debug(fn ->
      "[Discord] worker infrastructure not running; dropped #{length(kills)} " <>
        "#{role} kills for map #{map_id}"
    end)

    emit_not_delivered(map_id, role, kills, :not_running)
  end

  defp handle_delivery_result({:error, reason}, map_id, role, kills) do
    Logger.warning(
      "[Discord] #{role} delivery enqueue failed for map #{map_id}: #{inspect(reason)}"
    )

    emit_not_delivered(map_id, role, kills, reason)
  end

  defp emit_not_delivered(map_id, role, kills, reason) do
    :telemetry.execute(
      [:wanderer_app, :discord_dispatcher, :not_delivered],
      %{count: length(kills)},
      %{map_id: map_id, role: role, reason: reason}
    )
  end
```

- [ ] **Step 14: Delete the now-dead batch-level helpers and annotate the dedup key**

Delete `system_allowed?/2` (lines 262-268) — `Router.route/3` owns those rules now, with per-kill carve-outs. Delete `system_name/1` (lines 293-298) — `SystemName.display_name/3` replaces it, per destination.

Replace `dedup_key/2` at line 291 with the same code plus its rationale:

```elixir
  # NOT role-scoped, deliberately: exactly one destination is chosen per kill,
  # so one key per (map, killmail) is exactly right. Should a future change ever
  # post one kill to BOTH channels, this key must gain the role — otherwise the
  # first post marks the kill and the second is silently suppressed.
  defp dedup_key(map_id, kill), do: "#{map_id}:#{kill["killmail_id"]}"
```

- [ ] **Step 15: Update the moduledoc's cap paragraph**

Replace lines 36-39:

```elixir
  The rationale covers losses to *delivery failure* only. Kills past the
  formatter's per-destination cap are never rendered into a message, so they are
  not marked at all and stay eligible if they arrive again. The same holds for
  kills the router drops: they belong to no partition and are never marked.
```

- [ ] **Step 16: Run the mixed-batch test to verify it passes**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs -k "a mixed batch splits across destinations"`
Expected: 1 test, 0 failures.

- [ ] **Step 17: Write the overflow test — 35 kills to ONE destination**

This is the exact bug the whole-partition rule prevents. If `deliver_partition/4` passes `rendered` to `format_batch/2`, the overflow line disappears and this fails.

```elixir
  test "the overflow line counts kills beyond the per-destination cap", %{
    map: map,
    notification: n,
    system_wh: system_wh
  } do
    {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
    DiscordDispatcher.invalidate_cache(map.id)
    track(map.id, [])

    cap = EmbedFormatter.max_kills_per_event()
    kills = for i <- 1..(cap + 5), do: killmail(710_000 + i)
    assert length(kills) == 35

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: kills}))
    )

    settle(system_wh.id)

    expected = ceil(cap / 10)
    requests = wait_for_requests(expected)

    contents = requests |> Enum.map(fn {_url, body} -> body["content"] end) |> Enum.reject(&is_nil/1)

    assert ["…and 5 more kills not shown."] == contents
  end
```

- [ ] **Step 18: Run it**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs -k "the overflow line counts kills"`
Expected: PASS with the implementation from Step 12. To confirm the test has teeth, temporarily change `entries` to `rendered` in the `format_batch/2` pipe and re-run — it must fail with `contents == []`. Revert.

- [ ] **Step 19: Write the "destinations do not share one budget" test**

```elixir
  test "two destinations each get their own cap budget", %{
    map: map,
    notification: n,
    system_wh: system_wh
  } do
    character_wh = character_webhook(n)
    track(map.id, [1001])

    {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
    DiscordDispatcher.invalidate_cache(map.id)

    cap = EmbedFormatter.max_kills_per_event()

    system_kills = for i <- 1..(cap + 5), do: killmail(720_000 + i)

    character_kills =
      for i <- 1..(cap + 5), do: killmail(730_000 + i, %{"victim_char_id" => 1001})

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(
        Factory.build(:kill_event, %{
          solar_system_id: @wh_system,
          killmails: system_kills ++ character_kills
        })
      )
    )

    settle(system_wh.id)
    settle(character_wh.id)

    per_destination = ceil(cap / 10)
    requests = wait_for_requests(per_destination * 2)
    by_url = Enum.group_by(requests, &elem(&1, 0), &elem(&1, 1))

    system_bodies = by_url["https://discord.com/api/webhooks/123/tok"]
    character_bodies = by_url["https://discord.com/api/webhooks/456/chr"]

    # Each destination renders a FULL cap of kills. A shared budget would give
    # one of them 30 and the other 0.
    assert Enum.sum(Enum.map(system_bodies, &length(&1["embeds"]))) == cap
    assert Enum.sum(Enum.map(character_bodies, &length(&1["embeds"]))) == cap

    # And each counts only its own overflow.
    assert Enum.any?(system_bodies, &(&1["content"] == "…and 5 more kills not shown."))
    assert Enum.any?(character_bodies, &(&1["content"] == "…and 5 more kills not shown."))
  end
```

- [ ] **Step 20: Run it**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs -k "two destinations each get their own cap budget"`
Expected: 1 test, 0 failures.

- [ ] **Step 21: Write the "dropped kills are not marked" test**

```elixir
  # A kill the router drops belongs to no partition, so it is never marked. If
  # it becomes routable later — the user removes the exclusion, or one of their
  # pilots turns up in it — it must still be deliverable.
  test "kills dropped by the router are not marked attempted", %{
    map: map,
    notification: n,
    system_wh: system_wh
  } do
    {:ok, _} =
      MapDiscordNotification.update(n, %{wh_only: false, excluded_systems: [@ks_system]})

    DiscordDispatcher.invalidate_cache(map.id)
    track(map.id, [])

    kill = killmail(740_001, %{solar_system_id: @ks_system})

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(Factory.build(:kill_event, %{solar_system_id: @ks_system, killmails: [kill]}))
    )

    :sys.get_state(DiscordDispatcher)
    assert HttpStub.requests() == []

    # Lift the exclusion; the same killmail must now be delivered.
    {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false, excluded_systems: []})
    DiscordDispatcher.invalidate_cache(map.id)

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(Factory.build(:kill_event, %{solar_system_id: @ks_system, killmails: [kill]}))
    )

    settle(system_wh.id)

    assert [{_url, body}] = wait_for_requests(1)
    assert length(body["embeds"]) == 1
  end
```

- [ ] **Step 22: Write the "disabled character webhook drops rather than rerouting" dispatcher test**

The Router unit test covers the decision; this covers the wiring end to end, because a reroute would show up here as a message on the system URL.

```elixir
  test "a disabled character webhook drops rather than rerouting", %{
    map: map,
    notification: n,
    system_wh: system_wh
  } do
    character_wh = character_webhook(n)
    {:ok, _} = MapDiscordWebhook.set_enabled(character_wh, %{enabled?: false})

    {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
    DiscordDispatcher.invalidate_cache(map.id)
    track(map.id, [1001])

    involved = killmail(750_001, %{"victim_char_id" => 1001})

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, killmails: [involved]}))
    )

    # Nothing anywhere — in particular, nothing on the system webhook.
    refute_delivery(system_wh.id)
  end
```

- [ ] **Step 23: Write the "`:not_running` releases only that partition's marks" test**

```elixir
  # Partition results are independent. Stopping the worker tree makes BOTH
  # partitions report `:not_running`, so this test instead disables the system
  # destination's worker path by asserting the narrower property: the marks
  # released belong to the failing partition only, verified by replaying just
  # that partition's kill and seeing it delivered while the other partition's
  # kill stays suppressed.
  test "not_running releases only the failing partition's marks", %{
    map: map,
    notification: n,
    system_wh: system_wh
  } do
    character_wh = character_webhook(n)
    {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
    DiscordDispatcher.invalidate_cache(map.id)
    track(map.id, [1001])

    system_kill = killmail(760_001)
    character_kill = killmail(760_002, %{"victim_char_id" => 1001})

    :ok = stop_supervised(WorkerSupervisor)

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(
        Factory.build(:kill_event, %{
          solar_system_id: @wh_system,
          killmails: [system_kill, character_kill]
        })
      )
    )

    :sys.get_state(DiscordDispatcher)
    assert HttpStub.requests() == []
    assert Process.alive?(Process.whereis(DiscordDispatcher))

    start_supervised!(WorkerSupervisor)

    # Both partitions were released, so both kills are still eligible and both
    # destinations receive one message.
    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(
        Factory.build(:kill_event, %{
          solar_system_id: @wh_system,
          killmails: [system_kill, character_kill]
        })
      )
    )

    settle(system_wh.id)
    settle(character_wh.id)

    requests = wait_for_requests(2)
    by_url = Enum.group_by(requests, &elem(&1, 0), &elem(&1, 1))

    assert [system_body] = by_url["https://discord.com/api/webhooks/123/tok"]
    assert [character_body] = by_url["https://discord.com/api/webhooks/456/chr"]
    assert length(system_body["embeds"]) == 1
    assert length(character_body["embeds"]) == 1
  end
```

- [ ] **Step 24: Add the telemetry-metadata test**

```elixir
  test "telemetry is emitted per destination with the role", %{
    map: map,
    notification: n,
    system_wh: system_wh
  } do
    character_wh = character_webhook(n)
    {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})
    DiscordDispatcher.invalidate_cache(map.id)
    track(map.id, [1001])

    test_pid = self()
    handler_id = "discord-role-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:wanderer_app, :discord_dispatcher, :dispatched],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:dispatched, metadata[:role], measurements[:count]})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    DiscordDispatcher.dispatch_event(
      map.id,
      kill_event(
        Factory.build(:kill_event, %{
          solar_system_id: @wh_system,
          killmails: [killmail(770_001), killmail(770_002, %{"victim_char_id" => 1001})]
        })
      )
    )

    settle(system_wh.id)
    settle(character_wh.id)

    assert_receive {:dispatched, :system, 1}
    assert_receive {:dispatched, :character, 1}
  end
```

- [ ] **Step 25: Run the whole dispatcher suite**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs`
Expected: 0 failures, including every pre-existing test (gate off, kill_count events, wh_only, exclusions, dedup per map, the formatter-cap test at lines 343-381, and the three `send_test_message` tests).

- [ ] **Step 26: Run the surrounding suites for regressions**

Run: `mix test test/unit/external_events/ && mix format --check-formatted && mix credo --strict`
Expected: 0 failures, formatted, no new credo issues.

- [ ] **Step 27: Commit**

Run: `git add lib/wanderer_app/external_events/discord_dispatcher.ex test/unit/external_events/discord_dispatcher_test.exs && git commit -m "Partition Discord kill batches per destination"`

## Phase C — Embeds and the privacy constraint (Tasks 9–10)

Rewrites the embed for parity with wanderer-notifier, and introduces the role-aware system name resolver that enforces the map-local-names privacy boundary.

### Task 9: EmbedFormatter rewrite

**Files:**
- Modify: `lib/wanderer_app/external_events/discord/embed_formatter.ex:1-156` (whole file)
- Test: `test/unit/external_events/discord/embed_formatter_test.exs` (whole file rewritten)

**Interfaces:**
- Consumes: `WandererApp.ExternalEvents.Discord.Matcher.involvement/3` verdict values —
  `{:involved, :victim} | {:involved, :attacker} | :not_involved` (Phase B, CONTRACT.md).
  Consumes the Phase B kill keys `top_damage_char_id`, `top_damage_char_name`
  (CONTRACT.md "Kill payload keys added by Phase B").
- Produces:
  - `EmbedFormatter.format_batch([{kill :: map(), verdict}], system_name :: String.t() | nil) :: [map()]`
  - `EmbedFormatter.format_kill(kill :: map(), verdict, system_name :: String.t() | nil) :: map()`
  - `EmbedFormatter.max_kills_per_event() :: pos_integer()` (unchanged, arity 0, still 30)
  - `EmbedFormatter.format_isk(number() | nil) :: String.t() | nil` (unchanged, kept verbatim)

Background you need before starting:

- The current file is 156 lines. `@max_embeds_per_message 10` (line 10),
  `@max_kills_per_event 30` (line 11), `@color 0xD9534F` (line 12), the `@isk_units`
  table (lines 21-26), `format_batch/2` (lines 36-51), `append_overflow/2`
  (lines 53-58), `format_kill/2` (lines 60-75). `format_isk/1` and its helpers
  (lines 112-145) are kept **verbatim** — do not touch them, they have their own
  boundary tests that must keep passing.
- Available kill keys come from `WandererApp.Kills.MessageHandler`:
  `victim_char_id`, `victim_char_name`, `victim_corp_id`, `victim_corp_ticker`,
  `victim_corp_name`, `victim_alliance_*`, `victim_ship_type_id`,
  `victim_ship_name` (`kills/message_handler.ex:304-320`); `final_blow_char_id`,
  `final_blow_char_name`, `final_blow_corp_id`, `final_blow_corp_ticker`,
  `final_blow_corp_name`, `final_blow_ship_*` (`kills/message_handler.ex:322-338`);
  `attacker_count`, `total_value`, `npc` (`kills/message_handler.ex:340-347`).
- The test factory builds a flattened kill at `test/support/factory.ex:895-927`.
  Its defaults are: victim `90_000_001` "Test Victim", corp `98_000_001` "TSTC",
  ship type `626` "Vexor", final blow `90_000_002` "Test Attacker", corp
  `98_000_002` "ATKC", `attacker_count` 3, `total_value` 84_000_000.
  **The factory does not define `top_damage_*` keys** unless Phase B added them.
  Every test below that depends on the presence *or absence* of a top-damage
  pilot therefore sets those keys explicitly, so the tests do not silently change
  meaning depending on what Phase B did to the factory.

---

- [ ] **Step 1: Write the failing colour and signature tests**

Replace the whole of `test/unit/external_events/discord/embed_formatter_test.exs`
with this. It keeps the three `format_isk/1` boundary tests verbatim from the
current file (lines 70-128) because `format_isk/1` is unchanged and those tests
must keep passing.

```elixir
defmodule WandererApp.ExternalEvents.Discord.EmbedFormatterTest do
  use ExUnit.Case, async: true

  alias WandererApp.ExternalEvents.Discord.EmbedFormatter
  alias WandererAppWeb.Factory

  @loss {:involved, :victim}
  @kill {:involved, :attacker}
  @bystander :not_involved

  describe "colour" do
    test "a loss is red" do
      kill = Factory.build(:killmail)
      assert EmbedFormatter.format_kill(kill, @loss, "J123456")["color"] == 0xE74C3C
    end

    test "a kill is green" do
      kill = Factory.build(:killmail)
      assert EmbedFormatter.format_kill(kill, @kill, "J123456")["color"] == 0x2ECC71
    end

    test "an uninvolved kill is coloured by ISK tier" do
      tiers = [
        {5_000_000_000, 0xFF0000},
        {9_999_999_999, 0xFF0000},
        {4_999_999_999, 0xFF6600},
        {1_000_000_000, 0xFF6600},
        {999_999_999, 0xFFFF00},
        {100_000_000, 0xFFFF00},
        {99_999_999, 0x00FF00},
        {10_000_000, 0x00FF00},
        {9_999_999, 0x808080},
        {0, 0x808080}
      ]

      Enum.each(tiers, fn {value, expected} ->
        kill = Factory.build(:killmail, %{"total_value" => value})
        actual = EmbedFormatter.format_kill(kill, @bystander, "J123456")["color"]

        assert actual == expected,
               "total_value #{value} coloured #{inspect(actual, base: :hex)}, " <>
                 "expected #{inspect(expected, base: :hex)}"
      end)
    end

    test "an uninvolved kill with no value falls to the default grey" do
      kill = Factory.build(:killmail, %{"total_value" => nil})
      assert EmbedFormatter.format_kill(kill, @bystander, "J123456")["color"] == 0x808080
    end

    test "the loss colour and the kill colour do not depend on ISK value" do
      cheap = Factory.build(:killmail, %{"total_value" => 1})
      rich = Factory.build(:killmail, %{"total_value" => 9_000_000_000})

      assert EmbedFormatter.format_kill(cheap, @loss, "J")["color"] ==
               EmbedFormatter.format_kill(rich, @loss, "J")["color"]

      assert EmbedFormatter.format_kill(cheap, @kill, "J")["color"] ==
               EmbedFormatter.format_kill(rich, @kill, "J")["color"]
    end
  end

  describe "format_isk/1" do
    test "handles ISK formatting boundary values correctly" do
      test_cases = [
        {0, "0 ISK"},
        {999, "999 ISK"},
        {1_000, "1.0K ISK"},
        {999_999, "1.0M ISK"},
        {1_000_000, "1.0M ISK"},
        {999_999_999, "1.0B ISK"},
        {1_500_000_000, "1.5B ISK"},
        {nil, nil}
      ]

      Enum.each(test_cases, fn {value, expected} ->
        actual = EmbedFormatter.format_isk(value)

        assert actual == expected,
               "format_isk(#{inspect(value)}) returned #{inspect(actual)}, expected #{inspect(expected)}"
      end)
    end

    test "handles trillion-ISK values correctly (supercapital/structure kills)" do
      test_cases = [
        {999_999_999_999, "1.0T ISK"},
        {1_000_000_000_000, "1.0T ISK"},
        {5_000_000_000_000, "5.0T ISK"}
      ]

      Enum.each(test_cases, fn {value, expected} ->
        actual = EmbedFormatter.format_isk(value)

        assert actual == expected,
               "format_isk(#{inspect(value)}) returned #{inspect(actual)}, expected #{inspect(expected)}"
      end)
    end

    test "clamps at trillion unit (does not underreport above 1 quadrillion)" do
      test_cases = [
        {100_000_000_000_000, "100.0T ISK"},
        {999_000_000_000_000, "999.0T ISK"},
        {1_000_000_000_000_000, "1000.0T ISK"},
        {999_999_999_999_999, "1000.0T ISK"}
      ]

      Enum.each(test_cases, fn {value, expected} ->
        actual = EmbedFormatter.format_isk(value)

        assert actual == expected,
               "format_isk(#{inspect(value)}) returned #{inspect(actual)}, expected #{inspect(expected)}"
      end)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

Expected: FAIL with `undefined function EmbedFormatter.format_kill/3` (the current
module defines `format_kill/2`). The three `format_isk/1` describes pass.

- [ ] **Step 3: Rewrite the module head, colours, and the two public signatures**

Replace lines 1-110 of `lib/wanderer_app/external_events/discord/embed_formatter.ex`
(everything above `@doc false def format_isk(nil)` on line 113) with this. Lines
112-155 — `format_isk/1`, `format_at_unit/2`, `format_float/1`, `round_to/1`,
`present/1`, `maybe_put/3`, `drop_nils/1` — stay exactly as they are.

```elixir
defmodule WandererApp.ExternalEvents.Discord.EmbedFormatter do
  @moduledoc """
  Turns flattened killmails into Discord message bodies.

  Only `killmail_id`, `kill_time` and `solar_system_id` are guaranteed present
  on a killmail (see `WandererApp.Kills.MessageHandler`), so every other field
  is rendered defensively.

  Each kill arrives paired with the involvement verdict from
  `WandererApp.ExternalEvents.Discord.Matcher.involvement/3`. The verdict, not
  the payload, decides the colour and the author line.
  """

  @type verdict :: {:involved, :victim} | {:involved, :attacker} | :not_involved

  @max_embeds_per_message 10
  @max_kills_per_event 30

  @color_loss 0xE74C3C
  @color_kill 0x2ECC71

  # ISK tiers for kills involving nobody we track, largest first.
  #
  # NOTE: @color_kill (0x2ECC71) and the 10M tier (0x00FF00) are both green.
  # They are *distinct meanings* that happen to share a hue — "you killed
  # something" versus "a bystander kill worth 10M-100M" — and they are
  # disambiguated by the author line, which is present on a kill and absent on
  # an uninvolved embed. Do not collapse these two constants into one.
  @value_colors [
    {5_000_000_000, 0xFF0000},
    {1_000_000_000, 0xFF6600},
    {100_000_000, 0xFFFF00},
    {10_000_000, 0x00FF00}
  ]
  @color_default 0x808080

  @zkill_base "https://zkillboard.com"
  @image_base "https://images.evetech.net"
  @thumbnail_size 1024

  @doc """
  The per-event kill cap. Exposed so callers can tell which kills were actually
  formatted — the dispatcher must not mark kills past this cap as attempted,
  since they are never rendered into a message.
  """
  @spec max_kills_per_event() :: pos_integer()
  def max_kills_per_event, do: @max_kills_per_event

  @spec format_batch([{map(), verdict()}], String.t() | nil) :: [map()]
  def format_batch([], _system_name), do: []

  def format_batch(entries, system_name) do
    total = length(entries)
    shown = Enum.take(entries, @max_kills_per_event)
    overflow = total - length(shown)

    messages =
      shown
      |> Enum.map(fn {kill, verdict} -> format_kill(kill, verdict, system_name) end)
      |> Enum.chunk_every(@max_embeds_per_message)
      |> Enum.map(&%{"embeds" => &1})

    append_overflow(messages, overflow)
  end

  defp append_overflow(messages, overflow) when overflow <= 0, do: messages

  defp append_overflow(messages, overflow) do
    {init, [last]} = Enum.split(messages, -1)
    init ++ [Map.put(last, "content", "…and #{overflow} more kills not shown.")]
  end

  @spec format_kill(map(), verdict(), String.t() | nil) :: map()
  def format_kill(kill, verdict, system_name) do
    %{
      "title" => title(kill, system_name),
      "url" => zkill_url(kill["killmail_id"]),
      "color" => color(verdict, kill["total_value"])
    }
    |> drop_nils()
  end

  defp title(kill, system_name) do
    ship = present(kill["victim_ship_name"]) || "Unknown ship"
    system = present(system_name) || "Unknown system"
    "#{ship} destroyed in #{system}"
  end

  defp color({:involved, :victim}, _value), do: @color_loss
  defp color({:involved, :attacker}, _value), do: @color_kill

  defp color(:not_involved, value) when is_number(value) do
    Enum.find_value(@value_colors, @color_default, fn {threshold, color} ->
      if value >= threshold, do: color
    end)
  end

  defp color(:not_involved, _value), do: @color_default

  defp zkill_url(nil), do: nil
  defp zkill_url(id), do: "#{@zkill_base}/kill/#{id}/"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

Expected: all colour tests and all three `format_isk/1` tests pass.

- [ ] **Step 5: Write the failing author-line tests**

Append this describe block to the test file, before the closing `end`.

```elixir
  describe "author line" do
    test "a loss is labelled Loss and carries the victim's corp logo" do
      kill = Factory.build(:killmail, %{"victim_corp_id" => 98_000_001})
      author = EmbedFormatter.format_kill(kill, @loss, "J123456")["author"]

      assert author["name"] == "Loss"
      assert author["icon_url"] == "https://images.evetech.net/corporations/98000001/logo?size=64"
    end

    test "a kill is labelled Kill and carries the final-blow pilot's corp logo" do
      kill = Factory.build(:killmail, %{"final_blow_corp_id" => 98_000_002})
      author = EmbedFormatter.format_kill(kill, @kill, "J123456")["author"]

      assert author["name"] == "Kill"
      assert author["icon_url"] == "https://images.evetech.net/corporations/98000002/logo?size=64"
    end

    test "the author line is omitted entirely when not involved" do
      kill = Factory.build(:killmail)
      embed = EmbedFormatter.format_kill(kill, @bystander, "J123456")

      refute Map.has_key?(embed, "author")
    end

    test "the label survives a missing corp id, without a logo" do
      kill = Factory.build(:killmail, %{"victim_corp_id" => nil})
      author = EmbedFormatter.format_kill(kill, @loss, "J123456")["author"]

      assert author == %{"name" => "Loss"}
    end
  end
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

Expected: FAIL — `author["name"]` raises on `nil` because the embed has no
`"author"` key yet.

- [ ] **Step 7: Implement the author line**

In `format_kill/3`, pipe the base map through `maybe_put("author", ...)` before
`drop_nils/1`:

```elixir
  @spec format_kill(map(), verdict(), String.t() | nil) :: map()
  def format_kill(kill, verdict, system_name) do
    %{
      "title" => title(kill, system_name),
      "url" => zkill_url(kill["killmail_id"]),
      "color" => color(verdict, kill["total_value"])
    }
    |> maybe_put("author", author(kill, verdict))
    |> drop_nils()
  end
```

And add these clauses immediately after `color/2`:

```elixir
  # Omitted entirely when we are not involved: neither "Kill" nor "Loss" would
  # be a true statement about a fight none of our pilots were in.
  defp author(_kill, :not_involved), do: nil
  defp author(kill, {:involved, :victim}), do: author_line("Loss", kill["victim_corp_id"])
  defp author(kill, {:involved, :attacker}), do: author_line("Kill", kill["final_blow_corp_id"])

  defp author_line(label, corp_id) when is_integer(corp_id) do
    %{
      "name" => label,
      "icon_url" => "#{@image_base}/corporations/#{corp_id}/logo?size=64"
    }
  end

  defp author_line(label, _corp_id), do: %{"name" => label}
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

- [ ] **Step 9: Write the failing title and description-prose tests**

Append this describe block to the test file.

```elixir
  describe "title and description prose" do
    test "the title names the ship and the system it died in" do
      kill = Factory.build(:killmail, %{"victim_ship_name" => "Vexor"})
      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      assert embed["title"] == "Vexor destroyed in Home"
    end

    test "the title survives a missing ship name and a missing system name" do
      kill = Factory.build(:killmail, %{"victim_ship_name" => nil})
      embed = EmbedFormatter.format_kill(kill, @loss, nil)

      assert embed["title"] == "Unknown ship destroyed in Unknown system"
    end

    test "the prose links every name to zKillboard" do
      kill =
        Factory.build(:killmail, %{
          "victim_char_id" => 90_000_001,
          "victim_char_name" => "Test Victim",
          "victim_corp_id" => 98_000_001,
          "victim_corp_ticker" => "TSTC",
          "victim_ship_name" => "Vexor",
          "final_blow_char_id" => 90_000_002,
          "final_blow_char_name" => "Test Attacker",
          "final_blow_corp_id" => 98_000_002,
          "final_blow_corp_ticker" => "ATKC",
          "top_damage_char_id" => 90_000_003,
          "top_damage_char_name" => "Top Gun",
          "attacker_count" => 5
        })

      assert EmbedFormatter.format_kill(kill, @loss, "Home")["description"] ==
               "**[Test Victim](https://zkillboard.com/character/90000001/)** " <>
                 "(**[TSTC](https://zkillboard.com/corporation/98000001/)**) " <>
                 "lost their **Vexor** to " <>
                 "**[Test Attacker](https://zkillboard.com/character/90000002/)** " <>
                 "(**[ATKC](https://zkillboard.com/corporation/98000002/)**), " <>
                 "top damage by **[Top Gun](https://zkillboard.com/character/90000003/)**, " <>
                 "and 3 others."
    end

    test "top damage is not named when it is the final-blow pilot" do
      kill =
        Factory.build(:killmail, %{
          "final_blow_char_id" => 90_000_002,
          "final_blow_char_name" => "Test Attacker",
          "top_damage_char_id" => 90_000_002,
          "top_damage_char_name" => "Test Attacker",
          "attacker_count" => 3
        })

      description = EmbedFormatter.format_kill(kill, @loss, "Home")["description"]

      refute description =~ "top damage"
      assert description =~ "and 2 others."
    end

    test "a solo kill omits the others clause" do
      kill =
        Factory.build(:killmail, %{
          "attacker_count" => 1,
          "final_blow_char_id" => 90_000_002,
          "final_blow_char_name" => "Test Attacker",
          "top_damage_char_id" => 90_000_002,
          "top_damage_char_name" => "Test Attacker"
        })

      description = EmbedFormatter.format_kill(kill, @loss, "Home")["description"]

      refute description =~ "others"
      refute description =~ "other."
      assert description =~ "lost their **Vexor** to **[Test Attacker]"
    end

    test "a single unnamed extra attacker reads 'other', not 'others'" do
      kill =
        Factory.build(:killmail, %{
          "attacker_count" => 2,
          "final_blow_char_id" => 90_000_002,
          "final_blow_char_name" => "Test Attacker",
          "top_damage_char_id" => 90_000_002,
          "top_damage_char_name" => "Test Attacker"
        })

      assert EmbedFormatter.format_kill(kill, @loss, "Home")["description"] =~ "and 1 other."
    end

    test "an NPC final blow renders as absent, not as a placeholder name" do
      kill =
        Factory.build(:killmail, %{
          "npc" => true,
          "attacker_count" => 1,
          "final_blow_char_id" => nil,
          "final_blow_char_name" => nil,
          "final_blow_corp_id" => nil,
          "final_blow_corp_ticker" => nil,
          "top_damage_char_id" => nil,
          "top_damage_char_name" => nil
        })

      description = EmbedFormatter.format_kill(kill, @bystander, "Home")["description"]

      assert description == "**[Test Victim](https://zkillboard.com/character/90000001/)** " <>
                              "(**[TSTC](https://zkillboard.com/corporation/98000001/)**) " <>
                              "lost their **Vexor**."

      refute description =~ "Unknown"
      refute description =~ "nil"
    end

    test "names render unlinked when the id is missing" do
      kill =
        Factory.build(:killmail, %{
          "victim_char_id" => nil,
          "victim_corp_id" => nil,
          "final_blow_char_id" => nil,
          "top_damage_char_id" => nil,
          "top_damage_char_name" => nil,
          "attacker_count" => 1
        })

      assert EmbedFormatter.format_kill(kill, @loss, "Home")["description"] ==
               "**Test Victim** (**TSTC**) lost their **Vexor** to **Test Attacker** (**ATKC**)."
    end

    test "a missing victim name does not leak the word nil" do
      kill =
        Factory.build(:killmail, %{
          "victim_char_id" => nil,
          "victim_char_name" => nil,
          "victim_corp_ticker" => nil,
          "top_damage_char_id" => nil,
          "top_damage_char_name" => nil
        })

      description = EmbedFormatter.format_kill(kill, @loss, "Home")["description"]

      assert description =~ "**Unknown pilot** lost their **Vexor**"
      refute description =~ "nil"
    end
  end
```

- [ ] **Step 10: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

Expected: the title tests pass; every description test FAILs with the embed
having no `"description"` key (`nil =~ "..."` raises `FunctionClauseError`, or
the equality assertion reports `nil`).

- [ ] **Step 11: Implement the description prose**

Add `"description" => description(kill)` to the base map in `format_kill/3`:

```elixir
    %{
      "title" => title(kill, system_name),
      "url" => zkill_url(kill["killmail_id"]),
      "color" => color(verdict, kill["total_value"]),
      "description" => description(kill)
    }
```

Add these functions after `author_line/2`:

```elixir
  # Prose, not a field grid. Each clause carries its own leading separator and
  # returns nil when the underlying data is absent, so an NPC kill simply reads
  # "X lost their Y." rather than naming a placeholder attacker.
  defp description(kill) do
    [
      victim_clause(kill),
      final_blow_clause(kill),
      top_damage_clause(kill),
      others_clause(kill)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
    |> Kernel.<>(".")
  end

  defp victim_clause(kill) do
    pilot =
      character_link(kill["victim_char_id"], present(kill["victim_char_name"]) || "Unknown pilot")

    ship = present(kill["victim_ship_name"]) || "Unknown ship"

    case corporation_link(kill["victim_corp_id"], present(kill["victim_corp_ticker"])) do
      nil -> "#{pilot} lost their **#{ship}**"
      corp -> "#{pilot} (#{corp}) lost their **#{ship}**"
    end
  end

  defp final_blow_clause(kill) do
    case present(kill["final_blow_char_name"]) do
      nil ->
        nil

      name ->
        pilot = character_link(kill["final_blow_char_id"], name)

        case corporation_link(kill["final_blow_corp_id"], present(kill["final_blow_corp_ticker"])) do
          nil -> " to #{pilot}"
          corp -> " to #{pilot} (#{corp})"
        end
    end
  end

  defp top_damage_clause(kill) do
    with name when not is_nil(name) <- present(kill["top_damage_char_name"]),
         true <- distinct_from_final_blow?(kill) do
      ", top damage by #{character_link(kill["top_damage_char_id"], name)}"
    else
      _ -> nil
    end
  end

  # Ids are authoritative when both are present; names are the fallback for
  # payloads that carry one without the other.
  defp distinct_from_final_blow?(kill) do
    case {kill["final_blow_char_id"], kill["top_damage_char_id"]} do
      {fb, td} when is_integer(fb) and is_integer(td) ->
        fb != td

      _ ->
        present(kill["final_blow_char_name"]) != present(kill["top_damage_char_name"])
    end
  end

  defp others_clause(kill) do
    named = named_attacker_count(kill)

    case kill["attacker_count"] do
      count when is_integer(count) and count - named == 1 -> ", and 1 other"
      count when is_integer(count) and count - named > 1 -> ", and #{count - named} others"
      _ -> nil
    end
  end

  defp named_attacker_count(kill) do
    final_blow = if present(kill["final_blow_char_name"]), do: 1, else: 0

    top_damage =
      if present(kill["top_damage_char_name"]) && distinct_from_final_blow?(kill), do: 1, else: 0

    final_blow + top_damage
  end

  defp character_link(id, name) when is_integer(id),
    do: "**[#{name}](#{@zkill_base}/character/#{id}/)**"

  defp character_link(_id, name), do: "**#{name}**"

  defp corporation_link(_id, nil), do: nil

  defp corporation_link(id, ticker) when is_integer(id),
    do: "**[#{ticker}](#{@zkill_base}/corporation/#{id}/)**"

  defp corporation_link(_id, ticker), do: "**#{ticker}**"
```

- [ ] **Step 12: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

- [ ] **Step 13: Write the failing Value/When field tests**

Append this describe block to the test file.

```elixir
  describe "fields" do
    test "carries exactly Value and When, both inline" do
      kill = Factory.build(:killmail, %{"total_value" => 84_000_000})
      fields = EmbedFormatter.format_kill(kill, @loss, "Home")["fields"]

      assert Enum.map(fields, & &1["name"]) == ["Value", "When"]
      assert Enum.all?(fields, & &1["inline"])
    end

    test "Value uses the existing ISK formatter" do
      kill = Factory.build(:killmail, %{"total_value" => 84_000_000})
      fields = EmbedFormatter.format_kill(kill, @loss, "Home")["fields"]

      assert Enum.find(fields, &(&1["name"] == "Value"))["value"] == "84.0M ISK"
    end

    test "When is a Discord relative timestamp derived from kill_time" do
      kill = Factory.build(:killmail, %{"kill_time" => "2026-08-01T12:00:00Z"})
      fields = EmbedFormatter.format_kill(kill, @loss, "Home")["fields"]

      unix = DateTime.to_unix(~U[2026-08-01 12:00:00Z])
      assert Enum.find(fields, &(&1["name"] == "When"))["value"] == "<t:#{unix}:R>"
    end

    test "an unparseable kill_time drops the When field rather than rendering junk" do
      kill = Factory.build(:killmail, %{"kill_time" => "not a timestamp"})
      fields = EmbedFormatter.format_kill(kill, @loss, "Home")["fields"]

      assert Enum.map(fields, & &1["name"]) == ["Value"]
    end

    test "a nil total_value drops the Value field" do
      kill = Factory.build(:killmail, %{"total_value" => nil})
      fields = EmbedFormatter.format_kill(kill, @loss, "Home")["fields"]

      assert Enum.map(fields, & &1["name"]) == ["When"]
    end

    test "the system name is no longer a field — it is in the title" do
      kill = Factory.build(:killmail)
      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      refute Enum.any?(embed["fields"], &(&1["name"] == "System"))
      assert embed["title"] =~ "Home"
    end
  end
```

- [ ] **Step 14: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

Expected: FAIL — `Enum.map(nil, ...)` raises, since the embed has no `"fields"`
key yet.

- [ ] **Step 15: Implement the Value and When fields**

Add `"fields" => fields(kill)` to the base map in `format_kill/3`:

```elixir
    %{
      "title" => title(kill, system_name),
      "url" => zkill_url(kill["killmail_id"]),
      "color" => color(verdict, kill["total_value"]),
      "description" => description(kill),
      "fields" => fields(kill)
    }
```

Add these functions after `corporation_link/2`. Note there is deliberately no
top-level `"timestamp"` key any more: the `When` field replaces it, and carrying
both would render the same instant twice in one embed.

```elixir
  defp fields(kill) do
    [
      field("Value", format_isk(kill["total_value"]), true),
      field("When", relative_time(kill["kill_time"]), true)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp field(_name, nil, _inline), do: nil
  defp field(name, value, inline), do: %{"name" => name, "value" => value, "inline" => inline}

  # `<t:unix:R>` renders client-side as "3 hours ago", in the reader's own
  # timezone. An unparseable kill_time drops the field rather than guessing.
  defp relative_time(kill_time) when is_binary(kill_time) do
    case DateTime.from_iso8601(kill_time) do
      {:ok, datetime, _offset} -> "<t:#{DateTime.to_unix(datetime)}:R>"
      _ -> nil
    end
  end

  defp relative_time(%DateTime{} = datetime), do: "<t:#{DateTime.to_unix(datetime)}:R>"

  defp relative_time(%NaiveDateTime{} = naive),
    do: relative_time(DateTime.from_naive!(naive, "Etc/UTC"))

  defp relative_time(unix) when is_integer(unix), do: "<t:#{unix}:R>"
  defp relative_time(_), do: nil
```

- [ ] **Step 16: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

- [ ] **Step 17: Write the failing thumbnail and footer tests**

Append this describe block to the test file.

```elixir
  describe "thumbnail and footer" do
    test "renders a 1024px ship render when the ship type id is present" do
      kill = Factory.build(:killmail, %{"victim_ship_type_id" => 626})
      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      assert embed["thumbnail"]["url"] ==
               "https://images.evetech.net/types/626/render?size=1024"
    end

    test "falls back to the character portrait when the ship type id is absent" do
      kill =
        Factory.build(:killmail, %{
          "victim_ship_type_id" => nil,
          "victim_char_id" => 90_000_001
        })

      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      assert embed["thumbnail"]["url"] ==
               "https://images.evetech.net/characters/90000001/portrait?size=1024"
    end

    test "omits the thumbnail when neither ship type nor character id is present" do
      kill =
        Factory.build(:killmail, %{
          "victim_ship_type_id" => nil,
          "victim_char_id" => nil
        })

      refute Map.has_key?(EmbedFormatter.format_kill(kill, @loss, "Home"), "thumbnail")
    end

    test "prefers the ship render even when a character id is also present" do
      kill =
        Factory.build(:killmail, %{
          "victim_ship_type_id" => 626,
          "victim_char_id" => 90_000_001
        })

      assert EmbedFormatter.format_kill(kill, @loss, "Home")["thumbnail"]["url"] =~ "/types/626/"
    end

    test "the footer carries the killmail id" do
      kill = Factory.build(:killmail, %{"killmail_id" => 12_345})
      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      assert embed["footer"] == %{"text" => "Killmail ID: 12345"}
      assert embed["url"] == "https://zkillboard.com/kill/12345/"
    end

    test "the corp ticker is no longer in the footer" do
      kill = Factory.build(:killmail, %{"victim_corp_ticker" => "TSTC"})
      embed = EmbedFormatter.format_kill(kill, @loss, "Home")

      refute embed["footer"]["text"] =~ "TSTC"
      assert embed["description"] =~ "TSTC"
    end

    test "is JSON-encodable and never leaks the word nil" do
      kill =
        Factory.build(:killmail, %{
          "victim_char_name" => nil,
          "victim_corp_name" => nil,
          "victim_corp_ticker" => nil,
          "victim_alliance_name" => nil,
          "victim_ship_name" => nil,
          "victim_ship_type_id" => nil,
          "victim_char_id" => nil,
          "final_blow_char_name" => nil,
          "top_damage_char_name" => nil,
          "total_value" => nil,
          "kill_time" => nil
        })

      embed = EmbedFormatter.format_kill(kill, @bystander, nil)

      assert {:ok, json} = Jason.encode(embed)
      refute json =~ "nil"
    end
  end
```

- [ ] **Step 18: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

Expected: FAIL — the embed has no `"thumbnail"` or `"footer"` key.

- [ ] **Step 19: Implement the thumbnail and the footer**

Extend the pipeline in `format_kill/3`:

```elixir
    |> maybe_put("author", author(kill, verdict))
    |> maybe_put("thumbnail", thumbnail(kill))
    |> maybe_put("footer", footer(kill))
    |> drop_nils()
```

Add these functions after `relative_time/1`:

```elixir
  # Selection is on FIELD PRESENCE ONLY. This is *not* a 404 fallback: Discord
  # fetches the image itself when it renders the embed, so a failed fetch is
  # never observable from here and cannot be reacted to. If the ship type id is
  # present we use the ship render even if that render happens not to exist
  # upstream; the character portrait is only for kills that carry no ship type.
  defp thumbnail(kill) do
    cond do
      is_integer(kill["victim_ship_type_id"]) ->
        %{"url" => "#{@image_base}/types/#{kill["victim_ship_type_id"]}/render?size=#{@thumbnail_size}"}

      is_integer(kill["victim_char_id"]) ->
        %{
          "url" =>
            "#{@image_base}/characters/#{kill["victim_char_id"]}/portrait?size=#{@thumbnail_size}"
        }

      true ->
        nil
    end
  end

  defp footer(kill) do
    case kill["killmail_id"] do
      nil -> nil
      id -> %{"text" => "Killmail ID: #{id}"}
    end
  end
```

- [ ] **Step 20: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

- [ ] **Step 21: Write the failing batching tests for the tuple input**

Append this describe block to the test file.

```elixir
  describe "format_batch/2" do
    defp entries(count, verdict \\ :not_involved) do
      for _ <- 1..count, do: {Factory.build(:killmail), verdict}
    end

    test "single message for 10 or fewer kills" do
      assert [%{"embeds" => embeds}] = EmbedFormatter.format_batch(entries(10), "J123456")
      assert length(embeds) == 10
    end

    test "chunks into messages of at most 10 embeds" do
      messages = EmbedFormatter.format_batch(entries(25), "J123456")

      assert length(messages) == 3
      assert Enum.all?(messages, &(length(&1["embeds"]) <= 10))
      assert messages |> Enum.map(&length(&1["embeds"])) |> Enum.sum() == 25
    end

    test "caps at 30 kills and notes the overflow" do
      messages = EmbedFormatter.format_batch(entries(42), "J123456")

      assert messages |> Enum.map(&length(&1["embeds"])) |> Enum.sum() == 30
      assert List.last(messages)["content"] =~ "12 more"
    end

    test "exactly 30 kills has no overflow notation" do
      messages = EmbedFormatter.format_batch(entries(30), "J123456")

      assert messages |> Enum.map(&length(&1["embeds"])) |> Enum.sum() == 30
      refute Map.has_key?(List.last(messages), "content")
    end

    test "returns empty list for no kills" do
      assert EmbedFormatter.format_batch([], "J123456") == []
    end

    test "each kill is coloured by its own verdict within one batch" do
      batch = [
        {Factory.build(:killmail), {:involved, :victim}},
        {Factory.build(:killmail), {:involved, :attacker}},
        {Factory.build(:killmail, %{"total_value" => 1_000}), :not_involved}
      ]

      [%{"embeds" => embeds}] = EmbedFormatter.format_batch(batch, "J123456")

      assert Enum.map(embeds, & &1["color"]) == [0xE74C3C, 0x2ECC71, 0x808080]
    end

    test "every embed in a batch carries the same system name" do
      [%{"embeds" => embeds}] = EmbedFormatter.format_batch(entries(3), "Home")

      assert Enum.all?(embeds, &(&1["title"] =~ "destroyed in Home"))
    end

    test "max_kills_per_event/0 is still 30" do
      assert EmbedFormatter.max_kills_per_event() == 30
    end
  end
```

- [ ] **Step 22: Run the test to verify it fails or passes**

Run: `mix test test/unit/external_events/discord/embed_formatter_test.exs`

Expected: PASS — `format_batch/2` was already rewritten for tuples in Step 3.
If anything fails here it is a real defect in Step 3's `format_batch/2`; fix it
before continuing rather than adjusting the test.

- [ ] **Step 23: Confirm no caller still uses the old arities**

Run: `grep -rn "format_kill\|format_batch" lib test | grep -v embed_formatter`

Expected: the only hits are in `lib/wanderer_app/external_events/discord_dispatcher.ex`
and its test, which Phase B already moved to the 2-tuple `format_batch/2`. If a
2-arity `format_kill` call survives anywhere, fix that call site now — the old
arity no longer exists.

- [ ] **Step 24: Run the full Discord test directory and format**

Run: `mix format && mix test test/unit/external_events/`

Expected: green.

- [ ] **Step 25: Commit**

Run: `git add -A && git commit -m "Rewrite Discord embeds: semantic colour, author line, linked prose"`

---

### Task 10: SystemName and the privacy constraint

**Files:**
- Create: `lib/wanderer_app/external_events/discord/system_name.ex`
- Test: `test/unit/external_events/discord/system_name_test.exs`

**Interfaces:**
- Consumes: `WandererApp.Api.MapSystem` read actions; `WandererApp.CachedInfo.get_system_static_info/1`
- Produces: `SystemName.display_name(map_id :: String.t(), solar_system_id :: integer(), role :: :system | :character) :: String.t() | nil`
  — the dispatcher calls this once per partition and passes the result to
  `EmbedFormatter.format_batch/2` as `system_name` (Task 9).

**One verified deviation from the design, read this before writing code.**

The design (§7) and `CONTRACT.md` both say to look the system up via
`MapSystem.by_map_id_and_solar_system_id/2` (`api/map_system.ex:82-85`). **Do not
use it.** That code interface targets the *primary* `:read` action
(`api/map_system.ex:217-228`), which runs
`prepare WandererApp.Api.Preparations.FilterSystemsByActorMap`. With no actor in
context — which is exactly our situation, since the dispatcher runs from a
GenServer with no user — `FilterByActorMap.filter_by_map/3` applies
`Ash.Query.filter(query, false)` (`api/preparations/filter_by_actor_map.ex:33-46`)
and the read returns nothing. `by_map_id_and_solar_system_id` has no callers
anywhere in `lib/` or `test/`; every internal lookup goes through
`read_by_map_and_solar_system` instead (see `repositories/map_system_repo.ex:16-20`,
`map/server/map_server_signatures_impl.ex:29`).

Using the contract's function would make `display_name/3` silently return the
canonical name for **both** roles: the privacy rule would appear to hold, the
feature would be quietly dead, and the regression test would pass for the wrong
reason. Use the dedicated action instead:

`WandererApp.Api.MapSystem.read_by_map_and_solar_system(%{map_id:, solar_system_id:})`
(`api/map_system.ex:95-97` for the code interface, `245-252` for the action,
which is `get?(true)` and carries no actor preparation).

**Test-environment note.** The `map_solar_systems` table is static import data
and is **not** populated by `mix test` on a clean database, so canonical-name
lookups must be seeded into `:system_static_info_cache` directly. That is a
**global Cachex table** shared with every other test file — the seed helper below
mirrors `test/unit/external_events/discord_dispatcher_test.exs:61-80` exactly,
including its `on_exit` cleanup. Omitting the cleanup breaks unrelated test files.

---

- [ ] **Step 1: Write the failing privacy regression test**

Create `test/unit/external_events/discord/system_name_test.exs`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.SystemNameTest do
  # `async: false` is mandatory: this file seeds `:system_static_info_cache`,
  # a global Cachex table shared with every other test file, and it writes to
  # the database.
  use WandererApp.DataCase, async: false

  alias WandererApp.ExternalEvents.Discord.SystemName
  alias WandererAppWeb.Factory

  # Real EVE ids: a J-space system and Jita.
  @wh_system 31_000_005
  @ks_system 30_000_142

  setup do
    seed_static_info()
    map = Factory.insert(:map, %{})
    %{map: map}
  end

  # `map_solar_systems` is static import data and is NOT populated by `mix test`
  # on a clean database, so the canonical name has to come from the cache.
  # This mirrors `discord_dispatcher_test.exs:61-80`; the `on_exit` cleanup is
  # required because the table is global.
  defp seed_static_info do
    Cachex.put(:system_static_info_cache, @wh_system, %{
      solar_system_id: @wh_system,
      solar_system_name: "J115405",
      system_class: 3
    })

    Cachex.put(:system_static_info_cache, @ks_system, %{
      solar_system_id: @ks_system,
      solar_system_name: "Jita",
      system_class: 0
    })

    on_exit(fn ->
      Cachex.del(:system_static_info_cache, @wh_system)
      Cachex.del(:system_static_info_cache, @ks_system)
    end)

    :ok
  end

  describe "the privacy constraint" do
    # This test is named for the constraint on purpose. The asymmetry it locks
    # in looks like an inconsistency and will invite a "fix"; the reason lives
    # in the SystemName moduledoc. See the design doc §7.
    test "map-local system names never reach the character webhook", %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @wh_system,
        name: "J115405",
        temporary_name: "HOME"
      })

      assert SystemName.display_name(map.id, @wh_system, :character) == "J115405"
      assert SystemName.display_name(map.id, @wh_system, :system) == "HOME"
    end

    test "a custom_name is equally confined to the system webhook", %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @wh_system,
        name: "J115405",
        custom_name: "Staging"
      })

      assert SystemName.display_name(map.id, @wh_system, :character) == "J115405"
      assert SystemName.display_name(map.id, @wh_system, :system) == "Staging"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord/system_name_test.exs`

Expected: FAIL to compile with
`WandererApp.ExternalEvents.Discord.SystemName.display_name/3 is undefined (module WandererApp.ExternalEvents.Discord.SystemName is not available)`.

- [ ] **Step 3: Implement SystemName**

Create `lib/wanderer_app/external_events/discord/system_name.ex`. The moduledoc
below is the design doc §7 paragraph verbatim — keep it that way; it is the
answer a reviewer needs to find when they conclude this asymmetry is a bug.

```elixir
defmodule WandererApp.ExternalEvents.Discord.SystemName do
  @moduledoc """
  Resolves the system name shown on a killmail embed, per destination role.

  Map-local system names (`temporary_name`, then `custom_name`) appear on the
  system webhook only. The character webhook always shows the canonical EVE name.

  This is a privacy boundary, not a formatting preference. Corporations commonly
  keep the character-kill channel public so members without map access can see
  kills and losses. Map-local chain naming in that channel leaks the map's
  private naming to people who were deliberately not granted map access, and a
  message posted to a public channel cannot be recalled.

  Resolution order on the system webhook: `temporary_name` -> `custom_name` ->
  canonical name.

  This rule looks like an inconsistency and will invite a "fix." It gets a
  regression test named for the constraint, and this paragraph is the reason a
  reviewer should find when they go looking.
  """

  require Logger

  alias WandererApp.Api.MapSystem

  @type role :: :system | :character

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

  defp map_local_name(map_id, solar_system_id)
       when is_binary(map_id) and is_integer(solar_system_id) do
    # NOTE: `read_by_map_and_solar_system`, not `by_map_id_and_solar_system_id`.
    # The latter targets the primary `:read` action, whose
    # `FilterSystemsByActorMap` preparation filters to nothing when there is no
    # actor in context — and there never is one here, because the dispatcher
    # runs from a GenServer. It would return nil for every system and silently
    # collapse the two roles into one.
    case MapSystem.read_by_map_and_solar_system(%{
           map_id: map_id,
           solar_system_id: solar_system_id
         }) do
      {:ok, %{} = system} ->
        present(system.temporary_name) || present(system.custom_name)

      _ ->
        nil
    end
  rescue
    error ->
      Logger.debug(fn ->
        "[SystemName] map-local lookup failed for #{map_id}/#{solar_system_id}: #{inspect(error)}"
      end)

      nil
  end

  defp map_local_name(_map_id, _solar_system_id), do: nil

  defp canonical_name(solar_system_id) do
    case WandererApp.CachedInfo.get_system_static_info(solar_system_id) do
      {:ok, %{solar_system_name: name}} -> present(name)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord/system_name_test.exs`

Expected: both privacy tests pass.

- [ ] **Step 5: Write the failing resolution-order and fallback tests**

Append this describe block to the test file, before the closing `end`.

```elixir
  describe "display_name/3 resolution order" do
    test "temporary_name wins over custom_name on the system webhook", %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @wh_system,
        name: "J115405",
        custom_name: "Staging",
        temporary_name: "HOME"
      })

      assert SystemName.display_name(map.id, @wh_system, :system) == "HOME"
    end

    test "falls through to the canonical name when neither is set", %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @ks_system,
        name: "Jita"
      })

      assert SystemName.display_name(map.id, @ks_system, :system) == "Jita"
      assert SystemName.display_name(map.id, @ks_system, :character) == "Jita"
    end

    test "an empty-string map-local name is treated as unset", %{map: map} do
      Factory.insert(:map_system, %{
        map_id: map.id,
        solar_system_id: @ks_system,
        name: "Jita",
        temporary_name: "",
        custom_name: ""
      })

      assert SystemName.display_name(map.id, @ks_system, :system) == "Jita"
    end

    test "a system absent from the map still resolves canonically", %{map: map} do
      assert SystemName.display_name(map.id, @ks_system, :system) == "Jita"
      assert SystemName.display_name(map.id, @ks_system, :character) == "Jita"
    end

    test "returns nil when nothing can be resolved", %{map: map} do
      unknown = 39_999_999

      assert SystemName.display_name(map.id, unknown, :system) == nil
      assert SystemName.display_name(map.id, unknown, :character) == nil
    end

    test "a nil map_id does not crash the system role" do
      assert SystemName.display_name(nil, @ks_system, :system) == "Jita"
    end
  end
```

The `returns nil when nothing can be resolved` case relies on `39_999_999` being
absent from both the seeded cache and the (empty) `map_solar_systems` table; if
`get_system_static_info/1` returns `{:ok, nil}` for it, `present(nil)` yields nil
via the `_ -> nil` clause.

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord/system_name_test.exs`

Expected: all eight tests pass. If `a nil map_id does not crash the system role`
fails, the `when is_binary(map_id)` guard on `map_local_name/2` is missing.

- [ ] **Step 7: Verify the global cache is left clean**

Run: `mix test test/unit/external_events/`

Expected: green — in particular `discord_dispatcher_test.exs`, which seeds the
same two ids into the same global Cachex table. A failure there means an
`on_exit` cleanup is missing.

- [ ] **Step 8: Commit**

Run: `git add -A && git commit -m "Add SystemName: map-local names on the system webhook only"`

## Phase D — Ingestion resilience and configuration (Tasks 11–12)

Independent of Phases A–C except for the Task 11 / Task 8 ordering noted above.

### Task 11: Maximum killmail age guard + config plumbing

Kills older than `discord_max_killmail_age_seconds` (default 3600) are dropped **at
the dispatcher**. This guards against upstream replay on reconnect (design §8), and
is the precondition that would make preload safe if it is ever added.

A parsing failure on `kill_time` **allows the kill through** — fail-open, consistent
with the dispatcher's existing posture and with the failure table in the design
("`kill_time` unparseable → Kill allowed through (fail-open)"). Do not "fix" this to
fail-closed.

The config plumbing is three files. All three must be touched: without the
`runtime.exs` entry the env accessor's default silently becomes the only reachable
value, and without the `Env` accessor the dispatcher would read `Application.get_env`
directly, which the design forbids.

**Files:**
- Modify: `config/runtime.exs:494-500` (the `:external_events` block)
- Modify: `lib/wanderer_app/env.ex:92-95` (add accessor directly after `webhooks_enabled?/0`)
- Modify: `.env.example:18` (add directly after `WANDERER_WEBHOOK_TIMEOUT_MS`)
- Modify: `lib/wanderer_app/external_events/discord_dispatcher.ex:44-49` (aliases), `:148-180` (`do_dispatch/2`), and append the new public guard near `system_name/1` at `:293-298`
- Test: `test/unit/external_events/discord_killmail_age_test.exs` (new)

**Interfaces:**
- Consumes: nothing from earlier tasks. This task is independent of Phases A–C.
- Produces:
  - `WandererApp.Env.discord_max_killmail_age_seconds() :: pos_integer()`
  - `WandererApp.ExternalEvents.DiscordDispatcher.kill_fresh?(kill :: map(), now :: DateTime.t()) :: boolean()` — public so it is directly testable; `now` defaults to `DateTime.utc_now/0`.
- **Ordering:** Phase B's Task 8 reworks `do_dispatch/2` and calls
  `Env.discord_max_killmail_age_seconds/0` via `kill_fresh?/2`. Task 11 must land
  **before or together with** Task 8. If Task 8 has already landed, apply Step 9's
  filter inside Task 8's per-kill partition step instead of the `with` chain — the
  guard function itself is unchanged either way.

Background facts verified by reading the code:

- `kill_time` on a flattened killmail is a **string** (ISO 8601). It is copied
  verbatim from the upstream payload in
  `lib/wanderer_app/kills/message_handler.ex:298`
  (`"kill_time" => kill["kill_time"]`), and the test factory produces
  `"2026-08-01T12:00:00Z"` (`test/support/factory.ex:898`). It is one of the three
  `required_fields` for the flat-format branch
  (`message_handler.ex:245`), so it is normally present — but the guard must still
  tolerate it being absent or a non-string.
- `config/runtime.exs:500` already uses `get_int_from_path_or_env/3` for
  `webhook_timeout_ms`; that is the helper for integer env vars.
- `lib/wanderer_app/env.ex:92-95` is the accessor pattern to mirror: read the
  `:external_events` keyword list, `Keyword.get/3` with the default. Note it is
  **not** wrapped in `@decorate cacheable` — the neighbouring `sse_enabled?/0` and
  `webhooks_enabled?/0` both read app env on every call. Match that, so a test
  overriding app env takes effect immediately without a cache flush.

---

- [ ] **Step 1: Write the failing test for the `Env` accessor**

Create `test/unit/external_events/discord_killmail_age_test.exs`.

`async: false` and `WandererApp.DataCase` are mandatory here: this file mutates
application env, which is global. The `Application.put_env` / `on_exit` restore
pattern below is copied from `test/unit/external_events/discord_dispatcher_test.exs:26-34`.

```elixir
defmodule WandererApp.ExternalEvents.DiscordKillmailAgeTest do
  # `async: false` is mandatory: this file mutates application env, which is
  # global and would leak into any test running concurrently.
  use WandererApp.DataCase, async: false

  alias WandererApp.Env
  alias WandererApp.ExternalEvents.DiscordDispatcher

  # Mirrors discord_dispatcher_test.exs:26-34 — read the whole `:external_events`
  # keyword list, put the one key back on top of it, and restore the original
  # list wholesale in `on_exit` so unrelated keys (webhooks_enabled,
  # webhook_timeout_ms) survive.
  defp put_max_age(seconds) do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, :discord_max_killmail_age_seconds, seconds)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
    :ok
  end

  describe "Env.discord_max_killmail_age_seconds/0" do
    test "defaults to 3600 when the key is absent" do
      original = Application.get_env(:wanderer_app, :external_events, [])

      Application.put_env(
        :wanderer_app,
        :external_events,
        Keyword.delete(original, :discord_max_killmail_age_seconds)
      )

      on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)

      assert Env.discord_max_killmail_age_seconds() == 3600
    end

    # The regression this guards: an accessor that hardcodes its default and
    # never reads config passes the test above and fails this one.
    test "returns the configured value, not only the default" do
      put_max_age(120)

      assert Env.discord_max_killmail_age_seconds() == 120
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord_killmail_age_test.exs`

Expected: FAIL with `** (UndefinedFunctionError) function WandererApp.Env.discord_max_killmail_age_seconds/0 is undefined or private` on both tests.

- [ ] **Step 3: Add the `Env` accessor**

In `lib/wanderer_app/env.ex`, insert immediately after `webhooks_enabled?/0`
(which ends at line 95) and before the `map_connection_auto_expire_hours`
`@decorate` block at line 97:

```elixir
  @doc """
  Killmails older than this are dropped at the Discord dispatcher.

  Guards against an upstream replay burst on reconnect posting hours of history
  into a chat channel. Deliberately not cached: it is read once per killmail
  batch, and `Application.get_env/3` on a keyword list is cheaper than the cache
  round trip.
  """
  def discord_max_killmail_age_seconds() do
    Application.get_env(@app, :external_events, [])
    |> Keyword.get(:discord_max_killmail_age_seconds, 3600)
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord_killmail_age_test.exs`

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Plumb the value through `runtime.exs` and `.env.example`**

In `config/runtime.exs`, replace the `:external_events` block at lines 494-500 with:

```elixir
# External Events Configuration
config :wanderer_app, :external_events,
  webhooks_enabled:
    config_dir
    |> get_var_from_path_or_env("WANDERER_WEBHOOKS_ENABLED", "false")
    |> String.to_existing_atom(),
  webhook_timeout_ms: config_dir |> get_int_from_path_or_env("WANDERER_WEBHOOK_TIMEOUT_MS", 15000),
  discord_max_killmail_age_seconds:
    config_dir
    |> get_int_from_path_or_env("WANDERER_DISCORD_MAX_KILLMAIL_AGE_SECONDS", 3600)
```

In `.env.example`, insert after line 18 (`export WANDERER_WEBHOOK_TIMEOUT_MS="15000"`):

```bash
# Killmails older than this many seconds are dropped before reaching Discord.
# Guards against an upstream replay burst on reconnect flooding the channel.
# (optional, default 3600)
# export WANDERER_DISCORD_MAX_KILLMAIL_AGE_SECONDS="3600"
```

- [ ] **Step 6: Verify the runtime config still compiles**

Run: `mix compile --warnings-as-errors`

Expected: PASS. (`runtime.exs` is evaluated at boot rather than compile time, so
this only proves it parses; Step 12 exercises the value through `Env`.)

- [ ] **Step 7: Commit the config plumbing**

Run:
```
git add lib/wanderer_app/env.ex config/runtime.exs .env.example test/unit/external_events/discord_killmail_age_test.exs
git commit -m "feat(discord): add discord_max_killmail_age_seconds config"
```

- [ ] **Step 8: Write the failing test for the age guard**

Append these to `test/unit/external_events/discord_killmail_age_test.exs`, inside
the existing module and after the `Env` describe block. Note that `@now` and
`kill_at/1` go at **module level**, not inside the `describe` block.

The boundary cases are stated in the design's Testing section: exactly at the
boundary, one second either side, future-dated, and unparseable.

```elixir
  # A fixed reference instant, so these assertions never depend on wall clock.
  @now ~U[2026-08-03 12:00:00Z]

  defp kill_at(iso8601), do: %{"killmail_id" => 1, "kill_time" => iso8601}

  describe "DiscordDispatcher.kill_fresh?/2" do
    setup do
      put_max_age(3600)
    end

    test "a kill exactly at the boundary is allowed through" do
      # 12:00:00 - 3600s = 11:00:00, age == max, inclusive.
      assert DiscordDispatcher.kill_fresh?(kill_at("2026-08-03T11:00:00Z"), @now)
    end

    test "a kill one second inside the boundary is allowed through" do
      assert DiscordDispatcher.kill_fresh?(kill_at("2026-08-03T11:00:01Z"), @now)
    end

    test "a kill one second outside the boundary is dropped" do
      refute DiscordDispatcher.kill_fresh?(kill_at("2026-08-03T10:59:59Z"), @now)
    end

    test "a far-older kill is dropped" do
      refute DiscordDispatcher.kill_fresh?(kill_at("2026-08-01T12:00:00Z"), @now)
    end

    # A negative age must not be treated as a huge positive one by a sloppy
    # `abs/1` or an argument-order slip in `DateTime.diff/3`.
    test "a future-dated kill_time is allowed through" do
      assert DiscordDispatcher.kill_fresh?(kill_at("2026-08-03T12:05:00Z"), @now)
    end

    test "an unparseable kill_time is allowed through (fail-open)" do
      assert DiscordDispatcher.kill_fresh?(kill_at("not-a-timestamp"), @now)
    end

    test "a missing kill_time is allowed through (fail-open)" do
      assert DiscordDispatcher.kill_fresh?(%{"killmail_id" => 1}, @now)
    end

    test "a non-string kill_time is allowed through (fail-open)" do
      assert DiscordDispatcher.kill_fresh?(%{"killmail_id" => 1, "kill_time" => nil}, @now)
    end

    test "an offset timestamp is compared in absolute time, not naively" do
      # 13:30:00+02:00 is 11:30:00Z — thirty minutes old, well inside the hour.
      assert DiscordDispatcher.kill_fresh?(kill_at("2026-08-03T13:30:00+02:00"), @now)
    end

    # Proves the guard reads the configured value rather than a hardcoded 3600.
    test "honours a shortened configured max age" do
      put_max_age(60)

      assert DiscordDispatcher.kill_fresh?(kill_at("2026-08-03T11:59:30Z"), @now)
      refute DiscordDispatcher.kill_fresh?(kill_at("2026-08-03T11:58:00Z"), @now)
    end
  end
```

- [ ] **Step 9: Run the test to verify it fails**

Run: `mix test test/unit/external_events/discord_killmail_age_test.exs`

Expected: the two `Env` tests pass; the ten `kill_fresh?/2` tests FAIL with
`** (UndefinedFunctionError) function WandererApp.ExternalEvents.DiscordDispatcher.kill_fresh?/2 is undefined or private`.

- [ ] **Step 10: Implement `kill_fresh?/2`**

In `lib/wanderer_app/external_events/discord_dispatcher.ex`, add `WandererApp.Env`
to the aliases at lines 46-48:

```elixir
  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Env
  alias WandererApp.ExternalEvents.Discord.{EmbedFormatter, WorkerSupervisor}
  alias WandererApp.SystemClass
```

Then add the public guard just above `defp system_name(system_id)` (currently at
line 293):

```elixir
  @doc """
  Whether a killmail is recent enough to post.

  Guards against an upstream replay burst on reconnect dumping hours of history
  into a chat channel, and is the precondition that would make a join-time
  preload safe if one is ever added.

  **Fail-open on purpose.** An absent, non-string, or unparseable `kill_time`
  allows the kill through, matching the dispatcher's posture everywhere else: a
  malformed field must not silently suppress notifications. Do not change this
  to fail-closed — a parse regression would then look exactly like a quiet map.

  `now` is an argument rather than an internal `DateTime.utc_now/0` call so the
  boundary cases are testable without sleeping or freezing the clock.
  """
  @spec kill_fresh?(map(), DateTime.t()) :: boolean()
  def kill_fresh?(kill, now \\ DateTime.utc_now())

  def kill_fresh?(%{"kill_time" => kill_time}, now) when is_binary(kill_time) do
    case DateTime.from_iso8601(kill_time) do
      {:ok, killed_at, _utc_offset} ->
        # Positive when the kill is in the past. A future-dated kill_time gives a
        # negative age and passes, which is the intent: this guard is about
        # staleness only.
        DateTime.diff(now, killed_at, :second) <= Env.discord_max_killmail_age_seconds()

      {:error, _reason} ->
        true
    end
  end

  def kill_fresh?(_kill, _now), do: true
```

- [ ] **Step 11: Run the test to verify it passes**

Run: `mix test test/unit/external_events/discord_killmail_age_test.exs`

Expected: 12 tests, 0 failures.

- [ ] **Step 12: Wire the guard into `do_dispatch/2`**

The guard has to run *before* `reject_duplicates/2` marks anything, and the
resulting empty-list case must short-circuit exactly like the existing
`[_ | _] = fresh <-` clause does. Change the `with` chain in
`do_dispatch/2` (lines 148-154) to:

```elixir
  defp do_dispatch(map_id, %{type: :map_kill, payload: payload}) do
    now = DateTime.utc_now()

    with true <- enabled_globally?(),
         {:ok, notification} <- fetch_config(map_id),
         true <- notification.enabled?,
         {:ok, system_id, killmails} <- extract_kills(payload),
         true <- system_allowed?(notification, system_id),
         [_ | _] = recent <- Enum.filter(killmails, &kill_fresh?(&1, now)),
         [_ | _] = fresh <- reject_duplicates(map_id, recent) do
```

The rest of the function body is unchanged. Stale kills are filtered before
`reject_duplicates/2`, so they are never marked in the dedup cache — consistent
with the existing rule that a kill the dispatcher never renders stays eligible.

- [ ] **Step 13: Write the dispatcher-level test**

Append to `test/unit/external_events/discord_dispatcher_test.exs`. This file's
existing `setup` already flips `webhooks_enabled` on, seeds static info, and
starts `HttpStub`, `WorkerSupervisor` and `DiscordDispatcher`
(`discord_dispatcher_test.exs:15-52`), so the new tests reuse it. Read the
delivery-assertion helpers already in that file and follow whichever it uses;
the shape below assumes `HttpStub.requests/0`.

```elixir
  describe "maximum killmail age" do
    setup do
      original = Application.get_env(:wanderer_app, :external_events, [])

      Application.put_env(
        :wanderer_app,
        :external_events,
        Keyword.put(original, :discord_max_killmail_age_seconds, 3600)
      )

      on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
      :ok
    end

    test "a stale killmail is not delivered", %{map: map} do
      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

      DiscordDispatcher.dispatch_event(map.id, kill_event(@wh_system, [kill(9_001, stale)]))
      _ = :sys.get_state(DiscordDispatcher)

      assert HttpStub.requests() == []
    end

    test "a stale killmail is not marked, so a later fresh arrival still delivers",
         %{map: map} do
      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()
      fresh = DateTime.utc_now() |> DateTime.to_iso8601()

      DiscordDispatcher.dispatch_event(map.id, kill_event(@wh_system, [kill(9_002, stale)]))
      _ = :sys.get_state(DiscordDispatcher)
      assert HttpStub.requests() == []

      DiscordDispatcher.dispatch_event(map.id, kill_event(@wh_system, [kill(9_002, fresh)]))
      _ = :sys.get_state(DiscordDispatcher)

      assert length(HttpStub.requests()) == 1
    end

    test "a mixed batch delivers only the fresh kills", %{map: map} do
      stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()
      recent = DateTime.utc_now() |> DateTime.to_iso8601()

      DiscordDispatcher.dispatch_event(
        map.id,
        kill_event(@wh_system, [kill(9_003, stale), kill(9_004, recent)])
      )

      _ = :sys.get_state(DiscordDispatcher)

      assert [request] = HttpStub.requests()
      assert request.body["embeds"] |> length() == 1
    end
  end

  # Minimal killmail and event builders matching what `extract_kills/1` expects
  # (`discord_dispatcher.ex:253-258`).
  defp kill(id, kill_time) do
    %{
      "killmail_id" => id,
      "kill_time" => kill_time,
      "solar_system_id" => @wh_system,
      "victim_char_name" => "Pilot #{id}",
      "victim_ship_name" => "Rifter"
    }
  end

  defp kill_event(system_id, killmails) do
    %Event{
      type: :map_kill,
      payload: %{
        "type" => :killmail_update,
        "solar_system_id" => system_id,
        "killmails" => killmails
      }
    }
  end
```

If `discord_dispatcher_test.exs` already defines `kill/2` or `kill_event/2`,
reuse the existing helpers instead of redefining them — a duplicate definition
is a compile error, not a warning.

- [ ] **Step 14: Run the dispatcher tests**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs test/unit/external_events/discord_killmail_age_test.exs`

Expected: 0 failures. The pre-existing tests in `discord_dispatcher_test.exs`
must still pass — their fixtures use `"kill_time" => "2026-08-01T12:00:00Z"`
(`test/support/factory.ex:898`), which is **older than an hour** relative to any
real run and would now be filtered. If any of them fail, fix the *fixture* to use
a recent timestamp rather than loosening the guard.

- [ ] **Step 15: Commit**

Run:
```
git add lib/wanderer_app/external_events/discord_dispatcher.ex test/unit/external_events/
git commit -m "feat(discord): drop killmails older than the configured max age"
```

---

### Task 12: Jittered exponential reconnect backoff

Replace the fixed `[5s, 10s, 30s, 60s]` ladder at
`lib/wanderer_app/kills/client.ex:16` with exponential backoff from 1s to a 60s
ceiling, plus ~30% jitter. Without jitter, every instance restarting after an
upstream blip reconnects in lockstep and hammers the kills service at the same
instant.

**The jitter source must be injectable.** `retry_delay_ms/2` is public and takes
the random source as an argument. A function that calls `:rand.uniform/1`
internally can only be tested by asserting a *range*, which would not catch the
specific bug this design guards against: applying the 60s ceiling **before** jitter
instead of after, which lets a jittered delay exceed 60s.

**Files:**
- Modify: `lib/wanderer_app/kills/client.ex:15-21` (module attributes), `:472-491` (`schedule_retry/1`)
- Test: `test/unit/kills/client_backoff_test.exs` (new; `test/unit/kills/` does not exist yet and must be created)

**Interfaces:**
- Consumes: nothing. Fully independent of Phases A–C and of Task 11.
- Produces: `WandererApp.Kills.Client.retry_delay_ms(retry_count :: non_neg_integer(), rand_fun :: (pos_integer() -> pos_integer())) :: pos_integer()` — `rand_fun` defaults to `&:rand.uniform/1` and is called as `rand_fun.(n)`, returning an integer in `1..n` (the `:rand.uniform/1` contract).

Background facts verified by reading the code:

- `client.ex:16` is `@retry_delays [5_000, 10_000, 30_000, 60_000]` and
  `client.ex:17` is `@max_retries 10`.
- `schedule_retry/1` (`client.ex:472-491`) computes
  `Enum.at(@retry_delays, min(state.retry_count, length(@retry_delays) - 1))` at
  line 487 and passes it to `Process.send_after(self(), :retry_connection, delay)`
  at line 489. Note it reads `state.retry_count` (the **pre-increment** value) for
  the delay while storing `new_retry_count`, so the first retry uses index 0. The
  replacement must preserve that: `retry_delay_ms(state.retry_count)`, not
  `new_retry_count`, or the first backoff doubles.
- `@max_retries` (10) is unchanged by this task, as is `@message_timeout`
  (`client.ex:21`), which drives the retry-cycle reset at `client.ex:456-460`.
- `@retry_delays` has exactly one other reference — the `length(@retry_delays)`
  on line 487 — so removing the attribute is safe once `schedule_retry/1` changes.

---

- [ ] **Step 1: Write the failing test**

Create `test/unit/kills/client_backoff_test.exs`.

`retry_delay_ms/2` is pure — no app env, no cache, no database — so
`use ExUnit.Case, async: true` is correct here.

```elixir
defmodule WandererApp.Kills.ClientBackoffTest do
  # `retry_delay_ms/2` is pure: no app env, no cache, no process state.
  use ExUnit.Case, async: true

  alias WandererApp.Kills.Client

  # `:rand.uniform/1` returns an integer in 1..n. These three stand-ins pin it to
  # the bottom, middle and top of that range, which map to the minimum, zero and
  # maximum jitter offsets respectively.
  #
  # They are functions rather than module attributes on purpose: an anonymous
  # function cannot be stored in a module attribute (it is not a valid
  # compile-time value).
  defp min_jitter, do: fn _n -> 1 end
  defp no_jitter, do: fn n -> div(n + 1, 2) end
  defp max_jitter, do: fn n -> n end

  describe "retry_delay_ms/2 with jitter pinned to zero" do
    test "doubles from 1s and holds at the 60s ceiling" do
      assert Client.retry_delay_ms(0, no_jitter()) == 1_000
      assert Client.retry_delay_ms(1, no_jitter()) == 2_000
      assert Client.retry_delay_ms(2, no_jitter()) == 4_000
      assert Client.retry_delay_ms(3, no_jitter()) == 8_000
      assert Client.retry_delay_ms(4, no_jitter()) == 16_000
      assert Client.retry_delay_ms(5, no_jitter()) == 32_000
      assert Client.retry_delay_ms(6, no_jitter()) == 60_000
      assert Client.retry_delay_ms(7, no_jitter()) == 60_000
      assert Client.retry_delay_ms(10, no_jitter()) == 60_000
    end
  end

  describe "retry_delay_ms/2 with jitter pinned to its minimum" do
    test "produces exactly the base minus 30%" do
      assert Client.retry_delay_ms(0, min_jitter()) == 700
      assert Client.retry_delay_ms(1, min_jitter()) == 1_400
      assert Client.retry_delay_ms(2, min_jitter()) == 2_800
      assert Client.retry_delay_ms(3, min_jitter()) == 5_600
      assert Client.retry_delay_ms(4, min_jitter()) == 11_200
      assert Client.retry_delay_ms(5, min_jitter()) == 22_400
      assert Client.retry_delay_ms(6, min_jitter()) == 42_000
      assert Client.retry_delay_ms(9, min_jitter()) == 42_000
    end
  end

  describe "retry_delay_ms/2 with jitter pinned to its maximum" do
    test "produces exactly the base plus 30% below the ceiling" do
      assert Client.retry_delay_ms(0, max_jitter()) == 1_300
      assert Client.retry_delay_ms(1, max_jitter()) == 2_600
      assert Client.retry_delay_ms(2, max_jitter()) == 5_200
      assert Client.retry_delay_ms(3, max_jitter()) == 10_400
      assert Client.retry_delay_ms(4, max_jitter()) == 20_800
      assert Client.retry_delay_ms(5, max_jitter()) == 41_600
    end

    # THE regression this design guards against. With the ceiling applied only
    # before jitter, retry 6 computes min(64_000, 60_000) = 60_000, then adds
    # +18_000 for 78_000 — over the ceiling. The ceiling must be applied again
    # after the offset.
    test "the ceiling holds AFTER jitter is applied, not before" do
      assert Client.retry_delay_ms(6, max_jitter()) == 60_000
      assert Client.retry_delay_ms(7, max_jitter()) == 60_000
      assert Client.retry_delay_ms(20, max_jitter()) == 60_000
    end
  end

  describe "retry_delay_ms/2 invariants across the real random source" do
    test "no delay ever exceeds the 60s ceiling or drops to zero" do
      for retry_count <- 0..20, _ <- 1..50 do
        delay = Client.retry_delay_ms(retry_count)

        assert delay > 0, "retry #{retry_count} produced a non-positive delay #{delay}"
        assert delay <= 60_000, "retry #{retry_count} produced #{delay}, over the ceiling"
      end
    end

    test "the first retry is not zero" do
      for _ <- 1..100 do
        assert Client.retry_delay_ms(0) >= 700
      end
    end

    test "the default rand_fun is used when the second argument is omitted" do
      assert is_integer(Client.retry_delay_ms(3))
    end

    # Not a strict ordering assertion — jitter ranges overlap between adjacent
    # steps. This asserts the *envelope* grows, which a broken exponent would
    # not.
    test "later retries back off further than earlier ones" do
      assert Client.retry_delay_ms(0, max_jitter()) < Client.retry_delay_ms(2, min_jitter())
      assert Client.retry_delay_ms(2, max_jitter()) < Client.retry_delay_ms(4, min_jitter())
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/kills/client_backoff_test.exs`

Expected: FAIL with `** (UndefinedFunctionError) function WandererApp.Kills.Client.retry_delay_ms/2 is undefined or private`.

- [ ] **Step 3: Replace the retry attributes**

In `lib/wanderer_app/kills/client.ex`, replace lines 15-17:

```elixir
  # Simple retry configuration - inline like character module
  @retry_delays [5_000, 10_000, 30_000, 60_000]
  @max_retries 10
```

with:

```elixir
  # Reconnect backoff: exponential from 1s to a 60s ceiling, plus ~30% jitter.
  # The jitter matters operationally — without it every instance that lost the
  # upstream at the same moment reconnects at the same moment, turning one blip
  # into a synchronized thundering herd against the kills service.
  @retry_base_delay_ms 1_000
  @retry_max_delay_ms 60_000
  @retry_jitter_fraction 0.3
  # A floor, so a pathological jitter draw can never schedule an immediate retry.
  @retry_min_delay_ms 100
  # Caps the exponent so `Integer.pow/2` cannot blow up if retry_count is ever
  # raised well above @max_retries. 2^16 * 1s is already far past the ceiling.
  @retry_max_exponent 16
  @max_retries 10
```

- [ ] **Step 4: Implement `retry_delay_ms/2`**

Add to the Client API section of `lib/wanderer_app/kills/client.ex`, after
`force_health_check/0` (which ends at line 86) and before the `# Server callbacks`
comment at line 88:

```elixir
  @doc """
  Delay before the next reconnect attempt, in milliseconds.

  Exponential from #{@retry_base_delay_ms}ms, capped at #{@retry_max_delay_ms}ms,
  with a jitter offset of up to ±#{trunc(@retry_jitter_fraction * 100)}%.

  ## Why `rand_fun` is an argument

  Public and injectable on purpose. With the random source pinned a test can
  assert the *exact* delay sequence; a function that called `:rand.uniform/1`
  internally could only be range-asserted, and a range assertion does not
  distinguish a ceiling applied before jitter from one applied after. The
  before-jitter version silently schedules retries past the ceiling.

  `rand_fun` follows the `:rand.uniform/1` contract: given `n`, it returns an
  integer in `1..n`.
  """
  @spec retry_delay_ms(non_neg_integer(), (pos_integer() -> pos_integer())) :: pos_integer()
  def retry_delay_ms(retry_count, rand_fun \\ &:rand.uniform/1)
      when is_integer(retry_count) and retry_count >= 0 and is_function(rand_fun, 1) do
    base =
      @retry_base_delay_ms
      |> Kernel.*(Integer.pow(2, min(retry_count, @retry_max_exponent)))
      |> min(@retry_max_delay_ms)

    span = trunc(base * @retry_jitter_fraction)

    # rand_fun.(2 * span + 1) is in 1..2*span+1, so the offset is in -span..span.
    # The +1 keeps the argument positive when span is 0.
    offset = rand_fun.(2 * span + 1) - span - 1

    # The ceiling is re-applied HERE, after the offset. Applying it only to
    # `base` above would let the top of the jitter range exceed it.
    (base + offset)
    |> min(@retry_max_delay_ms)
    |> max(@retry_min_delay_ms)
  end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/unit/kills/client_backoff_test.exs`

Expected: 8 tests, 0 failures.

- [ ] **Step 6: Point `schedule_retry/1` at the new function**

In `lib/wanderer_app/kills/client.ex`, replace line 487:

```elixir
    delay = Enum.at(@retry_delays, min(state.retry_count, length(@retry_delays) - 1))
```

with:

```elixir
    # `state.retry_count` is the PRE-increment value, matching the previous
    # `Enum.at/2` indexing: the first retry after a disconnect backs off by one
    # base interval, not two.
    delay = retry_delay_ms(state.retry_count)
```

- [ ] **Step 7: Verify the old attribute is fully gone**

Run: `grep -rn "@retry_delays" lib/ test/`

Expected: no output. If anything matches, remove or update it — a leftover
reference to a deleted module attribute is a compile error.

- [ ] **Step 8: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`

Expected: PASS, with no "module attribute @retry_delays was set but never used"
warning.

- [ ] **Step 9: Run the kills test suite to check for regressions**

Run: `mix test test/unit/kills/ test/unit/kills_storage_test.exs`

Expected: 0 failures. Any existing test asserting a 5000ms first retry is
asserting the *old* ladder and should be updated to the new envelope, not
worked around.

- [ ] **Step 10: Commit**

Run:
```
git add lib/wanderer_app/kills/client.ex test/unit/kills/client_backoff_test.exs
git commit -m "feat(kills): jittered exponential reconnect backoff"
```

## Phase E — UI and public surface (Tasks 13–15)

Configuration for two destinations and focus corporations, plus the incidental JSON:API attribute fix.

### Task 13: Extract corporation search into a shared module

**Files:**
- Create: `lib/wanderer_app/esi/corporation_search.ex`
- Modify: `lib/wanderer_app_web/live/map/event_handlers/map_systems_event_handler.ex:434-445` (call site) and `:629-670` (delete the private clauses)
- Test: `test/unit/esi/corporation_search_test.exs`

> Path note: the module lives at `lib/wanderer_app_web/live/map/event_handlers/map_systems_event_handler.ex`, not `lib/wanderer_app_web/live/maps/…`. Verified by `find`.

**Interfaces:**
- Consumes: nothing from earlier phases.
- Produces:
  - `WandererApp.Esi.CorporationSearch.search(characters, text) :: {:ok, [%{id: String.t(), name: String.t(), ticker: String.t(), formatted: String.t(), label: String.t(), value: String.t(), type: String.t()}]}`
  - `WandererApp.Esi.CorporationSearch.label_for(corp_id) :: String.t()`
  - `WandererApp.Esi.CorporationSearch.label_for(corp_id, fetch_fun) :: String.t()`
  - `WandererApp.Esi.CorporationSearch.min_search_length() :: pos_integer()`

Why extraction rather than a second copy in the LiveComponent: ESI corporation search
must run **as an authenticated character** (`Character.search/2` pulls an access token
out of the character record, `character.ex:176-201`). Reimplementing the
"pick a character, enrich with ticker, enforce a minimum query length" logic in the
component is exactly how the two copies drift — one gains a fix, the other keeps the
bug, and the user sees different results in two places in the same app.

Two facts the extraction must preserve, both verified by reading the current code:

1. `Character.search/2` returns corporation hits shaped `%{label: name, value: eve_id_string, corporation: true}` (`character.ex:362-368`). **`value` is a string**, not an integer. `focus_corp_ids` persists integers, so the component (Task 14) is responsible for `String.to_integer/1`. The extracted function must not silently change the type — the existing frontend call site sends this map to JS.
2. The existing call site merges the enrichment **into** the original item, so `label`, `value` and `corporation` survive alongside `formatted`/`name`/`ticker`/`id`/`type`. `handle_ui_event("get_corporation_names", …)` replies with `%{results: results}` straight to the browser, so dropping any of those keys is a frontend break. Keep `Map.merge/2`.

`label_for/1` takes an optional second argument (a fetch function, defaulting to
`&WandererApp.Esi.get_corporation_info/1`) purely so the ESI-failure path is testable
without a network call. Callers use the arity-1 form; the contract signature is
unchanged.

- [ ] **Step 1: Write the failing test**

Create `test/unit/esi/corporation_search_test.exs`:

```elixir
defmodule WandererApp.Esi.CorporationSearchTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Esi.CorporationSearch

  describe "search/2" do
    test "returns no results when the user has no characters" do
      assert {:ok, []} = CorporationSearch.search([], "Karmafleet")
    end

    test "returns no results below the minimum search length" do
      # Two characters is under the three-character minimum, so this must not
      # reach ESI at all. A character id that does not exist would make any
      # actual lookup fail loudly.
      assert {:ok, []} =
               CorporationSearch.search([%{id: Ecto.UUID.generate()}], "Ka")
    end

    test "returns no results for a non-binary search term" do
      assert {:ok, []} = CorporationSearch.search([%{id: Ecto.UUID.generate()}], nil)
    end

    test "min_search_length is three, matching the pre-extraction behaviour" do
      assert CorporationSearch.min_search_length() == 3
    end
  end

  describe "label_for/2" do
    test "renders ticker and name when ESI answers" do
      fetch = fn 98_000_001 -> {:ok, %{"name" => "Karmafleet", "ticker" => "KARMA"}} end

      assert CorporationSearch.label_for(98_000_001, fetch) == "[KARMA] Karmafleet"
    end

    test "renders the bare name when ESI answers without a ticker" do
      fetch = fn 98_000_001 -> {:ok, %{"name" => "Karmafleet", "ticker" => ""}} end

      assert CorporationSearch.label_for(98_000_001, fetch) == "Karmafleet"
    end

    test "falls back to the bare id when ESI fails" do
      # A saved focus corporation must still render as a removable chip while
      # ESI is down. Dropping it would look like the setting was lost, and the
      # user has no way to un-set what is not rendered.
      fetch = fn _ -> {:error, :timeout} end

      assert CorporationSearch.label_for(98_000_001, fetch) == "98000001"
    end

    test "falls back to the bare id when ESI raises" do
      fetch = fn _ -> raise "boom" end

      assert CorporationSearch.label_for(98_000_001, fetch) == "98000001"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/esi/corporation_search_test.exs`
Expected: FAIL with `** (UndefinedFunctionError) function WandererApp.Esi.CorporationSearch.search/2 is undefined (module WandererApp.Esi.CorporationSearch is not available)`.

- [ ] **Step 3: Create the module**

Create `lib/wanderer_app/esi/corporation_search.ex`:

```elixir
defmodule WandererApp.Esi.CorporationSearch do
  @moduledoc """
  Corporation name search against ESI, performed as one of the user's characters.

  ESI's `/search/` endpoint is authenticated, so a search needs a character with
  a live access token — which is why this takes a character list rather than a
  bare query string. Extracted from `MapSystemsEventHandler` so the map UI and
  the notification settings component share one implementation of the
  minimum-length rule and the ticker enrichment.
  """

  require Logger

  alias WandererApp.Character

  @min_search_length 3

  @doc "Minimum number of characters before a search is sent to ESI."
  @spec min_search_length() :: pos_integer()
  def min_search_length, do: @min_search_length

  @doc """
  Searches corporations by name as the first of `characters`.

  Returns `{:ok, []}` — never an error tuple — when the user has no characters
  or the term is too short, so callers can render "no matches" without
  distinguishing those cases from a genuinely empty result.

  Each hit keeps the keys `Character.search/2` produced (`:label`, `:value`,
  `:corporation`) and adds `:formatted`, `:name`, `:ticker`, `:id`, `:type`.
  `:value` and `:id` are **strings**; callers that persist integers must convert.
  """
  @spec search(list(), any()) :: {:ok, list(map())}
  def search([], _search), do: {:ok, []}

  def search([first_char | _], search) when is_binary(search) do
    if String.length(search) < @min_search_length do
      {:ok, []}
    else
      case Character.search(first_char.id, params: [search: search, categories: "corporation"]) do
        {:ok, results} ->
          {:ok, Enum.map(results, &decorate/1)}

        other ->
          other
      end
    end
  end

  def search(_characters, _search), do: {:ok, []}

  @doc """
  Human-readable label for a stored corporation id.

  Falls back to `to_string(corp_id)` whenever ESI cannot answer: a saved focus
  corporation has to stay visible and removable while ESI is down.
  """
  @spec label_for(integer() | String.t()) :: String.t()
  @spec label_for(integer() | String.t(), (any() -> any())) :: String.t()
  def label_for(corp_id, fetch_fun \\ &WandererApp.Esi.get_corporation_info/1) do
    case safe_fetch(fetch_fun, corp_id) do
      {:ok, %{"name" => name} = info} when is_binary(name) and name != "" ->
        format_label(name, Map.get(info, "ticker"))

      _ ->
        to_string(corp_id)
    end
  end

  defp decorate(item) do
    name = Map.get(item, :label, "")
    corp_id = Map.get(item, :value, "")

    ticker =
      case safe_fetch(&WandererApp.Esi.get_corporation_info/1, corp_id) do
        {:ok, %{"ticker" => ticker}} -> ticker
        _ -> ""
      end

    Map.merge(item, %{
      formatted: format_label(name, ticker),
      name: name,
      ticker: ticker,
      id: corp_id,
      type: "corp"
    })
  end

  defp format_label(name, ticker) when is_binary(ticker) and ticker != "",
    do: "[#{ticker}] #{name}"

  defp format_label(name, _ticker), do: name

  # ESI is a network dependency reached from a LiveView process; a raise here
  # would take the settings tab down over a transient lookup.
  defp safe_fetch(fetch_fun, corp_id) do
    fetch_fun.(corp_id)
  rescue
    error ->
      Logger.warning("[CorporationSearch] lookup failed for #{inspect(corp_id)}: #{inspect(error)}")
      :error
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/unit/esi/corporation_search_test.exs`
Expected: all 7 tests pass.

- [ ] **Step 5: Point the existing handler at the new module**

In `lib/wanderer_app_web/live/map/event_handlers/map_systems_event_handler.ex`, replace
the body of the corporation branch at lines 434-445:

```elixir
  # Handle UI events for getting corporation names
  def handle_ui_event("get_corporation_names", %{"search" => search}, socket) do
    user_chars = socket.assigns.current_user.characters

    response =
      case WandererApp.Esi.CorporationSearch.search(user_chars, search) do
        {:ok, results} -> %{results: results}
        _ -> %{results: []}
      end

    {:reply, response, socket}
  end
```

Then delete the three private clauses at lines 629-670 (`search_corporation_names/2`).
**Leave `search_alliance_names/2` (line 672 onward) alone** — it is a separate
category and is not in scope here.

- [ ] **Step 6: Verify the handler still compiles clean**

Run: `mix compile --warnings-as-errors`
Expected: no `function search_corporation_names/2 is unused` warning, no unused-alias
warning for `Character` (it is still used by `search_alliance_names/2`).

- [ ] **Step 7: Run the surrounding suites**

Run: `mix test test/unit/esi/corporation_search_test.exs && mix test test/wanderer_app_web/`
Expected: pass.

- [ ] **Step 8: Commit**

`git commit -m "refactor(esi): extract shared CorporationSearch from map systems handler"`

---

### Task 14: Rework the notifications component for two destinations and focus corps

**Files:**
- Modify: `lib/wanderer_app_web/live/maps/components/map_notifications_component.ex` (whole file, currently 381 lines)
- Modify: `lib/wanderer_app_web/live/maps/maps_live.html.heex:665-670` (add `current_user`)
- Test: `test/wanderer_app_web/live/map_notifications_test.exs` (existing, 337 lines — extend and update)

**Interfaces:**
- Consumes (Phase A): `WandererApp.Api.MapDiscordWebhook.create/1` (`%{notification_id:, role:, webhook_url:}`), `by_id/1`, `by_notification/1` (read, returns a list), `update/2`, `destroy/1`, `set_enabled/2` (`%{enabled?: bool}`), `valid_webhook_url?/1`; and `WandererApp.Api.MapDiscordNotification` with `focus_corp_ids` (integer list, default `[]`) and **without** `webhook_url` / the four failure-state columns, which moved to the child.
- Consumes (Task 13): `WandererApp.Esi.CorporationSearch.search/2`, `label_for/1`, `min_search_length/0`.
- Consumes (Phase C/D): `WandererApp.ExternalEvents.DiscordDispatcher.send_test_message(webhook_id)` — **arity 1, targets a webhook**, returning `:ok | {:error, :notifications_disabled | :not_configured | term()}`.
- Produces: no module API; the DOM ids below are the contract the tests bind to.

DOM ids this task establishes (tests depend on them):
`#discord-notification-form`, `#webhook-form-system`, `#webhook-form-character`,
`#excluded-system-form`, `#focus-corp-form`,
`#excluded_system_live_select_component`, `#focus_corp_live_select_component`.

**The two live_selects need distinct ids.** Today `@live_select_id
"excluded_system_live_select_component"` (line 14) is a single module attribute, and
`handle_event("live_select_change", %{"id" => id, "text" => text}, …)` (line 85)
answers unconditionally with system options. With two pickers in one component that
handler must dispatch on which id fired, or typing in the corporation box fills it
with solar systems.

**Webhook URLs stay credentials.** Only `masked_url/1` (lines 249-262) ever reaches
the template. That invariant is currently covered by the "saved url is never rendered
in full" test (line 151); this task keeps that test and extends it to both rows.

#### 14a — Two webhook rows

- [ ] **Step 1: Write the failing test for the zero/one/two-webhook rendering**

Add to `test/wanderer_app_web/live/map_notifications_test.exs`:

```elixir
  defp open_notifications(conn, map) do
    {:ok, view, _html} = live(conn, ~p"/maps/#{map.slug}/settings")
    view |> element("[phx-value-tab='notifications']") |> render_click()
    view
  end

  # Task 2's `create` takes `webhook_url` as a required argument and seeds the
  # `:system` child in the same transaction, so `roles` here only controls
  # whether a `:character` row is added on top. Passing `:system` in `roles`
  # would violate the (notification_id, role) identity from Task 1.
  defp notification_with_webhooks(map, roles) do
    {:ok, rec} =
      MapDiscordNotification.create(%{
        map_id: map.id,
        webhook_url: "https://discord.com/api/webhooks/#{:erlang.unique_integer([:positive])}/tok"
      })

    for role <- roles, role != :system do
      {:ok, _} =
        WandererApp.Api.MapDiscordWebhook.create(%{
          notification_id: rec.id,
          role: role,
          webhook_url: "https://discord.com/api/webhooks/#{:erlang.unique_integer([:positive])}/tok"
        })
    end

    rec
  end

  test "with no configuration at all, only the create form renders", %{conn: conn, map: map} do
    view = open_notifications(conn, map)

    assert has_element?(view, "#discord-notification-form")
    refute has_element?(view, "#webhook-form-character")
  end

  test "with only a system webhook, the character row offers to add one", %{
    conn: conn,
    map: map
  } do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    assert has_element?(view, "#webhook-form-system")
    assert has_element?(view, "#webhook-form-character")
    # The character destination is unset, so its form must be in add mode: a
    # URL field, and no test/remove buttons for a webhook that does not exist.
    assert has_element?(view, "#webhook-form-character input[type='password']")
    refute has_element?(view, "#webhook-form-character button[phx-click='remove-webhook']")
  end

  test "with both webhooks, each row has its own test and status controls", %{
    conn: conn,
    map: map
  } do
    notification_with_webhooks(map, [:system, :character])

    view = open_notifications(conn, map)

    assert has_element?(view, "#webhook-form-system button[phx-click='send-test']")
    assert has_element?(view, "#webhook-form-character button[phx-click='send-test']")
    # Distinct webhook ids, so the two buttons target different destinations.
    assert has_element?(view, "#webhook-form-character button[phx-click='remove-webhook']")
  end

  test "neither saved url is ever rendered in full", %{conn: conn, map: map} do
    # `create` seeds the `:system` webhook itself — see the note on
    # `notification_with_webhooks/2` above.
    {:ok, rec} =
      MapDiscordNotification.create(%{
        map_id: map.id,
        webhook_url: "https://discord.com/api/webhooks/123/SYSTEMSECRET"
      })

    {:ok, _} =
      WandererApp.Api.MapDiscordWebhook.create(%{
        notification_id: rec.id,
        role: :character,
        webhook_url: "https://discord.com/api/webhooks/456/CHARACTERSECRET"
      })

    view = open_notifications(conn, map)
    html = render(view)

    refute html =~ "SYSTEMSECRET"
    refute html =~ "CHARACTERSECRET"
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/wanderer_app_web/live/map_notifications_test.exs`
Expected: FAIL — `#webhook-form-system` is never rendered, and the old
single-URL form is what renders instead.

- [ ] **Step 3: Rewrite the component's `update/2` to load both webhooks**

Replace lines 1-36 of `map_notifications_component.ex`:

```elixir
defmodule WandererAppWeb.MapNotificationsComponent do
  @moduledoc """
  Settings tab for per-map Discord kill notifications.

  A map has one notification record and up to two destinations: a `:system`
  webhook (kills in systems on the map) and an optional `:character` webhook
  (kills involving characters tracked on the map). Each destination has its own
  URL, enable flag, delivery status and test button, because an owner needs to
  be able to diagnose one channel without touching the other.

  Webhook URLs are credentials: stored encrypted, only ever rendered as a masked
  hint with a replace flow, like a password field.
  """

  use WandererAppWeb, :live_component

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.Api.MapSolarSystem
  alias WandererApp.Esi.CorporationSearch

  @excluded_select_id "excluded_system_live_select_component"
  @focus_corp_select_id "focus_corp_live_select_component"
  @min_search_length 2
  @max_search_results 20

  @roles [:system, :character]

  @impl true
  def update(%{map_id: map_id} = assigns, socket) do
    notification =
      case MapDiscordNotification.by_map(map_id) do
        {:ok, rec} -> rec
        _ -> nil
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:excluded_select_id, @excluded_select_id)
     |> assign(:focus_corp_select_id, @focus_corp_select_id)
     |> assign(:min_search_length, @min_search_length)
     |> assign(:corp_min_search_length, CorporationSearch.min_search_length())
     |> assign_new(:system_options, fn -> [] end)
     |> assign_new(:corp_options, fn -> [] end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:flash_message, fn -> nil end)
     |> assign_notification(notification)}
  end
```

- [ ] **Step 4: Replace `assign_notification/2` and its helpers**

Replace lines 167-234 (the `update_excluded/3` … `excluded_system_labels/1` block) with:

```elixir
  defp update_excluded(socket, rec, excluded) do
    case MapDiscordNotification.update(rec, %{excluded_systems: excluded}) do
      {:ok, updated} ->
        {:noreply, socket |> assign_notification(updated) |> assign(:error, nil)}

      {:error, error} ->
        {:noreply, assign(socket, :error, humanize_error(error))}
    end
  end

  # Resolves excluded-system names and focus-corporation labels once per change,
  # not once per render: both run lookups, and the template re-renders on every
  # live_select keystroke. Also rebuilds every form so values follow the record.
  defp assign_notification(socket, notification) do
    webhooks = load_webhooks(notification)

    socket
    |> assign(:notification, notification)
    |> assign(:webhooks, webhooks)
    |> assign(:excluded_systems, excluded_system_labels(notification))
    |> assign(:focus_corps, focus_corp_labels(notification))
    |> assign(:form, notification_form(notification))
    |> assign(:webhook_forms, webhook_forms(webhooks))
    |> assign(:excluded_form, to_form(%{"excluded_system" => nil}, as: :excluded))
    |> assign(:focus_corp_form, to_form(%{"focus_corp" => nil}, as: :focus_corp))
    |> assign_replacing(webhooks)
  end

  # A destination with no stored URL is always in "replace" (i.e. entry) mode;
  # one with a URL starts masked. Recomputed on every record change so that
  # saving a URL collapses the field back to the masked hint.
  defp assign_replacing(socket, webhooks) do
    replacing =
      Map.new(@roles, fn role ->
        {role, is_nil(Map.get(webhooks, role))}
      end)

    assign(socket, :replacing_url?, replacing)
  end

  defp load_webhooks(nil), do: %{system: nil, character: nil}

  defp load_webhooks(%{id: notification_id}) do
    records =
      case MapDiscordWebhook.by_notification(notification_id) do
        {:ok, list} -> list
        _ -> []
      end

    Map.new(@roles, fn role -> {role, Enum.find(records, &(&1.role == role))} end)
  end

  defp notification_form(notification) do
    to_form(
      %{
        "webhook_url" => "",
        "wh_only" => is_nil(notification) or notification.wh_only,
        "enabled" => is_nil(notification) or notification.enabled?
      },
      as: :notification
    )
  end

  defp webhook_forms(webhooks) do
    Map.new(@roles, fn role ->
      webhook = Map.get(webhooks, role)

      form =
        to_form(
          %{
            "webhook_url" => "",
            "enabled" => is_nil(webhook) or webhook.enabled?
          },
          as: :webhook
        )

      {role, form}
    end)
  end

  # Mirrors the ACL live_select pattern in maps_live: search server-side, feed
  # `{label, value}` options back into the component.
  defp search_systems(text) when is_binary(text) and byte_size(text) >= @min_search_length do
    case MapSolarSystem.find_by_name(%{name: text}) do
      {:ok, systems} ->
        systems
        |> Enum.take(@max_search_results)
        |> Enum.map(&{"#{&1.solar_system_name} (#{&1.region_name})", &1.solar_system_id})

      _ ->
        []
    end
  end

  defp search_systems(_), do: []

  # One query for every excluded system, not one per system. Falls back to the
  # bare id for anything the lookup did not return, and keeps the stored order.
  defp excluded_system_labels(nil), do: []
  defp excluded_system_labels(%{excluded_systems: []}), do: []

  defp excluded_system_labels(%{excluded_systems: ids}) do
    labels =
      case MapSolarSystem.by_solar_system_ids(ids) do
        {:ok, systems} ->
          Map.new(
            systems,
            &{&1.solar_system_id, "#{&1.solar_system_name} (#{&1.solar_system_id})"}
          )

        _ ->
          %{}
      end

    Enum.map(ids, &{&1, Map.get(labels, &1, to_string(&1))})
  end

  # `label_for/1` already degrades to the bare id, so a chip is never dropped
  # because ESI is unreachable — the user must always be able to remove what
  # they saved.
  defp focus_corp_labels(nil), do: []
  defp focus_corp_labels(%{focus_corp_ids: []}), do: []

  defp focus_corp_labels(%{focus_corp_ids: ids}),
    do: Enum.map(ids, &{&1, CorporationSearch.label_for(&1)})
```

- [ ] **Step 5: Replace the `save` handler and add the per-webhook handlers**

Replace lines 38-76 (`handle_event("save", …)` and `handle_event("replace-url", …)`):

```elixir
  @impl true
  def handle_event("save", %{"notification" => params}, socket) do
    # `.input type="checkbox"` renders a hidden "false" before the box, so a
    # rendered field always submits a value and Phoenix keeps the last one.
    attrs = %{
      wh_only: checked?(params["wh_only"]),
      enabled?: checked?(params["enabled"])
    }

    result =
      case socket.assigns.notification do
        nil ->
          create_with_system_webhook(socket.assigns.map_id, attrs, params["webhook_url"])

        rec ->
          MapDiscordNotification.update(rec, attrs)
      end

    case result do
      {:ok, rec} ->
        {:noreply,
         socket
         |> assign_notification(rec)
         |> assign(:error, nil)
         |> assign(:flash_message, "Saved.")}

      {:error, error} ->
        {:noreply, socket |> assign(:error, humanize_error(error)) |> assign(:flash_message, nil)}
    end
  end

  # Creating the config and its required `:system` destination is one user
  # action, so a failure to create the webhook must not leave a parent record
  # with no destination sitting in the database.
  defp create_with_system_webhook(map_id, attrs, url) do
    with {:ok, rec} <- MapDiscordNotification.create(Map.put(attrs, :map_id, map_id)),
         {:ok, _webhook} <-
           MapDiscordWebhook.create(%{
             notification_id: rec.id,
             role: :system,
             webhook_url: url
           }) do
      {:ok, rec}
    else
      {:error, error} = failure ->
        cleanup_orphan(map_id)
        _ = error
        failure
    end
  end

  defp cleanup_orphan(map_id) do
    with {:ok, rec} <- MapDiscordNotification.by_map(map_id),
         {:ok, []} <- MapDiscordWebhook.by_notification(rec.id) do
      MapDiscordNotification.destroy(rec)
    else
      _ -> :ok
    end
  end

  def handle_event("replace-url", %{"role" => role}, socket) do
    {:noreply, put_replacing(socket, parse_role(role), true)}
  end

  def handle_event("save-webhook", %{"role" => role, "webhook" => params}, socket) do
    role = parse_role(role)

    with %{} = rec <- socket.assigns.notification,
         {:ok, _} <- save_webhook(rec, socket.assigns.webhooks[role], role, params) do
      {:noreply,
       socket
       |> assign_notification(reload_notification(socket.assigns.map_id))
       |> assign(:error, nil)
       |> assign(:flash_message, "Saved.")}
    else
      {:error, error} ->
        {:noreply, socket |> assign(:error, humanize_error(error)) |> assign(:flash_message, nil)}

      _ ->
        {:noreply, assign(socket, :error, "Save the map's notification settings first.")}
    end
  end

  defp save_webhook(rec, nil, role, %{"webhook_url" => url}) when is_binary(url) and url != "" do
    MapDiscordWebhook.create(%{notification_id: rec.id, role: role, webhook_url: url})
  end

  defp save_webhook(_rec, nil, _role, _params), do: {:error, "Enter a webhook URL first."}

  defp save_webhook(_rec, webhook, _role, %{"webhook_url" => url} = params)
       when is_binary(url) and url != "" do
    MapDiscordWebhook.update(webhook, %{
      webhook_url: url,
      enabled?: checked?(params["enabled"])
    })
  end

  defp save_webhook(_rec, webhook, _role, params) do
    MapDiscordWebhook.set_enabled(webhook, %{enabled?: checked?(params["enabled"])})
  end

  def handle_event("remove-webhook", %{"role" => role}, socket) do
    # Only the `:character` destination is removable. `:system` is required —
    # removing notifications entirely means deleting the parent record.
    case {parse_role(role), socket.assigns.webhooks[parse_role(role)]} do
      {:character, %{} = webhook} ->
        case MapDiscordWebhook.destroy(webhook) do
          :ok ->
            {:noreply,
             socket
             |> assign_notification(reload_notification(socket.assigns.map_id))
             |> assign(:error, nil)
             |> assign(:flash_message, "Character destination removed.")}

          {:error, error} ->
            {:noreply,
             socket |> assign(:error, humanize_error(error)) |> assign(:flash_message, nil)}
        end

      _ ->
        {:noreply, assign(socket, :error, "The system destination cannot be removed.")}
    end
  end

  defp put_replacing(socket, role, value) do
    assign(socket, :replacing_url?, Map.put(socket.assigns.replacing_url?, role, value))
  end

  defp parse_role("character"), do: :character
  defp parse_role(_), do: :system

  defp reload_notification(map_id) do
    case MapDiscordNotification.by_map(map_id) do
      {:ok, rec} -> rec
      _ -> nil
    end
  end
```

- [ ] **Step 6: Replace `send-test` and `delete`**

Replace lines 114-165 (`handle_event("send-test", …)` and `handle_event("delete", …)`):

```elixir
  def handle_event("send-test", %{"webhook_id" => webhook_id}, socket) do
    case WandererApp.ExternalEvents.DiscordDispatcher.send_test_message(webhook_id) do
      # `:ok` means the message was ENQUEUED — the last hop is an async cast, so
      # this must not claim Discord accepted it.
      :ok ->
        {:noreply,
         socket |> assign(:flash_message, "Test message queued.") |> assign(:error, nil)}

      {:error, :notifications_disabled} ->
        {:noreply,
         socket
         |> assign(
           :error,
           "Discord notifications are disabled on this server. Ask an administrator to enable them."
         )
         |> assign(:flash_message, nil)}

      {:error, :not_configured} ->
        {:noreply,
         socket |> assign(:error, "Save a webhook URL first.") |> assign(:flash_message, nil)}

      {:error, other} ->
        {:noreply,
         socket
         |> assign(:error, "Could not send a test message: #{inspect(other)}")
         |> assign(:flash_message, nil)}
    end
  end

  def handle_event("delete", _params, socket) do
    case socket.assigns.notification do
      nil ->
        {:noreply, socket}

      rec ->
        # The resource's custom destroy invalidates the config cache and stops
        # the delivery workers; the webhook children cascade with the parent.
        case Ash.destroy(rec) do
          :ok ->
            {:noreply,
             socket
             |> assign_notification(nil)
             |> assign(:error, nil)
             |> assign(:flash_message, "Removed.")}

          {:error, error} ->
            {:noreply,
             socket |> assign(:error, humanize_error(error)) |> assign(:flash_message, nil)}
        end
    end
  end
```

- [ ] **Step 7: Replace the template's webhook section**

Replace lines 264-306 of the `render/1` template (the intro paragraph through the end
of `#discord-notification-form`) with:

```heex
    <div id={@id} class="flex flex-col gap-4">
      <p class="text-sm opacity-70">
        Posts kills to Discord. These filters are separate from the Kills widget's
        own filters, which are per-user and only affect what you see in the map UI.
      </p>

      <p :if={@error} class="text-sm text-red-400">{@error}</p>
      <p :if={@flash_message} class="text-sm text-green-400">{@flash_message}</p>

      <.form
        :let={f}
        for={@form}
        id="discord-notification-form"
        phx-submit="save"
        phx-target={@myself}
        class="flex flex-col gap-3"
      >
        <.input
          :if={is_nil(@notification)}
          field={f[:webhook_url]}
          type="password"
          label="Discord webhook URL (system channel)"
          placeholder="https://discord.com/api/webhooks/..."
          autocomplete="off"
        />

        <.input field={f[:wh_only]} type="checkbox" label="Only wormhole kills" />
        <.input field={f[:enabled]} type="checkbox" label="Enabled for this map" />

        <.button type="submit">Save</.button>
      </.form>

      <.webhook_row
        :if={@notification}
        role={:system}
        title="System channel"
        help="Receives kills that happen in systems on this map."
        webhook={@webhooks[:system]}
        form={@webhook_forms[:system]}
        replacing?={@replacing_url?[:system]}
        removable?={false}
        myself={@myself}
      />

      <.webhook_row
        :if={@notification}
        role={:character}
        title="Character channel (optional)"
        help={
          "Receives kills involving characters tracked on this map, wherever they happen. " <>
            "Leave it unset and those kills go to the system channel instead."
        }
        webhook={@webhooks[:character]}
        form={@webhook_forms[:character]}
        replacing?={@replacing_url?[:character]}
        removable?={true}
        myself={@myself}
      />
```

- [ ] **Step 8: Add the `webhook_row` function component**

Add above `render/1` in the same module:

```elixir
  attr :role, :atom, required: true
  attr :title, :string, required: true
  attr :help, :string, required: true
  attr :webhook, :any, required: true
  attr :form, :any, required: true
  attr :replacing?, :boolean, required: true
  attr :removable?, :boolean, required: true
  attr :myself, :any, required: true

  defp webhook_row(assigns) do
    ~H"""
    <div id={"webhook-row-#{@role}"} class="flex flex-col gap-2 rounded border border-white/10 p-3">
      <h4 class="text-sm font-semibold">{@title}</h4>
      <p class="text-xs opacity-70">{@help}</p>

      <.form
        :let={wf}
        for={@form}
        id={"webhook-form-#{@role}"}
        phx-submit="save-webhook"
        phx-value-role={@role}
        phx-target={@myself}
        class="flex flex-col gap-2"
      >
        <.input
          :if={@replacing?}
          field={wf[:webhook_url]}
          type="password"
          label="Discord webhook URL"
          placeholder="https://discord.com/api/webhooks/..."
          autocomplete="off"
        />

        <div :if={!@replacing? && @webhook} class="flex items-center gap-2">
          <span class="text-sm opacity-70">URL: {masked_url(@webhook.webhook_url)}</span>
          <.button type="button" phx-click="replace-url" phx-value-role={@role} phx-target={@myself}>
            Replace
          </.button>
        </div>

        <.input :if={@webhook} field={wf[:enabled]} type="checkbox" label="Enabled" />

        <.button type="submit">{if @webhook, do: "Save", else: "Add"}</.button>
      </.form>

      <div :if={@webhook} class="flex items-center gap-2">
        <.button
          type="button"
          phx-click="send-test"
          phx-value-webhook_id={@webhook.id}
          phx-target={@myself}
        >
          Send test message
        </.button>
        <.button
          :if={@removable?}
          type="button"
          class="btn-error"
          phx-click="remove-webhook"
          phx-value-role={@role}
          phx-target={@myself}
          data-confirm="Remove this Discord destination?"
        >
          Remove
        </.button>
      </div>

      <div :if={@webhook} class="flex flex-col gap-1 text-sm">
        <span :if={@webhook.last_delivery_at} class="opacity-70">
          Last delivered: {Calendar.strftime(@webhook.last_delivery_at, "%Y-%m-%d %H:%M UTC")}
        </span>
        <span :if={is_nil(@webhook.last_delivery_at)} class="opacity-70">
          No kills delivered yet.
        </span>

        <span :if={@webhook.last_error} class="text-amber-400">
          Last error: {@webhook.last_error}
          <span :if={@webhook.consecutive_failures > 0}>
            ({@webhook.consecutive_failures} consecutive failures)
          </span>
        </span>
        <span :if={!@webhook.enabled?} class="text-amber-400">
          This destination is disabled and is not delivering.
        </span>
      </div>
    </div>
    """
  end
```

Also delete the old trailing status block (original lines 348-377: the map-level
`send-test`/`Remove` pair and the `@notification.last_delivery_at` block), and replace
it with a single map-level delete control:

```heex
      <div :if={@notification} class="flex items-center gap-2">
        <.button
          type="button"
          class="btn-error"
          phx-click="delete"
          phx-target={@myself}
          data-confirm="Remove Discord notifications for this map?"
        >
          Remove all Discord notifications
        </.button>
      </div>
    </div>
```

- [ ] **Step 9: Update the pre-existing tests that assumed one URL on the parent**

In `test/wanderer_app_web/live/map_notifications_test.exs`, the setup calls
`MapDiscordNotification.create(%{map_id: …, webhook_url: …})` in nine places
(lines 103, 127, 152, 175, 238, 271, 290, 309 and the assertions at 51-57, 72-76).
Replace each with `notification_with_webhooks(map, [:system])` from Step 1, and update:

- line 51-57 (`saving a valid webhook url creates the record`) — additionally assert
  `{:ok, [webhook]} = WandererApp.Api.MapDiscordWebhook.by_notification(rec.id)` and
  `webhook.role == :system`.
- line 284 (`send test message reports the global kill-switch`) — the button now
  carries `phx-value-webhook_id`, so select
  `"#webhook-form-system ~ div button[phx-click='send-test']"`; simpler and less
  brittle: `element(view, "button[phx-click='send-test']", "Send test message")` will
  match two rows once a character webhook exists, so keep that test's fixture at
  `[:system]` only.
- line 305 (`assert has_element?(view, "#discord-notification-form")`) — still valid;
  the create form re-renders after delete because `@notification` is nil.

- [ ] **Step 10: Run the webhook-row tests**

Run: `mix test test/wanderer_app_web/live/map_notifications_test.exs`
Expected: the four new rendering tests and all updated pre-existing tests pass.

- [ ] **Step 11: Commit**

`git commit -m "feat(ui): per-destination Discord webhook rows in the notifications tab"`

#### 14b — Focus corporations

- [ ] **Step 12: Write the failing focus-corporation tests**

Add to `test/wanderer_app_web/live/map_notifications_test.exs`:

```elixir
  test "focus corporations can be added and removed", %{conn: conn, map: map} do
    rec = notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    # LiveSelect renders `focus_corp[focus_corp]` as a hidden input, and
    # LiveViewTest refuses to set any value other than "" on a hidden input, so
    # push the event at the component rather than driving the form.
    view
    |> with_target("#map-notifications")
    |> render_submit("add-focus-corp", %{"focus_corp" => %{"focus_corp" => "98000001"}})

    assert {:ok, reloaded} = MapDiscordNotification.by_id(rec.id)
    # Persisted as an INTEGER: `Character.search/2` yields string eve ids
    # (`character.ex:365`) while `focus_corp_ids` is an integer list.
    assert reloaded.focus_corp_ids == [98_000_001]

    view
    |> element("button[phx-click='remove-focus-corp'][phx-value-corp_id='98000001']")
    |> render_click()

    assert {:ok, after_remove} = MapDiscordNotification.by_id(rec.id)
    assert after_remove.focus_corp_ids == []
  end

  test "a saved focus corporation renders as a removable chip even when ESI cannot name it",
       %{conn: conn, map: map} do
    rec = notification_with_webhooks(map, [:system])
    {:ok, _} = MapDiscordNotification.update(rec, %{focus_corp_ids: [98_000_001]})

    view = open_notifications(conn, map)

    # ESI is unreachable in the test environment, so `label_for/1` degrades to
    # the bare id. The chip must still be there — a vanishing chip looks like
    # the setting was lost and invites a duplicate re-add.
    assert render(view) =~ "98000001"
    assert has_element?(view, "button[phx-click='remove-focus-corp'][phx-value-corp_id='98000001']")
  end

  test "a non-numeric focus corporation is rejected with a message", %{conn: conn, map: map} do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    html =
      view
      |> with_target("#map-notifications")
      |> render_submit("add-focus-corp", %{"focus_corp" => %{"focus_corp" => "not-an-id"}})

    assert html =~ "Pick a corporation from the list."
  end

  test "a user with no characters is told why corporation search is unavailable", %{
    conn: conn,
    user: user,
    map: map
  } do
    # Detach every character from the user so `current_user.characters` is [].
    for character <- user.characters || [] do
      Ash.destroy!(character)
    end

    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    assert render(view) =~ "Add a character to this account to search corporations."
    refute has_element?(view, "#focus_corp_live_select_component")
  end

  test "the two live_selects have distinct ids and the corp search does not return systems", %{
    conn: conn,
    map: map
  } do
    Factory.insert(:solar_system, %{
      solar_system_id: 30_000_142,
      solar_system_name: "Jita",
      region_name: "The Forge"
    })

    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    assert has_element?(view, "#excluded_system_live_select_component")
    assert has_element?(view, "#focus_corp_live_select_component")

    # A corporation-box keystroke must not be answered with solar systems.
    view
    |> with_target("#map-notifications")
    |> render_change("live_select_change", %{
      "id" => "focus_corp_live_select_component",
      "text" => "Jita",
      "field" => "focus_corp"
    })

    refute render(view) =~ "Jita (The Forge)"
  end
```

- [ ] **Step 13: Run the test to verify it fails**

Run: `mix test test/wanderer_app_web/live/map_notifications_test.exs`
Expected: FAIL — `add-focus-corp` is an unhandled event, and
`#focus_corp_live_select_component` does not exist.

- [ ] **Step 14: Make `live_select_change` dispatch on the id that fired**

Replace lines 79-91 of the component (the single `live_select_change` handler):

```elixir
  # LiveSelect's search callback: users know systems and corporations by name,
  # not by numeric id.
  #
  # This must be handled HERE and not by the parent LiveView, whose own
  # `live_select_change` handler answers unconditionally with access-list
  # options. `phx-target={@myself}` on each live_select is what keeps the event
  # in this component.
  #
  # Two pickers now share this handler, so it MUST dispatch on the id that
  # fired. Answering unconditionally with system options would fill the
  # corporation dropdown with solar systems.
  def handle_event("live_select_change", %{"id" => @focus_corp_select_id, "text" => text}, socket) do
    options = search_corporations(socket.assigns[:current_user], text)

    send_update(LiveSelect.Component, id: @focus_corp_select_id, options: options)

    {:noreply, assign(socket, :corp_options, options)}
  end

  def handle_event("live_select_change", %{"id" => id, "text" => text}, socket) do
    options = search_systems(text)

    send_update(LiveSelect.Component, id: id, options: options)

    {:noreply, assign(socket, :system_options, options)}
  end
```

And add the search helper next to `search_systems/1`:

```elixir
  # `CorporationSearch.search/2` enforces its own minimum length and returns
  # `{:ok, []}` for a user with no characters, so no length guard is needed here.
  defp search_corporations(%{characters: characters}, text) when is_list(characters) do
    case CorporationSearch.search(characters, text) do
      {:ok, results} ->
        results
        |> Enum.take(@max_search_results)
        |> Enum.map(&{&1.formatted, &1.id})

      _ ->
        []
    end
  end

  defp search_corporations(_current_user, _text), do: []
```

- [ ] **Step 15: Add the add/remove focus-corporation handlers**

Add after `handle_event("remove-excluded", …)` (currently ending at line 112):

```elixir
  # Guarded the same way as `add-excluded`: only reachable from a rendered
  # record, and only for an id that parses cleanly. LiveSelect hands back the
  # corporation eve id as a STRING (`character.ex:365`), while `focus_corp_ids`
  # stores integers.
  def handle_event("add-focus-corp", %{"focus_corp" => %{"focus_corp" => raw}}, socket) do
    with %{} = rec <- socket.assigns.notification,
         {id, ""} <- Integer.parse(to_string(raw)) do
      update_focus_corps(socket, rec, Enum.uniq(rec.focus_corp_ids ++ [id]))
    else
      _ -> {:noreply, assign(socket, :error, "Pick a corporation from the list.")}
    end
  end

  def handle_event("remove-focus-corp", %{"corp_id" => raw}, socket) do
    with %{} = rec <- socket.assigns.notification,
         {id, ""} <- Integer.parse(to_string(raw)) do
      update_focus_corps(socket, rec, Enum.reject(rec.focus_corp_ids, &(&1 == id)))
    else
      _ -> {:noreply, assign(socket, :error, "Could not remove that corporation.")}
    end
  end

  defp update_focus_corps(socket, rec, corp_ids) do
    case MapDiscordNotification.update(rec, %{focus_corp_ids: corp_ids}) do
      {:ok, updated} ->
        {:noreply, socket |> assign_notification(updated) |> assign(:error, nil)}

      {:error, error} ->
        {:noreply, assign(socket, :error, humanize_error(error))}
    end
  end
```

- [ ] **Step 16: Add the focus-corporations block to the template**

Insert immediately after the excluded-systems `<div :if={@notification}>` block
(original lines 307-346) and before the map-level delete control:

```heex
      <div :if={@notification} class="flex flex-col gap-2">
        <h4 class="text-sm font-semibold">Focus corporations</h4>
        <p class="text-xs opacity-70">
          Kills involving these corporations are treated as relevant even when the
          system or wormhole-only filters would otherwise drop them.
        </p>

        <ul class="flex flex-wrap gap-2">
          <li
            :for={{corp_id, label} <- @focus_corps}
            class="flex items-center gap-2 rounded-full bg-white/10 px-3 py-1 text-sm"
          >
            <span>{label}</span>
            <.button
              type="button"
              phx-click="remove-focus-corp"
              phx-value-corp_id={corp_id}
              phx-target={@myself}
            >
              Remove
            </.button>
          </li>
        </ul>

        <p :if={@current_user.characters in [nil, []]} class="text-sm text-amber-400">
          Add a character to this account to search corporations.
        </p>

        <.form
          :let={cf}
          :if={@current_user.characters not in [nil, []]}
          for={@focus_corp_form}
          id="focus-corp-form"
          phx-submit="add-focus-corp"
          phx-target={@myself}
          class="grid items-end gap-2"
          style="grid-template-columns: 1fr auto"
        >
          <.live_select
            field={cf[:focus_corp]}
            id={@focus_corp_select_id}
            phx-target={@myself}
            dropdown_extra_class="!h-24"
            debounce={250}
            update_min_len={@corp_min_search_length}
            mode={:single}
            options={@corp_options}
            placeholder="Search a corporation by name"
          />
          <.button type="submit">Add</.button>
        </.form>
      </div>
```

Also change the excluded-systems `live_select` id at original line 336 from
`id={@live_select_id}` to `id={@excluded_select_id}` — the `@live_select_id` assign no
longer exists.

- [ ] **Step 17: Pass `current_user` at the render site**

In `lib/wanderer_app_web/live/maps/maps_live.html.heex`, the component is rendered at
lines 665-670. Insert `current_user={@current_user}` as a new line **after** line 669
(`map_id={@map.id}`), so the block reads:

```heex
              <.live_component
                :if={@active_settings_tab == "notifications"}
                module={WandererAppWeb.MapNotificationsComponent}
                id="map-notifications"
                map_id={@map.id}
                current_user={@current_user}
              />
```

`@current_user` is already in scope in this template — the sibling
`MapSubscriptionsComponent` at line 661 passes exactly this assign.

- [ ] **Step 18: Run the focus-corporation tests**

Run: `mix test test/wanderer_app_web/live/map_notifications_test.exs`
Expected: all tests in the file pass.

- [ ] **Step 19: Compile clean and run the wider LiveView suite**

Run: `mix compile --warnings-as-errors && mix test test/wanderer_app_web/`
Expected: no warnings (in particular no `@live_select_id` unused-attribute warning),
suite green.

- [ ] **Step 20: Commit**

`git commit -m "feat(ui): focus-corporation picker in the Discord notifications tab"`

---

### Task 15: Fix the JSON:API killmail key mapping + changelog

**Files:**
- Modify: `lib/wanderer_app/external_events/json_api_formatter.ex:364-387`
- Modify: `CHANGELOG.md` (top, under a new unreleased heading)
- Test: `test/unit/external_events/json_api_formatter_test.exs` (new file — no test
  currently references this module)

**Interfaces:**
- Consumes: `WandererApp.ExternalEvents.Event` (`defstruct [:id, :map_id, :type, :payload, :timestamp]`, `event.ex:44`).
- Produces: no new API. The JSON:API `kills` resource object gains three previously-`nil`
  attributes and one changed attribute.

> Path note: the formatter is at `lib/wanderer_app/external_events/json_api_formatter.ex`,
> not `lib/wanderer_app_web/schemas/`. Verified by `find`.

**Verification of the four key names, done by reading both sides.** All four claims in
the task brief hold; none is already correct and none is differently named:

| Formatter reads (line) | `MessageHandler` actually produces (line) | Effect today |
|---|---|---|
| `payload["victim_character_name"]` (370-371) | `"victim_char_name"` (`message_handler.ex:308`) | always `nil` |
| `payload["victim_ship_type"]` (372) | `"victim_ship_name"` (`message_handler.ex:316`) | always `nil` |
| `payload["system_id"]` (379) | `"solar_system_id"` (`message_handler.ex:299`) | always `nil` |
| `payload["killmail_time"]` (373) | `"kill_time"` (`message_handler.ex:298`) | **not** nil — falls back to `event.timestamp` |

The fourth is the subtle one and must be described accurately in the changelog: because
line 373 falls back to `event.timestamp`, `occurred_at` has always been populated — with
the time the event was *broadcast*, not the time of the kill. Fixing the key **changes
its value** rather than filling in a nil, so a consumer that has been treating
`occurred_at` as a broadcast time will see a different number. That is the only one of
the four that can break an existing integration rather than improve it.

Note also `message_handler.ex:294`: the flattener accepts either `"solar_system_id"` or
`"system_id"` on input but always writes `"solar_system_id"` on output. The fix therefore
reads the output key and keeps the `system_id` fallback only for hand-built payloads.

- [ ] **Step 1: Write the failing test**

Create `test/unit/external_events/json_api_formatter_test.exs`:

```elixir
defmodule WandererApp.ExternalEvents.JsonApiFormatterTest do
  use ExUnit.Case, async: true

  alias WandererApp.ExternalEvents.Event
  alias WandererApp.ExternalEvents.JsonApiFormatter

  # Keys copied from `MessageHandler.add_core_kill_data/3` and
  # `add_victim_data/2` (message_handler.ex:296-320), which is the only
  # producer of `:map_kill` payloads.
  defp flattened_kill do
    %{
      "killmail_id" => 120_000_001,
      "kill_time" => "2026-08-03T12:34:56Z",
      "solar_system_id" => 31_000_005,
      "victim_char_id" => 95_000_001,
      "victim_char_name" => "Some Pilot",
      "victim_corp_id" => 98_000_001,
      "victim_corp_ticker" => "KARMA",
      "victim_ship_type_id" => 670,
      "victim_ship_name" => "Capsule",
      "attacker_count" => 3,
      "total_value" => 1_234_567.0,
      "npc" => false
    }
  end

  defp kill_event(payload) do
    %Event{
      id: "evt-1",
      map_id: "11111111-1111-1111-1111-111111111111",
      type: :map_kill,
      payload: payload,
      timestamp: ~U[2026-08-03 23:59:59Z]
    }
  end

  test "populates victim attributes from the flattened killmail keys" do
    %{"data" => data} = JsonApiFormatter.format_event(kill_event(flattened_kill()))

    assert data["type"] == "kills"
    assert data["id"] == 120_000_001
    assert data["attributes"]["killmail_id"] == 120_000_001
    assert data["attributes"]["victim_character_name"] == "Some Pilot"
    assert data["attributes"]["victim_ship_type"] == "Capsule"
  end

  test "occurred_at is the kill time, not the broadcast time" do
    %{"data" => data} = JsonApiFormatter.format_event(kill_event(flattened_kill()))

    assert data["attributes"]["occurred_at"] == "2026-08-03T12:34:56Z"
    refute data["attributes"]["occurred_at"] == ~U[2026-08-03 23:59:59Z]
  end

  test "the system relationship carries the solar system id" do
    %{"data" => data} = JsonApiFormatter.format_event(kill_event(flattened_kill()))

    assert data["relationships"]["system"]["data"] == %{
             "type" => "map_systems",
             "id" => 31_000_005
           }
  end

  test "falls back to the broadcast timestamp when the kill time is missing" do
    payload = Map.delete(flattened_kill(), "kill_time")

    %{"data" => data} = JsonApiFormatter.format_event(kill_event(payload))

    assert data["attributes"]["occurred_at"] == ~U[2026-08-03 23:59:59Z]
  end

  test "atom-keyed payloads are still supported" do
    payload = %{
      killmail_id: 120_000_002,
      kill_time: "2026-08-03T01:02:03Z",
      solar_system_id: 31_000_006,
      victim_char_name: "Atom Pilot",
      victim_ship_name: "Rifter"
    }

    %{"data" => data} = JsonApiFormatter.format_event(kill_event(payload))

    assert data["attributes"]["victim_character_name"] == "Atom Pilot"
    assert data["attributes"]["victim_ship_type"] == "Rifter"
    assert data["attributes"]["occurred_at"] == "2026-08-03T01:02:03Z"
    assert data["relationships"]["system"]["data"]["id"] == 31_000_006
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/unit/external_events/json_api_formatter_test.exs`
Expected: FAIL — `victim_character_name` is `nil` rather than `"Some Pilot"`,
`occurred_at` is `~U[2026-08-03 23:59:59Z]` rather than the kill time, and the system
relationship id is `nil`.

- [ ] **Step 3: Fix the key names**

Replace `lib/wanderer_app/external_events/json_api_formatter.ex:364-387`:

```elixir
  defp format_resource_data(%Event{type: :map_kill, payload: payload} = event) do
    # These attribute names are the PUBLIC JSON:API shape and are deliberately
    # not renamed. What changes here is the payload keys they read: the
    # flattener in `MessageHandler` emits `victim_char_name`,
    # `victim_ship_name`, `solar_system_id` and `kill_time`
    # (message_handler.ex:296-320), so the previous keys never matched.
    %{
      "type" => "kills",
      "id" => payload["killmail_id"] || payload[:killmail_id],
      "attributes" => %{
        "killmail_id" => payload["killmail_id"] || payload[:killmail_id],
        "victim_character_name" => payload["victim_char_name"] || payload[:victim_char_name],
        "victim_ship_type" => payload["victim_ship_name"] || payload[:victim_ship_name],
        # Falls back to the broadcast time only when the kill time is genuinely
        # absent; previously the fallback fired on every event.
        "occurred_at" => payload["kill_time"] || payload[:kill_time] || event.timestamp
      },
      "relationships" => %{
        "system" => %{
          "data" => %{
            "type" => "map_systems",
            "id" =>
              payload["solar_system_id"] || payload[:solar_system_id] || payload["system_id"] ||
                payload[:system_id]
          }
        },
        "map" => %{
          "data" => %{"type" => "maps", "id" => event.map_id}
        }
      }
    }
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/unit/external_events/json_api_formatter_test.exs`
Expected: all 5 tests pass.

- [ ] **Step 5: Check no other consumer depended on the nils**

Run: `grep -rn "victim_character_name\|victim_ship_type\|occurred_at" lib/ test/ assets/js/`
Expected: hits only in the formatter, the new test, and API documentation. If the
frontend reads any of these, note it — this task does not change the frontend.

- [ ] **Step 6: Add the changelog entries**

`CHANGELOG.md` is generated by `git_ops` (line 3 is the `<!-- changelog -->` marker;
released sections follow the pattern at lines 5-19). Add an unreleased section
immediately after the marker, matching the existing heading and bullet style:

```markdown
## Unreleased

### Bug Fixes:

* api: populate `victim_character_name`, `victim_ship_type` and the `system`
  relationship id on `:map_kill` JSON:API events. These three attributes were read
  from payload keys the killmail flattener never produced and had been emitting
  `null` to every external subscriber.

* api: `occurred_at` on `:map_kill` JSON:API events is now the time of the kill.
  It previously fell back to the time the event was broadcast, so its value
  changes for existing consumers rather than merely filling in a null.

### Behaviour Changes:

* discord: a map with Discord kill notifications configured now posts **more**
  kills than before. Kills involving characters tracked on the map are delivered
  even when they fall outside wormhole space or occur in an excluded system, so a
  channel tuned to the previous volume will get busier without anyone changing a
  setting. Narrow it with the wormhole-only filter, the excluded-systems list, or
  by routing character kills to a separate channel with the new character webhook.
```

- [ ] **Step 7: Verify the changelog renders and nothing else regressed**

Run: `mix test test/unit/external_events/ && mix format --check-formatted`
Expected: pass.

- [ ] **Step 8: Commit**

`git commit -m "fix(api): read the real killmail payload keys in the JSON:API formatter"`
