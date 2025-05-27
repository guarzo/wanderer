defmodule WandererApp.Zkb.KillsProvider.ZkbApi do
  @moduledoc """
  A small module for making HTTP requests to zKillboard and
  parsing JSON responses, separate from the multi-page logic.
  """

  require Logger
  alias WandererApp.Zkb.HttpClient

  @doc """
  Perform rate-limit check before fetching a single page from zKillboard and parse the response.

  Returns:
    - `{:ok, updated_state, partials_list}` on success
    - `{:error, reason, updated_state}` if error
  """
  def fetch_and_parse_page(system_id, page, %{calls_count: _} = state) do
    case HttpClient.fetch_kills_page(system_id, page) do
      {:ok, partials} when is_list(partials) ->
        {:ok, state, partials}

      {:error, reason} ->
        {:error, reason, state}
    end
  end
end
