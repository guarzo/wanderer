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

  test "settings entry loads tokens only when the allowed Public API tab is selected", %{
    conn: conn,
    map: map,
    user: user
  } do
    {:ok, token, _} = Tokens.create(map.id, user, "Lazy")
    parent = self()
    id = {__MODULE__, :lazy, parent}

    :telemetry.attach(
      id,
      [:wanderer_app, :repo, :query],
      fn _, _, metadata, _ ->
        if String.contains?(metadata.query, ~s(FROM "map_integration_tokens_v1")),
          do: send(parent, :token_read)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    {:ok, view, _} = live(conn, "/maps/#{map.slug}/settings")
    assert :sys.get_state(view.pid).socket.assigns.integration_tokens == []
    refute_receive :token_read, 0
    render_click(view, "change_settings_tab", %{"tab" => "public_api"})
    assert_receive :token_read
    assert [%{id: id}] = :sys.get_state(view.pid).socket.assigns.integration_tokens
    assert id == token.id

    render_click(view, "change_settings_tab", %{"tab" => "general"})
    Application.put_env(:wanderer_app, :public_api_disabled, true)
    on_exit(fn -> Application.put_env(:wanderer_app, :public_api_disabled, false) end)
    render_click(view, "change_settings_tab", %{"tab" => "public_api"})
    assert :sys.get_state(view.pid).socket.assigns.active_settings_tab == "general"
    refute_receive :token_read, 0
  end

  for {mutation, reveal?} <- [
        {"name = 'Updated metadata'", true},
        {"generation = generation + 1", false},
        {"revoked_at = now(), generation = generation + 1", false}
      ] do
    test "one-time reveal rechecks identity and generation after #{mutation}", %{view: view} do
      after_token_issue(fn ->
        WandererApp.Repo.query!("UPDATE map_integration_tokens_v1 SET " <> unquote(mutation))
      end)

      html = view |> form("#create-integration-token", %{name: "Reveal check"}) |> render_submit()
      assert html =~ ~r/wmi_v1_[0-9a-f-]{36}_[A-Za-z0-9_-]{43}/ == unquote(reveal?)
    end
  end

  test "an issued token missing from the fresh list is never revealed", %{view: view} do
    after_token_issue(fn -> WandererApp.Repo.query!("DELETE FROM map_integration_tokens_v1") end)
    html = view |> form("#create-integration-token", %{name: "Hidden"}) |> render_submit()
    refute html =~ ~r/wmi_v1_[0-9a-f-]{36}_[A-Za-z0-9_-]{43}/
    assert :sys.get_state(view.pid).socket.assigns.revealed_integration_token == nil
  end

  test "stale generation clears reveal and refreshes the current token list", %{
    view: view,
    map: map,
    user: user
  } do
    view |> form("#create-integration-token", %{name: "Conflict"}) |> render_submit()
    {:ok, [token]} = Tokens.list(map.id, user)
    {:ok, current, _} = Tokens.replace(map.id, user, token.id, token.generation)

    html =
      render_click(view, "replace-integration-token", %{"id" => token.id, "generation" => "1"})

    assert html =~ "Integration token changed"
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.revealed_integration_token == nil
    assert assigns.integration_tokens == [current]
  end

  test "conflict refresh failure clears metadata without retrying recursively", %{
    view: view,
    map: map
  } do
    stranger = insert(:character)
    Api.Map.assign_owner!(map, %{owner_id: stranger.id})

    html =
      render_click(view, "replace-integration-token", %{
        "id" => Ash.UUID.generate(),
        "generation" => "bad"
      })

    assert html =~ "Unable to manage integration tokens"
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.integration_tokens == []
    assert assigns.revealed_integration_token == nil
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

      assert html =~ "Integration token changed"
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

  defp after_token_issue(fun) do
    id = {__MODULE__, :issue, make_ref()}

    :telemetry.attach(
      id,
      [:wanderer_app, :repo, :query],
      fn _, _, metadata, _ ->
        if String.starts_with?(metadata.query, ~s(INSERT INTO "map_integration_tokens_v1")) do
          :telemetry.detach(id)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
