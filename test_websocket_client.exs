#!/usr/bin/env elixir

# Test script for WandererKills WebSocket client
# Usage: elixir test_websocket_client.exs

Mix.install([
  {:phoenix_gen_socket_client, "~> 4.0"},
  {:jason, "~> 1.4"}
])

defmodule TestWebSocketClient do
  @moduledoc """
  Simple test for WebSocket connectivity to WandererKills service.
  This demonstrates the basic connection and message handling without
  the full Wanderer app context.
  """

  use GenServer
  require Logger

  alias Phoenix.Channels.GenSocketClient

  @behaviour GenSocketClient

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def subscribe_to_systems(system_ids) do
    GenServer.cast(__MODULE__, {:subscribe_systems, system_ids})
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    server_url = Keyword.get(opts, :server_url, "ws://localhost:4004")

    state = %{
      server_url: server_url,
      socket: nil,
      connected: false,
      subscribed_systems: MapSet.new()
    }

    Logger.info("[TestWebSocketClient] Starting test client for #{server_url}")
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect_to_websocket(state) do
      {:ok, socket} ->
        Logger.info("[TestWebSocketClient] ✅ Connected successfully!")

        case join_channel(socket) do
          {:ok, channel} ->
            new_state = %{state | socket: socket, connected: true}
            Logger.info("[TestWebSocketClient] 📡 Joined killmails channel")

            # Subscribe to Jita as a test
            send(self(), {:test_subscribe, [30000142]})
            {:noreply, new_state}

          {:error, reason} ->
            Logger.error("[TestWebSocketClient] ❌ Failed to join channel: #{inspect(reason)}")
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.error("[TestWebSocketClient] ❌ Connection failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:test_subscribe, system_ids}, %{connected: true} = state) do
    Logger.info("[TestWebSocketClient] 🔔 Testing subscription to systems: #{inspect(system_ids)}")

    case push_to_channel(state.socket, "subscribe_systems", %{systems: system_ids}) do
      :ok ->
        new_subscriptions = MapSet.union(state.subscribed_systems, MapSet.new(system_ids))
        new_state = %{state | subscribed_systems: new_subscriptions}
        Logger.info("[TestWebSocketClient] ✅ Subscription successful!")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[TestWebSocketClient] ❌ Subscription failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("[TestWebSocketClient] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:subscribe_systems, system_ids}, %{connected: true} = state) do
    case push_to_channel(state.socket, "subscribe_systems", %{systems: system_ids}) do
      :ok ->
        new_subscriptions = MapSet.union(state.subscribed_systems, MapSet.new(system_ids))
        new_state = %{state | subscribed_systems: new_subscriptions}
        Logger.info("[TestWebSocketClient] ✅ Subscribed to systems: #{inspect(system_ids)}")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[TestWebSocketClient] ❌ Failed to subscribe: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_cast({:subscribe_systems, _}, state) do
    Logger.warning("[TestWebSocketClient] ⚠️  Cannot subscribe: not connected")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      connected: state.connected,
      server_url: state.server_url,
      subscribed_systems: MapSet.to_list(state.subscribed_systems),
      systems_count: MapSet.size(state.subscribed_systems)
    }

    {:reply, {:ok, status}, state}
  end

  # Phoenix GenSocketClient Callbacks

  @impl GenSocketClient
  def handle_connected(_transport, state) do
    Logger.debug("[TestWebSocketClient] 🔗 WebSocket transport connected")
    {:ok, state}
  end

  @impl GenSocketClient
  def handle_disconnected(reason, state) do
    Logger.warning("[TestWebSocketClient] 📡 WebSocket disconnected: #{inspect(reason)}")
    {:ok, %{state | connected: false, socket: nil}}
  end

  @impl GenSocketClient
  def handle_channel_closed(topic, payload, _transport, state) do
    Logger.warning("[TestWebSocketClient] 📺 Channel closed",
      topic: topic,
      payload: inspect(payload)
    )

    {:ok, %{state | connected: false}}
  end

  @impl GenSocketClient
  def handle_message(topic, event, payload, _transport, state) do
    handle_channel_message(topic, event, payload, state)
  end

  @impl GenSocketClient
  def handle_reply(_topic, _ref, _payload, _transport, state) do
    {:ok, state}
  end

  # Private Helper Functions

  defp connect_to_websocket(state) do
    url = "#{state.server_url}/socket/websocket"

    socket_opts = [
      url: url,
      params: %{vsn: "2.0.0"}
    ]

    case GenSocketClient.start_link(__MODULE__, nil, socket_opts) do
      {:ok, socket} -> {:ok, socket}
      error -> error
    end
  end

  defp join_channel(socket) do
    case GenSocketClient.join(socket, "killmails:lobby", %{}) do
      {:ok, _response} -> {:ok, socket}
      error -> error
    end
  end

  defp push_to_channel(socket, event, payload) when is_pid(socket) do
    case GenSocketClient.push(socket, "killmails:lobby", event, payload) do
      {:ok, _ref} -> :ok
      error -> error
    end
  end

  defp push_to_channel(_socket, _event, _payload) do
    {:error, :no_socket}
  end

  defp handle_channel_message("killmails:lobby", "killmail_update", payload, state) do
    system_id = payload["system_id"]
    killmails = payload["killmails"] || []

    Logger.info("[TestWebSocketClient] 🔥 Received #{length(killmails)} killmails for system #{system_id}")

    Enum.with_index(killmails, 1)
    |> Enum.each(fn {killmail, index} ->
      killmail_id = killmail["killmail_id"]
      victim = killmail["victim"] || %{}
      character_name = victim["character_name"] || "Unknown"

      Logger.info("   [#{index}] Killmail ID: #{killmail_id}, Victim: #{character_name}")
    end)

    {:ok, state}
  end

  defp handle_channel_message("killmails:lobby", "kill_count_update", payload, state) do
    system_id = payload["system_id"]
    count = payload["count"]

    Logger.info("[TestWebSocketClient] 📊 Kill count update for system #{system_id}: #{count}")
    {:ok, state}
  end

  defp handle_channel_message(_topic, event, payload, state) do
    Logger.debug("[TestWebSocketClient] 📨 Unhandled message: #{event}",
      payload: inspect(payload)
    )

    {:ok, state}
  end
end

# Main execution
Logger.configure(level: :info)

# Start the test client
{:ok, _pid} = TestWebSocketClient.start_link(
  server_url: "ws://localhost:4004"
)

# Keep the script running
IO.puts("🎧 Test client running. Press Ctrl+C to stop.")

# Run for 30 seconds to see initial connection behavior
Process.sleep(30_000)

# Show final status
case TestWebSocketClient.get_status() do
  {:ok, status} ->
    IO.puts("📋 Final status: #{inspect(status)}")
  {:error, reason} ->
    IO.puts("❌ Failed to get status: #{inspect(reason)}")
end

IO.puts("�� Test completed")
