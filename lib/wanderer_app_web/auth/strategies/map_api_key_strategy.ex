defmodule WandererAppWeb.Auth.Strategies.MapApiKeyStrategy do
  @moduledoc """
  Authentication strategy for Map API keys using Bearer tokens.

  This strategy validates the Bearer token against the map's public API key.
  The map must be already resolved in conn.assigns.map.
  """

  @behaviour WandererAppWeb.Auth.AuthStrategy

  import Plug.Conn
  alias WandererApp.Api.Map

  @impl true
  def name, do: :map_api_key

  @impl true
  def validate_opts(_opts), do: :ok

  @impl true
  def authenticate(conn, _opts) do
    with {:map, %{id: map_id} = map} <- {:map, conn.assigns[:map]},
         {:header, ["Bearer " <> token]} <- {:header, get_req_header(conn, "authorization")},
         {:key, api_key} when not is_nil(api_key) <- {:key, map.public_api_key},
         {:valid, true} <- {:valid, Plug.Crypto.secure_compare(token, api_key)} do
      # Authentication successful
      auth_data = %{
        type: :map_api_key,
        map_id: map_id,
        map: map
      }

      conn =
        conn
        |> assign(:map_id, map_id)
        |> assign(:authenticated_by, :map_api_key)

      {:ok, conn, auth_data}
    else
      {:map, nil} ->
        # No map in assigns, this strategy doesn't apply
        :skip

      {:header, _} ->
        # No Bearer token, skip this strategy
        :skip

      {:key, nil} ->
        {:error, :api_key_not_configured}

      {:valid, false} ->
        {:error, :invalid_api_key}
    end
  end
end
