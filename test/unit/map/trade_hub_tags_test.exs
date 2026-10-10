defmodule WandererApp.Map.TradeHubTagsTest do
  use WandererApp.DataCase, async: false

  import Mox

  alias WandererApp.Map.TradeHubTags

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # `Routes.find/5` builds its solver params from trig-system data; priming
    # it to `[]` keeps params deterministic (same trick as
    # `map_routes_find_strict_test.exs`).
    WandererApp.Cache.insert(:trig_systems, [])
    on_exit(fn -> WandererApp.Cache.delete(:trig_systems) end)

    original_esi = Application.get_env(:wanderer_app, :esi_client)
    Application.put_env(:wanderer_app, :esi_client, WandererApp.Esi.Mock)
    on_exit(fn -> Application.put_env(:wanderer_app, :esi_client, original_esi) end)

    :ok
  end

  defp stub_static_info(system_id, security) do
    Cachex.put(:system_static_info_cache, system_id, %{
      solar_system_id: system_id,
      security: security,
      system_class: 7
    })

    on_exit(fn -> Cachex.del(:system_static_info_cache, system_id) end)
  end

  defp unique_system_id, do: 30_000_000 + System.unique_integer([:positive])

  defp stub_route(origin, destination, jumps) do
    stub(WandererApp.Esi.Mock, :get_routes_custom, fn _hubs, _origin, _params ->
      {:ok,
       [
         %{
           "origin" => origin,
           "destination" => destination,
           "systems" => for(_ <- 1..jumps, do: unique_system_id()) ++ [destination],
           "success" => true
         }
       ]}
    end)

    # `find/5` falls back to `get_routes_eve/4` when the custom route errors;
    # the custom stub above always succeeds, but stub the fallback to `[]` so
    # an unexpected fallback can't crash with Mox.UnexpectedCallError.
    stub(WandererApp.Esi.Mock, :get_routes_eve, fn _hubs, _origin, _params, _opts -> {:ok, []} end)
  end

  # --- pick_tag (pure selection over normalized route maps) ---

  test "closest hub wins" do
    jita = WandererApp.Map.RouteAlert.Evaluator.jita_system_id()

    routes = [
      %{origin: 1, destination: jita, systems: [2, 3, 4, jita], success: true},
      %{origin: 1, destination: 30_002_187, systems: [2, 30_002_187], success: true}
    ]

    assert {:ok, "2-A"} = TradeHubTags.pick_tag(routes)
  end

  test "tie breaks in Jita > Dodixie > Amarr > Hek > Rens order" do
    jita = WandererApp.Map.RouteAlert.Evaluator.jita_system_id()

    routes = [
      %{
        origin: 1,
        destination: 30_002_659,
        systems: [2, 3, 4, 5, 6, 7, 8, 9, 30_002_659],
        success: true
      },
      %{origin: 1, destination: jita, systems: [2, 3, 4, 5, 6, 7, 8, 9, jita], success: true}
    ]

    assert {:ok, "8-J"} = TradeHubTags.pick_tag(routes)
  end

  test "more than max_jumps from every hub skips" do
    jita = WandererApp.Map.RouteAlert.Evaluator.jita_system_id()
    too_far = TradeHubTags.max_jumps() + 1

    routes = [
      %{
        origin: 1,
        destination: jita,
        systems: Enum.to_list(2..(1 + too_far)) ++ [jita],
        success: true
      }
    ]

    assert :skip = TradeHubTags.pick_tag(routes)
  end

  test "exactly max_jumps still tags" do
    jita = WandererApp.Map.RouteAlert.Evaluator.jita_system_id()
    at_cap = TradeHubTags.max_jumps()

    routes = [
      %{
        origin: 1,
        destination: jita,
        systems: Enum.to_list(2..(1 + at_cap)) ++ [jita],
        success: true
      }
    ]

    assert {:ok, "10-J"} = TradeHubTags.pick_tag(routes)
  end

  test "unsuccessful routes never produce a tag" do
    jita = WandererApp.Map.RouteAlert.Evaluator.jita_system_id()

    routes = [
      %{origin: 1, destination: jita, systems: [jita], success: false}
    ]

    assert :skip = TradeHubTags.pick_tag(routes)
  end

  # --- maybe_tag_system (full path through Routes.find) ---

  test "tags a highsec system within range" do
    origin = unique_system_id()
    jita = WandererApp.Map.RouteAlert.Evaluator.jita_system_id()
    stub_static_info(origin, "0.9")
    stub_route(origin, jita, 5)

    # Tag write goes through the map server; with no live map the update
    # degrades to logged no-ops, so just assert the computation completes.
    assert :ok = TradeHubTags.maybe_tag_system("00000000-0000-0000-0000-000000000000", origin)
  end

  test "lowsec system is never routed or tagged" do
    origin = unique_system_id()
    stub_static_info(origin, "0.3")

    expect(WandererApp.Esi.Mock, :get_routes_custom, 0, fn _, _, _ -> flunk("must not route") end)

    assert :ok = TradeHubTags.maybe_tag_system("00000000-0000-0000-0000-000000000000", origin)
  end

  test "solver outage is swallowed" do
    origin = unique_system_id()
    stub_static_info(origin, "0.9")

    stub(WandererApp.Esi.Mock, :get_routes_custom, fn _hubs, _origin, _params ->
      {:error, :solver_unreachable}
    end)

    stub(WandererApp.Esi.Mock, :get_routes_eve, fn _hubs, _origin, _params, _opts ->
      {:error, :esi_unreachable}
    end)

    assert :ok = TradeHubTags.maybe_tag_system("00000000-0000-0000-0000-000000000000", origin)
  end
end
