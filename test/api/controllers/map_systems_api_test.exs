defmodule WandererApp.MapSystemsAPITest do
  use WandererApp.ApiCase

  @moduledoc """
  Tests for Map Systems and Connections API endpoints using the map server mock infrastructure.
  These tests verify CRUD operations on systems and connections within a map context.
  """

  describe "Map Systems CRUD operations" do
    setup do
      map_data = create_test_map_with_auth()
      {:ok, map_data: map_data}
    end

    test "GET /api/v1/maps/:map_identifier/systems lists all systems", %{conn: conn, map_data: map_data} do
      # Add some systems to the map
      system1 = add_system_to_mock(map_data, %{
        name: "Jita",
        solar_system_id: 30000142,
        position_x: 100,
        position_y: 200
      })
      
      system2 = add_system_to_mock(map_data, %{
        name: "Amarr",
        solar_system_id: 30002187,
        position_x: 300,
        position_y: 400
      })

      response =
        conn
        |> authenticate_map(map_data.api_key)
        |> put_req_header("accept", "application/vnd.api+json")
        |> put_req_header("content-type", "application/vnd.api+json")
        |> get("/api/v1/maps/#{map_data.map_slug}/systems")
        |> json_response(200)

      assert length(response["data"]) == 2
      
      # Verify system details - JSON:API format
      jita = Enum.find(response["data"], & &1["attributes"]["solar_system_id"] == 30000142)
      assert jita["attributes"]["name"] == "Jita"
      assert jita["attributes"]["position_x"] == 100
      assert jita["attributes"]["position_y"] == 200
    end

    test "GET /api/v1/maps/:map_identifier/systems/:id shows specific system", %{conn: conn, map_data: map_data} do
      system = add_system_to_mock(map_data, %{
        name: "Test System",
        solar_system_id: 30000001
      })

      response =
        conn
        |> authenticate_map(map_data.api_key)
        |> get("/api/v1/maps/#{map_data.map_slug}/systems/#{system.id}")
        |> json_response(200)

      assert response["data"]["id"] == system.id
      assert response["data"]["name"] == "Test System"
    end

    test "POST /api/v1/maps/:map_identifier/systems creates new system", %{conn: conn, map_data: map_data} do
      system_data = %{
        "solar_system_id" => 30000142,
        "name" => "Jita",
        "position_x" => 500,
        "position_y" => 500,
        "status" => "clear",
        "visible" => true,
        "description" => "Trade hub",
        "tag" => "TRADE",
        "locked" => false
      }

      response =
        conn
        |> authenticate_map(map_data.api_key)
        |> post("/api/v1/maps/#{map_data.map_slug}/systems", system_data)
        |> json_response(201)

      assert response["data"]["solar_system_id"] == 30000142
      assert response["data"]["name"] == "Jita"
      assert response["data"]["tag"] == "TRADE"
      
      # Verify system was added to mock
      assert_map_has_systems(map_data.map.id, 1)
    end

    test "PUT /api/v1/maps/:map_identifier/systems/:id updates system", %{conn: conn, map_data: map_data} do
      system = add_system_to_mock(map_data, %{
        name: "Old Name",
        tag: "OLD"
      })

      update_data = %{
        "name" => "New Name",
        "tag" => "NEW",
        "description" => "Updated description"
      }

      response =
        conn
        |> authenticate_map(map_data.api_key)
        |> put("/api/v1/maps/#{map_data.map_slug}/systems/#{system.id}", update_data)
        |> json_response(200)

      assert response["data"]["name"] == "New Name"
      assert response["data"]["tag"] == "NEW"
    end

    test "DELETE /api/v1/maps/:map_identifier/systems bulk deletes systems", %{conn: conn, map_data: map_data} do
      system1 = add_system_to_mock(map_data)
      system2 = add_system_to_mock(map_data)
      system3 = add_system_to_mock(map_data)

      # Delete first two systems
      delete_data = %{
        "system_ids" => [system1.id, system2.id]
      }

      conn
      |> authenticate_map(map_data.api_key)
      |> delete("/api/v1/maps/#{map_data.map_slug}/systems", delete_data)
      |> response(204)

      # Verify only one system remains
      assert_map_has_systems(map_data.map.id, 1)
    end

    test "DELETE /api/v1/maps/:map_identifier/systems/:id deletes single system", %{conn: conn, map_data: map_data} do
      system = add_system_to_mock(map_data)

      conn
      |> authenticate_map(map_data.api_key)
      |> delete("/api/v1/maps/#{map_data.map_slug}/systems/#{system.id}")
      |> response(204)

      # Verify system was removed
      assert_map_has_systems(map_data.map.id, 0)
    end
  end

  describe "Map Connections CRUD operations" do
    setup do
      map_data = create_test_map_with_auth()
      
      # Create two systems to connect
      system1 = add_system_to_mock(map_data, %{
        name: "System A",
        solar_system_id: 30000001
      })
      
      system2 = add_system_to_mock(map_data, %{
        name: "System B", 
        solar_system_id: 30000002
      })
      
      {:ok, map_data: map_data, system1: system1, system2: system2}
    end

    test "GET /api/maps/:map_identifier/connections lists all connections", %{
      conn: conn,
      map_data: map_data,
      system1: system1,
      system2: system2
    } do
      # Add a connection
      connection = add_connection_to_mock(map_data, system1, system2)

      response =
        conn
        |> authenticate_map(map_data.api_key)
        |> get("/api/maps/#{map_data.map_slug}/connections")
        |> json_response(200)

      assert length(response["data"]) == 1
      
      conn_data = hd(response["data"])
      assert conn_data["solar_system_source"] == system1.solar_system_id
      assert conn_data["solar_system_target"] == system2.solar_system_id
    end

    test "POST /api/maps/:map_identifier/connections creates new connection", %{
      conn: conn,
      map_data: map_data,
      system1: system1,
      system2: system2
    } do
      connection_data = %{
        "solar_system_source" => system1.solar_system_id,
        "solar_system_target" => system2.solar_system_id,
        "type" => 0,
        "mass_status" => 0,
        "time_status" => 0,
        "ship_size_type" => 1,
        "wormhole_type" => "K162",
        "count_of_passage" => 0
      }

      response =
        conn
        |> authenticate_map(map_data.api_key)
        |> post("/api/maps/#{map_data.map_slug}/connections", connection_data)
        |> json_response(201)

      assert response["data"]["solar_system_source"] == system1.solar_system_id
      assert response["data"]["solar_system_target"] == system2.solar_system_id
      assert response["data"]["wormhole_type"] == "K162"
      
      # Verify connection was added
      assert_map_has_connections(map_data.map.id, 1)
    end

    test "PATCH /api/maps/:map_identifier/connections updates connection", %{
      conn: conn,
      map_data: map_data,
      system1: system1,
      system2: system2
    } do
      # Add initial connection
      connection = add_connection_to_mock(map_data, system1, system2, %{
        mass_status: 0,
        ship_size_type: 1
      })

      update_data = %{
        "mass_status" => 1,
        "ship_size_type" => 2,
        "time_status" => 1
      }

      response =
        conn
        |> authenticate_map(map_data.api_key)
        |> patch(
          "/api/maps/#{map_data.map_slug}/connections?solar_system_source=#{system1.solar_system_id}&solar_system_target=#{system2.solar_system_id}",
          update_data
        )
        |> json_response(200)

      assert response["data"]["mass_status"] == 1
      assert response["data"]["ship_size_type"] == 2
    end

    test "DELETE /api/maps/:map_identifier/connections removes connection", %{
      conn: conn,
      map_data: map_data,
      system1: system1,
      system2: system2
    } do
      # Add connection first
      connection = add_connection_to_mock(map_data, system1, system2)

      conn
      |> authenticate_map(map_data.api_key)
      |> delete(
        "/api/maps/#{map_data.map_slug}/connections?solar_system_source=#{system1.solar_system_id}&solar_system_target=#{system2.solar_system_id}"
      )
      |> response(204)

      # Verify connection was removed
      assert_map_has_connections(map_data.map.id, 0)
    end
  end

  describe "API authentication and authorization" do
    test "requests without authentication return 403", %{conn: conn} do
      conn
      |> get("/api/v1/maps/test-map/systems")
      |> json_response(403)
    end

    test "requests with invalid API key return 403", %{conn: conn} do
      map_data = create_test_map_with_auth()
      
      conn
      |> put_req_header("x-api-key", "invalid-key")
      |> get("/api/v1/maps/#{map_data.map_slug}/systems")
      |> json_response(403)
    end

    test "requests to non-existent map return 404", %{conn: conn} do
      # Create a valid map to get a valid API key
      map_data = create_test_map_with_auth()
      
      conn
      |> authenticate_map(map_data.api_key)
      |> get("/api/v1/maps/non-existent-map/systems")
      |> json_response(404)
    end
  end

  describe "API validation" do
    setup do
      map_data = create_test_map_with_auth()
      {:ok, map_data: map_data}
    end

    test "POST systems with missing required fields returns 422", %{conn: conn, map_data: map_data} do
      invalid_system_data = %{
        "position_x" => 500,
        "position_y" => 500
        # Missing required solar_system_id
      }

      conn
      |> authenticate_map(map_data.api_key)
      |> post("/api/v1/maps/#{map_data.map_slug}/systems", invalid_system_data)
      |> json_response(422)
    end

    test "POST connections with invalid data returns 422", %{conn: conn, map_data: map_data} do
      invalid_connection_data = %{
        "solar_system_source" => "not-a-number",  # Should be integer
        "solar_system_target" => 30000144,
        "type" => 0
      }

      conn
      |> authenticate_map(map_data.api_key)
      |> post("/api/maps/#{map_data.map_slug}/connections", invalid_connection_data)
      |> json_response(422)
    end

    test "DELETE systems with empty system_ids returns 422", %{conn: conn, map_data: map_data} do
      conn
      |> authenticate_map(map_data.api_key)
      |> delete("/api/v1/maps/#{map_data.map_slug}/systems", %{"system_ids" => []})
      |> json_response(422)
    end
  end
end