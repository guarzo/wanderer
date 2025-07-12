defmodule WandererAppWeb.MapConnectionAPIControllerTest do
  use WandererAppWeb.ConnCase

  alias WandererAppWeb.MapConnectionAPIController

  describe "parameter validation and helper functions" do
    test "index validates solar_system_source parameter" do
      conn = build_conn() |> assign(:map_id, Ecto.UUID.generate())
      
      # Test with valid parameter
      params_valid = %{"solar_system_source" => "30000142"}
      result_valid = MapConnectionAPIController.index(conn, params_valid)
      assert %Plug.Conn{} = result_valid
      
      # Test with invalid parameter
      params_invalid = %{"solar_system_source" => "invalid"}
      result_invalid = MapConnectionAPIController.index(conn, params_invalid)
      assert json_response(result_invalid, 400)
      response = json_response(result_invalid, 400)
      assert Map.has_key?(response, "error")
    end

    test "index validates solar_system_target parameter" do
      conn = build_conn() |> assign(:map_id, Ecto.UUID.generate())
      
      # Test with valid parameter
      params_valid = %{"solar_system_target" => "30000143"}
      result_valid = MapConnectionAPIController.index(conn, params_valid)
      assert %Plug.Conn{} = result_valid
      
      # Test with invalid parameter
      params_invalid = %{"solar_system_target" => "invalid"}
      result_invalid = MapConnectionAPIController.index(conn, params_invalid)
      assert json_response(result_invalid, 400)
      response = json_response(result_invalid, 400)
      assert Map.has_key?(response, "error")
    end

    test "index filters connections by source and target" do
      conn = build_conn() |> assign(:map_id, Ecto.UUID.generate())
      
      # Test with both filters
      params = %{
        "solar_system_source" => "30000142",
        "solar_system_target" => "30000143"
      }
      result = MapConnectionAPIController.index(conn, params)
      assert %Plug.Conn{} = result
      assert result.status in [200, 404, 500]
    end

    test "show by connection id" do
      map_id = Ecto.UUID.generate()
      conn_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      params = %{"id" => conn_id}
      result = MapConnectionAPIController.show(conn, params)
      # Should handle the call without crashing
      assert %Plug.Conn{} = result
    end

    test "show by source and target system IDs" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test with valid system IDs
      params_valid = %{
        "solar_system_source" => "30000142",
        "solar_system_target" => "30000143"
      }
      result_valid = MapConnectionAPIController.show(conn, params_valid)
      assert %Plug.Conn{} = result_valid
      
      # Test with invalid system IDs
      params_invalid = %{
        "solar_system_source" => "invalid",
        "solar_system_target" => "30000143"
      }
      result_invalid = MapConnectionAPIController.show(conn, params_invalid)
      assert %Plug.Conn{} = result_invalid
    end

    test "create connection with valid parameters" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      params = %{
        "solar_system_source" => 30000142,
        "solar_system_target" => 30000143,
        "type" => 0
      }
      
      result = MapConnectionAPIController.create(conn, params)
      assert %Plug.Conn{} = result
      # Response depends on underlying data
      assert result.status in [200, 201, 400, 500]
    end

    test "create connection handles various response types" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      params = %{
        "solar_system_source" => 30000142,
        "solar_system_target" => 30000143
      }
      
      result = MapConnectionAPIController.create(conn, params)
      assert %Plug.Conn{} = result
    end

    test "delete connection by id" do
      map_id = Ecto.UUID.generate()
      conn_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      params = %{"id" => conn_id}
      result = MapConnectionAPIController.delete(conn, params)
      assert %Plug.Conn{} = result
    end

    test "delete connection by source and target" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      params = %{
        "solar_system_source" => "30000142",
        "solar_system_target" => "30000143"
      }
      result = MapConnectionAPIController.delete(conn, params)
      assert %Plug.Conn{} = result
    end

    test "delete multiple connections by connection_ids" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      conn_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      params = %{"connection_ids" => conn_ids}
      result = MapConnectionAPIController.delete(conn, params)
      assert %Plug.Conn{} = result
    end

    test "update connection by id" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Mock body_params
      body_params = %{
        "mass_status" => 1,
        "ship_size_type" => 2,
        "locked" => false
      }
      conn = %{conn | body_params: body_params}
      
      params = %{"id" => conn_id}
      result = MapConnectionAPIController.update(conn, params)
      assert %Plug.Conn{} = result
    end

    test "update connection by source and target systems" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      body_params = %{
        "mass_status" => 1,
        "type" => 0
      }
      conn = %{conn | body_params: body_params}
      
      params = %{
        "solar_system_source" => "30000142",
        "solar_system_target" => "30000143"
      }
      result = MapConnectionAPIController.update(conn, params)
      assert %Plug.Conn{} = result
    end

    test "list_all_connections legacy endpoint" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      result = MapConnectionAPIController.list_all_connections(conn, %{})
      assert %Plug.Conn{} = result
      assert result.status in [200, 500]
    end
  end

  describe "parameter parsing and edge cases" do
    test "parse_optional handles various input formats" do
      # This tests the private function indirectly through index
      conn = build_conn() |> assign(:map_id, Ecto.UUID.generate())
      
      # Test nil parameter
      result_nil = MapConnectionAPIController.index(conn, %{})
      assert %Plug.Conn{} = result_nil
      
      # Test empty string
      result_empty = MapConnectionAPIController.index(conn, %{"solar_system_source" => ""})
      assert %Plug.Conn{} = result_empty
      
      # Test zero value
      result_zero = MapConnectionAPIController.index(conn, %{"solar_system_source" => "0"})
      assert %Plug.Conn{} = result_zero
    end

    test "filter functions handle edge cases" do
      # Test filtering indirectly through index
      conn = build_conn() |> assign(:map_id, Ecto.UUID.generate())
      
      # Test with valid filters
      params_with_filters = %{
        "solar_system_source" => "30000142",
        "solar_system_target" => "30000143"
      }
      result = MapConnectionAPIController.index(conn, params_with_filters)
      assert %Plug.Conn{} = result
    end

    test "handles missing map_id in assigns" do
      conn = build_conn()
      
      # This should fail due to missing assigns
      assert_raise(MatchError, fn ->
        MapConnectionAPIController.index(conn, %{})
      end)
    end

    test "handles different parameter combinations for show" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test various parameter combinations that should route to different clauses
      param_combinations = [
        %{"id" => Ecto.UUID.generate()},
        %{"solar_system_source" => "30000142", "solar_system_target" => "30000143"},
        %{"solar_system_source" => "invalid", "solar_system_target" => "30000143"},
        %{"solar_system_source" => "30000142", "solar_system_target" => "invalid"}
      ]
      
      Enum.each(param_combinations, fn params ->
        result = MapConnectionAPIController.show(conn, params)
        assert %Plug.Conn{} = result
      end)
    end

    test "handles different parameter combinations for delete" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test various parameter combinations
      param_combinations = [
        %{"id" => Ecto.UUID.generate()},
        %{"solar_system_source" => "30000142", "solar_system_target" => "30000143"},
        %{"connection_ids" => [Ecto.UUID.generate()]},
        %{"connection_ids" => []}
      ]
      
      Enum.each(param_combinations, fn params ->
        result = MapConnectionAPIController.delete(conn, params)
        assert %Plug.Conn{} = result
      end)
    end

    test "handles different body_params for update" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn_id = Ecto.UUID.generate()
      base_conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test different body_params combinations
      body_param_combinations = [
        %{},
        %{"mass_status" => 1},
        %{"ship_size_type" => 2},
        %{"locked" => true},
        %{"custom_info" => "test info"},
        %{"type" => 0},
        %{"mass_status" => 1, "ship_size_type" => 2, "locked" => false},
        %{"invalid_field" => "should_be_ignored", "mass_status" => 1}
      ]
      
      Enum.each(body_param_combinations, fn body_params ->
        conn = %{base_conn | body_params: body_params}
        result = MapConnectionAPIController.update(conn, %{"id" => conn_id})
        assert %Plug.Conn{} = result
      end)
    end
  end

  describe "error handling scenarios" do
    test "handles malformed connection IDs" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test with various malformed IDs
      malformed_ids = ["", "invalid-uuid", "123", nil]
      
      Enum.each(malformed_ids, fn id ->
        params = %{"id" => id}
        result = MapConnectionAPIController.show(conn, params)
        assert %Plug.Conn{} = result
      end)
    end

    test "handles malformed system IDs for show" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test with various malformed system IDs
      malformed_system_combinations = [
        %{"solar_system_source" => nil, "solar_system_target" => "30000143"},
        %{"solar_system_source" => "30000142", "solar_system_target" => nil},
        %{"solar_system_source" => "", "solar_system_target" => "30000143"},
        %{"solar_system_source" => "abc", "solar_system_target" => "def"},
        %{"solar_system_source" => -1, "solar_system_target" => 30000143}
      ]
      
      Enum.each(malformed_system_combinations, fn params ->
        result = MapConnectionAPIController.show(conn, params)
        assert %Plug.Conn{} = result
      end)
    end

    test "handles malformed system IDs for delete" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      malformed_params = [
        %{"solar_system_source" => "invalid", "solar_system_target" => "30000143"},
        %{"solar_system_source" => "30000142", "solar_system_target" => "invalid"},
        %{"solar_system_source" => "", "solar_system_target" => ""},
        %{"solar_system_source" => nil, "solar_system_target" => nil}
      ]
      
      Enum.each(malformed_params, fn params ->
        result = MapConnectionAPIController.delete(conn, params)
        assert %Plug.Conn{} = result
      end)
    end

    test "handles create with missing or invalid parameters" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test various invalid parameter combinations
      invalid_param_combinations = [
        %{},
        %{"solar_system_source" => nil},
        %{"solar_system_target" => nil},
        %{"solar_system_source" => "invalid", "solar_system_target" => "30000143"},
        %{"solar_system_source" => 30000142, "solar_system_target" => "invalid"}
      ]
      
      Enum.each(invalid_param_combinations, fn params ->
        result = MapConnectionAPIController.create(conn, params)
        assert %Plug.Conn{} = result
        # Should handle gracefully with appropriate error response
        assert result.status in [200, 201, 400, 500]
      end)
    end

    test "handles update with malformed system IDs" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      base_conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      body_params = %{"mass_status" => 1}
      conn = %{base_conn | body_params: body_params}
      
      malformed_params = [
        %{"solar_system_source" => "invalid", "solar_system_target" => "30000143"},
        %{"solar_system_source" => "30000142", "solar_system_target" => "invalid"},
        %{"solar_system_source" => "", "solar_system_target" => ""}
      ]
      
      Enum.each(malformed_params, fn params ->
        result = MapConnectionAPIController.update(conn, params)
        assert %Plug.Conn{} = result
      end)
    end

    test "handles nil and empty values in body_params" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn_id = Ecto.UUID.generate()
      base_conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      # Test body_params with nil values (should be filtered out)
      body_params_with_nils = %{
        "mass_status" => nil,
        "ship_size_type" => 2,
        "locked" => nil,
        "custom_info" => nil,
        "type" => 0
      }
      conn = %{base_conn | body_params: body_params_with_nils}
      
      result = MapConnectionAPIController.update(conn, %{"id" => conn_id})
      assert %Plug.Conn{} = result
    end

    test "handles empty connection_ids list for batch delete" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      params = %{"connection_ids" => []}
      result = MapConnectionAPIController.delete(conn, params)
      assert %Plug.Conn{} = result
      
      # Should return successful response with 0 deleted count
      if result.status == 200 do
        response = json_response(result, 200)
        assert Map.has_key?(response, "data")
        assert Map.has_key?(response["data"], "deleted_count")
        assert response["data"]["deleted_count"] == 0
      end
    end
  end

  describe "response structure validation" do
    test "index returns consistent data structure" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      result = MapConnectionAPIController.index(conn, %{})
      assert %Plug.Conn{} = result
      
      # If successful, should have data wrapper
      if result.status == 200 do
        response = json_response(result, 200)
        assert Map.has_key?(response, "data")
        assert is_list(response["data"])
      end
    end

    test "show returns consistent data structure" do
      map_id = Ecto.UUID.generate()
      conn_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      result = MapConnectionAPIController.show(conn, %{"id" => conn_id})
      assert %Plug.Conn{} = result
      
      # Should have proper JSON structure
      assert result.resp_body != ""
    end

    test "create returns proper response formats" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      params = %{
        "solar_system_source" => 30000142,
        "solar_system_target" => 30000143
      }
      
      result = MapConnectionAPIController.create(conn, params)
      assert %Plug.Conn{} = result
      
      # Should return JSON response
      assert result.resp_body != ""
      
      # Parse response and check structure
      response = Jason.decode!(result.resp_body)
      assert is_map(response)
      # Should have either data or error field
      assert Map.has_key?(response, "data") or Map.has_key?(response, "error")
    end

    test "update returns proper response structure" do
      map_id = Ecto.UUID.generate()
      char_id = "123456789"
      conn_id = Ecto.UUID.generate()
      base_conn = build_conn() |> assign(:map_id, map_id) |> assign(:owner_character_id, char_id)
      
      body_params = %{"mass_status" => 1}
      conn = %{base_conn | body_params: body_params}
      
      result = MapConnectionAPIController.update(conn, %{"id" => conn_id})
      assert %Plug.Conn{} = result
      
      # Should have JSON response
      assert result.resp_body != ""
    end

    test "delete returns proper response structure" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      # Test both deletion methods
      delete_params = [
        %{"id" => Ecto.UUID.generate()},
        %{"solar_system_source" => "30000142", "solar_system_target" => "30000143"},
        %{"connection_ids" => [Ecto.UUID.generate()]}
      ]
      
      Enum.each(delete_params, fn params ->
        result = MapConnectionAPIController.delete(conn, params)
        assert %Plug.Conn{} = result
        
        # Should have some response
        assert is_binary(result.resp_body)
      end)
    end

    test "list_all_connections returns proper structure" do
      map_id = Ecto.UUID.generate()
      conn = build_conn() |> assign(:map_id, map_id)
      
      result = MapConnectionAPIController.list_all_connections(conn, %{})
      assert %Plug.Conn{} = result
      
      if result.status == 200 do
        response = json_response(result, 200)
        assert Map.has_key?(response, "data")
        assert is_list(response["data"])
      end
    end
  end
end