#!/usr/bin/env elixir

# Corrected WebSocket test following phoenix_gen_socket_client 4.0 patterns
# Usage: elixir test_websocket_corrected.exs

Mix.install([
  {:phoenix_gen_socket_client, "~> 4.0"},
  {:websocket_client, "~> 1.2"},
  {:jason, "~> 1.4"}
])

defmodule CorrectedWebSocketTest do
  @moduledoc """
  Corrected WebSocket test following phoenix_gen_socket_client 4.0 patterns.
  """

  require Logger

  alias Phoenix.Channels.GenSocketClient

  @behaviour GenSocketClient

  def start_link(opts \\ []) do
    server_url = Keyword.get(opts, :server_url, "ws://localhost:4004")

    socket_opts = [
      url: "#{server_url}/socket/websocket",
      params: %{vsn: "2.0.0"},
      serializer: Jason
    ]

    initial_state = %{
      server_url: server_url,
      connected: false,
      joined: false
    }

    GenSocketClient.start_link(
      __MODULE__,
      Phoenix.Channels.GenSocketClient.Transport.WebSocketClient,
      initial_state,
      socket_opts,
      [name: __MODULE__]
    )
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # Phoenix GenSocketClient Callbacks

  @impl GenSocketClient
  def init(state) do
    IO.puts("🚀 Starting corrected WebSocket test for #{state.server_url}")
    {:connect, state.server_url <> "/socket/websocket", %{}, state}
  end

  @impl GenSocketClient
  def handle_connected(transport, state) do
    IO.puts("✅ WebSocket connected successfully!")

    # Join the channel after connection
    case GenSocketClient.join(transport, "killmails:lobby") do
      {:ok, _response} ->
        new_state = %{state | connected: true, joined: true}
        IO.puts("📡 Successfully joined killmails:lobby channel")
        {:ok, new_state}

      {:error, reason} ->
        IO.puts("❌ Failed to join channel: #{inspect(reason)}")
        new_state = %{state | connected: true, joined: false}
        {:ok, new_state}
    end
  end

  @impl GenSocketClient
  def handle_disconnected(reason, state) do
    IO.puts("📡 WebSocket disconnected: #{inspect(reason)}")
    {:ok, %{state | connected: false, joined: false}}
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

  @impl GenSocketClient
  def handle_info(msg, _transport, state) do
    IO.puts("📨 Received message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl GenSocketClient
  def handle_call(:get_status, _from, _transport, state) do
    status = %{
      connected: state.connected,
      joined: state.joined,
      server_url: state.server_url
    }

    {:reply, {:ok, status}, state}
  end

  @impl GenSocketClient
  def handle_cast(_msg, _transport, state) do
    {:ok, state}
  end
end

# Main execution
IO.puts("🧪 Starting corrected WebSocket connectivity test...")

# Start the test client
{:ok, _pid} = CorrectedWebSocketTest.start_link(
  server_url: "ws://localhost:4004"
)

# Wait a bit for connection
Process.sleep(5_000)

# Show status
case CorrectedWebSocketTest.get_status() do
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

IO.puts(" Test completed")
