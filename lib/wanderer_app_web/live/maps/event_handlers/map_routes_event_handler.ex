defmodule WandererAppWeb.MapRoutesEventHandler do
  @moduledoc false

  use WandererAppWeb, :live_component
  use Phoenix.Component
  require Logger

  alias WandererAppWeb.{MapEventHandler, MapCoreEventHandler}

  def handle_server_event(
        %{
          event: :routes,
          payload: {solar_system_id, routes_data}
        },
        socket
      ) do
    # Push the event to all users - each client will filter based on their requested system
    socket
    |> MapEventHandler.push_map_event(
      "routes",
      %{
        solar_system_id: solar_system_id,
        loading: false,
        routes: routes_data.routes,
        systems_static_data: routes_data.systems_static_data
      }
    )
  end

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

  def handle_ui_event(
        "get_routes",
        %{"system_id" => solar_system_id, "routes_settings" => routes_settings} = _params,
        %{assigns: %{map_id: map_id, map_loaded?: true, current_user: current_user}} = socket
      ) do
    Task.async(fn ->
      {:ok, hubs} = map_id |> WandererApp.Map.list_hubs()

      # Load user-specific settings if available
      user_settings =
        case WandererApp.Settings.get_user_settings(current_user.id, map_id, "routes") do
          {:ok, settings} -> settings
          {:error, _} -> %{}
        end

      # Parse the provided settings
      parsed_settings = get_routes_settings(routes_settings)

      # Merge settings: user_settings as base, override with parsed_settings
      merged_settings = Map.merge(user_settings, parsed_settings)

      # Special handling for wormhole systems
      is_wormhole = String.starts_with?(solar_system_id, "31")
      final_settings = if is_wormhole, do: Map.put(merged_settings, :avoid_wormholes, false), else: merged_settings

      Logger.debug("Final settings for routes: #{inspect(final_settings)}")

      {:ok, routes} =
        WandererApp.Maps.find_routes(
          map_id,
          hubs,
          solar_system_id,
          final_settings
        )

      # Return the routes without user ID - client will filter by requested system
      {:routes, {solar_system_id, routes}}
    end)

    {:noreply, socket}
  end

  def handle_ui_event(
        "add_hub",
        %{"system_id" => system_id} = _event,
        %{assigns: %{map_id: map_id, map_loaded?: true}} = socket
      ) do
    Task.async(fn ->
      {:ok, _} = WandererApp.Map.add_hub(map_id, system_id)
      {:hubs, {map_id, system_id}}
    end)

    {:noreply, socket}
  end

  def handle_ui_event(
        "remove_hub",
        %{"system_id" => system_id} = _event,
        %{assigns: %{map_id: map_id, map_loaded?: true}} = socket
      ) do
    Task.async(fn ->
      {:ok, _} = WandererApp.Map.remove_hub(map_id, system_id)
      {:hubs, {map_id, system_id}}
    end)

    {:noreply, socket}
  end

  def handle_ui_event(event, params, socket),
    do: MapCoreEventHandler.handle_ui_event(event, params, socket)

  # Simplified merging logic for better readability
  defp merge_route_settings(user_settings, provided_settings, is_wormhole) do
    # Merge settings: user_settings as base, override with provided_settings
    merged_settings = Map.merge(user_settings, provided_settings)

    # Ensure avoid_wormholes is false for wormhole systems
    if is_wormhole do
      Map.put(merged_settings, :avoid_wormholes, false)
    else
      merged_settings
    end
  end

  defp get_routes_settings(
         %{
           "path_type" => path_type,
           "include_mass_crit" => include_mass_crit,
           "include_eol" => include_eol,
           "include_frig" => include_frig,
           "include_cruise" => include_cruise,
           "avoid_wormholes" => avoid_wormholes,
           "avoid_pochven" => avoid_pochven,
           "avoid_edencom" => avoid_edencom,
           "avoid_triglavian" => avoid_triglavian,
           "include_thera" => include_thera,
           "avoid" => avoid
         }) do
    # Use debug level for detailed operational logs
    Logger.debug("Processing route settings: #{inspect(%{
      path_type: path_type,
      avoid_wormholes: avoid_wormholes
    })}")

    %{
      path_type: path_type,
      include_mass_crit: include_mass_crit,
      include_eol: include_eol,
      include_frig: include_frig,
      include_cruise: include_cruise,
      avoid_wormholes: avoid_wormholes,
      avoid_pochven: avoid_pochven,
      avoid_edencom: avoid_edencom,
      avoid_triglavian: avoid_triglavian,
      include_thera: include_thera,
      avoid: avoid
    }
  end

  defp get_routes_settings(_), do: %{}

  defp set_autopilot_waypoint(
         current_user,
         character_eve_id,
         add_to_beginning,
         clear_other_waypoints,
         destination_id
       ) do
    case current_user.characters
         |> Enum.find(fn c -> c.eve_id == character_eve_id end) do
      nil ->
        :skip

      %{id: character_id} = _character ->
        character_id
        |> WandererApp.Character.set_autopilot_waypoint(destination_id,
          add_to_beginning: add_to_beginning,
          clear_other_waypoints: clear_other_waypoints
        )

        :skip
    end
  end
end
