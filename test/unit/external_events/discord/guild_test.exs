defmodule WandererApp.ExternalEvents.Discord.GuildTest do
  # `async: false`: the Discord HTTP seam is application env, so Mox has to be
  # in global mode, and `:api_cache` is a process shared by the whole suite.
  use ExUnit.Case, async: false

  import Mox

  alias WandererApp.ExternalEvents.Discord.Guild

  @guild_id "9876543210123456789"
  @roles_url "https://discord.com/api/v10/guilds/#{@guild_id}/roles"
  @search_base "https://discord.com/api/v10/guilds/#{@guild_id}/members/search"

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # Restored, not deleted: `config/test.exs` points this seam at `HttpStub`,
    # and deleting it would leave later delivery tests pointed at real Discord.
    original_client = Application.get_env(:wanderer_app, :discord_http_client)
    Application.put_env(:wanderer_app, :discord_http_client, Test.DiscordHttpClientMock)

    original_events = Application.get_env(:wanderer_app, :external_events, [])
    put_bot_token(original_events, "test-bot-token")

    # `:api_cache` outlives the test process, so a role list cached by one test
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

  defp json(term), do: {:ok, 200, Jason.encode!(term)}

  describe "roles/1" do
    test "returns id/name pairs for every role" do
      expect(Test.DiscordHttpClientMock, :get, fn @roles_url, _headers ->
        json([
          %{"id" => "111", "name" => "Scouts"},
          %{"id" => "222", "name" => "FC"}
        ])
      end)

      assert {:ok, [%{id: "111", name: "Scouts"}, %{id: "222", name: "FC"}]} =
               Guild.roles(@guild_id)
    end

    test "sends the bot authorization header" do
      expect(Test.DiscordHttpClientMock, :get, fn @roles_url, headers ->
        assert {_name, "Bot test-bot-token"} =
                 Enum.find(headers, fn {name, _value} ->
                   String.downcase(name) == "authorization"
                 end)

        json([])
      end)

      assert {:ok, []} = Guild.roles(@guild_id)
    end

    test "excludes @everyone, whose id is the guild id" do
      # This is the one entry that can wake a whole server up. Discord does not
      # mark it specially — it is identified only by its id matching the guild.
      expect(Test.DiscordHttpClientMock, :get, fn @roles_url, _headers ->
        json([
          %{"id" => @guild_id, "name" => "@everyone"},
          %{"id" => "111", "name" => "Scouts"}
        ])
      end)

      assert {:ok, [%{id: "111", name: "Scouts"}]} = Guild.roles(@guild_id)
    end

    test "drops entries with no usable name rather than rendering a blank row" do
      expect(Test.DiscordHttpClientMock, :get, fn @roles_url, _headers ->
        json([
          %{"id" => "111", "name" => "   "},
          %{"id" => "222"},
          %{"name" => "no id"},
          %{"id" => "333", "name" => "FC"}
        ])
      end)

      assert {:ok, [%{id: "333", name: "FC"}]} = Guild.roles(@guild_id)
    end

    test "the second call is served from cache and performs no HTTP" do
      # `expect/4` with a count of 1 is the assertion: a second request would
      # fail verification rather than silently double the traffic behind a
      # picker that reopens on every tab switch.
      expect(Test.DiscordHttpClientMock, :get, 1, fn @roles_url, _headers ->
        json([%{"id" => "111", "name" => "Scouts"}])
      end)

      assert {:ok, roles} = Guild.roles(@guild_id)
      assert {:ok, ^roles} = Guild.roles(@guild_id)
    end

    test "a 401 is distinct from a 403" do
      expect(Test.DiscordHttpClientMock, :get, fn @roles_url, _headers ->
        {:ok, 401, ~s({"message":"401: Unauthorized","code":0})}
      end)

      assert {:error, :unauthorized} = Guild.roles(@guild_id)

      Cachex.clear(:api_cache)

      expect(Test.DiscordHttpClientMock, :get, fn @roles_url, _headers ->
        {:ok, 403, ~s({"message":"Missing Access","code":50001})}
      end)

      assert {:error, :forbidden} = Guild.roles(@guild_id)
    end

    test "a failure is not cached, so an invite that just landed works on the next open" do
      expect(Test.DiscordHttpClientMock, :get, fn @roles_url, _headers ->
        {:ok, 403, ~s({"message":"Missing Access","code":50001})}
      end)

      assert {:error, :forbidden} = Guild.roles(@guild_id)

      expect(Test.DiscordHttpClientMock, :get, fn @roles_url, _headers ->
        json([%{"id" => "111", "name" => "Scouts"}])
      end)

      assert {:ok, [%{id: "111"}]} = Guild.roles(@guild_id)
    end

    test "a 200 carrying malformed JSON is an error, not a crash" do
      expect(Test.DiscordHttpClientMock, :get, fn @roles_url, _headers ->
        {:ok, 200, "<html>upstream proxy says no</html>"}
      end)

      assert {:error, :unexpected_response} = Guild.roles(@guild_id)
    end

    test "a 200 carrying JSON that is not a list is an error" do
      expect(Test.DiscordHttpClientMock, :get, fn @roles_url, _headers ->
        json(%{"message" => "not a list"})
      end)

      assert {:error, :unexpected_response} = Guild.roles(@guild_id)
    end

    test "a raise inside the client does not escape" do
      # An unrescued raise on this path already killed the settings tab once.
      expect(Test.DiscordHttpClientMock, :get, fn _url, _headers -> raise "boom" end)

      assert {:error, :unavailable} = Guild.roles(@guild_id)
    end

    test "an exit inside the client does not escape" do
      # A dead Finch pool exits rather than raising; `rescue` alone misses it.
      expect(Test.DiscordHttpClientMock, :get, fn _url, _headers ->
        exit(:no_pool)
      end)

      assert {:error, :unavailable} = Guild.roles(@guild_id)
    end

    test "no bot token is reported as such, without any request", %{external_events: original} do
      put_bot_token(original, nil)

      assert {:error, :no_bot_token} = Guild.roles(@guild_id)
    end

    test "no guild is reported as such, without any request" do
      assert {:error, :no_guild} = Guild.roles(nil)
    end
  end

  describe "search_members/3" do
    test "returns id/name pairs, preferring nickname then display name then username" do
      expect(Test.DiscordHttpClientMock, :get, fn _url, _headers ->
        json([
          %{"nick" => "Scout One", "user" => %{"id" => "1", "username" => "scoutone"}},
          %{
            "nick" => nil,
            "user" => %{"id" => "2", "global_name" => "Scout Two", "username" => "scout2"}
          },
          %{"user" => %{"id" => "3", "username" => "scout3"}}
        ])
      end)

      assert {:ok,
              [
                %{id: "1", name: "Scout One"},
                %{id: "2", name: "Scout Two"},
                %{id: "3", name: "scout3"}
              ]} = Guild.search_members(@guild_id, "scout")
    end

    test "url-encodes a query containing a space and an ampersand" do
      expect(Test.DiscordHttpClientMock, :get, fn url, _headers ->
        # The point of the assertion: an unencoded `&` would make `limit=25` a
        # value of the *query* parameter and turn the rest into new parameters.
        assert String.starts_with?(url, @search_base <> "?")
        assert %URI{query: query} = URI.parse(url)
        assert %{"query" => "big & tall", "limit" => "25"} = URI.decode_query(query)

        json([])
      end)

      assert {:ok, []} = Guild.search_members(@guild_id, "big & tall")
    end

    test "sends the bot authorization header" do
      expect(Test.DiscordHttpClientMock, :get, fn _url, headers ->
        assert {_name, "Bot test-bot-token"} =
                 Enum.find(headers, fn {name, _value} ->
                   String.downcase(name) == "authorization"
                 end)

        json([])
      end)

      assert {:ok, []} = Guild.search_members(@guild_id, "scout")
    end

    test "clamps the limit into Discord's range" do
      expect(Test.DiscordHttpClientMock, :get, fn url, _headers ->
        assert %{"limit" => "100"} =
                 url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

        json([])
      end)

      assert {:ok, []} = Guild.search_members(@guild_id, "scout", limit: 5_000)
    end

    test "a blank query short-circuits without a request" do
      # The keystroke that empties the box would otherwise send a request
      # Discord rejects outright.
      assert {:ok, []} = Guild.search_members(@guild_id, "   ")
    end

    test "results are not cached: a second search actually asks again" do
      expect(Test.DiscordHttpClientMock, :get, 2, fn _url, _headers -> json([]) end)

      assert {:ok, []} = Guild.search_members(@guild_id, "scout")
      assert {:ok, []} = Guild.search_members(@guild_id, "scout")
    end

    test "a 401 is distinct from a 403" do
      expect(Test.DiscordHttpClientMock, :get, fn _url, _headers ->
        {:ok, 401, ~s({"message":"401: Unauthorized","code":0})}
      end)

      assert {:error, :unauthorized} = Guild.search_members(@guild_id, "scout")

      expect(Test.DiscordHttpClientMock, :get, fn _url, _headers ->
        {:ok, 403, ~s({"message":"Missing Access","code":50001})}
      end)

      assert {:error, :forbidden} = Guild.search_members(@guild_id, "scout")
    end

    test "a 200 carrying malformed JSON is an error, not a crash" do
      expect(Test.DiscordHttpClientMock, :get, fn _url, _headers ->
        {:ok, 200, "<html>upstream proxy says no</html>"}
      end)

      assert {:error, :unexpected_response} = Guild.search_members(@guild_id, "scout")
    end

    test "a raise inside the client does not escape" do
      expect(Test.DiscordHttpClientMock, :get, fn _url, _headers -> raise "boom" end)

      assert {:error, :unavailable} = Guild.search_members(@guild_id, "scout")
    end

    test "an exit inside the client does not escape" do
      expect(Test.DiscordHttpClientMock, :get, fn _url, _headers -> exit(:no_pool) end)

      assert {:error, :unavailable} = Guild.search_members(@guild_id, "scout")
    end

    test "no bot token is reported as such, without any request", %{external_events: original} do
      put_bot_token(original, nil)

      assert {:error, :no_bot_token} = Guild.search_members(@guild_id, "scout")
    end

    test "no guild is reported as such, without any request" do
      assert {:error, :no_guild} = Guild.search_members(nil, "scout")
    end
  end

  describe "unavailable?/1" do
    test "covers exactly the reasons the manual fallback exists for" do
      for reason <- [:no_bot_token, :no_guild, :unauthorized, :forbidden] do
        assert Guild.unavailable?(reason), "expected #{inspect(reason)} to be unavailable"
      end

      # A transient failure keeps the picker: telling an operator to add a bot
      # that is already there is worse than an empty dropdown that recovers.
      refute Guild.unavailable?(:unavailable)
      refute Guild.unavailable?(:rate_limited)
      refute Guild.unavailable?(:unexpected_response)
    end
  end
end
