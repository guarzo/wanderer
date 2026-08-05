defmodule WandererAppWeb.HealthControllerTest do
  use WandererAppWeb.ConnCase

  import WandererApp.EnvHelper

  test "GET /health returns 200 with status, version and database state", %{conn: conn} do
    conn = get(conn, "/health")

    assert %{"status" => "ok", "version" => version, "database" => database} =
             json_response(conn, 200)

    assert is_binary(version)
    assert database == "ok"
  end

  # The reason this route does not live in the :api scope, which pipes through
  # CheckApiDisabled. A 403 here reads to an orchestrator as a dead instance, so
  # setting WANDERER_PUBLIC_API_DISABLED would restart a perfectly healthy
  # container. This test is the guard.
  test "GET /health still returns 200 when the public API is disabled", %{conn: conn} do
    with_env_override(:public_api_disabled, true) do
      conn = get(conn, "/health")
      assert %{"status" => "ok"} = json_response(conn, 200)
    end
  end
end
