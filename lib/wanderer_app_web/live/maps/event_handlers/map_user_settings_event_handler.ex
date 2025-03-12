defmodule WandererAppWeb.MapUserSettingsEventHandler do
  @moduledoc """
  Event handler for user-specific settings in maps.
  """

  use WandererAppWeb, :live_component
  use Phoenix.Component
  require Logger

  alias WandererAppWeb.MapCoreEventHandler
  alias WandererApp.Settings

  @doc """
  Handles server events related to user settings.
  """
  def handle_server_event(event, socket) do
    MapCoreEventHandler.handle_server_event(event, socket)
  end

  @doc """
  Handles UI events related to user settings.
  """
  def handle_ui_event(
        "save_user_settings",
        %{"key" => key, "settings" => settings} = _params,
        socket
      ) do
    # Handle both cases: when socket has map or map_id
    {current_user, map_id} = case socket.assigns do
      %{current_user: current_user, map: %{id: map_id}} ->
        {current_user, map_id}
      %{current_user: current_user, map_id: map_id} ->
        {current_user, map_id}
    end

    Logger.info("=== SAVE USER SETTINGS START (User: #{current_user.id}) ===")
    Logger.info("Key: #{key}")
    Logger.info("Settings to save: #{inspect(settings)}")

    # Validate settings based on key
    case validate_settings(key, settings) do
      {:ok, validated_settings} ->
        Logger.info("Validated settings: #{inspect(validated_settings)}")

        case Settings.save_user_settings(current_user.id, map_id, key, validated_settings) do
          {:ok, _settings} ->
            Logger.info("Successfully saved user settings for user #{current_user.id}, key: #{key}")
            Logger.info("=== SAVE USER SETTINGS END (User: #{current_user.id}) ===")
            {:noreply, socket}

          {:error, error} ->
            Logger.error("Failed to save settings for user #{current_user.id}: #{inspect(error)}")
            Logger.info("=== SAVE USER SETTINGS END (User: #{current_user.id}) - ERROR ===")
            {:noreply, put_flash(socket, :error, "Failed to save settings. Please try again.")}
        end

      {:error, reason} ->
        Logger.error("Invalid settings for user #{current_user.id}: #{inspect(reason)}")
        Logger.info("=== SAVE USER SETTINGS END (User: #{current_user.id}) - ERROR ===")
        {:noreply, put_flash(socket, :error, "Invalid settings format. Please check your input.")}
    end
  end

  def handle_ui_event(
        "get_user_settings",
        %{"key" => key} = _params,
        socket
      ) do
    # Handle both cases: when socket has map or map_id
    {current_user, map_id} = case socket.assigns do
      %{current_user: current_user, map: %{id: map_id}} ->
        {current_user, map_id}
      %{current_user: current_user, map_id: map_id} ->
        {current_user, map_id}
    end

    Logger.info("=== GET USER SETTINGS START (User: #{current_user.id}) ===")
    Logger.info("Key: #{key}")

    settings =
      case Settings.get_user_settings(current_user.id, map_id, key) do
        {:ok, settings} ->
          Logger.info("Retrieved user settings for user #{current_user.id}, key: #{key}: #{inspect(settings)}")
          settings
        {:error, error} ->
          Logger.info("No settings found for user #{current_user.id}, key: #{key}, error: #{inspect(error)}")
          %{}
      end

    Logger.info("Pushing settings to client: #{inspect(settings)}")
    Logger.info("=== GET USER SETTINGS END (User: #{current_user.id}) ===")

    push_event(socket, "user_settings", %{key: key, settings: settings})
    {:noreply, socket}
  end

  def handle_ui_event(event, params, socket) do
    Logger.warning("Unknown user settings event: #{inspect(event)}, params: #{inspect(params)}")
    {:noreply,
     put_flash(
       socket,
       :error,
       "Unknown user settings event: #{inspect(event)}"
     )}
  end

  # Validate settings based on key
  defp validate_settings("routes", settings) when is_map(settings) do
    # Try to extract values with both string and atom keys
    path_type = Map.get(settings, "path_type", Map.get(settings, :path_type, "shortest"))
    avoid_wormholes = Map.get(settings, "avoid_wormholes", Map.get(settings, :avoid_wormholes, false))
    include_mass_crit = Map.get(settings, "include_mass_crit", Map.get(settings, :include_mass_crit, true))
    include_eol = Map.get(settings, "include_eol", Map.get(settings, :include_eol, true))
    include_frig = Map.get(settings, "include_frig", Map.get(settings, :include_frig, true))
    include_cruise = Map.get(settings, "include_cruise", Map.get(settings, :include_cruise, true))
    avoid_pochven = Map.get(settings, "avoid_pochven", Map.get(settings, :avoid_pochven, false))
    avoid_edencom = Map.get(settings, "avoid_edencom", Map.get(settings, :avoid_edencom, false))
    avoid_triglavian = Map.get(settings, "avoid_triglavian", Map.get(settings, :avoid_triglavian, false))
    include_thera = Map.get(settings, "include_thera", Map.get(settings, :include_thera, true))
    avoid = Map.get(settings, "avoid", Map.get(settings, :avoid, []))
    hubs = Map.get(settings, "hubs", Map.get(settings, :hubs, []))

    # Remove any timestamp or other non-route settings
    # This ensures we only store the actual route settings
    clean_settings = %{
      "path_type" => path_type,
      "avoid_wormholes" => to_boolean(avoid_wormholes),
      "include_mass_crit" => to_boolean(include_mass_crit),
      "include_eol" => to_boolean(include_eol),
      "include_frig" => to_boolean(include_frig),
      "include_cruise" => to_boolean(include_cruise),
      "avoid_pochven" => to_boolean(avoid_pochven),
      "avoid_edencom" => to_boolean(avoid_edencom),
      "avoid_triglavian" => to_boolean(avoid_triglavian),
      "include_thera" => to_boolean(include_thera),
      "avoid" => ensure_list(avoid),
      "hubs" => ensure_list(hubs)
    }

    # Validate path_type
    if path_type not in ["shortest", "secure", "insecure"] do
      {:error, "Invalid path_type: #{path_type}. Must be one of: shortest, secure, insecure"}
    else
      # Return validated settings with string keys for consistency
      {:ok, clean_settings}
    end
  end

  # For other keys, just pass through the settings for now
  defp validate_settings(_key, settings) when is_map(settings) do
    {:ok, settings}
  end

  defp validate_settings(_key, _settings) do
    {:error, "Settings must be a map"}
  end

  # Helper to ensure value is a boolean
  defp to_boolean(value) when is_boolean(value), do: value
  defp to_boolean("true"), do: true
  defp to_boolean("false"), do: false
  defp to_boolean(1), do: true
  defp to_boolean(0), do: false
  defp to_boolean(_), do: false

  # Helper to ensure value is a list
  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(_), do: []
end
