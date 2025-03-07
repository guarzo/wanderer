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
    %{assigns: %{current_user: current_user, map: map}} = socket

    # Validate settings based on key
    case validate_settings(key, settings) do
      {:ok, validated_settings} ->
        case Settings.save_user_settings(current_user.id, map.id, key, validated_settings) do
          {:ok, _settings} ->
            Logger.debug("Successfully saved user settings for key: #{key}")
            {:noreply, socket}

          {:error, error} ->
            Logger.error("Failed to save settings: #{inspect(error)}")
            {:noreply, put_flash(socket, :error, "Failed to save settings. Please try again.")}
        end

      {:error, reason} ->
        Logger.error("Invalid settings: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Invalid settings format. Please check your input.")}
    end
  end

  def handle_ui_event(
        "get_user_settings",
        %{"key" => key} = _params,
        socket
      ) do
    %{assigns: %{current_user: current_user, map: map}} = socket

    settings =
      case Settings.get_user_settings(current_user.id, map.id, key) do
        {:ok, settings} ->
          Logger.debug("Retrieved user settings for key: #{key}")
          settings
        {:error, error} ->
          Logger.debug("No settings found for key: #{key}, error: #{inspect(error)}")
          %{}
      end

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
    # Validate required fields for routes settings
    with {:ok, path_type} <- validate_path_type(settings),
         {:ok, avoid_wormholes} <- validate_boolean(settings, "avoid_wormholes"),
         {:ok, include_mass_crit} <- validate_boolean(settings, "include_mass_crit"),
         {:ok, include_eol} <- validate_boolean(settings, "include_eol"),
         {:ok, include_frig} <- validate_boolean(settings, "include_frig"),
         {:ok, include_cruise} <- validate_boolean(settings, "include_cruise"),
         {:ok, avoid_pochven} <- validate_boolean(settings, "avoid_pochven"),
         {:ok, avoid_edencom} <- validate_boolean(settings, "avoid_edencom"),
         {:ok, avoid_triglavian} <- validate_boolean(settings, "avoid_triglavian"),
         {:ok, include_thera} <- validate_boolean(settings, "include_thera"),
         {:ok, avoid} <- validate_avoid_list(settings) do
      # Return validated settings
      {:ok, %{
        "path_type" => path_type,
        "avoid_wormholes" => avoid_wormholes,
        "include_mass_crit" => include_mass_crit,
        "include_eol" => include_eol,
        "include_frig" => include_frig,
        "include_cruise" => include_cruise,
        "avoid_pochven" => avoid_pochven,
        "avoid_edencom" => avoid_edencom,
        "avoid_triglavian" => avoid_triglavian,
        "include_thera" => include_thera,
        "avoid" => avoid
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # For other keys, just pass through the settings for now
  defp validate_settings(_key, settings) when is_map(settings) do
    {:ok, settings}
  end

  defp validate_settings(_key, _settings) do
    {:error, "Settings must be a map"}
  end

  # Validate path_type
  defp validate_path_type(%{"path_type" => path_type}) when path_type in ["shortest", "secure", "insecure"] do
    {:ok, path_type}
  end

  defp validate_path_type(%{"path_type" => path_type}) do
    {:error, "Invalid path_type: #{path_type}. Must be one of: shortest, secure, insecure"}
  end

  defp validate_path_type(_) do
    {:ok, "shortest"} # Default value
  end

  # Validate boolean fields
  defp validate_boolean(%{} = settings, key) do
    case Map.get(settings, key) do
      nil -> {:ok, false} # Default value
      true -> {:ok, true}
      false -> {:ok, false}
      value when is_binary(value) ->
        case String.downcase(value) do
          "true" -> {:ok, true}
          "false" -> {:ok, false}
          _ -> {:error, "Invalid boolean value for #{key}: #{value}"}
        end
      value -> {:error, "Invalid boolean value for #{key}: #{inspect(value)}"}
    end
  end

  # Validate avoid list
  defp validate_avoid_list(%{"avoid" => avoid}) when is_list(avoid) do
    # Ensure all items in the list are strings or integers
    valid_avoid = Enum.all?(avoid, fn item ->
      is_binary(item) or is_integer(item)
    end)

    if valid_avoid do
      # Convert all items to strings for consistency
      {:ok, Enum.map(avoid, &to_string/1)}
    else
      {:error, "Invalid avoid list: all items must be strings or integers"}
    end
  end

  defp validate_avoid_list(_) do
    {:ok, []} # Default value
  end
end
