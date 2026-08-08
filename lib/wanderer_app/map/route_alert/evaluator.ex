defmodule WandererApp.Map.RouteAlert.Evaluator do
  @moduledoc """
  Pure decision function turning a `WandererApp.Map.Routes.find_strict/5`
  result into the three-state model the route-alert watcher acts on. No HTTP,
  no GenServer, no `CachedInfo` lookups — every system's security and class
  travel in `systems_static_data`, which `find_strict/5` already hydrates.

  See the design doc's "Alert semantics" and "Failure posture" sections for the
  rules this module encodes.
  """

  alias WandererApp.SystemClass

  @jita_system_id 30_000_142
  @highsec_threshold 0.45

  # Derived at compile time from the canonical list rather than restated, so
  # this cannot drift from `SystemClass`. A module attribute is required because
  # `system_qualifies?/2` matches on the class in a guard, and a guard cannot
  # call a remote function.
  @wormhole_classes SystemClass.wormhole_classes()

  # Pinned per the design's decision 8 — there is no user in this code path, so
  # settings are not read from any widget preference. `include_mass_crit:
  # false` and `include_frig: false` differ from `Routes`' own module defaults
  # because a crit or frigate-sized connection will not pass a hauler.
  # `include_thera: false` keeps every alert attributable to the map's own
  # chain rather than to public Thera connectivity.
  @solver_settings %{
    include_eol: false,
    include_mass_crit: false,
    include_frig: false,
    include_cruise: true,
    avoid_pochven: true,
    avoid_edencom: true,
    avoid_triglavian: true,
    include_thera: false
  }

  @type outcome ::
          {:qualifying, %{jumps: pos_integer(), path: [integer()], exit_system: integer() | nil}}
          | :none
          | :unknown

  @spec jita_system_id() :: 30_000_142
  def jita_system_id, do: @jita_system_id

  # `@spec ... :: 0.45` (as literally written in the design contract) is not
  # valid Elixir: unlike integers, float literals cannot appear as singleton
  # types in a typespec (`Kernel.Typespec.compile_error/2`). `float()` is the
  # nearest valid spec; the value itself is still pinned to 0.45 below and
  # asserted by `evaluate/2 — the 0.45 boundary` and the constants test.
  @spec highsec_threshold() :: float()
  def highsec_threshold, do: @highsec_threshold

  @spec solver_settings() :: map()
  def solver_settings, do: @solver_settings

  @doc """
  `opts` must include `max_jumps: pos_integer()`.

  Fails closed: any system on a route's path that is missing from
  `systems_static_data`, or whose `security` will not parse, disqualifies that
  route entirely (`:none`, not `:unknown`) — an unresolvable system is a route
  this module will not vouch for. See the design doc's "Failure posture".
  """
  @spec evaluate({:ok, map()} | {:error, term()}, keyword()) :: outcome()
  def evaluate({:error, _reason}, _opts), do: :unknown

  def evaluate({:ok, %{routes: []}}, _opts), do: :unknown

  def evaluate({:ok, %{routes: entries, systems_static_data: static_data}}, opts) do
    if Enum.all?(entries, &unsuccessful?/1) do
      :none
    else
      max_jumps = Keyword.fetch!(opts, :max_jumps)
      static_by_id = index_static_data(static_data)

      entries
      |> Enum.reject(&unsuccessful?/1)
      |> Enum.find_value(:none, &qualify(&1, static_by_id, max_jumps))
    end
  end

  defp unsuccessful?(%{success: false}), do: true
  defp unsuccessful?(%{has_connection: false}), do: true
  defp unsuccessful?(_entry), do: false

  defp qualify(entry, static_by_id, max_jumps) do
    path = [entry.origin | entry.systems]
    jumps = length(entry.systems)

    if jumps <= max_jumps and path_qualifies?(path, static_by_id) do
      {:qualifying,
       %{jumps: jumps, path: path, exit_system: find_exit_system(path, static_by_id)}}
    end
  end

  # `Enum.all?/2` short-circuits on the first disqualifying hop, which is also
  # the fail-closed behavior: an unresolvable or wormhole-failing hop stops the
  # check rather than being skipped.
  defp path_qualifies?(path, static_by_id) do
    Enum.all?(path, &system_qualifies?(&1, static_by_id))
  end

  defp system_qualifies?(system_id, static_by_id) do
    case Map.fetch(static_by_id, system_id) do
      :error ->
        false

      {:ok, %{system_class: class}} when class in @wormhole_classes ->
        true

      {:ok, %{security: security}} ->
        case parse_security(security) do
          {:ok, value} -> value >= @highsec_threshold
          {:error, _reason} -> false
        end

      # A static record carrying a non-wormhole class but no `:security` key at
      # all. Fails closed for the same reason a missing record does: this module
      # will not vouch for a system it cannot classify (design: "Failure
      # posture"). Without this clause the `case` raises instead, which would
      # take the whole solve down rather than disqualifying one route.
      {:ok, _static} ->
        false
    end
  end

  defp find_exit_system(path, static_by_id) do
    Enum.find(path, fn system_id ->
      case Map.fetch(static_by_id, system_id) do
        {:ok, %{system_class: class}} -> not SystemClass.wormhole?(class)
        :error -> false
      end
    end)
  end

  defp index_static_data(static_data) do
    static_data
    |> Enum.reject(&is_nil/1)
    |> Map.new(&{&1.solar_system_id, &1})
  end

  # Duplicated from `RouteBuilderClient.parse_security/1` (`route_builder_client.ex:200-210`)
  # rather than reused: that function is private, and this module's threshold
  # deliberately diverges from it (0.45 here vs. 0.5 there — see
  # `highsec_threshold/0`'s moduledoc reference and the design doc's decision
  # 4), so sharing the parser without sharing the threshold would leave the one
  # place that says "0.5" sitting next to the one place that says "0.45" with
  # no visible link between them.
  defp parse_security(security) when is_float(security), do: {:ok, security}
  defp parse_security(security) when is_integer(security), do: {:ok, security * 1.0}

  defp parse_security(security) when is_binary(security) do
    # Only a fully-consumed parse counts. `Float.parse("0.9invalid")` returns
    # {0.9, "invalid"}, so accepting the remainder would read a corrupt static
    # record as highsec — failing OPEN on exactly the value this module exists
    # to be careful about.
    case Float.parse(String.trim(security)) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_security}
    end
  end

  defp parse_security(_security), do: {:error, :invalid_security}
end
