defmodule WandererAppWeb.TrackedLocationsPollingTest do
  use WandererAppWeb.ApiCase, async: false
  import WandererApp.Test.TrackedLocationsFixtures
  alias WandererApp.Character.Tracker
  alias WandererApp.MapIntegrationTokens, as: Tokens

  @tag timeout: 120_000
  test "ten independent clients poll every two seconds for sixty seconds without GET-triggered ESI or writes" do
    # This real-time exercise outlives the ordinary 60-second test ownership timeout.
    Ecto.Adapters.SQL.Sandbox.stop_owner(Process.get(:sandbox_owner_pid))

    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(WandererApp.Repo,
        shared: true,
        ownership_timeout: 120_000
      )

    Process.put(:sandbox_owner_pid, owner)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    unless Process.whereis(:unique_tracker_pool_registry) do
      start_supervised!({Registry, keys: :unique, name: :unique_tracker_pool_registry})
    end

    Application.put_env(:wanderer_app, :map_integrations_enabled, true)
    original = Req.default_options()

    on_exit(fn ->
      Req.default_options(original)
      Application.delete_env(:wanderer_app, :map_integrations_enabled)
    end)

    user = insert(:user)
    owner = insert(:character, %{user_id: user.id})
    map = insert(:map, %{owner_id: owner.id})
    static_system()

    characters =
      for n <- 1..20 do
        char =
          tracked_character(map, %{user_id: user.id, eve_id: Integer.to_string(92_000_000 + n)})
          |> online(map)

        {:ok, char} =
          WandererApp.Api.Character.update_location(char, %{solar_system_id: 30_000_142})

        char
      end

    counter = :counters.new(3, [:write_concurrency])

    Req.default_options(
      plug: fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"solar_system_id":30000142}))
      end
    )

    for char <- characters do
      assert :ok = Tracker.update_location(WandererApp.Character.get_character_state!(char.id))
    end

    assert :counters.get(counter, 1) == 20
    # Independent consumers use independent issued tokens and conditional state.
    clients =
      for n <- 1..10 do
        {:ok, _, wire} = Tokens.create(map.id, user, "Polling client #{n}")
        {wire, nil}
      end

    handler = {__MODULE__, self()}

    :telemetry.attach(
      handler,
      [:wanderer_app, :repo, :query],
      fn _, _, metadata, _ ->
        :counters.add(counter, 2, 1)

        if Regex.match?(~r/^\s*(UPDATE|INSERT|DELETE)/i, metadata.query),
          do: :counters.add(counter, 3, 1)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    start = System.monotonic_time(:millisecond)

    {_, statuses, queries, max_us} =
      Enum.reduce(0..29, {clients, %{}, [], 0}, fn tick, {clients, statuses, queries, max_us} ->
        Process.sleep(max(start + tick * 2000 - System.monotonic_time(:millisecond), 0))

        results =
          Task.async_stream(
            clients,
            fn {wire, etag} ->
              before = :counters.get(counter, 2)

              {elapsed, conn} =
                :timer.tc(fn ->
                  conn = build_conn() |> put_req_header("authorization", "Bearer #{wire}")
                  conn = if etag, do: put_req_header(conn, "if-none-match", etag), else: conn
                  get(conn, "/api/maps/#{map.id}/tracked-character-locations")
                end)

              assert conn.status in [200, 304]

              if conn.status == 200 do
                data = json_response(conn, 200)["data"]
                assert length(data) == 20
                assert Enum.all?(data, &is_integer(&1["character_id"]))
                assert Enum.all?(data, &(&1["solar_system_id"] in [nil, 30_000_142]))
              end

              {wire, hd(get_resp_header(conn, "etag")), conn.status,
               :counters.get(counter, 2) - before, elapsed}
            end,
            max_concurrency: 10,
            timeout: 15_000
          )
          |> Enum.map(fn {:ok, value} -> value end)

        clients = Enum.map(results, fn {wire, etag, _, _, _} -> {wire, etag} end)

        statuses =
          Enum.reduce(results, statuses, fn {_, _, status, _, _}, acc ->
            Map.update(acc, status, 1, &(&1 + 1))
          end)

        {clients, statuses, queries ++ Enum.map(results, &elem(&1, 3)),
         max(max_us, Enum.max(Enum.map(results, &elem(&1, 4))))}
      end)

    Process.sleep(max(start + 60_000 - System.monotonic_time(:millisecond), 0))
    assert Enum.sum(Map.values(statuses)) == 300
    # First content + expiry transition per client; other polls are conditional.
    assert statuses[200] == 20
    assert statuses[304] == 280
    assert :counters.get(counter, 1) == 20
    assert :counters.get(counter, 3) == 0
    # Counter includes concurrent peers; bound total queries for the full batch.
    assert :counters.get(counter, 2) <= 300 * 20

    IO.puts(
      "POLLING_SMOKE clients=10 records=20 duration_ms=#{System.monotonic_time(:millisecond) - start} requests=300 statuses=#{inspect(statuses)} queries=#{:counters.get(counter, 2)} max_concurrent_query_delta=#{Enum.max(queries)} max_request_us=#{max_us} fixture_http=20 snapshot_http=0 writes=0"
    )
  end
end
