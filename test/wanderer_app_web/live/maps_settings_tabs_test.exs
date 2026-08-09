defmodule WandererAppWeb.MapsSettingsTabsTest do
  @moduledoc """
  The settings dialog's tab list carries `:if` guards that are purely
  deployment feature flags (`maps_live.html.heex`). Those guards only control
  what is *rendered* — `change_settings_tab` is a client-pushed event, so
  without a server-side allowlist a crafted event can select a panel whose
  `<li>` was never shown.

  These tests are not a permission boundary: the dialog itself is already gated
  on the `delete_map` permission in `apply_action(:settings, ...)`, so every
  actor reaching this point is a map owner or ACL admin.
  """
  use WandererAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias WandererAppWeb.Factory

  setup %{conn: conn} do
    # `Api.Map.owner_id` points at a CHARACTER, not a user (see
    # map_notifications_test.exs) — passing a user id fails the foreign key.
    user = Factory.insert(:user, %{})
    character = Factory.insert(:character, %{user_id: user.id})
    map = Factory.insert(:map, %{owner_id: character.id})

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, map: map}
  end

  defp open_settings(conn, map) do
    {:ok, view, _html} = live(conn, ~p"/maps/#{map.slug}/settings")
    view
  end

  defp push_tab(view, tab) do
    render_click(view, "change_settings_tab", %{"tab" => tab})
  end

  defp selected_tab_count(view, tab) do
    view
    |> element("li.p-tabview-selected button[phx-value-tab='#{tab}']")
    |> has_element?()
  end

  describe "always-available tabs" do
    test "a rendered tab can be selected", %{conn: conn, map: map} do
      view = open_settings(conn, map)

      push_tab(view, "notifications")

      assert selected_tab_count(view, "notifications")
      assert has_element?(view, "#map-notifications")
    end

    test "the dialog opens on the general tab", %{conn: conn, map: map} do
      view = open_settings(conn, map)

      assert selected_tab_count(view, "general")
    end

    # The tab strip was transcribed out of a rendered PrimeReact TabView, which
    # left `aria-selected` as a hardcoded literal on all seven tabs: General
    # permanently claimed to be the selected tab and every other tab
    # permanently denied it, whatever was actually on screen. It is computed
    # now, and this is the test that keeps it computed.
    test "aria-selected follows the active tab", %{conn: conn, map: map} do
      view = open_settings(conn, map)

      assert has_element?(view, "button[phx-value-tab='general'][aria-selected='true']")
      assert has_element?(view, "button[phx-value-tab='notifications'][aria-selected='false']")

      push_tab(view, "notifications")

      assert has_element?(view, "button[phx-value-tab='notifications'][aria-selected='true']")
      assert has_element?(view, "button[phx-value-tab='general'][aria-selected='false']")
    end

    # `aria-controls` pointed at four ids, three of which did not exist in the
    # document, and one of which was shared by three different tabs. There is
    # exactly one panel element; every tab must name it, and the panel must
    # name whichever tab is showing.
    test "every tab points at the one real panel, which points back", %{conn: conn, map: map} do
      view = open_settings(conn, map)

      for tab <- ~w(general import public_api notifications) do
        assert has_element?(
                 view,
                 "button[phx-value-tab='#{tab}'][aria-controls='map-settings-tabpanel']"
               )
      end

      assert has_element?(
               view,
               "#map-settings-tabpanel[aria-labelledby='map-settings-tab-general']"
             )

      push_tab(view, "notifications")

      assert has_element?(
               view,
               "#map-settings-tabpanel[aria-labelledby='map-settings-tab-notifications']"
             )
    end

    # Every tab but General used to be `tabindex="-1"` on an `<a>` with no
    # `href`: not focusable, and not activatable by Enter even if focused, so
    # Notifications could not be reached from the keyboard at all.
    test "tabs are real buttons, not inert anchors", %{conn: conn, map: map} do
      view = open_settings(conn, map)

      refute has_element?(view, "a[phx-value-tab='notifications']")
      assert has_element?(view, "button[type='button'][phx-value-tab='notifications']")
      refute has_element?(view, "[phx-value-tab='notifications'][tabindex='-1']")
    end
  end

  describe "unknown tab values are ignored" do
    test "an unrecognised tab leaves the current selection intact", %{conn: conn, map: map} do
      view = open_settings(conn, map)

      push_tab(view, "definitely-not-a-tab")

      assert selected_tab_count(view, "general")
      refute has_element?(view, "#map-notifications")
    end

    test "an unrecognised tab does not clear an existing selection", %{conn: conn, map: map} do
      view = open_settings(conn, map)
      push_tab(view, "notifications")

      push_tab(view, "definitely-not-a-tab")

      assert selected_tab_count(view, "notifications")
    end
  end

  describe "feature-flagged tabs" do
    setup do
      original = Application.get_env(:wanderer_app, :map_subscriptions_enabled)
      on_exit(fn -> Application.put_env(:wanderer_app, :map_subscriptions_enabled, original) end)
      :ok
    end

    test "a subscription tab is rejected when subscriptions are disabled", %{
      conn: conn,
      map: map
    } do
      Application.put_env(:wanderer_app, :map_subscriptions_enabled, false)
      view = open_settings(conn, map)

      # The <li> is not rendered ...
      refute has_element?(view, "button[phx-value-tab='bot']")

      # ... and pushing the event directly must not render the panel either.
      push_tab(view, "bot")

      refute selected_tab_count(view, "bot")
      refute render(view) =~ "Bots Integration"
    end

    test "a subscription tab is selectable when subscriptions are enabled", %{
      conn: conn,
      map: map
    } do
      Application.put_env(:wanderer_app, :map_subscriptions_enabled, true)
      view = open_settings(conn, map)

      push_tab(view, "bot")

      assert selected_tab_count(view, "bot")
      assert render(view) =~ "Bots Integration"
    end
  end

  describe "public api tab" do
    setup do
      original = Application.get_env(:wanderer_app, :public_api_disabled)
      on_exit(fn -> Application.put_env(:wanderer_app, :public_api_disabled, original) end)
      :ok
    end

    test "is rejected when the public api is disabled", %{conn: conn, map: map} do
      Application.put_env(:wanderer_app, :public_api_disabled, true)
      view = open_settings(conn, map)

      push_tab(view, "public_api")

      # Asserting on the public_api <li>/panel would be vacuous here: both carry
      # their own `:if` on the same flag, so neither renders either way. The
      # meaningful signal is that the selection did not move off general.
      assert selected_tab_count(view, "general")
      refute selected_tab_count(view, "public_api")
    end

    test "is selectable when the public api is enabled", %{conn: conn, map: map} do
      Application.put_env(:wanderer_app, :public_api_disabled, false)
      view = open_settings(conn, map)

      push_tab(view, "public_api")

      assert selected_tab_count(view, "public_api")
    end
  end
end
