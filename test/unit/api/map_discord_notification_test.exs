defmodule WandererApp.Api.MapDiscordNotificationTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererAppWeb.Factory

  defp valid_url, do: "https://discord.com/api/webhooks/123456789/abcdefTOKEN"

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

    # Neither the cache nor the worker registry is running in this test; the
    # custom destroy must tolerate that rather than crash.
    assert :ok = MapDiscordNotification.destroy(rec)
    assert {:error, _} = MapDiscordNotification.by_map(map.id)
  end
end
