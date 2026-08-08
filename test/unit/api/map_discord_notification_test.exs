defmodule WandererApp.Api.MapDiscordNotificationTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.ExternalEvents.Discord.{Worker, WorkerSupervisor}
  alias WandererAppWeb.Factory

  defp valid_url, do: "https://discord.com/api/webhooks/123456789/abcdefTOKEN"

  # The dispatcher's per-map config cache, seeded and read directly so these
  # tests do not depend on the dispatcher GenServer running.
  @cache :discord_notification_cache

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

  setup do
    map = Factory.insert(:map, %{})
    %{map: map}
  end

  test "creates with policy defaults", %{map: map} do
    assert {:ok, rec} =
             MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert rec.enabled? == true
    assert rec.wh_only == true
    assert rec.excluded_systems == []
    assert rec.focus_corp_ids == []
  end

  test "no longer carries webhook_url or failure state", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    refute Map.has_key?(rec, :webhook_url)
    refute Map.has_key?(rec, :consecutive_failures)
    refute Map.has_key?(rec, :last_error)
    refute Map.has_key?(rec, :last_error_at)
    refute Map.has_key?(rec, :last_delivery_at)
  end

  test "focus_corp_ids round-trips", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, rec} =
             MapDiscordNotification.update(rec, %{focus_corp_ids: [98_000_001, 98_000_002]})

    assert rec.focus_corp_ids == [98_000_001, 98_000_002]

    assert {:ok, reloaded} = MapDiscordNotification.by_map(map.id)
    assert reloaded.focus_corp_ids == [98_000_001, 98_000_002]
  end

  test "create makes the parent and its :system webhook in one transaction", %{map: map} do
    assert {:ok, rec} =
             MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, [hook]} = MapDiscordWebhook.by_notification(rec.id)
    assert hook.role == :system
    assert hook.webhook_url == valid_url()
  end

  test "a rejected webhook url leaves no parent row behind", %{map: map} do
    # The invariant "a system webhook always exists" is transactional, not
    # declarative — the unique identity gives at most one webhook per role, never
    # at least one. If the child create fails the parent must roll back, or the
    # map is left with a policy row and nowhere to deliver.
    assert {:error, _} =
             MapDiscordNotification.create(%{
               map_id: map.id,
               webhook_url: "https://evil.example.com/api/webhooks/1/tok"
             })

    assert {:error, _} = MapDiscordNotification.by_map(map.id)
  end

  test "by_map loads the webhooks relationship", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    {:ok, _} =
      MapDiscordWebhook.create(%{
        notification_id: rec.id,
        role: :character,
        webhook_url: "https://discord.com/api/webhooks/222/othertok"
      })

    assert {:ok, found} = MapDiscordNotification.by_map(map.id)
    refute match?(%Ash.NotLoaded{}, found.webhooks)
    assert Enum.map(found.webhooks, & &1.role) |> Enum.sort() == [:character, :system]
  end

  test "enforces one notification per map", %{map: map} do
    {:ok, _} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:error, _} =
             MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})
  end

  test "deleting the map cascades the notification and its webhooks away", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})
    {:ok, [hook]} = MapDiscordWebhook.by_notification(rec.id)

    Ash.destroy!(map)

    assert {:error, _} = MapDiscordNotification.by_id(rec.id)
    assert {:error, _} = MapDiscordWebhook.by_id(hook.id)
  end

  test "destroy invalidates the cache and stops each webhook's worker", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    {:ok, [system_hook]} = MapDiscordWebhook.by_notification(rec.id)

    {:ok, character_hook} =
      MapDiscordWebhook.create(%{
        notification_id: rec.id,
        role: :character,
        webhook_url: "https://discord.com/api/webhooks/222/othertok"
      })

    start_supervised!(WorkerSupervisor)
    registry = WorkerSupervisor.registry()

    # Seed the routing cache so the destroy has something to evict — without
    # this the test asserts only the worker teardown, and a regression in the
    # destroy-side invalidation passes silently despite the test's name.
    Cachex.put(@cache, map.id, rec)

    # Register one worker per webhook id — the key `stash_webhook_ids/2` reads
    # and `after_destroy/3` stops by. Started directly against the real
    # `Worker`/`Registry` (rather than through `WorkerSupervisor.deliver/2`) so
    # this proves the actual registry entries this destroy path is responsible
    # for clearing.
    for webhook <- [system_hook, character_hook] do
      start_supervised!(
        {Worker, webhook_id: webhook.id, registry: registry, idle_timeout: :infinity},
        id: webhook.id,
        restart: :temporary
      )
    end

    assert [{_pid, _}] = Registry.lookup(registry, system_hook.id)
    assert [{_pid, _}] = Registry.lookup(registry, character_hook.id)

    assert :ok = MapDiscordNotification.destroy(rec)
    assert {:error, _} = MapDiscordNotification.by_map(map.id)
    assert Cachex.get(@cache, map.id) == {:ok, nil}

    # Registry release on process exit is asynchronous, so poll rather than
    # asserting immediately.
    await_condition(fn ->
      if Registry.lookup(registry, system_hook.id) == [] and
           Registry.lookup(registry, character_hook.id) == [] do
        {:ok, :done}
      else
        :retry
      end
    end)
  end

  test "destroy tolerates the worker registry not running at all", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    # No WorkerSupervisor started in this test — the custom destroy must not
    # crash just because the delivery infrastructure is down (e.g. webhooks
    # globally disabled).
    assert :ok = MapDiscordNotification.destroy(rec)
    assert {:error, _} = MapDiscordNotification.by_map(map.id)
  end

  # `after_action` hooks run inside the action's transaction, in the order they
  # were added. This one is appended after the resource's own hooks, so it
  # stands in for a killmail that arrives *just after* an `after_action`
  # invalidation would have run: `DiscordDispatcher.load_and_cache/1` reads
  # pre-commit state, finds no config, and stores the negative `:none` marker.
  #
  # Only an invalidation that runs after the transaction clears that marker.
  # Under `after_action` it survives for the cache's 5-minute default TTL, and
  # the map the user just configured posts nothing for five minutes.
  defp cache_none_inside_transaction(changeset, map_id) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      Cachex.put(@cache, map_id, :none)
      {:ok, record}
    end)
  end

  test "create invalidates the cache after the transaction, not inside it", %{map: map} do
    assert {:ok, _rec} =
             MapDiscordNotification
             |> Ash.Changeset.for_create(:create, %{map_id: map.id, webhook_url: valid_url()})
             |> cache_none_inside_transaction(map.id)
             |> Ash.create()

    assert Cachex.get(@cache, map.id) == {:ok, nil}
  end

  test "update invalidates the cache after the transaction, not inside it", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, _rec} =
             rec
             |> Ash.Changeset.for_update(:update, %{wh_only: false})
             |> cache_none_inside_transaction(map.id)
             |> Ash.update()

    assert Cachex.get(@cache, map.id) == {:ok, nil}
  end

  test "a rolled-back create leaves the cached config alone", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})
    Cachex.put(@cache, map.id, rec)

    # A map with no notification of its own, so the create below can only fail
    # on the child's URL validation. Reusing `map` would trip the one-per-map
    # identity first and never exercise the rollback path this test is about.
    fresh_map = Factory.insert(:map, %{})
    Cachex.put(@cache, fresh_map.id, rec)

    # Rejected by the child's URL validation, so the whole transaction rolls
    # back. The after_transaction hook still runs, with an `{:error, _}` result:
    # nothing was written, so nothing may be evicted.
    assert {:error, _} =
             MapDiscordNotification.create(%{
               map_id: fresh_map.id,
               webhook_url: "https://evil.example.com/x"
             })

    assert {:ok, ^rec} = Cachex.get(@cache, fresh_map.id)
    assert {:ok, ^rec} = Cachex.get(@cache, map.id)
  end

  test "route alert fields default off with a 5-jump cap", %{map: map} do
    assert {:ok, rec} =
             MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert rec.route_alerts_enabled? == false
    assert rec.home_system_id == nil
    assert rec.route_max_jumps == 5
  end

  test "route alert config round-trips through update", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, updated} =
             MapDiscordNotification.update(rec, %{
               route_alerts_enabled?: true,
               home_system_id: 30_000_142,
               route_max_jumps: 3
             })

    assert updated.route_alerts_enabled? == true
    assert updated.home_system_id == 30_000_142
    assert updated.route_max_jumps == 3

    assert {:ok, reloaded} = MapDiscordNotification.by_map(map.id)
    assert reloaded.home_system_id == 30_000_142
  end

  test "route_alerts_enabled? without a home_system_id is rejected", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             MapDiscordNotification.update(rec, %{route_alerts_enabled?: true})

    assert Enum.any?(errors, fn e ->
             Map.get(e, :field) == :home_system_id and
               to_string(Map.get(e, :message, "")) =~ "required"
           end)
  end

  test "route_alerts_enabled? with a home_system_id already set is accepted", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    {:ok, rec} = MapDiscordNotification.update(rec, %{home_system_id: 30_000_142})

    assert {:ok, updated} = MapDiscordNotification.update(rec, %{route_alerts_enabled?: true})
    assert updated.route_alerts_enabled? == true
  end

  test "home_system_id can be set while route_alerts_enabled? stays false", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, updated} = MapDiscordNotification.update(rec, %{home_system_id: 30_000_142})
    assert updated.route_alerts_enabled? == false
  end

  test "route_max_jumps accepts the 1..20 boundary and rejects outside it", %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, _} = MapDiscordNotification.update(rec, %{route_max_jumps: 1})
    assert {:ok, _} = MapDiscordNotification.update(rec, %{route_max_jumps: 20})
    assert {:error, _} = MapDiscordNotification.update(rec, %{route_max_jumps: 0})
    assert {:error, _} = MapDiscordNotification.update(rec, %{route_max_jumps: 21})
  end

  test "updating route alert config invalidates the cache after the transaction, not inside it",
       %{map: map} do
    {:ok, rec} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    assert {:ok, _rec} =
             rec
             |> Ash.Changeset.for_update(:update, %{
               route_alerts_enabled?: true,
               home_system_id: 30_000_142
             })
             |> cache_none_inside_transaction(map.id)
             |> Ash.update()

    assert Cachex.get(@cache, map.id) == {:ok, nil}
  end
end
