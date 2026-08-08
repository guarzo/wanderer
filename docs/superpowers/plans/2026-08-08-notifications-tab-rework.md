# Notifications Tab Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Map Settings → Notifications legible at a normal window height and honest about what it is showing: two peer cards instead of one deep tree, real Discord channel names instead of webhook nicknames, and mention targets picked from a guild-scoped typeahead instead of hand-typed `user:`/`role:` snowflakes.

**Architecture:** The single 1,990-line `MapNotificationsComponent` render tree is split into two sibling cards. `ChannelInfo` grows a fourth fact (`guild_id`) and a truthful `source` quad-state; a new `Discord.Guild` module reads roles and members over the existing `HttpClient.get/2` seam with the bot token, feeding two `live_select` pickers. Mention targets stop being a CSV form field and become chip state edited by discrete events, the same shape excluded systems and focus corporations already use.

**Tech Stack:** Elixir 1.17 / OTP 26, Phoenix LiveView, Ash Framework 3.9, `live_select`, daisyUI, Cachex, Finch.

## Global constraints

- **Branch base is `guarzo/zoo`.** The whole Discord stack exists only on the fork. A worktree cut from `origin/main` does not contain `map_notifications_component.ex` at all. *(This plan's own worktree was initially cut from `main` and had to be repointed.)*
- **Ash actions, never raw Ecto**; every new action needs a `define(...)` in `code_interface`.
- **Migrations are generated:** `mix ash.codegen <name>`. Per `ash-codegen-drift-destructive-regen`, inspect the generated migration before running it — codegen only knows the snapshot and will emit `add` for columns a hand-written migration already created.
- **`error_summary/1` must never `inspect` an error struct.** `Ash.Error.Invalid` carries the submitted webhook URL in `value:`, and `sensitive? true` does not redact it.
- **`HttpClient.get/2`'s bot `Authorization` stays a parameter** (`http_client.ex:18-22`). The webhook identity read is authorised by the URL alone and must never carry a bot token.
- **`Mentions.allowed_mentions/1` always emits `"parse" => []`.** Nothing in this rework touches that module.
- **`notification_attrs/1`'s absent-key-means-keep semantics are load-bearing** (`map_notifications_component.ex:681-707`). A disabled `<fieldset>` submits nothing; treating that as `nil` wipes a saved home system.
- Run `mix format` before every commit. Verification commands run from the worktree root.

## Evidence and constraints

| Claim | Evidence |
|---|---|
| The route webhook box is a card inside a card | `webhook_row/1`'s container is `rounded border border-white/10 p-3` (`:1452`); the enclosing L1 card is the identical class list (`:1638`). Nested cards are an absolute ban. |
| The system channel shows the webhook's nickname, not the channel | `resolve_uncached/1` stamps `bot_channel_label(channel_id) \|\| webhook_label(webhook)` both as `source: :resolved` (`channel_info.ex:234-237`). Downstream cannot tell `#kills` from `Zoo Killfeed`. |
| The route channel stays masked forever | `describe/1` schedules `refresh_async/1` and returns immediately (`channel_info.ex:120-128`); the task holds no reference to the LiveView (`:161-172`), so the persisted label never reaches the open tab. |
| The route row claims "No kills delivered yet" | `show_status?` defaults `true` (`:1446`); the route call site (`:1953`) does not override it, and the empty-state string is hardcoded (`:1552-1554`). |
| `status_line/1` can render a dangling separator | `channel_hint/1` returns `nil` on error (`:1166-1171`); `status_line/1` interpolates it unguarded (`:1233-1234`). |
| A save result inside a collapsed body is invisible | Why `filters_expanded?/7` carries `match?(%{scope: :filters}, message)` (`:1293-1309`), documented at `:1289-1292`. Any collapse-by-default change must remove the cause, not the guard. |
| Chips do not match the rest of the app | `chip/1` is `rounded-full bg-white/10 px-3 py-1 text-sm` plus a full ghost `<.button>Remove</.button>` (`:1411-1418`). The house idiom is daisyUI `badge badge-ghost badge-sm` (`admin_maps_live.html.heex:64,77`). daisyUI is a configured plugin (`assets/tailwind.config.js:72`). |
| The dialog cannot be made to scroll | `core_components.ex`'s `modal/1` sets `overflow-visible` in four places including `!overflow-visible` on the dialog box, with no `max-height` anywhere — deliberate, so `live_select` dropdowns can escape. Collapse is the only lever on height. |
| `guild_id` is already one decode away | Tier 2 already calls `GET /channels/{channel_id}` with the bot token (`channel_info.ex:262-277`) and decodes only `"name"`. The same response carries `guild_id`. |
| Storage does not need to change for mentions | `mention_targets` is `{:array, :string}` (`map_discord_webhook.ex:284-287`) validated by `Mentions.valid_target?/1`. Splitting the *form* and recombining on save keeps `Mentions`, the dispatcher, `router_test` and `worker_test` out of the diff. |
| Search Guild Members needs no privileged intent | Discord docs, Search Guild Members: `query` + `limit` only; the intent warning appears on List Guild Members, not on search. |
| Get Guild Roles' intent requirement is **unverified** | The docs page truncated before that section. Expected to need only guild membership; **confirm with a live call before relying on it** (see Adaptation points). |

**Conflict to flag:** CLAUDE.md says all state changes broadcast to `"maps:#{map_id}"`. The channel-identity refresh is not map state — it is a UI-cache warm-up with no other consumer — so this plan routes it as a direct message to the requesting LiveView instead of a map-wide broadcast. See D8.

## Decisions for review

### D1 — Two peer cards, one tab *(observable behaviour)*

**Kill notifications** card:

1. Heading + delivery status pill.
2. Card-level message region.
3. Destinations: *System channel* (always shown) and *Character channel* — the character row moves **out** of the filters disclosure to sit as a peer of the system row, still collapsed behind `+ Add a separate channel` when absent.
4. Master switches (`enabled`, `wh_only`) + Save.
5. Disclosure: **Kill filters** — excluded systems, corporation filter. Collapsed, badged.

**Route alerts** card (peer, no longer a disclosure):

1. Heading + on/off state.
2. Card-level message region.
3. `route_alert_banner` (unchanged).
4. Enable toggle, home system, max jumps + Save.
5. *Route alert channel* destination at top level — **no bordered inner box**.
6. **Mentions**: Users picker and Roles picker at top level, with chips.
7. Collision warning.

`webhook_row/1` loses its own border and padding; the card owns the frame. This removes the nested-card ban violation and the "why is the route channel in a sub box" question at once.

### D2 — Collapse unconditionally, badge the problem; move messages to card level *(observable behaviour)*

Rather than keep an escape hatch for messages rendered inside a collapsed body, **remove the cause**: every save/test/remove result renders in its card's message region, which is never collapsed. `filters_expanded?/7` and `route_expanded?/3` are deleted. The only remaining disclosure ("Kill filters") starts collapsed and carries `filters_badge/2`, extended to badge problems as well as counts (`"2 systems excluded"`, `"1 corporation · needs attention"`).

Consequences:

- `panel_message` scopes reduce to `:kills` and `:route`. The `:filters` scope is dropped.
- `webhook_scope(:character)` becomes `:kills`, resolving the remapping that sent character-channel results into a panel the character row no longer lives in.

**Dropping `:filters` is six call sites, not one.** `webhook_scope/1` is the mapping; these are the direct emitters, and every one must be retargeted to `:kills` or its error becomes invisible the moment the filters message region is deleted:

| Line | Message |
|---|---|
| `:401` | `"Pick a system from the list."` |
| `:413` | `"Could not remove that system."` |
| `:426` | `"Pick a corporation from the list."` |
| `:435` | `"Could not remove that corporation."` |
| `:667` | `humanize_error(error)` — excluded-systems save |
| `:677` | `humanize_error(error)` — focus-corps save |

Step 6 greps `put_message(socket, :filters` to zero before it is done. Step 8 adds a message-placement test per row: trigger the failure, assert the text renders in the kills card's message region. Without those, a silently-swallowed filter error is indistinguishable from a successful save.

### D3 — Mentions are chip state edited by events, not a form field *(architecture)*

Mention targets leave `#webhook-form-route` entirely. `@mention_users` and `@mention_roles` are `[{snowflake, label_or_nil}]` assigns; `add-mention-user` / `remove-mention-role` / etc. save immediately through `MapDiscordWebhook.update`, recombining both lists into `["user:<id>", "role:<id>", ...]`. This mirrors `update_excluded/3` and `update_focus_corps/3` exactly and removes the mention field from the dirty-gate question.

The section renders only when the route webhook exists — there is nothing to attach a mention to otherwise.

**Hydration: the id is the state, the label is decoration.** Storage holds only `"user:<id>"` / `"role:<id>"` strings (`map_discord_webhook.ex:280-287`), so labels have to come from somewhere on mount, and the typeahead is exactly the thing that may be unavailable. The rule that keeps this safe:

- **The chip list is built from stored ids alone**, by splitting each target on its prefix into the matching list with `label: nil`. This happens before and independently of any Discord call, so every saved target is always visible and always removable.
- **Labels are filled in opportunistically.** `Guild.roles/1` returns the whole role list in one call, so role labels are free whenever the guild is reachable. User labels are not — `members/search` is query-based, and resolving N stored ids would be N calls on tab open. Stored users are left unlabelled unless the id happens to appear in a later search result.
- **A nil label renders as the raw id** in a monospace chip (`@1234567890…`), carrying the same `×` control. It is not an error state and is not hidden.
- **Recombination writes ids, never labels.** Because save is `Enum.map(users, &elem(&1, 0))`, an unlabelled target round-trips byte-identically. This is the property that makes the silent-discard failure Codex flagged impossible: no code path can drop a target for lacking a label.

**"Add by ID" takes a bare snowflake, not a prefixed target.** `parse_mention_targets/1` (`map_notifications_component.ex:598-616`) parses a prefixed CSV out of one shared field — the wrong shape once the field is split, since each input already knows whether it is users or roles. Step 5 adds `parse_mention_id(kind, raw)`, which trims, prefixes with `"user:"` / `"role:"`, and validates the result through `Mentions.valid_target?/1` — the same validator, reached without asking the user to retype a prefix the input already implies. `parse_mention_targets/1` itself stays for now only if another caller needs it; Step 5 checks and deletes it if not.

### D4 — Two new attributes on `MapDiscordWebhook` *(data model, migration)*

```elixir
# Guild this destination's channel belongs to, resolved alongside the channel
# name by `ChannelInfo` tier 2 and cached here so the mention typeahead can
# scope its search on tab open without a round trip. Public snowflake, never a
# credential; nil whenever tier 2 could not answer, which is also exactly when
# the typeahead is unavailable.
attribute :guild_id, :string

# Which tier produced `channel_label`: `:channel` for a real `#name` read from
# `GET /channels/{id}`, `:webhook_name` for the webhook's own nickname.
# Persisted rather than inferred from a leading "#", because a webhook may
# legitimately be named "#anything" and the UI must not claim that is a
# channel.
#
# `:atom` with `one_of` follows the existing `role` attribute; a bare `:string`
# cannot carry the constraint (Ash's string type takes only length/match).
attribute :channel_label_source, :atom do
  constraints one_of: [:channel, :webhook_name]
end
```

`cache_channel_info`'s `accept` widens to `[:channel_id, :channel_label, :channel_label_source, :guild_id]`.

**Which guard actually protects these fields.** `cache_channel_info`'s `webhook_url`-rejection validation (`map_discord_webhook.ex:163-177`) exists for one narrow reason: AshCloak's `SetUpEncryption` re-adds the cloaked attribute as an action *argument* regardless of `accept`, so the validation slams that argument shut. It does **not** authenticate the caller or validate the cached identity fields, and it is not what stops a crafted form submit from claiming this destination posts to `#some-innocent-channel`. That boundary is the **normal update action's restricted `accept` list** (`map_discord_webhook.ex:76-94`), which is deliberately `[:webhook_url, :enabled?, :mention_targets]` rather than `default_accept` — none of the four cache fields are reachable from the settings forms at all. Widening `cache_channel_info` does not widen that boundary, because the two actions are separate. **Step 1 adds a test asserting the normal update action rejects `channel_label`, `channel_label_source`, and `guild_id`**, so the boundary is pinned rather than assumed.

**Legacy rows.** Rows written before this change already carry `channel_id` and `channel_label` (`map_discord_webhook.ex:266-278`) with no source — the column is nil for every webhook currently configured, which is all of them. No backfill can recover the truth: nothing recorded which tier produced the stored label. So `source` carries a fourth value, `:unknown`, covered in D5. There is no data migration; the column is nullable and legacy rows self-heal on first view.

### D5 — `ChannelInfo.info` gains `guild_id`; `source` becomes a quad-state *(interface)*

```elixir
@type info :: %{
        label: String.t(),
        channel_id: String.t() | nil,
        guild_id: String.t() | nil,
        source: :channel | :webhook_name | :unknown | :masked
      }
```

`bot_channel_label/1` becomes `bot_channel/1`, returning `%{label: label, guild_id: guild_id}` or `nil`. `resolve_uncached/1` stamps `:channel` for a tier-2 answer and `:webhook_name` for the tier-1 nickname fallback. `persisted/1` reads `channel_label_source` back off the row instead of hardcoding `:resolved`. `ttl_for/1` keeps the long TTL for `:channel` and `:webhook_name`.

**`:unknown` is the legacy state, and it is self-healing.** A persisted row whose `channel_label_source` is nil maps to `source: :unknown`. Three consequences, all deliberate:

- **The UI makes no claim.** `:channel` renders `Channel: #kills`, `:webhook_name` renders `Webhook: Zoo Killfeed`, `:unknown` renders the bare stored label with neither prefix. Guessing from a leading `#` is exactly the inference D4 exists to stop.
- **`describe/1` treats `:unknown` as stale** and schedules `refresh_async/1`, the same as a cache miss, while still returning the stored label immediately. The first time anyone opens the tab the row is rewritten with a real source — so `:unknown` drains from the table on its own, without a backfill migration and without a masked-until-refresh regression that would hide a label users can see today.
- **`ttl_for(:unknown)` is short** (the masked TTL), so a row that fails to resolve retries rather than pinning `:unknown` for an hour.

`guild_id` is nil on every legacy row, which correctly routes those webhooks into D7's manual-entry fallback until a refresh fills it in.

The settings tab renders the distinction: `Channel: #kills` versus `Webhook: Zoo Killfeed` with a one-line note that the channel name needs the bot in the guild. This is issue #3's actual fix — the label was never wrong, only mislabelled.

### D6 — A new `Discord.Guild` module over the existing HTTP seam *(architecture)*

`lib/wanderer_app/external_events/discord/guild.ex`:

```elixir
@spec roles(String.t()) :: {:ok, [%{id: String.t(), name: String.t()}]} | {:error, term()}
@spec search_members(String.t(), String.t(), keyword()) ::
        {:ok, [%{id: String.t(), name: String.t()}]} | {:error, term()}
```

- `GET /guilds/{guild_id}/roles` and `GET /guilds/{guild_id}/members/search?query=…&limit=…`, both on `@bot_api_base` v10 with `Authorization: Bot …`.
- Same `safe_get`-style `rescue`/`catch` discipline as `ChannelInfo` — an unrescued raise on a keystroke path already killed this tab once (`channel_info.ex:453-458`).
- Roles are cached in `:api_cache` (a guild's role list changes rarely); member searches are **not** cached — the query is the cache key and the space is unbounded.
- Deliberately **not** Nostrum. Nostrum's gateway only starts when `discord_voice_mentions_enabled?/0` is true (`voice_gateway.ex`), which would couple the typeahead to voice mentions being configured. `HttpClient.get/2` is the seam the test suite already stubs.

**Test seam: Mox, not the shared stub.** `WandererApp.ExternalEvents.Discord.HttpStub` (`test/support/discord_http_stub.ex:1`) is the config-wired default, but its `get/2` discards headers, maps one exact URL to one fixed response, and records nothing (`:49-63`). It cannot express a query-string search, a second search returning different results, or an assertion that the bot token was sent. `Test.DiscordHttpClientMock` (`test/support/mock_definitions.ex:181-185`) is a Mox against the same behaviour and exists for precisely this — "tests that want per-call expectations instead, and swaps the config for their duration". `Discord.Guild`'s unit tests use the Mox; `HttpStub` is left alone so the delivery tests keep their shared scripted queue.

Required coverage for `Discord.Guild`: URL-encoding of a query containing a space and a `&`; the `Authorization: Bot …` header actually present on both calls; 401 and 403 distinctly (D7's fallback trigger); a 200 with malformed JSON; a raise and an exit inside the client; and a cache-hit assertion for `roles/1` proving the second call does not hit HTTP.

### D7 — Degrade, visibly, when the typeahead cannot work *(failure handling)*

The typeahead needs a bot token **and** the bot in the destination's guild. Neither is guaranteed; `channel_info.ex:24` already documents that "403 here is normal". When `guild_id` is nil or a search returns 401/403:

- The pickers are replaced by a plain "Add by ID" input per list, taking a bare snowflake and validating through `parse_mention_id/2` (D3).
- A short line states why: *"Add the bot to this guild to search names."* Not silent, not a dead picker.

Chips already saved stay visible and removable throughout — they are built from stored ids, not from the picker (D3).

This is the single most important failure path in the rework. A picker that returns nothing looks identical to a guild with no roles.

### D8 — The refresh notifies the requesting LiveView directly *(architecture)*

`describe/1` keeps its arity and current behaviour; a new **`describe/2`** takes an options keyword and accepts `notify: pid`. Every existing caller — the render helper at `map_notifications_component.ex:1166-1170` and the unit tests at `test/unit/external_events/discord/channel_info_test.exs:261-299` — compiles and behaves unchanged. Only the settings-tab render path moves to `describe/2`.

When the background task persists a `:channel` / `:webhook_name` result it sends to that pid. `maps_live` handles the message and calls `send_update(MapNotificationsComponent, id: "map-notifications", channel_info_version: System.unique_integer())`, forcing a re-render that now hits a warm cache.

**The message must be a three-tuple: `{:discord_channel_info, notification_id, source}`.** A two-tuple would be a live crash, not a style preference. `maps_live.ex:651-667` ends with an unguarded

```elixir
def handle_info({ref, result}, socket) do
  Process.demonitor(ref, [:flush])
```

catch-all for `Task.async` replies. A `{:discord_channel_info, id}` message matches it, and `Process.demonitor/2` raises `ArgumentError` on an atom — so the first async channel refresh would take down the whole map LiveView. A three-tuple cannot match that clause, and cannot match the `{_event, {:flash, type, message}}` clause above it either. Ordering the new clause before the catch-all would also work and is rejected: it makes correctness depend on source-file position, which the next person to add a handler has no reason to preserve.

**Delivery to a gone process is already safe.** `send/2` to a dead pid is a no-op in Erlang — a user closing the tab or navigating away between the request and the reply needs no guard. A *replaced* LiveView (reconnect) is a different pid that never requested the refresh and so is never sent to; it re-renders from the now-warm cache on its own mount. Neither case needs a monitor.

`ChannelInfo` sends a **plain message**, not a `send_update` — the domain module stays free of any LiveView dependency; the web layer decides what to do with the ping.

**Step 3 tests, explicitly:** (a) `describe/2` with `notify:` delivers the three-tuple after the task persists; (b) `describe/1` still schedules a refresh and sends nothing; (c) a dead pid does not raise; (d) `maps_live` handles the three-tuple without falling through to the `{ref, result}` clause — a regression test for the crash above, asserting the LiveView is alive afterwards.

**Rejected:** a `"maps:#{map_id}"` broadcast. `ChannelInfo` has no `map_id` (it holds `notification_id`), `cache_channel_info` deliberately has no `after_transaction` hook (`map_discord_webhook.ex:143-151`), and the message has exactly one consumer. **Rejected:** polling — it would re-render the tab on a timer for a value that changes once.

### D9 — Guild-scoped ids are correct by construction; manual ids are not *(security)*

Discord renders an unknown role mention as inert text with no error. Sourcing ids from a picker scoped to *this webhook's* guild makes that failure structurally impossible — which is why per-webhook `guild_id` was chosen over the installation-wide `DISCORD_GUILD_ID`, whose ids would be silently inert on any map pointed at a different guild. That is the exact silent-inert-config class #137 existed to remove.

The D7 manual fallback cannot offer that guarantee. Its help text says so plainly rather than implying validation it cannot perform.

### D10 — Copy and styling *(routine)*

- `chip/1` → daisyUI `badge badge-ghost badge-sm` with a compact `×` control replacing the full "Remove" button.
- Corporation-filter help shortened to two short sentences; the long explanation moves to `docs/ZOO-FORK.md`.
- Headings scoped to kills: "Kill filters", and the intro line states filters do not affect route alerts.
- `webhook_row/1` gains `empty_status_text`; the route row reads "No route alerts delivered yet."
- `status_line/1` omits the separator when `channel_hint/1` is nil.
- `message_class(:info)` moves off `text-green-400` so it stops colliding with the `:delivering` status green.
- `disclosure/1` gains `aria-expanded` / `aria-controls` and swaps the literal `▸` glyph for an `aria-hidden` icon.

## Alternatives and tradeoffs

| Decision | Chosen | Rejected, and why |
|---|---|---|
| Height | Collapse + badge | Scrolling the dialog: `modal/1` sets `overflow-visible` with no max-height on purpose, so `live_select` dropdowns can escape. Changing that belongs to `core_components`' owner and would break every dropdown in the app. |
| Guild scope | Per-webhook `guild_id` | Installation-wide `DISCORD_GUILD_ID`: documented as the *voice* guild (`env.ex:151`), and would offer ids that render inert on any map pointed elsewhere. |
| Mention storage | Unchanged `{:array, :string}` | A new `{user_ids, role_ids}` shape: would drag `Mentions`, the dispatcher, and the security-critical `allowed_mentions/1` path into the diff for no user-visible gain. |
| Discord client | `HttpClient.get/2` | Nostrum: gateway is gated on voice mentions being configured; would make the typeahead depend on an unrelated feature flag. |
| Collapsed-message safety | Move messages to card level | Keep the `%{scope: :filters}` escape hatch: preserves the bug's cause and makes the disclosure's initial state depend on transient message state. |

## Ordered implementation steps

- [ ] **1. Data model.** Add `guild_id` and `channel_label_source` to `MapDiscordWebhook`; widen `cache_channel_info`'s `accept`. `mix ash.codegen add_webhook_guild_identity`; **read the generated migration** before `mix ash.migrate`. No backfill — legacy rows are nil by design (D4/D5). Add the boundary test: the normal update action rejects `channel_label`, `channel_label_source`, and `guild_id`.
- [ ] **2. `ChannelInfo`.** `info` type gains `guild_id`; `source` becomes `:channel | :webhook_name | :unknown | :masked`; `bot_channel_label/1` → `bot_channel/1` decoding `guild_id`; `persist/2` and `persisted/1` carry all four fields; nil `channel_label_source` → `:unknown`, which `describe` treats as stale and `ttl_for` gives the short TTL. Unit tests for each tier **plus a legacy row**: label returned immediately, refresh scheduled, no `Channel:`/`Webhook:` claim.
- [ ] **3. `describe/2` notify + re-render.** New `describe/2` with `notify:` (arity-1 untouched), three-tuple `{:discord_channel_info, notification_id, source}` from the task, `handle_info` in `maps_live`, `send_update` into the component. Tests (a)–(d) from D8, including the `{ref, result}` catch-all regression.
- [ ] **4. `Discord.Guild`.** `roles/1`, `search_members/3`, caching, `rescue`/`catch`, `Test.DiscordHttpClientMock` expectations with the D6 coverage list. Verify Get Guild Roles against a live guild before wiring the UI.
- [ ] **5. Mention state.** `@mention_users`/`@mention_roles` assigns hydrated from stored ids with `label: nil`, add/remove events, id-only recombination on save, unlabelled-chip rendering, `parse_mention_id/2`, `live_select` handlers for both pickers, D7 fallback path. Check `parse_mention_targets/1` for remaining callers; delete if none.
- [ ] **6. Render split.** Two peer cards; `webhook_row/1` de-bordered with `empty_status_text`; character row promoted out of the filters disclosure; route card assembled; `route_expanded?/3` and `filters_expanded?/7` deleted; message regions moved to card level; `webhook_scope(:character)` → `:kills`; all six `put_message(socket, :filters` sites retargeted (D2 table) and grepped to zero.
- [ ] **7. Copy and chips (D10).** Mechanical; group into one commit.
- [ ] **8. Tests.** Update the two CSV mention tests to drive the pickers; add manual-fallback coverage; add channel-vs-webhook-vs-unknown label coverage; add the six filter message-placement tests; keep every preserved DOM id green.

## Testing and verification strategy

**DOM ids that must survive** (asserted across `test/wanderer_app_web/live/map_notifications_test.exs`, 1,501 lines): `#discord-notification-form`, `#route-alerts-form`, `#webhook-form-{system,character,route}`, `#webhook-row-{system,character,route}`, `#excluded_system_live_select_component`, `#focus_corp_live_select_component`, `#home_system_live_select_component`, `input[name='notification[home_system_id]']`, and the `#route-alerts-form fieldset[disabled]` selector. `:1385` regex-matches the raw `<form>` tag per role, so the forms must stay real `<form>` elements with those exact ids.

**Tests that must change** (disclosed, not incidental): `map_notifications_test.exs:1405` and `:1429` submit `mention_targets` as CSV through `#webhook-form-route`. Under D3 that field no longer exists there; both are rewritten to drive the pickers, and the CSV-validation assertion moves to the D7 manual-entry path, where `parse_mention_id/2` covers the same invalid-snowflake rejection through `Mentions.valid_target?/1`.

**Tests added by the review pass**, each pinning a failure that would otherwise be silent:

| Test | Guards against |
|---|---|
| Normal update rejects the four cache fields (Step 1) | D4's real boundary going unpinned |
| Legacy row: label shown, refresh scheduled, no source claim (Step 2) | `:unknown` regressing to a guess or to masked |
| `maps_live` survives `{:discord_channel_info, _, _}` (Step 3) | The `{ref, result}` catch-all crash |
| Six filter message-placement tests (Step 8) | Filter errors vanishing with the `:filters` scope |
| Unlabelled mention chip renders and removes (Step 8) | Silent discard of stored targets with no label |

Commands:

```
mix format --check-formatted
mix credo
mix test test/wanderer_app_web/live/map_notifications_test.exs
mix test test/unit/external_events/
mix test
cd assets && yarn build
```

Plus a manual pass at ~900px viewport height with both cards collapsed, confirming the whole tab is visible — that is issue #1's acceptance criterion and no automated test covers it.

## Adaptation points

- **Get Guild Roles' intent requirement is unverified.** If it turns out to need a privileged intent, D6's `roles/1` becomes unavailable on instances that have not enabled it, and the Roles picker falls back to D7's manual entry permanently. The Users picker (`members/search`) is unaffected. Revisit D6 if this is confirmed.
- **`live_select` may not support two independent pickers of the same shape** inside one component without id collisions. If so, they get explicit distinct ids (`mention_user_…`, `mention_role_…`) — already the plan, but verify the `send_update` targeting works for both.
- **If the generated migration conflicts** with an existing hand-written one (the known codegen-drift failure mode), reconcile the snapshot rather than editing the migration in place.
- **If de-bordering `webhook_row/1` makes the three call sites visually diverge**, the row may need a `variant` attr rather than a flat removal.
- **If `:unknown` proves visually unacceptable** — an unprefixed label next to two prefixed ones reading as a rendering bug rather than as honest uncertainty — the fallback is a neutral prefix (`Posting to: …`) rather than guessing the source. Do not infer from a leading `#`.
- **Steps 1–4 are independently landable**; 5 and 6 are not. Step 5 introduces assigns that Step 6's render tree consumes, and Step 6 deletes the form field Step 5 replaces — between them the mention UI is inconsistent. Land them as one commit, or land 6 first with the old CSV field still wired and swap it in 5.

## Explicit exclusions

- `Mentions`, `DiscordDispatcher`, `Router`, `WorkerSupervisor`, and the delivery path are untouched.
- `core_components.ex`'s `modal/1` overflow behaviour is untouched.
- No change to `mention_targets`' storage shape, validation, or `allowed_mentions/1`.
- No Nostrum/voice-mention changes; `DISCORD_GUILD_ID` keeps its current meaning.
- Kill-destination (system/character) mention targets keep today's behaviour — no picker UI is added for them in this pass.
- No new authorizer or Ash policy (see `wanderer-ash-no-policies`).
