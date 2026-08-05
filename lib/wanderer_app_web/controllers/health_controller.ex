defmodule WandererAppWeb.HealthController do
  @moduledoc """
  Machine liveness for Fly health checks.

  Answers one question: is this machine serving? It must never gain an
  authentication, rate-limiting, or feature-flag plug — see the `:health`
  pipeline in the router.

  Database reachability is reported in the body but deliberately does not change
  the status code. Fly kills a machine that fails its check, and under
  `min_machines_running = 1` that is the only machine; a restart cannot repair an
  external Postgres outage, so letting the database drive the status code would
  turn a transient blip into a self-inflicted outage.
  """
  use WandererAppWeb, :controller

  # Short on purpose. This endpoint is polled every few seconds; the Repo default
  # of 15s would let a saturated database hold each request open long enough for
  # polls to pile up on top of the problem.
  @db_check_timeout_ms 2_000

  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      version: to_string(WandererApp.Env.vsn()),
      database: if(database_reachable?(), do: "ok", else: "unreachable")
    })
  end

  defp database_reachable? do
    case Ecto.Adapters.SQL.query(WandererApp.Repo, "SELECT 1", [], timeout: @db_check_timeout_ms) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    # Most query-level failures come back as an error tuple and are handled
    # above; this catches the ones that raise instead.
    _ -> false
  catch
    # `rescue` does not cover exits. If the connection pool is not alive, the
    # GenServer.call inside DBConnection exits with :noproc or :timeout, which
    # would otherwise crash the request into a 500 — the exact status this
    # endpoint exists to avoid returning for a database fault.
    :exit, _ -> false
  end
end
