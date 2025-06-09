defmodule WandererApp.Kills.Client do
  @moduledoc """
  WebSocket client for WandererKills service.

  Manages the complete WebSocket connection lifecycle, health monitoring,
  and system subscriptions for receiving killmail data.
  """

  use GenServer
  require Logger

  alias WandererApp.Kills.{Config, SystemTracker, MessageHandler}
  alias WandererApp.Kills.Subscription.Manager, as: SubscriptionManager
  alias Phoenix.Channels.GenSocketClient

  defstruct [
    :socket_pid,
    :server_url,
    connected: false,
    subscribed_systems: MapSet.new(),
    retry_state: %{retry_count: 0, cycle_count: 0}
  ]

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
    GenServer.call(__MODULE__, :get_status, Config.genserver_call_timeout())
  catch
    :exit, _ -> {:error, :not_running}
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    if Config.enabled?() do
      Logger.info("[KillsClient] Starting WandererKills WebSocket client")

      send(self(), :connect)
      schedule_health_check()
      schedule_cleanup()

      {:ok, %__MODULE__{server_url: Config.server_url()}}
    else
      Logger.info("[KillsClient] WandererKills integration disabled")
      :ignore
    end
  end

  @impl true
  def handle_info(:connect, state) do
    new_state = attempt_connection(state)
    {:noreply, new_state}
  end

  def handle_info(:retry_connection, state) do
    new_state = attempt_connection(state)
    {:noreply, new_state}
  end

  def handle_info({:connected, socket_pid}, state) do
    Logger.info("[KillsClient] WebSocket connected")
    new_state = %{state | connected: true, socket_pid: socket_pid, retry_state: %{retry_count: 0, cycle_count: 0}}

    # Resubscribe to all systems
    if MapSet.size(state.subscribed_systems) > 0 do
      SubscriptionManager.resubscribe_all(socket_pid, state.subscribed_systems)
    end

    {:noreply, new_state}
  end

  def handle_info({:disconnected, reason}, state) do
    Logger.warning("[KillsClient] WebSocket disconnected: #{inspect(reason)}")
    new_state = %{state | connected: false}
    schedule_retry(new_state.retry_state)
    {:noreply, new_state}
  end

  def handle_info(:health_check, state) do
    case check_connection_health(state) do
      :ok ->
        Logger.debug("[KillsClient] Connection healthy")

      {:reconnect, reason} ->
        Logger.warning("[KillsClient] Connection unhealthy: #{reason}. Triggering reconnection.")
        send(self(), :retry_connection)
    end

    schedule_health_check()
    {:noreply, state}
  end

  def handle_info(:cleanup_subscriptions, state) do
    {updated_systems, to_unsubscribe} = SubscriptionManager.cleanup_subscriptions(state.subscribed_systems)

    if length(to_unsubscribe) > 0 do
      SubscriptionManager.sync_with_server(state.socket_pid, [], to_unsubscribe)
    end

    schedule_cleanup()
    {:noreply, %{state | subscribed_systems: updated_systems}}
  end

  def handle_info(msg, state) do
    Logger.debug("[KillsClient] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:subscribe_systems, system_ids}, state) do
    {updated_systems, to_subscribe} = SubscriptionManager.subscribe_systems(state.subscribed_systems, system_ids)

    if length(to_subscribe) > 0 do
      SubscriptionManager.sync_with_server(state.socket_pid, to_subscribe, [])
    end

    {:noreply, %{state | subscribed_systems: updated_systems}}
  end

  def handle_cast({:unsubscribe_systems, system_ids}, state) do
    {updated_systems, to_unsubscribe} = SubscriptionManager.unsubscribe_systems(state.subscribed_systems, system_ids)

    if length(to_unsubscribe) > 0 do
      SubscriptionManager.sync_with_server(state.socket_pid, [], to_unsubscribe)
    end

    {:noreply, %{state | subscribed_systems: updated_systems}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      connection: get_connection_status(state),
      subscriptions: SubscriptionManager.get_stats(state.subscribed_systems),
      health: get_health_metrics(state),
      retry_state: state.retry_state
    }

    {:reply, {:ok, status}, state}
  end

  # Private functions - Connection Management

  defp attempt_connection(state) do
    disconnect(state.socket_pid)

    case connect(state.server_url) do
      {:ok, socket_pid} ->
        %{state | socket_pid: socket_pid}

      {:error, _reason} ->
        Logger.error("[KillsClient] Connection failed")
        new_retry_state = increment_retry(state.retry_state)
        schedule_retry(new_retry_state)
        %{state | retry_state: new_retry_state}
    end
  end

  defp connect(server_url) do
    Logger.info("[KillsClient] Attempting to connect to: #{server_url}")

    handler_state = %{server_url: server_url, parent: self()}

    case GenSocketClient.start_link(
           __MODULE__.Handler,
           Phoenix.Channels.GenSocketClient.Transport.WebSocketClient,
           handler_state
         ) do
      {:ok, socket_pid} ->
        Logger.info("[KillsClient] Socket process started: #{inspect(socket_pid)}")
        {:ok, socket_pid}

      {:error, reason} = error ->
        Logger.error("[KillsClient] Failed to start socket: #{inspect(reason)}")
        error
    end
  end

  defp disconnect(nil), do: :ok

  defp disconnect(socket_pid) when is_pid(socket_pid) do
    Logger.info("[KillsClient] Disconnecting WebSocket: #{inspect(socket_pid)}")

    if Process.alive?(socket_pid) do
      GenServer.stop(socket_pid, :normal)
    end

    :ok
  end

  # Private functions - Health Monitoring

  defp schedule_health_check do
    interval = Config.health_check_interval()
    Process.send_after(self(), :health_check, interval)
  end

  defp schedule_cleanup do
    interval = Config.cleanup_interval()
    Process.send_after(self(), :cleanup_subscriptions, interval)
  end

  defp check_connection_health(%{connected: false}), do: {:reconnect, "Not connected"}
  defp check_connection_health(%{socket_pid: nil}), do: {:reconnect, "No socket PID"}

  defp check_connection_health(%{socket_pid: socket_pid, connected: true}) do
    if Process.alive?(socket_pid) do
      :ok
    else
      {:reconnect, "Socket process died"}
    end
  end

  defp get_health_metrics(state) do
    %{
      connected: state.connected,
      socket_alive: case state.socket_pid do
        nil -> false
        pid -> Process.alive?(pid)
      end,
      retry_count: state.retry_state.retry_count,
      subscribed_systems_count: MapSet.size(state.subscribed_systems)
    }
  end

  # Private functions - Retry Logic

  defp schedule_retry(retry_state) do
    delay = get_retry_delay(retry_state)
    Logger.info("[KillsClient] Scheduling retry in #{delay}ms")
    Process.send_after(self(), :retry_connection, delay)
  end

  defp increment_retry(%{retry_count: count, cycle_count: cycles} = state) do
    max_retries = Config.max_retries()

    if count < max_retries do
      %{state | retry_count: count + 1}
    else
      %{retry_count: 0, cycle_count: cycles + 1}
    end
  end

  defp get_retry_delay(%{retry_count: count, cycle_count: _cycles}) do
    max_retries = Config.max_retries()

    if count < max_retries do
      Enum.at(Config.retry_delays(), count)
    else
      Config.cycle_delay()
    end
  end

  # Private functions - Status

  defp get_connection_status(state) do
    %{
      connected: state.connected,
      socket_alive: case state.socket_pid do
        nil -> false
        pid -> Process.alive?(pid)
      end,
      server_url: state.server_url,
      socket_pid: inspect(state.socket_pid)
    }
  end

  defmodule Handler do
    @moduledoc false
    @behaviour Phoenix.Channels.GenSocketClient
    require Logger

    alias WandererApp.Kills.{Config, SystemTracker, MessageHandler}

    @impl true
    def init(state) do
      Logger.info("[KillsClient] Initializing WebSocket connection")
      ws_url = "#{state.server_url}/socket/websocket"
      {:connect, ws_url, [vsn: Config.websocket_version()], state}
    end

    @impl true
    def handle_connected(transport, state) do
      Logger.info("[KillsClient] Connected to WebSocket")

      systems = case SystemTracker.get_tracked_system_ids() do
        {:ok, system_list} -> system_list
        {:error, reason} ->
          Logger.error("[KillsClient] Failed to get tracked systems: #{inspect(reason)}")
          []
      end

      case Phoenix.Channels.GenSocketClient.join(transport, "killmails:lobby", %{
        systems: systems,
        client_identifier: Config.client_identifier()
      }) do
        {:ok, _response} ->
          Logger.info("[KillsClient] Joined killmails:lobby channel")
          send(state.parent, {:connected, self()})
          {:ok, state}

        {:error, reason} ->
          Logger.error("[KillsClient] Failed to join channel: #{inspect(reason)}")
          send(state.parent, {:disconnected, {:join_error, reason}})
          {:ok, state}
      end
    end

    @impl true
    def handle_disconnected(reason, state) do
      Logger.warning("[KillsClient] WebSocket disconnected: #{inspect(reason)}")
      send(state.parent, {:disconnected, reason})
      {:ok, state}
    end

    @impl true
    def handle_channel_closed(topic, _payload, _transport, state) do
      Logger.warning("[KillsClient] Channel #{topic} closed")
      send(state.parent, {:disconnected, {:channel_closed, topic}})
      {:ok, state}
    end

    @impl true
    def handle_message(topic, event, payload, _transport, state) do
      case {topic, event} do
        {"killmails:lobby", "killmail_update"} ->
          Task.start(fn -> MessageHandler.process_killmail_update(payload) end)
          {:ok, state}

        {"killmails:lobby", "kill_count_update"} ->
          Task.start(fn -> MessageHandler.process_kill_count_update(payload) end)
          {:ok, state}

        _ ->
          Logger.debug("[KillsClient] Unhandled message: #{topic}/#{event}")
          {:ok, state}
      end
    end

    @impl true
    def handle_reply(_topic, _ref, payload, _transport, state) do
      Logger.debug("[KillsClient] Received reply: #{inspect(payload)}")
      {:ok, state}
    end

    @impl true
    def handle_info({:subscribe_systems, system_ids}, transport, state) do
      case Phoenix.Channels.GenSocketClient.push(transport, "killmails:lobby", "subscribe_systems", %{systems: system_ids}) do
        {:ok, _ref} ->
          Logger.debug("[KillsClient] Subscription request sent")
          {:ok, state}

        {:error, reason} ->
          Logger.error("[KillsClient] Failed to subscribe: #{inspect(reason)}")
          {:ok, state}
      end
    end

    def handle_info({:unsubscribe_systems, system_ids}, transport, state) do
      case Phoenix.Channels.GenSocketClient.push(transport, "killmails:lobby", "unsubscribe_systems", %{systems: system_ids}) do
        {:ok, _ref} ->
          Logger.debug("[KillsClient] Unsubscription request sent")
          {:ok, state}

        {:error, reason} ->
          Logger.error("[KillsClient] Failed to unsubscribe: #{inspect(reason)}")
          {:ok, state}
      end
    end

    def handle_info(msg, _transport, state) do
      Logger.debug("[KillsClient] Unhandled info message: #{inspect(msg)}")
      {:ok, state}
    end

    @impl true
    def handle_call(msg, _from, _transport, state) do
      Logger.debug("[KillsClient] Unhandled call: #{inspect(msg)}")
      {:reply, {:error, :not_implemented}, state}
    end

    @impl true
    def handle_joined(topic, payload, _transport, state) do
      Logger.info("[KillsClient] Successfully joined #{topic}: #{inspect(payload)}")
      {:ok, state}
    end

    @impl true
    def handle_join_error(topic, payload, _transport, state) do
      Logger.error("[KillsClient] Failed to join #{topic}: #{inspect(payload)}")
      send(state.parent, {:disconnected, {:join_error, {topic, payload}}})
      {:ok, state}
    end
  end
end
