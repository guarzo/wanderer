defmodule WandererApp.Zkb.KillsProvider.RedisQ do
  @moduledoc """
  Handles real-time kills from zKillboard RedisQ.
  """

  require Logger
  use GenServer
  alias WandererApp.Zkb.KillsProvider.Parser
  alias WandererApp.Utils.HttpUtil

  @base_url "https://zkillredisq.stream/listen.php"


  # Generate a unique queue ID using the secret key base
  @queue_id (
    case Application.compile_env(:wanderer_app, :secret_key_base) do
      nil -> "wanderer_default"
      secret_key_base ->
        "wanderer_#{secret_key_base}"
        |> :crypto.hash(:sha256)
        |> Base.encode16()
        |> String.slice(0, 8)
    end
  )

  @poll_interval_ms 1_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll_kills, state) do
    case poll_kills() do
      :no_kills ->
        schedule_poll()
        {:noreply, state}

      {:ok, package} ->
        process_package(package)
        schedule_poll()
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[RedisQ] Failed to poll kills: #{inspect(reason)}")
        schedule_poll()
        {:noreply, state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll_kills, @poll_interval_ms)
  end

  defp poll_kills do
    url = "#{@base_url}?queueID=#{@queue_id}"

    case HttpUtil.get_with_rate_limit(url, bucket: "redisq", limit: 5, scale_ms: 1000) do
      {:ok, %{status: 200, body: %{"package" => nil}}} ->
        :no_kills

      {:ok, %{status: 200, body: %{"package" => package}}} when is_map(package) ->
        {:ok, package}

      {:ok, %{status: status}} ->
        Logger.warning("[RedisQ] Unexpected status code #{status}")
        {:error, :unexpected_status}

      {:error, reason} ->
        Logger.warning("[RedisQ] Failed to poll kills: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_package(package) do
    case package do
      %{"killID" => kill_id, "zkb" => %{"hash" => kill_hash}} ->
        case WandererApp.Esi.ApiClient.get_killmail(kill_id, kill_hash) do
          {:ok, killmail} ->
            Parser.parse_and_store_killmail(killmail)

          {:error, reason} ->
            Logger.warning("[RedisQ] Failed to fetch full killmail: #{inspect(reason)}")
        end

      _ ->
        Logger.warning("[RedisQ] Invalid package format: #{inspect(package)}")
    end
  end
end
