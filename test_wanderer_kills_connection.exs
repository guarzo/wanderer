#!/usr/bin/env elixir

# Test script for WandererKills service connectivity
# Run with: mix run test_wanderer_kills_connection.exs

alias WandererApp.Kills.WandererKillsClient

IO.puts("🔍 Testing WandererKills Service Connection...")
IO.puts("=====================================")

# Test 1: Basic connectivity
IO.puts("\n1. Testing basic connectivity...")

case WandererKillsClient.test_connection() do
  {:ok, :connected} ->
    IO.puts("✅ Connection test passed!")

  {:error, reason} ->
    IO.puts("❌ Connection test failed: #{inspect(reason)}")
    IO.puts("\n💡 Troubleshooting tips:")
    IO.puts("   - Make sure WandererKills service is running")
    IO.puts("   - Check if port 4004 is accessible from this container")
    IO.puts("   - Verify the service URL in config: #{Application.get_env(:wanderer_app, :wanderer_kills_base_url)}")
    System.halt(1)
end

# Test 2: Try fetching system kill count for Jita (system ID: 30000142)
IO.puts("\n2. Testing kill count API for Jita (30000142)...")

case WandererKillsClient.get_system_kill_count(30000142) do
  {:ok, count} ->
    IO.puts("✅ Kill count API works! Jita has #{count} recent kills")

  {:error, reason} ->
    IO.puts("⚠️  Kill count API failed: #{inspect(reason)}")
end

# Test 3: Try fetching cached kills for Jita
IO.puts("\n3. Testing cached kills API for Jita...")

case WandererKillsClient.fetch_cached_kills(30000142) do
  {:ok, kills} when is_list(kills) ->
    IO.puts("✅ Cached kills API works! Found #{length(kills)} cached kills")

  {:error, reason} ->
    IO.puts("⚠️  Cached kills API failed: #{inspect(reason)}")
end

# Test 4: Try fetching fresh system kills
IO.puts("\n4. Testing fresh system kills API for Jita (last 1 hour)...")

case WandererKillsClient.fetch_system_kills(30000142, 1, 5) do
  {:ok, kills} when is_list(kills) ->
    IO.puts("✅ Fresh kills API works! Found #{length(kills)} recent kills")
    if length(kills) > 0 do
      first_kill = List.first(kills)
      IO.puts("   📝 Sample kill: #{first_kill["killmail_id"]} at #{first_kill["kill_time"]}")
    end

  {:error, reason} ->
    IO.puts("⚠️  Fresh kills API failed: #{inspect(reason)}")
end

IO.puts("\n🎉 Connection test completed!")
IO.puts("If all tests passed, the WandererKills integration is working correctly.")
