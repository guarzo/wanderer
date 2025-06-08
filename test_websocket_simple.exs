#!/usr/bin/env elixir

# Simple WebSocket connection test
# Usage: elixir test_websocket_simple.exs

Mix.install([
  {:phoenix_gen_socket_client, "~> 4.0"},
  {:jason, "~> 1.4"}
])

defmodule SimpleWebSocketTest do
  @moduledoc """
  Simple WebSocket connection test to verify basic connectivity.
  """

  use GenServer
  require Logger

  alias Phoenix.Channels.GenSocketClient

  @behaviour GenSocketClient

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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
      joined: false
    }

    IO.puts("🚀 Starting simple WebSocket test for #{server_url}")
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect_to_websocket(state) do
      {:ok, socket} ->
        IO.puts("✅ WebSocket connected successfully!")

        # Try to join channel
        case join_channel(socket) do
          {:ok, _response} ->
            new_state = %{state | socket: socket, connected: true, joined: true}
            IO.puts("📡 Successfully joined killmails:lobby channel")
            {:noreply, new_state}

          {:error, reason} ->
            IO.puts("❌ Failed to join channel: #{inspect(reason)}")
            new_state = %{state | socket: socket, connected: true, joined: false}
            {:noreply, new_state}
        end

      {:error, reason} ->
        IO.puts("❌ Connection failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    IO.puts("📨 Received message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      connected: state.connected,
      joined: state.joined,
      server_url: state.server_url
    }

    {:reply, {:ok, status}, state}
  end

  # Phoenix GenSocketClient Callbacks

  @impl GenSocketClient
  def handle_connected(_transport, state) do
    IO.puts("🔗 Transport connected")
    {:ok, state}
  end

  @impl GenSocketClient
  def handle_disconnected(reason, state) do
    IO.puts("📡 WebSocket disconnected: #{inspect(reason)}")
    {:ok, %{state | connected: false, joined: false, socket: nil}}
  end

  @impl GenSocketClient
  def handle_channel_closed(topic, payload, _transport, state) do
    IO.puts("📺 Channel #{topic} closed: #{inspect(payload)}")
    {:ok, %{state | joined: false}}
  end

  @impl GenSocketClient
  def handle_message(topic, event, payload, _transport, state) do
    IO.puts("📩 Received #{event} on #{topic}: #{inspect(payload)}")
    {:ok, state}
  end

  @impl GenSocketClient
  def handle_reply(topic, ref, payload, _transport, state) do
    IO.puts("📬 Reply on #{topic} (#{ref}): #{inspect(payload)}")
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
    GenSocketClient.join(socket, "killmails:lobby", %{})
  end
end

# Main execution
IO.puts("🧪 Starting simple WebSocket connectivity test...")

# Start the test client
{:ok, _pid} = SimpleWebSocketTest.start_link(
  server_url: "ws://localhost:4004"
)

# Wait a bit for connection
Process.sleep(5_000)

# Show status
case SimpleWebSocketTest.get_status() do
  {:ok, status} ->
    IO.puts("📋 Status: #{inspect(status)}")

    if status.connected do
      IO.puts("✅ WebSocket connection successful!")
    else
      IO.puts("❌ WebSocket connection failed")
    end

    if status.joined do
      IO.puts("✅ Channel join successful!")
    else
      IO.puts("❌ Channel join failed (this is expected if WandererKills service is not running)")
    end

  {:error, reason} ->
    IO.puts("❌ Failed to get status: #{inspect(reason)}")
end

IO.puts("�� Test completed")
