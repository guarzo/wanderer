defmodule WandererApp.Kills.Subscription.MapIntegration do
  @moduledoc """
  Handles integration between the kills WebSocket service and the map system.
  
  Manages automatic subscription updates when maps change and provides
  utilities for syncing kill data with map systems.
  """
  
  require Logger
  
  @doc """
  Handles updates when map systems change.
  
  Determines which systems to subscribe/unsubscribe based on the update.
  """
  @spec handle_map_systems_updated([integer()], MapSet.t(integer())) :: {:ok, [integer()], [integer()]}
  def handle_map_systems_updated(system_ids, current_subscriptions) when is_list(system_ids) do
    Logger.info("[MapIntegration] 🗺️ Processing map systems update for #{length(system_ids)} systems")
    
    # Find all unique systems across all maps
    all_map_systems = get_all_map_systems()
    
    # Systems to subscribe: in the update and in active maps but not currently subscribed
    new_systems = system_ids
    |> Enum.filter(&(&1 in all_map_systems))
    |> Enum.reject(&MapSet.member?(current_subscriptions, &1))
    
    # Systems to unsubscribe: currently subscribed but no longer in any active map
    obsolete_systems = current_subscriptions
    |> MapSet.to_list()
    |> Enum.reject(&(&1 in all_map_systems))
    
    if length(new_systems) > 0 or length(obsolete_systems) > 0 do
      Logger.info("[MapIntegration] 📊 Changes detected - Subscribe: #{length(new_systems)}, Unsubscribe: #{length(obsolete_systems)}")
    end
    
    {:ok, new_systems, obsolete_systems}
  end
  
  @doc """
  Gets all unique system IDs across all active maps.
  """
  @spec get_all_map_systems() :: MapSet.t(integer())
  def get_all_map_systems do
    {:ok, maps} = WandererApp.Maps.get_available_maps()
    
    all_systems = Enum.reduce(maps, MapSet.new(), fn map, acc ->
      case get_map_system_ids(map.id) do
        {:ok, system_ids} ->
          MapSet.union(acc, MapSet.new(system_ids))
        _ ->
          acc
      end
    end)
    
    Logger.debug("[MapIntegration] Found #{MapSet.size(all_systems)} unique systems across #{length(maps)} maps")
    all_systems
  end
  
  @doc """
  Gets all system IDs for a specific map.
  """
  @spec get_map_system_ids(String.t()) :: {:ok, [integer()]} | {:error, term()}
  def get_map_system_ids(map_id) do
    case WandererApp.MapSystemRepo.get_all_by_map(map_id) do
      {:ok, systems} ->
        system_ids = Enum.map(systems, & &1.solar_system_id)
        {:ok, system_ids}
      error ->
        Logger.error("[MapIntegration] Failed to get systems for map #{map_id}: #{inspect(error)}")
        error
    end
  end
  
  @doc """
  Checks if a system is in any active map.
  """
  @spec system_in_active_map?(integer()) :: boolean()
  def system_in_active_map?(system_id) do
    {:ok, maps} = WandererApp.Maps.get_available_maps()
    
    Enum.any?(maps, fn map ->
      case WandererApp.MapSystemRepo.get_by_map_and_solar_system_id(map.id, system_id) do
        {:ok, _system} -> true
        _ -> false
      end
    end)
  end
  
  @doc """
  Broadcasts kill data to relevant map servers.
  """
  @spec broadcast_kill_to_maps(map()) :: :ok
  def broadcast_kill_to_maps(kill_data) do
    system_id = kill_data["solar_system_id"]
    
    # Find all maps containing this system
    {:ok, maps} = WandererApp.Maps.get_available_maps()
    
    Enum.each(maps, fn map ->
      case WandererApp.MapSystemRepo.get_by_map_and_solar_system_id(map.id, system_id) do
        {:ok, _system} ->
          # Broadcast to this map's topic
          Phoenix.PubSub.broadcast(
            WandererApp.PubSub,
            "map:#{map.id}",
            {:map_kill, kill_data}
          )
          
        _ ->
          # System not in this map
          :ok
      end
    end)
    
    :ok
  end
  
  @doc """
  Gets subscription statistics grouped by map.
  """
  @spec get_map_subscription_stats(MapSet.t(integer())) :: map()
  def get_map_subscription_stats(subscribed_systems) do
    {:ok, maps} = WandererApp.Maps.get_available_maps()
    
    stats = Enum.map(maps, fn map ->
      case get_map_system_ids(map.id) do
        {:ok, system_ids} ->
          subscribed_count = system_ids
          |> Enum.filter(&MapSet.member?(subscribed_systems, &1))
          |> length()
          
          %{
            map_id: map.id,
            map_name: map.name,
            total_systems: length(system_ids),
            subscribed_systems: subscribed_count,
            subscription_rate: if(length(system_ids) > 0, do: subscribed_count / length(system_ids) * 100, else: 0)
          }
          
        _ ->
          %{
            map_id: map.id,
            map_name: map.name,
            error: "Failed to load systems"
          }
      end
    end)
    
    %{
      maps: stats,
      total_subscribed: MapSet.size(subscribed_systems),
      total_maps: length(maps)
    }
  end
  
  @doc """
  Handles map deletion by returning systems to unsubscribe.
  """
  @spec handle_map_deleted(String.t(), MapSet.t(integer())) :: [integer()]
  def handle_map_deleted(map_id, current_subscriptions) do
    Logger.info("[MapIntegration] 🗑️ Handling map deletion: #{map_id}")
    
    # Get systems from the deleted map
    case get_map_system_ids(map_id) do
      {:ok, deleted_systems} ->
        # Only unsubscribe systems that aren't in other maps
        deleted_systems
        |> Enum.filter(&MapSet.member?(current_subscriptions, &1))
        |> Enum.reject(&system_in_active_map?/1)
        
      _ ->
        []
    end
  end
end