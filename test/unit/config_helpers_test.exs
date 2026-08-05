defmodule WandererApp.ConfigHelpersTest do
  # Pure functions: no app env, no cache, no process state.
  use ExUnit.Case, async: true

  alias WandererApp.ConfigHelpers

  # "NOT_FLY_APP" is the sentinel `runtime.exs` uses as the default for
  # FLY_APP_NAME, so it must be treated as "not on Fly", not as an app name.
  describe "resolve_host/2 off Fly" do
    test "uses PHX_HOST when set" do
      assert ConfigHelpers.resolve_host("map.example.com", "NOT_FLY_APP") ==
               "map.example.com"
    end

    test "falls back to localhost when PHX_HOST is unset" do
      assert ConfigHelpers.resolve_host(nil, "NOT_FLY_APP") == "localhost"
      assert ConfigHelpers.resolve_host("", "NOT_FLY_APP") == "localhost"
    end

    test "treats a missing FLY_APP_NAME the same as the sentinel" do
      assert ConfigHelpers.resolve_host(nil, nil) == "localhost"
      assert ConfigHelpers.resolve_host("map.example.com", nil) == "map.example.com"
    end
  end

  describe "resolve_host/2 on Fly" do
    test "derives from FLY_APP_NAME when PHX_HOST is unset" do
      assert ConfigHelpers.resolve_host(nil, "wanderer") == "wanderer.fly.dev"
      assert ConfigHelpers.resolve_host("", "wanderer") == "wanderer.fly.dev"
    end

    # This is the whole point of the change: on Fly, an explicitly-set
    # PHX_HOST must win, otherwise a custom domain is unreachable.
    test "prefers an explicitly-set PHX_HOST over the .fly.dev derivation" do
      assert ConfigHelpers.resolve_host("map.example.com", "wanderer") ==
               "map.example.com"
    end
  end

  describe "resolve_web_app_url/4 off Fly" do
    test "uses WEB_APP_URL when set" do
      assert ConfigHelpers.resolve_web_app_url(
               "https://map.example.com",
               "localhost",
               8000,
               "NOT_FLY_APP"
             ) == "https://map.example.com"
    end

    test "falls back to http://host:port when WEB_APP_URL is unset" do
      assert ConfigHelpers.resolve_web_app_url(nil, "localhost", 8000, "NOT_FLY_APP") ==
               "http://localhost:8000"
    end

    test "passes an explicitly-empty WEB_APP_URL through so the scheme check still raises" do
      # `WEB_APP_URL=` in a .env file yields "" rather than nil. Today that reaches
      # URI.parse/1, produces a nil scheme, and raises at boot with the variable named.
      # Treating "" as unset would replace that loud failure with a silently wrong
      # OAuth callback URL, so "" must pass through unchanged.
      assert ConfigHelpers.resolve_web_app_url("", "localhost", 8000, "NOT_FLY_APP") == ""
    end
  end

  describe "resolve_web_app_url/4 on Fly" do
    test "derives https from the resolved host when WEB_APP_URL is unset" do
      assert ConfigHelpers.resolve_web_app_url(nil, "wanderer.fly.dev", 8080, "wanderer") ==
               "https://wanderer.fly.dev"
    end

    test "prefers an explicitly-set WEB_APP_URL over the https derivation" do
      assert ConfigHelpers.resolve_web_app_url(
               "https://map.example.com",
               "map.example.com",
               8080,
               "wanderer"
             ) == "https://map.example.com"
    end

    # Composition check: the two resolvers must agree, because the EVE OAuth
    # callback_url (runtime.exs:268) is built from web_app_url.
    test "composes with resolve_host so a custom domain flows into the URL" do
      host = ConfigHelpers.resolve_host("map.example.com", "wanderer")

      assert ConfigHelpers.resolve_web_app_url(nil, host, 8080, "wanderer") ==
               "https://map.example.com"
    end
  end
end
