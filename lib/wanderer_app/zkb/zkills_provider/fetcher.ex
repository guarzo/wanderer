defmodule WandererApp.Zkb.KillsProvider.Fetcher do
  require Logger
  alias WandererApp.Zkb.KillsProvider.{Parser, KillsCache, ZkbApi}
  use Retry

  @page_size 200
  @max_pages 5

  def fetch_limited_for_system(system_id, since_hours, limit, state) do
    {:ok, state1} = increment_calls_count(state)

    if KillsCache.recently_fetched?(system_id) do
      kills = KillsCache.fetch_cached_kills(system_id)
      {:ok, Enum.take(kills, limit), state1}
    else
      Logger.debug(
        "[Fetcher] fetch_limited_for_system => system=#{system_id}, " <>
          "limit=#{limit}, since_hours=#{since_hours}"
      )

      retry with: exponential_backoff(200)
             |> randomize()
             |> cap(2_000)
             |> expiry(10_000) do
        case do_partial_page_fetch(system_id, since_hours, limit, state1) do
          {:ok, new_st, kills} ->
            KillsCache.put_full_fetched_timestamp(system_id)
            {:ok, kills, new_st}

          {:error, :rate_limited, _new_st} ->
            raise ":rate_limited"

          {:error, reason, _new_st} ->
            raise "[Fetcher] partial_page_fetch => system=#{system_id}, reason=#{inspect(reason)}"
        end
      else
        exception ->
          Logger.error(
            "[Fetcher] EXHAUSTED partial fetch => system=#{system_id}, " <>
              "exception=#{inspect(exception)}"
          )

          {:error, exception, state1}
      after
        {:ok, kills, new_st} ->
          {:ok, kills, new_st}
      end
    end
  rescue
    e ->
      Logger.error(
        "[Fetcher] EXCEPTION in fetch_limited_for_system => #{Exception.message(e)}"
      )

      {:error, e, state}
  end

  defp do_partial_page_fetch(system_id, since_hours, limit, st) do
    case increment_calls_count(st) do
      {:ok, st2} ->
        Logger.debug(
          "[Fetcher] do_partial_page_fetch => system=#{system_id}, " <>
            "page=1, limit=#{limit}, since_hours=#{since_hours}"
        )

        case ZkbApi.fetch_and_parse_page(system_id, 1, st2) do
          {:ok, st3, partials} ->
            Logger.debug(
              "[Fetcher] system=#{system_id}, partials_count=#{length(partials)} from page=1"
            )

            cutoff_dt = hours_ago(since_hours)

            {_, _} =
              Enum.reduce_while(partials, {[], 0}, fn partial, {acc_list, count} ->
                if count >= limit do
                  {:halt, {acc_list, count}}
                else
                  case parse_partial_if_recent(partial, cutoff_dt) do
                    :older ->
                      {:halt, {acc_list, count}}

                    :ok ->
                      {:cont, {[partial | acc_list], count + 1}}

                    :skip ->
                      {:cont, {acc_list, count}}
                  end
                end
              end)

            stored_kills = KillsCache.fetch_cached_kills(system_id)
            final = Enum.take(stored_kills, limit)

            Logger.debug(
              "[Fetcher] system=#{system_id}, after partial => " <>
                "total cached=#{length(stored_kills)} returning=#{length(final)}"
            )

            {:ok, st3, final}

          {:error, reason, st3} ->
            {:error, reason, st3}
        end

      {:error, reason} ->
        {:error, reason, st}
    end
  end

  def fetch_kills_for_system(system_id, since_hours, state) do
    if KillsCache.recently_fetched?(system_id) do
      kills = KillsCache.fetch_cached_kills(system_id)
      {:ok, kills, state}
    else
      Logger.debug(
        "[Fetcher] fetch_kills_for_system => system=#{system_id}, since_hours=#{since_hours}"
      )

      retry with: exponential_backoff(300)
             |> randomize()
             |> cap(5_000)
             |> expiry(120_000) do
        case do_multi_page_fetch(system_id, since_hours, 1, state) do
          {:ok, new_st} ->
            KillsCache.put_full_fetched_timestamp(system_id)
            final_kills = KillsCache.fetch_cached_kills(system_id)

            Logger.debug(
              "[Fetcher] system=#{system_id} => multi-page done, " <>
                "total cached=#{length(final_kills)} calls_count=#{new_st.calls_count}"
            )

            {:ok, final_kills, new_st}

          {:error, :rate_limited, _new_st} ->
            raise ":rate_limited"

          {:error, reason, _new_st} ->
            raise "[Fetcher] multi_page_fetch => system=#{system_id}, reason=#{inspect(reason)}"
        end
      else
        error ->
          Logger.error(
            "[Fetcher] EXHAUSTED multi-page => system=#{system_id}, error=#{inspect(error)}"
          )

          {:error, error, state}
      after
        {:ok, kills, new_st} ->
          {:ok, kills, new_st}
      end
    end
  rescue
    e ->
      Logger.error(
        "[Fetcher] EXCEPTION fetch_kills_for_system => #{Exception.message(e)}"
      )

      {:error, e, state}
  end

  defp do_multi_page_fetch(system_id, since_hours, page, state) do
    if page > @max_pages do
      Logger.debug("[Fetcher] system=#{system_id}, reached max_pages=#{@max_pages}, stopping.")
      {:ok, state}
    else
      Logger.debug(
        "[Fetcher] do_multi_page_fetch => system=#{system_id}, page=#{page}, since_hours=#{since_hours}"
      )

      case do_fetch_page(system_id, page, since_hours, state) do
        {:stop, new_st, :found_older} ->
          Logger.debug(
            "[Fetcher] system=#{system_id}, page=#{page} => found_older => stopping multi-page."
          )

          {:ok, new_st}

        {:ok, new_st, count} when count < @page_size ->
          Logger.debug(
            "[Fetcher] system=#{system_id}, page=#{page}, count=#{count} < page_size => done"
          )

          {:ok, new_st}

        {:ok, new_st, count} ->
          Logger.debug(
            "[Fetcher] system=#{system_id}, page=#{page}, count=#{count} => continuing next page..."
          )

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
      Logger.debug(
        "[Fetcher] system=#{system_id}, page=#{page}, " <>
          "partials_count=#{length(partials)} calls_count=#{st3.calls_count}"
      )

      cutoff_dt = hours_ago(since_hours)

      {count_stored, older_found?} =
        Enum.reduce_while(partials, {0, false}, fn partial, {acc_count, _had_older} ->
          case parse_partial_if_recent(partial, cutoff_dt) do
            :older ->
              {:halt, {acc_count, true}}

            :ok ->
              {:cont, {acc_count + 1, false}}

            :skip ->
              {:cont, {acc_count, false}}
          end
        end)

      Logger.debug(
        "[Fetcher] system=#{system_id}, page=#{page}, stored_now=#{count_stored}, " <>
          "older_found=#{older_found?}"
      )

      if older_found? do
        {:stop, st3, :found_older}
      else
        {:ok, st3, count_stored}
      end
    else
      {:error, :rate_limited, stX} ->
        Logger.debug("[Fetcher] system=#{system_id}, page=#{page} => rate_limited!")
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

  def fetch_kills_for_system_up_to_age_and_limit(system_id, since_hours, limit, state, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    if not force? and KillsCache.recently_fetched?(system_id) do
      cached = KillsCache.fetch_cached_kills(system_id)
      {:ok, Enum.take(cached, limit), state}
    else
      Logger.debug(
        "[Fetcher] fetch_kills_for_system_up_to_age_and_limit => " <>
          "system=#{system_id}, hours=#{since_hours}, limit=#{limit}, force=#{force?}"
      )

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
              "[Fetcher] system=#{system_id}, up_to_limit => done, " <>
                "total_fetched=#{total_fetched}, final_cached=#{length(final_kills)} " <>
                "calls_count=#{new_st.calls_count}"
            )

            {:ok, final_kills, new_st}

          {:error, :rate_limited, _new_st} ->
            raise ":rate_limited"

          {:error, reason, _new_st} ->
            raise "[Fetcher] up_to_limit => system=#{system_id}, reason=#{inspect(reason)}"
        end
      else
        error ->
          Logger.error(
            "[Fetcher] EXHAUSTED up_to_limit => system=#{system_id}, error=#{inspect(error)}"
          )

          {:error, error, state}
      after
        {:ok, kills, new_st} ->
          {:ok, kills, new_st}
      end
    end
  rescue
    e ->
      Logger.error(
        "[Fetcher] EXCEPTION up_to_age_and_limit => #{Exception.message(e)}"
      )

      {:error, e, state}
  end

  defp do_multi_page_fetch_up_to_limit(system_id, cutoff_dt, limit, page, total_so_far, state) do
    if page > @max_pages do
      Logger.debug(
        "[Fetcher] system=#{system_id}, up_to_limit => hit max_pages=#{@max_pages}, " <>
          "total_so_far=#{total_so_far}"
      )

      {:ok, state, total_so_far}
    else
      Logger.debug(
        "[Fetcher] do_multi_page_fetch_up_to_limit => system=#{system_id}, " <>
          "page=#{page}, total_so_far=#{total_so_far}, limit=#{limit}"
      )

      case increment_calls_count(state) do
        {:ok, st1} ->
          case ZkbApi.fetch_and_parse_page(system_id, page, st1) do
            {:ok, st2, partials} ->
              Logger.debug(
                "[Fetcher] system=#{system_id}, page=#{page}, " <>
                  "partials_count=#{length(partials)}"
              )

              {_, _, total_count_now} =
                Enum.reduce_while(
                  partials,
                  {0, false, total_so_far},
                  fn partial, {count_acc, older?, total_acc} ->
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
                  end
                )

              Logger.debug(
                "[Fetcher] system=#{system_id}, page=#{page}, total_count_now=#{total_count_now}"
              )

              if total_count_now >= limit or length(partials) < @page_size do
                {:ok, st2, total_count_now}
              else
                do_multi_page_fetch_up_to_limit(
                  system_id,
                  cutoff_dt,
                  limit,
                  page + 1,
                  total_count_now,
                  st2
                )
              end

            {:error, :rate_limited, st2} ->
              Logger.debug("[Fetcher] system=#{system_id}, page=#{page} => rate_limited")
              {:error, :rate_limited, st2}

            {:error, reason, st2} ->
              {:error, reason, st2}
          end

        {:error, reason} ->
          {:error, reason, state}
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

  def fetch_kills_for_systems(system_ids, since_hours, state, _opts \\ []) when is_list(system_ids) do
    Logger.debug(
      "[Fetcher] fetch_kills_for_systems => system_ids_count=#{length(system_ids)}, " <>
        "since_hours=#{since_hours}"
    )

    try do
      {final_map, final_state} =
        Enum.reduce(system_ids, {%{}, state}, fn sid, {acc_map, acc_st} ->
          case fetch_kills_for_system(sid, since_hours, acc_st) do
            {:ok, kills, new_st} ->
              {Map.put(acc_map, sid, kills), new_st}

            {:error, reason, new_st} ->
              Logger.debug(
                "[Fetcher] fetch_kills_for_system => system=#{sid} => error=#{inspect(reason)}"
              )

              {Map.put(acc_map, sid, {:error, reason}), new_st}
          end
        end)

      Logger.debug(
        "[Fetcher] fetch_kills_for_systems => done, final_map_size=#{map_size(final_map)}, " <>
          "calls_count=#{final_state.calls_count}"
      )

      {:ok, final_map}
    rescue
      e ->
        Logger.error(
          "[Fetcher] EXCEPTION in fetch_kills_for_systems => #{Exception.message(e)}"
        )

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
      {:ok, dt, _off} -> {:ok, dt}
      _ -> :skip
    end
  end

  defp parse_and_store(enriched) do
    case Parser.parse_and_store_killmail(enriched) do
      {:ok, _time} -> :ok
      _ -> :skip
    end
  end

  defp older_than_cutoff?(dt, cutoff_dt) do
    DateTime.compare(dt, cutoff_dt) == :lt
  end

  defp hours_ago(h),
    do: DateTime.utc_now() |> DateTime.add(-h * 3600, :second)

  defp increment_calls_count(%{calls_count: c} = st),
    do: {:ok, %{st | calls_count: c + 1}}
end
