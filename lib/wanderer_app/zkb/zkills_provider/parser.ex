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

    # Log what fields we have
    Logger.info(fn -> "[Parser] Processing killmail with fields: #{inspect(Map.keys(km))}" end)
    Logger.info(fn -> "[Parser] Killmail ID: #{inspect(km["killmail_id"])}" end)
    Logger.info(fn -> "[Parser] ZKB hash: #{inspect(get_in(km, ["zkb", "hash"]))}" end)

    # First check if we have the required fields for ESI fetch
    case {km["killmail_id"], get_in(km, ["zkb", "hash"])} do
      {kill_id, hash} when is_integer(kill_id) and is_binary(hash) ->
        # We have the required fields, try ESI fetch
        Logger.info(fn -> "[Parser] Attempting to fetch killmail #{kill_id} from ESI with hash #{hash}" end)
        case ApiClient.get_killmail(kill_id, hash) do
          {:ok, full_km} ->
            Logger.info(fn -> "[Parser] Successfully fetched full killmail for #{kill_id} with time: #{inspect(get_in(full_km, ["killmail_time"]))}" end)
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
            Logger.info(fn -> "[Parser] Skipping kill #{km["killmail_id"]} - no killmail_time and missing required fields for ESI fetch" end)
            :skip
          time ->
            Logger.info(fn -> "[Parser] Using existing killmail_time: #{time}" end)
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
      :older -> :older
      :skip -> :skip
      {km, kill_time_dt} ->
        case build_kill_data(km, kill_time_dt) do
          nil -> :skip
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
          Logger.info(fn ->
            "[Parser] Skipping kill #{km["killmail_id"]} - older than cutoff (kill_time=#{DateTime.to_iso8601(km_dt)}, cutoff=#{DateTime.to_iso8601(cutoff_dt)}, diff_hours=#{DateTime.diff(km_dt, cutoff_dt) / 3600})"
          end)
          :older
        else
          Logger.info(fn ->
            "[Parser] Accepting kill #{km["killmail_id"]} - within time window (kill_time=#{DateTime.to_iso8601(km_dt)}, cutoff=#{DateTime.to_iso8601(cutoff_dt)}, diff_hours=#{DateTime.diff(km_dt, cutoff_dt) / 3600})"
          end)
          {km, km_dt}
        end

      _ ->
        Logger.info(fn -> "[Parser] Skipping kill #{km["killmail_id"]} - invalid time format" end)
        :skip
    end
  end

  @spec build_kill_data(killmail(), DateTime.t()) :: killmail() | nil
  defp build_kill_data(%{"killmail_id" => kill_id} = km, kill_time_dt) do
    victim = Map.get(km, "victim", %{})
    attackers = Map.get(km, "attackers", [])
    npc_flag = get_in(km, ["zkb", "npc"]) || false

    if npc_flag do
      Logger.info(fn -> "[Parser] Skipping kill #{kill_id} - NPC kill" end)
      nil
    else
      %{
        "killmail_id" => kill_id,
        "kill_time" => kill_time_dt,
        "solar_system_id" => km["solar_system_id"],
        "zkb" => Map.get(km, "zkb", %{}),
        "attacker_count" => length(attackers),
        "total_value" => get_in(km, ["zkb", "totalValue"]) || 0,
        "victim" => victim,
        "attackers" => attackers,
        "npc" => npc_flag
      }
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
    Logger.info(fn -> "[Parser] Storing kill #{km["killmail_id"]} in cache" end)
    KillsCache.put_killmail(km["killmail_id"], km)
    KillsCache.add_killmail_id_to_system_list(km["solar_system_id"], km["killmail_id"])
    km
  end

  @spec inc_counter_if_recent(killmail() | :skip) :: :ok | :skip
  defp inc_counter_if_recent(:skip), do: :skip
  defp inc_counter_if_recent(km) do
    if recent_kill?(km) do
      Logger.info(fn -> "[Parser] Incrementing kill counter for system #{km["solar_system_id"]}" end)
      KillsCache.incr_system_kill_count(km["solar_system_id"])
      :ok
    else
      Logger.info(fn -> "[Parser] Skipping kill counter increment for system #{km["solar_system_id"]} - not recent" end)
      :skip
    end
  end

  # Helper Functions

  @spec parse_killmail_time(killmail()) :: {:ok, DateTime.t()} | {:error, term()}
  defp parse_killmail_time(%{"killmail_time" => time_str}) when is_binary(time_str) do
    # zKillboard returns time in format "2024-02-14T19:04:39Z"
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _offset} -> {:ok, dt}
      error ->
        Logger.info(fn -> "[Parser] Failed to parse time #{time_str}: #{inspect(error)}" end)
        error
    end
  end

  defp parse_killmail_time(km) do
    Logger.info(fn -> "[Parser] Invalid killmail time format: #{inspect(km)}" end)
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
    Map.put(km, "victim", enriched_victim)
  end

  @spec enrich_final_blow(killmail()) :: killmail()
  defp enrich_final_blow(km) do
    final_blow = Enum.find(km["attackers"], & &1["final_blow"])
    Map.put(km, "final_blow", final_blow)
  end
end
