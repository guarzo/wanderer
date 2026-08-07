# Discord Voice-Participant Mentions for Kill Notifications — Design

**Date:** 2026-08-07
**Status:** Approved (brainstorming session)
**Source of truth ported from:** `wanderer-notifier` (`WandererNotifier.Infrastructure.Adapters.Discord.VoiceParticipants`)

## Goal

When a kill notification is posted to a map's **system** Discord webhook, prepend
individual `<@user_id>` mentions for every member currently active in a voice
channel of the configured Discord guild, so people on comms get pinged about
kills in mapped systems. This ports proven behavior from `wanderer-notifier`
into wanderer's native Discord kill-notification pipeline.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Deployment model | Self-hosted, single guild |
| Which notifications get mentions | System webhook (`role == :system`) only; character webhook untouched |
| Enable/disable | Env vars only: presence of `DISCORD_BOT_TOKEN` **and** `DISCORD_GUILD_ID` enables the feature. No DB migration, no UI |
| Throttling | None — one ping per delivered kill event (wanderer already batches kills per event) |
| How voice state is obtained | Embedded Nostrum bot (approach A). Discord exposes voice states only over the gateway; webhooks/REST cannot list them |

### Rejected alternatives

- **HTTP call to wanderer-notifier** — couples two deployments; notifier is not
  guaranteed to run alongside this instance.
- **Hand-rolled minimal gateway client** — reimplements the fragile part
  (identify/heartbeat/resume/reconnect) of a library already vetted in
  wanderer-notifier.

## Architecture

Three new pieces, all in the existing `WandererApp.ExternalEvents.Discord`
namespace:

### 1. Nostrum dependency + conditional gateway startup

- `mix.exs`: add `{:nostrum, "~> 0.10", runtime: false}`. `runtime: false`
  guarantees the bot never starts implicitly (including in tests).
- New module `WandererApp.ExternalEvents.Discord.VoiceGateway`, added to the
  supervision tree near the existing Discord worker infrastructure. At boot it
  reads config; if **both** `DISCORD_BOT_TOKEN` and `DISCORD_GUILD_ID` are set
  it calls `Application.ensure_all_started(:nostrum)`; otherwise it is a no-op
  and the instance behaves exactly as today.
- Gateway intents: `:guilds`, `:guild_voice_states` — both non-privileged.
  Voice states are folded into Nostrum's default ETS `GuildCache` passively;
  no consumer logic is needed. If the installed Nostrum version requires a
  consumer process to boot, include a minimal no-op `Nostrum.Consumer`
  (verify at implementation time).
- Config in `config/runtime.exs`, mirroring wanderer-notifier: only configure
  `:nostrum` (token + intents) when `DISCORD_BOT_TOKEN` is present and
  `config_env() != :test`. Do **not** copy the notifier's `cache_guilds:` /
  `caches: []` keys — they are not recognized Nostrum options (the default
  `GuildCache` is what serves voice states).
- Expose `WandererApp.Env.discord_bot_token/0`, `discord_guild_id/0`, and
  `discord_voice_mentions_enabled?/0` (true iff both are set and the guild id
  parses as a positive integer).
- One-time operational step (documented, not coded): create a Discord
  application/bot, invite it to the guild with no permissions beyond guild
  visibility, and set the two env vars.

### 2. `Discord.VoiceParticipants`

Near-verbatim port of the notifier module:

- `get_active_voice_mentions/0` → reads guild id from `Env`, delegates.
- `get_active_voice_mentions/1` → `GuildCache.get!(guild_id)`, then:
  - exclude users whose voice state is in the guild's AFK channel,
  - keep only users in real voice channels (Discord channel types 2
    `GUILD_VOICE` and 13 `GUILD_STAGE_VOICE`),
  - map to `"<@user_id>"`, dedup.
- Every failure path — bot not started, guild not cached yet, malformed
  config, unexpected struct shape — rescues/returns `[]`.
- Logging: the notifier's per-call `Logger.info` narration becomes
  `Logger.debug`; keep one `Logger.warning` for the "users present but all
  filtered out" diagnostic case.
- The `GuildCache` read sits behind a single seam (an injectable
  guild-fetching function or a public function accepting a guild struct) so
  unit tests supply guild fixtures without Nostrum running.

### 3. Injection in `DiscordDispatcher.deliver_to/5`

In `lib/wanderer_app/external_events/discord_dispatcher.ex` (`deliver_to/5`,
currently line ~667):

```
entries
|> EmbedFormatter.format_batch(system_name)
|> maybe_prepend_voice_mentions(role)
|> then(&WorkerSupervisor.deliver(webhook.id, &1))
```

- `maybe_prepend_voice_mentions(messages, :system)` when
  `Env.discord_voice_mentions_enabled?()`: fetch mentions; if non-empty, set or
  prepend the joined mention string on the **first** message's `"content"`
  field (separated from any existing content by a space). Embeds are untouched.
- All other roles, feature disabled, or empty mentions: messages pass through
  unchanged — no stray whitespace, no empty content key.
- One event = one ping regardless of chunk count. If a single-chunk event also
  carries the overflow "…and N more kills not shown." content line, mentions
  are prepended to that same content string.
- Discord's default `allowed_mentions` for webhook payloads pings users
  mentioned in `content`, so no payload changes beyond the string.

## Data flow

**Boot:** supervision tree starts `VoiceGateway` → (if configured) Nostrum
connects to the gateway, identifies with the two intents → Discord pushes
`VOICE_STATE_UPDATE` events → Nostrum maintains voice states in ETS. No
polling.

**Per kill event:** pipeline unchanged through matching, routing, and
formatting. At `deliver_to/5`, for the `:system` partition only, mentions are
read from ETS (microseconds, no network — cannot block or add latency on the
dispatch path) and prepended to chunk one's content. Delivery, retry, chunk
spacing, and status tracking in `Discord.Worker` are untouched — mentions ride
inside the already-queued message payloads.

## Error handling

Invariant: **voice tagging can never cost a kill notification.**

| Condition | Behavior |
|---|---|
| Env vars absent | `VoiceGateway` no-op; dispatcher predicate false; messages unchanged |
| Malformed `DISCORD_GUILD_ID` | One `Logger.warning` at boot; feature off; no per-kill noise |
| Nostrum fails to start (bad token, network) | Error logged by `VoiceGateway`; supervision tree continues; kills deliver without pings. `VoiceGateway` must not link the app's fate to Discord's gateway |
| Gateway down / reconnecting / guild not yet cached | `GuildCache.get!` raises → rescued → `[]` → message sends without pings |
| Nobody in voice, or everyone in AFK channel | `[]` → clean message, no prepended whitespace |

## Testing

- **`VoiceParticipantsTest`** (unit, async): guild fixtures injected through
  the cache seam. Cases: AFK-channel users excluded; users in non-voice
  channels excluded; stage channels (type 13) included; duplicate user ids
  deduped; nil/absent voice_states, nil channels map, non-integer guild id,
  and raise-from-cache all return `[]`.
- **Dispatcher tests** (extend existing): mentions prepended only for
  `:system` role; only first chunk's content modified; single-chunk event with
  overflow line keeps both mentions and overflow text; feature disabled →
  byte-identical messages; mention lookup raising does not prevent delivery.
- **Not covered by automated tests:** the live gateway connection. Verified
  manually once against the real guild (bot online, user in voice, kill in a
  mapped system → ping received; user in AFK channel → no ping).
- Nostrum never starts in `mix test` (`runtime: false`, no test config), so
  the suite stays hermetic.

## Explicit exclusions

- No per-map or per-webhook toggle, no UI, no DB migration.
- No mention throttling/cooldown.
- No multi-guild support; one guild id per instance.
- No changes to the character webhook path, embed formatting, worker retry
  logic, or upstream (non-zoo) behavior — this is a zoo-fork feature.
