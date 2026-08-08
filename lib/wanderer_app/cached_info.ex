defmodule WandererApp.CachedInfo do
  require Logger

  alias WandererAppWeb.Helpers.APIUtils

  # Courier lock key for the full-table warm-up in `warm_system_static_info_cache/0`.
  # It is never committed to the cache (the fallback returns `{:ignore, _}`), so
  # it cannot collide with the integer solar system ids stored alongside it.
  @static_info_warm_key :__system_static_info_warm__

  @system_static_info_attrs [
    :solar_system_id,
    :region_id,
    :constellation_id,
    :solar_system_name,
    :solar_system_name_lc,
    :constellation_name,
    :region_name,
    :system_class,
    :security,
    :type_description,
    :class_title,
    :is_shattered,
    :effect_name,
    :effect_power,
    :statics,
    :wandering,
    :triglavian_invasion_status,
    :sun_type_id
  ]

  def run(_arg) do
    :ok = cache_trig_systems()
  end

  def get_ship_type(type_id) do
    case Cachex.get(:ship_types_cache, type_id) do
      {:ok, nil} ->
        {:ok, ship_types} = WandererApp.Api.ShipTypeInfo.read()

        ship_types
        |> Enum.each(fn ship_type ->
          Cachex.put(
            :ship_types_cache,
            ship_type.type_id,
            ship_type
            |> Map.take([
              :type_id,
              :group_id,
              :group_name,
              :name,
              :description,
              :mass,
              :capacity,
              :volume
            ])
          )
        end)

        get_ship_type_from_cache_or_api(type_id)

      {:ok, ship_type} ->
        {:ok, ship_type}
    end
  end

  defp get_ship_type_from_cache_or_api(type_id) do
    case Cachex.get(:ship_types_cache, type_id) do
      {:ok, ship_type} when not is_nil(ship_type) ->
        {:ok, ship_type}

      {:ok, nil} ->
        case WandererApp.Esi.get_type_info(type_id) do
          {:ok, info} when not is_nil(info) ->
            ship_type = parse_type(type_id, info)
            {:ok, group_info} = get_group_info(ship_type.group_id)

            {:ok, ship_type_info} =
              WandererApp.Api.ShipTypeInfo |> Ash.create(ship_type |> Map.merge(group_info))

            {:ok,
             ship_type_info
             |> Map.take([
               :type_id,
               :group_id,
               :group_name,
               :name,
               :description,
               :mass,
               :capacity,
               :volume
             ])}

          {:error, reason} ->
            Logger.error("Failed to get ship_type #{type_id} from ESI: #{inspect(reason)}")
            {:ok, nil}

          error ->
            Logger.error("Failed to get ship_type #{type_id} from ESI: #{inspect(error)}")
            {:ok, nil}
        end
    end
  end

  def get_group_info(nil), do: {:ok, nil}

  def get_group_info(group_id) do
    case WandererApp.Esi.get_group_info(group_id) do
      {:ok, info} when not is_nil(info) ->
        {:ok, parse_group(group_id, info)}

      {:error, reason} ->
        Logger.error("Failed to get group_info #{group_id} from ESI: #{inspect(reason)}")
        {:ok, %{group_name: ""}}

      error ->
        Logger.error("Failed to get group_info #{group_id} from ESI: #{inspect(error)}")
        {:ok, %{group_name: ""}}
    end
  end

  def get_system_static_info(nil), do: {:ok, nil}

  def get_system_static_info(solar_system_id) do
    {:ok, solar_system_id} = APIUtils.parse_int(solar_system_id)

    case Cachex.get(:system_static_info_cache, solar_system_id) do
      {:ok, nil} ->
        case warm_system_static_info_cache() do
          :ok ->
            case Cachex.get(:system_static_info_cache, solar_system_id) do
              {:ok, nil} -> {:error, :not_found}
              result -> result
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, system_static_info} ->
        {:ok, system_static_info}

      {:error, reason} ->
        Logger.error("Failed to get system static info from cache: #{inspect(reason)}")
        {:error, :cache_error}
    end
  end

  # A single cache miss repopulates the WHOLE table, so N concurrent misses used
  # to run N full `MapSolarSystem.read/0` scans plus N row-by-row rewrites of the
  # same data. That is the normal case, not an edge case: `:system_static_info_cache`
  # has a 4h TTL (application.ex) and route hydration fans out over every system
  # in a route at `schedulers_online() * 4` concurrency, so every restart and
  # every TTL rollover produced a stampede — and each of those scans is what made
  # a single lookup slow enough to blow a `Task.async_stream` timeout.
  #
  # `Cachex.fetch/4` routes the fallback through Cachex's Courier, which runs it
  # at most once at a time per key and hands every concurrent caller the same
  # result. Returning `{:ignore, _}` means the marker key is never written, so
  # sequential behaviour is unchanged: a later miss still triggers a fresh scan
  # and still picks up a newly inserted system immediately. Only *simultaneous*
  # scans are collapsed.
  defp warm_system_static_info_cache do
    # Cachex runs the fallback in a Courier-owned process, not the caller's, and
    # that process starts with an empty dictionary. `$callers` has to be carried
    # across by hand or the read loses the caller's context — most visibly under
    # `Ecto.Adapters.SQL.Sandbox` ownership mode, where an unlinked process has
    # no checked-out connection and every warm-up would fail with
    # `DBConnection.OwnershipError`.
    callers = [self() | Process.get(:"$callers", [])]

    result =
      Cachex.fetch(:system_static_info_cache, @static_info_warm_key, fn _key ->
        Process.put(:"$callers", callers)

        case WandererApp.Api.MapSolarSystem.read() do
          {:ok, systems} ->
            # A discarded write is worse here than anywhere else: the caller
            # re-reads the key straight after this returns, so a silently failed
            # put surfaces as `{:error, :not_found}` — "this system does not
            # exist" — for a system that does. Halt on the first failure rather
            # than grinding through thousands more writes into a cache that has
            # already told us it is not accepting them.
            Enum.reduce_while(systems, {:ignore, :ok}, fn system, acc ->
              case Cachex.put(
                     :system_static_info_cache,
                     system.solar_system_id,
                     Map.take(system, @system_static_info_attrs)
                   ) do
                {:ok, true} ->
                  {:cont, acc}

                error ->
                  Logger.error(
                    "Failed to cache static info for solar system " <>
                      "#{system.solar_system_id}: #{inspect(error)}"
                  )

                  {:halt, {:ignore, {:error, :cache_error}}}
              end
            end)

          {:error, reason} ->
            Logger.error("Failed to read solar systems from API: #{inspect(reason)}")
            {:ignore, {:error, :api_error}}
        end
      end)

    case result do
      {:ignore, outcome} ->
        outcome

      # Defensive: `{:ignore, _}` above is the only path that can populate this,
      # so anything else means Cachex itself failed (dead cache, etc.).
      {:error, reason} ->
        Logger.error("Failed to warm system static info cache: #{inspect(reason)}")
        {:error, :cache_error}
    end
  end

  def get_system_static_info!(solar_system_id) do
    case get_system_static_info(solar_system_id) do
      {:ok, system_static_info} ->
        system_static_info

      error ->
        Logger.error("Error loading system static info: #{inspect(error)}")
        nil
    end
  end

  def get_wormhole_types() do
    case WandererApp.Cache.lookup(:wormhole_types) do
      {:ok, nil} ->
        wormhole_types = WandererApp.EveDataService.load_wormhole_types()

        cache_items(wormhole_types, :wormhole_types)

        {:ok, wormhole_types}

      {:ok, wormhole_types} ->
        {:ok, wormhole_types}
    end
  end

  def get_solar_system_jumps() do
    case WandererApp.Cache.lookup(:solar_system_jumps) do
      {:ok, nil} ->
        {:ok, data} = WandererApp.Api.MapSolarSystemJumps.read()

        cache_items(data, :solar_system_jumps)

        {:ok, data}

      {:ok, data} ->
        {:ok, data}
    end
  end

  def get_solar_system_jump(from_solar_system_id, to_solar_system_id) do
    # Create normalized cache key (smaller ID first for bidirectional lookup)
    {id1, id2} =
      if from_solar_system_id < to_solar_system_id do
        {from_solar_system_id, to_solar_system_id}
      else
        {to_solar_system_id, from_solar_system_id}
      end

    cache_key = "jump_#{id1}_#{id2}"

    case WandererApp.Cache.lookup(cache_key) do
      {:ok, nil} ->
        # Build jump index if not exists
        build_jump_index()
        WandererApp.Cache.lookup(cache_key)

      result ->
        result
    end
  end

  defp parse_group(group_id, group) do
    %{
      group_id: group_id,
      group_name: Map.get(group, "name")
    }
  end

  defp parse_type(type_id, type) do
    %{
      type_id: type_id,
      name: Map.get(type, "name"),
      description: Map.get(type, "description"),
      group_id: Map.get(type, "group_id"),
      mass: "#{Map.get(type, "mass")}",
      capacity: "#{Map.get(type, "capacity")}",
      volume: "#{Map.get(type, "volume")}"
    }
  end

  defp build_jump_index() do
    case get_solar_system_jumps() do
      {:ok, jumps} ->
        jumps
        |> Enum.each(fn jump ->
          {id1, id2} =
            if jump.from_solar_system_id < jump.to_solar_system_id do
              {jump.from_solar_system_id, jump.to_solar_system_id}
            else
              {jump.to_solar_system_id, jump.from_solar_system_id}
            end

          cache_key = "jump_#{id1}_#{id2}"
          WandererApp.Cache.put(cache_key, jump)
        end)

      _ ->
        :error
    end
  end

  def get_wormhole_types!() do
    case get_wormhole_types() do
      {:ok, wormhole_types} ->
        wormhole_types

      error ->
        Logger.error("Error loading wormhole types: #{inspect(error)}")
        error
    end
  end

  def get_wormhole_classes() do
    case WandererApp.Cache.lookup(:wormhole_classes) do
      {:ok, nil} ->
        wormhole_classes = WandererApp.EveDataService.load_wormhole_classes()

        cache_items(wormhole_classes, :wormhole_classes)

        {:ok, wormhole_classes}

      {:ok, wormhole_classes} ->
        {:ok, wormhole_classes}
    end
  end

  def get_wormhole_classes!() do
    case get_wormhole_classes() do
      {:ok, wormhole_classes} ->
        wormhole_classes

      error ->
        Logger.error("Error loading wormhole classes: #{inspect(error)}")
        error
    end
  end

  def get_effects() do
    case WandererApp.Cache.lookup(:effects) do
      {:ok, nil} ->
        effects = WandererApp.EveDataService.load_effects()

        cache_items(effects, :effects)

        {:ok, effects}

      {:ok, effects} ->
        {:ok, effects}
    end
  end

  def get_effects!() do
    case get_effects() do
      {:ok, effects} ->
        effects

      error ->
        Logger.error("Error loading effects: #{inspect(error)}")
        error
    end
  end

  def get_wh_class_a_systems() do
    case WandererApp.Cache.lookup(:wh_class_a_systems) do
      {:ok, nil} ->
        {:ok, wh_class_a} = WandererApp.Api.MapSolarSystem.get_wh_class_a()

        wh_class_a_ids = wh_class_a |> Enum.map(& &1.solar_system_id)

        cache_items(wh_class_a_ids, :wh_class_a_systems)

        {:ok, wh_class_a_ids}

      {:ok, wh_class_a_ids} ->
        {:ok, wh_class_a_ids}
    end
  end

  def get_trig_systems() do
    case WandererApp.Cache.lookup(:trig_systems) do
      {:ok, nil} ->
        {:ok, trig_systems} = WandererApp.Api.MapSolarSystem.get_trig_systems()

        cache_items(trig_systems, :trig_systems)

        {:ok, trig_systems}

      {:ok, trig_systems} ->
        {:ok, trig_systems}
    end
  end

  defp cache_trig_systems() do
    trig_systems = WandererApp.Api.MapSolarSystem.get_trig_systems!()

    trig_systems
    |> Enum.filter(fn s -> s.triglavian_invasion_status == "Final" end)
    |> Enum.map(& &1.solar_system_id)
    |> cache_items(:pochven_solar_systems)

    trig_systems
    |> Enum.filter(fn s -> s.triglavian_invasion_status == "Triglavian" end)
    |> Enum.map(& &1.solar_system_id)
    |> cache_items(:triglavian_solar_systems)

    trig_systems
    |> Enum.filter(fn s -> s.triglavian_invasion_status == "Edencom" end)
    |> Enum.map(& &1.solar_system_id)
    |> cache_items(:edencom_solar_systems)
  end

  defp cache_items([], _list_name), do: :ok

  defp cache_items(items, list_name),
    do: WandererApp.Cache.put(list_name, items, ttl: :timer.hours(4))
end
