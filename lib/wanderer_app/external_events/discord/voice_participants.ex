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
