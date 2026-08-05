defmodule WandererApp.Market.Triff.HttpClient do
  @moduledoc """
  Seam over HTTP calls to triff.tools, so market pricing can be tested without a
  live endpoint. The real implementation uses an isolated Finch pool.

  Mirrors `WandererApp.ExternalEvents.Discord.HttpClient`.
  """

  @callback get(url :: String.t(), headers :: list()) ::
              {:ok, status :: integer(), body :: binary()} | {:error, term()}

  @doc "Returns the configured implementation module."
  def impl do
    Application.get_env(
      :wanderer_app,
      :triff_http_client,
      WandererApp.Market.Triff.HttpClient.Live
    )
  end

  @doc "Issues a GET, delegating to the configured implementation."
  def get(url, headers \\ []), do: impl().get(url, headers)

  defmodule Live do
    @moduledoc """
    Real HTTP delivery via the isolated triff Finch pool.

    Named `Live` rather than `Finch` so the nested module does not shadow the
    Finch library inside its own body.
    """
    @behaviour WandererApp.Market.Triff.HttpClient

    # A backstop, not the real deadline. In the dispatcher path the enrichment
    # task is brutally killed at `notable_items_timeout_ms` (1.5s by default),
    # well before this fires; this only bounds a caller running outside that
    # budget, so a hung socket cannot hold a pool connection indefinitely.
    @timeout 5_000

    @impl true
    def get(url, headers) do
      :get
      |> Finch.build(url, headers)
      |> Finch.request(WandererApp.Finch.Triff, receive_timeout: @timeout)
      |> case do
        {:ok, %Finch.Response{status: status, body: body}} -> {:ok, status, body}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
