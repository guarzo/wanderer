defmodule WandererApp.Zkb.Provider.Redisq do
  @moduledoc """
  Handles real-time kills from zKillboard RedisQ.

  • Idle (no kills): poll every @idle_interval_ms
  • On kill:       poll again after @fast_interval_ms
  • On error:      exponential backoff up to @max_backoff_ms
  """

  use GenServer
  require Logger

  alias WandererApp.Zkb.Provider.Parser
  alias WandererApp.Utils.HttpUtil

  @base_url           "https://zkillredisq.stream/listen.php"
  @fast_interval_ms   1_000
  @idle_interval_ms   5_000
  @initial_backoff_ms 1_000
  @max_backoff_ms     30_000
  @backoff_factor     2

  defmodule State do
    @moduledoc false
    defstruct [:queue_id, :backoff]
  end

  ## Public API

  @doc """
  Starts the RedisQ listener.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    queue_id = build_queue_id()
    state = %State{queue_id: queue_id, backoff: @initial_backoff_ms}
    schedule_poll(@idle_interval_ms)
    {:ok, state}
  end

  @impl true
  # Single handle_info clause that drives both scheduling and backoff
  def handle_info(:poll_kills, %State{queue_id: queue_id, backoff: backoff} = state) do
    case poll_and_process(queue_id) do
      {:ok, :kill_received} ->
        schedule_poll(@fast_interval_ms)
        {:noreply, %{state | backoff: @initial_backoff_ms}}

      {:ok, :no_kills} ->
        schedule_poll(@idle_interval_ms)
        {:noreply, %{state | backoff: @initial_backoff_ms}}

      {:error, _reason} ->
        next_backoff = min(backoff * @backoff_factor, @max_backoff_ms)
        schedule_poll(next_backoff)
        {:noreply, %{state | backoff: next_backoff}}
    end
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  ## Internal

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll_kills, ms)
  end

  # Combines polling the RedisQ endpoint with processing whatever comes back
  defp poll_and_process(queue_id) do
    url = "#{@base_url}?queueID=#{queue_id}"

    case HttpUtil.get_with_rate_limit(url, bucket: "redisq", limit: 5, scale_ms: @fast_interval_ms) do
      {:ok, %{"package" => nil}} ->
        {:ok, :no_kills}

      # new-format payload: inline killmail + zkb
      {:ok, %{"package" => %{"killmail" => killmail, "zkb" => zkb}}} ->
        Parser.parse_and_store_killmail(Map.put(killmail, "zkb", zkb))
        {:ok, :kill_received}

      # legacy-format payload: only killID + zkb; fetch full mail
      {:ok, %{"killID" => id, "zkb" => zkb}} ->
        fetch_and_process_full_kill(id, zkb)
        {:ok, :kill_received}

      {:ok, other} ->
        Logger.warning("[RedisQ] Unexpected response: #{inspect(other)}")
        {:error, :unexpected_format}

      {:error, reason} ->
        Logger.warning("[RedisQ] Poll error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Fires off an async task under our TaskSupervisor, so crashes don't leak in here
  defp fetch_and_process_full_kill(id, zkb) do
    Task.Supervisor.async_nolink(WandererApp.TaskSupervisor, fn ->
      case WandererApp.Esi.ApiClient.get_killmail(id, zkb["hash"]) do
        {:ok, killmail} ->
          Parser.parse_and_store_killmail(Map.put(killmail, "zkb", zkb))

        {:error, reason} ->
          Logger.warning("[RedisQ] Fetch error for #{id}: #{inspect(reason)}")
      end
    end)
    |> Task.await(10_000)
  catch
    :exit, {:timeout, _} ->
      Logger.error("[RedisQ] Timeout fetching killmail #{id}")
  end

  defp build_queue_id do
    base =
      Application.get_env(:wanderer_app, :secret_key_base)
      |> case do
        nil -> "wanderer_default"
        s   -> "wanderer_#{s}"
      end

    :crypto.hash(:sha256, base)
    |> Base.encode16()
    |> String.slice(0, 15)
  end
end
