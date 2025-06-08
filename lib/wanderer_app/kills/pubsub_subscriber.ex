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

      # Start WebSocket client
      case WebSocketClient.start_link() do
        {:ok, _pid} ->
          Logger.info("[PubSubSubscriber] ✅ WebSocket client started successfully")
        {:error, reason} ->
          Logger.error("[PubSubSubscriber] ❌ Failed to start WebSocket client: #{inspect(reason)}")
      end
    else
      Logger.info("[PubSubSubscriber] WandererKills service disabled, using legacy zkillboard")
    end

    {:ok, state}
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

  def update_subscriptions do
    if Application.get_env(:wanderer_app, :use_wanderer_kills_service, false) do
      WebSocketClient.update_subscriptions()
    else
      Logger.debug("[PubSubSubscriber] WandererKills service disabled, ignoring subscription update")
    end
  end
end
