defmodule WandererApp.ExternalEvents.SseStreamManager do
  @moduledoc """
  Manages Server-Sent Events (SSE) connections for a specific map.

  This GenServer maintains active SSE client connections, handles event broadcasting
  to connected clients based on their event filters, and manages client lifecycle
  including disconnections and crashes.

  One instance is started per map under the ExternalEvents supervision tree.
  """

  use GenServer
  require Logger

  alias WandererApp.ExternalEvents.EventFilter

  defstruct [
    :map_id,
    # %{pid => %{filter: event_filter, connected_at: DateTime}}
    clients: %{},
    # %{monitor_ref => pid}
    client_monitors: %{}
  ]

  @type client_info :: %{
          filter: EventFilter.event_filter(),
          connected_at: DateTime.t()
        }

  @doc """
  Starts a new SSE stream manager for the given map.
  """
  def start_link(map_id) do
    GenServer.start_link(__MODULE__, map_id, name: via(map_id))
  end

  @doc """
  Adds a new SSE client connection to the stream manager.

  Returns {:ok, manager_pid} on success.
  """
  @spec add_client(String.t(), pid(), EventFilter.event_filter()) ::
          {:ok, pid()} | {:error, term()}
  def add_client(map_id, client_pid, event_filter) do
    GenServer.call(via(map_id), {:add_client, client_pid, event_filter})
  end

  @doc """
  Removes a client connection from the stream manager.
  """
  @spec remove_client(String.t(), pid()) :: :ok
  def remove_client(map_id, client_pid) do
    GenServer.call(via(map_id), {:remove_client, client_pid})
  catch
    # Manager might be gone already
    :exit, _ -> :ok
  end

  @doc """
  Broadcasts an event to all connected SSE clients based on their filters.
  """
  @spec broadcast_event(String.t(), map()) :: :ok
  def broadcast_event(map_id, event) do
    GenServer.cast(via(map_id), {:broadcast_event, event})
  catch
    # Manager might not exist yet
    :exit, _ -> :ok
  end

  @doc """
  Gets the current count of connected clients for a map.
  """
  @spec get_client_count(String.t()) :: non_neg_integer()
  def get_client_count(map_id) do
    GenServer.call(via(map_id), :get_client_count)
  catch
    :exit, _ -> 0
  end

  @doc """
  Gets detailed information about connected clients.
  """
  @spec get_client_info(String.t()) :: %{pid() => client_info()}
  def get_client_info(map_id) do
    GenServer.call(via(map_id), :get_client_info)
  catch
    :exit, _ -> %{}
  end

  # GenServer callbacks

  @impl true
  def init(map_id) do
    Logger.info("Starting SSE stream manager for map #{map_id}")

    state = %__MODULE__{
      map_id: map_id,
      clients: %{},
      client_monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:add_client, client_pid, event_filter}, _from, state) do
    Logger.debug("Adding SSE client #{inspect(client_pid)} to map #{state.map_id}")

    # Monitor the client process to detect disconnections
    monitor_ref = Process.monitor(client_pid)

    client_info = %{
      filter: event_filter,
      connected_at: DateTime.utc_now()
    }

    new_state = %{
      state
      | clients: Map.put(state.clients, client_pid, client_info),
        client_monitors: Map.put(state.client_monitors, monitor_ref, client_pid)
    }

    Logger.info(
      "SSE client connected to map #{state.map_id}. Total clients: #{map_size(new_state.clients)}"
    )

    {:reply, {:ok, self()}, new_state}
  end

  @impl true
  def handle_call({:remove_client, client_pid}, _from, state) do
    new_state = remove_client_from_state(client_pid, state)

    Logger.info(
      "SSE client disconnected from map #{state.map_id}. Total clients: #{map_size(new_state.clients)}"
    )

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_client_count, _from, state) do
    {:reply, map_size(state.clients), state}
  end

  @impl true
  def handle_call(:get_client_info, _from, state) do
    {:reply, state.clients, state}
  end

  @impl true
  def handle_cast({:broadcast_event, event}, state) do
    # Count clients that will receive this event
    matching_clients =
      Enum.count(state.clients, fn {_pid, %{filter: filter}} ->
        EventFilter.matches?(event.type, filter)
      end)

    if matching_clients > 0 do
      Logger.debug(
        "Broadcasting #{event.type} event to #{matching_clients}/#{map_size(state.clients)} SSE clients on map #{state.map_id}"
      )

      # Send event to each client that has matching filter
      Enum.each(state.clients, fn {pid, %{filter: filter}} ->
        if EventFilter.matches?(event.type, filter) do
          send(pid, {:sse_event, event})
        end
      end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    # Handle client process termination
    client_pid = Map.get(state.client_monitors, monitor_ref)

    if client_pid do
      Logger.debug(
        "SSE client #{inspect(client_pid)} disconnected from map #{state.map_id}: #{inspect(reason)}"
      )

      new_state = remove_client_from_state(client_pid, state)

      Logger.info(
        "SSE client terminated on map #{state.map_id}. Total clients: #{map_size(new_state.clients)}"
      )

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # Private functions

  defp via(map_id) do
    {:via, Registry, {WandererApp.Registry, {:sse_stream_manager, map_id}}}
  end

  defp remove_client_from_state(client_pid, state) do
    # Find the monitor ref for this client
    {monitor_ref, _} =
      Enum.find(state.client_monitors, {nil, nil}, fn {_ref, pid} ->
        pid == client_pid
      end)

    # Demonitor if we found the ref
    if monitor_ref do
      Process.demonitor(monitor_ref, [:flush])
    end

    %{
      state
      | clients: Map.delete(state.clients, client_pid),
        client_monitors: Map.delete(state.client_monitors, monitor_ref)
    }
  end
end
