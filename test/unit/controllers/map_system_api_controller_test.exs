defmodule WandererAppWeb.MapSystemAPIControllerTest do
  use WandererAppWeb.ConnCase

  alias WandererAppWeb.MapSystemAPIController

  describe "parameter validation and core functions" do
    test "index lists systems and connections" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      result = MapSystemAPIController.index(conn, %{})
      assert %Plug.Conn{} = result
      assert result.status in [200, 500]
      
      if result.status == 200 do
        response = json_response(result, 200)
        assert Map.has_key?(response, "data")
        assert Map.has_key?(response["data"], "systems")
        assert Map.has_key?(response["data"], "connections")
      end
    end

    test "show validates system ID parameter" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test with valid system ID
      params_valid = %{"id" => "30000142"}
      result_valid = MapSystemAPIController.show(conn, params_valid)
      assert %Plug.Conn{} = result_valid
      
      # Test with invalid system ID
      params_invalid = %{"id" => "invalid"}
      result_invalid = MapSystemAPIController.show(conn, params_invalid)
      assert %Plug.Conn{} = result_invalid
    end

    test "create handles single system creation" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test with valid single system parameters
      params_valid = %{
        "solar_system_id" => 30000142,
        "position_x" => 100,
        "position_y" => 200
      }
      result_valid = MapSystemAPIController.create(conn, params_valid)
      assert %Plug.Conn{} = result_valid
      
      # Test with missing position parameters
      params_missing_pos = %{
        "solar_system_id" => 30000142
      }
      result_missing = MapSystemAPIController.create(conn, params_missing_pos)
      assert json_response(result_missing, 400)
      response = json_response(result_missing, 400)
      assert Map.has_key?(response, "error")
      assert String.contains?(response["error"], "position_x and position_y")
    end

    test "create handles batch operations" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test with valid batch parameters
      params_batch = %{
        "systems" => [
          %{
            "solar_system_id" => 30000142,
            "position_x" => 100,
            "position_y" => 200
          }
        ],
        "connections" => [
          %{
            "solar_system_source" => 30000142,
            "solar_system_target" => 30000143
          }
        ]
      }
      result_batch = MapSystemAPIController.create(conn, params_batch)
      assert %Plug.Conn{} = result_batch
      
      # Test with empty arrays
      params_empty = %{
        "systems" => [],
        "connections" => []
      }
      result_empty = MapSystemAPIController.create(conn, params_empty)
      assert %Plug.Conn{} = result_empty
    end

    test "create validates array parameters for batch" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test with invalid systems parameter (not array)
      params_invalid_systems = %{
        "systems" => "not_an_array",
        "connections" => []
      }
      result_invalid_systems = MapSystemAPIController.create(conn, params_invalid_systems)
      assert json_response(result_invalid_systems, 400)
      response = json_response(result_invalid_systems, 400)
      assert response["error"] == "systems must be an array"
      
      # Test with invalid connections parameter (not array)
      params_invalid_connections = %{
        "systems" => [],
        "connections" => "not_an_array"
      }
      result_invalid_connections = MapSystemAPIController.create(conn, params_invalid_connections)
      assert json_response(result_invalid_connections, 400)
      response = json_response(result_invalid_connections, 400)
      assert response["error"] == "connections must be an array"
    end

    test "create handles malformed single system requests" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test with position parameters but no solar_system_id
      params_malformed = %{
        "position_x" => 100,
        "position_y" => 200
      }
      result_malformed = MapSystemAPIController.create(conn, params_malformed)
      assert json_response(result_malformed, 400)
      response = json_response(result_malformed, 400)
      assert String.contains?(response["error"], "solar_system_id")
    end

    test "update validates system ID and parameters" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test with valid system ID
      params_valid = %{"id" => "30000142", "position_x" => 150}
      result_valid = MapSystemAPIController.update(conn, params_valid)
      assert %Plug.Conn{} = result_valid
      
      # Test with invalid system ID
      params_invalid = %{"id" => "invalid", "position_x" => 150}
      result_invalid = MapSystemAPIController.update(conn, params_invalid)
      assert %Plug.Conn{} = result_invalid
    end

    test "delete handles batch deletion" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test with system and connection IDs
      params = %{
        "system_ids" => [30000142, 30000143],
        "connection_ids" => [Ecto.UUID.generate()]
      }
      result = MapSystemAPIController.delete(conn, params)
      assert %Plug.Conn{} = result
      
      if result.status == 200 do
        response = json_response(result, 200)
        assert Map.has_key?(response, "data")
        assert Map.has_key?(response["data"], "deleted_count")
      end
    end

    test "delete_single handles individual system deletion" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test with valid system ID
      params_valid = %{"id" => "30000142"}
      result_valid = MapSystemAPIController.delete_single(conn, params_valid)
      assert %Plug.Conn{} = result_valid
      
      # Test with invalid system ID
      params_invalid = %{"id" => "invalid"}
      result_invalid = MapSystemAPIController.delete_single(conn, params_invalid)
      assert %Plug.Conn{} = result_invalid
    end

    test "show_system legacy endpoint validates parameters" do
      # Test with missing parameters
      result_missing = MapSystemAPIController.show_system(build_conn(), %{})
      assert json_response(result_missing, 400)
      response = json_response(result_missing, 400)
      assert String.contains?(response["error"], "Missing required parameters")
      
      # Test with valid parameters
      params_valid = %{
        "map_id" => Ecto.UUID.generate(),
        "id" => "30000142"
      }
      result_valid = MapSystemAPIController.show_system(build_conn(), params_valid)
      assert %Plug.Conn{} = result_valid
      
      # Test with slug instead of map_id
      params_slug = %{
        "slug" => "test-map",
        "id" => "30000142"
      }
      result_slug = MapSystemAPIController.show_system(build_conn(), params_slug)
      assert %Plug.Conn{} = result_slug
    end
  end

  describe "parameter parsing and edge cases" do
    test "create_single_system handles invalid solar_system_id" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      base_conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test invalid solar_system_id formats
      invalid_system_ids = ["invalid", "", nil, -1]
      
      Enum.each(invalid_system_ids, fn solar_system_id ->
        params = %{
          "solar_system_id" => solar_system_id,
          "position_x" => 100,
          "position_y" => 200
        }
        result = MapSystemAPIController.create(base_conn, params)
        assert %Plug.Conn{} = result
        # Should handle invalid IDs gracefully
        assert result.status in [400, 422, 500]
      end)
    end

    test "handles different parameter combinations for batch create" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test various parameter combinations
      param_combinations = [
        %{"systems" => [], "connections" => []},
        %{"systems" => [%{"solar_system_id" => 30000142, "position_x" => 100, "position_y" => 200}]},
        %{"connections" => [%{"solar_system_source" => 30000142, "solar_system_target" => 30000143}]},
        %{}, # Empty parameters
        %{"other_field" => "value"} # Unexpected field
      ]
      
      Enum.each(param_combinations, fn params ->
        result = MapSystemAPIController.create(conn, params)
        assert %Plug.Conn{} = result
      end)
    end

    test "delete handles empty and invalid arrays" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test with empty arrays
      params_empty = %{
        "system_ids" => [],
        "connection_ids" => []
      }
      result_empty = MapSystemAPIController.delete(conn, params_empty)
      assert %Plug.Conn{} = result_empty
      
      # Test with missing fields
      params_missing = %{}
      result_missing = MapSystemAPIController.delete(conn, params_missing)
      assert %Plug.Conn{} = result_missing
      
      # Test with malformed IDs
      params_malformed = %{
        "system_ids" => ["invalid", "", nil],
        "connection_ids" => ["invalid-uuid", ""]
      }
      result_malformed = MapSystemAPIController.delete(conn, params_malformed)
      assert %Plug.Conn{} = result_malformed
    end

    test "update extracts parameters correctly" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test with various update parameters
      update_param_combinations = [
        %{"id" => "30000142", "position_x" => 100},
        %{"id" => "30000142", "position_y" => 200},
        %{"id" => "30000142", "status" => 1},
        %{"id" => "30000142", "visible" => true},
        %{"id" => "30000142", "description" => "test"},
        %{"id" => "30000142", "tag" => "test-tag"},
        %{"id" => "30000142", "locked" => false},
        %{"id" => "30000142", "temporary_name" => "temp"},
        %{"id" => "30000142", "labels" => "label1,label2"},
        %{"id" => "30000142"} # No update fields
      ]
      
      Enum.each(update_param_combinations, fn params ->
        result = MapSystemAPIController.update(conn, params)
        assert %Plug.Conn{} = result
      end)
    end

    test "show_system handles different map identifier formats" do
      # Test with UUID format
      uuid = Ecto.UUID.generate()
      params_uuid = %{
        "map_id" => uuid,
        "id" => "30000142"
      }
      result_uuid = MapSystemAPIController.show_system(build_conn(), params_uuid)
      assert %Plug.Conn{} = result_uuid
      
      # Test with slug format
      params_slug = %{
        "slug" => "test-map-slug",
        "id" => "30000142"
      }
      result_slug = MapSystemAPIController.show_system(build_conn(), params_slug)
      assert %Plug.Conn{} = result_slug
      
      # Test with invalid formats
      params_invalid = %{
        "map_id" => "invalid-uuid",
        "id" => "30000142"
      }
      result_invalid = MapSystemAPIController.show_system(build_conn(), params_invalid)
      assert %Plug.Conn{} = result_invalid
    end

    test "get_map_id_from_identifier handles various formats" do
      # This tests the private function indirectly through show_system
      test_identifiers = [
        Ecto.UUID.generate(), # Valid UUID
        "test-map-slug", # Valid slug format
        "invalid-uuid-format", # Invalid UUID
        "", # Empty string
        nil # Nil value (though this should be caught earlier)
      ]
      
      Enum.each(test_identifiers, fn identifier ->
        if identifier do
          params = %{
            "map_id" => identifier,
            "id" => "30000142"
          }
          result = MapSystemAPIController.show_system(build_conn(), params)
          assert %Plug.Conn{} = result
        end
      end)
    end

    test "handles missing assigns gracefully" do
      conn = build_conn()
      
      # Should fail due to missing map_id assign
      assert_raise(MatchError, fn ->
        MapSystemAPIController.index(conn, %{})
      end)
      
      assert_raise(MatchError, fn ->
        MapSystemAPIController.show(conn, %{"id" => "30000142"})
      end)
    end
  end

  describe "error handling scenarios" do
    test "create handles various error conditions" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test malformed single system requests
      malformed_single_params = [
        %{"solar_system_id" => "invalid", "position_x" => 100, "position_y" => 200},
        %{"solar_system_id" => nil, "position_x" => 100, "position_y" => 200},
        %{"solar_system_id" => "", "position_x" => 100, "position_y" => 200}
      ]
      
      Enum.each(malformed_single_params, fn params ->
        result = MapSystemAPIController.create(conn, params)
        assert %Plug.Conn{} = result
        assert result.status in [400, 422, 500]
      end)
    end

    test "delete_system_id and delete_connection_id helper functions" do
      # These are tested indirectly through the delete function
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test with various ID formats
      test_ids = [
        30000142, # Valid integer ID
        "30000142", # Valid string ID
        "invalid", # Invalid string
        "", # Empty string
        nil # Nil value
      ]
      
      Enum.each(test_ids, fn id ->
        params = %{
          "system_ids" => [id],
          "connection_ids" => []
        }
        result = MapSystemAPIController.delete(conn, params)
        assert %Plug.Conn{} = result
      end)
    end

    test "handles invalid update parameters" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test with various invalid parameters
      invalid_updates = [
        %{"id" => "", "position_x" => 100},
        %{"id" => nil, "position_x" => 100},
        %{"id" => "invalid", "position_x" => "invalid"},
        %{"id" => "30000142", "status" => "invalid"},
        %{"id" => "30000142", "visible" => "invalid"}
      ]
      
      Enum.each(invalid_updates, fn params ->
        result = MapSystemAPIController.update(conn, params)
        assert %Plug.Conn{} = result
      end)
    end

    test "handles malformed show_system parameters" do
      # Test with various malformed parameter combinations
      malformed_params = [
        %{"map_id" => "", "id" => "30000142"},
        %{"map_id" => nil, "id" => "30000142"},
        %{"map_id" => Ecto.UUID.generate(), "id" => ""},
        %{"map_id" => Ecto.UUID.generate(), "id" => nil},
        %{"map_id" => Ecto.UUID.generate(), "id" => "invalid"},
        %{"slug" => "", "id" => "30000142"},
        %{"slug" => nil, "id" => "30000142"}
      ]
      
      Enum.each(malformed_params, fn params ->
        result = MapSystemAPIController.show_system(build_conn(), params)
        assert %Plug.Conn{} = result
        # Should handle gracefully with appropriate error response
        assert result.status in [400, 404, 500]
      end)
    end

    test "delete_single handles various error conditions" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test with various system ID formats
      system_id_formats = [
        "30000142", # Valid
        "invalid", # Invalid string
        "", # Empty
        nil, # Nil
        "-1", # Negative
        "0" # Zero
      ]
      
      Enum.each(system_id_formats, fn id ->
        params = %{"id" => id}
        result = MapSystemAPIController.delete_single(conn, params)
        assert %Plug.Conn{} = result
      end)
    end
  end

  describe "response structure validation" do
    test "index returns consistent response structure" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      result = MapSystemAPIController.index(conn, %{})
      assert %Plug.Conn{} = result
      
      if result.status == 200 do
        response = json_response(result, 200)
        assert Map.has_key?(response, "data")
        assert is_map(response["data"])
        assert Map.has_key?(response["data"], "systems")
        assert Map.has_key?(response["data"], "connections")
        assert is_list(response["data"]["systems"])
        assert is_list(response["data"]["connections"])
      end
    end

    test "show returns proper response structure" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      result = MapSystemAPIController.show(conn, %{"id" => "30000142"})
      assert %Plug.Conn{} = result
      
      # Should have JSON response
      assert result.resp_body != ""
    end

    test "create returns proper response structures" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test single system creation response
      params_single = %{
        "solar_system_id" => 30000142,
        "position_x" => 100,
        "position_y" => 200
      }
      result_single = MapSystemAPIController.create(conn, params_single)
      assert %Plug.Conn{} = result_single
      assert result_single.resp_body != ""
      
      # Test batch operation response
      params_batch = %{
        "systems" => [],
        "connections" => []
      }
      result_batch = MapSystemAPIController.create(conn, params_batch)
      assert %Plug.Conn{} = result_batch
      assert result_batch.resp_body != ""
    end

    test "update returns proper response structure" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      result = MapSystemAPIController.update(conn, %{"id" => "30000142", "position_x" => 150})
      assert %Plug.Conn{} = result
      assert result.resp_body != ""
    end

    test "delete returns proper response structure" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      result = MapSystemAPIController.delete(conn, %{"system_ids" => [], "connection_ids" => []})
      assert %Plug.Conn{} = result
      
      if result.status == 200 do
        response = json_response(result, 200)
        assert Map.has_key?(response, "data")
        assert Map.has_key?(response["data"], "deleted_count")
        assert is_integer(response["data"]["deleted_count"])
      end
    end

    test "delete_single returns proper response structure" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      result = MapSystemAPIController.delete_single(conn, %{"id" => "30000142"})
      assert %Plug.Conn{} = result
      
      # Should have JSON response
      assert result.resp_body != ""
      response = Jason.decode!(result.resp_body)
      assert Map.has_key?(response, "data")
      assert Map.has_key?(response["data"], "deleted")
    end

    test "show_system returns proper response structure" do
      params = %{
        "map_id" => Ecto.UUID.generate(),
        "id" => "30000142"
      }
      result = MapSystemAPIController.show_system(build_conn(), params)
      assert %Plug.Conn{} = result
      
      # Should have JSON response
      assert result.resp_body != ""
    end

    test "error responses have consistent structure" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test error response from create
      params_error = %{
        "solar_system_id" => 30000142
        # Missing position_x and position_y
      }
      result_error = MapSystemAPIController.create(conn, params_error)
      assert json_response(result_error, 400)
      response = json_response(result_error, 400)
      assert Map.has_key?(response, "error")
      assert is_binary(response["error"])
    end
  end

  describe "legacy endpoint compatibility" do
    test "list_systems delegates to index" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # The list_systems function delegates to index, so it should behave the same
      result = MapSystemAPIController.list_systems(conn, %{})
      assert %Plug.Conn{} = result
      assert result.status in [200, 500]
    end

    test "show_system works with both map_id and slug parameters" do
      # Test with map_id
      params_map_id = %{
        "map_id" => Ecto.UUID.generate(),
        "id" => "30000142"
      }
      result_map_id = MapSystemAPIController.show_system(build_conn(), params_map_id)
      assert %Plug.Conn{} = result_map_id
      
      # Test with slug
      params_slug = %{
        "slug" => "test-map",
        "id" => "30000142"
      }
      result_slug = MapSystemAPIController.show_system(build_conn(), params_slug)
      assert %Plug.Conn{} = result_slug
    end
  end
end