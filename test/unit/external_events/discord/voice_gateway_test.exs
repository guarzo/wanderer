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

    # Temporarily lower the logger level to capture info logs during the test
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    log =
      capture_log(fn ->
        assert VoiceGateway.start_link([]) == :ignore
      end)

    assert log =~ "voice mentions enabled for guild 123456789"
  end
end
