defmodule WandererApp.Zkb.HttpClient do
  @moduledoc """
  HTTP client for zKillboard API with built-in rate limiting and error handling.
  """

  require Logger
  alias WandererApp.Utils.HttpUtil
  use Retry

  @zkillboard_api "https://zkillboard.com/api"
  @redisq_url "https://zkillredisq.stream/listen.php"
  @rate_limit 10
  @rate_scale_ms 1_000

  @type url :: String.t()
  @type opts :: keyword()
  @type response :: {:ok, map()} | {:error, term()}

  @doc """
  Fetches kills for a given system ID with rate limiting.

  ## Parameters
    - system_id: The EVE Online solar system ID to fetch kills for
    - opts: Optional parameters for the request

  ## Returns
    - `{:ok, kills}` on success, where kills is the parsed JSON response
    - `{:error, reason}` on failure
  """
  @spec fetch_kills(integer(), keyword()) :: response()
  def fetch_kills(system_id, opts \\ []) when is_integer(system_id) do
    url = "#{@zkillboard_api}/kills/systemID/#{system_id}/"
    Logger.info("[Zkb.HttpClient] Fetching kills from url=#{url}")

    case HttpUtil.get_with_rate_limit(url,
           limit: @rate_limit,
           scale_ms: @rate_scale_ms,
           bucket: "zkillboard"
         ) do
      {:ok, %{status: 200, body: kills}} ->
        Logger.info("[Zkb.HttpClient] Successfully fetched #{length(kills)} kills for system=#{system_id}")
        {:ok, kills}

      {:ok, %{status: status}} ->
        Logger.error("[Zkb.HttpClient] Failed to fetch kills for system=#{system_id}, status=#{status}")
        {:error, "HTTP #{status}"}

      {:error, :rate_limited} ->
        Logger.warning("[Zkb.HttpClient] Rate limited for system=#{system_id}")
        {:error, :rate_limited}

      {:error, reason} ->
        Logger.error("[Zkb.HttpClient] Error fetching kills for system=#{system_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetches kills for a given system ID and page number with rate limiting.

  ## Parameters
    - system_id: The EVE Online solar system ID to fetch kills for
    - page: The page number to fetch

  ## Returns
    - `{:ok, kills}` on success, where kills is the parsed JSON response
    - `{:error, reason}` on failure
  """
  @spec fetch_kills_page(system_id :: integer(), page :: integer()) :: response()
  def fetch_kills_page(system_id, page) when is_integer(system_id) and is_integer(page) do
    url = "#{@zkillboard_api}/kills/systemID/#{system_id}/page/#{page}/"

    case HttpUtil.get_with_rate_limit(url,
           limit: @rate_limit,
           scale_ms: @rate_scale_ms,
           bucket: "zkillboard"
         ) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.error("[Zkb.HttpClient] Failed to fetch kills page for system=#{system_id}, page=#{page}, status=#{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.error("[Zkb.HttpClient] Failed to fetch kills page for system=#{system_id}, page=#{page}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Polls the RedisQ endpoint for real-time killmails.

  ## Parameters
    - queue_id: The RedisQ queue ID to listen to

  ## Returns
    - `{:ok, package}` on success, where package is the parsed JSON response
    - `{:ok, nil}` if no new kills are available
    - `{:error, reason}` on failure
  """
  @spec poll_redisq(queue_id :: String.t()) :: response()
  def poll_redisq(queue_id) do
    url = "#{@redisq_url}?queueID=#{queue_id}"

    case Req.get(url, decode_body: :json) do
      {:ok, %{status: 200, body: %{"package" => nil}}} ->
        {:ok, nil}

      {:ok, %{status: 200, body: %{"package" => package}}} when is_map(package) ->
        {:ok, package}

      {:error, reason} ->
        Logger.warning("[Zkb.HttpClient] RedisQ poll failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Makes an HTTP request with automatic retry logic.

  ## Parameters
    - url: The URL to request
    - opts: Options for the request and retry logic

  ## Returns
    - `{:ok, response}` on success
    - `{:error, reason}` on failure
  """
  @spec request_with_retry(url(), opts()) :: response()
  def request_with_retry(url, opts \\ []) do
    retry_opts = [
      rescue_only: [RuntimeError],
      max_retries: Keyword.get(opts, :max_retries, 3),
      base_backoff: Keyword.get(opts, :base_backoff, 300),
      max_backoff: Keyword.get(opts, :max_backoff, 5_000),
      expiry: Keyword.get(opts, :expiry, 30_000)
    ]

    retry with: exponential_backoff(retry_opts[:base_backoff])
           |> randomize()
           |> cap(retry_opts[:max_backoff])
           |> expiry(retry_opts[:expiry]), rescue_only: retry_opts[:rescue_only] do
      case Req.get(url, decode_body: :json) do
        {:ok, %{status: 200} = resp} ->
          {:ok, resp}

        {:ok, %{status: status}} ->
          Logger.warning("[Zkb.HttpClient] Request failed with status #{status}: #{url}")
          raise "HTTP status #{status}"

        {:error, reason} ->
          if HttpUtil.retriable_error?(reason) do
            Logger.warning("[Zkb.HttpClient] Retriable error: #{inspect(reason)}")
            raise "Retriable error: #{inspect(reason)}"
          else
            {:error, reason}
          end
      end
    end
  end

  @doc """
  Make a general HTTP GET request to zKillboard.
  Returns {:ok, response} or {:error, reason}.
  """
  @spec get_json(url()) :: response()
  def get_json(url) do
    case HttpUtil.get_with_rate_limit(url,
           limit: @rate_limit,
           scale_ms: @rate_scale_ms,
           bucket: "zkillboard"
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 429}} ->
        Logger.warning("[Zkb.HttpClient] Rate limit exceeded for URL=#{url}")
        {:error, :rate_limit_exceeded}

      {:ok, %{status: status}} ->
        Logger.warning("[Zkb.HttpClient] Unexpected status code #{status} for URL=#{url}")
        {:error, :unexpected_status}

      {:error, reason} ->
        Logger.warning("[Zkb.HttpClient] Failed to fetch URL=#{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp zkb_url(system_id) do
    "#{@zkillboard_api}/kills/systemID/#{system_id}/"
  end
end
