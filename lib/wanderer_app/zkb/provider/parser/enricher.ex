defmodule WandererApp.Zkb.Provider.Parser.Enricher do
  @moduledoc """
  Handles enrichment of killmail data with additional information.
  Manages fetching and adding character, corporation, alliance, and ship information.
  """

  require Logger
  alias WandererApp.Esi.ApiClient
  alias WandererApp.CachedInfo
  alias WandererApp.Utils.HttpUtil

  @type killmail :: map()
  @type enrich_result :: {:ok, killmail()} | {:error, term()}

  @doc """
  Enriches a killmail with additional information.
  Returns:
    - `{:ok, enriched_km}` if enrichment was successful
    - `{:error, reason}` if enrichment failed
  """
  @spec enrich_killmail(killmail() | nil) :: enrich_result()
  def enrich_killmail(nil), do: {:error, :invalid_killmail}
  def enrich_killmail({:error, reason}), do: {:error, reason}
  def enrich_killmail(km) when is_map(km) do
    try do
      enriched_km = km
        |> enrich_victim()
        |> enrich_final_blow()

      {:ok, enriched_km}
    rescue
      e ->
        Logger.error("[Enricher] Failed to enrich killmail #{inspect(km["killmail_id"])}: #{inspect(e)}")
        {:error, :enrichment_failed}
    end
  end
  def enrich_killmail(invalid) do
    Logger.error("[Enricher] Invalid killmail data: #{inspect(invalid)}")
    {:error, :invalid_killmail}
  end

  @spec enrich_victim(killmail()) :: killmail()
  defp enrich_victim(km) do
    km
    |> maybe_put_character_name("victim_char_id", "victim_char_name")
    |> maybe_put_corp_info("victim_corp_id", "victim_corp_ticker", "victim_corp_name")
    |> maybe_put_alliance_info("victim_alliance_id", "victim_alliance_ticker", "victim_alliance_name")
    |> maybe_put_ship_name("victim_ship_type_id", "victim_ship_name")
  end

  @spec enrich_final_blow(killmail()) :: killmail()
  defp enrich_final_blow(km) do
    km
    |> maybe_put_character_name("final_blow_char_id", "final_blow_char_name")
    |> maybe_put_corp_info("final_blow_corp_id", "final_blow_corp_ticker", "final_blow_corp_name")
    |> maybe_put_alliance_info("final_blow_alliance_id", "final_blow_alliance_ticker", "final_blow_alliance_name")
    |> maybe_put_ship_name("final_blow_ship_type_id", "final_blow_ship_name")
  end

  @spec maybe_put_character_name(killmail(), String.t(), String.t()) :: killmail()
  defp maybe_put_character_name(km, id_key, name_key) do
    case Map.get(km, id_key) do
      nil ->
        km
      0 ->
        km
      eve_id ->
        handle_character_info(km, eve_id, name_key)
    end
  end

  @spec handle_character_info(killmail(), integer(), String.t()) :: killmail()
  defp handle_character_info(km, eve_id, name_key) do
    result = fetch_character_info(eve_id)
    handle_character_result(km, result, eve_id, name_key)
  end

  @spec fetch_character_info(integer()) :: {:ok, String.t()} | :skip | {:error, term()}
  defp fetch_character_info(eve_id) do
    HttpUtil.retry_with_backoff(
      fn ->
        case ApiClient.get_character_info(eve_id) do
          {:ok, %{"name" => char_name}} ->
            {:ok, char_name}
          {:error, :timeout} ->
            Logger.warning("[Enricher] Timeout fetching character info for ID #{eve_id}")
            raise "Character info timeout, will retry"
          {:error, :not_found} ->
            Logger.warning("[Enricher] Character not found for ID #{eve_id}")
            :skip
          {:error, reason} ->
            Logger.error("[Enricher] Error fetching character info for ID #{eve_id}: #{inspect(reason)}")
            handle_character_error(reason)
        end
      end,
      max_retries: 3
    )
  end

  @spec handle_character_error(term()) :: :skip | no_return()
  defp handle_character_error(reason) do
    if HttpUtil.retriable_error?(reason) do
      raise "Character info error: #{inspect(reason)}, will retry"
    else
      :skip
    end
  end

  @spec handle_character_result(killmail(), {:ok, String.t()} | :skip | {:error, term()}, integer(), String.t()) :: killmail()
  defp handle_character_result(km, {:ok, char_name}, _eve_id, name_key) do
    Map.put(km, name_key, char_name)
  end
  defp handle_character_result(km, :skip, _eve_id, _name_key) do
    km
  end
  defp handle_character_result(km, {:error, _reason}, _eve_id, _name_key) do
    km
  end

  @spec maybe_put_corp_info(killmail(), String.t(), String.t(), String.t()) :: killmail()
  defp maybe_put_corp_info(km, id_key, ticker_key, name_key) do
    case Map.get(km, id_key) do
      nil ->
        km
      0 ->
        km
      corp_id ->
        handle_corp_info(km, corp_id, ticker_key, name_key)
    end
  end

  @spec handle_corp_info(killmail(), integer(), String.t(), String.t()) :: killmail()
  defp handle_corp_info(km, corp_id, ticker_key, name_key) do
    result = fetch_corp_info(corp_id)
    handle_corp_result(km, result, corp_id, ticker_key, name_key)
  end

  @spec fetch_corp_info(integer()) :: {:ok, {String.t(), String.t()}} | :skip | {:error, term()}
  defp fetch_corp_info(corp_id) do
    HttpUtil.retry_with_backoff(
      fn ->
        case ApiClient.get_corporation_info(corp_id) do
          {:ok, %{"ticker" => ticker, "name" => corp_name}} ->
            {:ok, {ticker, corp_name}}
          {:error, :timeout} ->
            Logger.warning("[Enricher] Timeout fetching corporation info for ID #{corp_id}")
            raise "Corporation info timeout, will retry"
          {:error, :not_found} ->
            Logger.warning("[Enricher] Corporation not found for ID #{corp_id}")
            :skip
          {:error, reason} ->
            Logger.error("[Enricher] Error fetching corporation info for ID #{corp_id}: #{inspect(reason)}")
            handle_corp_error(reason, corp_id)
        end
      end,
      max_retries: 3
    )
  end

  @spec handle_corp_error(term(), integer()) :: :skip | no_return()
  defp handle_corp_error(reason, _corp_id) do
    if HttpUtil.retriable_error?(reason) do
      raise "Corporation info error: #{inspect(reason)}, will retry"
    else
      :skip
    end
  end

  @spec handle_corp_result(killmail(), {:ok, {String.t(), String.t()}} | :skip | {:error, term()}, integer(), String.t(), String.t()) :: killmail()
  defp handle_corp_result(km, {:ok, {ticker, corp_name}}, _corp_id, ticker_key, name_key) do
    km
    |> Map.put(ticker_key, ticker)
    |> Map.put(name_key, corp_name)
  end
  defp handle_corp_result(km, :skip, _corp_id, _ticker_key, _name_key) do
    km
  end
  defp handle_corp_result(km, {:error, _reason}, _corp_id, _ticker_key, _name_key) do
    km
  end

  @spec maybe_put_alliance_info(killmail(), String.t(), String.t(), String.t()) :: killmail()
  defp maybe_put_alliance_info(km, id_key, ticker_key, name_key) do
    case Map.get(km, id_key) do
      nil ->
        km
      0 ->
        km
      alliance_id ->
        handle_alliance_info(km, alliance_id, ticker_key, name_key)
    end
  end

  @spec handle_alliance_info(killmail(), integer(), String.t(), String.t()) :: killmail()
  defp handle_alliance_info(km, alliance_id, ticker_key, name_key) do
    result = fetch_alliance_info(alliance_id)
    handle_alliance_result(km, result, alliance_id, ticker_key, name_key)
  end

  @spec fetch_alliance_info(integer()) :: {:ok, {String.t(), String.t()}} | :skip | {:error, term()}
  defp fetch_alliance_info(alliance_id) do
    HttpUtil.retry_with_backoff(
      fn ->
        case ApiClient.get_alliance_info(alliance_id) do
          {:ok, %{"ticker" => alliance_ticker, "name" => alliance_name}} ->
            {:ok, {alliance_ticker, alliance_name}}
          {:error, :timeout} ->
            Logger.warning("[Enricher] Timeout fetching alliance info for ID #{alliance_id}")
            raise "Alliance info timeout, will retry"
          {:error, :not_found} ->
            Logger.warning("[Enricher] Alliance not found for ID #{alliance_id}")
            :skip
          {:error, reason} ->
            Logger.error("[Enricher] Error fetching alliance info for ID #{alliance_id}: #{inspect(reason)}")
            handle_alliance_error(reason)
        end
      end,
      max_retries: 3
    )
  end

  @spec handle_alliance_error(term()) :: :skip | no_return()
  defp handle_alliance_error(reason) do
    if HttpUtil.retriable_error?(reason) do
      raise "Alliance info error: #{inspect(reason)}, will retry"
    else
      :skip
    end
  end

  @spec handle_alliance_result(killmail(), {:ok, {String.t(), String.t()}} | :skip | {:error, term()}, integer(), String.t(), String.t()) :: killmail()
  defp handle_alliance_result(km, {:ok, {alliance_ticker, alliance_name}}, _alliance_id, ticker_key, name_key) do
    km
    |> Map.put(ticker_key, alliance_ticker)
    |> Map.put(name_key, alliance_name)
  end
  defp handle_alliance_result(km, :skip, _alliance_id, _ticker_key, _name_key) do
    km
  end
  defp handle_alliance_result(km, {:error, _reason}, _alliance_id, _ticker_key, _name_key) do
    km
  end

  @spec maybe_put_ship_name(killmail(), String.t(), String.t()) :: killmail()
  defp maybe_put_ship_name(km, id_key, name_key) do
    case Map.get(km, id_key) do
      nil ->
        km
      0 ->
        km
      type_id ->
        case CachedInfo.get_ship_type(type_id) do
          {:ok, nil} ->
            Logger.warning("[Enricher] Ship type not found for ID #{type_id}")
            km
          {:ok, %{name: ship_name}} ->
            Map.put(km, name_key, ship_name)
          {:error, :not_found} ->
            Logger.warning("[Enricher] Ship type not found for ID #{type_id}")
            km
          {:error, reason} ->
            Logger.error("[Enricher] Error fetching ship info for type ID #{type_id}: #{inspect(reason)}")
            km
        end
    end
  end
end
