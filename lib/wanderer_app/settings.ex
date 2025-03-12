defmodule WandererApp.Settings do
  @moduledoc """
  Context module for managing user-specific settings.
  """

  require Logger
  alias WandererApp.Api.MapUserSettings

  @doc """
  Gets user settings for a specific map and key.

  ## Examples

      iex> get_user_settings(user_id, map_id, "routes")
      {:ok, %{...}}

      iex> get_user_settings(user_id, map_id, "nonexistent_key")
      {:error, :not_found}
  """
  def get_user_settings(user_id, map_id, key) do
    Logger.info("=== GET USER SETTINGS DB START ===")
    Logger.info("Getting user settings for user #{user_id}, map #{map_id}, key #{key}")

    case MapUserSettings.by_user_id_and_key(map_id, user_id, key) do
      nil ->
        Logger.info("No settings found for user #{user_id}, map #{map_id}, key #{key}")
        Logger.info("=== GET USER SETTINGS DB END - NOT FOUND ===")
        {:error, :not_found}
      {:error, _} = error ->
        Logger.info("Error getting settings for user #{user_id}, map #{map_id}, key #{key}: #{inspect(error)}")
        Logger.info("=== GET USER SETTINGS DB END - ERROR ===")
        error
      settings ->
        decoded_settings = Jason.decode!(settings.settings || "{}")
        Logger.info("Found settings for user #{user_id}, map #{map_id}, key #{key}: #{inspect(decoded_settings)}")
        Logger.info("=== GET USER SETTINGS DB END - SUCCESS ===")
        {:ok, decoded_settings}
    end
  rescue
    Jason.DecodeError ->
      Logger.info("JSON decode error for user #{user_id}, map #{map_id}, key #{key}")
      Logger.info("=== GET USER SETTINGS DB END - JSON ERROR ===")
      {:ok, %{}}
    error ->
      Logger.error("Error in get_user_settings: #{inspect(error)}")
      Logger.info("=== GET USER SETTINGS DB END - UNKNOWN ERROR ===")
      {:error, :unknown_error}
  end

  @doc """
  Saves user settings for a specific map and key.

  ## Examples

      iex> save_user_settings(user_id, map_id, "routes", %{path_type: "shortest"})
      {:ok, %MapUserSettings{}}
  """
  def save_user_settings(user_id, map_id, key, settings) do
    Logger.info("=== SAVE USER SETTINGS DB START ===")
    Logger.info("Saving user settings for user #{user_id}, map #{map_id}, key #{key}: #{inspect(settings)}")

    settings_json = Jason.encode!(settings)

    result = case MapUserSettings.by_user_id_and_key(map_id, user_id, key) do
      nil ->
        Logger.info("Creating new settings for user #{user_id}, map #{map_id}, key #{key}")
        MapUserSettings.create(%{
          user_id: user_id,
          map_id: map_id,
          key: key,
          settings: settings_json
        })

      {:error, _} ->
        # If there was an error finding the settings, try to create a new one
        Logger.info("Error finding settings, creating new for user #{user_id}, map #{map_id}, key #{key}")
        MapUserSettings.create(%{
          user_id: user_id,
          map_id: map_id,
          key: key,
          settings: settings_json
        })

      existing_settings ->
        Logger.info("Updating existing settings for user #{user_id}, map #{map_id}, key #{key}")
        MapUserSettings.update_settings(existing_settings, %{settings: settings_json})
    end

    case result do
      {:ok, _} = success ->
        Logger.info("Successfully saved settings for user #{user_id}, map #{map_id}, key #{key}")
        Logger.info("=== SAVE USER SETTINGS DB END - SUCCESS ===")
        success
      error ->
        Logger.error("Failed to save settings for user #{user_id}, map #{map_id}, key #{key}: #{inspect(error)}")
        Logger.info("=== SAVE USER SETTINGS DB END - ERROR ===")
        error
    end
  rescue
    error ->
      Logger.error("Error in save_user_settings: #{inspect(error)}")
      Logger.info("=== SAVE USER SETTINGS DB END - UNKNOWN ERROR ===")
      {:error, :unknown_error}
  end

  @doc """
  Deletes user settings for a specific map and key.

  ## Examples

      iex> delete_user_settings(user_id, map_id, "routes")
      {:ok, %MapUserSettings{}}
  """
  def delete_user_settings(user_id, map_id, key) do
    case MapUserSettings.by_user_id_and_key(map_id, user_id, key) do
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      settings -> MapUserSettings.destroy(settings)
    end
  rescue
    error ->
      Logger.error("Error in delete_user_settings: #{inspect(error)}")
      {:error, :unknown_error}
  end
end
