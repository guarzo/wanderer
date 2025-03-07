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

  def handle_server_event(
        %{
          event: :hubs_updated,
          payload: {map_id, system_id}
        },
        %{assigns: %{current_user: current_user}} = socket
      ) do
    Logger.info("=== HUBS UPDATED EVENT (User: #{current_user.id}) ===")
    Logger.info("Map ID: #{map_id}, System ID: #{system_id}")
    Logger.info("Socket assigns: #{inspect(Map.take(socket.assigns, [:map_id, :current_user]))}")

    # Get user settings to retrieve the updated hubs
    case WandererApp.Settings.get_user_settings(current_user.id, map_id, "routes") do
      {:ok, settings} ->
        user_hubs = Map.get(settings, "hubs", [])
        Logger.info("User hubs after update: #{inspect(user_hubs)}")

        # Push the updated hubs to the client using the map_updated event
        # Make sure we're sending the hubs in the format expected by the frontend
        Logger.info("Pushing map_updated event with hubs: #{inspect(user_hubs)}")
        socket
        |> MapEventHandler.push_map_event(
          "map_updated",
          %{
            hubs: user_hubs
          }
        )

      {:error, error} ->
        Logger.error("Failed to get user hubs: #{inspect(error)}")
        socket
    end
  end

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

  def handle_ui_event(
        "get_routes",
        %{"system_id" => solar_system_id, "routes_settings" => routes_settings} = _params,
        %{assigns: %{map_id: map_id, map_loaded?: true, current_user: current_user}} = socket
      ) do
    # Add explicit log at the start
    Logger.info("=== ROUTES REQUEST START (User: #{current_user.id}) ===")
    Logger.info("System ID: #{solar_system_id}")
    Logger.info("Incoming routes_settings: #{inspect(routes_settings)}")

    Task.async(fn ->
      # Get map-level hubs for logging only
      {:ok, map_hubs} = map_id |> WandererApp.Map.list_hubs()
      Logger.info("Map hubs: #{inspect(map_hubs)}")

      # Load user-specific settings if available
      user_settings =
        case WandererApp.Settings.get_user_settings(current_user.id, map_id, "routes") do
          {:ok, settings} ->
            Logger.info("Found user settings for user #{current_user.id}: #{inspect(settings)}")
            # Convert string keys to atoms for consistency
            settings
            |> Enum.map(fn {k, v} ->
              # Try to convert the key to an atom
              atom_key = try do
                String.to_existing_atom(k)
              rescue
                _ -> String.to_atom(k)
              end
              {atom_key, v}
            end)
            |> Enum.into(%{})
          {:error, _} ->
            Logger.info("No user settings found for user #{current_user.id}")
            %{}
        end

      # Get user-specific hubs from settings, or use an empty list
      # This ensures each user starts with their own empty set of hubs
      user_hubs = Map.get(user_settings, :hubs, [])
      Logger.info("User hubs: #{inspect(user_hubs)}")

      # Parse the provided settings from the request
      parsed_settings = get_routes_settings(routes_settings)

      Logger.info("User settings before merge: #{inspect(user_settings)}")
      Logger.info("Parsed settings from request: #{inspect(parsed_settings)}")

      # Merge settings: user_settings as base, override with parsed_settings
      # This ensures user preferences are maintained but can be temporarily overridden
      # by the current request
      merged_settings = Map.merge(user_settings, parsed_settings)

      Logger.info("Merged settings: #{inspect(merged_settings)}")

      # Special handling for wormhole systems
      is_wormhole = String.starts_with?(solar_system_id, "31")
      final_settings =
        if is_wormhole do
          Map.put(merged_settings, :avoid_wormholes, false)
        else
          merged_settings
        end

      Logger.info("Final settings for routes (user: #{current_user.id}): #{inspect(final_settings)}")

      {:ok, routes} =
        WandererApp.Maps.find_routes(
          map_id,
          user_hubs,  # Use user-specific hubs here
          solar_system_id,
          final_settings
        )

      Logger.info("=== ROUTES REQUEST END (User: #{current_user.id}) ===")

      # Return the routes without user ID - client will filter by requested system
      {:routes, {solar_system_id, routes}}
    end)

    {:noreply, socket}
  end

  # Handle save_user_settings events that come through the OutCommand.getRoutes channel
  def handle_ui_event(
        "get_routes",
        %{"type" => "save_user_settings", "data" => %{"key" => key, "settings" => settings}} = _params,
        %{assigns: %{map_id: map_id, map_loaded?: true, current_user: current_user}} = socket
      ) do
    # Forward to the MapUserSettingsEventHandler
    WandererAppWeb.MapUserSettingsEventHandler.handle_ui_event(
      "save_user_settings",
      %{"key" => key, "settings" => settings},
      socket
    )
  end

  # Handle get_user_settings events that come through the OutCommand.getRoutes channel
  def handle_ui_event(
        "get_routes",
        %{"type" => "get_user_settings", "data" => %{"key" => key}} = _params,
        %{assigns: %{map_id: map_id, map_loaded?: true, current_user: current_user}} = socket
      ) do
    # Forward to the MapUserSettingsEventHandler
    WandererAppWeb.MapUserSettingsEventHandler.handle_ui_event(
      "get_user_settings",
      %{"key" => key},
      socket
    )
  end

  def handle_ui_event(
        "add_hub",
        %{"system_id" => system_id} = _event,
        %{assigns: %{map_id: map_id, map_loaded?: true, current_user: current_user}} = socket
      ) do
    Logger.info("=== ADD HUB START (User: #{current_user.id}) ===")
    Logger.info("Adding hub: #{system_id}")
    Logger.info("Event params: #{inspect(_event)}")
    Logger.info("Socket assigns: #{inspect(Map.take(socket.assigns, [:map_id, :current_user]))}")

    Task.async(fn ->
      # Get current user settings
      user_settings =
        case WandererApp.Settings.get_user_settings(current_user.id, map_id, "routes") do
          {:ok, settings} ->
            Logger.info("Found existing user settings: #{inspect(settings)}")
            settings
          {:error, error} ->
            Logger.info("No existing user settings found: #{inspect(error)}")
            %{}
        end

      # Get current user hubs or initialize empty list
      current_hubs = Map.get(user_settings, "hubs", [])
      Logger.info("Current user hubs: #{inspect(current_hubs)}")

      # Add the new hub if it's not already in the list
      updated_hubs =
        if system_id in current_hubs do
          Logger.info("Hub #{system_id} already exists in user hubs")
          current_hubs
        else
          Logger.info("Adding hub #{system_id} to user hubs")
          [system_id | current_hubs]
        end

      # Update user settings with new hubs
      updated_settings = Map.put(user_settings, "hubs", updated_hubs)
      Logger.info("Updated user hubs: #{inspect(updated_hubs)}")
      Logger.info("Updated user settings: #{inspect(updated_settings)}")

      # Save updated settings
      case WandererApp.Settings.save_user_settings(current_user.id, map_id, "routes", updated_settings) do
        {:ok, _} ->
          Logger.info("Successfully saved updated hubs for user #{current_user.id}")

          # Broadcast the updated hubs to all clients
          Logger.info("Broadcasting hubs_updated event to map:#{map_id}")
          Phoenix.PubSub.broadcast(
            WandererApp.PubSub,
            "map:#{map_id}",
            %{event: :hubs_updated, payload: {map_id, system_id}}
          )

          {:hubs, {map_id, system_id}}
        {:error, error} ->
          Logger.error("Failed to save updated hubs: #{inspect(error)}")
          {:error, "Failed to save hub"}
      end
    end)

    {:noreply, socket}
  end

  def handle_ui_event(
        "remove_hub",
        %{"system_id" => system_id} = _event,
        %{assigns: %{map_id: map_id, map_loaded?: true, current_user: current_user}} = socket
      ) do
    Logger.info("=== REMOVE HUB START (User: #{current_user.id}) ===")
    Logger.info("Removing hub: #{system_id}")

    Task.async(fn ->
      # Get current user settings
      user_settings =
        case WandererApp.Settings.get_user_settings(current_user.id, map_id, "routes") do
          {:ok, settings} ->
            Logger.info("Found existing user settings: #{inspect(settings)}")
            settings
          {:error, error} ->
            Logger.info("No existing user settings found: #{inspect(error)}")
            %{}
        end

      # Get current user hubs or initialize empty list
      current_hubs = Map.get(user_settings, "hubs", [])
      Logger.info("Current user hubs: #{inspect(current_hubs)}")

      # Remove the hub from the list
      updated_hubs = Enum.reject(current_hubs, fn hub -> hub == system_id end)
      Logger.info("Hub #{system_id} removed from user hubs")

      # Update user settings with new hubs
      updated_settings = Map.put(user_settings, "hubs", updated_hubs)
      Logger.info("Updated user hubs: #{inspect(updated_hubs)}")
      Logger.info("Updated user settings: #{inspect(updated_settings)}")

      # Save updated settings
      case WandererApp.Settings.save_user_settings(current_user.id, map_id, "routes", updated_settings) do
        {:ok, _} ->
          Logger.info("Successfully saved updated hubs for user #{current_user.id}")

          # Broadcast the updated hubs to all clients
          Phoenix.PubSub.broadcast(
            WandererApp.PubSub,
            "map:#{map_id}",
            %{event: :hubs_updated, payload: {map_id, system_id}}
          )

          {:hubs, {map_id, system_id}}
        {:error, error} ->
          Logger.error("Failed to save updated hubs: #{inspect(error)}")
          {:error, "Failed to remove hub"}
      end
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

    # Convert to atom keys for the backend
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

  # Handle case where keys might be atoms instead of strings
  defp get_routes_settings(%{
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
       }) do
    # Convert to atom keys for the backend
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

  # Handle partial settings
  defp get_routes_settings(settings) when is_map(settings) do
    # Extract known keys with defaults
    path_type = Map.get(settings, "path_type", "shortest")
    include_mass_crit = Map.get(settings, "include_mass_crit", true)
    include_eol = Map.get(settings, "include_eol", true)
    include_frig = Map.get(settings, "include_frig", true)
    include_cruise = Map.get(settings, "include_cruise", true)
    avoid_wormholes = Map.get(settings, "avoid_wormholes", false)
    avoid_pochven = Map.get(settings, "avoid_pochven", false)
    avoid_edencom = Map.get(settings, "avoid_edencom", false)
    avoid_triglavian = Map.get(settings, "avoid_triglavian", false)
    include_thera = Map.get(settings, "include_thera", true)
    avoid = Map.get(settings, "avoid", [])

    # Also try atom keys
    path_type = Map.get(settings, :path_type, path_type)
    include_mass_crit = Map.get(settings, :include_mass_crit, include_mass_crit)
    include_eol = Map.get(settings, :include_eol, include_eol)
    include_frig = Map.get(settings, :include_frig, include_frig)
    include_cruise = Map.get(settings, :include_cruise, include_cruise)
    avoid_wormholes = Map.get(settings, :avoid_wormholes, avoid_wormholes)
    avoid_pochven = Map.get(settings, :avoid_pochven, avoid_pochven)
    avoid_edencom = Map.get(settings, :avoid_edencom, avoid_edencom)
    avoid_triglavian = Map.get(settings, :avoid_triglavian, avoid_triglavian)
    include_thera = Map.get(settings, :include_thera, include_thera)
    avoid = Map.get(settings, :avoid, avoid)

    # Return with atom keys
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
