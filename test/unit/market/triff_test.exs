defmodule WandererApp.Market.TriffTest do
  # `async: false`: the stub keeps state in one named Agent and the module
  # caches into the shared `:api_cache`.
  use ExUnit.Case, async: false

  alias WandererApp.Market.Triff
  alias WandererApp.Market.Triff.HttpStub

  setup do
    HttpStub.start()
    HttpStub.reset()
    Cachex.clear(:api_cache)

    previous = Application.get_env(:wanderer_app, :triff_http_client)
    Application.put_env(:wanderer_app, :triff_http_client, HttpStub)

    on_exit(fn ->
      if previous do
        Application.put_env(:wanderer_app, :triff_http_client, previous)
      else
        Application.delete_env(:wanderer_app, :triff_http_client)
      end

      Cachex.clear(:api_cache)
    end)

    :ok
  end

  defp types(entries), do: %{"types" => entries}

  defp sell(type_id, p05, best),
    do: %{"type_id" => type_id, "sell" => %{"p05" => p05, "best" => best}}

  describe "quote_types/1" do
    test "returns an empty map without a request when given no ids" do
      assert {:ok, %{}} == Triff.quote_types([])
      assert HttpStub.requests() == []
    end

    test "prefers the p05 sell price" do
      HttpStub.set_responses([{:ok, 200, types([sell(1319, 316_539.07, 313_800)])}])

      assert {:ok, %{1319 => 316_539.07}} = Triff.quote_types([1319])
    end

    test "falls back to the best sell price when p05 is null" do
      HttpStub.set_responses([{:ok, 200, types([sell(1319, nil, 313_800)])}])

      assert {:ok, %{1319 => 313_800.0}} = Triff.quote_types([1319])
    end

    test "omits a type whose sell side is entirely null rather than pricing it at zero" do
      HttpStub.set_responses([{:ok, 200, types([sell(44_992, nil, nil)])}])

      assert {:ok, prices} = Triff.quote_types([44_992])
      refute Map.has_key?(prices, 44_992)
    end

    test "rejects negative, zero, and absurd prices" do
      HttpStub.set_responses([
        {:ok, 200,
         types([
           sell(1, -5, nil),
           sell(2, 0, nil),
           sell(3, 1.0e16, nil),
           sell(4, "not a number", nil)
         ])}
      ])

      assert {:ok, prices} = Triff.quote_types([1, 2, 3, 4])
      assert prices == %{}
    end

    test "falls back to best when p05 is present but invalid" do
      HttpStub.set_responses([{:ok, 200, types([sell(1319, -5, 313_800)])}])

      assert {:ok, %{1319 => 313_800.0}} = Triff.quote_types([1319])
    end

    test "does not return types that were not asked for" do
      HttpStub.set_responses([{:ok, 200, types([sell(1319, 100.0, nil), sell(9999, 200.0, nil)])}])

      assert {:ok, %{1319 => 100.0}} == Triff.quote_types([1319])
    end

    test "sends the mandatory station_id and aggregate parameters" do
      HttpStub.set_responses([{:ok, 200, types([])}])
      Triff.quote_types([1319])

      assert [url] = HttpStub.requests()
      assert url =~ "station_id=60003760"
      assert url =~ "include_aggregates=true"
      assert url =~ "include_orders=false"
      assert url =~ "type_ids=1319"
    end
  end

  describe "chunking" do
    test "splits at 900 ids per request" do
      ids = Enum.to_list(1..901)

      HttpStub.set_responses([
        {:ok, 200, types([sell(1, 10.0, nil)])},
        {:ok, 200, types([sell(901, 20.0, nil)])}
      ])

      assert {:ok, prices} = Triff.quote_types(ids)
      assert prices == %{1 => 10.0, 901 => 20.0}
      assert length(HttpStub.requests()) == 2
    end

    test "keeps a single request at exactly 900 ids" do
      HttpStub.set_responses([{:ok, 200, types([])}])

      assert {:ok, _} = Triff.quote_types(Enum.to_list(1..900))
      assert length(HttpStub.requests()) == 1
    end

    test "deduplicates ids before chunking" do
      HttpStub.set_responses([{:ok, 200, types([sell(1319, 100.0, nil)])}])

      assert {:ok, %{1319 => 100.0}} == Triff.quote_types([1319, 1319, 1319])
      assert length(HttpStub.requests()) == 1
    end

    test "keeps the prices from earlier chunks when a later chunk fails" do
      HttpStub.set_responses([
        {:ok, 200, types([sell(1, 10.0, nil)])},
        {:error, :timeout}
      ])

      assert {:ok, %{1 => 10.0}} == Triff.quote_types(Enum.to_list(1..901))
    end

    test "stops requesting after the first failing chunk" do
      HttpStub.set_responses([{:error, :timeout}])

      assert {:error, :timeout} = Triff.quote_types(Enum.to_list(1..1801))
      # Three chunks were due; the first failure ends the batch.
      assert length(HttpStub.requests()) == 1
    end
  end

  describe "failures" do
    test "returns an error on a non-200 status" do
      HttpStub.set_responses([{:ok, 400, ~s({"error":"station_id or region_id required"})}])

      assert {:error, {:http_status, 400}} = Triff.quote_types([1319])
    end

    test "returns an error on a malformed body" do
      HttpStub.set_responses([{:ok, 200, ~s({"unexpected":true})}])

      assert {:error, :malformed_response} = Triff.quote_types([1319])
    end

    test "returns an error on undecodable JSON" do
      HttpStub.set_responses([{:ok, 200, "<html>502</html>"}])

      assert {:error, {:invalid_json, _}} = Triff.quote_types([1319])
    end

    test "returns an error on a transport failure" do
      HttpStub.set_responses([{:error, :timeout}])

      assert {:error, :timeout} = Triff.quote_types([1319])
    end

    test "a failure suppresses further requests for the cooldown window" do
      HttpStub.set_responses([{:error, :timeout}])

      assert {:error, :timeout} = Triff.quote_types([1319])
      assert {:error, :recent_failure} = Triff.quote_types([2048])

      # Only the first call reached the network.
      assert length(HttpStub.requests()) == 1
    end

    test "the cooldown does not block a fully cached request" do
      HttpStub.set_responses([
        {:ok, 200, types([sell(1319, 100.0, nil)])},
        {:error, :timeout}
      ])

      assert {:ok, %{1319 => 100.0}} == Triff.quote_types([1319])
      assert {:error, :timeout} = Triff.quote_types([2048])

      # 1319 is cached, so this needs no request and is unaffected by the cooldown.
      assert {:ok, %{1319 => 100.0}} == Triff.quote_types([1319])
    end
  end

  describe "caching" do
    test "a cached price avoids a second request" do
      HttpStub.set_responses([{:ok, 200, types([sell(1319, 100.0, nil)])}])

      assert {:ok, %{1319 => 100.0}} == Triff.quote_types([1319])
      assert {:ok, %{1319 => 100.0}} == Triff.quote_types([1319])
      assert length(HttpStub.requests()) == 1
    end

    test "an unpriced type is remembered so it is not re-requested" do
      HttpStub.set_responses([{:ok, 200, types([sell(44_992, nil, nil)])}])

      assert {:ok, %{}} == Triff.quote_types([44_992])
      assert {:ok, %{}} == Triff.quote_types([44_992])
      assert length(HttpStub.requests()) == 1
    end

    test "a type absent from the response is remembered as unpriced" do
      HttpStub.set_responses([{:ok, 200, types([])}])

      assert {:ok, %{}} == Triff.quote_types([44_992])
      assert {:ok, %{}} == Triff.quote_types([44_992])
      assert length(HttpStub.requests()) == 1
    end

    test "only uncached ids are requested" do
      HttpStub.set_responses([
        {:ok, 200, types([sell(1319, 100.0, nil)])},
        {:ok, 200, types([sell(2048, 200.0, nil)])}
      ])

      assert {:ok, %{1319 => 100.0}} == Triff.quote_types([1319])
      assert {:ok, %{1319 => 100.0, 2048 => 200.0}} == Triff.quote_types([1319, 2048])

      assert [_first, second] = HttpStub.requests()
      assert second =~ "type_ids=2048"
      refute second =~ "1319"
    end
  end
end
