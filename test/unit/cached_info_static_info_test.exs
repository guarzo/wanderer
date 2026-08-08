defmodule WandererApp.CachedInfoStaticInfoTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.CachedInfo

  @repo_query_event [:wanderer_app, :repo, :query]
  @solar_system_table "map_solar_system_v2"

  defp unique_system_id, do: 31_000_000 + System.unique_integer([:positive])

  defp create_uncached_system do
    system = create_solar_system(%{solar_system_id: unique_system_id()})
    # The cache is process-global and survives across tests, so a system created
    # here could already have been pulled in by an earlier warm-up.
    Cachex.del(:system_static_info_cache, system.solar_system_id)
    on_exit(fn -> Cachex.del(:system_static_info_cache, system.solar_system_id) end)
    system
  end

  # Counts only full reads of the solar system table, which is what the warm-up
  # issues — inserts from the factory and unrelated queries are filtered out.
  defp count_table_scans(fun) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      @repo_query_event,
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == @solar_system_table and
             String.starts_with?(metadata[:query] || "", "SELECT") do
          Agent.update(counter, &(&1 + 1))
        end
      end,
      nil
    )

    try do
      result = fun.()
      {result, Agent.get(counter, & &1)}
    after
      :telemetry.detach(handler_id)
      Agent.stop(counter)
    end
  end

  # A single cache miss repopulates the entire table, so before the Courier
  # guard N concurrent misses each ran their own full scan and row-by-row
  # rewrite. Route hydration fans out over every system in a route at
  # `schedulers_online() * 4`, and the cache has a 4h TTL, so this fired on every
  # restart and every TTL rollover — and each redundant scan is what made an
  # individual lookup slow enough to blow its `Task.async_stream` budget.
  test "concurrent cache misses collapse into a single table scan" do
    systems = Enum.map(1..25, fn _ -> create_uncached_system() end)

    {results, scans} =
      count_table_scans(fn ->
        systems
        |> Enum.map(fn system ->
          Task.async(fn -> CachedInfo.get_system_static_info(system.solar_system_id) end)
        end)
        |> Task.await_many(15_000)
      end)

    # Every caller still gets its own system back, not just the one that won.
    assert length(results) == 25

    Enum.zip(systems, results)
    |> Enum.each(fn {system, result} ->
      assert {:ok, %{solar_system_id: id}} = result
      assert id == system.solar_system_id
    end)

    assert scans == 1
  end

  # The guard is `{:ignore, _}`, so nothing is written to mark the cache "warm".
  # That matters: a marker with a TTL would make a system inserted just after a
  # warm-up invisible until it expired. Sequential behaviour must be unchanged.
  test "a later miss still triggers a fresh scan and sees a newly added system" do
    first = create_uncached_system()
    assert {:ok, %{solar_system_id: _}} = CachedInfo.get_system_static_info(first.solar_system_id)

    second = create_uncached_system()

    {result, scans} =
      count_table_scans(fn -> CachedInfo.get_system_static_info(second.solar_system_id) end)

    assert {:ok, %{solar_system_id: id}} = result
    assert id == second.solar_system_id
    assert scans == 1
  end

  # `{:error, :not_found}` rather than a crash or a stale `{:ok, nil}` — the
  # route hydrator relies on this clause to drop the system instead of taking
  # the whole request down with a CaseClauseError.
  test "an id with no row still resolves to :not_found after the warm-up" do
    assert {:error, :not_found} = CachedInfo.get_system_static_info(unique_system_id())
  end
end
