defmodule WandererAppWeb.Plugs.DeprecatedApi do
  @moduledoc """
  Plug to add deprecation headers to legacy API endpoints.
  Implements RFC 8594 Sunset header for API deprecation.
  """

  import Plug.Conn

  def init(default), do: default

  def call(conn, _opts) do
    conn
    |> put_resp_header("sunset", sunset_date())
    |> put_resp_header("deprecation", "true")
    |> put_resp_header("link", "<https://docs.wanderer.app/api/v1>; rel=\"successor-version\"")
  end

  defp sunset_date do
    # Set sunset date to 6 months from now
    DateTime.utc_now()
    |> DateTime.add(6 * 30 * 24 * 60 * 60, :second)
    |> DateTime.to_string()
  end
end
