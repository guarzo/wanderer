defmodule WandererApp.Zkb.KillsProvider.Parser do
  @moduledoc """
  Helper for parsing & storing a killmail from the ESI data (plus zKB partial).
  Responsible for:
    - Parsing the raw JSON structures,
    - Combining partial & full kill data,
    - Checking whether kills are 'too old',
    - Storing in KillsCache, etc.
  """

  require Logger
  alias WandererApp.Zkb.KillsProvider.KillsCache
  alias WandererApp.Esi.ApiClient
  alias WandererApp.Utils.HttpUtil
  use Retry

  @type killmail :: map()
  @type partial_killmail :: map()
  @type cutoff_dt :: DateTime.t()
  @type result :: :ok | :older | :skip

  @doc """
  Merges the 'partial' from zKB and the 'full' killmail from ESI, checks its time
  vs. `cutoff_dt`.

  Returns:
    - `:ok` if we parsed & stored successfully,
    - `:older` if killmail time is older than `cutoff_dt`,
    - `:skip` if we cannot parse or store for some reason.
  """
  @spec parse_full_and_store(killmail(), partial_killmail(), cutoff_dt()) :: result()
  def parse_full_and_store(full_km, partial_zkb, cutoff_dt) when is_map(full_km) do
    case check_killmail_time(full_km, cutoff_dt) do
      :older -> :older
      :skip -> :skip
      {km, kill_time_dt} ->
        km
        |> merge_zkb_data(partial_zkb)
        |> build_kill_data(kill_time_dt)
        |> maybe_enrich()
        |> put_into_cache()
        |> inc_counter_if_recent()
    end
  end

  def parse_full_and_store(_full_km, _partial_zkb, _cutoff_dt),
    do: :skip

  @doc """
  Parse a raw killmail (`full_km`) and store it if valid.
  Returns:
    - `:ok` if successfully parsed & stored,
    - `:skip` otherwise
  """
  @spec parse_and_store_killmail(killmail()) :: result()
  def parse_and_store_killmail(km) do
    cutoff_dt = DateTime.utc_now() |> DateTime.add(-3600, :second)
    # First check if we have the required fields for ESI fetch
    case {km["killmail_id"], get_in(km, ["zkb", "hash"])} do
      {kill_id, hash} when is_integer(kill_id) and is_binary(hash) ->
        # We have the required fields, try ESI fetch
        case ApiClient.get_killmail(kill_id, hash) do
          {:ok, full_km} ->
            # Merge the zkb data from the partial killmail into the full one
            full_km = Map.put(full_km, "zkb", km["zkb"])
            case process_killmail(full_km, cutoff_dt) do
              :ok -> :ok
              :skip -> :skip
              :older -> :older
              _ -> :skip
            end
          {:error, reason} ->
            Logger.warning(fn -> "[Parser] Failed to fetch full killmail for #{kill_id}: #{inspect(reason)}" end)
            :skip
        end
      _ ->
        # No required fields, check if we have a time field
        case get_in(km, ["killmail_time"]) do
          nil ->
            :skip
          _time ->
            case process_killmail(km, cutoff_dt) do
              :ok -> :ok
              :skip -> :skip
              :older -> :older
              _ -> :skip
            end
        end
    end
  end

  # Helper function to process a killmail once we have it
  defp process_killmail(km, cutoff_dt) do
    case check_killmail_time(km, cutoff_dt) do
      :older ->
        :older
      :skip ->
        :skip
      {km, kill_time_dt} ->
        case build_kill_data(km, kill_time_dt) do
          nil ->
            :skip
          built_km ->
            built_km
            |> maybe_enrich()
            |> put_into_cache()
            |> inc_counter_if_recent()
        end
    end
  end

  # Pipeline Functions

  @spec merge_zkb_data(killmail(), partial_killmail()) :: killmail()
  defp merge_zkb_data(full_km, partial_zkb) do
    Map.merge(full_km, %{"zkb" => partial_zkb["zkb"]})
  end

  @spec check_killmail_time(killmail(), cutoff_dt()) :: {killmail(), DateTime.t()} | :older | :skip
  defp check_killmail_time(km, cutoff_dt) do
    case parse_killmail_time(km) do
      {:ok, km_dt} ->
        if older_than_cutoff?(km_dt, cutoff_dt) do
          :older
        else
          {km, km_dt}
        end

      _ ->
        :skip
    end
  end

  @spec build_kill_data(killmail(), DateTime.t()) :: killmail() | nil
  defp build_kill_data(%{"killmail_id" => kill_id} = km, kill_time_dt) do
    victim = Map.get(km, "victim", %{})
    attackers = Map.get(km, "attackers", [])
    npc_flag = get_in(km, ["zkb", "npc"]) || false

    if npc_flag do
      nil
    else
      final_blow = Enum.find(attackers, & &1["final_blow"])

      # Build base killmail
      base_km = %{
        "killmail_id" => kill_id,
        "kill_time" => kill_time_dt,
        "solar_system_id" => km["solar_system_id"],
        "zkb" => Map.get(km, "zkb", %{}),
        "attacker_count" => length(attackers),
        "total_value" => get_in(km, ["zkb", "totalValue"]) || 0,
        "victim" => victim,
        "attackers" => attackers,
        "npc" => npc_flag,
        # Add victim IDs at root level
        "victim_char_id" => victim["character_id"],
        "victim_corp_id" => victim["corporation_id"],
        "victim_alliance_id" => victim["alliance_id"],
        "victim_ship_type_id" => victim["ship_type_id"]
      }

      # Add final blow data at root level if it exists
      if final_blow do
        base_km
        |> Map.put("final_blow", final_blow)
        |> Map.put("final_blow_char_id", final_blow["character_id"])
        |> Map.put("final_blow_corp_id", final_blow["corporation_id"])
        |> Map.put("final_blow_alliance_id", final_blow["alliance_id"])
        |> Map.put("final_blow_ship_type_id", final_blow["ship_type_id"])
      else
        base_km
      end
    end
  end

  defp build_kill_data(_, _), do: nil

  @spec maybe_enrich(killmail() | nil) :: killmail() | nil
  defp maybe_enrich(nil), do: nil
  defp maybe_enrich(km) do
    km
    |> enrich_victim()
    |> enrich_final_blow()
  end

  @spec put_into_cache(killmail() | nil) :: killmail() | :skip
  defp put_into_cache(nil), do: :skip
  defp put_into_cache(km) do
    KillsCache.put_killmail(km["killmail_id"], km)
    KillsCache.add_killmail_id_to_system_list(km["solar_system_id"], km["killmail_id"])
    km
  end

  @spec inc_counter_if_recent(killmail() | :skip) :: :ok | :skip
  defp inc_counter_if_recent(:skip), do: :skip
  defp inc_counter_if_recent(km) do
    if recent_kill?(km) do
      KillsCache.incr_system_kill_count(km["solar_system_id"])
      :ok
    else
      :skip
    end
  end

  # Helper Functions

  @spec parse_killmail_time(killmail()) :: {:ok, DateTime.t()} | {:error, term()}
  defp parse_killmail_time(%{"killmail_time" => time_str}) when is_binary(time_str) do
    # zKillboard returns time in format "2024-02-14T19:04:39Z"
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _offset} ->
        # Convert to UTC if not already
        {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      error ->
        Logger.warning(fn -> "[Parser] Failed to parse time: #{inspect(time_str)}, error: #{inspect(error)}" end)
        error
    end
  end

  defp parse_killmail_time(%{"killTime" => time_str}) when is_binary(time_str) do
    # Handle alternative time format from zKillboard
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _offset} ->
        # Convert to UTC if not already
        {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      error ->
        Logger.warning(fn -> "[Parser] Failed to parse time: #{inspect(time_str)}, error: #{inspect(error)}" end)
        error
    end
  end

  defp parse_killmail_time(km) do
    Logger.warning(fn -> "[Parser] No time field found in killmail: #{inspect(km)}" end)
    {:error, :invalid_time}
  end

  @spec older_than_cutoff?(DateTime.t(), DateTime.t()) :: boolean()
  defp older_than_cutoff?(km_dt, cutoff_dt) do
    # A kill is older than cutoff if it's before the cutoff time
    # Note: DateTime.compare returns :lt if km_dt is before cutoff_dt
    DateTime.compare(km_dt, cutoff_dt) == :lt
  end

  @spec recent_kill?(killmail()) :: boolean()
  defp recent_kill?(km) do
    case km["kill_time"] do
      %DateTime{} = kill_time ->
        cutoff = DateTime.utc_now() |> DateTime.add(-3600, :second)
        DateTime.compare(kill_time, cutoff) == :gt

      _ ->
        false
    end
  end

  @spec enrich_victim(killmail()) :: killmail()
  defp enrich_victim(km) do
    victim = Map.get(km, "victim", %{})
    enriched_victim = Map.merge(victim, %{
      "ship_type_id" => victim["ship_type_id"],
      "character_id" => victim["character_id"],
      "corporation_id" => victim["corporation_id"],
      "alliance_id" => victim["alliance_id"]
    })
    km = Map.put(km, "victim", enriched_victim)

    km
    |> maybe_put_character_name("victim", "character_id", "victim_char_name")
    |> maybe_put_corp_info("victim", "corporation_id", "victim_corp_ticker", "victim_corp_name")
    |> maybe_put_alliance_info("victim", "alliance_id", "victim_alliance_ticker", "victim_alliance_name")
    |> maybe_put_ship_name("victim", "ship_type_id", "victim_ship_name")
  end

  @spec enrich_final_blow(killmail()) :: killmail()
  defp enrich_final_blow(km) do
    final_blow = Enum.find(km["attackers"], & &1["final_blow"])
    km = Map.put(km, "final_blow", final_blow)

    enriched_km = km
    |> maybe_put_character_name("final_blow", "character_id", "final_blow_char_name")
    |> maybe_put_corp_info("final_blow", "corporation_id", "final_blow_corp_ticker", "final_blow_corp_name")
    |> maybe_put_alliance_info("final_blow", "alliance_id", "final_blow_alliance_ticker", "final_blow_alliance_name")
    |> maybe_put_ship_name("final_blow", "ship_type_id", "final_blow_ship_name")

    enriched_km
  end

  @spec maybe_put_character_name(killmail(), String.t(), String.t(), String.t()) :: killmail()
  defp maybe_put_character_name(km, source_key, id_key, name_key) do
    case get_in(km, [source_key, id_key]) do
      nil -> km
      0 -> km
      eve_id ->
        result = retry with: exponential_backoff(200) |> randomize() |> cap(2_000) |> expiry(10_000), rescue_only: [RuntimeError] do
          case WandererApp.Esi.get_character_info(eve_id) do
            {:ok, %{"name" => char_name}} ->
              {:ok, char_name}

            {:error, :timeout} ->
              Logger.debug(fn -> "[Parser] Character info timeout, retrying => id=#{eve_id}" end)
              raise "Character info timeout, will retry"

            {:error, :not_found} ->
              Logger.debug(fn -> "[Parser] Character not found => id=#{eve_id}" end)
              :skip

            {:error, reason} ->
              if HttpUtil.retriable_error?(reason) do
                Logger.debug(fn -> "[Parser] Character info retriable error => id=#{eve_id}, reason=#{inspect(reason)}" end)
                raise "Character info error: #{inspect(reason)}, will retry"
              else
                Logger.debug(fn -> "[Parser] Character info failed => id=#{eve_id}, reason=#{inspect(reason)}" end)
                :skip
              end
          end
        end

        case result do
          {:ok, char_name} -> Map.put(km, name_key, char_name)
          _ -> km
        end
    end
  end

  @spec maybe_put_corp_info(killmail(), String.t(), String.t(), String.t(), String.t()) :: killmail()
  defp maybe_put_corp_info(km, source_key, id_key, ticker_key, name_key) do
    case get_in(km, [source_key, id_key]) do
      nil -> km
      0 -> km
      corp_id ->
        result = retry with: exponential_backoff(200) |> randomize() |> cap(2_000) |> expiry(10_000), rescue_only: [RuntimeError] do
          case WandererApp.Esi.get_corporation_info(corp_id) do
            {:ok, %{"ticker" => ticker, "name" => corp_name}} ->
              {:ok, {ticker, corp_name}}

            {:error, :timeout} ->
              Logger.debug(fn -> "[Parser] Corporation info timeout, retrying => id=#{corp_id}" end)
              raise "Corporation info timeout, will retry"

            {:error, :not_found} ->
              Logger.debug(fn -> "[Parser] Corporation not found => id=#{corp_id}" end)
              :skip

            {:error, reason} ->
              if HttpUtil.retriable_error?(reason) do
                Logger.debug(fn -> "[Parser] Corporation info retriable error => id=#{corp_id}, reason=#{inspect(reason)}" end)
                raise "Corporation info error: #{inspect(reason)}, will retry"
              else
                Logger.warning("[Parser] Failed to fetch corp info: ID=#{corp_id}, reason=#{inspect(reason)}")
                :skip
              end
          end
        end

        case result do
          {:ok, {ticker, corp_name}} ->
            km
            |> Map.put(ticker_key, ticker)
            |> Map.put(name_key, corp_name)
          _ -> km
        end
    end
  end

  @spec maybe_put_alliance_info(killmail(), String.t(), String.t(), String.t(), String.t()) :: killmail()
  defp maybe_put_alliance_info(km, source_key, id_key, ticker_key, name_key) do
    case get_in(km, [source_key, id_key]) do
      nil -> km
      0 -> km
      alliance_id ->
        result = retry with: exponential_backoff(200) |> randomize() |> cap(2_000) |> expiry(10_000), rescue_only: [RuntimeError] do
          case WandererApp.Esi.get_alliance_info(alliance_id) do
            {:ok, %{"ticker" => alliance_ticker, "name" => alliance_name}} ->
              {:ok, {alliance_ticker, alliance_name}}

            {:error, :timeout} ->
              Logger.debug(fn -> "[Parser] Alliance info timeout, retrying => id=#{alliance_id}" end)
              raise "Alliance info timeout, will retry"

            {:error, :not_found} ->
              Logger.debug(fn -> "[Parser] Alliance not found => id=#{alliance_id}" end)
              :skip

            {:error, reason} ->
              if HttpUtil.retriable_error?(reason) do
                Logger.debug(fn -> "[Parser] Alliance info retriable error => id=#{alliance_id}, reason=#{inspect(reason)}" end)
                raise "Alliance info error: #{inspect(reason)}, will retry"
              else
                Logger.debug(fn -> "[Parser] Alliance info failed => id=#{alliance_id}, reason=#{inspect(reason)}" end)
                :skip
              end
          end
        end

        case result do
          {:ok, {alliance_ticker, alliance_name}} ->
            km
            |> Map.put(ticker_key, alliance_ticker)
            |> Map.put(name_key, alliance_name)
          _ -> km
        end
    end
  end

  @spec maybe_put_ship_name(killmail(), String.t(), String.t(), String.t()) :: killmail()
  defp maybe_put_ship_name(km, source_key, id_key, name_key) do
    case get_in(km, [source_key, id_key]) do
      nil -> km
      0 -> km
      type_id ->
        result = retry with: exponential_backoff(200) |> randomize() |> cap(2_000) |> expiry(10_000), rescue_only: [RuntimeError] do
          case WandererApp.CachedInfo.get_ship_type(type_id) do
            {:ok, nil} -> :skip
            {:ok, %{name: ship_name}} -> {:ok, ship_name}
            {:error, :timeout} ->
              Logger.debug(fn -> "[Parser] Ship type timeout, retrying => id=#{type_id}" end)
              raise "Ship type timeout, will retry"

            {:error, :not_found} ->
              Logger.debug(fn -> "[Parser] Ship type not found => id=#{type_id}" end)
              :skip

            {:error, reason} ->
              if HttpUtil.retriable_error?(reason) do
                Logger.debug(fn -> "[Parser] Ship type retriable error => id=#{type_id}, reason=#{inspect(reason)}" end)
                raise "Ship type error: #{inspect(reason)}, will retry"
              else
                Logger.debug(fn -> "[Parser] Ship type failed => id=#{type_id}, reason=#{inspect(reason)}" end)
                :skip
              end
          end
        end

        case result do
          {:ok, ship_name} -> Map.put(km, name_key, ship_name)
          _ -> km
        end
    end
  end

  @spec parse_partial(map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def parse_partial(%{"killmail_id" => kill_id, "zkb" => %{"hash" => kill_hash}} = partial, cutoff_dt) do
    case WandererApp.Esi.ApiClient.get_killmail(kill_id, kill_hash) do
      {:ok, full_kill} ->
        case check_killmail_time(full_kill, cutoff_dt) do
          :older -> {:error, :older_than_cutoff}
          :skip -> {:error, :invalid_time}
          {km, kill_time_dt} ->
            km
            |> merge_zkb_data(partial)
            |> build_kill_data(kill_time_dt)
            |> maybe_enrich()
            |> put_into_cache()
            |> case do
              :skip -> {:error, :failed_to_store}
              km ->
                {:ok, km}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parse_partial(_, _), do: {:error, :invalid_killmail}
end
