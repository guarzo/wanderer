defmodule WandererApp.Map.RouteStaticData do
  @moduledoc """
  Shared static-data hydration for route results.

  `Routes.find/5`, `Routes.find_strict/5` and `RoutesBy.find/3` each return a
  `systems_static_data` list alongside their routes, and each hydrated it the
  same way: one `CachedInfo.get_system_static_info/1` lookup per system, fanned
  out with `Task.async_stream/3`. They were two near-identical private copies,
  and the copies had already drifted — `map_routes.ex` grew an `{:error, _}`
  clause, `routes_by.ex` never did — so the same defect had to be fixed twice
  and was not. Centralizing here keeps the failure handling in one place.
  """

  require Logger

  @minimum_route_attrs [
    :system_class,
    :class_title,
    :security,
    :triglavian_invasion_status,
    :solar_system_id,
    :solar_system_name,
    :region_name,
    :is_shattered
  ]

  @default_static_info_timeout :timer.seconds(15)

  @logger Application.compile_env(:wanderer_app, :logger)

  @doc """
  Resolves `system_ids` to their minimal static attributes.

  Order follows `system_ids`, but the result is NOT positional: systems that
  have no static record, whose lookup errors, or whose lookup overruns
  `static_info_timeout/0` are omitted entirely. Callers look systems up by
  `:solar_system_id`, never by index — see `hydrate/1`'s body for why omission
  beats a `nil` placeholder.
  """
  @spec hydrate([integer()]) :: [map()]
  def hydrate(system_ids) do
    system_ids = Enum.uniq(system_ids)
    lookup = lookup_fun()

    {static_data, timed_out_system_ids} =
      system_ids
      |> Task.async_stream(
        fn system_id ->
          case lookup.(system_id) do
            {:ok, nil} ->
              nil

            {:ok, system} ->
              system |> Map.take(@minimum_route_attrs)

            # `get_system_static_info/1` also returns {:error, :not_found},
            # {:error, :api_error} and {:error, :cache_error}. Without this clause
            # any of them raises CaseClauseError inside the task, and because
            # `Task.async_stream` LINKS its tasks, that kills the calling process
            # rather than surfacing as `{:exit, _}` below — `on_timeout` only
            # converts timeouts, never raises.
            {:error, _reason} ->
              nil
          end
        end,
        max_concurrency: System.schedulers_online() * 4,
        timeout: static_info_timeout(),
        # `:kill_task` is what makes the `{:exit, _}` clause below reachable at
        # all. Under the default `on_timeout: :exit` the overrunning task's exit
        # travels the link and kills the CALLING process before the collector
        # ever runs. The two options are a pair; neither is correct without the
        # other.
        #
        # That mattered most for `Routes.find/5` and `RoutesBy.find/3`, which run
        # inside plain `Task.async` calls linked to the LiveView
        # (map_routes_event_handler.ex:98,142,192). LiveView does not trap exits,
        # so one slow lookup remounted the user's entire map session.
        # `Routes.find_strict/5` was already contained — the route watcher calls
        # it under `Task.Supervisor.async_nolink/2` (route_watcher.ex:257) and
        # handles the `{:DOWN, ...}` — but it still lost every system in the
        # cycle where one system was slow.
        on_timeout: :kill_task
      )
      # `async_stream` is ordered by default, so zipping against the input
      # recovers which system each result belongs to — needed to report the
      # timed-out ones, since `{:exit, _}` carries no system id.
      |> Enum.zip(system_ids)
      |> Enum.map_reduce([], fn
        {{:ok, static_info}, _system_id}, timed_out -> {static_info, timed_out}
        {{:exit, _reason}, system_id}, timed_out -> {nil, [system_id | timed_out]}
      end)

    log_timed_out_systems(timed_out_system_ids)

    # Unresolved systems are dropped rather than passed through as `nil`. The
    # frontend reads this list only by id — `RoutesWidget.tsx:60` and
    # `PingRoute.tsx:28` both do `.find(sd => sd.solar_system_id === id)` — and a
    # `null` element makes that predicate throw a TypeError, taking down the
    # whole widget over one missing system. `Evaluator.index_static_data/1`
    # (route alerts) already rejected nils on its own.
    Enum.reject(static_data, &is_nil/1)
  end

  defp log_timed_out_systems([]), do: :ok

  defp log_timed_out_systems(system_ids) do
    # Worth a warning rather than silence: a dropped system is invisible in the
    # UI — `RoutesList.tsx:106` filters it out of the rendered chain while the
    # jump count beside it still comes from the raw id list, so a timeout shows
    # up to the user only as a route that looks shorter and safer than it is.
    @logger.warning(
      "Route static data lookup timed out for #{length(system_ids)} system(s): " <>
        "#{inspect(Enum.reverse(system_ids))}. They are omitted from systems_static_data."
    )
  end

  # Per-system budget for `hydrate/1`. Generous by default because a cold
  # `get_system_static_info/1` scans the whole MapSolarSystem table and
  # repopulates the cache row by row (cached_info.ex) — killing that at
  # `Task.async_stream`'s 5s default would drop static data routinely after any
  # restart. Overridable so tests can force the timeout path.
  defp static_info_timeout,
    do:
      Application.get_env(
        :wanderer_app,
        :route_static_info_timeout_ms,
        @default_static_info_timeout
      )

  # Resolved once per `hydrate/1` rather than per system, and only overridden by
  # tests: the timeout path is otherwise unreachable on demand, because a real
  # `get_system_static_info/1` is either a microsecond cache hit or a full table
  # scan whose duration nothing here controls. Squeezing the budget alone does
  # not prove the fix — that assertion passes whether or not a timeout actually
  # fired. Blocking a named system does.
  defp lookup_fun do
    Application.get_env(
      :wanderer_app,
      :route_static_info_lookup,
      &WandererApp.CachedInfo.get_system_static_info/1
    )
  end
end
