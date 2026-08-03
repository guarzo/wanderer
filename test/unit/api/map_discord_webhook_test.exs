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
end
