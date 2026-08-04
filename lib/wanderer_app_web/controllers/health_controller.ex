defmodule WandererAppWeb.HealthController do
  @moduledoc """
  Machine liveness for Fly health checks.

  Deliberately depends on nothing but the endpoint and the database. A TCP
  check would only prove the listener is up; this proves the app can reach
  Postgres. It must never gain an authentication, rate-limiting, or feature-flag
  plug — see the `:health` pipeline in the router.
  """
  use WandererAppWeb, :controller

  def index(conn, _params) do
    version = to_string(WandererApp.Env.vsn())

    if database_reachable?() do
      json(conn, %{status: "ok", version: version})
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "error", version: version, database: "unreachable"})
    end
  end

  defp database_reachable? do
    case Ecto.Adapters.SQL.query(WandererApp.Repo, "SELECT 1", []) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    # A pool checkout timeout or a down connection raises rather than returning
    # an error tuple; either way the answer is "not reachable".
    _ -> false
  end
end
