defmodule WandererApp.Api.MapDiscordNotificationTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.ExternalEvents.Discord.{Worker, WorkerSupervisor}
  alias WandererAppWeb.Factory

  defp valid_url, do: "https://discord.com/api/webhooks/123456789/abcdefTOKEN"

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

    # Register one worker per webhook id — the key `stash_webhook_ids/2` reads
    # and `after_destroy/3` stops by. Started directly against the real
    # `Worker`/`Registry` (rather than through `WorkerSupervisor.deliver/3`,
    # which is still map-id-keyed pending Task 3's rekey), so this proves the
    # actual registry entries this destroy path is responsible for clearing.
    for webhook <- [system_hook, character_hook] do
      start_supervised!(
        {Worker, map_id: webhook.id, registry: registry, idle_timeout: :infinity},
        id: webhook.id,
        restart: :temporary
      )
    end

    assert [{_pid, _}] = Registry.lookup(registry, system_hook.id)
    assert [{_pid, _}] = Registry.lookup(registry, character_hook.id)

    assert :ok = MapDiscordNotification.destroy(rec)
    assert {:error, _} = MapDiscordNotification.by_map(map.id)

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
end
