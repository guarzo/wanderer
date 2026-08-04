defmodule WandererApp.MapUserSettingsRepo do
  use WandererApp, :repository

  require Logger

  @default_form_data %{
    "select_on_spash" => false,
    "link_signature_on_splash" => false,
    "delete_connection_with_sigs" => false,
    "primary_character_id" => nil,
    "bookmark_name_format" => "",
    "bookmark_custom_mapping" => %{},
    "system_auto_tag" => "",
    "system_custom_label_name" => "",
    "bookmark_return_hole_ignore" => false,
    "bookmark_return_hole_symbol" => ""
  }

  def get(map_id, user_id) do
    map_id
    |> WandererApp.Api.MapUserSettings.by_user_id(user_id)
    |> case do
      {:ok, settings} ->
        {:ok, settings}

      _ ->
        {:ok, nil}
    end
  end

  def get!(map_id, user_id) do
    WandererApp.Api.MapUserSettings.by_user_id(map_id, user_id)
    |> case do
      {:ok, user_settings} -> user_settings
      _ -> nil
    end
  end

  def create_or_update(map_id, user_id, nil) do
    create_or_update(map_id, user_id, @default_form_data |> Jason.encode!())
  end

  def create_or_update(map_id, user_id, settings) do
    get!(map_id, user_id)
    |> case do
      user_settings when not is_nil(user_settings) ->
        user_settings
        |> WandererApp.Api.MapUserSettings.update_settings(%{settings: settings})

      _ ->
        WandererApp.Api.MapUserSettings.create(%{
          map_id: map_id,
          user_id: user_id,
          settings: settings
        })
    end
  end

  def get_hubs(map_id, user_id) do
    case WandererApp.MapUserSettingsRepo.get(map_id, user_id) do
      {:ok, user_settings} when not is_nil(user_settings) ->
        {:ok, Map.get(user_settings, :hubs, [])}

      _ ->
        {:ok, []}
    end
  end

  def update_hubs(map_id, user_id, hubs) do
    get!(map_id, user_id)
    |> case do
      user_settings when not is_nil(user_settings) ->
        user_settings
        |> WandererApp.Api.MapUserSettings.update_hubs(%{hubs: hubs})

      _ ->
        WandererApp.Api.MapUserSettings.create!(%{
          map_id: map_id,
          user_id: user_id,
          settings: @default_form_data |> Jason.encode!()
        })
        |> WandererApp.Api.MapUserSettings.update_hubs(%{hubs: hubs})
    end
  end

  def to_form_data(nil), do: {:ok, @default_form_data}
  def to_form_data(%{settings: settings} = _user_settings), do: {:ok, Jason.decode!(settings)}

  def to_form_data!(user_settings) do
    {:ok, data} = to_form_data(user_settings)
    data
  end

  def get_boolean_setting(settings, key, default \\ false) do
    settings
    |> Map.get(key, default)
    |> to_boolean()
  end

  def to_boolean(value) when is_binary(value), do: value |> String.to_existing_atom()
  def to_boolean(value) when is_boolean(value), do: value

  @doc """
  Gets all map user settings for a given map_id.
  Returns {:ok, [settings]} or {:error, reason}
  """
  def get_by_map(map_id) when is_binary(map_id) and map_id != "" do
    try do
      # `read_by_map!/1` returns a list or raises; the former `nil` and
      # unexpected-result branches were unreachable.
      {:ok, WandererApp.Api.MapUserSettings.read_by_map!(%{map_id: map_id})}
    rescue
      error ->
        Logger.error("Database error in get_by_map: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  The de-duplicated set of `ready_characters` eve ids across every user of a map.

  Cached, because this is read on the hot path. Every `characters_updated`
  broadcast is enriched with a `:ready` flag by each connected LiveView
  independently (`MapCharactersEventHandler.map_ui_characters_with_ready/2`),
  so on a map with N viewers one broadcast used to mean N identical
  `map_user_settings_v1` reads returning the same rows.

  Invalidated by `Api.MapUserSettings`'s `:update_ready_characters` action
  rather than by its callers, so a new write path cannot forget to.
  The TTL is a backstop for anything that ever writes the column outside that
  action, not the primary freshness mechanism.
  """
  @ready_ids_ttl :timer.minutes(5)

  def ready_character_eve_ids(map_id) when is_binary(map_id) and map_id != "" do
    case WandererApp.Cache.lookup!(ready_ids_cache_key(map_id)) do
      nil ->
        # A failed read yields `[]` for this call but is deliberately not
        # cached: caching it would pin every viewer's ready flags off for the
        # full TTL because of one transient database error.
        case load_ready_character_eve_ids(map_id) do
          {:ok, ids} ->
            WandererApp.Cache.insert(ready_ids_cache_key(map_id), ids, ttl: @ready_ids_ttl)
            ids

          :error ->
            []
        end

      ids ->
        ids
    end
  end

  def ready_character_eve_ids(_map_id), do: []

  @doc """
  Drops the cached ready-character set for a map. Safe to call for a map that
  was never cached.
  """
  def invalidate_ready_character_eve_ids(map_id) when is_binary(map_id) and map_id != "" do
    WandererApp.Cache.delete(ready_ids_cache_key(map_id))
    :ok
  end

  def invalidate_ready_character_eve_ids(_map_id), do: :ok

  defp ready_ids_cache_key(map_id), do: "map:#{map_id}:ready_character_eve_ids"

  defp load_ready_character_eve_ids(map_id) do
    case get_by_map(map_id) do
      {:ok, settings_list} ->
        {:ok,
         settings_list
         |> Enum.flat_map(fn setting -> setting.ready_characters || [] end)
         |> Enum.uniq()}

      {:error, _reason} ->
        :error
    end
  end

  @doc """
  Gets all map user settings where the specified character_eve_id is marked as ready.
  Returns {:ok, [settings]} or {:error, reason}
  """
  def get_settings_with_ready_character(character_eve_id)
      when is_binary(character_eve_id) and character_eve_id != "" do
    # Ash action rather than the raw Ecto query this used to run: that query
    # rebuilt partial `%MapUserSettings{}` structs by hand, so every field it
    # forgot to select silently came back as the struct default.
    case WandererApp.Api.MapUserSettings.read_by_ready_character(%{
           character_eve_id: character_eve_id
         }) do
      {:ok, settings_list} ->
        {:ok, settings_list}

      {:error, reason} ->
        Logger.error("Failed to read settings by ready character: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def get_settings_with_ready_character(character_eve_id) do
    Logger.warning(
      "Invalid character_eve_id provided (#{inspect(typeof(character_eve_id))}): " <>
        "expected a non-empty binary"
    )

    {:error, :invalid_character_eve_id}
  end

  defp typeof(value) when is_binary(value), do: :binary
  defp typeof(value) when is_nil(value), do: nil
  defp typeof(value) when is_atom(value), do: :atom
  defp typeof(value) when is_integer(value), do: :integer
  defp typeof(value) when is_list(value), do: :list
  defp typeof(value) when is_map(value), do: :map
  defp typeof(_value), do: :other
end
