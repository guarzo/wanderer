defmodule WandererApp.Api.MapDiscordWebhookTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererAppWeb.Factory

  defp valid_url, do: "https://discord.com/api/webhooks/123456789/abcdefTOKEN"

  # The dispatcher's per-map config cache, seeded and read directly so these
  # tests do not depend on the dispatcher GenServer running.
  @cache :discord_notification_cache

  setup do
    map = Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

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
    # `MapDiscordNotification.create/1` (setup) already creates the :system
    # webhook — this asserts a second :system create for the same notification
    # is rejected.
    assert {:error, _} =
             MapDiscordWebhook.create(%{
               notification_id: notification.id,
               role: :system,
               webhook_url: "https://discord.com/api/webhooks/222/othertok"
             })
  end

  test "allows both roles under the same notification", %{notification: notification} do
    # `MapDiscordNotification.create/1` (setup) already created the :system
    # webhook; only the :character one needs creating here.
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
    # `MapDiscordNotification.create/1` (setup) already created the :system
    # webhook.
    {:ok, [sys]} = MapDiscordWebhook.by_notification(notification.id)

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
    #
    # `MapDiscordNotification.create/1` (setup) already created the :system
    # webhook.
    {:ok, [sys]} = MapDiscordWebhook.by_notification(notification.id)

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

  # `after_action` hooks run inside the action's transaction, in the order they
  # were added. This one is appended after the resource's own hooks, so it
  # stands in for a killmail that arrives *just after* an `after_action`
  # invalidation would have run: `DiscordDispatcher.load_and_cache/1` reads
  # pre-commit state and re-caches it — the pre-update URL, or the negative
  # `:none` marker. Only an invalidation that runs after the transaction clears
  # that; under `after_action` the stale entry survives the cache's 5-minute
  # default TTL, so the destination the user just changed keeps posting nowhere
  # (or to the old channel).
  defp cache_none_inside_transaction(changeset, map_id) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      Cachex.put(@cache, map_id, :none)
      {:ok, record}
    end)
  end

  test "create invalidates the cache after the transaction, not inside it", %{
    map: map,
    notification: notification
  } do
    assert {:ok, _hook} =
             MapDiscordWebhook
             |> Ash.Changeset.for_create(:create, %{
               notification_id: notification.id,
               role: :character,
               webhook_url: valid_url()
             })
             |> cache_none_inside_transaction(map.id)
             |> Ash.create()

    assert Cachex.get(@cache, map.id) == {:ok, nil}
  end

  test "every health-updating action invalidates the cache after the transaction", %{
    map: map,
    notification: notification
  } do
    hook_id = character_hook(notification).id

    for {action, params} <- [
          {:update, %{webhook_url: "https://canary.discord.com/api/v10/webhooks/999/newtok"}},
          {:set_enabled, %{enabled?: false}},
          {:record_failure, %{error: "boom"}},
          {:disable, %{error: "404 Not Found"}}
        ] do
      {:ok, hook} = MapDiscordWebhook.by_id(hook_id)

      assert {:ok, _} =
               hook
               |> Ash.Changeset.for_update(action, params)
               |> cache_none_inside_transaction(map.id)
               |> Ash.update()

      assert Cachex.get(@cache, map.id) == {:ok, nil},
             "#{action} left the pre-commit cache entry in place"
    end
  end

  test "a rejected update leaves the cached config alone", %{
    map: map,
    notification: notification
  } do
    hook = character_hook(notification)
    Cachex.put(@cache, map.id, notification)

    assert {:error, _} =
             MapDiscordWebhook.update(hook, %{webhook_url: "https://evil.example.com/x"})

    # The after_transaction hook runs on failure too, with an `{:error, _}`
    # result: nothing was written, so nothing may be evicted.
    assert {:ok, ^notification} = Cachex.get(@cache, map.id)
  end

  describe "valid_webhook_url?/1" do
    test "accepts a Discord host regardless of case" do
      # URI.parse/1 returns the host as typed, and users paste URLs, so a
      # capitalised host must not be mistaken for a non-Discord one.
      for host <- ~w(discord.com Discord.com DISCORD.COM ptb.Discord.com CANARY.discord.com) do
        url = "https://#{host}/api/webhooks/123456789/abcdefTOKEN"
        assert MapDiscordWebhook.valid_webhook_url?(url), "rejected #{url}"
      end
    end

    test "still rejects a lookalike host" do
      refute MapDiscordWebhook.valid_webhook_url?(
               "https://discord.com.evil.example/api/webhooks/1/t"
             )

      refute MapDiscordWebhook.valid_webhook_url?("https://Evil.example/api/webhooks/1/t")
    end
  end

  test "update cannot re-parent a webhook onto another notification", %{
    notification: notification
  } do
    hook = character_hook(notification)

    {:ok, other_notification} = other_map_with_notification()

    # `notification_id` is outside the update action's accept list: moving a
    # webhook would carry the credential onto another map, and `do_invalidate/1`
    # resolves the notification *after* the write, so the original map would
    # keep routing to a destination it no longer owns for the rest of the TTL.
    assert {:error, error} =
             MapDiscordWebhook.update(hook, %{notification_id: other_notification.id})

    assert Exception.message(error) =~ "notification_id"

    {:ok, reloaded} = MapDiscordWebhook.by_id(hook.id)
    assert reloaded.notification_id == notification.id
  end

  defp other_map_with_notification do
    other_map = Factory.insert(:map, %{})

    WandererApp.Api.MapDiscordNotification.create(%{
      map_id: other_map.id,
      webhook_url: "https://discord.com/api/webhooks/999/othertok"
    })
  end
end
