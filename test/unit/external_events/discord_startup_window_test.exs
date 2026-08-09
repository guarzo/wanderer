defmodule WandererApp.ExternalEvents.DiscordStartupWindowTest do
  # `async: false` is mandatory: this file mutates application env and shares
  # the global `:discord_dedup_cache` with every other test.
  use WandererApp.DataCase, async: false

  alias WandererApp.ExternalEvents.DiscordDispatcher

  # Restores the whole `:external_events` list, per the global constraint.
  defp put_keys(pairs) do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Enum.reduce(pairs, original, fn {k, v}, acc -> Keyword.put(acc, k, v) end)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
    :ok
  end

  # `:discord_dedup_cache` is global and NOT sandboxed, so the sentinel written
  # by any earlier test in the run is still there. Clearing it is what "the
  # dedup cache is new" means, and every test here must start from a known
  # state or it silently asserts nothing.
  defp clear_sentinel do
    Cachex.del(DiscordDispatcher.dedup_cache(), DiscordDispatcher.startup_sentinel_key())

    on_exit(fn ->
      Cachex.del(DiscordDispatcher.dedup_cache(), DiscordDispatcher.startup_sentinel_key())
    end)

    :ok
  end

  describe "arming" do
    # These drive `arm_startup_grace/0` directly rather than through
    # `start_supervised!(DiscordDispatcher)`. That is the point: the window is
    # armed per batch, so its behaviour has nothing to do with the dispatcher's
    # lifecycle, and a test that restarted the dispatcher would be asserting
    # against the wrong lifecycle -- the exact mistake an earlier draft made.
    test "arms when the dedup cache carries no sentinel" do
      put_keys(discord_startup_grace_seconds: 600)
      clear_sentinel()

      arm_until = DiscordDispatcher.arm_startup_grace()

      assert is_integer(arm_until)
      assert arm_until > System.monotonic_time(:millisecond)
    end

    # Row 3 of the lifecycle table, and the case an earlier draft of the design
    # got backwards. The marks survived, so the window must NOT re-arm --
    # otherwise every batch silently pushes the deadline further out and the
    # window never closes at all.
    #
    # The grace is RAISED tenfold between the two calls, so a re-arm would move
    # the deadline by about 5,400,000 ms. Comparing two calls made under the
    # same grace would instead hinge on millisecond resolution, and would pass
    # by coincidence whenever both landed in the same millisecond.
    test "does not re-arm when the sentinel is already present" do
      put_keys(discord_startup_grace_seconds: 600)
      clear_sentinel()

      first = DiscordDispatcher.arm_startup_grace()

      put_keys(discord_startup_grace_seconds: 6000)

      assert DiscordDispatcher.arm_startup_grace() == first
    end

    # Row 2: the dedup cache crashed alone, taking every mark with it. Nothing
    # restarted the dispatcher. Same tenfold grace change, so the assertion
    # cannot pass on a same-millisecond coincidence in either direction.
    test "re-arms after the sentinel is cleared" do
      put_keys(discord_startup_grace_seconds: 600)
      clear_sentinel()

      first = DiscordDispatcher.arm_startup_grace()

      Cachex.del(DiscordDispatcher.dedup_cache(), DiscordDispatcher.startup_sentinel_key())
      put_keys(discord_startup_grace_seconds: 6000)

      assert DiscordDispatcher.arm_startup_grace() - first > 5_000_000
    end

    test "a zero grace period leaves the window closed immediately" do
      put_keys(discord_startup_grace_seconds: 0)
      clear_sentinel()

      refute DiscordDispatcher.within_startup_grace?(DiscordDispatcher.arm_startup_grace())
    end

    # Guards Deviation 2: `:discord_dedup_cache` has a 24h default_ttl, and
    # `Cachex.put/4` honours only an integer `:ttl`, so a bare put would leave
    # the sentinel expiring after a day -- after which the window would
    # spuriously re-arm on a healthy cache that never lost a mark.
    test "the sentinel never expires" do
      put_keys(discord_startup_grace_seconds: 600)
      clear_sentinel()

      DiscordDispatcher.arm_startup_grace()

      assert Cachex.ttl(
               DiscordDispatcher.dedup_cache(),
               DiscordDispatcher.startup_sentinel_key()
             ) == {:ok, nil}
    end
  end

  describe "within_startup_grace?/1" do
    test "an armed deadline in the future is inside the window" do
      assert DiscordDispatcher.within_startup_grace?(System.monotonic_time(:millisecond) + 60_000)
    end

    test "a deadline in the past is outside the window" do
      refute DiscordDispatcher.within_startup_grace?(System.monotonic_time(:millisecond) - 1)
    end

    # The value the dispatcher falls back to when the sentinel is unreadable.
    # A plain integer would be wrong here: Erlang monotonic time may be
    # negative, so `0` is not reliably "in the past".
    test "an unarmed window is never inside it" do
      refute DiscordDispatcher.within_startup_grace?(:never)
    end
  end
end
