defmodule WandererAppWeb.HealthControllerTest do
  use WandererAppWeb.ConnCase

  import WandererApp.EnvHelper

  test "GET /health returns 200 with status and version", %{conn: conn} do
    conn = get(conn, "/health")

    assert %{"status" => "ok", "version" => version} = json_response(conn, 200)
    assert is_binary(version)
  end

  # The reason this route does not live in the :api scope. Fly kills an
  # unhealthy machine, and there is exactly one, so a 403 here is a total
  # outage triggered by a product feature flag. This test is the guard.
  test "GET /health still returns 200 when the public API is disabled", %{conn: conn} do
    with_env_override(:public_api_disabled, true) do
      conn = get(conn, "/health")
      assert %{"status" => "ok"} = json_response(conn, 200)
    end
  end
end
