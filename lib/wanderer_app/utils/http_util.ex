defmodule WandererApp.Utils.HttpUtil do
  @moduledoc """
  HTTP utilities for making requests with rate limiting.
  """

  require Logger

  @type url :: String.t()
  @type opts :: keyword()
  @type response :: {:ok, map()} | {:error, term()}
  @type error :: term()

  @doc """
  Makes an HTTP GET request with rate limiting.
  Returns {:ok, response} or {:error, reason}.
  """
  @spec get_with_rate_limit(url(), opts()) :: {:ok, map()} | {:error, term()}
  def get_with_rate_limit(url, opts \\ []) do
    bucket = Keyword.get(opts, :bucket, "default")
    limit = Keyword.get(opts, :limit, 10)
    scale_ms = Keyword.get(opts, :scale_ms, 1000)

    case ExRated.check_rate(bucket, limit, scale_ms) do
      {:ok, _} ->
        case Req.get(url, decode_body: :json) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, reason}
        end

      {:error, _} ->
        Logger.warning("[HttpUtil] Rate limit exceeded for bucket=#{bucket}, limit=#{limit}/#{scale_ms}ms")
        {:error, :rate_limited}
    end
  end

  @doc """
  Check if an error is retriable.
  """
  def retriable_error?(%{reason: :timeout}), do: true
  def retriable_error?(%{reason: :closed}), do: true
  def retriable_error?(%{reason: :econnrefused}), do: true
  def retriable_error?(%{reason: :econnreset}), do: true
  def retriable_error?(_), do: false
end
