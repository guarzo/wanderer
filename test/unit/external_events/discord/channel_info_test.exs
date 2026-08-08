defmodule WandererApp.ExternalEvents.Discord.ChannelInfoTest do
  # `async: false`: the Discord HTTP seam is application env, `:api_cache` is a
  # process shared by the whole suite, and `refresh_async/1` resolves in a
  # supervised Task — so Mox has to be in global mode. `DataCase` at
  # `async: false` also puts the sandbox in shared mode, which is what lets
  # that Task reach the repo to persist what it resolved.
  use WandererApp.DataCase, async: false

  import Mox

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.ExternalEvents.Discord.ChannelInfo

  @webhook_id "1534657087244603394"
  @webhook_token "40AXsomethingsecret"
  @url "https://discord.com/api/webhooks/#{@webhook_id}/#{@webhook_token}"
  @other_url "https://discord.com/api/webhooks/9876543210987654321/differenttoken"
  @channel_id "1234567890123456789"

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # Restored, not deleted: `config/test.exs` points this seam at `HttpStub`,
    # and deleting it would leave later delivery tests pointed at real Discord.
    original_client = Application.get_env(:wanderer_app, :discord_http_client)
    Application.put_env(:wanderer_app, :discord_http_client, Test.DiscordHttpClientMock)

    original_events = Application.get_env(:wanderer_app, :external_events, [])

    # `:api_cache` outlives the test process, so a label cached by one test
    # would satisfy the next one's assertions without any HTTP happening.
    Cachex.clear(:api_cache)

    on_exit(fn ->
      Application.put_env(:wanderer_app, :discord_http_client, original_client)
      Application.put_env(:wanderer_app, :external_events, original_events)
      Cachex.clear(:api_cache)
    end)

    %{external_events: original_events}
  end

  defp put_bot_token(original, token) do
    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, :discord_bot_token, token)
    )
  end

  # Scripts the seam by URL. Anything unscripted is a 404, which is what an
  # unknown webhook actually returns.
  defp stub_get(responses) do
    stub(Test.DiscordHttpClientMock, :get, fn url, _headers ->
      Map.get(responses, url, {:ok, 404, ~s({"message":"Unknown Webhook","code":10015})})
    end)
  end

  defp json(map), do: {:ok, 200, Jason.encode!(map)}

  defp channel_url(channel_id), do: "https://discord.com/api/v10/channels/#{channel_id}"

  defp webhook(attrs), do: struct(MapDiscordWebhook, attrs)

  # A real row, for the paths that actually write. Everything else in this file
  # uses the bare struct above, because resolution itself never touches the repo.
  #
  # Role `:character`: creating the notification already creates the `:system`
  # webhook, and `(notification_id, role)` is unique.
  defp insert_webhook(attrs \\ %{}) do
    map = WandererAppWeb.Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{map_id: map.id, webhook_url: @url})

    {:ok, hook} =
      MapDiscordWebhook.create(
        Map.merge(%{notification_id: notification.id, role: :character, webhook_url: @url}, attrs)
      )

    hook
  end

  defp reload(%MapDiscordWebhook{id: id}), do: Ash.get!(MapDiscordWebhook, id)

  # `refresh_async/1` deliberately returns `:ok` rather than the task, so there
  # is nothing to await directly — poll the row instead of sleeping a fixed
  # amount, which would either flake or waste a second on every run.
  defp await_persisted(hook, fun) do
    eventually(fn -> fun.(reload(hook)) end, timeout: 2_000)
  end

  describe "resolve/1 tier 1 — the webhook's own identity" do
    test "returns the webhook name and channel id" do
      stub_get(%{@url => json(%{"name" => "Wanderer Kills", "channel_id" => @channel_id})})

      assert {:ok, info} = ChannelInfo.resolve(@url)
      assert info.label == "Wanderer Kills"
      assert info.channel_id == @channel_id
      assert info.source == :resolved
    end

    test "sends no authorization header — the URL is its own credential" do
      expect(Test.DiscordHttpClientMock, :get, fn @url, headers ->
        assert headers == []
        json(%{"name" => "Wanderer Kills", "channel_id" => @channel_id})
      end)

      assert {:ok, _info} = ChannelInfo.resolve(@url)
    end

    test "falls back to a masked hint when the webhook has no usable name" do
      stub_get(%{@url => json(%{"name" => "   ", "channel_id" => @channel_id})})

      assert {:ok, info} = ChannelInfo.resolve(@url)
      assert String.starts_with?(info.label, "••••")
      # The channel is known even though the name is not, so collision
      # detection keeps working off the cached id...
      assert info.channel_id == @channel_id
      # ...but this is NOT a resolved label. Marking it resolved would cache the
      # hint for the full hour and write it over a real label already on the row.
      assert info.source == :masked
    end
  end

  describe "resolve/1 tier 2 — the bot-resolved channel name" do
    test "prefers the real #channel-name when a bot token is configured", %{
      external_events: original
    } do
      put_bot_token(original, "bot-token")

      stub_get(%{
        @url => json(%{"name" => "Wanderer Kills", "channel_id" => @channel_id}),
        channel_url(@channel_id) => json(%{"name" => "wh-kills"})
      })

      assert {:ok, %{label: "#wh-kills", channel_id: @channel_id}} = ChannelInfo.resolve(@url)
    end

    test "sends the bot token only on the channel lookup", %{external_events: original} do
      put_bot_token(original, "bot-token")

      stub(Test.DiscordHttpClientMock, :get, fn url, headers ->
        case url do
          @url ->
            assert headers == []
            json(%{"name" => "Wanderer Kills", "channel_id" => @channel_id})

          _channel ->
            assert {"authorization", "Bot bot-token"} in headers
            json(%{"name" => "wh-kills"})
        end
      end)

      assert {:ok, %{label: "#wh-kills"}} = ChannelInfo.resolve(@url)
    end

    test "a 403 is normal and falls back to tier 1, not an error", %{external_events: original} do
      # The bot is simply not in this operator's guild. This is the common case
      # on a self-hosted instance and must not degrade the tier 1 answer.
      put_bot_token(original, "bot-token")

      stub_get(%{
        @url => json(%{"name" => "Wanderer Kills", "channel_id" => @channel_id}),
        channel_url(@channel_id) => {:ok, 403, ~s({"message":"Missing Access","code":50001})}
      })

      assert {:ok, %{label: "Wanderer Kills", channel_id: @channel_id, source: :resolved}} =
               ChannelInfo.resolve(@url)
    end

    test "skips the channel lookup entirely when no bot token is set", %{
      external_events: original
    } do
      put_bot_token(original, nil)

      expect(Test.DiscordHttpClientMock, :get, 1, fn @url, _headers ->
        json(%{"name" => "Wanderer Kills", "channel_id" => @channel_id})
      end)

      assert {:ok, %{label: "Wanderer Kills"}} = ChannelInfo.resolve(@url)
    end
  end

  describe "resolve/1 tier 3 — the masked hint" do
    test "masks the id as well as the token" do
      stub_get(%{})

      assert {:ok, info} = ChannelInfo.resolve(@url)
      assert info.source == :masked
      assert info.channel_id == nil

      # The whole point of the change: neither half of the credential, and no
      # fragment of either, reaches the rendered label.
      refute info.label =~ @webhook_id
      refute info.label =~ @webhook_token
      refute info.label =~ String.slice(@webhook_token, 0, 4)
    end

    test "two destinations mask to different hints" do
      stub_get(%{})

      assert {:ok, %{label: first}} = ChannelInfo.resolve(@url)
      assert {:ok, %{label: second}} = ChannelInfo.resolve(@other_url)
      refute first == second
    end

    test "the hint is deterministic for the same URL" do
      stub_get(%{})

      assert {:ok, %{label: label}} = ChannelInfo.resolve(@url)
      Cachex.clear(:api_cache)
      assert {:ok, %{label: ^label}} = ChannelInfo.resolve(@url)
    end

    test "a transport error masks rather than raising" do
      stub_get(%{@url => {:error, :timeout}})

      assert {:ok, %{source: :masked}} = ChannelInfo.resolve(@url)
    end

    test "a non-JSON response masks rather than raising" do
      stub_get(%{@url => {:ok, 200, "<html>502 Bad Gateway</html>"}})

      assert {:ok, %{source: :masked}} = ChannelInfo.resolve(@url)
    end

    test "a raising HTTP client masks rather than taking the caller down" do
      stub(Test.DiscordHttpClientMock, :get, fn _url, _headers -> raise "boom" end)

      assert {:ok, %{source: :masked}} = ChannelInfo.resolve(@url)
    end
  end

  describe "resolve/1 caching" do
    test "asks Discord once and serves the rest from cache" do
      expect(Test.DiscordHttpClientMock, :get, 1, fn @url, _headers ->
        json(%{"name" => "Wanderer Kills", "channel_id" => @channel_id})
      end)

      assert {:ok, %{label: "Wanderer Kills"}} = ChannelInfo.resolve(@url)
      assert {:ok, %{label: "Wanderer Kills"}} = ChannelInfo.resolve(@url)
      assert {:ok, %{label: "Wanderer Kills"}} = ChannelInfo.resolve(@url)
    end

    test "does not cache under the webhook URL" do
      stub_get(%{@url => json(%{"name" => "Wanderer Kills", "channel_id" => @channel_id})})
      assert {:ok, _info} = ChannelInfo.resolve(@url)

      {:ok, keys} = Cachex.keys(:api_cache)
      keys = Enum.map(keys, &to_string/1)

      refute Enum.any?(keys, &String.contains?(&1, @webhook_token))
      refute Enum.any?(keys, &String.contains?(&1, @webhook_id))
      assert Enum.any?(keys, &String.contains?(&1, ChannelInfo.fingerprint(@url)))
    end
  end

  describe "describe/1" do
    test "errors when there is no destination to describe" do
      assert {:error, :no_webhook_url} = ChannelInfo.describe(nil)
      assert {:error, :no_webhook_url} = ChannelInfo.describe("")
      assert {:error, :no_webhook_url} = ChannelInfo.describe("   ")
      assert {:error, :no_webhook_url} = ChannelInfo.describe(webhook(%{}))
    end

    test "returns the label persisted on the row without waiting on Discord" do
      stub_get(%{})

      record =
        webhook(%{
          id: Ecto.UUID.generate(),
          webhook_url: @url,
          channel_id: @channel_id,
          channel_label: "#wh-kills"
        })

      assert {:ok, %{label: "#wh-kills", channel_id: @channel_id, source: :resolved}} =
               ChannelInfo.describe(record)
    end

    test "returns a masked hint on a cold cache with nothing persisted" do
      stub_get(%{})

      record = webhook(%{id: Ecto.UUID.generate(), webhook_url: @url})

      assert {:ok, %{source: :masked, channel_id: nil}} = ChannelInfo.describe(record)
    end

    test "serves a warm cache entry ahead of a stale persisted label" do
      stub_get(%{@url => json(%{"name" => "Wanderer Kills", "channel_id" => @channel_id})})
      assert {:ok, _info} = ChannelInfo.resolve(@url)

      record = webhook(%{id: Ecto.UUID.generate(), webhook_url: @url, channel_label: "#renamed"})

      assert {:ok, %{label: "Wanderer Kills"}} = ChannelInfo.describe(record)
    end
  end

  describe "refresh_async/1 persistence" do
    test "writes the resolved identity onto the row" do
      put_bot_token(Application.get_env(:wanderer_app, :external_events, []), "bot-token")

      stub_get(%{
        @url => json(%{"name" => "Wanderer Kills", "channel_id" => @channel_id}),
        channel_url(@channel_id) => json(%{"name" => "wh-kills"})
      })

      hook = insert_webhook()
      assert hook.channel_id == nil
      assert hook.channel_label == nil

      assert :ok = ChannelInfo.refresh_async(hook)

      await_persisted(hook, fn reloaded ->
        assert reloaded.channel_id == @channel_id
        assert reloaded.channel_label == "#wh-kills"
      end)
    end

    test "skips the write when the row already holds what was resolved" do
      stub_get(%{@url => json(%{"name" => "Wanderer Kills", "channel_id" => @channel_id})})

      hook = insert_webhook(%{})

      {:ok, hook} =
        MapDiscordWebhook.cache_channel_info(hook, %{
          channel_id: @channel_id,
          channel_label: "Wanderer Kills"
        })

      assert :ok = ChannelInfo.refresh_async(hook)

      # Nothing to write, so nothing should touch the row. `updated_at` is the
      # only observable difference between "wrote the same values again" and
      # "correctly did not write".
      await_persisted(hook, fn reloaded -> assert reloaded.channel_label == "Wanderer Kills" end)
      assert reload(hook).updated_at == hook.updated_at
    end

    test "never overwrites a real stored label with a masked hint" do
      # Discord unreachable: resolution can do no better than the hint.
      stub_get(%{@url => {:error, :econnrefused}})

      hook = insert_webhook()

      {:ok, hook} =
        MapDiscordWebhook.cache_channel_info(hook, %{
          channel_id: @channel_id,
          channel_label: "#wh-kills"
        })

      assert :ok = ChannelInfo.refresh_async(hook)

      # A masked result carries no information the row does not already hold,
      # and one unreachable moment must not cost the operator a real name.
      await_persisted(hook, fn reloaded ->
        assert reloaded.channel_label == "#wh-kills"
        assert reloaded.channel_id == @channel_id
      end)
    end

    test "does not persist a hint when the channel is known but unnamed" do
      # Reachable and it named a channel, but no usable name anywhere — the
      # regression this guards: stamping that :resolved would write "•••• ...."
      # into channel_label.
      stub_get(%{@url => json(%{"name" => "   ", "channel_id" => @channel_id})})

      hook = insert_webhook()

      {:ok, hook} =
        MapDiscordWebhook.cache_channel_info(hook, %{
          channel_id: @channel_id,
          channel_label: "#wh-kills"
        })

      assert :ok = ChannelInfo.refresh_async(hook)

      await_persisted(hook, fn reloaded -> assert reloaded.channel_label == "#wh-kills" end)
      refute reload(hook).channel_label =~ "••••"
    end
  end

  describe "MapDiscordWebhook.cache_channel_info/2" do
    test "accepts the two cached identity attributes" do
      hook = insert_webhook()

      assert {:ok, updated} =
               MapDiscordWebhook.cache_channel_info(hook, %{
                 channel_id: @channel_id,
                 channel_label: "#wh-kills"
               })

      assert updated.channel_id == @channel_id
      assert updated.channel_label == "#wh-kills"
    end

    test "clears both when a destination stops resolving to a channel" do
      hook = insert_webhook()

      {:ok, hook} =
        MapDiscordWebhook.cache_channel_info(hook, %{
          channel_id: @channel_id,
          channel_label: "#wh-kills"
        })

      assert {:ok, cleared} =
               MapDiscordWebhook.cache_channel_info(hook, %{channel_id: nil, channel_label: nil})

      assert cleared.channel_id == nil
      assert cleared.channel_label == nil
    end

    test "cannot be used to redirect where a destination posts" do
      hook = insert_webhook()
      other = "https://discord.com/api/webhooks/999/otherTOKEN"

      # The action exists so a background task can cache a name. AshCloak adds
      # `webhook_url` as an argument to every action on this resource, so
      # `accept` does not keep it out — without the explicit rejection a crafted
      # submit could repoint the destination while claiming it still posts to
      # the channel the label names.
      assert {:error, %Ash.Error.Invalid{}} =
               MapDiscordWebhook.cache_channel_info(hook, %{
                 channel_label: "#wh-kills",
                 webhook_url: other
               })

      assert reload(hook).webhook_url == @url
    end
  end

  describe "colliding_roles/1" do
    test "reports nothing when the destinations differ" do
      webhooks = %{
        system: webhook(%{webhook_url: @url, channel_id: @channel_id}),
        character: nil,
        route: webhook(%{webhook_url: @other_url, channel_id: "2222222222222222222"})
      }

      assert ChannelInfo.colliding_roles(webhooks) == []
    end

    test "catches the same URL pasted into two roles before anything resolves" do
      webhooks = %{
        system: webhook(%{webhook_url: @url}),
        character: nil,
        route: webhook(%{webhook_url: @url})
      }

      assert ChannelInfo.colliding_roles(webhooks) == [[:system, :route]]
    end

    test "catches two different webhooks that resolve to one channel" do
      # The realistic leak: a separate webhook created for route alerts, in the
      # same channel as the public kill feed. Only the resolved channel id
      # reveals it.
      webhooks = %{
        system: webhook(%{webhook_url: @url, channel_id: @channel_id}),
        character: nil,
        route: webhook(%{webhook_url: @other_url, channel_id: @channel_id})
      }

      assert ChannelInfo.colliding_roles(webhooks) == [[:system, :route]]
    end

    test "reports roles in system/character/route order" do
      shared = webhook(%{webhook_url: @url, channel_id: @channel_id})

      assert ChannelInfo.colliding_roles(%{route: shared, character: shared, system: shared}) ==
               [[:system, :character, :route]]
    end

    test "ignores unconfigured destinations" do
      assert ChannelInfo.colliding_roles(%{system: nil, character: nil, route: nil}) == []
      assert ChannelInfo.colliding_roles(%{}) == []
    end

    test "never raises on input it did not expect" do
      assert ChannelInfo.colliding_roles(nil) == []
      assert ChannelInfo.colliding_roles(%{system: :not_a_webhook}) == []
      assert ChannelInfo.colliding_roles(%{system: webhook(%{webhook_url: nil})}) == []
    end
  end

  describe "fingerprint/1" do
    test "is stable, short, and reveals nothing about the URL" do
      assert ChannelInfo.fingerprint(@url) == ChannelInfo.fingerprint(@url)
      refute ChannelInfo.fingerprint(@url) == ChannelInfo.fingerprint(@other_url)
      refute ChannelInfo.fingerprint(@url) =~ @webhook_token
      refute ChannelInfo.fingerprint(@url) =~ @webhook_id
    end
  end
end
