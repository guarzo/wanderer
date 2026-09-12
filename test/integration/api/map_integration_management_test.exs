defmodule WandererAppWeb.MapIntegrationManagementTest do
  use WandererAppWeb.ApiCase, async: false
  import Phoenix.LiveViewTest
  alias WandererApp.Api
  alias WandererApp.MapIntegrationTokens, as: Tokens
  alias WandererAppWeb.MapCoreEventHandler, as: Handler

  setup do
    user = insert(:user)
    owner = insert(:character, %{user_id: user.id})
    map = insert(:map, %{owner_id: owner.id})
    Application.put_env(:wanderer_app, :map_integrations_enabled, true)
    on_exit(fn -> Application.delete_env(:wanderer_app, :map_integrations_enabled) end)
    socket = socket(map, user)
    %{user: user, owner: owner, map: map, socket: socket}
  end

  test "replies directly with the personal event contract, never assigns or broadcasts secrets",
       c do
    assert %{success: true, available: true, enabled: false} =
             event(c.socket, "get_location_api_settings")

    assert %{success: true, enabled: true} =
             event(c.socket, "set_location_api_enabled", %{"enabled" => true})

    Phoenix.PubSub.subscribe(WandererApp.PubSub, "maps:#{c.map.id}")

    assert %{success: true, available: true, enabled: true, token: nil} =
             event(c.socket, "get_location_api_token")

    assert %{success: true, token: token} = event(c.socket, "generate_location_api_token")
    assert Enum.sort(Map.keys(token)) == [:generation, :id, :value]
    assert token.generation == 1
    assert %{success: true, token: ^token} = event(c.socket, "get_location_api_token")

    assert %{success: true, token: ^token} =
             event(socket(c.map, c.user), "generate_location_api_token")

    refute_receive _, 0

    assert %{success: true, token: rotated} =
             event(c.socket, "regenerate_location_api_token", %{
               "id" => token.id,
               "generation" => 1
             })

    assert rotated.generation == 2

    assert %{success: false, code: "conflict"} =
             event(c.socket, "regenerate_location_api_token", %{
               "id" => token.id,
               "generation" => 1
             })

    assert %{success: true, token: nil} =
             event(c.socket, "revoke_location_api_token", %{"id" => rotated.id, "generation" => 2})

    assert {:error, :invalid_token} = Tokens.authenticate(rotated.value)
  end

  test "viewer can retrieve only their own token and forged admin state never authorizes toggles",
       c do
    {:ok, _} = Tokens.set_enabled(c.map.id, c.user, true)
    {viewer, member} = viewer(c)
    stale = socket(c.map, viewer)

    assert %{success: false, code: "forbidden"} =
             event(stale, "set_location_api_enabled", %{"enabled" => false})

    own = event(c.socket, "generate_location_api_token").token
    theirs = event(stale, "generate_location_api_token", %{"user_id" => c.user.id}).token
    refute own.value == theirs.value

    assert %{success: false, code: "conflict"} =
             event(c.socket, "revoke_location_api_token", %{
               "id" => theirs.id,
               "generation" => 1,
               "user_id" => viewer.id
             })

    Api.AccessListMember.update_role!(member, %{role: :blocked})

    for name <- [
          "get_location_api_settings",
          "get_location_api_token",
          "generate_location_api_token"
        ] do
      assert %{success: false, code: "forbidden"} = event(stale, name)
    end

    assert {:ok, _} = Tokens.authenticate(own.value)
  end

  test "ignores forged map identity and rejects malformed generations with bounded replies", c do
    {:ok, _} = Tokens.set_enabled(c.map.id, c.user, true)
    other = insert(:map, %{owner_id: c.owner.id})
    result = event(c.socket, "generate_location_api_token", %{"map_id" => other.id})
    assert {:ok, %{map_id: id}} = Tokens.authenticate(result.token.value)
    assert id == c.map.id

    for data <- [
          nil,
          %{},
          %{"id" => result.token.id, "generation" => "1"},
          %{"id" => ["secret"], "generation" => 1},
          %{"id" => result.token.id, "generation" => -1}
        ] do
      reply = event(c.socket, "regenerate_location_api_token", data)
      assert reply.success == false
      assert reply.code in ["conflict", "invalid_request"]
      refute Jason.encode!(reply) =~ result.token.value
      assert byte_size(Jason.encode!(reply)) < 256
    end

    assert %{success: false, code: "invalid_request"} =
             event(c.socket, "set_location_api_enabled", %{"enabled" => "true"})
  end

  test "temporary disable and decrypt failure never return a stale secret", c do
    {:ok, _} = Tokens.set_enabled(c.map.id, c.user, true)
    token = event(c.socket, "generate_location_api_token").token

    assert %{success: true, enabled: false} =
             event(c.socket, "set_location_api_enabled", %{"enabled" => false})

    assert %{success: true, token: nil} = event(c.socket, "get_location_api_token")
    assert %{success: false, code: "disabled"} = event(c.socket, "generate_location_api_token")
    event(c.socket, "set_location_api_enabled", %{"enabled" => true})
    assert %{success: true, token: ^token} = event(c.socket, "get_location_api_token")

    WandererApp.Repo.query!(
      "UPDATE map_integration_tokens_v1 SET encrypted_value = $1 WHERE id = $2",
      ["bad", Ecto.UUID.dump!(token.id)]
    )

    assert %{success: false, code: "service_unavailable", error: error} =
             reply = event(c.socket, "get_location_api_token")

    assert is_binary(error)
    refute Jason.encode!(reply) =~ token.value
  end

  test "admin-only MapsLive retains legacy API controls and points to personal map user settings",
       c do
    WandererApp.TestHelpers.ensure_map_server_started(c.map.id)
    conn = build_conn() |> Plug.Test.init_test_session(user_id: c.user.id)
    {:ok, view, _} = live(conn, "/maps/#{c.map.slug}/settings")
    render_click(view, "change_settings_tab", %{"tab" => "public_api"})
    assert has_element?(view, "button[phx-click=generate-map-api-key]")
    refute has_element?(view, "#create-integration-token")
    assert render(view) =~ "Map user settings"
    refute Map.has_key?(:sys.get_state(view.pid).socket.assigns, :revealed_integration_token)
  end

  defp socket(map, user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        map_id: map.id,
        current_user: user,
        user_permissions: %{admin_map: true},
        has_tracked_characters?: false,
        can_track?: true,
        flash: %{},
        __changed__: %{}
      }
    }
  end

  defp event(socket, name, data \\ nil) do
    assert {:reply, reply, ^socket} = Handler.handle_ui_event(name, data, socket)
    reply
  end

  defp viewer(c) do
    user = insert(:user)
    char = insert(:character, %{user_id: user.id})
    acl = insert(:access_list, %{owner_id: c.owner.id})
    insert(:map_access_list, %{map_id: c.map.id, access_list_id: acl.id})

    member =
      insert(:access_list_member, %{
        access_list_id: acl.id,
        eve_character_id: char.eve_id,
        role: :viewer
      })

    {user, member}
  end
end
