defmodule WandererApp.Zkb.KillsProvider.Fetcher do
  @moduledoc """
  Handles kills fetch from zKillboard for a certain time range.
  Supports single-page or multi-page fetches, with caching & ESI calls.

  Includes a multi-system function (`fetch_kills_for_systems/3`) that calls
  individual fetch logic per system and returns a map of system_id => kills.
  """

  require Logger
  alias WandererApp.Zkb.KillsProvider.{Parser, KillsCache, ZkbApi}
  use Retry

  @page_size 200
-
  def fetch_limited_for_system(system_id, since_hours, limit, state) do
    {:ok, state1} = increment_calls_count(state)

    if KillsCache.recently_fetched?(system_id) do
      kills = KillsCache.fetch_cached_kills(system_id)
      {:ok, Enum.take(kills, limit), state1}
    else
      retry with: exponential_backoff(200)
             |> randomize()
             |> cap(2_000)
             |> expiry(10_000) do
        case do_partial_page_fetch(system_id, since_hours, limit, state1) do
          {:ok, new_st, kills} ->
            KillsCache.put_full_fetched_timestamp(system_id)
            {:ok, kills, new_st}

          {:error, reason, new_st} ->
            raise "[Fetcher] partial_page_fetch failed => system=#{system_id}, reason=#{inspect(reason)}, state=#{inspect(new_st)}"
        end
      after
        {:ok, kills, new_st} ->
          {:ok, kills, new_st}
      else
        exception ->
          Logger.error("[Fetcher] EXHAUSTED RETRIES => system_id=#{system_id}, exception=#{inspect(exception)}")
          {:error, exception, state1}
      end
    end
  rescue
    e ->
      Logger.error("""
      [Fetcher] EXCEPTION in fetch_limited_for_system
        system_id=#{system_id}, message=#{Exception.message(e)}
      """)
      {:error, e, state}
  end

  defp do_partial_page_fetch(system_id, since_hours, limit, st) do
    try do
      case increment_calls_count(st) do
        {:ok, st2} ->
          case ZkbApi.fetch_and_parse_page(system_id, 1, st2) do
            {:ok, st3, partials} ->
              cutoff_dt = hours_ago(since_hours)

              {_, _} =
                Enum.reduce_while(partials, {[], 0}, fn partial, {acc_list, count} ->
                  if count >= limit do
                    {:halt, {acc_list, count}}
                  else
                    case parse_partial_if_recent(partial, cutoff_dt, false) do
                      :older -> {:halt, {acc_list, count}}
                      :ok    -> {:cont, {[partial | acc_list], count + 1}}
                      :skip  -> {:cont, {acc_list, count}}
                    end
                  end
                end)

              stored_kills = KillsCache.fetch_cached_kills(system_id)
              {:ok, st3, Enum.take(stored_kills, limit)}

            {:error, reason, st3} ->
              {:error, reason, st3}
          end

        {:error, reason} ->
          {:error, reason, st}
      end
    rescue
      e ->
        Logger.error("""
        [Fetcher] EXCEPTION in do_partial_page_fetch => system_id=#{system_id}, msg=#{Exception.message(e)}
        """)
        {:error, e, st}
    end
  end

  def fetch_kills_for_system(system_id, since_hours, state) do
    if KillsCache.recently_fetched?(system_id) do
      kills = KillsCache.fetch_cached_kills(system_id)
      {:ok, kills, state}
    else
      case do_multi_page_fetch(system_id, since_hours, 1, state) do
        {:ok, new_st} ->
          KillsCache.put_full_fetched_timestamp(system_id)
          kills = KillsCache.fetch_cached_kills(system_id)
          {:ok, kills, new_st}

        {:error, reason, new_st} ->
          {:error, reason, new_st}
      end
    end
  rescue
    e ->
      Logger.error("""
      [Fetcher] EXCEPTION in fetch_kills_for_system => system_id=#{system_id}, msg=#{Exception.message(e)}
      """)
      {:error, e, state}
  end

  defp do_multi_page_fetch(system_id, since_hours, page, state) do
    case do_fetch_page(system_id, page, since_hours, state) do
      {:stop, new_st, :found_older} -> {:ok, new_st}
      {:ok, new_st, count} when count < @page_size -> {:ok, new_st}
      {:ok, new_st, _count} -> do_multi_page_fetch(system_id, since_hours, page + 1, new_st)
      {:error, reason, new_st} -> {:error, reason, new_st}
    end
  end

  defp do_fetch_page(system_id, page, since_hours, st) do
    with {:ok, st2} <- increment_calls_count(st),
         {:ok, st3, partials} <- ZkbApi.fetch_and_parse_page(system_id, page, st2) do
      cutoff_dt = hours_ago(since_hours)

      {count_stored, older_found?} =
        Enum.reduce_while(partials, {0, false}, fn partial, {acc_count, _had_older} ->
          case parse_partial_if_recent(partial, cutoff_dt, false) do
            :older -> {:halt, {acc_count, true}}
            :ok    -> {:cont, {acc_count + 1, false}}
            :skip  -> {:cont, {acc_count, false}}
          end
        end)

      if older_found? do
        {:stop, st3, :found_older}
      else
        {:ok, st3, count_stored}
      end
    else
      {:error, reason, stX} ->
        {:error, reason, stX}

      other ->
        Logger.warning("[Fetcher] parse error => #{inspect(other)}")
        {:error, :unexpected, st}
    end
  end

  defp parse_partial_if_recent(
         %{"killmail_id" => k_id, "zkb" => %{"hash" => k_hash}} = partial,
         cutoff_dt,
         _force?
       ) do
    # 1) If we already have killmail in the cache => skip ESI
    if KillsCache.get_killmail(k_id) do
      :skip
    else
      # 2) Not in cache => do ESI fetch
      with {:ok, full_km} <- fetch_full_killmail(k_id, k_hash),
           {:ok, dt} <- parse_killmail_time(full_km),
           false <- older_than_cutoff?(dt, cutoff_dt) do
        # store
        enriched = Map.merge(full_km, %{"zkb" => partial["zkb"]})
        parse_and_store(enriched)
      else
        true ->
          :older

        {:error, reason} ->
          Logger.warning("[Fetcher] ESI fail => kill_id=#{k_id}, reason=#{inspect(reason)}")
          :skip

        :skip ->
          :skip
      end
    end
  end

  @doc """
  Fetch up to `limit` kills for `system_id`, ignoring kills older than `since_hours`.
  If `force: true`, we ignore the "recently fetched" short-circuit.
  Also skip ESI calls if we already have the kill in cache.
  """
  def fetch_kills_for_system_up_to_age_and_limit(system_id, since_hours, limit, state, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    # If not force, then skip if recently fetched
    if not force? and KillsCache.recently_fetched?(system_id) do
      cached = KillsCache.fetch_cached_kills(system_id)
      {:ok, Enum.take(cached, limit), state}
    else
      cutoff_dt = hours_ago(since_hours)

      case do_multi_page_fetch_up_to_limit(system_id, cutoff_dt, limit, 1, 0, state) do
        {:ok, new_st, _total_fetched} ->
          KillsCache.put_full_fetched_timestamp(system_id)
          final_kills = KillsCache.fetch_cached_kills(system_id) |> Enum.take(limit)
          {:ok, final_kills, new_st}

        {:error, reason, new_st} ->
          {:error, reason, new_st}
      end
    end
  rescue
    e ->
      Logger.error("""
      [Fetcher] EXCEPTION in fetch_kills_for_system_up_to_age_and_limit
        system_id=#{system_id}, limit=#{limit}, hours=#{since_hours}
        message=#{Exception.message(e)}
      """)
      {:error, e, state}
  end

  defp do_multi_page_fetch_up_to_limit(system_id, cutoff_dt, limit, page, total_so_far, state) do
    with {:ok, st1} <- increment_calls_count(state),
         {:ok, st2, partials} <- ZkbApi.fetch_and_parse_page(system_id, page, st1) do

      {_, _, total_count_now} =
        Enum.reduce_while(partials, {0, false, total_so_far}, fn partial, {count_acc, older?, total_acc} ->
          if total_acc >= limit do
            {:halt, {count_acc, older?, total_acc}}
          else
            case parse_partial_if_older(partial, cutoff_dt) do
              :older ->
                {:halt, {count_acc, true, total_acc}}

              :ok ->
                {:cont, {count_acc + 1, false, total_acc + 1}}

              :skip ->
                {:cont, {count_acc, false, total_acc}}
            end
          end
        end)

      # if we found older kills or reached limit, or partials < @page_size => stop
      if total_count_now >= limit or length(partials) < @page_size do
        {:ok, st2, total_count_now}
      else
        do_multi_page_fetch_up_to_limit(system_id, cutoff_dt, limit, page + 1, total_count_now, st2)
      end
    else
      {:error, reason, stX} ->
        {:error, reason, stX}

      other ->
        Logger.warning("[Fetcher] Unexpected => #{inspect(other)}")
        {:error, :unexpected, state}
    end
  end

  defp parse_partial_if_older(%{"killmail_id" => k_id, "zkb" => %{"hash" => k_hash}} = partial, cutoff_dt) do
    # Skip ESI if we already have it
    if KillsCache.get_killmail(k_id) do
      :skip
    else
      case fetch_full_killmail(k_id, k_hash) do
        {:ok, full_km} ->
          case parse_killmail_time(full_km) do
            {:ok, km_dt} ->
              if DateTime.compare(km_dt, cutoff_dt) == :lt do
                :older
              else
                enriched = Map.merge(full_km, %{"zkb" => partial["zkb"]})
                parse_and_store(enriched)
              end

            _ -> :skip
          end

        {:error, reason} ->
          Logger.warning("[Fetcher] ESI fail => kill_id=#{k_id}, reason=#{inspect(reason)}")
          :skip
      end
    end
  end

  @doc """
  Fetch kills for multiple systems, returning a map of system_id => kills.
  If you want a specific "limit" or "force", pass them in `opts`.
  """
  def fetch_kills_for_systems(system_ids, since_hours, state, _opts \\ []) when is_list(system_ids) do
    #   1) Initialize an empty map = %{}
    #   2) For each system_id, call `fetch_kills_for_system/3` or the "up_to_age_and_limit" variant
    #   3) Merge the results into the map
    try do
      Enum.reduce(system_ids, {:ok, %{}, state}, fn sid, {:ok, acc_map, acc_st} ->
        case fetch_kills_for_system(sid, since_hours, acc_st) do
          {:ok, kills, new_st} ->
            {:ok, Map.put(acc_map, sid, kills), new_st}

          {:error, reason, new_st} ->
            {:error, reason, new_st}
        end
      end)
      |> case do
        {:ok, final_map, _final_state} ->
          {:ok, final_map}

        {:error, reason, _st} ->
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("""
        [Fetcher] EXCEPTION in fetch_kills_for_systems
          system_ids=#{inspect(system_ids)}
          since_hours=#{since_hours}
          message=#{Exception.message(e)}
        """)
        {:error, e}
    end
  end


  defp fetch_full_killmail(k_id, k_hash) do
    case WandererApp.Esi.get_killmail(k_id, k_hash) do
      {:ok, full_km} -> {:ok, full_km}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_killmail_time(full_km) do
    killmail_time_str = Map.get(full_km, "killmail_time", "")
    case DateTime.from_iso8601(killmail_time_str) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :skip
    end
  end

  defp older_than_cutoff?(dt, cutoff_dt),
    do: DateTime.compare(dt, cutoff_dt) == :lt

  defp parse_and_store(enriched) do
    case Parser.parse_and_store_killmail(enriched) do
      {:ok, _ktime} -> :ok
      _ -> :skip
    end
  end

  defp increment_calls_count(%{calls_count: c} = st),
    do: {:ok, %{st | calls_count: c + 1}}

  defp hours_ago(h),
    do: DateTime.utc_now() |> DateTime.add(-h * 3600, :second)
end
