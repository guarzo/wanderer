defmodule WandererApp.Kills.Subscription.Manager do
  @moduledoc """
  Manages system subscriptions for kills WebSocket service.
  """

  require Logger

  @type subscriptions :: MapSet.t(integer())

  @spec subscribe_systems(subscriptions(), [integer()]) :: {subscriptions(), [integer()]}
  def subscribe_systems(current_systems, system_ids) when is_list(system_ids) do
    system_set = MapSet.new(system_ids)
    new_systems = MapSet.difference(system_set, current_systems)
    new_list = MapSet.to_list(new_systems)
    
    if new_list != [] do
      Logger.debug("[KillsClient] Subscribing to #{length(new_list)} systems")
    end
    
    {MapSet.union(current_systems, new_systems), new_list}
  end

  @spec unsubscribe_systems(subscriptions(), [integer()]) :: {subscriptions(), [integer()]}
  def unsubscribe_systems(current_systems, system_ids) when is_list(system_ids) do
    system_set = MapSet.new(system_ids)
    systems_to_remove = MapSet.intersection(current_systems, system_set)
    removed_list = MapSet.to_list(systems_to_remove)
    
    if removed_list != [] do
      Logger.debug("[KillsClient] Unsubscribing from #{length(removed_list)} systems")
    end
    
    {MapSet.difference(current_systems, systems_to_remove), removed_list}
  end

  @spec sync_with_server(pid() | nil, [integer()], [integer()]) :: :ok
  def sync_with_server(nil, _to_subscribe, _to_unsubscribe), do: :ok

  def sync_with_server(socket_pid, to_subscribe, to_unsubscribe) do
    if to_unsubscribe != [], do: send(socket_pid, {:unsubscribe_systems, to_unsubscribe})
    if to_subscribe != [], do: send(socket_pid, {:subscribe_systems, to_subscribe})
    :ok
  end

  @spec resubscribe_all(pid(), subscriptions()) :: :ok
  def resubscribe_all(socket_pid, subscribed_systems) do
    system_list = MapSet.to_list(subscribed_systems)
    
    if system_list != [] do
      Logger.info("[KillsClient] Resubscribing to #{length(system_list)} systems")
      send(socket_pid, {:subscribe_systems, system_list})
    end
    
    :ok
  end

  @spec get_stats(subscriptions()) :: map()
  def get_stats(subscribed_systems) do
    %{
      total_subscribed: MapSet.size(subscribed_systems),
      subscribed_systems: MapSet.to_list(subscribed_systems) |> Enum.sort()
    }
  end

  @spec cleanup_subscriptions(subscriptions()) :: {subscriptions(), [integer()]}
  def cleanup_subscriptions(subscribed_systems) do
    systems_to_check = MapSet.to_list(subscribed_systems)
    valid_systems = Enum.filter(systems_to_check, &system_has_active_maps?/1)
    invalid_systems = systems_to_check -- valid_systems
    
    if invalid_systems != [] do
      Logger.debug("[KillsClient] Removing #{length(invalid_systems)} orphaned subscriptions")
      {MapSet.new(valid_systems), invalid_systems}
    else
      {subscribed_systems, []}
    end
  end

  defp system_has_active_maps?(system_id) do
    case WandererApp.Maps.get_available_maps() do
      {:ok, maps} ->
        Enum.any?(maps, fn map ->
          case WandererApp.Repositories.MapSystemRepo.get_by_map_and_solar_system_id(map.id, system_id) do
            {:ok, _system} -> true
            _ -> false
          end
        end)
      _ -> false
    end
  end
end
