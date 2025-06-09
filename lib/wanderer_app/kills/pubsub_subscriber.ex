defmodule WandererApp.Kills.PubSubSubscriber do
  @moduledoc """
  Manages subscriptions to kill updates from WandererKills service via WebSocket.
  """

  use GenServer
  require Logger

  alias WandererApp.Kills.WebSocketClient

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    # Start the WebSocket client if WandererKills service is enabled
    if Application.get_env(:wanderer_app, :use_wanderer_kills_service, false) do
      Logger.info("[PubSubSubscriber] Starting WebSocket-based subscription system")

      # Start WebSocket client with retry logic
      case start_websocket_client_with_retry() do
        {:ok, _pid} ->
          Logger.info("[PubSubSubscriber] ✅ WebSocket client started successfully")
          {:ok, state}
        {:error, reason} ->
          Logger.error("[PubSubSubscriber] ❌ Failed to start WebSocket client after retries: #{inspect(reason)}")
          {:stop, {:websocket_client_failed, reason}}
      end
    else
      Logger.info("[PubSubSubscriber] WandererKills service disabled, using legacy zkillboard")
      {:ok, state}
    end
  end

  # Private helper to start WebSocket client with retry logic
  defp start_websocket_client_with_retry(attempt \\ 1, max_attempts \\ 3) do
    case WebSocketClient.start_link() do
      {:ok, pid} ->
        {:ok, pid}
      {:error, reason} when attempt < max_attempts ->
        Logger.warning("[PubSubSubscriber] WebSocket client start attempt #{attempt} failed: #{inspect(reason)}, retrying...")
        :timer.sleep(1000 * attempt)  # Progressive delay: 1s, 2s, 3s
        start_websocket_client_with_retry(attempt + 1, max_attempts)
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def handle_info(message, state) do
    Logger.debug(fn -> "[PubSubSubscriber] Received unhandled message: #{inspect(message)}" end)
    {:noreply, state}
  end

  # Public API for manual subscription management
  def subscribe_to_systems(system_ids) when is_list(system_ids) do
    if Application.get_env(:wanderer_app, :use_wanderer_kills_service, false) do
      WebSocketClient.subscribe_to_systems(system_ids)
    else
      Logger.debug("[PubSubSubscriber] WandererKills service disabled, ignoring subscription request")
    end
  end

  def unsubscribe_from_systems(system_ids) when is_list(system_ids) do
    if Application.get_env(:wanderer_app, :use_wanderer_kills_service, false) do
      WebSocketClient.unsubscribe_from_systems(system_ids)
    else
      Logger.debug("[PubSubSubscriber] WandererKills service disabled, ignoring unsubscription request")
    end
  end

  def get_status do
    if Application.get_env(:wanderer_app, :use_wanderer_kills_service, false) do
      WebSocketClient.get_status()
    else
      {:ok, %{connected: false, reason: "WandererKills service disabled"}}
    end
  end


end
