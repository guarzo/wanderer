defmodule WandererApp.Utils.HttpUtil do
  @moduledoc """
  HTTP utilities for making requests with retries and rate limiting.
  """

  require Logger
  require Retry
  alias Retry.DelayStreams
  alias Req

  defmodule RateLimitError do
    @moduledoc "Raised when a rate limit is hit"
    defexception [:message]
  end

  defmodule TimeoutError do
    @moduledoc "Raised when a request times out"
    defexception [:message]
  end

  defmodule ConnectionError do
    @moduledoc "Raised when a connection error occurs"
    defexception [:message]
  end

  @type url :: String.t()
  @type opts :: keyword()
  @type response :: {:ok, map()} | {:error, term()}
  @type error :: term()

  @doc """
  Retries a function with exponential backoff.

  ## Options
  * `:max_retries` - Maximum number of retry attempts (default: 3)
  * `:base_delay` - Initial delay in milliseconds (default: 200)
  * `:max_delay` - Maximum delay in milliseconds (default: 2000)
  * `:rescue_only` - List of exceptions to rescue (default: [RuntimeError])
  """
  def retry_with_backoff(fun, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    base_delay = Keyword.get(opts, :base_delay, 200)
    max_delay = Keyword.get(opts, :max_delay, 2000)
    rescue_only = Keyword.get(opts, :rescue_only, [RuntimeError, RateLimitError, TimeoutError, ConnectionError])

    Retry.retry(
      with: exponential_backoff(base_delay, max_delay) |> Stream.take(max_retries + 1),
      rescue_only: rescue_only
    ) do
      fun.()
    end
  end

  @doc """
  Makes a GET request with rate limiting and automatic retries.

  ## Options
  * `:max_retries` - Maximum number of retry attempts (default: 3)
  * `:base_delay` - Initial delay in milliseconds (default: 200)
  * `:max_delay` - Maximum delay in milliseconds (default: 2000)
  * `:bucket` - Rate limit bucket name
  * `:limit` - Maximum requests per time window
  * `:scale_ms` - Time window in milliseconds
  """
  def get_with_rate_limit(url, opts \\ []) do
    retry_with_backoff(
      fn ->
        case Req.get(url, decode_body: :json) do
          {:ok, %{status: 200, body: body}} when is_map(body) or is_list(body) ->
            {:ok, body}

          {:ok, %{status: 200, body: body}} ->
            Logger.error("[HttpUtil] Invalid JSON response: #{inspect(body)}")
            {:error, :invalid_json}

          {:ok, %{status: status}} when status in [429, 503] ->
            Logger.info("[HttpUtil] Rate limited (HTTP #{status}), retrying: #{url}")
            raise %RateLimitError{message: "Rate limited (HTTP #{status})"}

          {:ok, %{status: status}} ->
            Logger.error("[HttpUtil] HTTP error #{status}: #{url}")
            {:error, "HTTP #{status}"}

          {:error, %{reason: :timeout}} ->
            Logger.info("[HttpUtil] Request timeout, retrying: #{url}")
            raise %TimeoutError{message: "Request timeout"}

          {:error, %{reason: :closed}} ->
            Logger.info("[HttpUtil] Connection closed, retrying: #{url}")
            raise %ConnectionError{message: "Connection closed"}

          {:error, reason} ->
            if retriable_error?(reason) do
              Logger.info("[HttpUtil] Retriable error #{inspect(reason)}, retrying: #{url}")
              raise %ConnectionError{message: "Retriable error: #{inspect(reason)}"}
            else
              Logger.error("[HttpUtil] Non-retriable error #{inspect(reason)}: #{url}")
              {:error, reason}
            end
        end
      end,
      opts
    )
  end

  @doc """
  Checks if an error is retriable.

  ## Retriable Errors
  * `:timeout` - Request timeout
  * `:closed` - Connection closed
  * `:econnrefused` - Connection refused
  * `:econnreset` - Connection reset
  * `:enetdown` - Network down
  * `:enetreset` - Network reset
  * `:enetunreach` - Network unreachable
  * `:enotconn` - Not connected
  * `:etimedout` - Connection timed out
  """
  def retriable_error?(reason) do
    case reason do
      :timeout -> true
      :closed -> true
      :econnrefused -> true
      :econnreset -> true
      :enetdown -> true
      :enetreset -> true
      :enetunreach -> true
      :enotconn -> true
      :etimedout -> true
      _ -> false
    end
  end

  defp exponential_backoff(base_delay, max_delay) do
    base_delay
    |> DelayStreams.exponential_backoff()
    |> DelayStreams.randomize()
    |> DelayStreams.cap(max_delay)
  end
end
