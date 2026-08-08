defmodule WandererAppWeb.MapSystemsEventHandlerCorporationSearchTest do
  use WandererApp.DataCase, async: false

  alias WandererAppWeb.MapSystemsEventHandler

  # Guards the Task 13 rewiring: the "get_corporation_names" UI event must reach
  # WandererApp.Esi.CorporationSearch instead of the deleted private
  # implementation, and must answer in the `{:reply, %{results: [...]}, socket}`
  # shape the frontend expects. Both cases stay inside the shared no-characters
  # and minimum-length gates, so they also pin that the call site defers to those
  # rules rather than carrying a bespoke copy.
  #
  # What they do NOT catch — verified, not assumed — is a swapped argument order:
  # calling `CorporationSearch.search(search, user_chars)` still leaves these two
  # tests green, because `search/2`'s deliberate `{:ok, []}` catch-all absorbs
  # any argument shape it does not recognise. Pinning the order would take a test
  # that gets as far as a stubbed ESI client.
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
