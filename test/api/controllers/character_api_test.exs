defmodule WandererApp.CharacterApiTest do
  use WandererApp.ApiCase

  describe "GET /api/characters" do
    setup do
      user = insert(:user)
      character1 = insert(:character, user: user, name: "Test Character 1")
      character2 = insert(:character, user: user, name: "Test Character 2")
      _other_character = insert(:character, name: "Other User Character")
      
      {:ok, user: user, characters: [character1, character2]}
    end

    test "lists all characters for authenticated user", %{conn: conn, user: user} do
      response =
        conn
        |> authenticate_user(user)
        |> get("/api/characters")
        |> assert_status(200)
        |> json_response(200)

      assert length(response["data"]) == 2
      character_names = Enum.map(response["data"], & &1["name"])
      assert "Test Character 1" in character_names
      assert "Test Character 2" in character_names
    end

    test "includes character online status", %{conn: conn, user: user} do
      response =
        conn
        |> authenticate_user(user)
        |> get("/api/characters")
        |> assert_status(200)
        |> json_response(200)

      Enum.each(response["data"], fn character ->
        assert Map.has_key?(character, "online")
        assert Map.has_key?(character, "location")
        assert Map.has_key?(character, "ship")
      end)
    end

    test "returns 401 for unauthenticated requests", %{conn: conn} do
      conn
      |> get("/api/characters")
      |> assert_status(401)
      |> assert_error_response(401, :unauthorized)
    end
  end

  describe "GET /api/characters/:id" do
    setup do
      user = insert(:user)
      character = insert(:character, user: user, eve_id: 123456789)
      {:ok, user: user, character: character}
    end

    test "returns character details", %{conn: conn, user: user, character: character} do
      response =
        conn
        |> authenticate_user(user)
        |> get("/api/characters/#{character.id}")
        |> assert_status(200)
        |> json_response(200)

      assert response["data"]["id"] == character.id
      assert response["data"]["name"] == character.name
      assert response["data"]["eve_id"] == character.eve_id
    end

    test "includes character skills if available", %{conn: conn, user: user, character: character} do
      # Add some skills to the character
      insert(:character_skill, character: character, skill_id: 1, level: 5)
      insert(:character_skill, character: character, skill_id: 2, level: 3)

      response =
        conn
        |> authenticate_user(user)
        |> get("/api/characters/#{character.id}?include=skills")
        |> assert_status(200)
        |> json_response(200)

      assert Map.has_key?(response["data"], "skills")
      assert length(response["data"]["skills"]) == 2
    end

    test "returns 404 for non-existent character", %{conn: conn, user: user} do
      conn
      |> authenticate_user(user)
      |> get("/api/characters/999999")
      |> assert_status(404)
      |> assert_error_response(404, :not_found)
    end

    test "returns 403 when accessing another user's character", %{conn: conn} do
      other_user = insert(:user)
      character = insert(:character)

      conn
      |> authenticate_user(other_user)
      |> get("/api/characters/#{character.id}")
      |> assert_status(403)
      |> assert_error_response(403, :forbidden)
    end
  end

  describe "POST /api/characters/track" do
    setup do
      user = insert(:user)
      character = insert(:character, user: user)
      map = insert(:map, owner: user)
      {:ok, user: user, character: character, map: map}
    end

    test "starts tracking character location", %{conn: conn, user: user, character: character, map: map} do
      params = %{
        character_id: character.id,
        map_id: map.id,
        system_id: "30000142"  # Jita
      }

      response =
        conn
        |> authenticate_user(user)
        |> api_request(:post, "/api/characters/track", params)
        |> assert_status(200)
        |> json_response(200)

      assert response["data"]["tracking"] == true
      assert response["data"]["system_id"] == params.system_id
    end

    test "validates character belongs to user", %{conn: conn, user: user, map: map} do
      other_character = insert(:character)
      
      params = %{
        character_id: other_character.id,
        map_id: map.id,
        system_id: "30000142"
      }

      conn
      |> authenticate_user(user)
      |> api_request(:post, "/api/characters/track", params)
      |> assert_status(403)
      |> assert_error_response(403, :forbidden)
    end
  end

  describe "DELETE /api/characters/:id/track" do
    setup do
      user = insert(:user)
      character = insert(:character, user: user, tracking: true)
      {:ok, user: user, character: character}
    end

    test "stops tracking character", %{conn: conn, user: user, character: character} do
      response =
        conn
        |> authenticate_user(user)
        |> delete("/api/characters/#{character.id}/track")
        |> assert_status(200)
        |> json_response(200)

      assert response["data"]["tracking"] == false
    end
  end

  describe "POST /api/characters/import" do
    setup do
      user = insert(:user)
      {:ok, user: user}
    end

    test "imports character from EVE SSO token", %{conn: conn, user: user} do
      params = %{
        access_token: "valid-eve-sso-token",
        character_id: 123456789,
        character_name: "Test Pilot"
      }

      response =
        conn
        |> authenticate_user(user)
        |> api_request(:post, "/api/characters/import", params)
        |> assert_status(201)
        |> json_response(201)

      assert response["data"]["eve_id"] == params.character_id
      assert response["data"]["name"] == params.character_name
      assert response["data"]["user_id"] == user.id
    end

    test "handles duplicate character import", %{conn: conn, user: user} do
      character = insert(:character, user: user, eve_id: 123456789)
      
      params = %{
        access_token: "valid-eve-sso-token",
        character_id: character.eve_id,
        character_name: character.name
      }

      conn
      |> authenticate_user(user)
      |> api_request(:post, "/api/characters/import", params)
      |> assert_status(409)
      |> assert_error_response(409, :already_exists)
    end

    test "validates EVE SSO token", %{conn: conn, user: user} do
      params = %{
        access_token: "invalid-token",
        character_id: 123456789,
        character_name: "Test Pilot"
      }

      conn
      |> authenticate_user(user)
      |> api_request(:post, "/api/characters/import", params)
      |> assert_status(401)
      |> assert_error_response(401, :invalid_token)
    end
  end
end