defmodule WandererApp.ExternalEvents.DiscordStartupWindowTest do
  # `async: false` is mandatory: this file mutates application env and shares
  # the global `:discord_dedup_cache` with every other test.
  use WandererApp.DataCase, async: false

  alias WandererApp.ExternalEvents.DiscordDispatcher
  alias WandererApp.ExternalEvents.Event
  alias WandererApp.ExternalEvents.Discord.{HttpStub, WorkerSupervisor}
  alias WandererAppWeb.Factory

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

  # Mirrors discord_dispatcher_test.exs:185-204. `wh_only` filtering resolves
  # the system class through this cache, and the table behind it is static
  # import data that `mix test` does not populate.
  defp seed_static_info do
    Cachex.put(:system_static_info_cache, 31_000_005, %{
      solar_system_id: 31_000_005,
      solar_system_name: "J115405",
      system_class: 3
    })

    on_exit(fn -> Cachex.del(:system_static_info_cache, 31_000_005) end)
    :ok
  end

  # Closes the window without touching the dispatcher. Because the sentinel is
  # read per batch, a zero grace plus a cleared sentinel means the NEXT batch
  # arms a deadline that is already in the past. Both halves are needed: a
  # surviving sentinel would make the batch reuse the already-armed 600s
  # deadline from `setup` and the config change would do nothing.
  defp close_window do
    put_keys(discord_startup_grace_seconds: 0)
    Cachex.del(DiscordDispatcher.dedup_cache(), DiscordDispatcher.startup_sentinel_key())
    :ok
  end

  # Collects every drop event raised while `fun` runs, as {reason, count}.
  # Dispatch is a cast, so drain the dispatcher's mailbox before reading.
  defp capture_drops(fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:wanderer_app, :discord_dispatcher, :killmail_dropped],
      fn _event, measurements, metadata, _config ->
        Agent.update(agent, &[{metadata.reason, measurements.count} | &1])
      end,
      nil
    )

    try do
      fun.()
      :sys.get_state(DiscordDispatcher)
      Agent.get(agent, &Enum.reverse/1)
    after
      :telemetry.detach(handler_id)
      Agent.stop(agent)
    end
  end

  # Mirrors discord_dispatcher_test.exs:325-342. Absence of a drop event is NOT
  # evidence of delivery -- a kill silently lost anywhere else on the path would
  # satisfy `drops == []` just as well. The tests that claim a kill was
  # delivered assert an actual outbound request.
  defp wait_for_requests(count, timeout \\ 2_000) do
    do_wait(count, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_wait(count, deadline) do
    cond do
      length(HttpStub.requests()) >= count ->
        HttpStub.requests()

      System.monotonic_time(:millisecond) > deadline ->
        flunk("expected #{count} requests, got #{length(HttpStub.requests())}")

      true ->
        Process.sleep(25)
        do_wait(count, deadline)
    end
  end

  defp aged_kill(id, seconds_ago) do
    Factory.build(:killmail, %{
      "killmail_id" => id,
      "solar_system_id" => 31_000_005,
      "kill_time" =>
        DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.to_iso8601()
    })
  end

  defp dispatch(map_id, kills) do
    payload = Factory.build(:kill_event, %{solar_system_id: 31_000_005, killmails: kills})

    DiscordDispatcher.dispatch_event(map_id, %Event{
      map_id: nil,
      type: :map_kill,
      payload: payload
    })
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

  describe "drop telemetry" do
    setup do
      seed_static_info()

      # `config/test.exs` sets `webhooks_enabled: false` and the dispatcher
      # reads it at call time, so without this override every assertion below
      # would pass while dispatching nothing.
      put_keys(webhooks_enabled: true, discord_startup_grace_seconds: 600)
      clear_sentinel()

      HttpStub.start()
      HttpStub.reset()
      start_supervised!(WorkerSupervisor)
      start_supervised!(DiscordDispatcher)

      map = Factory.insert(:map, %{})

      {:ok, _notification} =
        WandererApp.Api.MapDiscordNotification.create(%{
          map_id: map.id,
          webhook_url: "https://discord.com/api/webhooks/123/tok"
        })

      DiscordDispatcher.invalidate_cache(map.id)

      %{map: map}
    end

    # 5 minutes old: inside the ordinary 3600s limit, outside the 120s startup
    # limit. This is the exact killmail the window exists to suppress.
    test "a kill dropped by the startup window reports :startup_age", %{map: map} do
      drops = capture_drops(fn -> dispatch(map.id, [aged_kill(5001, 300)]) end)

      assert drops == [{:startup_age, 1}]
      assert HttpStub.requests() == []
    end

    # The same kill, with the window closed, is delivered -- proving the drop
    # above is the window's doing and not the ordinary limit. Asserting the
    # request, not merely the absence of a drop event: a kill lost anywhere
    # else on the path would satisfy `drops == []` and make this test vacuous.
    test "the same kill is not dropped once the window has closed", %{map: map} do
      close_window()

      drops = capture_drops(fn -> dispatch(map.id, [aged_kill(5002, 300)]) end)

      assert drops == []
      assert length(wait_for_requests(1)) == 1
    end

    # Two hours old: outside BOTH limits. THE test for per-kill classification
    # -- it runs with the window WIDE OPEN, because that is the only condition
    # under which the two reasons can be confused. Classifying by `startup?`
    # alone reports `:startup_age` here and inflates the window's apparent
    # impact with a kill the pre-existing hour limit would have dropped anyway.
    test "a kill older than the ordinary limit reports :age even inside the window",
         %{map: map} do
      assert DiscordDispatcher.within_startup_grace?(DiscordDispatcher.arm_startup_grace())

      drops = capture_drops(fn -> dispatch(map.id, [aged_kill(5003, 7200)]) end)

      assert drops == [{:age, 1}]
    end

    # Both reasons in one batch, so the counts cannot be right by accident:
    # a single classification for the whole batch produces `[{:startup_age, 2}]`
    # or `[{:age, 2}]`, never this.
    test "a mixed batch splits the two age reasons", %{map: map} do
      drops =
        capture_drops(fn ->
          dispatch(map.id, [aged_kill(5006, 300), aged_kill(5007, 7200)])
        end)

      assert Enum.sort(drops) == [{:age, 1}, {:startup_age, 1}]
    end

    test "a repeated kill reports :duplicate", %{map: map} do
      close_window()
      kill = aged_kill(5004, 10)

      on_exit(fn ->
        Cachex.del(DiscordDispatcher.dedup_cache(), DiscordDispatcher.dedup_key(map.id, 5004))
      end)

      capture_drops(fn -> dispatch(map.id, [kill]) end)
      # The first dispatch must actually have been delivered and marked, or the
      # second one is not a duplicate of anything.
      assert length(wait_for_requests(1)) == 1

      drops = capture_drops(fn -> dispatch(map.id, [kill]) end)

      assert drops == [{:duplicate, 1}]
    end

    # No event at all when nothing is dropped: a counter that fires with
    # `count: 0` on every healthy batch is noise that buries the real signal.
    test "a fresh kill emits no drop event", %{map: map} do
      close_window()

      drops = capture_drops(fn -> dispatch(map.id, [aged_kill(5005, 10)]) end)

      assert drops == []
      assert length(wait_for_requests(1)) == 1
    end
  end
end
