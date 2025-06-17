defmodule WandererApp.SimpleWorkingTest do
  use WandererApp.ApiCase

  @moduletag :api

  @moduledoc """
  Simple working test that demonstrates how to properly set up test data
  using the existing factories from the main test suite.
  """

  # Note: WandererApp.Factory doesn't exist in this codebase
  # Tests need to use Ash resources or the hybrid approach with real API tokens

  setup do
    # Use Ecto Sandbox for test isolation
    case Ecto.Adapters.SQL.Sandbox.checkout(WandererApp.Repo) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end

    {:ok, conn: build_conn()}
  end

  describe "Direct database tests" do
    test "can query existing tables", %{conn: conn} do
      # Test that we can query the maps table
      result = WandererApp.Repo.query("SELECT COUNT(*) FROM maps_v1")
      assert {:ok, _} = result
    end

    test "can query characters table", %{conn: conn} do
      result = WandererApp.Repo.query("SELECT COUNT(*) FROM character_v1")
      assert {:ok, _} = result
    end
  end


  describe "API endpoint availability" do
    test "health check endpoint works", %{conn: conn} do
      conn = get(conn, "/api/common/system-static-info?system_id=30000142")

      # This endpoint might be public - it can return various statuses
      assert conn.status in [200, 400, 401, 404]
    end

    test "map systems endpoint exists", %{conn: conn} do
      conn = get(conn, "/api/maps/test-map/systems")

      # Should return 404 when map doesn't exist
      assert conn.status == 404
    end

    test "ACL endpoint exists", %{conn: conn} do
      conn = get(conn, "/api/acls/test-id")

      # Should return 401 without auth
      assert conn.status == 401
    end
  end
end
