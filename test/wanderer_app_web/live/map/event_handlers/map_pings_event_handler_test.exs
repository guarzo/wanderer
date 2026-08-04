defmodule WandererAppWeb.MapPingsEventHandlerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias WandererAppWeb.MapPingsEventHandler

  setup do
    # config/test.exs pins the logger at :warning, which drops the core
    # handler's debug line before capture_log can see it.
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "a cancel_ping the working clause cannot match is logged, not absorbed" do
    # update_system: false misses the clause at :145. The debug catch-all
    # returned {:noreply, socket} for it, so a permission-rejected cancel was
    # indistinguishable from a successful one - in the logs and to the caller.
    socket = %{
      assigns: %{
        map_id: "map-1",
        current_user: %{id: "user-1"},
        main_character_id: "char-1",
        has_tracked_characters?: true,
        user_permissions: %{update_system: false}
      }
    }

    log =
      capture_log(fn ->
        assert {:noreply, ^socket} =
                 MapPingsEventHandler.handle_ui_event(
                   "cancel_ping",
                   %{"id" => "ping-1", "type" => 1},
                   socket
                 )
      end)

    assert log =~ "unhandled map ui event"
  end
end
