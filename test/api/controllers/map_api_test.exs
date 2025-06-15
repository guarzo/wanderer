defmodule WandererApp.MapApiTest do
  use WandererApp.ApiCase

  alias WandererApp.Api.Map
  alias WandererApp.Api.User

  describe "GET /api/maps" do
    setup do
      user = insert(:user)
      map1 = insert(:map, owner: user, name: "Test Map 1")
      map2 = insert(:map, owner: user, name: "Test Map 2", public: true)
      _private_map = insert(:map, name: "Private Map")
      
      {:ok, user: user, maps: [map1, map2]}
    end

    test "lists all maps for authenticated user", %{conn: conn, user: user, maps: maps} do
      conn
      |> authenticate_user(user)
      |> get("/api/maps")
      |> assert_status(200)
      |> json_response(200)
      |> assert_maps_count(2)
      |> assert_map_names(Enum.map(maps, & &1.name))
    end

    test "returns 401 for unauthenticated requests", %{conn: conn} do
      conn
      |> get("/api/maps")
      |> assert_status(401)
      |> assert_error_response(401, :unauthorized)
    end

    test "supports pagination", %{conn: conn, user: user} do
      # Create more maps for pagination
      for i <- 1..20, do: insert(:map, owner: user, name: "Map #{i}")
      
      response =
        conn
        |> authenticate_user(user)
        |> get_paginated("/api/maps", %{page: 1, page_size: 10})
        |> assert_status(200)
        |> json_response(200)
        |> assert_pagination(%{
          page: 1,
          page_size: 10,
          total_pages: 3,
          total_count: 22
        })
      
      assert length(response["data"]) == 10
    end
  end

  describe "POST /api/maps" do
    setup do
      user = insert(:user)
      {:ok, user: user}
    end

    test "creates a new map with valid params", %{conn: conn, user: user} do
      params = %{
        name: "New Test Map",
        description: "A test map created via API",
        public: false
      }

      response =
        conn
        |> authenticate_user(user)
        |> api_request(:post, "/api/maps", params)
        |> assert_status(201)
        |> json_response(201)

      assert response["data"]["name"] == params.name
      assert response["data"]["description"] == params.description
      assert response["data"]["public"] == params.public
      assert response["data"]["owner_id"] == user.id
    end

    test "returns validation errors for invalid params", %{conn: conn, user: user} do
      params = %{
        # Missing required name field
        description: "Invalid map"
      }

      conn
      |> authenticate_user(user)
      |> api_request(:post, "/api/maps", params)
      |> assert_status(422)
      |> assert_error_response(422, :name)
    end

    test "enforces rate limiting", %{conn: conn, user: user} do
      # Make multiple requests to trigger rate limiting
      for _ <- 1..10 do
        conn
        |> authenticate_user(user)
        |> api_request(:post, "/api/maps", %{name: "Map"})
      end

      conn
      |> authenticate_user(user)
      |> api_request(:post, "/api/maps", %{name: "Too Many"})
      |> assert_status(429)
      |> assert_error_response(429, :rate_limit_exceeded)
    end
  end

  describe "GET /api/maps/:id" do
    setup do
      user = insert(:user)
      map = insert(:map, owner: user)
      {:ok, user: user, map: map}
    end

    test "returns map details for authorized user", %{conn: conn, user: user, map: map} do
      response =
        conn
        |> authenticate_user(user)
        |> get("/api/maps/#{map.id}")
        |> assert_status(200)
        |> json_response(200)

      assert response["data"]["id"] == map.id
      assert response["data"]["name"] == map.name
    end

    test "returns 404 for non-existent map", %{conn: conn, user: user} do
      conn
      |> authenticate_user(user)
      |> get("/api/maps/999999")
      |> assert_status(404)
      |> assert_error_response(404, :not_found)
    end

    test "returns 403 for unauthorized access", %{conn: conn} do
      other_user = insert(:user)
      private_map = insert(:map, public: false)

      conn
      |> authenticate_user(other_user)
      |> get("/api/maps/#{private_map.id}")
      |> assert_status(403)
      |> assert_error_response(403, :forbidden)
    end
  end

  describe "PUT /api/maps/:id" do
    setup do
      user = insert(:user)
      map = insert(:map, owner: user)
      {:ok, user: user, map: map}
    end

    test "updates map with valid params", %{conn: conn, user: user, map: map} do
      params = %{
        name: "Updated Map Name",
        description: "Updated description"
      }

      response =
        conn
        |> authenticate_user(user)
        |> api_request(:put, "/api/maps/#{map.id}", params)
        |> assert_status(200)
        |> json_response(200)

      assert response["data"]["name"] == params.name
      assert response["data"]["description"] == params.description
    end

    test "only allows owner to update map", %{conn: conn, map: map} do
      other_user = insert(:user)
      
      conn
      |> authenticate_user(other_user)
      |> api_request(:put, "/api/maps/#{map.id}", %{name: "Hacked!"})
      |> assert_status(403)
      |> assert_error_response(403, :forbidden)
    end
  end

  describe "DELETE /api/maps/:id" do
    setup do
      user = insert(:user)
      map = insert(:map, owner: user)
      {:ok, user: user, map: map}
    end

    test "deletes map when requested by owner", %{conn: conn, user: user, map: map} do
      conn
      |> authenticate_user(user)
      |> delete("/api/maps/#{map.id}")
      |> assert_status(204)

      # Verify map is deleted
      conn
      |> authenticate_user(user)
      |> get("/api/maps/#{map.id}")
      |> assert_status(404)
    end

    test "prevents deletion by non-owner", %{conn: conn, map: map} do
      other_user = insert(:user)
      
      conn
      |> authenticate_user(other_user)
      |> delete("/api/maps/#{map.id}")
      |> assert_status(403)
      |> assert_error_response(403, :forbidden)
    end
  end

  # Helper functions
  defp assert_maps_count(response, expected_count) do
    assert length(response["data"]) == expected_count
    response
  end

  defp assert_map_names(response, expected_names) do
    actual_names = Enum.map(response["data"], & &1["name"])
    assert Enum.sort(actual_names) == Enum.sort(expected_names)
    response
  end
end