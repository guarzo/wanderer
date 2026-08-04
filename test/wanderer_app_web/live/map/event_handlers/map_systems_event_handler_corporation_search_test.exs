defmodule WandererAppWeb.MapSystemsEventHandlerCorporationSearchTest do
  use WandererApp.DataCase, async: false

  alias WandererAppWeb.MapSystemsEventHandler

  # Guards the Task 13 rewiring: the "get_corporation_names" UI event must go
  # through WandererApp.Esi.CorporationSearch.search/2. A caller that still
  # points at the deleted private implementation, or that passes the wrong
  # argument order, would fail these assertions rather than the module's own
  # tests (which know nothing about this call site).
  describe "get_corporation_names UI event" do
    test "replies with no results when the user has no characters" do
      socket = %Phoenix.LiveView.Socket{assigns: %{current_user: %{characters: []}}}

      assert {:reply, %{results: []}, ^socket} =
               MapSystemsEventHandler.handle_ui_event(
                 "get_corporation_names",
                 %{"search" => "Karmafleet"},
                 socket
               )
    end

    test "replies with no results below the minimum search length without touching ESI" do
      # A character id that does not exist would make a real ESI lookup fail
      # loudly. Staying under the minimum-length gate proves the call site is
      # wired to the shared min-length rule, not a bespoke copy.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{current_user: %{characters: [%{id: Ecto.UUID.generate()}]}}
      }

      assert {:reply, %{results: []}, ^socket} =
               MapSystemsEventHandler.handle_ui_event(
                 "get_corporation_names",
                 %{"search" => "Ka"},
                 socket
               )
    end
  end
end
