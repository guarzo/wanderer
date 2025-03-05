defmodule WandererApp.Settings do
  @moduledoc """
  Context module for managing user-specific settings.
  """

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
    case MapUserSettings.by_user_id_and_key(map_id, user_id, key) do
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      settings -> {:ok, Jason.decode!(settings.settings || "{}")}
    end
  rescue
    Jason.DecodeError -> {:ok, %{}}
    error ->
      require Logger
      Logger.error("Error in get_user_settings: #{inspect(error)}")
      {:error, :unknown_error}
  end

  @doc """
  Saves user settings for a specific map and key.

  ## Examples

      iex> save_user_settings(user_id, map_id, "routes", %{path_type: "shortest"})
      {:ok, %MapUserSettings{}}
  """
  def save_user_settings(user_id, map_id, key, settings) do
    settings_json = Jason.encode!(settings)

    case MapUserSettings.by_user_id_and_key(map_id, user_id, key) do
      nil ->
        MapUserSettings.create(%{
          user_id: user_id,
          map_id: map_id,
          key: key,
          settings: settings_json
        })

      {:error, _} ->
        # If there was an error finding the settings, try to create a new one
        MapUserSettings.create(%{
          user_id: user_id,
          map_id: map_id,
          key: key,
          settings: settings_json
        })

      existing_settings ->
        MapUserSettings.update_settings(existing_settings, %{settings: settings_json})
    end
  rescue
    error ->
      require Logger
      Logger.error("Error in save_user_settings: #{inspect(error)}")
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
      require Logger
      Logger.error("Error in delete_user_settings: #{inspect(error)}")
      {:error, :unknown_error}
  end
end
