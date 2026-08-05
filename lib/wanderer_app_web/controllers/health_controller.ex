defmodule WandererAppWeb.HealthController do
  @moduledoc """
  Process liveness, for orchestrator health checks.

  Answers one question: is this instance serving? It must never gain an
  authentication, rate-limiting, or feature-flag plug — see the `:health`
  pipeline in the router.

  Database reachability is reported in the body but deliberately does not change
  the status code. An orchestrator restarts or replaces an instance that fails
  its check, and a restart cannot repair an external Postgres outage — so
  letting the database drive the status code turns a transient blip (a network
  partition, pool exhaustion, a slow migration) into a restart loop on top of
  the original problem. Reporting it in the body keeps the information available
  to humans and dashboards without wiring it to a kill signal.
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
