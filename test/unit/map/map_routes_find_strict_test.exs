defmodule WandererApp.Map.RoutesFindStrictTest do
  use WandererApp.DataCase, async: false

  import Mox

  alias WandererApp.Map.Routes

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # `find/5` and `find_strict/5` share a cache key built from `{origin, hubs,
    # params}` (map_routes.ex:224-225). Trig-system data feeds `params.avoid`
    # (map_routes.ex:154-201), so priming it to `[]` keeps every test's params
    # identical without a real `MapSolarSystem` row for the trig query.
    WandererApp.Cache.insert(:trig_systems, [])
    on_exit(fn -> WandererApp.Cache.delete(:trig_systems) end)

    original_esi = Application.get_env(:wanderer_app, :esi_client)
    Application.put_env(:wanderer_app, :esi_client, WandererApp.Esi.Mock)
    on_exit(fn -> Application.put_env(:wanderer_app, :esi_client, original_esi) end)

    :ok
  end

  # `avoid_wormholes: true` in `routes_settings` skips the `MapConnection` read
  # and the Thera chain fetch entirely (map_routes.ex:100-152), so these tests
  # exercise the ESI seam without needing a real map's connections in the DB.
  @routes_settings %{avoid_wormholes: true}

  defp unique_system_id, do: 30_000_000 + System.unique_integer([:positive])

  # `get_system_static_info/1` reads `:system_static_info_cache` before falling
  # back to a full `MapSolarSystem` table scan (cached_info.ex:101-141), and
  # that fallback has no clause for `{:error, :not_found}` in `find/5`'s
  # `Task.async_stream` handler (map_routes.ex:61-67) — priming the cache
  # avoids both the DB round trip and that latent crash.
  defp stub_static_info(system_id) do
    Cachex.put(:system_static_info_cache, system_id, %{
      solar_system_id: system_id,
      security: "0.9",
      system_class: 7
    })

    on_exit(fn -> Cachex.del(:system_static_info_cache, system_id) end)
  end

  test "find/5 still falls back to get_routes_eve on a custom-route error" do
    hub = unique_system_id()
    origin = unique_system_id()
    stub_static_info(hub)
    stub_static_info(origin)

    stub(WandererApp.Esi.Mock, :get_routes_custom, fn _hubs, _origin, _params ->
      {:error, :solver_unreachable}
    end)

    stub(WandererApp.Esi.Mock, :get_routes_eve, fn hubs, origin, _params, _opts ->
      {:ok,
       Enum.map(hubs, fn hub ->
         %{"origin" => origin, "destination" => hub, "systems" => [], "success" => false}
       end)}
    end)

    assert {:ok, %{routes: [%{success: false}], systems_static_data: []}} =
             Routes.find(
               Ecto.UUID.generate(),
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )
  end

  test "find_strict/5 propagates {:error, reason} instead of falling back to get_routes_eve" do
    hub = unique_system_id()
    origin = unique_system_id()

    stub(WandererApp.Esi.Mock, :get_routes_custom, fn _hubs, _origin, _params ->
      {:error, :solver_unreachable}
    end)

    stub(WandererApp.Esi.Mock, :get_routes_eve, fn _hubs, _origin, _params, _opts ->
      flunk("find_strict/5 must not fall back to get_routes_eve on a solver error")
    end)

    assert {:error, :solver_unreachable} =
             Routes.find_strict(
               Ecto.UUID.generate(),
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )
  end

  test "find_strict/5 matches find/5 on the success path and shares its cache key" do
    hub = unique_system_id()
    origin = unique_system_id()
    stub_static_info(hub)
    stub_static_info(origin)
    map_id = Ecto.UUID.generate()

    # `expect ... 1` proves the shared cache key: if `find_strict/5` hashed its
    # params differently from `find/5`, the second call below would miss the
    # cache and this expectation would fail with "called 2 times".
    expect(WandererApp.Esi.Mock, :get_routes_custom, 1, fn hubs, origin, _params ->
      {:ok,
       Enum.map(hubs, fn hub ->
         %{
           "origin" => origin,
           "destination" => hub,
           "systems" => [hub],
           "success" => true
         }
       end)}
    end)

    assert {:ok, strict_result} =
             Routes.find_strict(
               map_id,
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )

    assert {:ok, find_result} =
             Routes.find(
               map_id,
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )

    # `routes` are identical either way — only `systems_static_data` differs,
    # by design (see the next test): `find_strict/5` also hydrates the
    # origin's static info, `find/5` does not.
    assert strict_result.routes == find_result.routes
    assert [%{success: true, origin: ^origin, destination: ^hub}] = strict_result.routes
  end

  test "find_strict/5 includes the origin in systems_static_data, find/5 does not" do
    hub = unique_system_id()
    origin = unique_system_id()
    stub_static_info(hub)
    stub_static_info(origin)
    map_id = Ecto.UUID.generate()

    stub(WandererApp.Esi.Mock, :get_routes_custom, fn hubs, origin, _params ->
      {:ok,
       Enum.map(hubs, fn hub ->
         %{
           "origin" => origin,
           "destination" => hub,
           "systems" => [hub],
           "success" => true
         }
       end)}
    end)

    assert {:ok, %{systems_static_data: strict_static_data}} =
             Routes.find_strict(
               map_id,
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )

    assert {:ok, %{systems_static_data: find_static_data}} =
             Routes.find(
               # Different `map_id` so this second call cannot hit the cache
               # key `find_strict/5` just populated above.
               Ecto.UUID.generate(),
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )

    strict_system_ids = Enum.map(strict_static_data, & &1.solar_system_id)
    find_system_ids = Enum.map(find_static_data, & &1.solar_system_id)

    assert origin in strict_system_ids
    assert hub in strict_system_ids
    refute origin in find_system_ids
    assert hub in find_system_ids
  end

  # The counterpart to `stub_static_info/1`'s comment above: a system with no
  # cache entry and no `MapSolarSystem` row resolves to an error, not `{:ok,
  # nil}`. That must degrade to missing static data, not take the solve down.
  test "find_strict/5 survives a system whose static record does not resolve" do
    hub = unique_system_id()
    origin = unique_system_id()
    # `hub` is deliberately NOT stubbed.
    stub_static_info(origin)

    stub(WandererApp.Esi.Mock, :get_routes_custom, fn hubs, origin, _params ->
      {:ok,
       Enum.map(hubs, fn hub ->
         %{"origin" => origin, "destination" => hub, "systems" => [hub], "success" => true}
       end)}
    end)

    assert {:ok, %{routes: [%{success: true}], systems_static_data: static_data}} =
             Routes.find_strict(
               Ecto.UUID.generate(),
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )

    # The origin still hydrated; the unresolvable hub is absent from the list
    # rather than present as `nil` — `RoutesWidget.tsx:60` and `PingRoute.tsx:28`
    # dereference every element while searching by id, so a `null` there throws.
    refute Enum.any?(static_data, &is_nil/1)
    assert origin in Enum.map(static_data, & &1.solar_system_id)
    refute hub in Enum.map(static_data, & &1.solar_system_id)
  end

  # `Task.async_stream`'s default `on_timeout: :exit` kills the CALLING process
  # when a lookup overruns. A cold `get_system_static_info/1` scans the entire
  # MapSolarSystem table and repopulates the cache row by row
  # (cached_info.ex:101-141), so overrunning the 5s default is realistic on any
  # restart or TTL expiry.
  #
  # Exercised through `find_strict/5` because it is the entry point with a
  # seam this test can drive, but the severe case is `find/5`: it runs inside a
  # `Task.async` linked to the LiveView (map_routes_event_handler.ex:98,142),
  # which does not trap exits, so one slow lookup remounted the whole map. The
  # collector is shared, so covering it here covers both.
  #
  # Squeezing the per-system budget to 1ms forces the overrun deterministically:
  # reaching the assertion at all is the point, because under `on_timeout:
  # :exit` this test process simply exited instead.
  test "find_strict/5 survives a static lookup that overruns its timeout" do
    hub = unique_system_id()
    origin = unique_system_id()

    original_timeout = Application.get_env(:wanderer_app, :route_static_info_timeout_ms)
    Application.put_env(:wanderer_app, :route_static_info_timeout_ms, 1)

    on_exit(fn ->
      case original_timeout do
        nil -> Application.delete_env(:wanderer_app, :route_static_info_timeout_ms)
        value -> Application.put_env(:wanderer_app, :route_static_info_timeout_ms, value)
      end
    end)

    stub(WandererApp.Esi.Mock, :get_routes_custom, fn hubs, origin, _params ->
      {:ok,
       Enum.map(hubs, fn hub ->
         %{"origin" => origin, "destination" => hub, "systems" => [hub], "success" => true}
       end)}
    end)

    assert {:ok, %{routes: [%{success: true}], systems_static_data: static_data}} =
             Routes.find_strict(
               Ecto.UUID.generate(),
               [Integer.to_string(hub)],
               Integer.to_string(origin),
               @routes_settings,
               false
             )

    # A timed-out system is omitted, exactly like any other unresolvable one, so
    # the frontend's `.find(sd => sd.solar_system_id === id)` never meets a
    # `null`. Whether the cached origin wins the race at a 1ms budget is not
    # asserted — pinning that would be flaky.
    assert length(static_data) <= 2
    assert Enum.all?(static_data, &is_map/1)
  end
end
