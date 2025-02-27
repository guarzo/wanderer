defmodule WandererAppWeb.MapCharactersEventHandler do
  @moduledoc """
  Handles events related to character tracking and following in maps.

  This module is responsible for:
  - Tracking and untracking characters
  - Following and unfollowing characters
  - Updating character settings in the database
  - Pushing character data to the React UI components
  """
  use WandererAppWeb, :live_component
  use Phoenix.Component
  require Logger

  alias WandererAppWeb.{MapEventHandler, MapCoreEventHandler}

  def handle_server_event(%{event: :character_added, payload: character}, socket) do
    socket
    |> MapEventHandler.push_map_event(
      "character_added",
      character |> map_ui_character()
    )
  end

  def handle_server_event(%{event: :character_removed, payload: character}, socket) do
    socket
    |> MapEventHandler.push_map_event(
      "character_removed",
      character |> map_ui_character()
    )
  end

  def handle_server_event(%{event: :character_updated, payload: character}, socket) do
    socket
    |> MapEventHandler.push_map_event(
      "character_updated",
      character |> map_ui_character()
    )
  end

  def handle_server_event(
        %{event: :characters_updated},
        %{
          assigns: %{
            map_id: map_id
          }
        } = socket
      ) do
    characters =
      map_id
      |> WandererApp.Map.list_characters()
      |> Enum.map(&map_ui_character/1)

    socket
    |> MapEventHandler.push_map_event(
      "characters_updated",
      characters
    )
  end

  def handle_server_event(
        %{event: :present_characters_updated, payload: present_character_eve_ids},
        socket
      ),
      do:
        socket
        |> MapEventHandler.push_map_event(
          "present_characters",
          present_character_eve_ids
        )

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

  def handle_ui_event(
        "add_character",
        _,
        socket
      ),
      do: {:noreply, socket |> add_character()}

  def handle_ui_event(
        "add_character",
        _,
        %{
          assigns: %{
            user_permissions: %{track_character: false}
          }
        } = socket
      ),
      do:
        {:noreply,
         socket
         |> put_flash(
           :error,
           "You don't have permissions to track characters. Please contact administrator."
         )}

  def handle_ui_event(
        "toggle_track",
        %{"character-id" => character_id},
        %{
          assigns: %{
            map_id: map_id,
            current_user: current_user,
            only_tracked_characters: _only_tracked_characters
          }
        } = socket
      ) do
    # Get character settings
    {:ok, character_settings} = get_character_settings(map_id)

    # Find the character setting for this character
    character_setting = character_settings |> Enum.find(&(&1.character_id == character_id))

    # Update the character setting based on its current state
    {_action, _setting} = update_track_setting(character_setting, map_id, character_id)

    # Get updated character data and push to React
    socket = push_updated_character_data(socket, map_id, current_user)

    {:noreply, socket}
  end

  def handle_ui_event(
        "toggle_follow",
        %{"character-id" => character_id},
        %{
          assigns: %{
            map_id: map_id,
            current_user: current_user
          }
        } = socket
      ) do
    # Get character settings
    {:ok, character_settings} = get_character_settings(map_id)

    # Find the character setting for this character
    character_setting = character_settings |> Enum.find(&(&1.character_id == character_id))

    # Find any currently followed character
    currently_followed_setting = character_settings |> Enum.find(&(&1.followed))

    # Update the follow setting
    {_action, _setting} = update_follow_setting(character_setting, currently_followed_setting, map_id, character_id)

    # Get updated character data and push to React
    socket = push_updated_character_data(socket, map_id, current_user)

    {:noreply, socket}
  end

  def handle_ui_event("hide_tracking", _, socket) do
    socket = socket |> assign(show_tracking?: false, react_tracking_enabled: false)

    # Push an event to the React component to hide the tracking modal if connected
    socket = if connected?(socket) do
      socket |> push_event("hide_tracking", %{})
    else
      socket
    end

    {:noreply, socket}
  end

  def handle_ui_event(
    "refresh_characters",
    _params,
    %{
      assigns: %{
        map_id: map_id,
        current_user: current_user
      }
    } = socket
  ) do
    # Get updated character data and push to React
    socket = push_updated_character_data(socket, map_id, current_user)

    # Also push the show_tracking event
    socket = if connected?(socket) do
      socket |> push_event("show_tracking", %{})
    else
      socket
    end

    {:noreply, socket}
  end

  def handle_ui_event(event, body, socket),
    do: MapCoreEventHandler.handle_ui_event(event, body, socket)

  def add_character(
        %{
          assigns: %{
            current_user: current_user,
            map_id: map_id,
            user_permissions: %{track_character: true}
          }
        } = socket
      ) do
    # Set react_tracking_enabled to true to use the React component
    socket = socket |> assign(react_tracking_enabled: true, show_tracking?: true)

    # Get updated character data and push to React
    socket = push_updated_character_data(socket, map_id, current_user)

    # Also push the show_tracking event
    socket = if connected?(socket) do
      socket |> push_event("show_tracking", %{})
    else
      socket
    end

    socket
  end

  def add_character(socket), do: socket

  # Handle the async result for characters and push the update_tracking event
  def handle_info({:async_result, :characters, {:ok, %{characters: chars}}}, socket) when is_list(chars) do
    # Create a list of characters to send to the client
    react_characters = if length(chars) > 0 do
      Enum.map(chars, &transform_character_for_react/1)
    else
      []
    end

    socket = if connected?(socket) do
      socket = socket |> push_event("show_tracking", %{})
      socket = socket |> push_event("update_tracking", %{characters: react_characters})
      socket
    else
      socket
    end

    {:noreply, socket}
  end

  def handle_info({:push_characters, react_characters}, socket) do
    socket = socket |> push_event("show_tracking", %{})
    socket = socket |> push_event("update_tracking", %{characters: react_characters})
    {:noreply, socket}
  end

  def handle_info({:async_result, :characters, _result}, socket) do
    {:noreply, socket}
  end

  def has_tracked_characters?([]), do: false
  def has_tracked_characters?(_user_characters), do: true

  def map_ui_character(character),
    do:
      character
      |> Map.take([
        :eve_id,
        :name,
        :online,
        :corporation_id,
        :corporation_name,
        :corporation_ticker,
        :alliance_id,
        :alliance_name,
        :alliance_ticker
      ])
      |> Map.put_new(:ship, WandererApp.Character.get_ship(character))
      |> Map.put_new(:location, get_location(character))

  def add_characters([], _map_id, _track_character), do: :ok

  def add_characters([character | characters], map_id, track_character) do
    map_id
    |> WandererApp.Map.Server.add_character(character, track_character)

    add_characters(characters, map_id, track_character)
  end

  def remove_characters([], _map_id), do: :ok

  def remove_characters([character | characters], map_id) do
    map_id
    |> WandererApp.Map.Server.remove_character(character.id)

    remove_characters(characters, map_id)
  end

  def untrack_characters(characters, map_id) do
    characters
    |> Enum.each(fn character ->
      WandererAppWeb.Presence.untrack(self(), map_id, character.id)

      WandererApp.Cache.put(
        "#{inspect(self())}_map_#{map_id}:character_#{character.id}:tracked",
        false
      )

      :ok =
        Phoenix.PubSub.unsubscribe(
          WandererApp.PubSub,
          "character:#{character.eve_id}"
        )
    end)
  end

  def track_characters(_, _, false), do: :ok

  def track_characters([], _map_id, _is_track_character?), do: :ok

  def track_characters(
        [character | characters],
        map_id,
        true
      ) do
    track_character(character, map_id)

    track_characters(characters, map_id, true)
  end

  def track_character(
        %{
          id: character_id,
          eve_id: eve_id,
          corporation_id: corporation_id,
          alliance_id: alliance_id
        },
        map_id
      ) do
    WandererAppWeb.Presence.track(self(), map_id, character_id, %{})

    case WandererApp.Cache.lookup!(
           "#{inspect(self())}_map_#{map_id}:character_#{character_id}:tracked",
           false
         ) do
      true ->
        :ok

      _ ->
        :ok =
          Phoenix.PubSub.subscribe(
            WandererApp.PubSub,
            "character:#{eve_id}"
          )

        :ok =
          WandererApp.Cache.put(
            "#{inspect(self())}_map_#{map_id}:character_#{character_id}:tracked",
            true
          )
    end

    case WandererApp.Cache.lookup(
           "#{inspect(self())}_map_#{map_id}:corporation_#{corporation_id}:tracked",
           false
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        :ok =
          Phoenix.PubSub.subscribe(
            WandererApp.PubSub,
            "corporation:#{corporation_id}"
          )

        :ok =
          WandererApp.Cache.put(
            "#{inspect(self())}_map_#{map_id}:corporation_#{corporation_id}:tracked",
            true
          )
    end

    case WandererApp.Cache.lookup(
           "#{inspect(self())}_map_#{map_id}:alliance_#{alliance_id}:tracked",
           false
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        :ok =
          Phoenix.PubSub.subscribe(
            WandererApp.PubSub,
            "alliance:#{alliance_id}"
          )

        :ok =
          WandererApp.Cache.put(
            "#{inspect(self())}_map_#{map_id}:alliance_#{alliance_id}:tracked",
            true
          )
    end

    :ok = WandererApp.Character.TrackerManager.start_tracking(character_id)
  end

  defp get_location(character),
    do: %{solar_system_id: character.solar_system_id, structure_id: character.structure_id}

  # Helper functions to reduce complexity

  # Get character settings for a map
  defp get_character_settings(map_id) do
    case WandererApp.MapCharacterSettingsRepo.get_all_by_map(map_id) do
      {:ok, settings} -> {:ok, settings}
      _ -> {:ok, []}
    end
  end

  # Update track setting based on current state
  defp update_track_setting(character_setting, map_id, character_id) do
    case character_setting do
      nil ->
        # Create a new setting with tracking enabled
        {:ok, setting} =
          WandererApp.MapCharacterSettingsRepo.create(%{
            character_id: character_id,
            map_id: map_id,
            tracked: true,
            followed: false
          })
        {:track, setting}

      %{tracked: true} = setting ->
        # Untrack the character
        WandererApp.MapCharacterSettingsRepo.untrack!(setting)
        {:untrack, setting}

      setting ->
        # Track the character
        WandererApp.MapCharacterSettingsRepo.track!(setting)
        {:track, setting}
    end
  end

  defp update_follow_setting(character_setting, currently_followed_setting, map_id, character_id) do
    case character_setting do
      nil ->
        if currently_followed_setting do
          WandererApp.MapCharacterSettingsRepo.unfollow!(currently_followed_setting)
        end

        # Then create the new setting
        {:ok, setting} =
          WandererApp.MapCharacterSettingsRepo.create(%{
            character_id: character_id,
            map_id: map_id,
            tracked: true, # Ensure the character is tracked if followed
            followed: true
          })
        {:follow, setting}

      %{followed: true} = setting ->
        # Unfollow the character
        WandererApp.MapCharacterSettingsRepo.unfollow!(setting)
        {:unfollow, setting}

      setting ->
        # Follow the character and unfollow any currently followed character
        if currently_followed_setting && currently_followed_setting.id != setting.id do
          WandererApp.MapCharacterSettingsRepo.unfollow!(currently_followed_setting)
        end

        WandererApp.MapCharacterSettingsRepo.follow!(setting)
        {:follow, setting}
    end
  end

  # Get updated character data and push to React
  defp push_updated_character_data(socket, map_id, current_user) do
    # Get the updated character settings
    {:ok, updated_character_settings} = get_character_settings(map_id)

    # Get the map
    {:ok, map} = map_id |> WandererApp.MapRepo.get([:acls])

    # Load the characters with the updated settings
    {:ok, %{characters: chars}} =
      map
      |> WandererApp.Maps.load_characters(
        updated_character_settings,
        current_user.id
      )

    # Transform characters for the React component
    react_characters = Enum.map(chars, &transform_character_for_react/1)

    # Push the updated character data to the React component if connected
    if connected?(socket) do
      socket |> push_event("update_tracking", %{characters: react_characters})
    else
      socket
    end
  end

  # Transform a character for the React component
  defp transform_character_for_react(char) do
    %{
      character_id: char.id,
      character_name: char.name,
      eve_id: char.eve_id,
      corporation_ticker: char.corporation_ticker || "",
      alliance_ticker: Map.get(char, :alliance_ticker, ""),
      tracked: Map.get(char, :tracked, false),
      followed: Map.get(char, :followed, false)
    }
  end
end
