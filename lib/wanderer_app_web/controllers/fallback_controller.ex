defmodule WandererAppWeb.FallbackController do
  use WandererAppWeb, :controller

  # Handles not_found errors from with/else
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found"})
  end

  # Handles any other {:error, message} returns
  def call(conn, {:error, msg}) when is_binary(msg) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: msg})
  end
end
