defmodule WandererAppWeb.MapRoutesEventHandler do
  use WandererAppWeb, :live_component
  use Phoenix.Component
  require Logger

  alias WandererAppWeb.{MapEventHandler, MapCoreEventHandler}

  def handle_server_event(
        %{
          event: :routes,
          payload: {solar_system_id, %{routes: routes, systems_static_data: systems_static_data}, user_id}
        },
        %{assigns: %{current_user: %{id: current_user_id}}} = socket
      ) when current_user_id == user_id do
    # Only push the event to the user who requested it
    socket
    |> MapEventHandler.push_map_event(
      "routes",
      %{
        solar_system_id: solar_system_id,
        loading: false,
        routes: routes,
        systems_static_data: systems_static_data
      }
    )
  end

  # Ignore routes events for other users
  def handle_server_event(
        %{
          event: :routes,
          payload: {_solar_system_id, _routes_data, _user_id}
        },
        socket
      ) do
    socket
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

      # For wormhole systems (IDs starting with "31"), always set avoid_wormholes to false
      is_wormhole = String.starts_with?(solar_system_id, "31")

      # Merge settings with proper handling for wormhole systems
      merged_settings = merge_route_settings(user_settings, parsed_settings, is_wormhole)

      # Use debug level for detailed operational logs
      Logger.debug("Final merged settings for routes: #{inspect(merged_settings)}")

      {:ok, routes} =
        WandererApp.Maps.find_routes(
          map_id,
          hubs,
          solar_system_id,
          merged_settings
        )

      # Include the user_id in the payload to ensure the event is only processed by the requesting user
      {:routes, {solar_system_id, routes, current_user.id}}
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

  # Extract merging logic to a separate function for better readability
  defp merge_route_settings(user_settings, provided_settings, is_wormhole) do
    # Use debug level for detailed operational logs instead of info
    Logger.debug("User settings: #{inspect(user_settings)}")
    Logger.debug("Provided settings: #{inspect(provided_settings)}")
    Logger.debug("Is wormhole system: #{inspect(is_wormhole)}")

    # Merge settings: user_settings first, then override with provided_settings
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
