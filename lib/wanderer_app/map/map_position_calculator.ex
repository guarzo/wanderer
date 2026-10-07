defmodule WandererApp.Map.PositionCalculator do
  @moduledoc false
  require Logger

  @ddrt Application.compile_env(:wanderer_app, :ddrt)

  # Nominal rendered system node (convertSystem2Node / --rf-node-* defaults).
  @node_w 130
  @node_h 34
  # Spacing the server always kept between nodes (the old ring margins).
  @gap_x 50
  @gap_y 17
  # Extra breathing room required between node rectangles.
  @padding 4
  # Canonical shared placement grid: the Faoble (zoo) theme snap grid, which is
  # the app's default theme. Positions are shared map state, so the server has
  # to commit to one theme-independent grid; users on other themes still get
  # their own theme's drag snapping on top of these positions.
  @grid_x 238
  @grid_y 51
  # "Limited" sticky stacking: a lane spills into the next one after roughly
  # 2*@max_secondary_steps + 1 placements, and the ordered search spans
  # 2*@max_primary_steps lanes. If every one of those is occupied, the scan
  # widens to @max_fallback_lanes lanes before the snapped anchor is used as
  # the last resort (a system must not be dropped over placement).
  @max_secondary_steps 5
  @max_primary_steps 6
  @max_fallback_lane 25

  def get_system_bounding_rect(%{position_x: x, position_y: y} = _system) do
    [{x, x + @node_w}, {y, y + @node_h}]
  end

  def get_system_bounding_rect(_system), do: [{0, 0}, {0, 0}]

  def get_new_system_position(nil, rtree_name, opts) do
    get_new_system_position(%{position_x: 0, position_y: 0}, rtree_name, opts)
  end

  def get_new_system_position(%{position_x: px, position_y: py} = _parent, rtree_name, opts) do
    layout = Keyword.get(opts, :layout, "left_to_right")
    prime_name = normalize_name(Keyword.get(opts, :prime_name))
    systems = Keyword.get(opts, :systems, [])

    {x, y} =
      compute_slot(
        px,
        py,
        layout,
        prime_name,
        systems,
        fn {x, y} -> position_free?(x, y, rtree_name) end
      )

    %{x: x, y: y}
  end

  # Pure slot search so the grid/ordering/collision rules are unit-testable
  # without an rtree: `available?` receives a candidate {x, y} and answers
  # whether a system may be placed there.
  #
  # Children live in the lane adjacent to the parent (per layout direction),
  # stacking tightly along the other axis. With a prime name, the preferred
  # stacking position keeps named siblings in alphabetical order; without one,
  # stacking starts at the parent row. Lanes fan outward only when the adjacent
  # ones are crowded; the snapped parent anchor is the last-resort fallback.
  def compute_slot(parent_x, parent_y, layout, prime_name, systems, available?) do
    vertical? = layout == "top_to_bottom"
    x_step = step(@grid_x, @node_w, @gap_x)
    y_step = step(@grid_y, @node_h, @gap_y)
    anchor_x = snap(parent_x, @grid_x)
    anchor_y = snap(parent_y, @grid_y)

    {target, mode} =
      target_secondary_index(prime_name, anchor_x, anchor_y, x_step, y_step, vertical?, systems)

    secondary_offsets = around(target, @max_secondary_steps, mode)
    primary_offsets = Enum.concat(outward(@max_primary_steps), fallback_lanes())

    Enum.find_value(primary_offsets, fn primary ->
      {base_x, base_y} =
        if vertical? do
          {anchor_x, anchor_y + primary * y_step}
        else
          {anchor_x + primary * x_step, anchor_y}
        end

      Enum.find_value(secondary_offsets, fn secondary ->
        candidate =
          if vertical? do
            {base_x + secondary * x_step, base_y}
          else
            {base_x, base_y + secondary * y_step}
          end

        if available?.(candidate), do: candidate, else: nil
      end)
    end)
    |> case do
      # Unreachable unless the neighborhood is pathological (every lane within
      # @max_fallback_lanes fully stacked); the snapped anchor is the least
      # surprising last resort - a system must not be dropped over placement.
      nil -> {anchor_x, anchor_y}
      slot -> slot
    end
  end

  # Where along the stacking axis the prime-named system belongs so that named
  # siblings in the children lane read alphabetically. Systems without a name
  # start at the parent row.
  defp target_secondary_index(nil, _anchor_x, _anchor_y, _x_step, _y_step, _vertical?, _systems),
    do: {0, :symmetric}

  defp target_secondary_index(prime_name, anchor_x, anchor_y, x_step, y_step, vertical?, systems) do
    named =
      systems
      |> Enum.filter(fn system ->
        normalize_name(Map.get(system, :temporary_name)) != nil and
          in_children_lane?(system, anchor_x, anchor_y, x_step, y_step, vertical?)
      end)
      |> Enum.map(fn system ->
        {secondary_index(system, anchor_x, anchor_y, x_step, y_step, vertical?),
         normalize_name(Map.get(system, :temporary_name))}
      end)
      |> Enum.sort_by(fn {index, name} -> {String.downcase(name), index} end)

    case Enum.find_index(named, fn {_index, name} ->
           String.downcase(name) > String.downcase(prime_name)
         end) do
      nil ->
        # Alphabetically last: one row past the final named sibling, or the
        # parent row when the lane has no named systems yet. Nothing to cut in
        # front of, so plain symmetric expansion applies.
        case List.last(named) do
          nil -> {0, :symmetric}
          {index, _name} -> {index + 1, :symmetric}
        end

      index ->
        # The target row holds the first name sorting after ours: try the row
        # right in front of it, then continue downward so the system lands as
        # close as possible to its alphabetical position.
        {target_index, _name} = Enum.at(named, index)
        {target_index, :insert_before}
    end
  end

  defp in_children_lane?(system, anchor_x, anchor_y, x_step, y_step, vertical?) do
    if vertical? do
      snap(Map.get(system, :position_y), @grid_y) == anchor_y + y_step
    else
      snap(Map.get(system, :position_x), @grid_x) == anchor_x + x_step
    end
  end

  defp secondary_index(system, anchor_x, anchor_y, x_step, y_step, vertical?) do
    if vertical? do
      div(round(Map.get(system, :position_x) - anchor_x), x_step)
    else
      div(round(Map.get(system, :position_y) - anchor_y), y_step)
    end
  end

  defp position_free?(x, y, rtree_name) do
    rect = [
      {x - @padding, x + @node_w + @padding},
      {y - @padding, y + @node_h + @padding}
    ]

    case @ddrt.query(rect, rtree_name) do
      {:ok, []} ->
        true

      {:ok, _} ->
        false

      _ ->
        true
    end
  end

  defp snap(value, grid), do: round(value / grid) * grid

  defp step(grid, node, gap), do: grid * max(1, ceil((node + gap) / grid))

  # Adjacent lane first, then farther along the reading direction, mirroring
  # lanes behind the parent only last.
  defp outward(max),
    do: Enum.concat(Enum.map(1..max, & &1), Enum.map(1..max, &(-&1)))

  # Lanes beyond the ordered fan-out, scanned before giving up.
  defp fallback_lanes,
    do: Enum.concat(Enum.to_list(7..@max_fallback_lane), Enum.to_list(-@max_fallback_lane..-7//1))

  # Offsets along the stacking axis, relative to the preferred row. Rows below
  # come first (chains read downward), the rows above backfill after.
  #   :insert_before - when a primed name must land in front of the next named
  #                    sibling, the row directly above gets first shot before
  #                    continuing downward
  defp around(center, max, :symmetric),
    do:
      Enum.concat([
        [center],
        Enum.map(1..max, &(&1 + center)),
        Enum.map(1..max, &(center - &1))
      ])

  defp around(center, max, :insert_before),
    do:
      Enum.concat([
        [center, center - 1],
        Enum.map(1..max, &(&1 + center)),
        Enum.map(2..max, &(center - &1))
      ])

  defp normalize_name(nil), do: nil

  defp normalize_name(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
