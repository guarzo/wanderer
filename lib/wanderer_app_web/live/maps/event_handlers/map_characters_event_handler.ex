defmodule WandererAppWeb.MapCharactersEventHandler do
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
            only_tracked_characters: only_tracked_characters
          }
        } = socket
      ) do
    Logger.info("Handling toggle_track for character_id: #{character_id}")

    # Get the character settings for the map
    {:ok, character_settings} =
      case WandererApp.MapCharacterSettingsRepo.get_all_by_map(map_id) do
        {:ok, settings} ->
          Logger.info("Found #{length(settings)} character settings for map #{map_id}")
          {:ok, settings}
        _ ->
          Logger.info("No character settings found for map #{map_id}")
          {:ok, []}
      end

    # Find the character setting for the specified character
    character_setting = character_settings |> Enum.find(&(&1.character_id == character_id))
    Logger.info("Character setting found: #{inspect(character_setting)}")

    # Determine if we're tracking or untracking the character
    {action, socket} =
      case character_setting do
        nil ->
          # Create a new character setting with tracking enabled
          Logger.info("Creating new character setting with tracking enabled")
          {:ok, setting} =
            WandererApp.MapCharacterSettingsRepo.create(%{
              character_id: character_id,
              map_id: map_id,
              tracked: true,
              followed: false
            })
          Logger.info("Created new setting: #{inspect(setting)}")
          {:track, socket}

        %{tracked: true} = setting ->
          # Untrack the character
          Logger.info("Untracking character with setting: #{inspect(setting)}")
          _result = WandererApp.MapCharacterSettingsRepo.untrack!(setting)
          Logger.info("Character untracked")
          {:untrack, socket}

        setting ->
          # Track the character
          Logger.info("Tracking character with setting: #{inspect(setting)}")
          _result = WandererApp.MapCharacterSettingsRepo.track!(setting)
          Logger.info("Character tracked")
          {:track, socket}
      end

    Logger.info("Action taken: #{action}")

    # Get the updated character settings
    {:ok, updated_character_settings} =
      case WandererApp.MapCharacterSettingsRepo.get_all_by_map(map_id) do
        {:ok, settings} -> {:ok, settings}
        _ -> {:ok, []}
      end

    # Get the map
    {:ok, map} =
      map_id
      |> WandererApp.MapRepo.get([:acls])

    # Load the characters with the updated settings
    {:ok, %{characters: chars}} =
      map
      |> WandererApp.Maps.load_characters(
        updated_character_settings,
        current_user.id
      )

    # Log character tracking status
    Logger.info("Character tracked status after update: #{inspect(Enum.map(chars, fn c -> {c.id, Map.get(c, :tracked, false)} end))}")

    # Transform characters for the React component
    react_characters = Enum.map(chars, fn char ->
      %{
        character_id: char.id,
        character_name: char.name,
        eve_id: char.eve_id,
        corporation_ticker: char.corporation_ticker || "",
        alliance_ticker: Map.get(char, :alliance_ticker, ""),
        tracked: Map.get(char, :tracked, false),
        followed: Map.get(char, :followed, false)
      }
    end)

    # Log the transformed characters
    Logger.info("Transformed characters for React: #{inspect(react_characters)}")

    # Push the updated character data to the React component if connected
    socket =
      if connected?(socket) do
        Logger.info("Socket connected, pushing #{length(react_characters)} characters after toggle_track")
        socket |> push_event("update_tracking", %{characters: react_characters})
      else
        Logger.info("Socket not connected, not pushing events")
        socket
      end

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
    Logger.info("Handling toggle_follow for character_id: #{character_id}")

    # Get the character settings for the map
    {:ok, character_settings} =
      case WandererApp.MapCharacterSettingsRepo.get_all_by_map(map_id) do
        {:ok, settings} ->
          Logger.info("Found #{length(settings)} character settings for map #{map_id}")
          {:ok, settings}
        _ ->
          Logger.info("No character settings found for map #{map_id}")
          {:ok, []}
      end

    # Find the character setting for the specified character
    character_setting = character_settings |> Enum.find(&(&1.character_id == character_id))
    Logger.info("Character setting found: #{inspect(character_setting)}")

    # Find any currently followed character
    currently_followed_setting = character_settings |> Enum.find(&(&1.followed))
    Logger.info("Currently followed character: #{inspect(currently_followed_setting)}")

    # Determine if we're following or unfollowing the character
    {action, socket} =
      case character_setting do
        nil ->
          # Create a new character setting with following enabled
          Logger.info("Creating new character setting with following enabled")

          # First, unfollow any currently followed character
          if currently_followed_setting do
            Logger.info("Unfollowing currently followed character: #{inspect(currently_followed_setting)}")
            _result = WandererApp.MapCharacterSettingsRepo.unfollow!(currently_followed_setting)
          end

          # Then create the new setting
          {:ok, setting} =
            WandererApp.MapCharacterSettingsRepo.create(%{
              character_id: character_id,
              map_id: map_id,
              tracked: true, # Ensure the character is tracked if followed
              followed: true
            })
          Logger.info("Created new setting: #{inspect(setting)}")
          {:follow, socket}

        %{followed: true} = setting ->
          # Unfollow the character
          Logger.info("Unfollowing character with setting: #{inspect(setting)}")
          _result = WandererApp.MapCharacterSettingsRepo.unfollow!(setting)
          Logger.info("Character unfollowed")
          {:unfollow, socket}

        setting ->
          # Follow the character and unfollow any currently followed character
          Logger.info("Following character with setting: #{inspect(setting)}")

          # First, unfollow any currently followed character
          if currently_followed_setting && currently_followed_setting.id != setting.id do
            Logger.info("Unfollowing currently followed character: #{inspect(currently_followed_setting)}")
            _result = WandererApp.MapCharacterSettingsRepo.unfollow!(currently_followed_setting)
          end

          # Then follow the new character
          _result = WandererApp.MapCharacterSettingsRepo.follow!(setting)
          Logger.info("Character followed")
          {:follow, socket}
      end

    Logger.info("Action taken: #{action}")

    # Get the updated character settings
    {:ok, updated_character_settings} =
      case WandererApp.MapCharacterSettingsRepo.get_all_by_map(map_id) do
        {:ok, settings} -> {:ok, settings}
        _ -> {:ok, []}
      end

    # Get the map
    {:ok, map} =
      map_id
      |> WandererApp.MapRepo.get([:acls])

    # Load the characters with the updated settings
    {:ok, %{characters: chars}} =
      map
      |> WandererApp.Maps.load_characters(
        updated_character_settings,
        current_user.id
      )

    # Log character following status
    Logger.info("Character followed status after update: #{inspect(Enum.map(chars, fn c -> {c.id, Map.get(c, :followed, false)} end))}")

    # Transform characters for the React component
    react_characters = Enum.map(chars, fn char ->
      %{
        character_id: char.id,
        character_name: char.name,
        eve_id: char.eve_id,
        corporation_ticker: char.corporation_ticker || "",
        alliance_ticker: Map.get(char, :alliance_ticker, ""),
        tracked: Map.get(char, :tracked, false),
        followed: Map.get(char, :followed, false)
      }
    end)

    # Log the transformed characters
    Logger.info("Transformed characters for React: #{inspect(react_characters)}")

    # Push the updated character data to the React component if connected
    socket =
      if connected?(socket) do
        Logger.info("Socket connected, pushing #{length(react_characters)} characters after toggle_follow")
        socket |> push_event("update_tracking", %{characters: react_characters})
      else
        Logger.info("Socket not connected, not pushing events")
        socket
      end

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
    Logger.info("Received refresh_characters command")

    # Get the character settings for the map
    {:ok, character_settings} =
      case WandererApp.MapCharacterSettingsRepo.get_all_by_map(map_id) do
        {:ok, settings} -> {:ok, settings}
        _ -> {:ok, []}
      end

    # Load characters directly
    {:ok, map} =
      map_id
      |> WandererApp.MapRepo.get([:acls])

    # Load characters
    {:ok, %{characters: chars}} =
      map
      |> WandererApp.Maps.load_characters(
        character_settings,
        current_user.id
      )

    # Transform characters to match the expected format for the React component
    react_characters = Enum.map(chars, fn char ->
      %{
        character_id: char.id,
        character_name: char.name,
        eve_id: char.eve_id,
        corporation_ticker: char.corporation_ticker || "",
        alliance_ticker: Map.get(char, :alliance_ticker, ""),
        tracked: Map.get(char, :tracked, false),
        followed: Map.get(char, :followed, false)
      }
    end)

    Logger.info("Loaded #{length(react_characters)} characters for map #{map_id}")

    # If connected, push events to show the tracking modal with the characters
    socket = if connected?(socket) do
      socket = socket |> push_event("show_tracking", %{})
      socket = socket |> push_event("update_tracking", %{characters: react_characters})
      socket
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

    # Get the character settings for the map
    {:ok, character_settings} =
      case WandererApp.MapCharacterSettingsRepo.get_all_by_map(map_id) do
        {:ok, settings} -> {:ok, settings}
        _ -> {:ok, []}
      end

    # Load characters directly
    {:ok, map} =
      map_id
      |> WandererApp.MapRepo.get([:acls])

    # Load characters
    {:ok, %{characters: chars}} =
      map
      |> WandererApp.Maps.load_characters(
        character_settings,
        current_user.id
      )

    # Transform characters to match the expected format for the React component
    react_characters = Enum.map(chars, fn char ->
      %{
        character_id: char.id,
        character_name: char.name,
        eve_id: char.eve_id,
        corporation_ticker: char.corporation_ticker || "",
        alliance_ticker: Map.get(char, :alliance_ticker, ""),
        tracked: Map.get(char, :tracked, false),
        followed: Map.get(char, :followed, false)
      }
    end)

    Logger.info("Loaded #{length(react_characters)} characters for map #{map_id}")

    # If connected, push events to show the tracking modal with the characters
    socket = if connected?(socket) do
      Logger.info("Socket connected, pushing #{length(react_characters)} characters")

      # First push the show_tracking event to ensure the modal is visible
      socket = socket |> push_event("show_tracking", %{})
      Logger.info("Pushed show_tracking event")

      # Then push the update_tracking event with the characters
      socket = socket |> push_event("update_tracking", %{characters: react_characters})
      Logger.info("Pushed update_tracking event with #{length(react_characters)} characters")

      socket
    else
      Logger.info("Socket not connected, not pushing events")
      socket
    end

    socket
  end

  def add_character(socket), do: socket

  # Handle the async result for characters and push the update_tracking event
  def handle_info({:async_result, :characters, {:ok, %{characters: chars}}}, socket) when is_list(chars) do
    # Create a list of characters to send to the client
    react_characters = if length(chars) > 0 do
      transformed_chars = Enum.map(chars, fn char ->
        %{
          character_id: char.id,
          character_name: char.name,
          eve_id: char.eve_id,
          corporation_ticker: char.corporation_ticker || "",
          alliance_ticker: Map.get(char, :alliance_ticker, ""),
          tracked: Map.get(char, :tracked, false),
          followed: Map.get(char, :followed, false)
        }
      end)

      transformed_chars
    else
      Logger.warn("No characters found in async result, using placeholder")
      [
        %{
          character_id: "no-characters-found", # Changed from "no-characters" to avoid confusion
          character_name: "No Characters Found",
          eve_id: "1",
          corporation_ticker: "NONE",
          alliance_ticker: "FOUND",
          tracked: false,
          followed: false
        }
      ]
    end

    socket = if connected?(socket) do
      char_ids = Enum.map(react_characters, & &1.character_id)
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

  def handle_info({:async_result, :characters, result}, socket) do
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
end
