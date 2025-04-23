defmodule WandererAppWeb.Plugs.CheckMapApiKey do
  @moduledoc """
  A plug that:
    1. extracts “Bearer <token>” from the Authorization header,
    2. looks up the map via query params (`map_id` or `slug`),
    3. verifies `map.public_api_key == token`,
    4. assigns both `:map` and `:map_id` into `conn.assigns`.
  Halts with 401/404 if anything goes wrong.
  """

  import Plug.Conn
  alias WandererAppWeb.UtilAPIController, as: Util
  alias WandererApp.Api.Map, as: MapApi

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> incoming_token] <- get_req_header(conn, "authorization"),
         {:ok, map_id}                <- Util.fetch_map_id(conn.query_params),
         {:ok, %MapApi{} = map}       <- MapApi.by_id(map_id),
         true                         <- map.public_api_key == incoming_token
    do
      conn
      |> assign(:map, map)
      |> assign(:map_id, map.id)
    else
      # missing or malformed header
      [] ->
        conn
        |> unauthorized("Missing or invalid 'Bearer' token")
      # fetch_map_id failed (invalid param or neither map_id nor slug)
      {:error, msg} when is_binary(msg) ->
        conn
        |> bad_request(msg)
      # no such map
      {:error, :not_found} ->
        conn
        |> not_found("Map not found")
      # token mismatch
      false ->
        conn
        |> unauthorized("Unauthorized (invalid token for map)")
      # any other error
      _ ->
        conn
        |> internal_error("Unexpected error during auth")
    end
    |> halt_if_necessary()
  end

  # Helpers to keep the main clause tidy

  defp unauthorized(conn, msg) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: msg}))
  end

  defp bad_request(conn, msg) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{error: msg}))
  end

  defp not_found(conn, msg) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: msg}))
  end

  defp internal_error(conn, msg) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, Jason.encode!(%{error: msg}))
  end

  # halt only if we've already sent a response
  defp halt_if_necessary(%Plug.Conn{state: :sent} = conn), do: halt(conn)
  defp halt_if_necessary(conn),                          do: conn
end
