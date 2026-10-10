defmodule WandererApp.Map.TradeHubTags do
  @moduledoc """
  Auto-tags highsec systems with their gate-jump distance to the nearest major
  trade hub, as `<jumps><letter>` (e.g. `"5-J"`), per
  github.com/elboaf/wanderer#3.

  Rules:
  - Only highsec systems are tagged (threshold shared with the route-alert
    evaluator's deliberately-cautious 0.45 — see
    `WandererApp.Map.RouteAlert.Evaluator.highsec_threshold/0`).
  - Closest hub wins; ties break Jita > Dodixie > Amarr > Hek > Rens.
  - More than `@max_jumps` (10) from every hub, or any solver failure, leaves
    the tag untouched. So does an existing (e.g. manually-set) tag: we only
    populate, never overwrite.
  """

  require Logger

  # In tie-break preference order (issue #3 rule 3). IDs match
  # priv/repo/data/route_by_systems/trade_hubs.json.
  @trade_hubs [
    {30_000_142, "J"},
    {30_002_659, "D"},
    {30_002_187, "A"},
    {30_002_053, "H"},
    {30_002_510, "R"}
  ]

  @max_jumps 10

  def trade_hubs, do: @trade_hubs
  def max_jumps, do: @max_jumps

  @doc """
  Computes and writes the tag for `solar_system_id` on `map_id`. Fire-and-forget:
  every failure mode is logged and swallowed, and the tag is written only when
  the system is highsec, within `max_jumps` of some hub, and its tag is empty.
  """
  def maybe_tag_system(map_id, solar_system_id) do
    with {:ok, %{security: security}} <- system_info(solar_system_id),
         {:ok, security_value} <- parse_security(security),
         true <- security_value >= WandererApp.Map.RouteAlert.Evaluator.highsec_threshold(),
         {:ok, %{routes: routes}} <-
           WandererApp.Map.Routes.find(
             map_id,
             Enum.map(@trade_hubs, fn {id, _letter} -> Integer.to_string(id) end),
             Integer.to_string(solar_system_id),
             %{},
             false
           ),
         {:ok, tag} <- pick_tag(routes) do      WandererApp.Map.Server.update_system_tag(map_id, %{
        solar_system_id: solar_system_id,
        tag: tag
      })

      :ok
    else
      false ->
        :ok

      :skip ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[TradeHubTags] Skipping tag for system #{solar_system_id} on map #{map_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Pure tag selection over normalized `Routes.find/5` route maps
  (`%{destination, systems, success}` — `systems` excludes the origin).

  Returns `{:ok, "<jumps><letter>"}` for the closest successful hub, `:skip`
  when nothing qualifies (no successful route, or every distance above
  `max_jumps`). Ties among equal jump counts follow the `@trade_hubs` order.
  """
  @spec pick_tag([map()]) :: {:ok, String.t()} | :skip
  def pick_tag(routes) do
    successful =
      Enum.filter(routes, fn
        %{success: true, systems: systems, destination: destination} when is_list(systems) ->
          Enum.any?(@trade_hubs, fn {id, _letter} -> id == destination end)

        _ ->
          false
      end)

    case successful do
      [] ->
        :skip

      _ ->
        hub_index = Map.new(Enum.with_index(@trade_hubs))

        %{destination: destination, systems: systems} =
          Enum.min_by(successful, fn %{destination: destination, systems: systems} ->
            {length(systems), Map.get(hub_index, destination, 999)}
          end)

        jumps = length(systems)

        if jumps <= @max_jumps do
          {:ok, "#{jumps}-#{hub_letter(destination)}"}
        else
          :skip
        end
    end
  end

  defp hub_letter(destination) do
    {_, letter} = Enum.find(@trade_hubs, fn {id, _} -> id == destination end)
    letter
  end

  defp system_info(solar_system_id) do
    case WandererApp.CachedInfo.get_system_static_info(solar_system_id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, info} -> {:ok, info}
      error -> error
    end
  end

  # Same strict parse as `RouteAlert.Evaluator.parse_security/1` — only a fully
  # consumed parse counts, so a corrupt record can't read as highsec.
  defp parse_security(security) when is_float(security), do: {:ok, security}
  defp parse_security(security) when is_integer(security), do: {:ok, security * 1.0}

  defp parse_security(security) when is_binary(security) do
    case Float.parse(String.trim(security)) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_security}
    end
  end

  defp parse_security(_security), do: {:error, :invalid_security}
end
