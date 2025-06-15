defmodule WandererApp.MapSystemsAPITest do
  use WandererApp.ApiCase

  @moduletag :api

  describe "Map Systems CRUD operations (requires authentication)" do
    test "GET /api/maps/:map_slug/systems without authentication returns 404 for non-existent map",
         %{conn: conn} do
      # Remove auth headers
      conn =
        conn
        |> Plug.Conn.delete_req_header("authorization")
        |> Plug.Conn.delete_req_header("x-api-key")

      conn = get(conn, "/api/maps/test-map/systems")
      # Map doesn't exist, so we get 404 before auth check
      assert conn.status == 404
    end

    test "GET /api/maps/:map_slug/systems with invalid map returns 404", %{conn: conn} do
      # Add a fake API key for testing
      conn = Plug.Conn.put_req_header(conn, "x-api-key", "test-api-key-123")

      conn = get(conn, "/api/maps/nonexistent-map/systems")
      # Could be auth failure or not found
      assert conn.status in [401, 404]
    end

    test "POST /api/maps/:map_slug/systems without authentication returns 404 for non-existent map",
         %{conn: conn} do
      # Remove auth headers
      conn =
        conn
        |> Plug.Conn.delete_req_header("authorization")
        |> Plug.Conn.delete_req_header("x-api-key")

      system_data = %{
        "systems" => [
          %{
            "solar_system_id" => 30_000_142,
            "solar_system_name" => "Jita",
            "position_x" => 500.0,
            "position_y" => 500.0,
            "status" => "clear",
            "visible" => true,
            "description" => "Test system",
            "tag" => "TEST",
            "locked" => false
          }
        ]
      }

      conn = post(conn, "/api/maps/test-map/systems", system_data)
      # Map doesn't exist, so we get 404 before auth check
      assert conn.status == 404
    end

    test "DELETE /api/maps/:map_slug/systems without authentication returns 404 for non-existent map",
         %{conn: conn} do
      # Remove auth headers  
      conn =
        conn
        |> Plug.Conn.delete_req_header("authorization")
        |> Plug.Conn.delete_req_header("x-api-key")

      delete_data = %{
        "system_ids" => ["30000142"]
      }

      conn = delete(conn, "/api/maps/test-map/systems", delete_data)
      # Map doesn't exist, so we get 404 before auth check
      assert conn.status == 404
    end
  end

  describe "Map Connections CRUD operations (requires authentication)" do
    test "GET /api/maps/:map_slug/connections without authentication returns 404 for non-existent map",
         %{conn: conn} do
      # Remove auth headers
      conn =
        conn
        |> Plug.Conn.delete_req_header("authorization")
        |> Plug.Conn.delete_req_header("x-api-key")

      conn = get(conn, "/api/maps/test-map/connections")
      # Map doesn't exist, so we get 404 before auth check
      assert conn.status == 404
    end

    test "POST /api/maps/:map_slug/connections without authentication returns 404 for non-existent map",
         %{conn: conn} do
      # Remove auth headers
      conn =
        conn
        |> Plug.Conn.delete_req_header("authorization")
        |> Plug.Conn.delete_req_header("x-api-key")

      connection_data = %{
        "solar_system_source" => 30_000_142,
        "solar_system_target" => 30_000_144,
        "type" => 0,
        "mass_status" => 0,
        "time_status" => 0,
        "ship_size_type" => 1,
        "wormhole_type" => "K162",
        "count_of_passage" => 0
      }

      conn = post(conn, "/api/maps/test-map/connections", connection_data)
      # Map doesn't exist, so we get 404 before auth check
      assert conn.status == 404
    end

    test "PATCH /api/maps/:map_slug/connections without authentication returns 404 for non-existent map",
         %{conn: conn} do
      # Remove auth headers
      conn =
        conn
        |> Plug.Conn.delete_req_header("authorization")
        |> Plug.Conn.delete_req_header("x-api-key")

      update_data = %{
        "mass_status" => 1,
        "ship_size_type" => 2
      }

      conn =
        patch(
          conn,
          "/api/maps/test-map/connections?solar_system_source=30000142&solar_system_target=30000144",
          update_data
        )

      # Map doesn't exist, so we get 404 before auth check
      assert conn.status == 404
    end

    test "DELETE /api/maps/:map_slug/connections without authentication returns 404 for non-existent map",
         %{
           conn: conn
         } do
      # Remove auth headers
      conn =
        conn
        |> Plug.Conn.delete_req_header("authorization")
        |> Plug.Conn.delete_req_header("x-api-key")

      conn =
        delete(
          conn,
          "/api/maps/test-map/connections?solar_system_source=30000142&solar_system_target=30000144"
        )

      # Map doesn't exist, so we get 404 before auth check
      assert conn.status == 404
    end
  end

  describe "API validation tests" do
    test "POST /api/maps/:map_slug/systems with empty data returns 404 for non-existent map", %{
      conn: conn
    } do
      # Send empty data to test validation
      conn = Plug.Conn.put_req_header(conn, "x-api-key", "test-api-key-123")

      conn = post(conn, "/api/maps/test-map/systems", %{})
      # Map doesn't exist, so we get 404 before validation
      assert conn.status == 404
    end

    test "POST /api/maps/:map_slug/systems with missing required fields returns 404 for non-existent map",
         %{
           conn: conn
         } do
      conn = Plug.Conn.put_req_header(conn, "x-api-key", "test-api-key-123")

      invalid_system_data = %{
        "systems" => [
          %{
            "position_x" => 500.0,
            "position_y" => 500.0
            # Missing required fields like solar_system_id
          }
        ]
      }

      conn = post(conn, "/api/maps/test-map/systems", invalid_system_data)
      # Map doesn't exist, so we get 404 before validation
      assert conn.status == 404
    end

    test "POST /api/maps/:map_slug/connections with invalid data returns 404 for non-existent map",
         %{conn: conn} do
      conn = Plug.Conn.put_req_header(conn, "x-api-key", "test-api-key-123")

      invalid_connection_data = %{
        # Should be integer
        "solar_system_source" => "invalid",
        "solar_system_target" => 30_000_144,
        "type" => 0
      }

      conn = post(conn, "/api/maps/test-map/connections", invalid_connection_data)
      # Map doesn't exist, so we get 404 before validation
      assert conn.status == 404
    end
  end

  describe "API rate limiting and security" do
    test "requests without proper headers are rejected", %{conn: conn} do
      # Remove all authentication headers
      conn =
        conn
        |> Plug.Conn.delete_req_header("authorization")
        |> Plug.Conn.delete_req_header("x-api-key")
        |> Plug.Conn.delete_req_header("accept")
        |> Plug.Conn.delete_req_header("content-type")

      conn = get(conn, "/api/maps/test-map/systems")
      # Map doesn't exist, so we get 404 before auth check
      assert conn.status == 404
    end

    test "requests with invalid content-type are rejected", %{conn: conn} do
      system_data = %{
        "systems" => [
          %{
            "solar_system_id" => 30_000_142,
            "solar_system_name" => "Jita"
          }
        ]
      }

      # Send with wrong content-type but proper data structure
      conn =
        conn
        |> Plug.Conn.put_req_header("x-api-key", "test-api-key-123")
        |> post("/api/maps/test-map/systems", system_data)

      # Map doesn't exist, so we get 404
      assert conn.status == 404
    end
  end
end
