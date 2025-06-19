defmodule WandererApp.Kills.Client do
  @moduledoc """
  WebSocket client for WandererKills service.

  Follows patterns established in the character and map modules.
  """

  use GenServer
  require Logger

  alias WandererApp.Kills.{MessageHandler, Config}
  alias WandererApp.Kills.Subscription.{Manager, MapIntegration}
  alias Phoenix.Channels.GenSocketClient

  # Simple retry configuration - inline like character module
  @retry_delays [5_000, 10_000, 30_000, 60_000]
  @max_retries 10
  @health_check_interval :timer.seconds(30)  # Check every 30 seconds

  defstruct [
    :socket_pid,
    :retry_timer_ref,
    connected: false,
    connecting: false,
    subscribed_systems: MapSet.new(),
    retry_count: 0,
    last_error: nil
  ]

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec subscribe_to_systems([integer()]) :: :ok | {:error, atom()}
  def subscribe_to_systems(system_ids) do
    case validate_system_ids(system_ids) do
      {:ok, valid_ids} ->
        GenServer.cast(__MODULE__, {:subscribe_systems, valid_ids})

      {:error, _} = error ->
        Logger.error("[Client] Invalid system IDs: #{inspect(system_ids)}")
        error
    end
  end

  @spec unsubscribe_from_systems([integer()]) :: :ok | {:error, atom()}
  def unsubscribe_from_systems(system_ids) do
    case validate_system_ids(system_ids) do
      {:ok, valid_ids} ->
        GenServer.cast(__MODULE__, {:unsubscribe_systems, valid_ids})

      {:error, _} = error ->
        Logger.error("[Client] Invalid system IDs: #{inspect(system_ids)}")
        error
    end
  end

  @spec get_status() :: {:ok, map()} | {:error, term()}
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @spec reconnect() :: :ok | {:error, term()}
  def reconnect do
    Logger.info("[Client] Manual reconnect requested")
    GenServer.call(__MODULE__, :reconnect)
  catch
    :exit, _ -> {:error, :not_running}
  end
  
  @spec force_health_check() :: :ok
  def force_health_check do
    send(__MODULE__, :health_check)
    :ok
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    if Config.enabled?() do
      Logger.info("[Client] Starting kills WebSocket client")

      # Start connection attempt immediately
      send(self(), :connect)
      
      # Schedule first health check sooner
      Process.send_after(self(), :health_check, 5_000)

      {:ok, %__MODULE__{}}
    else
      Logger.info("[Client] Kills integration disabled")
      :ignore
    end
  end

  @impl true
  def handle_info(:connect, %{connecting: true} = state) do
    Logger.debug("[Client] Already connecting, ignoring connect request")
    {:noreply, state}
  end
  
  def handle_info(:connect, %{connected: true} = state) do
    Logger.debug("[Client] Already connected, ignoring connect request")
    {:noreply, state}
  end
  
  def handle_info(:connect, state) do
    Logger.info("[Client] Initiating connection attempt")
    state = cancel_retry(state)
    new_state = attempt_connection(%{state | connecting: true})
    {:noreply, new_state}
  end

  def handle_info(:retry_connection, %{connecting: true} = state) do
    Logger.debug("[Client] Already connecting, skipping retry")
    {:noreply, %{state | retry_timer_ref: nil}}
  end
  
  def handle_info(:retry_connection, %{connected: true} = state) do
    Logger.debug("[Client] Already connected, skipping retry")
    {:noreply, %{state | retry_timer_ref: nil}}
  end
  
  def handle_info(:retry_connection, state) do
    Logger.info("[Client] Retrying connection (attempt #{state.retry_count}/#{@max_retries})")
    state = %{state | retry_timer_ref: nil, connecting: true}
    new_state = attempt_connection(state)
    {:noreply, new_state}
  end

  def handle_info(:refresh_subscriptions, %{connected: true} = state) do
    Logger.info("[Client] Refreshing subscriptions after connection")

    case MapIntegration.get_tracked_system_ids() do
      {:ok, system_list} ->
        if system_list != [] do
          Logger.info("[Client] Refreshing with #{length(system_list)} systems")
          subscribe_to_systems(system_list)
        else
          Logger.info("[Client] No systems to refresh")
        end

      {:error, reason} ->
        Logger.error(
          "[Client] Failed to refresh subscriptions: #{inspect(reason)}, scheduling retry"
        )

        Process.send_after(self(), :refresh_subscriptions, 5000)
    end

    {:noreply, state}
  end

  def handle_info(:refresh_subscriptions, state) do
    # Not connected yet, retry later
    Process.send_after(self(), :refresh_subscriptions, 5000)
    {:noreply, state}
  end

  def handle_info({:connected, socket_pid}, state) do
    Logger.info("[Client] WebSocket connected, socket_pid: #{inspect(socket_pid)}")
    
    # Monitor the socket process so we know if it dies
    Process.monitor(socket_pid)

    new_state =
      %{
        state
        | connected: true,
          connecting: false,
          socket_pid: socket_pid,
          retry_count: 0,
          last_error: nil
      }
      |> cancel_retry()

    {:noreply, new_state}
  end

  # Guard against duplicate disconnection events
  def handle_info({:disconnected, reason}, %{connected: false} = state) do
    Logger.debug("[Client] Ignoring disconnection event - already disconnected")
    {:noreply, state}
  end
  
  def handle_info({:disconnected, reason}, state) do
    Logger.warning("[Client] WebSocket disconnected: #{inspect(reason)}")

    state = 
      %{state | 
        connected: false, 
        connecting: false, 
        socket_pid: nil, 
        last_error: reason
      }

    if should_retry?(state) do
      {:noreply, schedule_retry(state)}
    else
      Logger.error("[Client] Max retry attempts reached. Giving up.")
      {:noreply, state}
    end
  end

  def handle_info(:health_check, state) do
    health_status = check_health(state)
    Logger.debug("[Client] Health check result: #{health_status}, connected: #{state.connected}, socket_pid: #{inspect(state.socket_pid)}")
    
    case health_status do
      :healthy ->
        :ok

      :needs_reconnect ->
        Logger.warning("[Client] Connection unhealthy, triggering reconnect")
        handle_connection_lost(state)
    end

    schedule_health_check()
    {:noreply, state}
  end
  
  # Handle process DOWN messages for socket monitoring
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{socket_pid: pid} = state) do
    Logger.error("[Client] Socket process died: #{inspect(reason)}")
    send(self(), {:disconnected, {:socket_died, reason}})
    {:noreply, state}
  end
  
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Ignore DOWN messages for other processes
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:subscribe_systems, system_ids}, state) do
    {updated_systems, to_subscribe} =
      Manager.subscribe_systems(state.subscribed_systems, system_ids)

    # Log subscription details
    if length(to_subscribe) > 0 do
      # Get map information for the systems
      map_info = get_system_map_info(to_subscribe)
      
      Logger.info(
        "[Client] Subscribing to #{length(to_subscribe)} new systems. " <>
        "Total subscribed: #{MapSet.size(updated_systems)}. " <>
        "Map breakdown: #{inspect(map_info)}"
      )
      
      Logger.debug("[Client] Systems to subscribe: #{inspect(to_subscribe)}")
    end

    if length(to_subscribe) > 0 and state.socket_pid do
      Manager.sync_with_server(state.socket_pid, to_subscribe, [])
    end

    {:noreply, %{state | subscribed_systems: updated_systems}}
  end

  def handle_cast({:unsubscribe_systems, system_ids}, state) do
    {updated_systems, to_unsubscribe} =
      Manager.unsubscribe_systems(state.subscribed_systems, system_ids)

    # Log unsubscription details
    if length(to_unsubscribe) > 0 do
      # Get map information for the systems
      map_info = get_system_map_info(to_unsubscribe)
      
      Logger.info(
        "[Client] Unsubscribing from #{length(to_unsubscribe)} systems. " <>
        "Total subscribed: #{MapSet.size(updated_systems)}. " <>
        "Map breakdown: #{inspect(map_info)}"
      )
      
      Logger.debug("[Client] Systems to unsubscribe: #{inspect(to_unsubscribe)}")
    end

    if length(to_unsubscribe) > 0 and state.socket_pid do
      Manager.sync_with_server(state.socket_pid, [], to_unsubscribe)
    end

    {:noreply, %{state | subscribed_systems: updated_systems}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      connected: state.connected,
      connecting: state.connecting,
      retry_count: state.retry_count,
      last_error: state.last_error,
      subscribed_systems: MapSet.size(state.subscribed_systems),
      socket_alive: socket_alive?(state.socket_pid),
      subscriptions: %{
        subscribed_systems: MapSet.to_list(state.subscribed_systems)
      }
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call(:reconnect, _from, state) do
    Logger.info("[Client] Manual reconnection requested")

    state = cancel_retry(state)
    
    if state.socket_pid do
      Logger.info("[Client] Disconnecting existing socket: #{inspect(state.socket_pid)}")
      disconnect_socket(state.socket_pid)
    end

    new_state = %{
      state
      | connected: false,
        connecting: false,
        socket_pid: nil,
        retry_count: 0,
        last_error: nil
    }

    send(self(), :connect)
    {:reply, :ok, new_state}
  end

  # Private functions

  defp attempt_connection(state) do
    case connect_to_server() do
      {:ok, socket_pid} ->
        Logger.info("[Client] Socket process started: #{inspect(socket_pid)}")
        %{state | socket_pid: socket_pid, connecting: true}

      {:error, reason} ->
        Logger.error("[Client] Connection failed: #{inspect(reason)}")
        schedule_retry(%{state | connecting: false, last_error: reason})
    end
  end

  defp connect_to_server do
    url = Config.server_url()
    Logger.info("[Client] Connecting to: #{url}")

    # Get systems for initial subscription
    systems =
      case MapIntegration.get_tracked_system_ids() do
        {:ok, system_list} ->
          # Get map breakdown for logging
          map_info = get_system_map_info(system_list)
          
          Logger.info(
            "[Client] Initial connection with #{length(system_list)} systems. " <>
            "Map breakdown: #{map_info}"
          )
          
          system_list

        {:error, reason} ->
          Logger.warning(
            "[Client] Failed to get tracked system IDs for initial subscription: #{inspect(reason)}, will retry after connection"
          )

          # Return empty list but schedule immediate refresh after connection
          Process.send_after(self(), :refresh_subscriptions, 1000)
          []
      end

    handler_state = %{
      server_url: url,
      parent: self(),
      subscribed_systems: systems,
      disconnected: false
    }

    # Start the WebSocket client without extra transport options
    # The heartbeat is configured in the Handler.init function
    case GenSocketClient.start_link(
           __MODULE__.Handler,
           Phoenix.Channels.GenSocketClient.Transport.WebSocketClient,
           handler_state
         ) do
      {:ok, socket_pid} -> 
        Logger.info("[Client] Started WebSocket client process: #{inspect(socket_pid)}")
        {:ok, socket_pid}
        
      error -> 
        Logger.error("[Client] Failed to start WebSocket client: #{inspect(error)}")
        error
    end
  end

  defp should_retry?(%{retry_count: count}) when count >= @max_retries, do: false
  defp should_retry?(_), do: true

  defp schedule_retry(state) do
    # Cancel any existing retry timer first
    state = cancel_retry(state)
    
    delay = Enum.at(@retry_delays, min(state.retry_count, length(@retry_delays) - 1))
    Logger.info("[Client] Scheduling retry in #{delay}ms (attempt #{state.retry_count + 1})")

    timer_ref = Process.send_after(self(), :retry_connection, delay)
    %{state | retry_timer_ref: timer_ref, retry_count: state.retry_count + 1}
  end

  defp cancel_retry(%{retry_timer_ref: nil} = state), do: state

  defp cancel_retry(%{retry_timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    %{state | retry_timer_ref: nil}
  end

  defp check_health(%{connected: false} = state) do
    Logger.debug("[Client] Health check: not connected")
    :needs_reconnect
  end
  
  defp check_health(%{socket_pid: nil} = state) do
    Logger.debug("[Client] Health check: no socket pid")
    :needs_reconnect
  end

  defp check_health(%{socket_pid: pid} = state) do
    if socket_alive?(pid) do
      :healthy
    else
      Logger.warning("[Client] Health check: Socket process #{inspect(pid)} is dead")
      :needs_reconnect
    end
  end

  defp socket_alive?(nil), do: false
  defp socket_alive?(pid), do: Process.alive?(pid)

  defp disconnect_socket(nil), do: :ok

  defp disconnect_socket(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end
  
  defp handle_connection_lost(%{connected: false} = _state) do
    Logger.debug("[Client] Connection already lost, skipping cleanup")
  end
  
  defp handle_connection_lost(state) do
    Logger.warning("[Client] Connection lost, cleaning up and reconnecting")
    
    # Clean up existing socket
    if state.socket_pid do
      disconnect_socket(state.socket_pid)
    end
    
    # Reset state and trigger reconnection
    send(self(), {:disconnected, :connection_lost})
  end

  # Handler module for WebSocket events
  defmodule Handler do
    @moduledoc """
    WebSocket handler for the kills client.

    Handles Phoenix Channel callbacks for WebSocket communication.
    """

    @behaviour Phoenix.Channels.GenSocketClient
    require Logger

    alias WandererApp.Kills.MessageHandler

    @impl true
    def init(state) do
      ws_url = "#{state.server_url}/socket/websocket"
      # Configure with heartbeat interval (Phoenix default is 30s)
      params = [
        {"vsn", "2.0.0"},
        {"heartbeat", "30000"}  # 30 second heartbeat
      ]
      {:connect, ws_url, params, state}
    end

    @impl true
    def handle_connected(transport, state) do
      Logger.info("[Handler] WebSocket transport connected, joining channel...")

      join_params = %{
        systems: state.subscribed_systems,
        client_identifier: "wanderer_app"
      }
      
      Logger.info(
        "[Handler] Joining killmails:lobby with #{length(state.subscribed_systems)} initial systems"
      )
      
      case GenSocketClient.join(transport, "killmails:lobby", join_params) do
        {:ok, response} ->
          Logger.info("[Handler] Successfully joined killmails:lobby, response: #{inspect(response)}")
          send(state.parent, {:connected, self()})
          # Reset disconnected flag on successful connection
          {:ok, %{state | disconnected: false}}

        {:error, reason} ->
          Logger.error("[Handler] Failed to join channel: #{inspect(reason)}")
          send(state.parent, {:disconnected, {:join_error, reason}})
          {:ok, %{state | disconnected: true}}
      end
    end

    @impl true
    def handle_disconnected(reason, state) do
      if not state.disconnected do
        Logger.warning("[Handler] Disconnected from server: #{inspect(reason)}")
        send(state.parent, {:disconnected, reason})
        {:ok, %{state | disconnected: true}}
      else
        Logger.debug("[Handler] Ignoring duplicate disconnection event: #{inspect(reason)}")
        {:ok, state}
      end
    end

    @impl true
    def handle_channel_closed(topic, payload, _transport, state) do
      if not state.disconnected do
        Logger.warning("[Handler] Channel #{topic} closed with payload: #{inspect(payload)}")
        send(state.parent, {:disconnected, {:channel_closed, topic}})
        {:ok, %{state | disconnected: true}}
      else
        Logger.debug("[Handler] Ignoring channel closed - already disconnected")
        {:ok, state}
      end
    end

    @impl true
    def handle_message(topic, event, payload, _transport, state) do
      case {topic, event} do
        {"killmails:lobby", "killmail_update"} ->
          # Use supervised task to handle failures gracefully
          Task.Supervisor.start_child(
            WandererApp.Kills.TaskSupervisor,
            fn -> MessageHandler.process_killmail_update(payload) end
          )

        {"killmails:lobby", "kill_count_update"} ->
          # Use supervised task to handle failures gracefully
          Task.Supervisor.start_child(
            WandererApp.Kills.TaskSupervisor,
            fn -> MessageHandler.process_kill_count_update(payload) end
          )

        _ ->
          Logger.debug("[Handler] Unhandled message: #{topic} - #{event}")
          :ok
      end

      {:ok, state}
    end

    @impl true
    def handle_reply(_topic, _ref, _payload, _transport, state), do: {:ok, state}

    @impl true
    def handle_info({:subscribe_systems, system_ids}, transport, state) do
      Logger.info("[Handler] Pushing subscribe_systems event for #{length(system_ids)} systems")
      Logger.debug("[Handler] Subscribe systems: #{inspect(system_ids)}")
      
      case push_to_channel(transport, "subscribe_systems", %{"systems" => system_ids}) do
        :ok -> 
          Logger.debug("[Handler] Successfully pushed subscribe_systems event")
        error -> 
          Logger.error("[Handler] Failed to push subscribe_systems: #{inspect(error)}")
      end
      
      {:ok, state}
    end

    @impl true
    def handle_info({:unsubscribe_systems, system_ids}, transport, state) do
      Logger.info("[Handler] Pushing unsubscribe_systems event for #{length(system_ids)} systems")
      Logger.debug("[Handler] Unsubscribe systems: #{inspect(system_ids)}")
      
      case push_to_channel(transport, "unsubscribe_systems", %{"systems" => system_ids}) do
        :ok -> 
          Logger.debug("[Handler] Successfully pushed unsubscribe_systems event")
        error -> 
          Logger.error("[Handler] Failed to push unsubscribe_systems: #{inspect(error)}")
      end
      
      {:ok, state}
    end

    @impl true
    def handle_info(_msg, _transport, state) do
      {:ok, state}
    end

    @impl true
    def handle_call(_msg, _from, _transport, state),
      do: {:reply, {:error, :not_implemented}, state}

    @impl true
    def handle_joined(_topic, _payload, _transport, state), do: {:ok, state}

    @impl true
    def handle_join_error(topic, payload, _transport, state) do
      if not state.disconnected do
        Logger.error("[Handler] Join error on #{topic}: #{inspect(payload)}")
        send(state.parent, {:disconnected, {:join_error, {topic, payload}}})
        {:ok, %{state | disconnected: true}}
      else
        {:ok, state}
      end
    end

    defp push_to_channel(transport, event, payload) do
      Logger.debug("[Handler] Pushing event '#{event}' with payload: #{inspect(payload)}")
      
      case GenSocketClient.push(transport, "killmails:lobby", event, payload) do
        {:ok, ref} -> 
          Logger.debug("[Handler] Push successful, ref: #{inspect(ref)}")
          :ok
        error -> 
          Logger.error("[Handler] Push failed: #{inspect(error)}")
          error
      end
    end
  end

  # Validation functions (inlined from Validation module)

  @spec validate_system_id(any()) :: {:ok, integer()} | {:error, :invalid_system_id}
  defp validate_system_id(system_id)
       when is_integer(system_id) and system_id > 30_000_000 and system_id < 33_000_000 do
    {:ok, system_id}
  end

  defp validate_system_id(system_id) when is_binary(system_id) do
    case Integer.parse(system_id) do
      {id, ""} when id > 30_000_000 and id < 33_000_000 ->
        {:ok, id}

      _ ->
        {:error, :invalid_system_id}
    end
  end

  defp validate_system_id(_), do: {:error, :invalid_system_id}

  @spec validate_system_ids(list()) :: {:ok, [integer()]} | {:error, :invalid_system_ids}
  defp validate_system_ids(system_ids) when is_list(system_ids) do
    results = Enum.map(system_ids, &validate_system_id/1)

    case Enum.all?(results, &match?({:ok, _}, &1)) do
      true ->
        valid_ids = Enum.map(results, fn {:ok, id} -> id end)
        {:ok, valid_ids}

      false ->
        {:error, :invalid_system_ids}
    end
  end

  defp validate_system_ids(_), do: {:error, :invalid_system_ids}

  # Helper function to get map information for systems
  defp get_system_map_info(system_ids) do
    # Use the SystemMapIndex to get map associations
    system_ids
    |> Enum.reduce(%{}, fn system_id, acc ->
      maps = WandererApp.Kills.Subscription.SystemMapIndex.get_maps_for_system(system_id)
      
      Enum.reduce(maps, acc, fn map_id, inner_acc ->
        Map.update(inner_acc, map_id, 1, &(&1 + 1))
      end)
    end)
    |> Enum.map(fn {map_id, count} -> "#{map_id}: #{count} systems" end)
    |> Enum.join(", ")
    |> case do
      "" -> "no map associations found"
      info -> info
    end
  end
end
