defmodule WandererApp.ExternalEvents.Discord.RouteWatcherSupervisorTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.ExternalEvents.Discord.{RouteWatcher, RouteWatcherSupervisor}
  alias WandererAppWeb.Factory

  setup do
    start_supervised!(RouteWatcherSupervisor)
    :ok
  end

  test "notify starts a watcher on demand" do
    map_id = Ecto.UUID.generate()
    assert :ok = RouteWatcherSupervisor.notify(map_id)
    assert [{_pid, _}] = Registry.lookup(RouteWatcher.registry(), map_id)
  end

  test "two notifies for one map reuse one watcher" do
    map_id = Ecto.UUID.generate()
    RouteWatcherSupervisor.notify(map_id)
    [{pid1, _}] = Registry.lookup(RouteWatcher.registry(), map_id)

    RouteWatcherSupervisor.notify(map_id)
    [{pid2, _}] = Registry.lookup(RouteWatcher.registry(), map_id)

    assert pid1 == pid2
  end

  test "stop_watcher removes the running watcher" do
    map_id = Ecto.UUID.generate()
    RouteWatcherSupervisor.notify(map_id)
    assert [{pid, _}] = Registry.lookup(RouteWatcher.registry(), map_id)
    ref = Process.monitor(pid)

    assert :ok = RouteWatcherSupervisor.stop_watcher(map_id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

    # Registry cleans up its entry asynchronously when the owner dies, so the
    # :DOWN can arrive before the key is released. Poll rather than sleep.
    await_condition(fn ->
      case Registry.lookup(RouteWatcher.registry(), map_id) do
        [] -> {:ok, []}
        _ -> :retry
      end
    end)
  end

  test "notify is a no-op when the supervisor tree is not running" do
    stop_supervised!(RouteWatcherSupervisor)
    map_id = Ecto.UUID.generate()
    assert :ok = RouteWatcherSupervisor.notify(map_id)
  end

  test "stop_watcher tolerates the tree being gone" do
    map_id = Ecto.UUID.generate()
    RouteWatcherSupervisor.notify(map_id)
    assert [{pid, _}] = Registry.lookup(RouteWatcher.registry(), map_id)

    # Stopping the supervisor kills its DynamicSupervisor child and, with it,
    # the watcher registered above — so this exercises stop_watcher/1's
    # lookup-then-stop path with a real (now-dead) pid, not an empty lookup
    # that would pass whether or not the guard exists.
    stop_supervised!(RouteWatcherSupervisor)
    refute Process.alive?(pid)

    assert :ok = RouteWatcherSupervisor.stop_watcher(map_id)
  end

  describe "resource integration" do
    setup do
      map = Factory.insert(:map, %{})

      {:ok, notification} =
        MapDiscordNotification.create(%{
          map_id: map.id,
          webhook_url: "https://discord.com/api/webhooks/1/tok"
        })

      %{map: map, notification: notification}
    end

    test "destroying the notification stops its map's route watcher", %{
      map: map,
      notification: notification
    } do
      RouteWatcherSupervisor.notify(map.id)
      assert [{pid, _}] = Registry.lookup(RouteWatcher.registry(), map.id)

      :ok = MapDiscordNotification.destroy(notification)

      refute Process.alive?(pid)
    end

    # Regression for the Critical finding in round 1 of review: stop_watcher/1
    # used to stop the process but leave its cached route_state behind in the
    # TTL-less :discord_route_alert_cache. A re-created notification for the
    # same map would then rehydrate the STALE state (e.g. already
    # `{:qualifying, 5}`), so the transition table — which only posts
    # `:opened` from `:unknown` or `:none` — would silently never announce a
    # route that was, in fact, still open. Seeding the cache directly here
    # simulates "a watcher already ran and persisted a result" without needing
    # a real solve.
    test "destroying then re-creating the notification does not resurrect stale route_state",
         %{map: map, notification: notification} do
      Cachex.put(:discord_route_alert_cache, map.id, %{
        route_state: {:qualifying, 5},
        config_version: "stale"
      })

      :ok = MapDiscordNotification.destroy(notification)

      {:ok, _recreated} =
        MapDiscordNotification.create(%{
          map_id: map.id,
          webhook_url: "https://discord.com/api/webhooks/2/tok"
        })

      RouteWatcherSupervisor.notify(map.id)
      assert [{pid, _}] = Registry.lookup(RouteWatcher.registry(), map.id)

      assert %{route_state: :unknown} = :sys.get_state(pid)
    end
  end

  defp await_condition(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_condition(fun, deadline)
  end

  defp do_await_condition(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met before deadline")
        else
          Process.sleep(25)
          do_await_condition(fun, deadline)
        end
    end
  end
end
