defmodule WandererApp.Zkb.Provider.Parser do
  @moduledoc """
  Parses and stores killmails from zKB (partial) or ESI (full).
  Combines partial & full data, validates time, enriches, and caches results.
  """

  require Logger

  alias WandererApp.Esi.ApiClient
  alias WandererApp.Zkb.Provider.Parser.{Core, TimeHandler, Enricher, CacheHandler}

  @type killmail :: map()
  @type result :: :ok | :older | :skip

  # Cutoff duration in seconds (1 hour)
  @cutoff_seconds 3_600

  @doc """
  Entry-point for handling *any* killmail payload (RedisQ, zKill API, etc).
  """
  @spec parse_and_store_killmail(killmail()) :: {:ok, killmail()} | :older | :skip
  def parse_and_store_killmail(km) when is_map(km) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@cutoff_seconds, :second)
    do_parse(km, cutoff)
  end
  def parse_and_store_killmail(_), do: :skip

  @doc """
  Used when you already have a full killmail and its partial zKB envelope.
  """
  @spec parse_full_and_store(killmail(), killmail(), DateTime.t()) ::
          {:ok, killmail()} | :older | :skip
  def parse_full_and_store(full, %{"zkb" => zkb}, cutoff) when is_map(full) do
    full
    |> Map.put("zkb", zkb)
    |> do_parse(cutoff)
  end
  def parse_full_and_store(_, _, _), do: :skip

  @doc """
  Fetches the full killmail via ESI and then runs it through the same pipeline.
  """
  @spec parse_partial(killmail(), DateTime.t()) :: {:ok, killmail()} | :older | :skip | {:error, term()}
  def parse_partial(%{"killmail_id" => id, "zkb" => %{"hash" => hash}} = partial, cutoff) do
    case ApiClient.get_killmail(id, hash) do
      {:ok, full} ->
        full_with_zkb = Map.put(full, "zkb", partial["zkb"])
        do_parse(full_with_zkb, cutoff)

      {:error, reason} ->
        Logger.error("[ZkbParser] parse_partial fetch failed for #{id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  def parse_partial(_, _), do: {:error, :invalid_killmail}

  @doc """
  If you have a full killmail and just want to run validation → storage,
  you can call this directly.
  """
  @spec parse_full(killmail(), DateTime.t()) :: {:ok, killmail()} | {:older, term()} | :skip
  def parse_full(km, cutoff) do
    do_parse(km, cutoff)
  end

  # ------------------------------------------------------------
  # Internal parsing pipeline: validate time → build → enrich → cache
  # ------------------------------------------------------------
  @spec do_parse(killmail(), DateTime.t()) :: {:ok, killmail()} | :older | :skip
  defp do_parse(%{"killmail_id" => id} = km, cutoff) do
    with {:ok, time_dt} <- TimeHandler.get_killmail_time(km),
         :ok             <- ensure_not_older(time_dt, cutoff),
         km_with_time    = Map.put(km, "kill_time", time_dt),
         {:ok, built}    <- Core.build_kill_data(km_with_time, time_dt),
         {:ok, enriched} <- Enricher.enrich_killmail(built),
         {:ok, stored}   <- CacheHandler.store_killmail(enriched) do

      case CacheHandler.update_kill_count(stored) do
        :ok    -> {:ok, stored}
        :skip  -> {:ok, stored}
        other  ->
          Logger.error("[ZkbParser] update_kill_count #{inspect(other)} for #{id}")
          {:ok, stored}
      end
    else
      :older ->
        :older

      :missing ->
        Logger.error("[ZkbParser] Missing killmail time for #{id}")
        :skip

      {:error, reason} ->
        Logger.error("[ZkbParser] parsing failed for #{id}: #{inspect(reason)}")
        :skip

      other ->
        Logger.error("[ZkbParser] unexpected error for #{id}: #{inspect(other)}")
        :skip
    end
  end

  # Move the DateTime.compare/2 out of a guard
  @spec ensure_not_older(DateTime.t(), DateTime.t()) :: :ok | :older
  defp ensure_not_older(time_dt, cutoff) do
    if DateTime.compare(time_dt, cutoff) == :lt, do: :older, else: :ok
  end
end
