defmodule WandererApp.Kills.PubSubSubscriber do
  @moduledoc """
  Subscribes to WandererKills service PubSub topics for real-time updates.

  Listens to kill updates from the WandererKills service and broadcasts them
  to the appropriate maps using the existing broadcast patterns.
  """

  use GenServer
  require Logger

  alias WandererApp.Kills.DataAdapter

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    # Subscribe to global kill updates from WandererKills service
    # Note: These topic names match the WandererKills service PubSub topics
    subscribe_to_wanderer_kills_topics()

    Logger.info("[PubSubSubscriber] Started and subscribed to WandererKills topics")
    {:ok, state}
  end

  # Handle kill count updates from WandererKills service
  @impl true
  def handle_info(%{type: :kill_count_update, solar_system_id: system_id, count: count}, state) do
    Logger.debug(fn ->
      "[PubSubSubscriber] Received kill count update => system_id=#{system_id}, count=#{count}"
    end)

    # Update local cache for backward compatibility with existing code
    update_local_kill_count_cache(system_id, count)

    # Find all maps containing this system and broadcast updates
    broadcast_kill_count_to_maps(system_id, count)

    {:noreply, state}
  end

  # Handle detailed kill updates from WandererKills service
  @impl true
  def handle_info(%{type: :detailed_kill_update, solar_system_id: system_id, kills: kills}, state) do
    Logger.debug(fn ->
      "[PubSubSubscriber] Received detailed kill update => system_id=#{system_id}, kills=#{length(kills)}"
    end)

    # Adapt the kill data format to match frontend expectations
    adapted_kills = DataAdapter.adapt_kills_list(kills)

    # Find all maps containing this system and broadcast detailed updates
    broadcast_detailed_kills_to_maps(system_id, adapted_kills)

    {:noreply, state}
  end

  # Handle bulk kill updates (multiple systems at once)
  @impl true
  def handle_info(%{type: :bulk_kill_update, systems_kills: systems_kills}, state) do
    Logger.debug(fn ->
      "[PubSubSubscriber] Received bulk kill update => #{map_size(systems_kills)} systems"
    end)

    # Adapt all kills data
    adapted_systems_kills = DataAdapter.adapt_systems_kills(systems_kills)

    # Broadcast to each affected map
    Enum.each(adapted_systems_kills, fn {system_id, kills} ->
      broadcast_detailed_kills_to_maps(system_id, kills)
    end)

    {:noreply, state}
  end

  # Handle service status updates
  @impl true
  def handle_info(%{type: :service_status, status: status}, state) do
    Logger.info("[PubSubSubscriber] WandererKills service status: #{status}")
    {:noreply, state}
  end

  # Catch any other messages
  @impl true
  def handle_info(message, state) do
    Logger.debug(fn -> "[PubSubSubscriber] Received unhandled message: #{inspect(message)}" end)
    {:noreply, state}
  end

  # Private functions

  defp subscribe_to_wanderer_kills_topics() do
    # Subscribe to the main topics from WandererKills service
    # These topic names should match what the WandererKills service publishes to

    # Global kill count updates
    Phoenix.PubSub.subscribe(WandererKills.PubSub, "zkb:kills:updated")

    # Global detailed kill updates
    Phoenix.PubSub.subscribe(WandererKills.PubSub, "zkb:detailed_kills:updated")

    # Service status updates
    Phoenix.PubSub.subscribe(WandererKills.PubSub, "zkb:service:status")

    Logger.debug("[PubSubSubscriber] Subscribed to WandererKills PubSub topics")
  rescue
    error ->
      Logger.error("[PubSubSubscriber] Failed to subscribe to WandererKills topics: #{inspect(error)}")
      # Continue anyway - topics might not be available yet
  end

  defp update_local_kill_count_cache(system_id, count) do
    # Update the local cache to maintain compatibility with existing code
    # that might still check the cache directly
    WandererApp.Cache.put("zkb_kills_#{system_id}", count, ttl: :timer.hours(1))
  end

  defp broadcast_kill_count_to_maps(system_id, count) do
    # Find all active maps containing this system
    active_maps_with_system = get_active_maps_containing_system(system_id)

    Enum.each(active_maps_with_system, fn map_id ->
      payload = %{system_id => count}

      try do
        WandererApp.Map.Server.Impl.broadcast!(map_id, :kills_updated, payload)
        Logger.debug(fn ->
          "[PubSubSubscriber] Broadcasted kill count to map_id=#{map_id}, system_id=#{system_id}, count=#{count}"
        end)
      rescue
        error ->
          Logger.warning("[PubSubSubscriber] Failed to broadcast to map #{map_id}: #{inspect(error)}")
      end
    end)
  end

  defp broadcast_detailed_kills_to_maps(system_id, kills) do
    # Find all active maps containing this system with active subscriptions
    active_maps_with_subscriptions = get_active_maps_with_subscriptions_containing_system(system_id)

    Enum.each(active_maps_with_subscriptions, fn map_id ->
      payload = %{system_id => kills}

      try do
        WandererApp.Map.Server.Impl.broadcast!(map_id, :detailed_kills_updated, payload)
        Logger.debug(fn ->
          "[PubSubSubscriber] Broadcasted detailed kills to map_id=#{map_id}, system_id=#{system_id}, kills=#{length(kills)}"
        end)
      rescue
        error ->
          Logger.warning("[PubSubSubscriber] Failed to broadcast detailed kills to map #{map_id}: #{inspect(error)}")
      end
    end)
  end

  defp get_active_maps_containing_system(system_id) do
    WandererApp.Map.RegistryHelper.list_all_maps()
    |> Enum.filter(fn %{id: map_id} ->
      # Check if map is started
      WandererApp.Cache.lookup!("map_#{map_id}:started", false)
    end)
    |> Enum.filter(fn %{id: map_id} ->
      # Check if map contains this system
      case WandererApp.Map.get_map(map_id) do
        {:ok, %{systems: systems}} when is_map_key(systems, system_id) -> true
        _ -> false
      end
    end)
    |> Enum.map(& &1.id)
  end

  defp get_active_maps_with_subscriptions_containing_system(system_id) do
    get_active_maps_containing_system(system_id)
    |> Enum.filter(fn map_id ->
      # Only broadcast detailed kills to maps with active subscriptions
      case WandererApp.Map.is_subscription_active?(map_id) do
        {:ok, true} -> true
        _ -> false
      end
    end)
  end
end
