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

  defp put_key(key, value) do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, key, value)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
    :ok
  end

  defp delete_key(key) do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.delete(original, key)
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

    # `0` would otherwise silently drop every killmail (a kill that has already
    # happened always has a non-negative age, and the guard keeps a kill only
    # when `age <= max`), and a negative value is stricter still — it would keep
    # only kills timestamped in the future. Both fail in the same direction, so
    # both are treated the same way — a misconfiguration, not a valid setting —
    # falling back to the default with a loud warning rather than being honoured.
    test "falls back to the default and warns when configured as zero" do
      put_max_age(0)

      log =
        capture_log(fn ->
          assert Env.discord_max_killmail_age_seconds() == 3600
        end)

      assert log =~ "discord_max_killmail_age_seconds"
    end

    test "falls back to the default and warns when configured as negative" do
      put_max_age(-60)

      log =
        capture_log(fn ->
          assert Env.discord_max_killmail_age_seconds() == 3600
        end)

      assert log =~ "discord_max_killmail_age_seconds"
    end

    test "falls back to the default and warns when configured as a non-integer" do
      put_max_age("not-a-number")

      log =
        capture_log(fn ->
          assert Env.discord_max_killmail_age_seconds() == 3600
        end)

      assert log =~ "discord_max_killmail_age_seconds"
    end
  end

  describe "Env.discord_startup_grace_seconds/0" do
    test "defaults to 600 when the key is absent" do
      delete_key(:discord_startup_grace_seconds)

      assert Env.discord_startup_grace_seconds() == 600
    end

    test "returns the configured value, not only the default" do
      put_key(:discord_startup_grace_seconds, 90)

      assert Env.discord_startup_grace_seconds() == 90
    end

    # THE test for this key. `0` means "no startup window" and must be honoured
    # rather than treated as a misconfiguration. Routing this key through
    # `validate_positive_integer/3` would return 600 here and turn an operator's
    # "disabled" into ten minutes of tightened freshness -- and would break
    # config/test.exs, which uses exactly this value.
    test "honours zero as 'window disabled' rather than falling back" do
      put_key(:discord_startup_grace_seconds, 0)

      log =
        capture_log(fn ->
          assert Env.discord_startup_grace_seconds() == 0
        end)

      refute log =~ "discord_startup_grace_seconds"
    end

    test "falls back to the default and warns when configured as negative" do
      put_key(:discord_startup_grace_seconds, -1)

      log =
        capture_log(fn ->
          assert Env.discord_startup_grace_seconds() == 600
        end)

      assert log =~ "discord_startup_grace_seconds"
    end

    test "falls back to the default and warns when configured as a non-integer" do
      put_key(:discord_startup_grace_seconds, "ten minutes")

      log =
        capture_log(fn ->
          assert Env.discord_startup_grace_seconds() == 600
        end)

      assert log =~ "discord_startup_grace_seconds"
    end
  end

  describe "Env.discord_startup_max_killmail_age_seconds/0" do
    test "defaults to 120 when the key is absent" do
      delete_key(:discord_startup_max_killmail_age_seconds)

      assert Env.discord_startup_max_killmail_age_seconds() == 120
    end

    test "returns the configured value, not only the default" do
      put_key(:discord_startup_max_killmail_age_seconds, 45)

      assert Env.discord_startup_max_killmail_age_seconds() == 45
    end

    # The opposite of the grace key: here `0` IS a misconfiguration, because a
    # kill that has already happened always has a non-negative age and the guard
    # keeps a kill only when `age <= max`.
    test "falls back to the default and warns when configured as zero" do
      put_key(:discord_startup_max_killmail_age_seconds, 0)

      log =
        capture_log(fn ->
          assert Env.discord_startup_max_killmail_age_seconds() == 120
        end)

      assert log =~ "discord_startup_max_killmail_age_seconds"
    end

    test "falls back to the default and warns when configured as a non-integer" do
      put_key(:discord_startup_max_killmail_age_seconds, :soon)

      log =
        capture_log(fn ->
          assert Env.discord_startup_max_killmail_age_seconds() == 120
        end)

      assert log =~ "discord_startup_max_killmail_age_seconds"
    end
  end

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
end
