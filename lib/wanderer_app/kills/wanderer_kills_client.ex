defmodule WandererApp.Kills.WandererKillsClient do
  @moduledoc """
  Client for interfacing with the WandererKills service.
  Provides HTTP API calls with retry logic and error handling.
  """

  require Logger
  use Retry

  @base_url Application.compile_env(:wanderer_app, :wanderer_kills_base_url, "http://wanderer-kills:4004/api/v1")
  @timeout 30_000
  @max_retries 3

  @doc """
  Fetch kills for a specific system within the given time range.

  ## Parameters
  - system_id: EVE Online solar system ID
  - since_hours: Hours to look back for kills
  - limit: Maximum kills to return (optional, default: 100)

  ## Returns
  - {:ok, kills} on success
  - {:error, reason} on failure
  """
  def fetch_system_kills(system_id, since_hours, limit \\ 100) do
    url = "#{@base_url}/kills/system/#{system_id}"
    params = %{since_hours: since_hours, limit: limit}

    Logger.debug(fn ->
      "[WandererKillsClient] fetch_system_kills => system_id=#{system_id}, since_hours=#{since_hours}, limit=#{limit}"
    end)

    case http_get(url, params) do
      {:ok, %{"data" => %{"kills" => kills}}} ->
        Logger.debug(fn -> "[WandererKillsClient] fetch_system_kills => got #{length(kills)} kills" end)
        {:ok, kills}
      {:ok, %{"error" => error}} ->
        Logger.warning("[WandererKillsClient] fetch_system_kills => service error: #{error}")
        {:error, error}
      {:error, reason} ->
        Logger.error("[WandererKillsClient] fetch_system_kills => request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetch kills for multiple systems in a single request.

  ## Parameters
  - system_ids: List of EVE Online solar system IDs
  - since_hours: Hours to look back for kills
  - limit: Maximum kills per system (optional, default: 100)

  ## Returns
  - {:ok, systems_kills_map} on success where map is %{system_id => [kills]}
  - {:error, reason} on failure
  """
  def fetch_systems_kills(system_ids, since_hours, limit \\ 100) when is_list(system_ids) do
    url = "#{@base_url}/kills/systems"
    body = %{system_ids: system_ids, since_hours: since_hours, limit: limit}

    Logger.debug(fn ->
      "[WandererKillsClient] fetch_systems_kills => #{length(system_ids)} systems, since_hours=#{since_hours}"
    end)

    case http_post(url, body) do
      {:ok, %{"data" => %{"systems_kills" => systems_kills}}} ->
        total_kills = systems_kills |> Map.values() |> List.flatten() |> length()
        Logger.debug(fn -> "[WandererKillsClient] fetch_systems_kills => got #{total_kills} total kills" end)
        {:ok, systems_kills}
      {:ok, %{"error" => error}} ->
        Logger.warning("[WandererKillsClient] fetch_systems_kills => service error: #{error}")
        {:error, error}
      {:error, reason} ->
        Logger.error("[WandererKillsClient] fetch_systems_kills => request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetch cached kills for a system without triggering fresh data fetch.

  ## Parameters
  - system_id: EVE Online solar system ID

  ## Returns
  - {:ok, kills} on success
  - {:error, reason} on failure
  """
  def fetch_cached_kills(system_id) do
    url = "#{@base_url}/kills/cached/#{system_id}"

    Logger.debug(fn -> "[WandererKillsClient] fetch_cached_kills => system_id=#{system_id}" end)

    case http_get(url, %{}) do
      {:ok, %{"data" => %{"kills" => kills}}} ->
        Logger.debug(fn -> "[WandererKillsClient] fetch_cached_kills => got #{length(kills)} cached kills" end)
        {:ok, kills}
      {:ok, %{"error" => error}} ->
        Logger.warning("[WandererKillsClient] fetch_cached_kills => service error: #{error}")
        {:error, error}
      {:error, reason} ->
        Logger.error("[WandererKillsClient] fetch_cached_kills => request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get the current kill count for a system.

  ## Parameters
  - system_id: EVE Online solar system ID

  ## Returns
  - {:ok, count} on success
  - {:error, reason} on failure
  """
  def get_system_kill_count(system_id) do
    url = "#{@base_url}/kills/count/#{system_id}"

    Logger.debug(fn -> "[WandererKillsClient] get_system_kill_count => system_id=#{system_id}" end)

    case http_get(url, %{}) do
      {:ok, %{"data" => %{"count" => count}}} ->
        Logger.debug(fn -> "[WandererKillsClient] get_system_kill_count => count=#{count}" end)
        {:ok, count}
      {:ok, %{"error" => error}} ->
        Logger.warning("[WandererKillsClient] get_system_kill_count => service error: #{error}")
        {:error, error}
      {:error, reason} ->
        Logger.error("[WandererKillsClient] get_system_kill_count => request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get details for a specific killmail.

  ## Parameters
  - killmail_id: Killmail ID to fetch

  ## Returns
  - {:ok, killmail} on success
  - {:error, reason} on failure
  """
  def get_killmail(killmail_id) do
    url = "#{@base_url}/killmail/#{killmail_id}"

    Logger.debug(fn -> "[WandererKillsClient] get_killmail => killmail_id=#{killmail_id}" end)

    case http_get(url, %{}) do
      {:ok, %{"data" => killmail}} ->
        Logger.debug(fn -> "[WandererKillsClient] get_killmail => got killmail #{killmail_id}" end)
        {:ok, killmail}
      {:ok, %{"error" => error}} ->
        Logger.warning("[WandererKillsClient] get_killmail => service error: #{error}")
        {:error, error}
      {:error, reason} ->
        Logger.error("[WandererKillsClient] get_killmail => request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Subscribe to real-time kill updates for specific systems.

  ## Parameters
  - subscriber_id: Unique identifier for this subscriber
  - system_ids: List of system IDs to subscribe to
  - callback_url: Optional webhook URL for HTTP callbacks

  ## Returns
  - {:ok, subscription_data} on success
  - {:error, reason} on failure
  """
  def subscribe_to_kills(subscriber_id, system_ids, callback_url \\ nil) when is_list(system_ids) do
    url = "#{@base_url}/subscriptions"
    body = %{
      subscriber_id: subscriber_id,
      system_ids: system_ids,
      callback_url: callback_url
    }

    Logger.info("[WandererKillsClient] subscribe_to_kills => subscriber=#{subscriber_id}, systems=#{length(system_ids)}")

    case http_post(url, body) do
      {:ok, %{"data" => data}} ->
        Logger.info("[WandererKillsClient] subscribe_to_kills => subscription created: #{inspect(data)}")
        {:ok, data}
      {:ok, %{"error" => error}} ->
        Logger.warning("[WandererKillsClient] subscribe_to_kills => service error: #{error}")
        {:error, error}
      {:error, reason} ->
        Logger.error("[WandererKillsClient] subscribe_to_kills => request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Remove a subscription.

  ## Parameters
  - subscriber_id: Subscriber ID to remove

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  def unsubscribe_from_kills(subscriber_id) do
    url = "#{@base_url}/subscriptions/#{subscriber_id}"

    Logger.info("[WandererKillsClient] unsubscribe_from_kills => subscriber=#{subscriber_id}")

    case http_delete(url) do
      {:ok, _} ->
        Logger.info("[WandererKillsClient] unsubscribe_from_kills => subscription removed")
        :ok
      {:error, reason} ->
        Logger.error("[WandererKillsClient] unsubscribe_from_kills => request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Check service health.

  ## Returns
  - {:ok, status} on success
  - {:error, reason} on failure
  """
  def health_check() do
    url = "#{@base_url}/health"

    case http_get(url, %{}) do
      {:ok, %{"status" => "ok"} = response} ->
        Logger.debug("[WandererKillsClient] health_check => service healthy")
        {:ok, response}
      {:ok, response} ->
        Logger.warning("[WandererKillsClient] health_check => unexpected response: #{inspect(response)}")
        {:error, "unexpected_response"}
      {:error, reason} ->
        Logger.error("[WandererKillsClient] health_check => request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private HTTP helper functions

  defp http_get(url, params) do
    retry with: exponential_backoff(500) |> randomize() |> cap(5_000) |> Stream.take(@max_retries) do
      case Req.get(url, params: params, decode_body: :json, connect_timeout: @timeout, receive_timeout: @timeout) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}
        {:ok, %{status: 429}} ->
          Logger.debug("[WandererKillsClient] Rate limited, retrying...")
          raise "Rate limited"
        {:ok, %{status: status, body: body}} ->
          {:error, "HTTP #{status}: #{inspect(body)}"}
        {:error, %{reason: :timeout}} ->
          Logger.debug("[WandererKillsClient] Request timeout, retrying...")
          raise "Request timeout"
        {:error, reason} ->
          Logger.debug("[WandererKillsClient] Request failed: #{inspect(reason)}, retrying...")
          raise "Request failed: #{inspect(reason)}"
      end
    end
  rescue
    e ->
      Logger.error("[WandererKillsClient] HTTP GET exhausted retries: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp http_post(url, body) do
    retry with: exponential_backoff(500) |> randomize() |> cap(5_000) |> Stream.take(@max_retries) do
      case Req.post(url, json: body, decode_body: :json, connect_timeout: @timeout, receive_timeout: @timeout) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}
        {:ok, %{status: 429}} ->
          Logger.debug("[WandererKillsClient] Rate limited, retrying...")
          raise "Rate limited"
        {:ok, %{status: status, body: body}} ->
          {:error, "HTTP #{status}: #{inspect(body)}"}
        {:error, %{reason: :timeout}} ->
          Logger.debug("[WandererKillsClient] Request timeout, retrying...")
          raise "Request timeout"
        {:error, reason} ->
          Logger.debug("[WandererKillsClient] Request failed: #{inspect(reason)}, retrying...")
          raise "Request failed: #{inspect(reason)}"
      end
    end
  rescue
    e ->
      Logger.error("[WandererKillsClient] HTTP POST exhausted retries: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp http_delete(url) do
    retry with: exponential_backoff(500) |> randomize() |> cap(5_000) |> Stream.take(@max_retries) do
      case Req.delete(url, connect_timeout: @timeout, receive_timeout: @timeout) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, :deleted}
        {:ok, %{status: 429}} ->
          Logger.debug("[WandererKillsClient] Rate limited, retrying...")
          raise "Rate limited"
        {:ok, %{status: status, body: body}} ->
          {:error, "HTTP #{status}: #{inspect(body)}"}
        {:error, %{reason: :timeout}} ->
          Logger.debug("[WandererKillsClient] Request timeout, retrying...")
          raise "Request timeout"
        {:error, reason} ->
          Logger.debug("[WandererKillsClient] Request failed: #{inspect(reason)}, retrying...")
          raise "Request failed: #{inspect(reason)}"
      end
    end
  rescue
    e ->
      Logger.error("[WandererKillsClient] HTTP DELETE exhausted retries: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end
end
