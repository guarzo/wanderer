defmodule WandererApp.Kills.PubSubSubscriber do
  @moduledoc """
  Subscribes to kill updates from WandererKills service via webhooks.
  This replaces direct PubSub subscription since containers can't share PubSub registries.
  """

  use GenServer
  require Logger

  alias WandererApp.Kills.WandererKillsClient

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    # Instead of subscribing to PubSub, register a webhook with WandererKills service
    schedule_webhook_registration()
    Logger.info("[PubSubSubscriber] Started webhook-based subscription system")
    {:ok, state}
  end

  @impl true
  def handle_info(:register_webhook, state) do
    Logger.debug("[PubSubSubscriber] Attempting webhook registration...")

    case register_webhook() do
      :ok ->
        Logger.info("[PubSubSubscriber] Successfully registered webhook with WandererKills")
        # No need to re-register unless something changes
      {:error, reason} ->
        Logger.warning("[PubSubSubscriber] Failed to register webhook: #{inspect(reason)}")
        # Retry registration in 10 seconds
        schedule_webhook_registration(10_000)
      :no_systems ->
        Logger.debug("[PubSubSubscriber] No systems to track, retrying in 30 seconds...")
        schedule_webhook_registration(30_000)
    end
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.debug(fn -> "[PubSubSubscriber] Received unhandled message: #{inspect(message)}" end)
    {:noreply, state}
  end

    # Handle webhook calls from WandererKills service
  def handle_webhook(%{"type" => "kill_count_update"} = payload) do
    %{"data" => %{"solar_system_id" => system_id, "count" => count}} = payload

    Logger.info("[PubSubSubscriber] 🔴 Kill count update => system_id=#{system_id}, count=#{count}")

    broadcast_kill_count_to_maps(system_id, count)
  end

    def handle_webhook(%{"type" => "detailed_kill_update"} = payload) do
    %{"data" => %{"solar_system_id" => system_id, "kills" => kills}} = payload

    Logger.info("[PubSubSubscriber] ⚔️  Detailed kill update => system_id=#{system_id}, kills=#{length(kills)}")

    broadcast_detailed_kills_to_maps(system_id, kills)
  end

  def handle_webhook(%{"type" => "kill_update"} = payload) do
    # Handle single kill updates
    case payload do
      %{"data" => %{"solar_system_id" => system_id, "kill" => kill}} ->
        Logger.info("[PubSubSubscriber] ⚔️  Single kill update => system_id=#{system_id}")
        broadcast_detailed_kills_to_maps(system_id, [kill])

      %{"data" => %{"solar_system_id" => system_id, "kills" => kills}} ->
        Logger.info("[PubSubSubscriber] ⚔️  Kill batch update => system_id=#{system_id}, kills=#{length(kills)}")
        broadcast_detailed_kills_to_maps(system_id, kills)

      _ ->
        Logger.warning("[PubSubSubscriber] ⚠️  Unrecognized kill_update format: #{inspect(payload)}")
    end
  end

  def handle_webhook(%{"type" => "preload_kill_update"} = payload) do
    # Handle preload updates (background data loading)
    case payload do
      %{"data" => %{"solar_system_id" => system_id, "kills" => kills}} ->
        Logger.info("[PubSubSubscriber] 🔄 Preload update => system_id=#{system_id}, kills=#{length(kills)}")
        broadcast_detailed_kills_to_maps(system_id, kills)

      _ ->
        Logger.warning("[PubSubSubscriber] ⚠️  Unrecognized preload_kill_update format: #{inspect(payload)}")
    end
  end

  def handle_webhook(%{"type" => "bulk_kill_update"} = payload) do
    %{"data" => %{"systems_kills" => systems_kills}} = payload

    total_kills = systems_kills |> Map.values() |> List.flatten() |> length()
    Logger.info("[PubSubSubscriber] 📦 Bulk kill update => #{map_size(systems_kills)} systems, #{total_kills} total kills")

    Enum.each(systems_kills, fn {system_id, kills} ->
      broadcast_detailed_kills_to_maps(String.to_integer(system_id), kills)
    end)
  end

  def handle_webhook(payload) do
    Logger.debug(fn -> "[PubSubSubscriber] Received unhandled webhook: #{inspect(payload)}" end)
  end



  defp schedule_webhook_registration(delay \\ 1000) do
    Process.send_after(self(), :register_webhook, delay)
  end

      defp register_webhook do
    # Register webhook with WandererKills service
    subscriber_id = "wanderer_main_app"
    callback_url = webhook_callback_url()

    # Get all system IDs we want to track (could be from active maps)
    system_ids = get_tracked_system_ids()

    Logger.debug("[PubSubSubscriber] Found #{length(system_ids)} systems to track: #{inspect(Enum.take(system_ids, 5))}...")

    if length(system_ids) > 0 do
      # Clean up any existing subscriptions first to avoid duplicates
      case WandererKillsClient.unsubscribe_from_kills(subscriber_id) do
        :ok -> Logger.debug("[PubSubSubscriber] Cleaned up existing subscriptions")
        {:error, _} -> Logger.debug("[PubSubSubscriber] No existing subscriptions to clean up")
      end

      # Create fresh subscription
      case WandererKillsClient.subscribe_to_kills(subscriber_id, system_ids, callback_url) do
        {:ok, _data} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :no_systems
    end
  end

  defp webhook_callback_url do
    # This would be the URL that WandererKills can call back to
    # Use host.docker.internal for container-to-container communication
    base_url = System.get_env("WANDERER_APP_URL", "http://host.docker.internal:4444")
    "#{base_url}/api/webhooks/kills"
  end

    defp get_tracked_system_ids do
    # Use the same logic as KillsPreloader to get active maps and their systems
    try do
      # Get last-active maps (like KillsPreloader does)
      cutoff_time = DateTime.utc_now() |> DateTime.add(-30, :minute)

      last_active_maps =
        case WandererApp.Api.MapState.get_last_active(cutoff_time) do
          {:ok, []} ->
            Logger.debug("[PubSubSubscriber] No last-active maps, using fallback...")
            case WandererApp.Maps.get_available_maps() do
              {:ok, maps} ->
                fallback_map = Enum.max_by(maps, & &1.updated_at, fn -> nil end)
                if fallback_map, do: [fallback_map], else: []
              _ -> []
            end
          {:ok, maps} -> maps
          {:error, reason} ->
            Logger.warning("[PubSubSubscriber] Could not load last-active maps: #{inspect(reason)}")
            []
        end

      Logger.debug("[PubSubSubscriber] Found #{length(last_active_maps)} last-active maps")

      # Filter for maps with active subscriptions (like KillsPreloader does)
      active_maps_with_subscription =
        last_active_maps
        |> Enum.filter(fn map ->
          {:ok, is_subscription_active} = map.id |> WandererApp.Map.is_subscription_active?()
          is_subscription_active
        end)

      Logger.debug("[PubSubSubscriber] #{length(active_maps_with_subscription)} maps have active subscriptions")

      # Get visible systems from those maps (like KillsPreloader does)
      system_ids =
        active_maps_with_subscription
        |> Enum.flat_map(fn map_record ->
          the_map_id = Map.get(map_record, :map_id) || Map.get(map_record, :id)

          case WandererApp.MapSystemRepo.get_visible_by_map(the_map_id) do
            {:ok, systems} ->
              Logger.debug("[PubSubSubscriber] Map #{the_map_id} has #{length(systems)} visible systems")
              Enum.map(systems, fn sys -> sys.solar_system_id end)
            {:error, reason} ->
              Logger.debug("[PubSubSubscriber] get_visible_by_map failed for map #{the_map_id}: #{inspect(reason)}")
              []
          end
        end)
        |> Enum.uniq()

      Logger.debug("[PubSubSubscriber] Total unique systems: #{length(system_ids)}")
      system_ids
    rescue
      error ->
        Logger.warning("[PubSubSubscriber] Error getting tracked systems: #{inspect(error)}")
        []
    end
  end

  defp broadcast_kill_count_to_maps(system_id, count) do
    WandererApp.Map.RegistryHelper.list_all_maps()
    |> Enum.each(fn %{id: map_id} ->
      try do
        case WandererApp.Map.get_map(map_id) do
          {:ok, %{systems: systems}} ->
            if Map.has_key?(systems, system_id) do
              WandererApp.Map.Server.Impl.broadcast!(map_id, :kills_updated, %{system_id => count})
              Logger.debug(fn ->
                "[PubSubSubscriber] Broadcasted kill count to map_id=#{map_id}, system_id=#{system_id}, count=#{count}"
              end)
            end
          _ -> :ok
        end
      rescue
        error ->
          Logger.warning("[PubSubSubscriber] Failed to broadcast to map #{map_id}: #{inspect(error)}")
      end
    end)
  end

  defp broadcast_detailed_kills_to_maps(system_id, kills) do
    # Adapt the kills to frontend format if needed
    adapted_kills = WandererApp.Kills.DataAdapter.adapt_kills_list(kills)

    WandererApp.Map.RegistryHelper.list_all_maps()
    |> Enum.each(fn %{id: map_id} ->
      try do
        case WandererApp.Map.get_map(map_id) do
          {:ok, %{systems: systems}} ->
            if Map.has_key?(systems, system_id) do
              WandererApp.Map.Server.Impl.broadcast!(map_id, :detailed_kills_updated, %{system_id => adapted_kills})
              Logger.debug(fn ->
                "[PubSubSubscriber] Broadcasted #{length(adapted_kills)} kills to map_id=#{map_id}, system_id=#{system_id}"
              end)
            end
          _ -> :ok
        end
      rescue
        error ->
          Logger.warning("[PubSubSubscriber] Failed to broadcast detailed kills to map #{map_id}: #{inspect(error)}")
      end
    end)
  end
end
