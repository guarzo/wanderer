defmodule WandererApp.Map.PositionCalculatorTest do
  use ExUnit.Case, async: true

  alias WandererApp.Map.PositionCalculator

  # The Faoble/zoo grid the calculator commits to (see the module constants):
  # lanes are 238 apart, stacking rows 51 apart.
  @grid_x 238
  @grid_y 51

  # `child_ids` is the set of solar_system_ids connected to the parent (its
  # children). Defaults to "every system on the map", the lane-mate assumption
  # the ordering tests below are written against; the sibling-scoping tests
  # pass an explicit set.
  defp slot(
         parent,
         systems \\ [],
         prime_name \\ nil,
         layout \\ "left_to_right",
         taken \\ [],
         child_ids \\ nil
       ) do
    # In production the rtree knows every placed system, so systems block their
    # own cell in addition to any extra occupied cells the test passes in.
    system_cells = Enum.map(systems, fn s -> {s.position_x, s.position_y} end)

    child_ids =
      if child_ids == nil,
        do: MapSet.new(Enum.map(systems, &Map.get(&1, :solar_system_id))),
        else: MapSet.new(child_ids)

    PositionCalculator.compute_slot(
      parent_x(parent),
      parent_y(parent),
      layout,
      prime_name,
      systems,
      child_ids,
      fn {x, y} -> {x, y} not in taken and {x, y} not in system_cells end
    )
  end

  defp parent_x(parent), do: elem(parent, 0)
  defp parent_y(parent), do: elem(parent, 1)

  defp system(x, y, temporary_name) do
    %{position_x: x, position_y: y, temporary_name: temporary_name}
  end

  defp child_system(x, y, temporary_name, solar_system_id) do
    Map.merge(system(x, y, temporary_name), %{solar_system_id: solar_system_id})
  end

  describe "grid placement" do
    test "places into the adjacent lane on the parent row" do
      assert slot({476, 153}) == {476 + @grid_x, 153}
    end

    test "snaps off-grid parents onto the shared grid" do
      assert slot({500, 180}) == {476 + @grid_x, 153 + @grid_y}
    end

    test "stacks siblings downward in the shared lane, skipping occupied rows" do
      lane_x = 476 + @grid_x
      parent = {476, 153}
      taken = [{lane_x, 153}, {lane_x, 153 + @grid_y}]

      assert slot(parent, [], nil, "left_to_right", taken) == {lane_x, 153 + 2 * @grid_y}
    end

    test "fans out to the next lane when the adjacent one is full" do
      lane_x = 476 + @grid_x
      parent = {476, 153}

      taken =
        for row <- -5..5 do
          {lane_x, 153 + row * @grid_y}
        end

      assert slot(parent, [], nil, "left_to_right", taken) == {476 + 2 * @grid_x, 153}
    end

    test "never uses the parent's own lane before fanning out" do
      # The parent's own cell is always occupied; the first candidate lane is
      # the adjacent one.
      parent = {476, 153}
      taken = [parent]

      {x, _y} = slot(parent, [], nil, "left_to_right", taken)

      assert x == 476 + @grid_x
    end

    test "keeps the snapped parent position only after the widened fallback scan" do
      parent = {476, 153}

      # Wall off every lane the ordered search and the widened fallback may
      # try (1..6 in each direction, then 7..25), all rows.
      taken =
        for lane <- Enum.concat(1..6, 7..25),
            sign <- [1, -1],
            row <- -5..5 do
          {476 + sign * lane * @grid_x, 153 + row * @grid_y}
        end

      assert slot(parent, [], nil, "left_to_right", taken) == {476, 153}
    end

    test "finds a slot in the widened fallback lanes when the ordered ones are full" do
      parent = {476, 153}

      taken =
        for lane <- 1..6,
            sign <- [1, -1],
            row <- -5..5 do
          {476 + sign * lane * @grid_x, 153 + row * @grid_y}
        end

      assert slot(parent, [], nil, "left_to_right", taken) == {476 + 7 * @grid_x, 153}
    end

    test "places below the parent for top-to-bottom maps" do
      assert slot({476, 153}, [], nil, "top_to_bottom") == {476, 153 + @grid_y}
    end
  end

  describe "prime name ordering" do
    test "keeps named siblings in the lane alphabetically ordered" do
      parent = {476, 153}
      lane_x = 476 + @grid_x

      # alpha sits on the parent row, charlie one row down.
      systems = [
        system(lane_x, 153, "alpha"),
        system(lane_x, 153 + @grid_y, "charlie")
      ]

      # bravo belongs between them: its preferred row is charlie's, which is
      # taken, so it takes the next free row below.
      assert slot(parent, systems, "bravo") == {lane_x, 153 + 2 * @grid_y}
    end

    test "takes an open alphabetical slot directly" do
      parent = {476, 153}
      lane_x = 476 + @grid_x

      systems = [
        system(lane_x, 153 + @grid_y, "charlie")
      ]

      # alpha sorts before charlie, whose row is one below the parent row.
      assert slot(parent, systems, "alpha") == {lane_x, 153}
    end

    test "appends after the last named sibling when sorting last" do
      parent = {476, 153}
      lane_x = 476 + @grid_x

      systems = [
        system(lane_x, 153, "alpha"),
        system(lane_x, 153 + @grid_y, "charlie")
      ]

      assert slot(parent, systems, "zulu") == {lane_x, 153 + 2 * @grid_y}
    end

    test "unnamed systems in the lane do not affect the ordering" do
      parent = {476, 153}
      lane_x = 476 + @grid_x

      systems = [
        system(lane_x, 153, nil),
        system(lane_x, 153 + @grid_y, "")
      ]

      # Rows below the parent are taken by the unnamed systems, so the first
      # free row is two below.
      assert slot(parent, systems, "alpha") == {lane_x, 153 + 2 * @grid_y}
    end

    test "with no named siblings the parent row is preferred" do
      parent = {476, 153}
      lane_x = 476 + @grid_x

      # A named system in a different lane is ignored.
      systems = [system(476 - @grid_x, 153, "alpha")]

      assert slot(parent, systems, "zulu") == {lane_x, 153}
    end

    test "ordering works along x for top-to-bottom maps" do
      parent = {476, 153}
      lane_y = 153 + @grid_y

      systems = [
        system(476 + @grid_x, lane_y, "charlie")
      ]

      assert slot(parent, systems, "alpha", "top_to_bottom") == {476, lane_y}
    end
  end

  describe "sibling scoping" do
    # The branch roots 1 and 2 (at x=476, 2 eight rows below 1) share a column,
    # so their children lanes coincide; only connections tell them apart.
    @two {476, 153 + 8 * @grid_y}
    @lane_x 476 + @grid_x

    test "cousins in the shared column do not augment the placement" do
      # 1's named children occupy the shared children lane; 2 has none yet.
      systems = [
        child_system(@lane_x, 153, "11", 11),
        child_system(@lane_x, 153 + @grid_y, "12", 12)
      ]

      # 21 must branch horizontally from its own parent 2, not slot in below
      # the cousins (which the name rule alone would have it do).
      assert slot(@two, systems, "21", "left_to_right", [], []) ==
               {@lane_x, 153 + 8 * @grid_y}
    end

    test "inserts above its own alphabetically-later sibling, cousins ignored" do
      # 2A jumped first and sits on 2's parent row; 21 arrives later and, by
      # the temp-name rule, becomes 2A's sibling one row above it.
      systems = [
        child_system(@lane_x, 153, "11", 11),
        child_system(@lane_x, 153 + @grid_y, "12", 12),
        child_system(@lane_x, 153 + 8 * @grid_y, "2A", 22)
      ]

      assert slot(@two, systems, "21", "left_to_right", [], [22]) ==
               {@lane_x, 153 + 7 * @grid_y}
    end

    test "appends below its own alphabetically-earlier sibling, cousins ignored" do
      # 21 jumped first and sits on 2's parent row; 2A belongs below it.
      systems = [
        child_system(@lane_x, 153, "11", 11),
        child_system(@lane_x, 153 + @grid_y, "12", 12),
        child_system(@lane_x, 153 + 8 * @grid_y, "21", 21)
      ]

      assert slot(@two, systems, "2A", "left_to_right", [], [21]) ==
               {@lane_x, 153 + 9 * @grid_y}
    end
  end
end
