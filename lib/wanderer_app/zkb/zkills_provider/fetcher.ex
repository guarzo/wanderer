defmodule WandererApp.Zkb.KillsProvider.Fetcher do
  @moduledoc """
  Low-level API for fetching killmails from zKillboard + ESI.

  Offers multiple "modes":
    - Fetch with multi-page (unlimited),
    - Fetch limited (some maximum number of kills),
    - Fetch up to age and limit, etc.
  """

  require Logger
  use Retry

  alias WandererApp.Zkb.KillsProvider.{Parser, KillsCache, ZkbApi}

  @page_size 200
  @max_pages 2

  @doc """
  Fetch killmails for a single system, bounding the total number (limit)
  and the max killmail age (since_hours). Checks the 'recently_fetched?' cache
  to avoid re-fetching too often.
  """
  def fetch_kills_for_system_up_to_age_and_limit(system_id, since_hours, limit, state, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    log_prefix = "[Fetcher] fetch_kills_for_system_up_to_age_and_limit => system=#{system_id}"

    if not force? and KillsCache.recently_fetched?(system_id) do
      cached = KillsCache.fetch_cached_kills(system_id)
      Logger.debug("#{log_prefix}, recently_fetched?=true => returning #{length(cached)} cached kills")
      {:ok, Enum.take(cached, limit), state}
    else
      Logger.debug("#{log_prefix}, hours=#{since_hours}, limit=#{limit}, force=#{force?}")

      retry with: exponential_backoff(300)
             |> randomize()
             |> cap(5_000)
             |> expiry(120_000) do
        cutoff_dt = hours_ago(since_hours)

        case do_multi_page_fetch_up_to_limit(system_id, cutoff_dt, limit, 1, 0, state) do
          {:ok, new_st, total_fetched} ->
            KillsCache.put_full_fetched_timestamp(system_id)
            final_kills = KillsCache.fetch_cached_kills(system_id) |> Enum.take(limit)
            Logger.debug(
              "#{log_prefix}, total_fetched=#{total_fetched}, final_cached=#{length(final_kills)}, calls_count=#{new_st.calls_count}"
            )
            {:ok, final_kills, new_st}

          {:error, :rate_limited, _new_st} ->
            raise ":rate_limited"

          {:error, reason, _new_st} ->
            raise "#{log_prefix}, reason=#{inspect(reason)}"
        end
      else
        error ->
          Logger.error("#{log_prefix}, EXHAUSTED => error=#{inspect(error)}")
          {:error, error, state}
      after
        {:ok, kills, new_st} ->
          {:ok, kills, new_st}
      end
    end
  rescue
    e ->
      Logger.error("[Fetcher] EXCEPTION up_to_age_and_limit => #{Exception.message(e)}")
      {:error, e, state}
  end

  @doc """
  Fetch killmails for a single system, no limit on how many kills,
  but we stop once we exceed @max_pages or find kills older than `since_hours`.
  """
  def fetch_kills_for_system(system_id, since_hours, state) do
    if KillsCache.recently_fetched?(system_id) do
      kills = KillsCache.fetch_cached_kills(system_id)
      {:ok, kills, state}
    else
      Logger.debug("[Fetcher] fetch_kills_for_system => system=#{system_id}, since_hours=#{since_hours}")

      retry with: exponential_backoff(300)
             |> randomize()
             |> cap(5_000)
             |> expiry(120_000) do
        case do_multi_page_fetch(system_id, since_hours, 1, state) do
          {:ok, new_st} ->
            KillsCache.put_full_fetched_timestamp(system_id)
            final_kills = KillsCache.fetch_cached_kills(system_id)
            Logger.debug("[Fetcher] system=#{system_id} => multi-page done, total=#{length(final_kills)} calls=#{new_st.calls_count}")
            {:ok, final_kills, new_st}

          {:error, :rate_limited, _new_st} ->
            raise ":rate_limited"

          {:error, reason, _new_st} ->
            raise "[Fetcher] multi_page => system=#{system_id}, reason=#{inspect(reason)}"
        end
      else
        error ->
          Logger.error("[Fetcher] EXHAUSTED multi-page => system=#{system_id}, error=#{inspect(error)}")
          {:error, error, state}
      after
        {:ok, kills, new_st} ->
          {:ok, kills, new_st}
      end
    end
  rescue
    e ->
      Logger.error("[Fetcher] EXCEPTION fetch_kills_for_system => #{Exception.message(e)}")
      {:error, e, state}
  end

  @doc """
  Fetch killmails for multiple systems, returning a map of system_id => kills.
  This is a simple sequential approach.
  """
  def fetch_kills_for_systems(system_ids, since_hours, state, _opts \\ []) when is_list(system_ids) do
    Logger.debug("[Fetcher] fetch_kills_for_systems => count=#{length(system_ids)}, since_hours=#{since_hours}")

    try do
      {final_map, final_state} =
        Enum.reduce(system_ids, {%{}, state}, fn sid, {acc_map, acc_st} ->
          case fetch_kills_for_system(sid, since_hours, acc_st) do
            {:ok, kills, new_st} ->
              {Map.put(acc_map, sid, kills), new_st}

            {:error, reason, new_st} ->
              Logger.debug("[Fetcher] system=#{sid} => error=#{inspect(reason)}")
              {Map.put(acc_map, sid, {:error, reason}), new_st}
          end
        end)

      Logger.debug("[Fetcher] fetch_kills_for_systems => done, final_map_size=#{map_size(final_map)} calls=#{final_state.calls_count}")
      {:ok, final_map}
    rescue
      e ->
        Logger.error("[Fetcher] EXCEPTION in fetch_kills_for_systems => #{Exception.message(e)}")
        {:error, e}
    end
  end

  defp do_multi_page_fetch_up_to_limit(system_id, cutoff_dt, limit, page, total_so_far, state) do
    if page > @max_pages do
      Logger.debug("[Fetcher] system=#{system_id}, up_to_limit => max_pages=#{@max_pages}, total=#{total_so_far}")
      {:ok, state, total_so_far}
    else
      Logger.debug("[Fetcher] up_to_limit => system=#{system_id}, page=#{page}, total_so_far=#{total_so_far}, limit=#{limit}")

      with {:ok, st1} <- increment_calls_count(state),
           {:ok, st2, partials} <- ZkbApi.fetch_and_parse_page(system_id, page, st1) do
        Logger.debug("[Fetcher] system=#{system_id}, page=#{page}, partials=#{length(partials)}")

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

        if total_count_now >= limit or length(partials) < @page_size do
          {:ok, st2, total_count_now}
        else
          do_multi_page_fetch_up_to_limit(system_id, cutoff_dt, limit, page + 1, total_count_now, st2)
        end
      else
        {:error, :rate_limited, st2} ->
          {:error, :rate_limited, st2}

        {:error, reason, st2} ->
          {:error, reason, st2}

        other ->
          Logger.warning("[Fetcher] Unexpected result => #{inspect(other)}")
          {:error, :unexpected, state}
      end
    end
  end

  defp parse_partial_if_older(%{"killmail_id" => k_id, "zkb" => %{"hash" => k_hash}} = partial, cutoff_dt) do
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

            _ ->
              :skip
          end

        {:error, reason} ->
          Logger.warning("[Fetcher] ESI fail => kill_id=#{k_id}, reason=#{inspect(reason)}")
          :skip
      end
    end
  end

  defp do_multi_page_fetch(system_id, since_hours, page, state) do
    if page > @max_pages do
      Logger.debug("[Fetcher] system=#{system_id}, reached max_pages=#{@max_pages}, stopping.")
      {:ok, state}
    else
      Logger.debug("[Fetcher] do_multi_page_fetch => system=#{system_id}, page=#{page}")

      case do_fetch_page(system_id, page, since_hours, state) do
        {:stop, new_st, :found_older} ->
          Logger.debug("[Fetcher] system=#{system_id}, page=#{page} => found_older => stopping multi-page.")
          {:ok, new_st}

        {:ok, new_st, count} when count < @page_size ->
          Logger.debug("[Fetcher] system=#{system_id}, page=#{page}, count=#{count} < page_size => done")
          {:ok, new_st}

        {:ok, new_st, _count} ->
          do_multi_page_fetch(system_id, since_hours, page + 1, new_st)

        {:error, :rate_limited, new_st} ->
          {:error, :rate_limited, new_st}

        {:error, reason, new_st} ->
          {:error, reason, new_st}
      end
    end
  end

  defp do_fetch_page(system_id, page, since_hours, st) do
    with {:ok, st2} <- increment_calls_count(st),
         {:ok, st3, partials} <- ZkbApi.fetch_and_parse_page(system_id, page, st2) do
      Logger.debug("[Fetcher] system=#{system_id}, page=#{page}, partials_count=#{length(partials)}")

      cutoff_dt = hours_ago(since_hours)

      {count_stored, older_found?} =
        Enum.reduce_while(partials, {0, false}, fn partial, {acc_count, _had_older} ->
          if acc_count >= @page_size do
            {:halt, {acc_count, false}}
          else
            case parse_partial_if_recent(partial, cutoff_dt) do
              :older ->
                {:halt, {acc_count, true}}

              :ok ->
                {:cont, {acc_count + 1, false}}

              :skip ->
                {:cont, {acc_count, false}}
            end
          end
        end)

      if older_found? do
        {:stop, st3, :found_older}
      else
        {:ok, st3, count_stored}
      end
    else
      {:error, :rate_limited, stX} ->
        {:error, :rate_limited, stX}

      {:error, reason, stX} ->
        {:error, reason, stX}

      other ->
        Logger.warning("[Fetcher] parse error => #{inspect(other)}")
        {:error, :unexpected, st}
    end
  end

  defp parse_partial_if_recent(%{"killmail_id" => k_id, "zkb" => %{"hash" => k_hash}} = partial, cutoff_dt) do
    if KillsCache.get_killmail(k_id) do
      :skip
    else
      with {:ok, full_km} <- fetch_full_killmail(k_id, k_hash),
           {:ok, dt} <- parse_killmail_time(full_km),
           false <- older_than_cutoff?(dt, cutoff_dt) do
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

  defp fetch_full_killmail(k_id, k_hash) do
    case WandererApp.Esi.get_killmail(k_id, k_hash) do
      {:ok, full_km} -> {:ok, full_km}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_killmail_time(full_km) do
    killmail_time_str = Map.get(full_km, "killmail_time", "")

    case DateTime.from_iso8601(killmail_time_str) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        :skip
    end
  end

  defp parse_and_store(enriched) do
    case Parser.parse_and_store_killmail(enriched) do
      {:ok, _time} -> :ok
      _ -> :skip
    end
  end

  defp older_than_cutoff?(dt, cutoff_dt), do: DateTime.compare(dt, cutoff_dt) == :lt

  defp hours_ago(h), do: DateTime.utc_now() |> DateTime.add(-h * 3600, :second)

  defp increment_calls_count(%{calls_count: c} = st),
    do: {:ok, %{st | calls_count: c + 1}}
end
