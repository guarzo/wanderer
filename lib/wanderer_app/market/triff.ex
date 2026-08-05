defmodule WandererApp.Market.Triff do
  @moduledoc """
  Bulk item pricing via [triff.tools](https://triff.tools).

  Used by the Discord notable-items enricher to decide which dropped loot is
  worth naming. triff needs no API token, which is why this feature is not
  disabled-by-default the way wanderer-notifier's Janice-backed equivalent is.

  ## Scope and mode

  Prices are quoted against **Jita 4-4** (`station_id=60003760`), fixed. It is
  the tightest market in EVE and what players mentally price loot against. The
  `station_id` (or `region_id`) parameter is **mandatory** — without it the API
  answers `400 {"error":"station_id or region_id required"}`.

  The selected price is the 5th-percentile sell order, falling back to the best
  sell order when `p05` is null. Thin markets have too few orders to support a
  percentile; a null `best` has nothing to fall back to, so that type is omitted
  from the result map rather than coerced to zero.

  ## Caching

  Three distinct entries in `:api_cache`, all short-lived because prices move:

  * a resolved price per type id (30 min);
  * a `:no_quote` sentinel per type id (10 min) for types with no usable order
    on either side. Without an explicit sentinel these would be re-requested on
    every kill that drops them, forever — precisely the permanently-unpriced
    long tail;
  * one whole-request failure marker (60 s), so a hard-down triff costs one
    round trip per minute rather than one per batch.
  """

  require Logger

  alias WandererApp.Market.Triff.HttpClient

  @quote_url "https://triff.tools/api/market/quote"
  @jita_4_4_station_id 60_003_760

  # Matches authGD's QUOTE_CHUNK. Larger chunks risk a URL length rejection.
  @chunk_size 900

  @price_ttl :timer.minutes(30)
  @no_quote_ttl :timer.minutes(10)
  @failure_ttl :timer.seconds(60)

  # The priciest item in EVE is on the order of 1e12 ISK, so anything past this
  # is a malformed response, not a real quote. Mirrors authGD's sideSchema.
  @max_price 1.0e15

  @failure_key "triff-request-failure"

  @type prices :: %{integer() => float()}

  @doc """
  Quotes the given type ids.

  Returns `{:ok, prices}` where `prices` maps type id to unit price in ISK.
  Types with no usable quote are **absent from the map** — callers must not
  treat a missing key as zero.

  Returns `{:error, reason}` if the very first request in the batch fails, or if
  a recent request already failed and the cooldown is still active. A batch that
  spans several chunks and fails partway returns `{:ok, partial}` with whatever
  was priced before the failure — an under-reported section beats no section,
  and unpriced types are already an expected outcome.
  """
  @spec quote_types([integer()]) :: {:ok, prices()} | {:error, term()}
  def quote_types(type_ids) do
    ids = type_ids |> Enum.filter(&is_integer/1) |> Enum.uniq()
    {cached, missing} = split_cached(ids)

    cond do
      missing == [] ->
        {:ok, cached}

      recently_failed?() ->
        {:error, :recent_failure}

      true ->
        fetch_missing(missing, cached)
    end
  end

  # Halts on the first failing chunk — a failure usually means triff is down, so
  # issuing the remaining chunks would just add round trips to a dead endpoint.
  # But the chunks that already answered are kept and returned: their prices are
  # real, and discarding them would cost the whole batch its section over a
  # partial outage. The failure is still marked, so the cooldown engages either
  # way.
  defp fetch_missing(missing, cached) do
    missing
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce_while({cached, 0, nil}, fn chunk, {acc, ok_count, _reason} ->
      case fetch_chunk(chunk) do
        {:ok, priced} -> {:cont, {Map.merge(acc, priced), ok_count + 1, nil}}
        {:error, reason} -> {:halt, {acc, ok_count, reason}}
      end
    end)
    |> case do
      {prices, _ok_count, nil} ->
        {:ok, prices}

      {_prices, 0, reason} ->
        mark_failure(reason)
        {:error, reason}

      {prices, ok_count, reason} ->
        mark_failure(reason)

        Logger.warning(
          "[Triff] returning #{map_size(prices)} prices from #{ok_count} " <>
            "chunk(s) after a later chunk failed"
        )

        {:ok, prices}
    end
  end

  defp fetch_chunk(ids) do
    with {:ok, 200, body} <- HttpClient.get(url(ids), [{"accept", "application/json"}]),
         {:ok, priced} <- parse(body) do
      cache_results(ids, priced)
      {:ok, Map.take(priced, ids)}
    else
      {:ok, status, _body} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp url(ids) do
    query =
      URI.encode_query(
        type_ids: Enum.join(ids, ","),
        include_aggregates: "true",
        include_orders: "false",
        station_id: @jita_4_4_station_id
      )

    @quote_url <> "?" <> query
  end

  defp parse(body) do
    case Jason.decode(body) do
      {:ok, %{"types" => types}} when is_list(types) ->
        {:ok, Enum.reduce(types, %{}, &collect_price/2)}

      {:ok, _other} ->
        {:error, :malformed_response}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  defp collect_price(%{"type_id" => id} = type, acc) when is_integer(id) do
    case select_price(Map.get(type, "sell")) do
      nil -> acc
      price -> Map.put(acc, id, price)
    end
  end

  defp collect_price(_type, acc), do: acc

  # p05 first, best as the fallback. An invalid p05 is treated like a null one:
  # either way we have no usable percentile and the best order is the next-best
  # answer.
  defp select_price(%{} = sell) do
    valid_price(Map.get(sell, "p05")) || valid_price(Map.get(sell, "best"))
  end

  defp select_price(_), do: nil

  # `Jason` cannot produce NaN or Infinity — they are not valid JSON — so the
  # range check is the whole non-finite guard.
  defp valid_price(n) when is_number(n) and n > 0 and n <= @max_price, do: n * 1.0
  defp valid_price(_), do: nil

  defp split_cached(ids) do
    {found, missing} =
      Enum.reduce(ids, {%{}, []}, fn id, {found, missing} ->
        case Cachex.get(:api_cache, cache_key(id)) do
          {:ok, price} when is_float(price) -> {Map.put(found, id, price), missing}
          # A known-unpriced type: neither a hit to return nor a miss to re-request.
          {:ok, :no_quote} -> {found, missing}
          _ -> {found, [id | missing]}
        end
      end)

    {found, Enum.reverse(missing)}
  end

  # Every requested id gets an entry, including ids the response omitted
  # entirely — otherwise the unpriced long tail is re-requested forever.
  defp cache_results(requested_ids, priced) do
    Enum.each(requested_ids, fn id ->
      case Map.get(priced, id) do
        nil -> Cachex.put(:api_cache, cache_key(id), :no_quote, ttl: @no_quote_ttl)
        price -> Cachex.put(:api_cache, cache_key(id), price, ttl: @price_ttl)
      end
    end)
  end

  defp cache_key(id), do: "triff-price-#{id}"

  defp recently_failed? do
    match?({:ok, true}, Cachex.get(:api_cache, @failure_key))
  end

  defp mark_failure(reason) do
    Logger.warning(
      "[Triff] quote request failed (#{inspect(reason)}); " <>
        "suppressing requests for #{div(@failure_ttl, 1000)}s"
    )

    Cachex.put(:api_cache, @failure_key, true, ttl: @failure_ttl)
  end
end
