defmodule WandererApp.Map.RouteAlert.EvaluatorTest do
  use ExUnit.Case, async: true

  alias WandererApp.Map.RouteAlert.Evaluator

  # 7 = k-space highsec (per `SystemClass`'s companion class ids in
  # `map_scopes_test.exs:14`); 1 = a C1 wormhole; not in
  # `SystemClass.wormhole_classes/0` is exactly what "non-wormhole" means here.
  @hs_class 7
  @wh_class 1

  defp static(id, security, class \\ @hs_class) do
    %{solar_system_id: id, security: security, system_class: class}
  end

  defp entry(origin, systems, success \\ true) do
    %{
      origin: origin,
      systems: systems,
      destination: 30_000_142,
      success: success,
      has_connection: systems != []
    }
  end

  defp solver_result(entries, static_data) do
    {:ok, %{routes: entries, systems_static_data: static_data}}
  end

  describe "evaluate/2 — failure and no-path" do
    test "{:error, _} is :unknown, regardless of opts" do
      assert Evaluator.evaluate({:error, :timeout}, max_jumps: 5) == :unknown
    end

    test "routes: [] is :unknown — the solver returning nothing is not a decision" do
      assert Evaluator.evaluate(solver_result([], []), max_jumps: 5) == :unknown
    end

    test "every entry success: false is :none — a genuine no-path" do
      result = solver_result([entry(1, [], false)], [])
      assert Evaluator.evaluate(result, max_jumps: 5) == :none
    end
  end

  describe "evaluate/2 — wormhole exemption" do
    test "a J-space hop at wormhole security does not disqualify the route" do
      origin = 31_000_001
      exit = 30_000_100

      static_data = [
        static(origin, -1.0, @wh_class),
        static(exit, 0.9)
      ]

      result = solver_result([entry(origin, [exit])], static_data)

      assert {:qualifying, %{jumps: 1, path: [^origin, ^exit], exit_system: ^exit}} =
               Evaluator.evaluate(result, max_jumps: 5)
    end
  end

  describe "evaluate/2 — the 0.45 boundary" do
    # `entry/3`'s `has_connection` derives from `systems != []`
    # (`map_route_info/1`, `map_routes.ex:333`), so every boundary case here
    # needs a real hop rather than an empty `systems` list — an empty list
    # would make the entry itself `unsuccessful?/1` for the wrong reason and
    # the test would pass without ever reaching the security check.
    test "0.45 qualifies" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), static(hop, 0.45)]
      result = solver_result([entry(origin, [hop])], static_data)

      assert {:qualifying, %{jumps: 1}} = Evaluator.evaluate(result, max_jumps: 5)
    end

    test "0.4 does not qualify" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), static(hop, 0.4)]
      result = solver_result([entry(origin, [hop])], static_data)

      assert Evaluator.evaluate(result, max_jumps: 5) == :none
    end
  end

  describe "evaluate/2 — fail-closed on unresolved statics" do
    test "a system missing from systems_static_data disqualifies the whole route" do
      origin = 30_000_001
      hop = 30_000_002
      # `hop`'s static entry is absent entirely.
      static_data = [static(origin, 0.9)]

      result = solver_result([entry(origin, [hop])], static_data)

      assert Evaluator.evaluate(result, max_jumps: 5) == :none
    end

    test "a nil entry in systems_static_data is treated as absent, not crashed on" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), nil, static(hop, 0.9)]

      result = solver_result([entry(origin, [hop])], static_data)

      assert {:qualifying, _} = Evaluator.evaluate(result, max_jumps: 5)
    end

    test "an unparseable security string disqualifies the route" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), static(hop, "not-a-number")]

      result = solver_result([entry(origin, [hop])], static_data)

      assert Evaluator.evaluate(result, max_jumps: 5) == :none
    end
  end

  describe "evaluate/2 — jump counting" do
    test "wormhole hops count toward the jump total" do
      origin = 31_000_001
      wh_hop = 31_000_002
      exit = 30_000_100

      static_data = [
        static(origin, -1.0, @wh_class),
        static(wh_hop, -1.0, @wh_class),
        static(exit, 0.9)
      ]

      result = solver_result([entry(origin, [wh_hop, exit])], static_data)

      assert {:qualifying, %{jumps: 2}} = Evaluator.evaluate(result, max_jumps: 5)
    end

    test "jumps == max_jumps qualifies" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), static(hop, 0.9)]

      result = solver_result([entry(origin, [hop])], static_data)

      assert {:qualifying, %{jumps: 1}} = Evaluator.evaluate(result, max_jumps: 1)
    end

    test "jumps == max_jumps + 1 does not qualify" do
      origin = 30_000_001
      hop = 30_000_002
      static_data = [static(origin, 0.9), static(hop, 0.9)]

      result = solver_result([entry(origin, [hop])], static_data)

      assert Evaluator.evaluate(result, max_jumps: 0) == :none
    end
  end

  describe "evaluate/2 — exit_system" do
    test "exit_system is the first non-wormhole system on the path" do
      origin = 31_000_001
      wh_hop = 31_000_002
      exit = 30_000_100
      hs_hop_after_exit = 30_000_101

      static_data = [
        static(origin, -1.0, @wh_class),
        static(wh_hop, -1.0, @wh_class),
        static(exit, 0.9),
        static(hs_hop_after_exit, 0.9)
      ]

      result = solver_result([entry(origin, [wh_hop, exit, hs_hop_after_exit])], static_data)

      assert {:qualifying, %{exit_system: ^exit}} = Evaluator.evaluate(result, max_jumps: 5)
    end
  end

  describe "solver_settings/0, jita_system_id/0, highsec_threshold/0" do
    test "returns the pinned settings from the design's decision 8" do
      assert Evaluator.solver_settings() == %{
               include_eol: false,
               include_mass_crit: false,
               include_frig: false,
               include_cruise: true,
               avoid_pochven: true,
               avoid_edencom: true,
               avoid_triglavian: true,
               include_thera: false
             }
    end

    test "jita_system_id/0 and highsec_threshold/0 are pinned constants" do
      assert Evaluator.jita_system_id() == 30_000_142
      assert Evaluator.highsec_threshold() == 0.45
    end
  end
end
