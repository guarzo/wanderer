defmodule WandererApp.ExternalEvents.Discord.CorpTickersTest do
  # `async: false`: the ESI seam is application env and the lookups run in
  # `Task.async_stream` children, so Mox has to be in global mode.
  use ExUnit.Case, async: false

  import Mox

  alias WandererApp.ExternalEvents.Discord.CorpTickers

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # Restored, not deleted, on exit: `config/test.exs` points this seam at
    # `Esi.OfflineStub`, and deleting it would leave later tests pointed at real
    # ESI.
    original_esi = Application.get_env(:wanderer_app, :esi_client)
    Application.put_env(:wanderer_app, :esi_client, WandererApp.Esi.Mock)
    on_exit(fn -> Application.put_env(:wanderer_app, :esi_client, original_esi) end)
    :ok
  end

  # Scripts `%{corp_id => ticker | :error}` keyed by the id as the module will
  # pass it, i.e. stringified.
  defp stub_corps(corps) do
    stub(WandererApp.Esi.Mock, :get_corporation_info, fn corp_id ->
      case Map.fetch(corps, to_string(corp_id)) do
        {:ok, :error} -> {:error, :not_found}
        {:ok, ticker} -> {:ok, %{"name" => "Corp #{corp_id}", "ticker" => ticker}}
        :error -> {:error, :not_found}
      end
    end)
  end

  defp kill(fields), do: Map.merge(%{"killmail_id" => 1}, fields)

  defp corp_tickers_timeout(ms) do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, :corp_tickers_timeout_ms, ms)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)
  end

  describe "missing_corp_ids/1" do
    test "returns the ids of both rendered fields when the tickers are absent" do
      kills = [kill(%{"victim_corp_id" => 98_721_938, "final_blow_corp_id" => 98_832_599})]

      assert CorpTickers.missing_corp_ids(kills) == ["98721938", "98832599"]
    end

    test "skips fields whose ticker the payload already carried" do
      kills = [
        kill(%{
          "victim_corp_id" => 98_721_938,
          "victim_corp_ticker" => ".STEX",
          "final_blow_corp_id" => 98_832_599
        })
      ]

      assert CorpTickers.missing_corp_ids(kills) == ["98832599"]
    end

    test "treats a blank ticker as missing" do
      kills = [kill(%{"victim_corp_id" => 1, "victim_corp_ticker" => "   "})]

      assert CorpTickers.missing_corp_ids(kills) == ["1"]
    end

    test "ignores fields with no corporation id — there is nothing to look up" do
      assert CorpTickers.missing_corp_ids([kill(%{"victim_char_name" => "Pilot"})]) == []
    end

    test "deduplicates a corporation appearing on several kills and in both roles" do
      kills = [
        kill(%{"victim_corp_id" => 42, "final_blow_corp_id" => 42}),
        kill(%{"victim_corp_id" => "42"})
      ]

      assert CorpTickers.missing_corp_ids(kills) == ["42"]
    end

    test "does not resolve top damage — the embed never renders its corporation" do
      assert CorpTickers.missing_corp_ids([kill(%{"top_damage_corp_id" => 42})]) == []
    end
  end

  describe "enrich/1" do
    test "returns a ticker per resolvable corporation" do
      stub_corps(%{"1" => "AAA", "2" => "BBB"})

      kills = [kill(%{"victim_corp_id" => 1, "final_blow_corp_id" => 2})]

      assert CorpTickers.enrich(kills) == %{"1" => "AAA", "2" => "BBB"}
    end

    test "makes no ESI call when nothing is missing" do
      # No stub at all: an unexpected call fails the test rather than reaching
      # the network.
      kills = [kill(%{"victim_corp_id" => 1, "victim_corp_ticker" => "AAA"})]

      assert CorpTickers.enrich(kills) == %{}
    end

    test "returns an empty map for an empty batch" do
      assert CorpTickers.enrich([]) == %{}
    end

    test "looks a shared corporation up once" do
      test_pid = self()

      stub(WandererApp.Esi.Mock, :get_corporation_info, fn corp_id ->
        send(test_pid, {:esi_called, corp_id})
        {:ok, %{"ticker" => "AAA"}}
      end)

      kills = [
        kill(%{"killmail_id" => 1, "victim_corp_id" => 42}),
        kill(%{"killmail_id" => 2, "victim_corp_id" => 42, "final_blow_corp_id" => 42})
      ]

      assert CorpTickers.enrich(kills) == %{"42" => "AAA"}
      assert_received {:esi_called, "42"}
      refute_received {:esi_called, _}
    end

    test "omits a corporation ESI will not resolve, keeping the rest" do
      stub_corps(%{"1" => "AAA", "2" => :error})

      kills = [kill(%{"victim_corp_id" => 1, "final_blow_corp_id" => 2})]

      assert CorpTickers.enrich(kills) == %{"1" => "AAA"}
    end

    test "omits a corporation whose record carries no usable ticker" do
      stub(WandererApp.Esi.Mock, :get_corporation_info, fn _corp_id ->
        {:ok, %{"name" => "Ticker-less Corp"}}
      end)

      assert CorpTickers.enrich([kill(%{"victim_corp_id" => 1})]) == %{}
    end

    test "keeps the corporations that resolved when one lookup outlives its slice" do
      # The per-element timeout is half the enrichment budget precisely so this
      # can happen: the slow corporation is dropped and the stream still returns
      # the fast one, rather than the dispatcher killing the whole task.
      corp_tickers_timeout(200)

      stub(WandererApp.Esi.Mock, :get_corporation_info, fn corp_id ->
        if to_string(corp_id) == "2", do: Process.sleep(180)
        {:ok, %{"ticker" => "AAA"}}
      end)

      kills = [kill(%{"victim_corp_id" => 1, "final_blow_corp_id" => 2})]

      assert CorpTickers.enrich(kills) == %{"1" => "AAA"}
    end

    test "survives a raising lookup — one bad corporation must not cost the batch" do
      stub(WandererApp.Esi.Mock, :get_corporation_info, fn corp_id ->
        if to_string(corp_id) == "2", do: raise("esi boom")
        {:ok, %{"ticker" => "AAA"}}
      end)

      kills = [kill(%{"victim_corp_id" => 1, "final_blow_corp_id" => 2})]

      assert CorpTickers.enrich(kills) == %{"1" => "AAA"}
    end
  end

  describe "apply_tickers/2" do
    test "fills both rendered fields" do
      kill = kill(%{"victim_corp_id" => 1, "final_blow_corp_id" => 2})

      assert %{"victim_corp_ticker" => "AAA", "final_blow_corp_ticker" => "BBB"} =
               CorpTickers.apply_tickers(kill, %{"1" => "AAA", "2" => "BBB"})
    end

    test "never overwrites a ticker the payload carried" do
      kill = kill(%{"victim_corp_id" => 1, "victim_corp_ticker" => "PAYLOAD"})

      assert %{"victim_corp_ticker" => "PAYLOAD"} =
               CorpTickers.apply_tickers(kill, %{"1" => "ESI"})
    end

    test "matches a string id against the same corporation as an integer one" do
      kill = kill(%{"victim_corp_id" => "1"})

      assert %{"victim_corp_ticker" => "AAA"} = CorpTickers.apply_tickers(kill, %{"1" => "AAA"})
    end

    test "leaves the kill untouched when the corporation did not resolve" do
      kill = kill(%{"victim_corp_id" => 1})

      assert CorpTickers.apply_tickers(kill, %{"2" => "BBB"}) == kill
      assert CorpTickers.apply_tickers(kill, %{}) == kill
    end
  end
end
