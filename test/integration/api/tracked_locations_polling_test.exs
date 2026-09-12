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
    {:ok, _} = Tokens.set_enabled(map.id, user, true)
    acl = insert(:access_list, %{owner_id: owner.id})
    insert(:map_access_list, %{map_id: map.id, access_list_id: acl.id})
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

    # Issue credentials before dispatch so these active maps need fresh evidence.
    clients =
      for _ <- 1..10 do
        reader = insert(:user)
        character = insert(:character, %{user_id: reader.id})

        insert(:access_list_member, %{
          access_list_id: acl.id,
          eve_character_id: character.eve_id,
          role: :viewer
        })

        {:ok, %{token: token}} = Tokens.generate(map.id, reader)
        %{wire: token.value, etag: nil, data: nil, statuses: []}
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

    {clients, statuses, queries, max_us} =
      Enum.reduce(0..29, {clients, %{}, [], 0}, fn tick, {clients, statuses, queries, max_us} ->
        Process.sleep(max(start + tick * 2000 - System.monotonic_time(:millisecond), 0))

        results =
          Task.async_stream(
            clients,
            fn %{wire: wire, etag: etag} = client ->
              before = :counters.get(counter, 2)
              requested_at = DateTime.utc_now()

              {elapsed, conn} =
                :timer.tc(fn ->
                  conn = build_conn() |> put_req_header("authorization", "Bearer #{wire}")
                  conn = if etag, do: put_req_header(conn, "if-none-match", etag), else: conn
                  get(conn, "/api/maps/#{map.id}/tracked-character-locations")
                end)

              assert conn.status in [200, 304]

              data = check_transition(client, conn, requested_at)

              client = %{
                client
                | etag: hd(get_resp_header(conn, "etag")),
                  data: data,
                  statuses: [conn.status | client.statuses]
              }

              {client, conn.status, :counters.get(counter, 2) - before, elapsed}
            end,
            max_concurrency: 10,
            timeout: 15_000
          )
          |> Enum.map(fn {:ok, value} -> value end)

        clients = Enum.map(results, &elem(&1, 0))

        statuses =
          Enum.reduce(results, statuses, fn {_, status, _, _}, acc ->
            Map.update(acc, status, 1, &(&1 + 1))
          end)

        {clients, statuses, queries ++ Enum.map(results, &elem(&1, 2)),
         max(max_us, Enum.max(Enum.map(results, &elem(&1, 3))))}
      end)

    Process.sleep(max(start + 60_000 - System.monotonic_time(:millisecond), 0))
    assert Enum.sum(Map.values(statuses)) == 300
    # One initial 200 plus at most one removal per initially fresh character.
    # check_transition proves each later 200 really removes evidence, not arbitrary churn.
    for client <- clients do
      assert length(client.statuses) == 30
      assert Enum.count(client.statuses, &(&1 == 200)) in 2..21
      assert Enum.all?(client.data, &is_nil(&1["solar_system_id"]))
    end

    assert statuses[200] in 20..210
    assert statuses[304] == 300 - statuses[200]
    assert :counters.get(counter, 1) == 20
    assert :counters.get(counter, 3) == 0
    # Fresh personal authorization adds two map/ACL/character reads to each
    # request (27 queries/request measured, 8101 total). The 9000 ceiling below
    # leaves 899 queries of headroom: bounded background noise is tolerated, but
    # not unbounded permission work or a snapshot heartbeat.
    assert :counters.get(counter, 2) <= 300 * 30

    IO.puts(
      "POLLING_SMOKE clients=10 records=20 duration_ms=#{System.monotonic_time(:millisecond) - start} requests=300 statuses=#{inspect(statuses)} queries=#{:counters.get(counter, 2)} max_concurrent_query_delta=#{Enum.max(queries)} max_request_us=#{max_us} fixture_http=20 snapshot_http=0 writes=0"
    )
  end

  defp check_transition(%{data: previous, etag: etag}, %{status: 304} = conn, requested_at) do
    assert previous != nil
    assert conn.resp_body == ""
    assert get_resp_header(conn, "etag") == [etag]

    for record <- previous, record["location_observed_at"] != nil do
      {:ok, observed, _} = DateTime.from_iso8601(record["location_observed_at"])
      assert DateTime.diff(requested_at, observed, :microsecond) < 15_000_000
    end

    previous
  end

  defp check_transition(%{data: previous, etag: etag}, conn, _requested_at) do
    body = json_response(conn, 200)
    data = body["data"]
    {:ok, snapshot_at, _} = DateTime.from_iso8601(body["observed_at"])
    assert length(data) == 20
    assert Enum.all?(data, &is_integer(&1["character_id"]))

    if previous == nil do
      assert Enum.all?(data, &(&1["solar_system_id"] == 30_000_142))
    else
      refute get_resp_header(conn, "etag") == [etag]
      refute data == previous

      for {old, current} <- Enum.zip(previous, data), old != current do
        assert old["solar_system_id"] == 30_000_142
        {:ok, observed, _} = DateTime.from_iso8601(old["location_observed_at"])
        assert DateTime.diff(snapshot_at, observed, :microsecond) >= 15_000_000

        assert current ==
                 Map.merge(old, %{
                   "online" => nil,
                   "solar_system_id" => nil,
                   "solar_system_name" => nil,
                   "display_name" => nil,
                   "map_system_visible" => false,
                   "location_observed_at" => nil,
                   "map_system_updated_at" => nil
                 })
      end
    end

    data
  end
end
