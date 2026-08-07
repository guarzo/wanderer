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

  test "blank or whitespace-only token reads as unset and disables the feature",
       %{original: original} do
    for blank <- ["", "   ", "\n", "\t "] do
      put_voice_config(original, blank, "123456789")
      assert Env.discord_bot_token() == nil, "expected #{inspect(blank)} to normalize to nil"
      refute Env.discord_voice_mentions_enabled?()
    end
  end

  test "token surrounded by whitespace is trimmed", %{original: original} do
    put_voice_config(original, "  token-abc\n", "123456789")
    assert Env.discord_bot_token() == "token-abc"
    assert Env.discord_voice_mentions_enabled?()
  end
end
