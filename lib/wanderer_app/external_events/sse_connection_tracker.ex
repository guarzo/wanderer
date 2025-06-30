defmodule WandererApp.ExternalEvents.SseConnectionTracker do
  @moduledoc """
  Tracks and enforces connection limits for SSE connections.

  Maintains counts of active connections per map and per API key to prevent
  resource exhaustion. Uses ETS for efficient concurrent access.
  """

  use GenServer
  require Logger

  @table_name :sse_connection_tracker
  @cleanup_interval :timer.minutes(5)

  @doc """
  Starts the SSE connection tracker.
  """
  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Checks if a new connection would exceed configured limits.

  Returns :ok if within limits, or {:error, reason} if limits would be exceeded.
  """
  @spec check_limits(String.t(), String.t()) :: :ok | {:error, atom()}
  def check_limits(map_id, api_key) do
    GenServer.call(__MODULE__, {:check_limits, map_id, api_key})
  end

  @doc """
  Tracks a new SSE connection.

  Should be called after check_limits returns :ok.
  """
  @spec track_connection(String.t(), String.t(), pid()) :: :ok
  def track_connection(map_id, api_key, pid) do
    GenServer.call(__MODULE__, {:track_connection, map_id, api_key, pid})
  end

  @doc """
  Removes a tracked connection.

  Called when a connection is closed.
  """
  @spec remove_connection(String.t(), String.t(), pid()) :: :ok
  def remove_connection(map_id, api_key, pid) do
    GenServer.call(__MODULE__, {:remove_connection, map_id, api_key, pid})
  end

  @doc """
  Gets current connection statistics.
  """
  @spec get_stats() :: %{maps: map(), api_keys: map(), total_connections: non_neg_integer()}
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # GenServer callbacks

  @impl true
  def init([]) do
    # Create ETS table for connection tracking
    :ets.new(@table_name, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:check_limits, map_id, api_key}, _from, state) do
    map_count = count_connections_for_map(map_id)
    key_count = count_connections_for_api_key(api_key)

    result =
      cond do
        map_count >= max_connections_per_map() ->
          Logger.warning(
            "SSE connection limit exceeded for map #{map_id}: #{map_count}/#{max_connections_per_map()}"
          )

          {:error, :map_connection_limit_exceeded}

        key_count >= max_connections_per_api_key() ->
          Logger.warning(
            "SSE connection limit exceeded for API key: #{key_count}/#{max_connections_per_api_key()}"
          )

          {:error, :api_key_connection_limit_exceeded}

        true ->
          :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:track_connection, map_id, api_key, pid}, _from, state) do
    # Monitor the connection process
    monitor_ref = Process.monitor(pid)

    # Store connection info
    connection_info = %{
      map_id: map_id,
      api_key: api_key,
      pid: pid,
      monitor_ref: monitor_ref,
      connected_at: DateTime.utc_now()
    }

    :ets.insert(@table_name, {pid, connection_info})

    Logger.debug("Tracked SSE connection #{inspect(pid)} for map #{map_id}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove_connection, _map_id, _api_key, pid}, _from, state) do
    case :ets.lookup(@table_name, pid) do
      [{^pid, %{monitor_ref: ref}}] ->
        Process.demonitor(ref, [:flush])
        :ets.delete(@table_name, pid)
        Logger.debug("Removed SSE connection #{inspect(pid)}")

      _ ->
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    connections = :ets.tab2list(@table_name)

    stats = %{
      total_connections: length(connections),
      maps: count_by_field(connections, :map_id),
      api_keys: count_by_field(connections, :api_key)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Handle process termination
    case :ets.lookup(@table_name, pid) do
      [{^pid, _info}] ->
        :ets.delete(@table_name, pid)
        Logger.debug("SSE connection #{inspect(pid)} terminated")

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Clean up any stale entries (shouldn't normally happen due to monitors)
    cleanup_stale_connections()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp count_connections_for_map(map_id) do
    :ets.foldl(
      fn
        {_pid, %{map_id: ^map_id}}, acc -> acc + 1
        _, acc -> acc
      end,
      0,
      @table_name
    )
  end

  defp count_connections_for_api_key(api_key) do
    :ets.foldl(
      fn
        {_pid, %{api_key: ^api_key}}, acc -> acc + 1
        _, acc -> acc
      end,
      0,
      @table_name
    )
  end

  defp count_by_field(connections, field) do
    Enum.reduce(connections, %{}, fn {_pid, info}, acc ->
      key = Map.get(info, field)
      Map.update(acc, key, 1, &(&1 + 1))
    end)
  end

  defp cleanup_stale_connections do
    # Remove any connections where the process is no longer alive
    stale_pids =
      :ets.foldl(
        fn {pid, _info}, acc ->
          if Process.alive?(pid), do: acc, else: [pid | acc]
        end,
        [],
        @table_name
      )

    Enum.each(stale_pids, &:ets.delete(@table_name, &1))

    if length(stale_pids) > 0 do
      Logger.info("Cleaned up #{length(stale_pids)} stale SSE connections")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp max_connections_per_map do
    Application.get_env(:wanderer_app, :sse, [])
    |> Keyword.get(:max_connections_per_map, 50)
  end

  defp max_connections_per_api_key do
    Application.get_env(:wanderer_app, :sse, [])
    |> Keyword.get(:max_connections_per_api_key, 10)
  end
end
