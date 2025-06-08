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

  @spec get_status() :: {:ok, map()} | {:error, term()}
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    # Trap exits so GenSocketClient failures don't kill this GenServer
    Process.flag(:trap_exit, true)

    server_url = Keyword.get(opts, :server_url, Application.get_env(:wanderer_app, :wanderer_kills_base_url, "ws://wanderer-kills:4004"))

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
          send(self(), :subscribe_current_systems)

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
      exit_type, reason ->
        Logger.error("[WandererKills.WebSocketClient] 💥 Exit in handle_info(:connect): #{exit_type} - #{inspect(reason)}")
        schedule_reconnect(state)
      error_type, reason ->
        Logger.error("[WandererKills.WebSocketClient] 💥 Error in handle_info(:connect): #{error_type} - #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  def handle_info(:subscribe_current_systems, %{connected: true, socket_pid: socket_pid} = state) when is_pid(socket_pid) do
    system_ids = get_tracked_system_ids()

    if length(system_ids) > 0 do
      Logger.info("[WandererKills.WebSocketClient] 🔔 Auto-subscribing to #{length(system_ids)} tracked systems")

      case GenSocketClient.push(socket_pid, "killmails:lobby", "subscribe_systems", %{systems: system_ids}) do
        {:ok, _ref} ->
          new_subscriptions = MapSet.union(state.subscribed_systems, MapSet.new(system_ids))
          new_state = %{state | subscribed_systems: new_subscriptions}
          {:noreply, new_state}

        {:error, reason} ->
          Logger.warning("[WandererKills.WebSocketClient] ⚠️  Failed to auto-subscribe: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      Logger.debug("[WandererKills.WebSocketClient] No systems to subscribe to")
      {:noreply, state}
    end
  end

  def handle_info(:subscribe_current_systems, state) do
    Logger.debug("[WandererKills.WebSocketClient] Cannot subscribe to systems: not connected")
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, socket_pid, reason}, %{socket_pid: socket_pid} = state) do
    Logger.warning("[WandererKills.WebSocketClient] 📡 WebSocket process died: #{inspect(reason)}")
    new_state = %{state | socket_pid: nil, connected: false}
    schedule_reconnect(new_state)
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning("[WandererKills.WebSocketClient] 🚪 EXIT signal from #{inspect(pid)}: #{inspect(reason)}")
    if pid == state.socket_pid do
      new_state = %{state | socket_pid: nil, connected: false}
      schedule_reconnect(new_state)
    else
      {:noreply, state}
    end
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

  defp start_socket_client(state) do
    socket_opts = [
      url: "#{state.server_url}/socket/websocket?vsn=2.0.0",
      serializer: Jason
    ]

    callback_state = %{
      parent: self(),
      server_url: state.server_url
    }

    # Start the GenSocketClient in a separate task to avoid linking issues
    task = Task.async(fn ->
      GenSocketClient.start_link(
        WandererApp.Kills.SocketClientHandler,
        Phoenix.Channels.GenSocketClient.Transport.WebSocketClient,
        callback_state,
        socket_opts
      )
    end)

    try do
      case Task.await(task, 5_000) do
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
      :exit, {:timeout, _} ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("[WandererKills.WebSocketClient] Socket client startup timed out")
        {:error, :timeout}
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
end

defmodule WandererApp.Kills.SocketClientHandler do
  @moduledoc """
  GenSocketClient handler for the WandererKills WebSocket connection.
  """

  @behaviour Phoenix.Channels.GenSocketClient

  require Logger
  alias WandererApp.Kills.DataAdapter

  @impl true
  def init(state) do
    Logger.info("[WandererKills.SocketClientHandler] Initializing WebSocket handler")
    {:connect, state.server_url <> "/socket/websocket?vsn=2.0.0", state}
  end

  @impl true
  def handle_connected(transport, state) do
    Logger.info("[WandererKills.SocketClientHandler] ✅ Connected to WebSocket!")

    case Phoenix.Channels.GenSocketClient.join(transport, "killmails:lobby") do
      {:ok, _response} ->
        Logger.info("[WandererKills.SocketClientHandler] 📡 Joined killmails:lobby channel")
        {:ok, state}

      {:error, reason} ->
        Logger.error("[WandererKills.SocketClientHandler] ❌ Failed to join channel: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_disconnected(reason, state) do
    Logger.warning("[WandererKills.SocketClientHandler] 📡 WebSocket disconnected: #{inspect(reason)}")
    {:ok, state}
  end

  @impl true
  def handle_channel_closed(topic, payload, _transport, state) do
    Logger.warning("[WandererKills.SocketClientHandler] 📺 Channel #{topic} closed: #{inspect(payload)}")
    {:ok, state}
  end

  @impl true
  def handle_message(topic, event, payload, _transport, state) do
    handle_channel_message(topic, event, payload, state)
  end

  @impl true
  def handle_reply(_topic, _ref, _payload, _transport, state) do
    {:ok, state}
  end

  @impl true
  def handle_info(_msg, _transport, state) do
    {:ok, state}
  end

  @impl true
  def handle_call(_msg, _from, _transport, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(_msg, _transport, state) do
    {:ok, state}
  end

  # Private message handlers

  defp handle_channel_message("killmails:lobby", "killmail_update", payload, state) do
    system_id = payload["system_id"]
    killmails = payload["killmails"] || []

    Logger.info("[WandererKills.SocketClientHandler] 🔥 Received #{length(killmails)} killmails for system #{system_id}")

    # Adapt killmails and broadcast to maps
    adapted_kills = DataAdapter.adapt_kills_list(killmails)
    broadcast_detailed_kills_to_maps(system_id, adapted_kills)

    {:ok, state}
  end

  defp handle_channel_message("killmails:lobby", "kill_count_update", payload, state) do
    system_id = payload["system_id"]
    count = payload["count"]

    Logger.info("[WandererKills.SocketClientHandler] 📊 Kill count update for system #{system_id}: #{count}")

    # Broadcast kill count to maps
    broadcast_kill_count_to_maps(system_id, count)

    {:ok, state}
  end

  defp handle_channel_message(_topic, event, payload, state) do
    Logger.debug("[WandererKills.SocketClientHandler] 📨 Unhandled message: #{event}",
      payload: inspect(payload))
    {:ok, state}
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
          Logger.warning("[WandererKills.SocketClientHandler] Failed to broadcast kill count to map #{map_id}: #{inspect(error)}")
      end
    end)
  end

  defp broadcast_detailed_kills_to_maps(system_id, adapted_kills) do
    WandererApp.Map.RegistryHelper.list_all_maps()
    |> Enum.each(fn %{id: map_id} ->
      try do
        case WandererApp.Map.get_map(map_id) do
          {:ok, %{systems: systems}} ->
            if Map.has_key?(systems, system_id) do
              # Update local cache
              cache_key = "map_#{map_id}:zkb_detailed_kills"
              existing_cache = WandererApp.Cache.get(cache_key) || %{}
              updated_cache = Map.put(existing_cache, system_id, adapted_kills)
              WandererApp.Cache.put(cache_key, updated_cache, ttl: :timer.hours(1))

              # Broadcast the update
              WandererApp.Map.Server.Impl.broadcast!(map_id, :detailed_kills_updated, %{
                system_id => adapted_kills
              })
            end
          _ -> :ok
        end
      rescue
        error ->
          Logger.warning("[WandererKills.SocketClientHandler] Failed to broadcast detailed kills to map #{map_id}: #{inspect(error)}")
      end
    end)
  end
end
