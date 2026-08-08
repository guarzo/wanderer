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
