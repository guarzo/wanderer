defmodule WandererApp.Esi.CorporationSearchTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Esi.CorporationSearch

  describe "search/2" do
    test "returns no results when the user has no characters" do
      assert {:ok, []} = CorporationSearch.search([], "Karmafleet")
    end

    test "returns no results below the minimum search length" do
      # Two characters is under the three-character minimum, so this must not
      # reach ESI at all. A character id that does not exist would make any
      # actual lookup fail loudly.
      assert {:ok, []} =
               CorporationSearch.search([%{id: Ecto.UUID.generate()}], "Ka")
    end

    test "returns no results for a non-binary search term" do
      assert {:ok, []} = CorporationSearch.search([%{id: Ecto.UUID.generate()}], nil)
    end

    test "min_search_length is three, matching the pre-extraction behaviour" do
      assert CorporationSearch.min_search_length() == 3
    end
  end

  describe "label_for/2" do
    test "renders ticker and name when ESI answers" do
      fetch = fn 98_000_001 -> {:ok, %{"name" => "Karmafleet", "ticker" => "KARMA"}} end

      assert CorporationSearch.label_for(98_000_001, fetch) == "[KARMA] Karmafleet"
    end

    test "renders the bare name when ESI answers without a ticker" do
      fetch = fn 98_000_001 -> {:ok, %{"name" => "Karmafleet", "ticker" => ""}} end

      assert CorporationSearch.label_for(98_000_001, fetch) == "Karmafleet"
    end

    test "falls back to the bare id when ESI fails" do
      # A saved focus corporation must still render as a removable chip while
      # ESI is down. Dropping it would look like the setting was lost, and the
      # user has no way to un-set what is not rendered.
      fetch = fn _ -> {:error, :timeout} end

      assert CorporationSearch.label_for(98_000_001, fetch) == "98000001"
    end

    test "falls back to the bare id when ESI raises" do
      fetch = fn _ -> raise "boom" end

      assert CorporationSearch.label_for(98_000_001, fetch) == "98000001"
    end
  end
end
