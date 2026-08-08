defmodule WandererApp.Map.Routes do
  @moduledoc """
  Map routes helper
  """

  require Logger

  @default_routes_settings %{
    path_type: "shortest",
    include_mass_crit: true,
    include_eol: false,
    include_frig: true,
    include_cruise: true,
    avoid_wormholes: false,
    avoid_pochven: false,
    avoid_edencom: false,
    avoid_triglavian: false,
    include_thera: true,
    avoid: []
  }

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

  @get_link_pairs_advanced_params [
    :include_mass_crit,
    :include_eol,
    :include_frig
  ]

  @zarzakh_system 30_100_000
  @default_avoid_systems [@zarzakh_system]

  @routes_ttl :timer.minutes(15)
  @logger Application.compile_env(:wanderer_app, :logger)

  def find(map_id, hubs, origin, routes_settings, false) do
    case do_find_routes(map_id, origin, hubs, routes_settings) do
      {:ok, routes} ->
        {:ok, %{routes: routes, systems_static_data: hydrate_static_data(routes)}}

      _error ->
        {:ok, %{routes: [], systems_static_data: []}}
    end
  end

  def find(_map_id, hubs, origin, _routes_settings, true) do
    origin = origin |> String.to_integer()
    hubs = hubs |> Enum.map(&(&1 |> String.to_integer()))

    routes =
      hubs
      |> Enum.map(fn hub ->
        %{origin: origin, destination: hub, success: false, systems: [], has_connection: false}
      end)

    {:ok, %{routes: routes, systems_static_data: []}}
  end

  @doc """
  Sibling of `find/5` for callers that must distinguish a solver outage from a
  genuine no-path result (see the design doc, "Distinguishing failure from
  no-route"). Same params assembly, same cache key, same TTL — the only
  difference is that a `get_routes_custom/3` error is returned to the caller
  instead of falling back to the `get_routes_eve/4` stub.

  The final argument is named `hubs_limit_reached?`. It is *not* "avoid
  wormholes": as in `find/5`, `true` means "the hub count already exceeded the
  map's limit, skip the solver" — see `find/5`'s second clause
  (`map_routes.ex:80-91`) and its callers in `map_routes_event_handler.ex:96,105`.
  Route alerts always pass `false`.
  """
  @spec find_strict(binary(), [binary()], binary(), map(), boolean()) ::
          {:ok, %{routes: [map()], systems_static_data: [map() | nil]}} | {:error, term()}
  def find_strict(map_id, hubs, origin, routes_settings, false) do
    case do_find_routes(map_id, origin, hubs, routes_settings, strict: true) do
      {:ok, routes} ->
        # Unlike `find/5`, callers of `find_strict/5` (route alerts) must
        # judge the ORIGIN's security too — a highsec-only route from a
        # highsec home is a different claim than one from a lowsec home. Pass
        # `include_origin?: true` so the origin is present in
        # `systems_static_data`; `find/5` is unaffected (default `false`).
        {:ok, %{routes: routes, systems_static_data: hydrate_static_data(routes, true)}}

      {:error, _reason} = error ->
        error
    end
  end

  def find_strict(_map_id, hubs, origin, _routes_settings, true) do
    origin = origin |> String.to_integer()
    hubs = hubs |> Enum.map(&(&1 |> String.to_integer()))

    routes =
      hubs
      |> Enum.map(fn hub ->
        %{origin: origin, destination: hub, success: false, systems: [], has_connection: false}
      end)

    {:ok, %{routes: routes, systems_static_data: []}}
  end

  # `include_origin?` defaults to `false` to keep `find/5`'s observable output
  # byte-identical to before this change. `find_strict/5` (route alerts) is
  # the only caller that passes `true` — see its own comment for why the
  # origin's static data must be present for that caller and not this one.
  defp hydrate_static_data(routes, include_origin? \\ false) do
    routes
    |> Enum.flat_map(fn route_info ->
      if include_origin? do
        [route_info.origin | route_info.systems]
      else
        route_info.systems
      end
    end)
    |> Enum.uniq()
    |> Task.async_stream(
      fn system_id ->
        case WandererApp.CachedInfo.get_system_static_info(system_id) do
          {:ok, nil} ->
            nil

          {:ok, system} ->
            system |> Map.take(@minimum_route_attrs)

          # `get_system_static_info/1` also returns {:error, :not_found},
          # {:error, :api_error} and {:error, :cache_error}. Without this clause
          # any of them raises CaseClauseError inside the task, and because
          # `Task.async_stream` LINKS its tasks, that kills this process rather
          # than surfacing as `{:exit, _}` below. A system we cannot resolve is
          # missing static data, which every caller already handles as `nil`.
          {:error, _reason} ->
            nil
        end
      end,
      max_concurrency: System.schedulers_online() * 4
    )
    |> Enum.map(fn {:ok, val} -> val end)
  end

  defp do_find_routes(map_id, origin, hubs, routes_settings, opts \\ []) do
    origin = origin |> String.to_integer()
    hubs = hubs |> Enum.map(&(&1 |> String.to_integer()))

    routes_settings = @default_routes_settings |> Map.merge(routes_settings)

    connections =
      case routes_settings.avoid_wormholes do
        false ->
          map_chains =
            routes_settings
            |> Map.take(@get_link_pairs_advanced_params)
            |> Map.put_new(:map_id, map_id)
            |> WandererApp.Api.MapConnection.get_link_pairs_advanced!()
            |> Enum.map(fn %{
                             solar_system_source: solar_system_source,
                             solar_system_target: solar_system_target
                           } ->
              %{
                first: solar_system_source,
                second: solar_system_target
              }
            end)
            |> Enum.uniq()

          {:ok, thera_chains} =
            case routes_settings.include_thera do
              true ->
                WandererApp.Server.TheraDataFetcher.get_chain_pairs(routes_settings)

              false ->
                {:ok, []}
            end

          chains = remove_intersection([map_chains | thera_chains] |> List.flatten())

          chains =
            case routes_settings.include_cruise do
              false ->
                {:ok, wh_class_a_systems} = WandererApp.CachedInfo.get_wh_class_a_systems()

                chains
                |> Enum.filter(fn x ->
                  not Enum.member?(wh_class_a_systems, x.first) and
                    not Enum.member?(wh_class_a_systems, x.second)
                end)

              _ ->
                chains
            end

          chains
          |> Enum.map(fn chain ->
            ["#{chain.first}|#{chain.second}", "#{chain.second}|#{chain.first}"]
          end)
          |> List.flatten()

        true ->
          []
      end

    {:ok, trig_systems} = WandererApp.CachedInfo.get_trig_systems()

    pochven_solar_systems =
      trig_systems
      |> Enum.filter(fn s -> s.triglavian_invasion_status == "Final" end)
      |> Enum.map(& &1.solar_system_id)

    triglavian_solar_systems =
      trig_systems
      |> Enum.filter(fn s -> s.triglavian_invasion_status == "Triglavian" end)
      |> Enum.map(& &1.solar_system_id)

    edencom_solar_systems =
      trig_systems
      |> Enum.filter(fn s -> s.triglavian_invasion_status == "Edencom" end)
      |> Enum.map(& &1.solar_system_id)

    avoidance_list =
      case routes_settings.avoid_edencom do
        true ->
          edencom_solar_systems

        false ->
          []
      end

    avoidance_list =
      case routes_settings.avoid_triglavian do
        true ->
          [avoidance_list | triglavian_solar_systems]

        false ->
          avoidance_list
      end

    avoidance_list =
      case routes_settings.avoid_pochven do
        true ->
          [avoidance_list | pochven_solar_systems]

        false ->
          avoidance_list
      end

    avoidance_list =
      (@default_avoid_systems ++ [routes_settings.avoid | avoidance_list])
      |> List.flatten()
      |> Enum.uniq()

    params =
      %{
        datasource: "tranquility",
        flag: routes_settings.path_type,
        connections: connections,
        avoid: avoidance_list
      }

    case get_all_routes(hubs, origin, params, opts) do
      {:ok, all_routes} ->
        routes =
          all_routes
          |> Enum.map(fn route_info ->
            map_route_info(route_info)
          end)
          |> Enum.filter(fn route_info -> not is_nil(route_info) end)

        {:ok, routes}

      {:error, _reason} = error ->
        error
    end
  end

  defp get_all_routes(hubs, origin, params, opts) do
    cache_key =
      "routes-#{origin}-#{hubs |> Enum.join("-")}-#{:crypto.hash(:sha, :erlang.term_to_binary(params))}"

    case WandererApp.Cache.lookup(cache_key) do
      {:ok, result} when not is_nil(result) ->
        {:ok, result}

      _ ->
        case esi_client().get_routes_custom(hubs, origin, params) do
          {:ok, result} ->
            WandererApp.Cache.insert(
              cache_key,
              result,
              ttl: @routes_ttl
            )

            {:ok, result}

          {:error, error} ->
            error_file_path = save_error_params(origin, hubs, params)

            @logger.error(
              "Error getting custom routes for #{inspect(origin)}: #{inspect(params)}. Params saved to: #{error_file_path}"
            )

            if Keyword.get(opts, :strict, false) do
              {:error, error}
            else
              esi_client().get_routes_eve(hubs, origin, params, opts)
            end
        end
    end
  end

  defp esi_client, do: Application.get_env(:wanderer_app, :esi_client, WandererApp.Esi)

  defp save_error_params(origin, hubs, params) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    filename = "#{timestamp}_route_error_params.json"
    filepath = Path.join([System.tmp_dir!(), filename])

    error_data = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      origin: origin,
      hubs: hubs,
      params: params
    }

    case Jason.encode(error_data, pretty: true) do
      {:ok, json_string} ->
        File.write!(filepath, json_string)
        filepath

      {:error, _reason} ->
        # Fallback: save as Elixir term if JSON encoding fails
        filepath_term = Path.join([System.tmp_dir!(), "#{timestamp}_route_error_params.term"])
        File.write!(filepath_term, inspect(error_data, pretty: true))
        filepath_term
    end
  rescue
    e ->
      @logger.error("Failed to save error params: #{inspect(e)}")
      "error_saving_params"
  end

  defp remove_intersection(pairs_arr) do
    tuples = pairs_arr |> Enum.map(fn x -> {x.first, x.second} end)

    tuples
    |> Enum.reduce([], fn {first, second} = x, acc ->
      if Enum.member?(tuples, {second, first}) do
        acc
      else
        [x | acc]
      end
    end)
    |> Enum.uniq()
    |> Enum.map(fn {first, second} ->
      %{
        first: first,
        second: second
      }
    end)
  end

  defp map_route_info(
         %{
           "origin" => origin,
           "destination" => destination,
           "systems" => result_systems,
           "success" => success
         } = _route_info
       ),
       do:
         map_route_info(%{
           origin: origin,
           destination: destination,
           systems: result_systems,
           success: success
         })

  defp map_route_info(
         %{origin: origin, destination: destination, systems: result_systems, success: success} =
           _route_info
       ) do
    systems =
      case result_systems do
        [] ->
          []

        _ ->
          result_systems |> Enum.reject(fn system_id -> system_id == origin end)
      end

    %{
      has_connection: result_systems != [],
      systems: systems,
      origin: origin,
      destination: destination,
      success: success
    }
  end

  defp map_route_info(_), do: nil
end
