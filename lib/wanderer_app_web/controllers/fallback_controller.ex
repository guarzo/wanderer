defmodule WandererAppWeb.FallbackController do
  use WandererAppWeb, :controller

  alias WandererAppWeb.UtilAPIController, as: Util

  # Handles not_found errors from with/else
  def call(conn, {:error, :not_found}) do
    Util.standardized_error_response(conn, :not_found, "Not found", "The requested resource could not be found")
  end

  # Handles any other {:error, message} returns
  def call(conn, {:error, msg}) when is_binary(msg) do
    Util.standardized_error_response(conn, :bad_request, msg)
  end
end
