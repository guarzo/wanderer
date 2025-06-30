defmodule WandererAppWeb.SSE do
  @moduledoc """
  Server-Sent Events helper functions for establishing and managing SSE connections.

  Provides utilities for:
  - Setting up SSE response headers
  - Formatting events according to SSE specification
  - Sending events and keepalive messages
  - Handling connection errors gracefully
  """

  import Plug.Conn

  @doc """
  Sets up SSE-specific response headers and begins a chunked response.

  Returns a conn ready for streaming SSE data.
  """
  def send_headers(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-headers", "authorization")
    # Disable Nginx buffering
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  @doc """
  Formats an event according to the SSE specification.

  Includes the event ID for client-side reconnection support.
  """
  def format_event(event) do
    data = Jason.encode!(event)
    "id: #{event.id}\ndata: #{data}\n\n"
  end

  @doc """
  Sends an event to the SSE connection.

  Returns {:ok, conn} on success or {:error, reason} on failure.
  """
  def send_event(conn, event) do
    case chunk(conn, format_event(event)) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends a keepalive comment to maintain the connection.

  SSE clients ignore lines starting with ':'.
  """
  def send_keepalive(conn) do
    case chunk(conn, ": keepalive\n\n") do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends a retry hint to the client for reconnection delay.

  Time is in milliseconds.
  """
  def send_retry(conn, time_ms) do
    case chunk(conn, "retry: #{time_ms}\n\n") do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end
end
