defmodule WandererApp.ExternalEvents.Discord.NotableItemsTest do
  # `async: false`: the triff stub keeps state in one named Agent, the module
  # caches into the shared `:api_cache`, and both seams are application env.
  use ExUnit.Case, async: false

  import Mox

  alias WandererApp.ExternalEvents.Discord.NotableItems
  alias WandererApp.Market.Triff.HttpStub

  @hash "abc123hash"

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    HttpStub.start()
    HttpStub.reset()
    Cachex.clear(:api_cache)

    Application.put_env(:wanderer_app, :triff_http_client, HttpStub)
    Application.put_env(:wanderer_app, :esi_client, WandererApp.Esi.Mock)

    on_exit(fn ->
      Application.delete_env(:wanderer_app, :triff_http_client)
      Application.delete_env(:wanderer_app, :esi_client)
      Cachex.clear(:api_cache)
    end)

    :ok
  end

  # -- fixtures ---------------------------------------------------------------

  defp kill(killmail_id, opts \\ []) do
    zkb = Keyword.get(opts, :zkb, %{"hash" => @hash})
    %{"killmail_id" => killmail_id, "zkb" => zkb}
  end

  defp killmail(items), do: %{"victim" => %{"items" => items}}

  defp dropped(type_id, quantity, extra \\ %{}),
    do:
      Map.merge(
        %{"item_type_id" => type_id, "quantity_dropped" => quantity, "flag" => 5},
        extra
      )

  defp destroyed(type_id, quantity),
    do: %{"item_type_id" => type_id, "quantity_destroyed" => quantity, "flag" => 27}

  # Scripts one triff response pricing each `{type_id, unit_price}` pair.
  defp prices(pairs) do
    types =
      Enum.map(pairs, fn {type_id, price} ->
        %{"type_id" => type_id, "sell" => %{"p05" => price, "best" => nil}}
      end)

    HttpStub.set_responses([{:ok, 200, %{"types" => types}}])
  end

  defp stub_killmail(killmails) do
    stub(WandererApp.Esi.Mock, :get_killmail, fn killmail_id, _hash ->
      case Map.fetch(killmails, killmail_id) do
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, body} -> {:ok, body}
        :error -> {:error, :not_found}
      end
    end)
  end

  defp stub_names(names) do
    stub(WandererApp.Esi.Mock, :get_type_info, fn type_id ->
      case Map.fetch(names, type_id) do
        {:ok, :error} -> {:error, :not_found}
        {:ok, name} -> {:ok, %{"name" => name}}
        :error -> {:error, :not_found}
      end
    end)
  end

  # -- tests ------------------------------------------------------------------

  describe "enrich/1" do
    test "returns an empty map for no kills" do
      assert NotableItems.enrich([]) == %{}
    end

    test "names loot above the threshold" do
      stub_killmail(%{1 => killmail([dropped(1319, 1)])})
      prices([{1319, 100_000_000}])
      stub_names(%{1319 => "Damage Control II"})

      assert %{1 => [item]} = NotableItems.enrich([kill(1)])

      assert item == %{
               name: "Damage Control II",
               quantity: 1,
               value: 100_000_000.0,
               abyssal?: false
             }
    end

    test "excludes destroyed items" do
      stub_killmail(%{1 => killmail([destroyed(1319, 1)])})
      stub_names(%{1319 => "Damage Control II"})

      assert NotableItems.enrich([kill(1)]) == %{}
      # Nothing dropped, so no pricing request was needed at all.
      assert HttpStub.requests() == []
    end

    test "flattens items nested inside a container" do
      container = dropped(3468, 1, %{"items" => [dropped(1319, 1)]})
      stub_killmail(%{1 => killmail([container])})
      prices([{1319, 100_000_000}, {3468, 1_000}])
      stub_names(%{1319 => "Damage Control II", 3468 => "Small Standard Container"})

      assert %{1 => [%{name: "Damage Control II"}]} = NotableItems.enrich([kill(1)])
    end

    test "sums quantities of the same type across slots" do
      stub_killmail(%{1 => killmail([dropped(1319, 1), dropped(1319, 2, %{"flag" => 13})])})
      prices([{1319, 20_000_000}])
      stub_names(%{1319 => "Damage Control II"})

      assert %{1 => [%{quantity: 3, value: 60_000_000.0}]} = NotableItems.enrich([kill(1)])
    end
  end

  describe "threshold and limit" do
    test "excludes an item worth exactly the threshold" do
      stub_killmail(%{1 => killmail([dropped(1319, 1)])})
      prices([{1319, 50_000_000}])
      stub_names(%{1319 => "Damage Control II"})

      assert NotableItems.enrich([kill(1)]) == %{}
    end

    test "includes an item worth one ISK more than the threshold" do
      stub_killmail(%{1 => killmail([dropped(1319, 1)])})
      prices([{1319, 50_000_001}])
      stub_names(%{1319 => "Damage Control II"})

      assert %{1 => [%{name: "Damage Control II"}]} = NotableItems.enrich([kill(1)])
    end

    test "takes the highest-valued items in descending order, capped at the limit" do
      items = for type_id <- 1..7, do: dropped(type_id, 1)
      stub_killmail(%{1 => killmail(items)})
      prices(for type_id <- 1..7, do: {type_id, 100_000_000 * type_id})
      stub_names(Map.new(1..7, fn type_id -> {type_id, "Item #{type_id}"} end))

      assert %{1 => selected} = NotableItems.enrich([kill(1)])

      assert Enum.map(selected, & &1.name) == [
               "Item 7",
               "Item 6",
               "Item 5",
               "Item 4",
               "Item 3"
             ]
    end
  end

  describe "abyssal items" do
    test "flags a name beginning with abyssal, case-insensitively" do
      stub_killmail(%{1 => killmail([dropped(1319, 1), dropped(2048, 1)])})
      prices([{1319, 100_000_000}, {2048, 200_000_000}])
      stub_names(%{1319 => "Damage Control II", 2048 => "abyssal Warp Scrambler"})

      assert %{1 => [abyssal, regular]} = NotableItems.enrich([kill(1)])
      assert abyssal.abyssal?
      refute regular.abyssal?
    end
  end

  describe "multiple kills" do
    test "enriches each kill independently and omits those with nothing notable" do
      stub_killmail(%{
        1 => killmail([dropped(1319, 1)]),
        2 => killmail([dropped(2048, 1)])
      })

      prices([{1319, 100_000_000}, {2048, 1_000}])
      stub_names(%{1319 => "Damage Control II", 2048 => "Civilian Gatling Autocannon"})

      result = NotableItems.enrich([kill(1), kill(2)])

      assert Map.keys(result) == [1]
      # One batched pricing request covers both kills.
      assert length(HttpStub.requests()) == 1
    end

    # The kills are fetched concurrently, so an exception in one runs in its own
    # stream child. Without the per-kill rescue that child would take the whole
    # stream down and the healthy kills would be lost with it.
    test "one kill raising does not cost the others their section" do
      stub(WandererApp.Esi.Mock, :get_killmail, fn
        1, _hash -> raise "boom"
        2, _hash -> {:ok, killmail([dropped(1319, 1)])}
      end)

      prices([{1319, 100_000_000}])
      stub_names(%{1319 => "Damage Control II"})

      assert %{2 => [%{name: "Damage Control II"}]} =
               NotableItems.enrich([kill(1), kill(2)])
    end

    test "enriches a full batch of kills" do
      killmails = Map.new(1..30, fn id -> {id, killmail([dropped(1319, 1)])} end)
      stub_killmail(killmails)
      prices([{1319, 100_000_000}])
      stub_names(%{1319 => "Damage Control II"})

      result = NotableItems.enrich(Enum.map(1..30, &kill/1))

      assert map_size(result) == 30
      assert length(HttpStub.requests()) == 1
    end
  end

  describe "fail-open" do
    test "skips a kill with no zkb hash" do
      stub_killmail(%{1 => killmail([dropped(1319, 1)])})

      assert NotableItems.enrich([kill(1, zkb: %{})]) == %{}
      assert NotableItems.enrich([kill(1, zkb: nil)]) == %{}
    end

    test "skips a kill whose ESI fetch fails" do
      stub_killmail(%{1 => {:error, :timeout}})

      assert NotableItems.enrich([kill(1)]) == %{}
    end

    test "skips a kill whose ESI fetch raises" do
      stub(WandererApp.Esi.Mock, :get_killmail, fn _id, _hash -> raise "boom" end)

      assert NotableItems.enrich([kill(1)]) == %{}
    end

    test "returns nothing when pricing fails" do
      stub_killmail(%{1 => killmail([dropped(1319, 1)])})
      HttpStub.set_responses([{:error, :timeout}])

      assert NotableItems.enrich([kill(1)]) == %{}
    end

    test "omits an item whose name cannot be resolved" do
      stub_killmail(%{1 => killmail([dropped(1319, 1), dropped(2048, 1)])})
      prices([{1319, 100_000_000}, {2048, 200_000_000}])
      stub_names(%{1319 => "Damage Control II", 2048 => :error})

      assert %{1 => [%{name: "Damage Control II"}]} = NotableItems.enrich([kill(1)])
    end

    test "omits a kill whose only notable item cannot be named" do
      stub_killmail(%{1 => killmail([dropped(1319, 1)])})
      prices([{1319, 100_000_000}])
      stub_names(%{1319 => :error})

      assert NotableItems.enrich([kill(1)]) == %{}
    end

    test "omits an item that triff could not price" do
      stub_killmail(%{1 => killmail([dropped(1319, 1)])})
      prices([])
      stub_names(%{1319 => "Damage Control II"})

      assert NotableItems.enrich([kill(1)]) == %{}
    end

    test "tolerates a killmail with no victim items" do
      stub_killmail(%{1 => %{"victim" => %{}}})

      assert NotableItems.enrich([kill(1)]) == %{}
    end
  end

  describe "impl/0" do
    test "defaults to this module and honours the override" do
      assert NotableItems.impl() == NotableItems

      Application.put_env(:wanderer_app, :notable_items_enricher, __MODULE__)
      on_exit(fn -> Application.delete_env(:wanderer_app, :notable_items_enricher) end)

      assert NotableItems.impl() == __MODULE__
    end
  end
end
