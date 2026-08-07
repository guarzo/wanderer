# Discord Voice-Participant Mentions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepend `<@user_id>` mentions for everyone active in the configured Discord guild's voice channels onto kill notifications posted to a map's **system** webhook.

**Architecture:** A Nostrum gateway bot (started only when `DISCORD_BOT_TOKEN` + `DISCORD_GUILD_ID` are configured) passively maintains voice states in ETS; a new pure `VoiceParticipants` module turns them into a budget-capped mention prefix; the existing `DiscordDispatcher.deliver_to/5` injects that prefix into the first message chunk for `:system`-role deliveries only. Every failure path degrades to "no mentions" — voice tagging can never cost a kill notification.

**Tech Stack:** Elixir/Phoenix, Nostrum ~> 0.10 (`runtime: false`), existing `WandererApp.ExternalEvents.Discord` pipeline, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-07-discord-voice-mentions-design.md`

## Global Constraints

- Env vars: `DISCORD_BOT_TOKEN`, `DISCORD_GUILD_ID`. Feature enabled iff **both** are set and the guild id parses as a positive integer. No DB migration, no UI.
- Mentions on `:system`-role deliveries only; `:character` path byte-identical.
- Mention prefix budget: **1,800 characters** — append whole mentions until the next would exceed it, silently drop the rest.
- Nostrum dep is `runtime: false` in `deps`, and `nostrum: :load` in the release `applications` list (a `runtime: false` dep is otherwise excluded from the release).
- Gateway intents: `[:guilds, :guild_voice_states]` (both non-privileged).
- Nostrum never starts under `mix test`; new pure-logic tests are `async: true`, tests touching application env are `async: false`.
- Stale-cache mentions during gateway reconnect are an accepted tradeoff (spec, Error handling) — do not build a freshness signal.
- Zoo-fork feature: do not touch upstream-shared behavior beyond the listed files.
- Run `mix format` before every commit.

---

### Task 1: Config surface and Nostrum dependency

**Files:**
- Modify: `mix.exs` (deps ~line 60s; `releases` block at ~line 30)
- Modify: `config/runtime.exs` (`:external_events` block at ~line 495)
- Modify: `lib/wanderer_app/env.ex` (append near `discord_max_killmail_age_seconds/0`, ~line 127)
- Modify: `.env.example` (Discord section, if present; otherwise append)
- Test: `test/unit/env_discord_voice_test.exs` (create)

**Interfaces:**
- Consumes: existing `get_var_from_path_or_env/2,3` helpers in `config/runtime.exs`; `@app` module attribute in `WandererApp.Env`.
- Produces: `WandererApp.Env.discord_bot_token/0 :: String.t() | nil`, `WandererApp.Env.discord_guild_id/0 :: pos_integer() | nil`, `WandererApp.Env.discord_voice_mentions_enabled?/0 :: boolean()`. Tasks 3 and 4 call all three.

- [ ] **Step 1: Write the failing test**

Create `test/unit/env_discord_voice_test.exs`:

```elixir
defmodule WandererApp.EnvDiscordVoiceTest do
  # async: false — mutates the :external_events application env that other
  # test files also override.
  use ExUnit.Case, async: false

  alias WandererApp.Env

  setup do
    original = Application.get_env(:wanderer_app, :external_events, [])
    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
    %{original: original}
  end

  defp put_voice_config(original, token, guild_id) do
    Application.put_env(
      :wanderer_app,
      :external_events,
      original
      |> Keyword.put(:discord_bot_token, token)
      |> Keyword.put(:discord_guild_id, guild_id)
    )
  end

  test "disabled when neither var is set", %{original: original} do
    put_voice_config(original, nil, nil)
    refute Env.discord_voice_mentions_enabled?()
    assert Env.discord_bot_token() == nil
    assert Env.discord_guild_id() == nil
  end

  test "enabled when both are set and guild id is a positive integer string",
       %{original: original} do
    put_voice_config(original, "token-abc", "123456789")
    assert Env.discord_voice_mentions_enabled?()
    assert Env.discord_bot_token() == "token-abc"
    assert Env.discord_guild_id() == 123_456_789
  end

  test "disabled when only the token is set", %{original: original} do
    put_voice_config(original, "token-abc", nil)
    refute Env.discord_voice_mentions_enabled?()
  end

  test "disabled when only the guild id is set", %{original: original} do
    put_voice_config(original, nil, "123456789")
    refute Env.discord_voice_mentions_enabled?()
  end

  test "malformed guild id disables the feature", %{original: original} do
    for bad <- ["not-a-number", "12abc", "-5", "0", ""] do
      put_voice_config(original, "token-abc", bad)
      assert Env.discord_guild_id() == nil, "expected #{inspect(bad)} to parse as nil"
      refute Env.discord_voice_mentions_enabled?()
    end
  end

  test "integer guild id passes through", %{original: original} do
    put_voice_config(original, "token-abc", 42)
    assert Env.discord_guild_id() == 42
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/env_discord_voice_test.exs`
Expected: FAIL — `Env.discord_bot_token/0 is undefined or private`

- [ ] **Step 3: Add the Env functions**

In `lib/wanderer_app/env.ex`, after `discord_max_killmail_age_seconds/0` (~line 127), add:

```elixir
@doc """
Bot token for the voice-mention gateway connection. `nil` when unset —
voice mentions on system-channel kill notifications are then disabled.
"""
def discord_bot_token() do
  Application.get_env(@app, :external_events, [])
  |> Keyword.get(:discord_bot_token)
end

@doc """
Guild whose voice channels feed kill-notification mentions, as a positive
integer. `nil` when unset or malformed — a malformed id disables the
feature; `VoiceGateway` warns once at boot rather than per kill.
"""
def discord_guild_id() do
  Application.get_env(@app, :external_events, [])
  |> Keyword.get(:discord_guild_id)
  |> parse_guild_id()
end

defp parse_guild_id(nil), do: nil
defp parse_guild_id(id) when is_integer(id) and id > 0, do: id
defp parse_guild_id(id) when is_integer(id), do: nil

defp parse_guild_id(id) when is_binary(id) do
  case Integer.parse(id) do
    {parsed, ""} when parsed > 0 -> parsed
    _ -> nil
  end
end

defp parse_guild_id(_), do: nil

@doc """
Voice-participant mentions are on iff both the bot token and a valid guild
id are configured. Presence of config IS the feature flag (spec decision:
env vars only, no DB toggle).
"""
def discord_voice_mentions_enabled?() do
  discord_bot_token() != nil and discord_guild_id() != nil
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/unit/env_discord_voice_test.exs`
Expected: PASS (6 tests)

- [ ] **Step 5: Add the Nostrum dependency and release entry**

In `mix.exs` `deps`, add (alphabetical placement among existing deps):

```elixir
{:nostrum, "~> 0.10", runtime: false},
```

In the `releases` block, extend `applications`:

```elixir
applications: [
  wanderer_app: :permanent,
  # runtime: false keeps Nostrum out of the release unless listed; :load
  # ships the code without auto-starting it — VoiceGateway starts it only
  # when voice mentions are configured.
  nostrum: :load
],
```

Run: `mix deps.get && mix compile`
Expected: compiles clean; nostrum fetched.

- [ ] **Step 6: Add runtime config**

In `config/runtime.exs`, inside the existing `config :wanderer_app, :external_events` keyword list (~line 496), add two entries (2-arity `get_var_from_path_or_env` defaults to `nil` — verify against its definition in this file and use the explicit `nil` default 3-arity form if not):

```elixir
discord_bot_token: config_dir |> get_var_from_path_or_env("DISCORD_BOT_TOKEN"),
discord_guild_id: config_dir |> get_var_from_path_or_env("DISCORD_GUILD_ID"),
```

Immediately after that config block, add the Nostrum block (mirrors wanderer-notifier's `runtime.exs:127`; do NOT copy its `cache_guilds:`/`caches: []` keys — they are not recognized Nostrum options, and the default ETS `GuildCache` is required):

```elixir
# Nostrum powers voice-participant mentions on Discord kill notifications.
# Configured only when a bot token exists; VoiceGateway decides at boot
# whether to actually start it. Never configured in test — the suite must
# stay hermetic.
if config_env() != :test do
  discord_bot_token = config_dir |> get_var_from_path_or_env("DISCORD_BOT_TOKEN")

  if discord_bot_token do
    config :nostrum,
      token: discord_bot_token,
      gateway_intents: [:guilds, :guild_voice_states],
      ffmpeg: false
  end
end
```

In `.env.example`, add alongside other Discord/optional settings:

```bash
# Voice-participant mentions on Discord kill notifications (optional).
# Both must be set; the bot must be invited to the guild (no permissions
# needed beyond guild visibility).
# DISCORD_BOT_TOKEN=
# DISCORD_GUILD_ID=
```

- [ ] **Step 7: Verify compile and full env test**

Run: `mix compile --warnings-as-errors && mix test test/unit/env_discord_voice_test.exs`
Expected: PASS

- [ ] **Step 8: Format and commit**

```bash
mix format
git add mix.exs mix.lock config/runtime.exs lib/wanderer_app/env.ex .env.example test/unit/env_discord_voice_test.exs
git commit -m "feat(discord): config surface and nostrum dep for voice mentions"
```

---

### Task 2: VoiceParticipants module (pure logic + cache seam)

**Files:**
- Create: `lib/wanderer_app/external_events/discord/voice_participants.ex`
- Test: `test/unit/external_events/discord/voice_participants_test.exs` (create)

**Interfaces:**
- Consumes: `WandererApp.Env.discord_guild_id/0` (Task 1); `Nostrum.Cache.GuildCache.get!/1` (dep from Task 1; compile-time only reference via capture).
- Produces (all called by Task 4):
  - `get_active_voice_mentions/0 :: [String.t()]` — reads config + cache, rescues everything to `[]`.
  - `mentions_from_guild/1 :: (map() -> [String.t()])` — pure.
  - `mention_prefix/1,2 :: ([String.t()], pos_integer() -> {String.t() | nil, non_neg_integer()})` — budget-capped prefix + included count.
  - `prepend_to_messages/2 :: ([map()], String.t() | nil -> [map()])` — pure message munging.
- Test seam: `Application.get_env(:wanderer_app, :discord_voice_guild_fetcher)` — a 1-arity fun replacing the `GuildCache` read; used by Task 4's tests.

- [ ] **Step 1: Write the failing tests**

Create `test/unit/external_events/discord/voice_participants_test.exs`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.VoiceParticipantsTest do
  use ExUnit.Case, async: true

  alias WandererApp.ExternalEvents.Discord.VoiceParticipants

  # Shapes mirror Nostrum structs: atom keys, channels as an id-keyed map.
  # Channel types: 2 = GUILD_VOICE, 13 = GUILD_STAGE_VOICE, 0 = text.
  defp guild(overrides \\ %{}) do
    Map.merge(
      %{
        id: 999,
        afk_channel_id: 30,
        channels: %{
          10 => %{id: 10, type: 2},
          20 => %{id: 20, type: 0},
          30 => %{id: 30, type: 2},
          40 => %{id: 40, type: 13}
        },
        voice_states: [
          %{user_id: 111, channel_id: 10},
          %{user_id: 222, channel_id: 10}
        ]
      },
      overrides
    )
  end

  describe "mentions_from_guild/1" do
    test "mentions users in voice channels" do
      assert VoiceParticipants.mentions_from_guild(guild()) == ["<@111>", "<@222>"]
    end

    test "excludes users in the AFK channel" do
      g =
        guild(%{voice_states: [%{user_id: 111, channel_id: 10}, %{user_id: 333, channel_id: 30}]})

      assert VoiceParticipants.mentions_from_guild(g) == ["<@111>"]
    end

    test "excludes users whose state points at a non-voice channel" do
      g = guild(%{voice_states: [%{user_id: 111, channel_id: 20}]})
      assert VoiceParticipants.mentions_from_guild(g) == []
    end

    test "includes stage channels (type 13)" do
      g = guild(%{voice_states: [%{user_id: 444, channel_id: 40}]})
      assert VoiceParticipants.mentions_from_guild(g) == ["<@444>"]
    end

    test "dedups user ids" do
      g =
        guild(%{voice_states: [%{user_id: 111, channel_id: 10}, %{user_id: 111, channel_id: 40}]})

      assert VoiceParticipants.mentions_from_guild(g) == ["<@111>"]
    end

    test "nil voice_states yields no mentions" do
      assert VoiceParticipants.mentions_from_guild(guild(%{voice_states: nil})) == []
    end

    test "nil channels yields no mentions" do
      assert VoiceParticipants.mentions_from_guild(guild(%{channels: nil})) == []
    end
  end

  describe "mention_prefix/2" do
    test "empty list produces nil prefix and zero count" do
      assert VoiceParticipants.mention_prefix([]) == {nil, 0}
    end

    test "joins mentions with spaces and counts them" do
      assert VoiceParticipants.mention_prefix(["<@1>", "<@2>"]) == {"<@1> <@2>", 2}
    end

    test "drops mentions past the budget at a mention boundary" do
      # "<@1000000001>" is 13 chars; with separators, 3 fit in 41 but not 4.
      mentions = Enum.map(1_000_000_001..1_000_000_004, &"<@#{&1}>")
      {prefix, count} = VoiceParticipants.mention_prefix(mentions, 41)
      assert count == 3
      assert prefix == "<@1000000001> <@1000000002> <@1000000003>"
      assert String.length(prefix) <= 41
    end

    test "a single mention larger than the budget yields nil" do
      assert VoiceParticipants.mention_prefix(["<@12345>"], 3) == {nil, 0}
    end

    test "default budget truncates below Discord's 2,000-char content limit" do
      # 150 mentions x 14 chars (incl. separator) ~ 2,100 chars: must
      # truncate at the 1,800 default, not pass through.
      mentions = Enum.map(1_000_000_001..1_000_000_150, &"<@#{&1}>")
      {prefix, count} = VoiceParticipants.mention_prefix(mentions)
      assert count < 150
      assert String.length(prefix) <= 1_800
    end
  end

  describe "prepend_to_messages/2" do
    test "nil prefix leaves messages untouched" do
      messages = [%{"embeds" => [%{"title" => "kill"}]}]
      assert VoiceParticipants.prepend_to_messages(messages, nil) == messages
    end

    test "sets content on the first message only" do
      messages = [%{"embeds" => [1]}, %{"embeds" => [2]}]

      assert VoiceParticipants.prepend_to_messages(messages, "<@1>") == [
               %{"embeds" => [1], "content" => "<@1>"},
               %{"embeds" => [2]}
             ]
    end

    test "prepends before existing content with a space" do
      messages = [%{"embeds" => [1], "content" => "hello"}]

      assert VoiceParticipants.prepend_to_messages(messages, "<@1>") == [
               %{"embeds" => [1], "content" => "<@1> hello"}
             ]
    end

    test "empty message list passes through" do
      assert VoiceParticipants.prepend_to_messages([], "<@1>") == []
    end
  end

  describe "get_active_voice_mentions/0" do
    test "returns [] when the feature is unconfigured" do
      # Test env has no discord_guild_id, so this exercises the nil branch.
      assert VoiceParticipants.get_active_voice_mentions() == []
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/unit/external_events/discord/voice_participants_test.exs`
Expected: FAIL — module `VoiceParticipants` is not available

- [ ] **Step 3: Implement the module**

Create `lib/wanderer_app/external_events/discord/voice_participants.ex`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.VoiceParticipants do
  @moduledoc """
  Mentions for everyone active in the configured guild's voice channels,
  prepended to system-channel kill notifications.

  Voice states come from Nostrum's ETS `GuildCache`, populated passively by
  the gateway connection `VoiceGateway` starts. The cache read is
  microseconds and never touches the network, so it cannot slow dispatch.

  Every failure path — feature unconfigured, gateway never started, guild
  not cached yet — returns `[]`: voice tagging must never cost a kill
  notification. During a gateway reconnect the cache stays readable but
  stale; pinging a recently-departed user is an accepted tradeoff (see the
  design spec's error-handling section).

  Ported from wanderer-notifier's
  `WandererNotifier.Infrastructure.Adapters.Discord.VoiceParticipants`.
  """

  require Logger

  # Discord channel types: 2 = GUILD_VOICE, 13 = GUILD_STAGE_VOICE
  @voice_channel_types [2, 13]

  # Discord rejects `content` over 2,000 characters, and the worker treats a
  # 400 as a permanent event failure feeding the auto-disable counter
  # (`Worker`, `handle_post_result/2`). 1,800 leaves headroom for any
  # existing content on the chunk. A partially-tagged ping beats a rejected
  # notification.
  @mention_budget 1_800

  @doc """
  Mentions for the configured guild, `[]` unless the feature is configured
  and the guild is cached.
  """
  @spec get_active_voice_mentions() :: [String.t()]
  def get_active_voice_mentions do
    case WandererApp.Env.discord_guild_id() do
      nil ->
        []

      guild_id ->
        guild_id |> fetch_guild() |> mentions_from_guild()
    end
  rescue
    error ->
      Logger.debug(fn ->
        "[VoiceParticipants] lookup failed: #{Exception.message(error)}"
      end)

      []
  end

  # Seam: tests inject a fixture-returning fun via app env; production falls
  # through to Nostrum's cache. A config seam (not a parameter) keeps the
  # dispatcher call site zero-arity.
  defp fetch_guild(guild_id) do
    fetcher =
      Application.get_env(
        :wanderer_app,
        :discord_voice_guild_fetcher,
        &Nostrum.Cache.GuildCache.get!/1
      )

    fetcher.(guild_id)
  end

  @doc """
  Pure core: mention list from a guild's voice states. Public so tests can
  feed fixture guilds without Nostrum running.
  """
  @spec mentions_from_guild(map()) :: [String.t()]
  def mentions_from_guild(guild) do
    afk_channel_id = Map.get(guild, :afk_channel_id)
    voice_channel_ids = voice_channel_ids(guild, afk_channel_id)
    voice_states = Map.get(guild, :voice_states) || []

    mentions =
      voice_states
      |> Enum.filter(&(Map.get(&1, :channel_id) in voice_channel_ids))
      |> Enum.map(&"<@#{Map.get(&1, :user_id)}>")
      |> Enum.uniq()

    if mentions == [] and voice_states != [] do
      Logger.debug(fn ->
        "[VoiceParticipants] #{length(voice_states)} voice state(s) present " <>
          "but none in a taggable channel (afk_channel_id=#{inspect(afk_channel_id)})"
      end)
    end

    mentions
  end

  # Voice/stage channels minus the AFK channel. Filtering states against
  # this set covers both "in the AFK channel" and "in a non-voice channel".
  defp voice_channel_ids(guild, afk_channel_id) do
    (Map.get(guild, :channels) || %{})
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, :type) in @voice_channel_types))
    |> Enum.map(& &1.id)
    |> Enum.reject(&(&1 == afk_channel_id))
  end

  @doc """
  Joins mentions into a content prefix within `budget` characters, appending
  whole mentions until the next would overflow and silently dropping the
  rest. Returns `{prefix_or_nil, included_count}`.
  """
  @spec mention_prefix([String.t()], pos_integer()) ::
          {String.t() | nil, non_neg_integer()}
  def mention_prefix(mentions, budget \\ @mention_budget)

  def mention_prefix([], _budget), do: {nil, 0}

  def mention_prefix(mentions, budget) do
    {included, _size} =
      Enum.reduce_while(mentions, {[], 0}, fn mention, {acc, size} ->
        separator = if acc == [], do: 0, else: 1
        addition = String.length(mention) + separator

        if size + addition > budget do
          {:halt, {acc, size}}
        else
          {:cont, {[mention | acc], size + addition}}
        end
      end)

    case included do
      [] -> {nil, 0}
      list -> {list |> Enum.reverse() |> Enum.join(" "), length(list)}
    end
  end

  @doc """
  Prepends `prefix` to the first message's `"content"`; embeds and all other
  chunks untouched. `nil` prefix is the no-op path — no empty content key,
  no stray whitespace.
  """
  @spec prepend_to_messages([map()], String.t() | nil) :: [map()]
  def prepend_to_messages(messages, nil), do: messages
  def prepend_to_messages([], _prefix), do: []

  def prepend_to_messages([first | rest], prefix) do
    content =
      case Map.get(first, "content") do
        nil -> prefix
        existing -> prefix <> " " <> existing
      end

    [Map.put(first, "content", content) | rest]
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/unit/external_events/discord/voice_participants_test.exs`
Expected: PASS (all tests)

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/wanderer_app/external_events/discord/voice_participants.ex test/unit/external_events/discord/voice_participants_test.exs
git commit -m "feat(discord): voice participants module with mention budget"
```

---

### Task 3: VoiceGateway boot module + supervision entry

**Files:**
- Create: `lib/wanderer_app/external_events/discord/voice_gateway.ex`
- Modify: `lib/wanderer_app/application.ex` (`maybe_start_external_events_services/0`, webhook_services list at ~line 269)
- Test: `test/unit/external_events/discord/voice_gateway_test.exs` (create)

**Interfaces:**
- Consumes: `WandererApp.Env.discord_voice_mentions_enabled?/0`, `discord_bot_token/0`, `discord_guild_id/0` (Task 1).
- Produces: `VoiceGateway.start_link/1` returning `:ignore` always — a boot-time side-effect module, never a running process. Supervision order does not matter for correctness (mentions degrade to `[]` until the cache warms), but it is placed before `WorkerSupervisor` to start the gateway as early as possible.

- [ ] **Step 1: Write the failing test**

Create `test/unit/external_events/discord/voice_gateway_test.exs`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.VoiceGatewayTest do
  # async: false — mutates :external_events application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias WandererApp.ExternalEvents.Discord.VoiceGateway

  setup do
    original = Application.get_env(:wanderer_app, :external_events, [])
    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
    %{original: original}
  end

  defp put_voice_config(original, token, guild_id) do
    Application.put_env(
      :wanderer_app,
      :external_events,
      original
      |> Keyword.put(:discord_bot_token, token)
      |> Keyword.put(:discord_guild_id, guild_id)
    )
  end

  test "returns :ignore when the feature is unconfigured", %{original: original} do
    put_voice_config(original, nil, nil)
    assert VoiceGateway.start_link([]) == :ignore
  end

  test "warns once when config is partial (token without valid guild id)",
       %{original: original} do
    put_voice_config(original, "token-abc", "not-a-number")

    log =
      capture_log(fn ->
        assert VoiceGateway.start_link([]) == :ignore
      end)

    assert log =~ "DISCORD_GUILD_ID"
  end

  test "stays silent when nothing at all is configured", %{original: original} do
    put_voice_config(original, nil, nil)

    log =
      capture_log(fn ->
        assert VoiceGateway.start_link([]) == :ignore
      end)

    refute log =~ "DISCORD"
  end

  test "a failing gateway start logs an error and still returns :ignore",
       %{original: original} do
    put_voice_config(original, "token-abc", "123456789")

    Application.put_env(:wanderer_app, :discord_gateway_starter, fn :nostrum ->
      {:error, :boom}
    end)

    on_exit(fn -> Application.delete_env(:wanderer_app, :discord_gateway_starter) end)

    log =
      capture_log(fn ->
        assert VoiceGateway.start_link([]) == :ignore
      end)

    assert log =~ "failed to start"
  end

  test "a successful gateway start logs the enabled guild", %{original: original} do
    put_voice_config(original, "token-abc", "123456789")

    Application.put_env(:wanderer_app, :discord_gateway_starter, fn :nostrum ->
      {:ok, [:nostrum]}
    end)

    on_exit(fn -> Application.delete_env(:wanderer_app, :discord_gateway_starter) end)

    log =
      capture_log(fn ->
        assert VoiceGateway.start_link([]) == :ignore
      end)

    assert log =~ "voice mentions enabled for guild 123456789"
  end
end
```

Note: only the *real* gateway connection (live token, Discord reachable) stays untestable here — it is covered by the manual verification checklist in Task 5. The fail-open contract itself (error tuple → logged, `:ignore` returned, tree unharmed) is exercised through the `:discord_gateway_starter` seam, the same app-env seam pattern Task 2 uses for the guild fetch.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/unit/external_events/discord/voice_gateway_test.exs`
Expected: FAIL — module `VoiceGateway` is not available

- [ ] **Step 3: Implement the module**

Create `lib/wanderer_app/external_events/discord/voice_gateway.ex`:

```elixir
defmodule WandererApp.ExternalEvents.Discord.VoiceGateway do
  @moduledoc """
  Boot-time starter for the Nostrum gateway connection behind voice-mention
  kill notifications.

  Not a running process: `start_link/1` attempts the start and returns
  `:ignore`, so a failing gateway can never take the supervision tree with
  it — the invariant is that voice tagging degrades, kill delivery does
  not. Nostrum's own application supervises the connection from then on
  (reconnect/resume included).

  Startup outcomes are the one-time signals an operator needs: `info` on
  success, `error` on failure, one `warning` for partial configuration.
  After boot, per-lookup health is visible via the `mention_count`
  telemetry measurement and `VoiceParticipants` debug logs.
  """

  require Logger

  alias WandererApp.Env

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Nothing to restart: start_link always returns :ignore.
      restart: :temporary
    }
  end

  def start_link(_opts) do
    cond do
      Env.discord_voice_mentions_enabled?() ->
        start_gateway()

      Env.discord_bot_token() != nil or partial_guild_config?() ->
        Logger.warning(
          "[VoiceGateway] voice mentions disabled: set both DISCORD_BOT_TOKEN " <>
            "and a valid positive-integer DISCORD_GUILD_ID"
        )

      true ->
        :ok
    end

    :ignore
  end

  defp start_gateway do
    # Seam: tests inject a starter fun via app env to exercise the fail-open
    # contract without a live token; production starts Nostrum for real.
    starter =
      Application.get_env(
        :wanderer_app,
        :discord_gateway_starter,
        &Application.ensure_all_started/1
      )

    case starter.(:nostrum) do
      {:ok, _apps} ->
        Logger.info(
          "[VoiceGateway] Discord gateway started; voice mentions enabled " <>
            "for guild #{Env.discord_guild_id()}"
        )

      {:error, reason} ->
        Logger.error(
          "[VoiceGateway] Discord gateway failed to start: #{inspect(reason)} — " <>
            "kill notifications continue without voice mentions"
        )
    end
  end

  # A guild id that was set but failed to parse: Env returns nil for both
  # "unset" and "malformed", so re-read the raw value to tell them apart.
  defp partial_guild_config? do
    raw =
      Application.get_env(:wanderer_app, :external_events, [])
      |> Keyword.get(:discord_guild_id)

    raw != nil and Env.discord_guild_id() == nil
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/unit/external_events/discord/voice_gateway_test.exs`
Expected: PASS (5 tests)

- [ ] **Step 5: Add to the supervision tree**

In `lib/wanderer_app/application.ex`, `maybe_start_external_events_services/0`, extend the `webhook_services` list (~line 269) — VoiceGateway first, so the gateway starts warming before the first delivery:

```elixir
[
  WandererApp.ExternalEvents.WebhookDispatcher,
  # Boot-side-effect only (returns :ignore): starts the Nostrum gateway
  # when voice mentions are configured. Before the worker tree so the
  # voice cache starts warming as early as possible.
  WandererApp.ExternalEvents.Discord.VoiceGateway,
  # Supervisor before the dispatcher that routes work into it, so the
  # first event does not find the worker tree missing.
  WandererApp.ExternalEvents.Discord.WorkerSupervisor,
  WandererApp.ExternalEvents.DiscordDispatcher
]
```

- [ ] **Step 6: Verify compile and boot**

Run: `mix compile --warnings-as-errors && mix test test/unit/external_events/discord/`
Expected: compiles clean, all discord unit tests pass. (`maybe_start_external_events_services` returns `[]` in test env, so the tree change is exercised only at dev/prod boot; the compile check plus the `:ignore` contract cover it.)

- [ ] **Step 7: Format and commit**

```bash
mix format
git add lib/wanderer_app/external_events/discord/voice_gateway.ex lib/wanderer_app/application.ex test/unit/external_events/discord/voice_gateway_test.exs
git commit -m "feat(discord): conditional nostrum gateway startup for voice mentions"
```

---

### Task 4: Dispatcher injection + telemetry

**Files:**
- Modify: `lib/wanderer_app/external_events/discord_dispatcher.ex` (`deliver_to/5` ~line 667, `handle_delivery_result/4` ~line 690, alias block near top)
- Test: `test/unit/external_events/discord_dispatcher_test.exs` (extend)

**Interfaces:**
- Consumes: `VoiceParticipants.get_active_voice_mentions/0`, `mention_prefix/1` → `{String.t() | nil, non_neg_integer()}`, `prepend_to_messages/2` (Task 2); `Env.discord_voice_mentions_enabled?/0` (Task 1); test seam `:discord_voice_guild_fetcher` (Task 2).
- Produces: `[:wanderer_app, :discord_dispatcher, :dispatched]` telemetry gains a `mention_count` measurement on `:system` dispatches when the feature is enabled (absent otherwise).

- [ ] **Step 1: Write the failing tests**

In `test/unit/external_events/discord_dispatcher_test.exs`, add a fixture + helper near the other private helpers (e.g. after `disable_gate/0` ~line 204):

```elixir
# Guild fixture for voice-mention tests: users 111/222 in a voice channel,
# 333 in the AFK channel, channel 20 is text. Shapes mirror Nostrum structs.
@voice_guild %{
  id: 999,
  afk_channel_id: 30,
  channels: %{
    10 => %{id: 10, type: 2},
    20 => %{id: 20, type: 0},
    30 => %{id: 30, type: 2}
  },
  voice_states: [
    %{user_id: 111, channel_id: 10},
    %{user_id: 222, channel_id: 10},
    %{user_id: 333, channel_id: 30}
  ]
}

defp enable_voice_mentions(fetcher \\ nil) do
  original = Application.get_env(:wanderer_app, :external_events, [])

  Application.put_env(
    :wanderer_app,
    :external_events,
    original
    |> Keyword.put(:discord_bot_token, "test-token")
    |> Keyword.put(:discord_guild_id, "999")
  )

  Application.put_env(
    :wanderer_app,
    :discord_voice_guild_fetcher,
    fetcher || fn 999 -> @voice_guild end
  )

  on_exit(fn ->
    Application.put_env(:wanderer_app, :external_events, original)
    Application.delete_env(:wanderer_app, :discord_voice_guild_fetcher)
  end)
end
```

Then add the tests (alongside the other delivery tests):

```elixir
describe "voice mentions" do
  test "system-channel kills carry voice mentions in content", %{map: map, system: w} do
    enable_voice_mentions()

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
    DiscordDispatcher.dispatch_event(map.id, event)
    settle(w.id)

    assert [{@system_url, body}] = wait_for_requests(1)
    assert body["content"] == "<@111> <@222>"
    refute body["content"] =~ "<@333>", "AFK-channel user must not be pinged"
  end

  test "character-channel kills carry no mentions", %{map: map, notification: n} do
    enable_voice_mentions()
    character_webhook(n)
    track(map.id, [8000])

    event =
      kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system, victim_char_id: 8000}))

    DiscordDispatcher.dispatch_event(map.id, event)

    assert [{@character_url, body}] = wait_for_requests(1)
    refute Map.has_key?(body, "content")
  end

  test "feature disabled leaves messages byte-identical", %{map: map, system: w} do
    # No enable_voice_mentions(): test env has no token/guild id.
    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
    DiscordDispatcher.dispatch_event(map.id, event)
    settle(w.id)

    assert [{@system_url, body}] = wait_for_requests(1)
    refute Map.has_key?(body, "content")
  end

  test "a raising guild fetch still delivers the kill, without mentions",
       %{map: map, system: w} do
    enable_voice_mentions(fn _guild_id -> raise "cache boom" end)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
    DiscordDispatcher.dispatch_event(map.id, event)
    settle(w.id)

    assert [{@system_url, body}] = wait_for_requests(1)
    refute Map.has_key?(body, "content")
  end

  test "dispatch telemetry carries mention_count when enabled", %{map: map, system: w} do
    enable_voice_mentions()

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "voice-mention-count-#{inspect(ref)}",
      [:wanderer_app, :discord_dispatcher, :dispatched],
      fn _event, measurements, metadata, _config ->
        send(parent, {:dispatched, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("voice-mention-count-#{inspect(ref)}") end)

    event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
    DiscordDispatcher.dispatch_event(map.id, event)
    settle(w.id)
    wait_for_requests(1)

    assert_receive {:dispatched, ^ref, measurements, %{role: :system}}, 2_000
    assert measurements.mention_count == 2
  end
end
```

Also add a multi-chunk test asserting only the first chunk is touched:

```elixir
test "multi-chunk event: mentions on the first chunk only, overflow line intact",
     %{map: map, system: w} do
  enable_voice_mentions()

  # 31 kills: 30 rendered, 1 overflow. NEVER hard-code the request count —
  # chunking depends on embed sizes, so derive it from the formatter, the
  # same way "does not burn kills dropped by the formatter's per-event cap"
  # (~line 522) does.
  kills = Enum.map(1..31, fn i -> killmail(20_000 + i) end)
  expected_count = length(EmbedFormatter.format_batch(entries(kills), "J115405"))
  assert expected_count > 1, "fixture must produce a multi-chunk event"

  # Mirror the multi-kill event construction used by the existing batch tests
  # in this file (~line 522) — that construction is authoritative, not this
  # comment.
  event = kill_event(%{"kills" => kills})

  DiscordDispatcher.dispatch_event(map.id, event)
  settle(w.id)

  requests = wait_for_requests(expected_count)
  bodies = Enum.map(requests, fn {_url, body} -> body end)

  assert hd(bodies)["content"] == "<@111> <@222>"

  assert List.last(bodies)["content"] == "…and 1 more kills not shown.",
         "overflow line must not be disturbed by mention injection"

  for body <- bodies |> tl() |> Enum.drop(-1) do
    refute Map.has_key?(body, "content")
  end
end

test "enabled but nobody in voice: no content, telemetry mention_count 0",
     %{map: map, system: w} do
  enable_voice_mentions(fn 999 ->
    %{id: 999, afk_channel_id: nil, channels: %{}, voice_states: []}
  end)

  ref = make_ref()
  parent = self()

  :telemetry.attach(
    "voice-empty-#{inspect(ref)}",
    [:wanderer_app, :discord_dispatcher, :dispatched],
    fn _event, measurements, metadata, _config ->
      send(parent, {:dispatched, ref, measurements, metadata})
    end,
    nil
  )

  on_exit(fn -> :telemetry.detach("voice-empty-#{inspect(ref)}") end)

  event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
  DiscordDispatcher.dispatch_event(map.id, event)
  settle(w.id)

  assert [{@system_url, body}] = wait_for_requests(1)
  refute Map.has_key?(body, "content")

  assert_receive {:dispatched, ^ref, measurements, %{role: :system}}, 2_000
  assert measurements.mention_count == 0
end

test "disabled: dispatch telemetry carries no mention_count key", %{map: map, system: w} do
  # No enable_voice_mentions(): absent measurement is the "feature off"
  # signal, distinct from mention_count 0 ("enabled but nobody taggable").
  ref = make_ref()
  parent = self()

  :telemetry.attach(
    "voice-absent-#{inspect(ref)}",
    [:wanderer_app, :discord_dispatcher, :dispatched],
    fn _event, measurements, metadata, _config ->
      send(parent, {:dispatched, ref, measurements, metadata})
    end,
    nil
  )

  on_exit(fn -> :telemetry.detach("voice-absent-#{inspect(ref)}") end)

  event = kill_event(Factory.build(:kill_event, %{solar_system_id: @wh_system}))
  DiscordDispatcher.dispatch_event(map.id, event)
  settle(w.id)
  wait_for_requests(1)

  assert_receive {:dispatched, ^ref, measurements, %{role: :system}}, 2_000
  refute Map.has_key?(measurements, :mention_count)
end
```

**Check the existing batch tests first** (e.g. "does not burn kills dropped by the formatter's per-event cap" ~line 522) for how a multi-kill event payload is actually constructed, and mirror that construction exactly — the `%{"kills" => ...}` shape above must be corrected to whatever the existing test uses.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs`
Expected: the new "voice mentions" tests FAIL (no content injected, no `mention_count`); every pre-existing test still PASSES.

- [ ] **Step 3: Implement the injection**

In `lib/wanderer_app/external_events/discord_dispatcher.ex`:

1. Add `VoiceParticipants` to the existing `alias WandererApp.ExternalEvents.Discord.{...}` block.
2. Replace `deliver_to/5`'s delivery pipeline (~line 684):

```elixir
{prefix, mention_count} = voice_mention_prefix(role)

entries
|> EmbedFormatter.format_batch(system_name)
|> VoiceParticipants.prepend_to_messages(prefix)
|> then(&WorkerSupervisor.deliver(webhook.id, &1))
|> handle_delivery_result(map_id, role, marked, mention_count)
```

3. Add the private helper below `deliver_to/5`:

```elixir
# Voice mentions go to the system channel only (spec decision), and only
# when configured. `nil` count means "feature off" and keeps the
# measurement out of telemetry entirely, so 0 always means "enabled but
# nobody taggable" — the distinction operators need.
defp voice_mention_prefix(:system) do
  if Env.discord_voice_mentions_enabled?() do
    VoiceParticipants.get_active_voice_mentions()
    |> VoiceParticipants.mention_prefix()
  else
    {nil, nil}
  end
end

defp voice_mention_prefix(_role), do: {nil, nil}
```

(If the module refers to `WandererApp.Env` unaliased, use the full name — match the file's existing style.)

4. Extend `handle_delivery_result` — all three clauses gain a trailing `mention_count` argument (ignored except in the `:ok` clause):

```elixir
defp handle_delivery_result(:ok, map_id, role, kills, mention_count) do
  measurements =
    case mention_count do
      nil -> %{count: length(kills)}
      n -> %{count: length(kills), mention_count: n}
    end

  :telemetry.execute(
    [:wanderer_app, :discord_dispatcher, :dispatched],
    measurements,
    %{map_id: map_id, role: role}
  )
end
```

The `{:error, :not_running}` and `{:error, reason}` clauses change only their head: append `, _mention_count`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/unit/external_events/discord_dispatcher_test.exs`
Expected: PASS — all new and all pre-existing tests.

- [ ] **Step 5: Run the wider discord suite**

Run: `mix test test/unit/external_events/`
Expected: PASS (no regressions in worker/router/formatter tests).

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/wanderer_app/external_events/discord_dispatcher.ex test/unit/external_events/discord_dispatcher_test.exs
git commit -m "feat(discord): prepend voice-participant mentions to system kill notifications"
```

---

### Task 5: Docs, full verification, manual gateway check

**Files:**
- Modify: `.claude/references/zoo-extensions.md` — **main checkout only, post-merge**: this file is untracked and `.claude/` is in `.git/info/exclude`, so it exists only in the main checkout, not in this worktree, and can never be committed.
- Test: full suite + static analysis

**Interfaces:**
- Consumes: everything above.
- Produces: documented, verified feature.

- [ ] **Step 1: Document the zoo extension (manual, after merge)**

The tracked documentation of record is the spec + this plan. `.claude/references/zoo-extensions.md` is a local-only reference file that does not exist in the worktree — do NOT create it here and do NOT `git add` it. After the branch merges, append the following in the **main checkout** (match the file's existing heading style):

```markdown
## Discord Voice-Participant Mentions

System-channel kill notifications prepend `<@user_id>` mentions for every
member active in a voice channel of the configured guild (AFK channel
excluded). Requires `DISCORD_BOT_TOKEN` + `DISCORD_GUILD_ID`; the bot must
be invited to the guild (no permissions needed beyond guild visibility).
Intents: `guilds`, `guild_voice_states` (non-privileged).

- Modules: `ExternalEvents.Discord.VoiceGateway` (conditional Nostrum
  startup), `ExternalEvents.Discord.VoiceParticipants` (mention logic,
  1,800-char content budget), injection in `DiscordDispatcher.deliver_to/5`.
- Character-channel deliveries never carry mentions.
- Telemetry: `[:wanderer_app, :discord_dispatcher, :dispatched]` gains
  `mention_count` on system dispatches when enabled.
- Spec: `docs/superpowers/specs/2026-08-07-discord-voice-mentions-design.md`.
```

- [ ] **Step 2: Full verification**

```bash
mix format --check-formatted
mix credo
mix compile --warnings-as-errors
mix test test/unit/external_events/ test/unit/env_discord_voice_test.exs
mix test
```

Expected: all pass. If `mix dialyzer` is part of the repo's routine (PLT already built), run it too; otherwise note it skipped.

- [ ] **Step 3: Manual gateway verification (requires operator)**

This is the one part automated tests cannot cover. With a real bot token and guild id in `.env`:

1. `make server` — expect `[VoiceGateway] Discord gateway started; voice mentions enabled for guild <id>` in the log.
2. Join a voice channel; trigger/await a kill in a mapped system → the system-channel message starts with your mention and pings you.
3. Move to the AFK channel; next kill → no mention of you.
4. Unset both env vars, restart → no VoiceGateway log lines, notifications unchanged from pre-feature behavior.
5. If Nostrum fails to boot without a consumer process (watch for a startup error naming consumers), add a minimal no-op consumer module and re-verify:

```elixir
defmodule WandererApp.ExternalEvents.Discord.VoiceGateway.Consumer do
  @moduledoc """
  No-op consumer: Nostrum requires at least one consumer process in some
  configurations. Voice states reach the GuildCache regardless; events are
  discarded here.
  """
  use Nostrum.Consumer

  def handle_event(_event), do: :noop
end
```

Started from `VoiceGateway.start_gateway/0` after `ensure_all_started` succeeds, via `WandererApp.ExternalEvents.Discord.VoiceGateway.Consumer.start_link/0` — only add this if step 5's failure actually occurs.

- [ ] **Step 4: Confirm nothing is left uncommitted in the worktree**

No docs commit here — the zoo-extensions.md update is the post-merge manual
step above. Verify the worktree is clean:

```bash
git status --short
```

Expected: empty output (all implementation commits landed in Tasks 1-4).
