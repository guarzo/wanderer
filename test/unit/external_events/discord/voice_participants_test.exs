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
