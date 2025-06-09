defmodule WandererApp.Kills.SystemTracker do
  @moduledoc """
  Tracks which EVE Online systems need kill monitoring.
  
  Determines which systems to subscribe to based on active maps
  and their associated solar systems.
  """
  
  require Logger
  
  alias WandererApp.Kills.Config
  
  @doc """
  Gets all system IDs that should be tracked for kills.
  
  Returns a list of unique system IDs from all active maps.
  """
  @spec get_tracked_system_ids() :: {:ok, list(integer())} | {:error, term()}
  def get_tracked_system_ids do
    try do
      cutoff_time = DateTime.utc_now() |> DateTime.add(-Config.active_map_cutoff_minutes(), :minute)
      
      system_ids = cutoff_time
                   |> get_active_maps()
                   |> filter_subscribed_maps()
                   |> extract_system_ids()
                   |> Enum.uniq()
      
      {:ok, system_ids}
    rescue
      error ->
        Logger.error("[SystemTracker] Failed to get tracked systems: #{inspect(error)}")
        {:error, error}
    end
  end
  
  @doc """
  Gets all currently active maps based on the activity cutoff time.
  """
  @spec get_active_maps(DateTime.t()) :: list(map())
  def get_active_maps(cutoff_time) do
    case WandererApp.Api.MapState.get_last_active(cutoff_time) do
      {:ok, []} ->
        # Fallback to most recently updated map if no active maps
        case WandererApp.Maps.get_available_maps() do
          {:ok, maps} ->
            fallback_map = Enum.max_by(maps, & &1.updated_at, fn -> nil end)
            if fallback_map, do: [fallback_map], else: []
          _ -> 
            []
        end
      
      {:ok, active_maps} ->
        active_maps
      
      {:error, reason} ->
        Logger.error("[SystemTracker] Failed to get active maps: #{inspect(reason)}")
        []
    end
  end
  
  @doc """
  Filters maps to only include those with active subscriptions.
  """
  @spec filter_subscribed_maps(list(map())) :: list(map())
  def filter_subscribed_maps(maps) do
    Enum.filter(maps, fn map ->
      case WandererApp.MapSubscriptionRepo.get_active_by_map(map.id) do
        {:ok, _subscription} -> true
        _ -> false
      end
    end)
  end
  
  @doc """
  Extracts all unique system IDs from the given maps.
  """
  @spec extract_system_ids(list(map())) :: list(integer())
  def extract_system_ids(maps) do
    maps
    |> Enum.flat_map(&get_systems_for_map/1)
    |> Enum.uniq()
  end
  
  # Private functions
  
  defp get_systems_for_map(%{id: map_id}) do
    case WandererApp.MapSystemRepo.get_all_by_map(map_id) do
      {:ok, systems} ->
        systems
        |> Enum.map(& &1.solar_system_id)
        |> Enum.reject(&is_nil/1)
      
      {:error, reason} ->
        Logger.error("[SystemTracker] Failed to get systems for map #{map_id}: #{inspect(reason)}")
        []
    end
  end
end