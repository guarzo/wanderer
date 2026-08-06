defmodule WandererApp.ExternalEvents.Discord.CorpTickers do
  @moduledoc """
  Resolves the corporation tickers a kill embed renders, for kills whose
  websocket payload arrived without them.

  ## Why this is needed

  `EmbedFormatter` renders `(TICKER)` after the victim and the final blow, and
  drops the whole parenthetical when the ticker is nil
  (`embed_formatter.ex:364`). `MessageHandler.get_corp_ticker/1` reads the
  ticker straight out of the wanderer-kills payload and never falls back, so a
  payload that omits it produces a notification with no corporation at all —
  the reported symptom. Every wanderer-kills serializer rejects nil fields
  before encoding, which makes "upstream had not enriched this kill yet"
  indistinguishable from "this corporation has no ticker".

  The corporation **ids** do not have that problem: they come off the raw ESI
  killmail, so `victim_corp_id` / `final_blow_corp_id` are present even when the
  tickers are not. This module turns those ids into tickers.

  wanderer-notifier never hit this because it never trusted the payload — it
  resolved the ticker from `corporation_id` through cache→ESI on every kill
  (`killmail_formatter.ex:389-418`).

  ## Scope

  Discord path only, and only for the two fields the embed actually renders.
  `top_damage_corp_ticker` is carried in the payload but never rendered, so it
  is not resolved. Enriching in `MessageHandler` instead would also fix the
  kills widget, but would put an ESI lookup on every kill in every subscribed
  system rather than on the handful that become notifications.

  Lookups go through `WandererApp.Esi.get_corporation_info/1`, which is
  Nebulex-cached with a 1h TTL (`esi/api_client.ex:151`), so a busy chain
  resolves each corporation once an hour, not once a kill.

  ## Fail-open

  A corporation that will not resolve is simply left absent, and the embed
  renders as it does today — pilot name with no parenthetical. A missing ticker
  is an acceptable outcome; a missing kill notification is not. Rendering
  wanderer-notifier's literal `"????"` placeholder was considered and rejected:
  omitting reads as "no corp shown", `"????"` reads as "corp is called ????".
  """

  require Logger

  # The pairs the embed renders. Order is irrelevant; membership is not — adding
  # a field here without a matching `corporation_link/2` call in the formatter
  # buys ESI calls for something nobody sees.
  @fields [
    {"victim_corp_id", "victim_corp_ticker"},
    {"final_blow_corp_id", "final_blow_corp_ticker"}
  ]

  # Matches `NotableItems`: bounded so one batch cannot flood the ESI pool on
  # the dispatcher's behalf. Cache hits do not consume a slot for long.
  @esi_concurrency 8

  @typedoc "Corporation id, normalized to a string — payload ids are not consistently typed."
  @type corp_id :: String.t()

  @doc """
  Returns `%{corp_id => ticker}` for the corporations these kills need and did
  not carry.

  Corporations that fail to resolve are **absent from the map**. Keys are
  stringified ids; use `apply_tickers/2` rather than reading the map directly.
  """
  @callback enrich([map()]) :: %{optional(corp_id()) => String.t()}

  @doc "Returns the configured enricher, so the dispatcher can inject a stub."
  def impl, do: Application.get_env(:wanderer_app, :corp_tickers_enricher, __MODULE__)

  @spec enrich([map()]) :: %{optional(corp_id()) => String.t()}
  def enrich([]), do: %{}

  def enrich(kills) do
    case missing_corp_ids(kills) do
      [] ->
        %{}

      corp_ids ->
        corp_ids
        |> Task.async_stream(&resolve/1,
          max_concurrency: @esi_concurrency,
          timeout: element_timeout_ms(),
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.reduce(%{}, fn
          {:ok, {corp_id, ticker}}, acc -> Map.put(acc, corp_id, ticker)
          _result, acc -> acc
        end)
    end
  end

  @doc """
  Fills in whichever of the rendered ticker fields this kill is missing.

  Never overwrites a ticker the payload already carried: upstream saw the
  killmail, we only saw the corporation.
  """
  @spec apply_tickers(map(), %{optional(corp_id()) => String.t()}) :: map()
  def apply_tickers(kill, tickers) when map_size(tickers) == 0, do: kill

  def apply_tickers(kill, tickers) do
    Enum.reduce(@fields, kill, fn {id_key, ticker_key}, acc ->
      with nil <- present(acc[ticker_key]),
           id when not is_nil(id) <- normalize(acc[id_key]),
           ticker when is_binary(ticker) <- Map.get(tickers, id) do
        Map.put(acc, ticker_key, ticker)
      else
        _ -> acc
      end
    end)
  end

  @doc "The corporation ids these kills need looked up. Public for the dispatcher's telemetry."
  @spec missing_corp_ids([map()]) :: [corp_id()]
  def missing_corp_ids(kills) do
    kills
    |> Enum.flat_map(fn kill ->
      Enum.flat_map(@fields, fn {id_key, ticker_key} ->
        case {present(kill[ticker_key]), normalize(kill[id_key])} do
          {nil, id} when not is_nil(id) -> [id]
          _ -> []
        end
      end)
    end)
    |> Enum.uniq()
  end

  defp resolve(corp_id) do
    case safe(corp_id, fn -> esi_client().get_corporation_info(corp_id) end) do
      {:ok, %{"ticker" => ticker}} when is_binary(ticker) ->
        case present(ticker) do
          nil -> :unresolved
          ticker -> {corp_id, ticker}
        end

      _ ->
        :unresolved
    end
  end

  # Strictly smaller than the budget the dispatcher gives the whole enrichment,
  # and that gap is the point. Both deadlines start at roughly the same moment,
  # so a per-element timeout equal to the whole budget means the dispatcher
  # shuts this task down before `on_timeout: :kill_task` can drop the slow
  # corporation — the corporations that already resolved die with it. Half the
  # budget leaves room for the stream to finish and hand back what it got.
  defp element_timeout_ms do
    WandererApp.Env.corp_tickers_timeout_ms()
    |> div(2)
    |> max(1)
  end

  defp normalize(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize(id) when is_binary(id), do: present(id)
  defp normalize(_id), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp esi_client, do: Application.get_env(:wanderer_app, :esi_client, WandererApp.Esi)

  # An exception in an `async_stream` child brings down the whole stream, which
  # would discard the corporations that had already resolved.
  #
  # The corporation id is carried into the message because the concurrency means
  # a systemic failure produces several identical lines at once, with nothing
  # else to tell them apart by.
  defp safe(corp_id, fun) do
    fun.()
  rescue
    error ->
      Logger.warning("[CorpTickers] corporation #{corp_id}: #{Exception.message(error)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("[CorpTickers] corporation #{corp_id} exited: #{inspect(reason)}")
      :error
  end
end
