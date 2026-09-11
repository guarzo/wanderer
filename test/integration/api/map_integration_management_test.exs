defmodule WandererAppWeb.MapIntegrationManagementTest do
  use WandererAppWeb.ApiCase, async: false
  import Phoenix.LiveViewTest
  alias WandererApp.Api
  alias WandererApp.MapIntegrationTokens, as: Tokens

  setup do
    user = insert(:user)
    owner = insert(:character, %{user_id: user.id})
    map = insert(:map, %{owner_id: owner.id})
    WandererApp.TestHelpers.ensure_map_server_started(map.id)
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)
    on_exit(fn -> Application.delete_env(:wanderer_app, :map_integrations_enabled) end)
    conn = build_conn() |> Plug.Test.init_test_session(user_id: user.id)
    {:ok, view, _} = live(conn, "/maps/#{map.slug}/settings")
    render_click(view, "change_settings_tab", %{"tab" => "public_api"})
    %{user: user, map: map, view: view, conn: conn}
  end

  test "creates, reveals once, lists, replaces and revokes from existing Public API settings", %{
    view: view,
    map: map,
    user: user,
    conn: conn
  } do
    assert has_element?(view, "#create-integration-token")
    html = view |> form("#create-integration-token", %{name: "Wingman"}) |> render_submit()
    [wire] = Regex.run(~r/wmi_v1_[0-9a-f-]{36}_[A-Za-z0-9_-]{43}/, html)
    assert {:ok, [token]} = Tokens.list(map.id, user)
    assert {:ok, _} = Tokens.authenticate(wire)
    refute inspect(:sys.get_state(view.pid), limit: :infinity) =~ wire
    render_click(view, "dismiss-integration-token")
    refute render(view) =~ wire
    {:ok, another_view, _} = live(conn, "/maps/#{map.slug}/settings")
    refute render_click(another_view, "change_settings_tab", %{"tab" => "public_api"}) =~ wire

    html =
      render_click(view, "replace-integration-token", %{"id" => token.id, "generation" => "1"})

    [new] = Regex.run(~r/wmi_v1_[0-9a-f-]{36}_[A-Za-z0-9_-]{43}/, html)
    refute new == wire
    assert {:error, :invalid_token} = Tokens.authenticate(wire)
    render_click(view, "revoke-integration-token", %{"id" => token.id, "generation" => "2"})
    assert {:error, :invalid_token} = Tokens.authenticate(new)
    refute render(view) =~ new
  end

  test "closing settings clears the one-time token reveal from the live socket", %{view: view} do
    view |> form("#create-integration-token", %{name: "Cancel reveal"}) |> render_submit()
    assert %Tokens.Revealed{} = :sys.get_state(view.pid).socket.assigns.revealed_integration_token

    # LiveViewTest does not follow JS.exec; exercise the modal's cancel patch directly.
    render_patch(view, "/maps")
    assert :sys.get_state(view.pid).socket.assigns.live_action == :index
    refute has_element?(view, "#map-settings-modal")
    assert :sys.get_state(view.pid).socket.assigns.revealed_integration_token == nil
  end

  test "malformed event generations fail without crashing or changing tokens", %{
    view: view,
    map: map,
    user: user
  } do
    {:ok, token, wire} = Tokens.create(map.id, user, "Wingman")

    for generation <- [%{}, [], "bad", "-1"] do
      html =
        render_click(view, "replace-integration-token", %{
          "id" => token.id,
          "generation" => generation
        })

      assert html =~ "Unable to manage integration tokens"
      assert {:ok, _} = Tokens.authenticate(wire)
    end
  end

  test "stale settings cannot issue, replace, list or revoke after permission loss", %{
    view: view,
    map: map,
    user: user
  } do
    {:ok, token, wire} = Tokens.create(map.id, user, "Wingman")
    stranger = insert(:character)
    {:ok, _} = Api.Map.assign_owner(map, %{owner_id: stranger.id})

    for {event, params} <- [
          {"create-integration-token", %{"name" => "Forbidden"}},
          {"replace-integration-token", %{"id" => token.id, "generation" => "1"}},
          {"revoke-integration-token", %{"id" => token.id, "generation" => "1"}},
          {"list-integration-tokens", %{}}
        ] do
      html = render_click(view, event, params)
      assert html =~ "Unable to manage integration tokens"
      refute html =~ wire
    end

    assert length(Api.MapIntegrationToken.by_map!(map.id)) == 1
  end

  test "ignores forged selected-map parameters and rejects token IDs from another map", %{
    view: view,
    map: map,
    user: user
  } do
    other = insert(:map, %{owner_id: map.owner_id})
    {:ok, foreign, wire} = Tokens.create(other.id, user, "Other")

    render_click(view, "revoke-integration-token", %{
      "id" => foreign.id,
      "generation" => "1",
      "map_id" => other.id
    })

    assert {:ok, _} = Tokens.authenticate(wire)
    render_click(view, "create-integration-token", %{"name" => "Selected", "map_id" => other.id})
    assert {:ok, [%{name: "Selected"}]} = Tokens.list(map.id, user)
    assert {:ok, [%{name: "Other"}]} = Tokens.list(other.id, user)
  end
end
