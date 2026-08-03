defmodule WandererApp.Api.MapDiscordWebhookTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererAppWeb.Factory

  defp valid_url, do: "https://discord.com/api/webhooks/123456789/abcdefTOKEN"

  setup do
    map = Factory.insert(:map, %{})
    {:ok, notification} = MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})
    %{map: map, notification: notification}
  end

  test "creates with valid discord url and defaults", %{notification: notification} do
    assert {:ok, hook} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: valid_url()
             })

    assert hook.role == :character
    assert hook.webhook_url == valid_url()
    assert hook.enabled? == true
    assert hook.consecutive_failures == 0
    assert hook.last_error == nil
    assert hook.last_error_at == nil
    assert hook.last_delivery_at == nil
  end

  test "accepts discordapp.com host", %{notification: notification} do
    url = "https://discordapp.com/api/webhooks/123/tok"

    assert {:ok, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })
  end

  test "accepts a versioned webhook path", %{notification: notification} do
    url = "https://canary.discord.com/api/v10/webhooks/999/newtok"

    assert {:ok, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })
  end

  test "rejects non-https scheme", %{notification: notification} do
    url = "http://discord.com/api/webhooks/123/tok"

    assert {:error, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })
  end

  test "rejects non-discord host", %{notification: notification} do
    url = "https://evil.example.com/api/webhooks/123/tok"

    # Assert on the specific validation message, not a bare {:error, _}. A
    # blanket-reject regression (e.g. reading the AshCloak attribute instead of
    # the argument, which yields %Ash.NotLoaded{}) would satisfy {:error, _}
    # while rejecting valid URLs too.
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })

    assert Enum.any?(errors, fn e ->
             Map.get(e, :field) == :webhook_url and
               to_string(Map.get(e, :message, "")) =~ "Discord webhook URL"
           end)
  end

  test "rejects host that merely contains discord.com", %{notification: notification} do
    url = "https://discord.com.evil.example/api/webhooks/123/tok"

    assert {:error, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })
  end

  test "rejects malformed webhook path", %{notification: notification} do
    url = "https://discord.com/api/not-webhooks/123/tok"

    assert {:error, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: url
             })
  end

  test "rejects an unknown role", %{notification: notification} do
    assert {:error, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :corporation,
               webhook_url: valid_url()
             })
  end

  test "enforces one webhook per (notification, role)", %{notification: notification} do
    {:ok, _} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :system,
        webhook_url: valid_url()
      })

    assert {:error, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :system,
               webhook_url: "https://discord.com/api/webhooks/222/othertok"
             })
  end

  test "allows both roles under the same notification", %{notification: notification} do
    {:ok, _} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :system,
        webhook_url: valid_url()
      })

    assert {:ok, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :character,
               webhook_url: "https://discord.com/api/webhooks/222/othertok"
             })

    assert {:ok, hooks} = MapDiscordWebhook.by_notification(notification.id)
    assert Enum.map(hooks, & &1.role) |> Enum.sort() == [:character, :system]
  end

  test "rejects invalid url on UPDATE as well as create", %{notification: notification} do
    {:ok, hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: valid_url()
      })

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             MapDiscordWebhook.update(hook, %{webhook_url: "https://evil.example.com/x"})

    assert Enum.any?(errors, fn e ->
             Map.get(e, :field) == :webhook_url and
               to_string(Map.get(e, :message, "")) =~ "Discord webhook URL"
           end)

    # The rejected value must not have been persisted.
    {:ok, reloaded} = MapDiscordWebhook.by_id(hook.id)
    assert reloaded.webhook_url == valid_url()
  end

  test "accepts a valid replacement url on UPDATE", %{notification: notification} do
    # Guards against a blanket-reject regression: replacement must still work.
    {:ok, hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: valid_url()
      })

    replacement = "https://canary.discord.com/api/v10/webhooks/999/newtok"

    assert {:ok, updated} = MapDiscordWebhook.update(hook, %{webhook_url: replacement})
    assert updated.webhook_url == replacement
  end

  test "set_enabled toggles only this webhook", %{notification: notification} do
    {:ok, sys} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :system,
        webhook_url: valid_url()
      })

    {:ok, char} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: "https://discord.com/api/webhooks/222/othertok"
      })

    assert {:ok, char} = MapDiscordWebhook.set_enabled(char, %{enabled?: false})
    assert char.enabled? == false

    assert {:ok, sys} = MapDiscordWebhook.by_id(sys.id)
    assert sys.enabled? == true
  end

  test "destroying the notification cascades the webhooks away", %{notification: notification} do
    {:ok, hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: valid_url()
      })

    :ok = MapDiscordNotification.destroy(notification)

    assert {:error, _} = MapDiscordWebhook.by_id(hook.id)
  end

  test "destroy tolerates a cache and worker registry that are not running", %{
    notification: notification
  } do
    {:ok, hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: valid_url()
      })

    assert :ok = MapDiscordWebhook.destroy(hook)
    assert {:error, _} = MapDiscordWebhook.by_id(hook.id)
  end

  defp character_hook(notification) do
    {:ok, hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: valid_url()
      })

    hook
  end

  test "record_failure increments and does not disable before the threshold", %{
    notification: notification
  } do
    hook = character_hook(notification)

    hook =
      Enum.reduce(1..9, hook, fn _, acc ->
        {:ok, updated} = MapDiscordWebhook.record_failure(acc, "boom")
        updated
      end)

    assert hook.consecutive_failures == 9
    assert hook.enabled? == true
    assert hook.last_error == "boom"
    assert hook.last_error_at != nil
  end

  test "record_failure disables at 10 consecutive failures", %{notification: notification} do
    hook = character_hook(notification)

    hook =
      Enum.reduce(1..10, hook, fn _, acc ->
        {:ok, updated} = MapDiscordWebhook.record_failure(acc, "boom")
        updated
      end)

    assert hook.consecutive_failures == 10
    assert hook.enabled? == false
  end

  test "record_failure disables only the failing webhook", %{notification: notification} do
    # This is the entire point of the split: before it, ten failures on the
    # character channel would have silenced system kills too.
    {:ok, sys} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :system,
        webhook_url: valid_url()
      })

    {:ok, char} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: "https://discord.com/api/webhooks/222/othertok"
      })

    Enum.reduce(1..10, char, fn _, acc ->
      {:ok, updated} = MapDiscordWebhook.record_failure(acc, "boom")
      updated
    end)

    assert {:ok, sys} = MapDiscordWebhook.by_id(sys.id)
    assert sys.enabled? == true
    assert sys.consecutive_failures == 0
  end

  test "record_failure re-reads the counter rather than trusting a stale copy", %{
    notification: notification
  } do
    stale = character_hook(notification)

    # Advance the stored counter behind the back of the `stale` struct.
    {:ok, _} = MapDiscordWebhook.record_failure(stale, "first")

    {:ok, updated} = MapDiscordWebhook.record_failure(stale, "second")

    assert updated.consecutive_failures == 2
    assert updated.last_error == "second"
  end

  test "record_failure truncates an overlong error", %{notification: notification} do
    hook = character_hook(notification)

    {:ok, hook} = MapDiscordWebhook.record_failure(hook, String.duplicate("x", 900))

    assert String.length(hook.last_error) == 500
  end

  test "record_success clears the failure state", %{notification: notification} do
    hook = character_hook(notification)
    {:ok, hook} = MapDiscordWebhook.record_failure(hook, "boom")

    {:ok, hook} = MapDiscordWebhook.record_success(hook)

    assert hook.consecutive_failures == 0
    assert hook.last_error == nil
    assert hook.last_error_at == nil
    assert hook.last_delivery_at != nil
  end

  test "disable switches the webhook off immediately", %{notification: notification} do
    hook = character_hook(notification)

    {:ok, hook} = MapDiscordWebhook.disable(hook, "404 Not Found")

    assert hook.enabled? == false
    assert hook.last_error == "404 Not Found"
    assert hook.last_error_at != nil
  end
end
