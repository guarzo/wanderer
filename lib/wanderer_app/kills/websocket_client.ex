defmodule WandererApp.Kills.WebSocketClient do
  @moduledoc """
  WebSocket client for WandererKills service using phoenix_gen_socket_client.
  Handles real-time killmail updates and broadcasting to map channels.
  """

  use GenServer
  require Logger

  alias Phoenix.Channels.GenSocketClient
  alias WandererApp.Kills.DataAdapter

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec subscribe_to_systems([integer()]) :: :ok
  def subscribe_to_systems(system_ids) do
    GenServer.cast(__MODULE__, {:subscribe_systems, system_ids})
  end

  @spec unsubscribe_from_systems([integer()]) :: :ok
  def unsubscribe_from_systems(system_ids) do
    GenServer.cast(__MODULE__, {:unsubscribe_systems, system_ids})
  end

  @spec get_status() :: {:ok, map()} | {:error, term()}
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Notify the WebSocket client that map systems have been updated.
  This triggers a refresh of subscriptions to add/remove systems as needed.
  """
  @spec notify_map_systems_updated([integer()]) :: :ok
  def notify_map_systems_updated(system_ids) when is_list(system_ids) do
    send(__MODULE__, {:map_systems_updated, system_ids})
    :ok
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    # Trap exits so GenSocketClient failures don't kill this GenServer
    Process.flag(:trap_exit, true)

    server_url = Keyword.get(opts, :server_url, Application.get_env(:wanderer_app, :wanderer_kills_base_url, "ws://wanderer-kills:4004"))

    # Subscribe to all active maps to get notified when systems are added
    subscribe_to_map_events()

    state = %{
      server_url: server_url,
      socket_pid: nil,
      connected: false,
      subscribed_systems: MapSet.new(),
      retry_count: 0,
      max_retries: 3,
      cycle_count: 0
    }

        Logger.info("[WandererKills.WebSocketClient] Starting WebSocket client for #{server_url}")
    # Wait before trying to connect to avoid rapid startup loops
    Process.send_after(self(), :connect, 30_000)

    # Schedule hourly cleanup of unused subscriptions
    schedule_subscription_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    Logger.info("[WandererKills.WebSocketClient] 🔄 Attempting to connect to #{state.server_url}")

    try do
      result = start_socket_client(state)

      case result do
        {:ok, socket_pid} ->
          Logger.info("[WandererKills.WebSocketClient] ✅ Connected successfully!")

          new_state = %{state | socket_pid: socket_pid, connected: true, retry_count: 0, cycle_count: 0}
          # Note: subscription will be triggered when we receive :channel_joined message

          {:noreply, new_state}

        {:error, reason} ->
          Logger.warning("[WandererKills.WebSocketClient] ⚠️  Connection failed: #{inspect(reason)} - will retry")
          schedule_reconnect(state)
      end
    rescue
      error ->
        Logger.error("[WandererKills.WebSocketClient] 💥 Exception in handle_info(:connect): #{inspect(error)}")
        schedule_reconnect(state)
    catch
      :exit, reason ->
        Logger.error("[WandererKills.WebSocketClient] 💥 Exit in handle_info(:connect): #{inspect(reason)}")
        schedule_reconnect(state)
      error_type, reason ->
        Logger.error("[WandererKills.WebSocketClient] 💥 Error in handle_info(:connect): #{error_type} - #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

    def handle_info({:channel_joined, socket_pid, initial_systems}, state) do
    Logger.info("[WandererKills.WebSocketClient] 📡 Channel joined successfully with #{length(initial_systems)} initial systems")

    # Track the initially subscribed systems
    new_state = %{state | socket_pid: socket_pid, subscribed_systems: MapSet.new(initial_systems)}
    {:noreply, new_state}
  end



  def handle_info({:DOWN, _ref, :process, socket_pid, reason}, %{socket_pid: socket_pid} = state) do
    Logger.warning("[WandererKills.WebSocketClient] 📡 WebSocket process died: #{inspect(reason)}")
    new_state = %{state | socket_pid: nil, connected: false}
    schedule_reconnect(new_state)
  end

  def handle_info({:EXIT, pid, reason}, state) do
    if pid == state.socket_pid do
      Logger.warning("[WandererKills.WebSocketClient] 🚪 Current WebSocket process died: #{inspect(reason)}")
      new_state = %{state | socket_pid: nil, connected: false}
      schedule_reconnect(new_state)
    end
  end

  def handle_info(%{event: :add_system, payload: system}, %{connected: true, socket_pid: socket_pid} = state) when is_pid(socket_pid) do
    system_id = system.solar_system_id

    # Check if we're already subscribed to this system
    if not MapSet.member?(state.subscribed_systems, system_id) do
      Logger.info("[WandererKills.WebSocketClient] 🗺️ New system #{system_id} added to map, subscribing to kills")
      send(socket_pid, {:subscribe_systems, [system_id]})

      # Update our tracked subscriptions
      new_subscriptions = MapSet.put(state.subscribed_systems, system_id)
      new_state = %{state | subscribed_systems: new_subscriptions}
      {:noreply, new_state}
    else
      Logger.debug("[WandererKills.WebSocketClient] System #{system_id} already subscribed")
      {:noreply, state}
    end
  end

  def handle_info(%{event: :add_system, payload: _system}, state) do
    # Not connected - ignore for now, will pick up systems on next connection
    {:noreply, state}
  end

  def handle_info(:cleanup_subscriptions, %{connected: true, socket_pid: socket_pid} = state) when is_pid(socket_pid) do
    Logger.info("[WandererKills.WebSocketClient] 🧹 Running hourly subscription cleanup")

    # Get current systems that should be tracked
    current_tracked_systems = MapSet.new(get_tracked_system_ids())
    subscribed_systems = state.subscribed_systems

    # Find systems we're subscribed to but no longer need
    obsolete_systems = MapSet.difference(subscribed_systems, current_tracked_systems)
    |> MapSet.to_list()

    if length(obsolete_systems) > 0 do
      Logger.info("[WandererKills.WebSocketClient] 🗑️ Unsubscribing from #{length(obsolete_systems)} obsolete systems")
      send(socket_pid, {:unsubscribe_systems, obsolete_systems})

      # Update our tracked subscriptions
      new_subscriptions = MapSet.difference(subscribed_systems, MapSet.new(obsolete_systems))
      new_state = %{state | subscribed_systems: new_subscriptions}

      # Schedule next cleanup
      schedule_subscription_cleanup()
      {:noreply, new_state}
    else
      Logger.debug("[WandererKills.WebSocketClient] ✅ No obsolete subscriptions found")
      # Schedule next cleanup
      schedule_subscription_cleanup()
      {:noreply, state}
    end
  end

  def handle_info(:cleanup_subscriptions, state) do
    # Not connected - schedule next cleanup anyway
    Logger.debug("[WandererKills.WebSocketClient] Skipping cleanup (not connected)")
    schedule_subscription_cleanup()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[WandererKills.WebSocketClient] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:subscribe_systems, system_ids}, %{connected: true, socket_pid: socket_pid} = state) when is_pid(socket_pid) do
    case GenSocketClient.push(socket_pid, "killmails:lobby", "subscribe_systems", %{systems: system_ids}) do
      {:ok, _ref} ->
        new_subscriptions = MapSet.union(state.subscribed_systems, MapSet.new(system_ids))
        new_state = %{state | subscribed_systems: new_subscriptions}
        Logger.info("[WandererKills.WebSocketClient] ✅ Subscribed to systems: #{inspect(system_ids)}")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[WandererKills.WebSocketClient] ❌ Failed to subscribe: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_cast({:subscribe_systems, _}, state) do
    Logger.warning("[WandererKills.WebSocketClient] ⚠️  Cannot subscribe: not connected")
    {:noreply, state}
  end

  def handle_cast({:unsubscribe_systems, system_ids}, %{connected: true, socket_pid: socket_pid} = state) when is_pid(socket_pid) do
    case GenSocketClient.push(socket_pid, "killmails:lobby", "unsubscribe_systems", %{systems: system_ids}) do
      {:ok, _ref} ->
        new_subscriptions = MapSet.difference(state.subscribed_systems, MapSet.new(system_ids))
        new_state = %{state | subscribed_systems: new_subscriptions}
        Logger.info("[WandererKills.WebSocketClient] ✅ Unsubscribed from systems: #{inspect(system_ids)}")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[WandererKills.WebSocketClient] ❌ Failed to unsubscribe: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_cast({:unsubscribe_systems, _}, state) do
    Logger.warning("[WandererKills.WebSocketClient] ⚠️  Cannot unsubscribe: not connected")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      connected: state.connected,
      server_url: state.server_url,
      subscribed_systems: MapSet.to_list(state.subscribed_systems),
      systems_count: MapSet.size(state.subscribed_systems),
      retry_count: state.retry_count,
      cycle_count: state.cycle_count,
      socket_pid: state.socket_pid
    }

    {:reply, {:ok, status}, state}
  end

  # Private Helper Functions

  defp websocket_url(base_url) do
    "#{base_url}/socket/websocket"
  end

  defp start_socket_client(state) do
    socket_opts = [
      serializer: Phoenix.Channels.GenSocketClient.Serializer.Json
    ]

    callback_state = %{
      parent: self(),
      server_url: state.server_url
    }

    # Start the GenSocketClient directly, not in a task
    try do
      case GenSocketClient.start_link(
        WandererApp.Kills.SocketHandler,
        Phoenix.Channels.GenSocketClient.Transport.WebSocketClient,
        callback_state,
        socket_opts
      ) do
        {:ok, socket_pid} ->
          Process.monitor(socket_pid)
          {:ok, socket_pid}
        error ->
          Logger.warning("[WandererKills.WebSocketClient] Failed to start socket client: #{inspect(error)}")
          error
      end
    rescue
      error ->
        Logger.error("[WandererKills.WebSocketClient] 💥 Exception in start_socket_client: #{inspect(error)}")
        {:error, error}
    catch
      :exit, reason ->
        Logger.warning("[WandererKills.WebSocketClient] Socket client exited during startup: #{inspect(reason)}")
        {:error, reason}
      error_type, reason ->
        Logger.warning("[WandererKills.WebSocketClient] Socket client failed during startup: #{error_type} #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp schedule_reconnect(state) do
    if state.retry_count < state.max_retries do
      # Quick retries: 30s, 60s, 120s
      delay = case state.retry_count do
        0 -> 30_000   # 30 seconds
        1 -> 60_000   # 1 minute
        2 -> 120_000  # 2 minutes
        _ -> 30_000   # fallback
      end

      delay_seconds = Float.round(delay / 1_000, 1)
      Logger.info("[WandererKills.WebSocketClient] 🔄 Scheduling reconnect in #{delay_seconds}s (attempt #{state.retry_count + 1}/#{state.max_retries}, cycle #{state.cycle_count + 1})")
      Process.send_after(self(), :connect, delay)

      new_state = %{state | retry_count: state.retry_count + 1}
      {:noreply, new_state}
    else
      # Max retries reached for this cycle, wait 10 minutes before next cycle
      cycle_delay = 10 * 60 * 1000  # 10 minutes
      cycle_minutes = Float.round(cycle_delay / 60_000, 1)

      Logger.warning("[WandererKills.WebSocketClient] ⚠️  Max retries reached for cycle #{state.cycle_count + 1}, waiting #{cycle_minutes} minutes before next cycle")

      # Reset retry count and increment cycle count
      new_state = %{state | retry_count: 0, cycle_count: state.cycle_count + 1}
      Process.send_after(self(), :connect, cycle_delay)
      {:noreply, new_state}
    end
  end

  # Reuse the existing logic from PubSubSubscriber
  defp get_tracked_system_ids do
    try do
      cutoff_time = DateTime.utc_now() |> DateTime.add(-30, :minute)

      last_active_maps =
        case WandererApp.Api.MapState.get_last_active(cutoff_time) do
          {:ok, []} ->
            case WandererApp.Maps.get_available_maps() do
              {:ok, maps} ->
                fallback_map = Enum.max_by(maps, & &1.updated_at, fn -> nil end)
                if fallback_map, do: [fallback_map], else: []
              _ -> []
            end
          {:ok, maps} -> maps
          _ -> []
        end

      active_maps_with_subscription =
        last_active_maps
        |> Enum.filter(fn map ->
          {:ok, is_subscription_active} = map.id |> WandererApp.Map.is_subscription_active?()
          is_subscription_active
        end)

      system_ids =
        active_maps_with_subscription
        |> Enum.flat_map(fn map_record ->
          the_map_id = Map.get(map_record, :map_id) || Map.get(map_record, :id)

          case WandererApp.MapSystemRepo.get_visible_by_map(the_map_id) do
            {:ok, systems} -> Enum.map(systems, fn sys -> sys.solar_system_id end)
            _ -> []
          end
        end)
        |> Enum.uniq()

      system_ids
    rescue
      error ->
        Logger.warning("[WandererKills.WebSocketClient] Error getting tracked systems: #{inspect(error)}")
        []
    end
  end

    defp subscribe_to_map_events do
    try do
      # Get all active maps and subscribe to their events
      active_maps = WandererApp.Map.RegistryHelper.list_all_maps()

      Logger.info("[WandererKills.WebSocketClient] 📡 Subscribing to #{length(active_maps)} map channels for system updates")

      Enum.each(active_maps, fn %{id: map_id} ->
        # Subscribe to this map's broadcasts using the map_id as topic
        Phoenix.PubSub.subscribe(WandererApp.PubSub, map_id)
      end)

      Logger.info("[WandererKills.WebSocketClient] ✅ Subscribed to all active map events")
    rescue
      error ->
        Logger.warning("[WandererKills.WebSocketClient] ⚠️  Failed to subscribe to map events: #{inspect(error)}")
    end
  end

  defp schedule_subscription_cleanup do
    # Schedule cleanup in 1 hour (3,600,000 milliseconds)
    Process.send_after(self(), :cleanup_subscriptions, :timer.hours(1))
  end


end

defmodule WandererApp.Kills.SocketHandler do
  @moduledoc """
  Minimal GenSocketClient handler for WandererKills WebSocket connection.
  """

  @behaviour Phoenix.Channels.GenSocketClient
  require Logger
  alias WandererApp.Kills.DataAdapter

  @impl true
  def init(state) do
    Logger.info("[WandererKills.SocketHandler] Initializing with state: #{inspect(state)}")
    base_url = "#{state.server_url}/socket/websocket"
    query_params = [vsn: "2.0.0"]
    {:connect, base_url, query_params, state}
  end

  @impl true
  def handle_connected(transport, state) do
    Logger.info("[WandererKills.SocketHandler] ✅ Connected to WebSocket!")

    # Get initial systems to send with join
    initial_systems = get_tracked_system_ids_for_join()
    Logger.info("[WandererKills.SocketHandler] 🔌 Joining with #{length(initial_systems)} initial systems: #{inspect(initial_systems)}")

    case Phoenix.Channels.GenSocketClient.join(transport, "killmails:lobby", %{initial_systems: initial_systems}) do
      {:ok, response} ->
        Logger.info("[WandererKills.SocketHandler] 📡 Joined killmails:lobby channel - Response: #{inspect(response)}")
        send(state.parent, {:channel_joined, self(), initial_systems})
        {:ok, state}

      {:error, reason} ->
        Logger.error("[WandererKills.SocketHandler] ❌ Failed to join channel: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_disconnected(reason, state) do
    Logger.warning("[WandererKills.SocketHandler] 📡 WebSocket disconnected: #{inspect(reason)}")
    {:ok, state}
  end

  @impl true
  def handle_channel_closed(topic, _payload, _transport, state) do
    Logger.warning("[WandererKills.SocketHandler] 📺 Channel #{topic} closed")
    {:ok, state}
  end

  @impl true
  def handle_message(topic, event, payload, _transport, state) do
    # Always log incoming messages for debugging
    Logger.info("[WandererKills.SocketHandler] 📨 Received message - Topic: #{topic}, Event: #{event}, Payload: #{inspect(payload, limit: :infinity)}")

    case {topic, event} do
      {"killmails:lobby", "killmail_update"} ->
        system_id = payload["system_id"]
        killmails = payload["killmails"] || []
        Logger.info("[WandererKills.SocketHandler] 🔥 Processing #{length(killmails)} killmails for system #{system_id}")

        adapted_kills = DataAdapter.adapt_kills_list(killmails)
        Logger.info("[WandererKills.SocketHandler] 📊 Adapted #{length(adapted_kills)} kills for system #{system_id}")

        broadcast_detailed_kills_to_maps(system_id, adapted_kills)

      {"killmails:lobby", "kill_count_update"} ->
        system_id = payload["system_id"]
        count = payload["count"]
        Logger.info("[WandererKills.SocketHandler] 📊 Processing kill count update for system #{system_id}: #{count}")

        broadcast_kill_count_to_maps(system_id, count)

      _ ->
        Logger.warning("[WandererKills.SocketHandler] ⚠️ Unhandled message - Topic: #{topic}, Event: #{event}")
    end

    {:ok, state}
  end

  @impl true
  def handle_reply(topic, ref, payload, _transport, state) do
    Logger.info("[WandererKills.SocketHandler] 📬 Received reply - Topic: #{topic}, Ref: #{inspect(ref)}, Payload: #{inspect(payload)}")
    {:ok, state}
  end

  @impl true
  def handle_info({:subscribe_systems, system_ids}, transport, state) do
    Logger.info("[WandererKills.SocketHandler] 🔔 Subscribing to #{length(system_ids)} systems: #{inspect(system_ids)}")
    case Phoenix.Channels.GenSocketClient.push(transport, "killmails:lobby", "subscribe_systems", %{systems: system_ids}) do
      {:ok, ref} ->
        Logger.info("[WandererKills.SocketHandler] ✅ Successfully sent subscription request, ref: #{inspect(ref)}")
        {:ok, state}
      {:error, reason} ->
        Logger.error("[WandererKills.SocketHandler] ❌ Failed to subscribe: #{inspect(reason)}")
        {:ok, state}
    end
  end

  def handle_info({:unsubscribe_systems, system_ids}, transport, state) do
    Logger.info("[WandererKills.SocketHandler] 🔕 Unsubscribing from #{length(system_ids)} systems")
    case Phoenix.Channels.GenSocketClient.push(transport, "killmails:lobby", "unsubscribe_systems", %{systems: system_ids}) do
      {:ok, _ref} ->
        Logger.info("[WandererKills.SocketHandler] ✅ Successfully unsubscribed from systems")
        {:ok, state}
      {:error, reason} ->
        Logger.error("[WandererKills.SocketHandler] ❌ Failed to unsubscribe: #{inspect(reason)}")
        {:ok, state}
    end
  end

  def handle_info(_msg, _transport, state) do
    {:ok, state}
  end

  @impl true
  def handle_call(_msg, _from, _transport, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_joined(_topic, _payload, _transport, state) do
    {:ok, state}
  end

  @impl true
  def handle_join_error(topic, payload, _transport, state) do
    Logger.error("[WandererKills.SocketHandler] ❌ Failed to join channel #{topic}: #{inspect(payload)}")
    {:ok, state}
  end

  # Private helper functions

  defp get_tracked_system_ids_for_join do
    try do
      cutoff_time = DateTime.utc_now() |> DateTime.add(-30, :minute)

      last_active_maps =
        case WandererApp.Api.MapState.get_last_active(cutoff_time) do
          {:ok, []} ->
            case WandererApp.Maps.get_available_maps() do
              {:ok, maps} ->
                fallback_map = Enum.max_by(maps, & &1.updated_at, fn -> nil end)
                if fallback_map, do: [fallback_map], else: []
              _ -> []
            end
          {:ok, maps} -> maps
          _ -> []
        end

      active_maps_with_subscription =
        last_active_maps
        |> Enum.filter(fn map ->
          {:ok, is_subscription_active} = map.id |> WandererApp.Map.is_subscription_active?()
          is_subscription_active
        end)

      system_ids =
        active_maps_with_subscription
        |> Enum.flat_map(fn map_record ->
          the_map_id = Map.get(map_record, :map_id) || Map.get(map_record, :id)

          case WandererApp.MapSystemRepo.get_visible_by_map(the_map_id) do
            {:ok, systems} -> Enum.map(systems, fn sys -> sys.solar_system_id end)
            _ -> []
          end
        end)
        |> Enum.uniq()

      Logger.debug("[WandererKills.SocketHandler] Found #{length(system_ids)} tracked systems for join")
      system_ids
    rescue
      error ->
        Logger.warning("[WandererKills.SocketHandler] Error getting tracked systems for join: #{inspect(error)}")
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
            end
          _ -> :ok
        end
      rescue
        error ->
          Logger.warning("[WandererKills.SocketHandler] Failed to broadcast kill count: #{inspect(error)}")
      end
    end)
  end

  defp broadcast_detailed_kills_to_maps(system_id, adapted_kills) do
    active_maps = WandererApp.Map.RegistryHelper.list_all_maps()
    Logger.debug("[WandererKills.SocketHandler] 🗺️ Broadcasting kills for system #{system_id} to #{length(active_maps)} active maps")

    maps_with_system = active_maps
    |> Enum.filter(fn %{id: map_id} ->
      try do
        case WandererApp.Map.get_map(map_id) do
          {:ok, %{systems: systems}} ->
            has_system = Map.has_key?(systems, system_id)
            if has_system do
              Logger.info("[WandererKills.SocketHandler] ✅ Map #{map_id} has system #{system_id}, broadcasting #{length(adapted_kills)} kills")

              cache_key = "map_#{map_id}:zkb_detailed_kills"
              existing_cache = WandererApp.Cache.get(cache_key) || %{}
              updated_cache = Map.put(existing_cache, system_id, adapted_kills)
              WandererApp.Cache.put(cache_key, updated_cache, ttl: :timer.hours(1))

              WandererApp.Map.Server.Impl.broadcast!(map_id, :detailed_kills_updated, %{
                system_id => adapted_kills
              })

              true
            else
              false
            end
          _ ->
            Logger.debug("[WandererKills.SocketHandler] ⚠️ Could not get map #{map_id}")
            false
        end
      rescue
        error ->
          Logger.warning("[WandererKills.SocketHandler] Failed to broadcast detailed kills to map #{map_id}: #{inspect(error)}")
          false
      end
    end)

    if length(maps_with_system) == 0 do
      Logger.warning("[WandererKills.SocketHandler] ⚠️ No active maps have system #{system_id} - kills not broadcasted")
    else
      Logger.info("[WandererKills.SocketHandler] 📡 Successfully broadcasted kills to #{length(maps_with_system)} maps")
    end
  end
end
