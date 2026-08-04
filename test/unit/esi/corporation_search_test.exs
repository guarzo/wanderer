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

    test "reports unusable characters as an error rather than as no results" do
      # `MapSystemsEventHandler` passes `current_user.characters` straight
      # through, so an unloaded association reaches here as `%Ash.NotLoaded{}`.
      # Answering `{:ok, []}` rendered a permanently empty dropdown that looked
      # exactly like "no corporation by that name", with nothing in the logs.
      assert {:error, :invalid_characters} =
               CorporationSearch.search(%Ash.NotLoaded{}, "Karmafleet")
    end

    test "reports swapped arguments as an error rather than as no results" do
      assert {:error, :invalid_characters} =
               CorporationSearch.search("Karmafleet", [%{id: Ecto.UUID.generate()}])
    end

    test "min_search_length is three, matching the pre-extraction behaviour" do
      assert CorporationSearch.min_search_length() == 3
    end

    test "decorates each hit with the shape both callers render" do
      search_fun = fn _char_id, _opts ->
        {:ok, [%{label: "Karmafleet", value: "98000001", corporation: true}]}
      end

      fetch_fun = fn "98000001" -> {:ok, %{"name" => "Karmafleet", "ticker" => "KARMA"}} end

      assert {:ok, [hit]} =
               CorporationSearch.search([%{id: Ecto.UUID.generate()}], "Karmafleet",
                 search_fun: search_fun,
                 fetch_fun: fetch_fun
               )

      # The keys `Character.search/2` produced survive alongside the added ones.
      assert hit.label == "Karmafleet"
      assert hit.corporation == true

      assert hit.formatted == "[KARMA] Karmafleet"
      assert hit.name == "Karmafleet"
      assert hit.ticker == "KARMA"
      # Documented as strings: callers that persist integers must convert.
      assert hit.id == "98000001"
      assert hit.value == "98000001"
      assert hit.type == "corp"
    end

    test "a hit whose ticker lookup fails still renders its bare name" do
      search_fun = fn _char_id, _opts -> {:ok, [%{label: "Karmafleet", value: "98000001"}]} end
      fetch_fun = fn _ -> {:error, :timeout} end

      assert {:ok, [hit]} =
               CorporationSearch.search([%{id: Ecto.UUID.generate()}], "Karmafleet",
                 search_fun: search_fun,
                 fetch_fun: fetch_fun
               )

      assert hit.formatted == "Karmafleet"
      assert hit.ticker == ""
    end

    test "caps the hits at max_results/0 BEFORE enriching them" do
      over_cap = CorporationSearch.max_results() + 15

      results =
        Enum.map(1..over_cap, fn n ->
          %{label: "Corp #{n}", value: to_string(98_000_000 + n)}
        end)

      search_fun = fn _char_id, _opts -> {:ok, results} end

      # Counting the enrichment calls is the point: capping after enrichment
      # would return the right length while still issuing one sequential ESI
      # lookup per hit, which is the block this cap exists to prevent.
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

      fetch_fun = fn _ ->
        Agent.update(counter, &(&1 + 1))
        {:ok, %{"name" => "Corp", "ticker" => "C"}}
      end

      assert {:ok, hits} =
               CorporationSearch.search([%{id: Ecto.UUID.generate()}], "Corp",
                 search_fun: search_fun,
                 fetch_fun: fetch_fun
               )

      assert length(hits) == CorporationSearch.max_results()
      assert Agent.get(counter, & &1) == CorporationSearch.max_results()
    end

    test "passes an ESI failure through instead of swallowing it" do
      search_fun = fn _char_id, _opts -> {:error, :forbidden} end

      assert {:error, :forbidden} =
               CorporationSearch.search([%{id: Ecto.UUID.generate()}], "Karmafleet",
                 search_fun: search_fun
               )
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
