defmodule WandererApp.Utils.HttpUtil do
  @moduledoc """
  HTTP utilities for making requests with retries and rate limiting.
  """

  require Logger
  require Retry
  alias Retry.DelayStreams
  alias Req

  @type url :: String.t()
  @type opts :: keyword()
  @type response :: {:ok, map()} | {:error, term()}
  @type error :: term()

  @doc """
  Retries a function with exponential backoff.
  """
  def retry_with_backoff(fun, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    base_delay = Keyword.get(opts, :base_delay, 200)
    max_delay = Keyword.get(opts, :max_delay, 2000)

    Retry.retry(
      with: exponential_backoff(base_delay, max_delay) |> Stream.take(max_retries + 1),
      rescue_only: [RuntimeError]
    ) do
      fun.()
    end
  end

  @doc """
  Makes a GET request with rate limiting.
  """
  def get_with_rate_limit(url, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    base_delay = Keyword.get(opts, :base_delay, 200)
    max_delay = Keyword.get(opts, :max_delay, 2000)

    Retry.retry(
      with: exponential_backoff(base_delay, max_delay) |> Stream.take(max_retries + 1),
      rescue_only: [RuntimeError]
    ) do
      case Req.get(url, decode_body: :json) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: status}} when status in [429, 503] ->
          Logger.info(fn -> "Rate limited, retrying: #{url}" end)
          raise "Rate limited, will retry"

        {:ok, %{status: status}} ->
          {:error, "HTTP #{status}"}

        {:error, %{reason: :timeout}} ->
          Logger.info(fn -> "Request timeout, retrying: #{url}" end)
          raise "Request timeout, will retry"

        {:error, %{reason: :closed}} ->
          Logger.info(fn -> "Connection closed, retrying: #{url}" end)
          raise "Connection closed, will retry"

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Checks if an error is retriable.
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
