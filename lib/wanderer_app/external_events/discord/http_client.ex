defmodule WandererApp.ExternalEvents.Discord.HttpClient do
  @moduledoc """
  Seam over HTTP delivery to Discord, so dispatch logic can be tested without
  a live endpoint. The real implementation uses an isolated Finch pool.
  """

  @callback post(url :: String.t(), body :: map()) ::
              {:ok, status :: integer(), headers :: list()} | {:error, term()}

  @doc """
  Reads a Discord REST resource.

  Returns the raw response body rather than decoded JSON so this seam stays
  transport-only: `ChannelInfo` owns the shape of what it asked for, and a
  non-JSON error page from a proxy reaches the caller as data instead of
  raising inside the client.

  `headers` carries the bot `Authorization` for guild-scoped reads. It must
  stay a parameter and never be read from the environment here — the webhook
  identity read (`GET /webhooks/{id}/{token}`) is authorised by the URL alone
  and must not carry a bot token it does not need.
  """
  @callback get(url :: String.t(), headers :: list()) ::
              {:ok, status :: integer(), body :: String.t()} | {:error, term()}

  @doc "Returns the configured implementation module."
  def impl do
    Application.get_env(
      :wanderer_app,
      :discord_http_client,
      WandererApp.ExternalEvents.Discord.HttpClient.Live
    )
  end

  @doc "Posts a Discord message body, delegating to the configured implementation."
  def post(url, body), do: impl().post(url, body)

  @doc "Reads a Discord REST resource, delegating to the configured implementation."
  def get(url, headers \\ []), do: impl().get(url, headers)

  defmodule Live do
    @moduledoc """
    Real HTTP delivery via the isolated Discord Finch pool.

    Named `Live` rather than `Finch` so the nested module does not shadow the
    Finch library inside its own body.
    """
    @behaviour WandererApp.ExternalEvents.Discord.HttpClient

    @timeout 15_000

    # Identity reads sit behind a settings screen, not behind a killmail, so
    # they get a much shorter leash than delivery: a slow Discord must degrade
    # to a masked hint quickly rather than hold a background refresh open for
    # the delivery timeout.
    @read_timeout 5_000

    @impl true
    def post(url, body) do
      headers = [{"content-type", "application/json"}]

      case Jason.encode(body) do
        {:ok, json} ->
          :post
          |> Finch.build(url, headers, json)
          |> Finch.request(WandererApp.Finch.Discord, receive_timeout: @timeout)
          |> case do
            {:ok, %Finch.Response{status: status, headers: resp_headers}} ->
              {:ok, status, resp_headers}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, {:encode_failed, reason}}
      end
    end

    @impl true
    def get(url, headers) do
      :get
      |> Finch.build(url, headers)
      |> Finch.request(WandererApp.Finch.Discord, receive_timeout: @read_timeout)
      |> case do
        {:ok, %Finch.Response{status: status, body: body}} when is_binary(body) ->
          {:ok, status, body}

        {:ok, %Finch.Response{status: status}} ->
          {:ok, status, ""}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
