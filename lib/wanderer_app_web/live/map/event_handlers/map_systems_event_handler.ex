defmodule WandererAppWeb.MapSystemsEventHandler do
  use WandererAppWeb, :live_component
  use Phoenix.Component
  require Logger

  alias WandererAppWeb.{MapEventHandler, MapCoreEventHandler}
  alias WandererApp.Character
  alias WandererApp.Map.Server.Impl

  def handle_server_event(%{event: :add_system, payload: system}, socket),
    do:
      socket
      |> MapEventHandler.push_map_event("add_systems", [
        MapEventHandler.map_ui_system(system)
      ])

  def handle_server_event(%{event: :update_system, payload: system}, socket),
    do:
      socket
      |> MapEventHandler.push_map_event("update_systems", [
        MapEventHandler.map_ui_system(system, false)
      ])

  def handle_server_event(%{event: :systems_removed, payload: solar_system_ids}, socket),
    do:
      socket
      |> MapEventHandler.push_map_event("remove_systems", solar_system_ids)

  def handle_server_event(
        %{
          event: :maybe_select_system,
          payload: %{
            character_id: character_id,
            solar_system_id: solar_system_id
          }
        },
        %{
          assigns: %{
            current_user: current_user,
            tracked_characters: tracked_characters,
            map_id: map_id,
            map_user_settings: map_user_settings
          }
        } = socket
      ) do
    character =
      tracked_characters
      |> Enum.find(fn tracked_character -> tracked_character.id == character_id end)

    is_user_character =
      not is_nil(character)

    is_select_on_spash =
      map_user_settings
      |> WandererApp.MapUserSettingsRepo.to_form_data!()
      |> WandererApp.MapUserSettingsRepo.get_boolean_setting("select_on_spash")

    is_following =
      case WandererApp.MapUserSettingsRepo.get(map_id, current_user.id) do
        {:ok, %{following_character_eve_id: following_character_eve_id}}
        when not is_nil(following_character_eve_id) ->
          is_user_character && following_character_eve_id == character.eve_id

        _ ->
          false
      end

    must_select? = is_user_character && (is_select_on_spash || is_following)

    if not must_select? do
      socket
    else
      # Check if we already selected this exact system for this char:
      last_selected =
        WandererApp.Cache.lookup!(
          "char:#{character_id}:map:#{map_id}:last_selected_system_id",
          nil
        )

      if last_selected == solar_system_id do
        # same system => skip
        socket
      else
        # new system => update cache + push event
        WandererApp.Cache.put(
          "char:#{character_id}:map:#{map_id}:last_selected_system_id",
          solar_system_id
        )

        socket
        |> MapEventHandler.push_map_event("select_system", solar_system_id)
      end
    end
  end

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

  def handle_ui_event(
        "manual_add_system",
        %{"solar_system_id" => solar_system_id, "coordinates" => coordinates} = _event,
        %{
          assigns: %{
            current_user: current_user,
            has_tracked_characters?: true,
            map_id: map_id,
            main_character_id: main_character_id,
            user_permissions: %{add_system: true}
          }
        } =
          socket
      ) do
    WandererApp.Map.Server.add_system(
      map_id,
      %{
        solar_system_id: solar_system_id,
        coordinates: coordinates
      },
      current_user.id,
      main_character_id
    )

    {:noreply, socket}
  end

  def handle_ui_event(
        "add_hub",
        %{"system_id" => solar_system_id} = _event,
        %{
          assigns: %{
            map_id: map_id,
            current_user: current_user,
            main_character_id: main_character_id,
            has_tracked_characters?: true,
            user_permissions: %{update_system: true}
          }
        } =
          socket
      ) do
    map_id
    |> WandererApp.Map.Server.add_hub(%{
      solar_system_id: solar_system_id
    })

    {:ok, _} =
      WandererApp.User.ActivityTracker.track_map_event(:hub_added, %{
        character_id: main_character_id,
        user_id: current_user.id,
        map_id: map_id,
        solar_system_id: solar_system_id
      })

    {:noreply, socket}
  end

  def handle_ui_event(
        "delete_hub",
        %{"system_id" => solar_system_id} = _event,
        %{
          assigns: %{
            map_id: map_id,
            current_user: current_user,
            main_character_id: main_character_id,
            has_tracked_characters?: true,
            user_permissions: %{update_system: true}
          }
        } =
          socket
      ) do
    map_id
    |> WandererApp.Map.Server.remove_hub(%{
      solar_system_id: solar_system_id
    })

    {:ok, _} =
      WandererApp.User.ActivityTracker.track_map_event(:hub_removed, %{
        character_id: main_character_id,
        user_id: current_user.id,
        map_id: map_id,
        solar_system_id: solar_system_id
      })

    {:noreply, socket}
  end

  def handle_ui_event(
        "update_system_position",
        position,
        %{
          assigns: %{
            map_id: map_id,
            has_tracked_characters?: true,
            user_permissions: %{update_system: true}
          }
        } = socket
      ) do
    map_id
    |> update_system_position(position)

    {:noreply, socket}
  end

  def handle_ui_event(
        "update_system_positions",
        positions,
        %{
          assigns: %{
            map_id: map_id,
            has_tracked_characters?: true,
            user_permissions: %{update_system: true}
          }
        } = socket
      ) do
    map_id
    |> update_system_positions(positions)

    {:noreply, socket}
  end

  def handle_ui_event(
      "update_system_owner",
      %{"system_id" => sid} = params,
      %{
        assigns: %{
          map_id: map_id,
          current_user: current_user,
          tracked_characters: tracked_characters,
          user_permissions: user_permissions
        }
      } = socket
    ) do

    # Extract owner_id, owner_type, and owner_ticker from params using STRING keys
    oid = Map.get(params, "owner_id")
    otype = Map.get(params, "owner_type")
    ticker = Map.get(params, "owner_ticker")

    # Clean up potential null/empty string values
    oid = case oid do
      "null" -> nil
      "" -> nil
      val -> val
    end

    otype = case otype do
      "null" -> nil
      "" -> nil
      val -> val
    end

    ticker = case ticker do
      "null" -> nil
      "" -> nil
      val -> val
    end

    if can_update_system?(:owner, user_permissions) do
      system_id_int =
          case sid do
            id when is_integer(id) -> id
            id when is_binary(id) -> String.to_integer(id)
            _ -> nil
          end

      if system_id_int do
        WandererApp.Map.Server.update_system_owner(
          map_id,
          %{
            solar_system_id: system_id_int,
            owner_id: oid,
            owner_type: otype,
            owner_ticker: ticker
          }
        )

        main_character_id = case tracked_characters do
          [first | _] -> first.id
          _ -> nil
        end

        if main_character_id do
          {:ok, _} =
            WandererApp.User.ActivityTracker.track_map_event(:system_updated, %{
              character_id: main_character_id,
              user_id: current_user.id,
              map_id: map_id,
              solar_system_id: system_id_int,
              key: :owner,
              value: %{owner_id: oid, owner_type: otype, ticker: ticker}
            })
        end
      end
    end

    {:noreply, socket}
  end


  def handle_ui_event(
        "update_system_" <> param,
        %{"system_id" => solar_system_id, "value" => value} = _event,
        %{
          assigns: %{
            map_id: map_id,
            current_user: current_user,
            main_character_id: main_character_id,
            has_tracked_characters?: true,
            user_permissions: %{update_system: true} = user_permissions
          }
        } =
          socket
      ) do
    method_atom =
      case param do
        "name" -> :update_system_name
        "description" -> :update_system_description
        "labels" -> :update_system_labels
        "locked" -> :update_system_locked
        "tag" -> :update_system_tag
        "temporary_name" -> :update_system_temporary_name
        "custom_flags" -> :update_system_custom_flags
        "status" -> :update_system_status
        _ -> nil
      end

    key_atom =
      case param do
        "name" -> :name
        "description" -> :description
        "labels" -> :labels
        "locked" -> :locked
        "tag" -> :tag
        "temporary_name" -> :temporary_name
        "custom_flags" -> :custom_flags
        "status" -> :status
        _ -> :none
      end

    if can_update_system?(key_atom, user_permissions) do
      apply(WandererApp.Map.Server, method_atom, [
        map_id,
        %{
          solar_system_id: "#{solar_system_id}" |> String.to_integer()
        }
        |> Map.put_new(key_atom, value)
      ])

      {:ok, _} =
        WandererApp.User.ActivityTracker.track_map_event(:system_updated, %{
          character_id: main_character_id,
          user_id: current_user.id,
          map_id: map_id,
          solar_system_id: "#{solar_system_id}" |> String.to_integer(),
          key: key_atom,
          value: value
        })
    end

    {:noreply, socket}
  end

  def handle_ui_event(
        "get_system_static_infos",
        %{"solar_system_ids" => solar_system_ids} = _event,
        socket
      ) do
    system_static_infos =
      solar_system_ids
      |> Enum.map(&WandererApp.CachedInfo.get_system_static_info!/1)
      |> Enum.map(&MapEventHandler.map_ui_system_static_info/1)

    {:reply, %{system_static_infos: system_static_infos}, socket}
  end

  def handle_ui_event(
        "search_systems",
        %{"text" => text} = _event,
        socket
      ) do
    systems =
      WandererApp.Api.MapSolarSystem.find_by_name!(%{name: text})
      |> Enum.take(100)
      |> Enum.map(&map_system/1)
      |> Enum.filter(fn system ->
        not is_nil(system) && not is_nil(system.system_static_info) &&
          not WandererApp.Map.Server.ConnectionsImpl.is_prohibited_system_class?(
            system.system_static_info.system_class
          )
      end)

    {:reply, %{systems: systems}, socket}
  end

  def handle_ui_event(
        "delete_systems",
        solar_system_ids,
        %{
          assigns: %{
            map_id: map_id,
            current_user: current_user,
            main_character_id: main_character_id,
            has_tracked_characters?: true,
            user_permissions: %{delete_system: true}
          }
        } =
          socket
      ) do
    map_id
    |> WandererApp.Map.Server.delete_systems(
      solar_system_ids |> Enum.map(&String.to_integer/1),
      current_user.id,
      main_character_id
    )

    {:noreply, socket}
  end

  def map_system(
        %{
          solar_system_name: solar_system_name,
          constellation_name: constellation_name,
          region_name: region_name,
          solar_system_id: solar_system_id,
          class_title: class_title
        } = _system
      ) do
    system_static_info = MapEventHandler.get_system_static_info(solar_system_id)

    %{
      label: solar_system_name,
      value: solar_system_id,
      constellation_name: constellation_name,
      region_name: region_name,
      class_title: class_title,
      system_static_info: system_static_info
    }
  end

  defp can_update_system?(:locked, %{lock_system: false} = _user_permissions), do: false
  defp can_update_system?(_key, _user_permissions), do: true

  defp update_system_positions(_map_id, []), do: :ok

  defp update_system_positions(map_id, [position | rest]) do
    update_system_position(map_id, position)
    update_system_positions(map_id, rest)
  end

  defp update_system_position(map_id, %{
         "position" => %{"x" => x, "y" => y},
         "solar_system_id" => solar_system_id
       }),
       do:
         map_id
         |> WandererApp.Map.Server.update_system_position(%{
           solar_system_id: solar_system_id |> String.to_integer(),
           position_x: x,
           position_y: y
         })

  def search_corporation_names([], _search), do: {:ok, []}

  def search_corporation_names([first_char | _], search) when is_binary(search) do
    # Ensure search is at least 3 characters
    if String.length(search) < 3 do
      {:ok, []}
    else
      search_term = search

      result = Character.search(first_char.id, params: [search: search_term, categories: "corporation"])

      # Format the results to include both ticker and name
      formatted_result = case result do
        {:ok, results} ->
          formatted_results = Enum.map(results, fn item ->
            name = Map.get(item, :label, "")
            corp_id = Map.get(item, :value, "")

            # Fetch the ticker for each corporation
            ticker = case WandererApp.Esi.get_corporation_info(corp_id) do
              {:ok, %{"ticker" => ticker}} ->
                ticker
              _ ->
                ""
            end

            # Create formatted label with ticker if available
            formatted_label = if ticker && ticker != "", do: "[#{ticker}] #{name}", else: name

            # Update the item with the formatted label and ticker
            Map.merge(item, %{
              formatted: formatted_label,
              name: name,
              ticker: ticker,
              id: item.value,
              type: "corp"
            })
          end)

          {:ok, formatted_results}

        other ->
          other
      end

      formatted_result
    end
  end

  def search_corporation_names(_user_chars, _search), do: {:ok, []}

  def search_alliance_names([], _search), do: {:ok, []}

  def search_alliance_names([first_char | _], search) when is_binary(search) do
    # Ensure search is at least 3 characters
    if String.length(search) < 3 do
      {:ok, []}
    else
      search_term = search

      result = Character.search(first_char.id, params: [search: search_term, categories: "alliance"])

      # Format the results to include both ticker and name
      formatted_result = case result do
        {:ok, results} ->
          formatted_results = Enum.map(results, fn item ->
            name = Map.get(item, :label, "")
            alliance_id = Map.get(item, :value, "")

            # Fetch the ticker for each alliance
            ticker = case WandererApp.Esi.get_alliance_info(alliance_id) do
              {:ok, %{"ticker" => ticker}} ->
                ticker
              _ ->
                ""
            end

            # Create formatted label with ticker if available
            formatted_label = if ticker && ticker != "", do: "[#{ticker}] #{name}", else: name

            # Update the item with the formatted label and ticker
            Map.merge(item, %{
              formatted: formatted_label,
              name: name,
              ticker: ticker,
              id: item.value,
              type: "alliance"
            })
          end)

          {:ok, formatted_results}

        other ->
          other
      end

      formatted_result
    end
  end

  def search_alliance_names(_user_chars, _search), do: {:ok, []}

  # Handle UI events for getting corporation names
  def handle_ui_event("get_corporation_names", %{"search" => search}, socket) do
    # Get the current user's characters
    user_chars = socket.assigns.current_user.characters

    # Search for corporations
    result = search_corporation_names(user_chars, search)

    # Format the response
    response = case result do
      {:ok, results} ->
        %{results: results}
      _ ->
        %{results: []}
    end

    {:reply, response, socket}
  end

  # Handle UI events for getting alliance names
  def handle_ui_event("get_alliance_names", %{"search" => search}, socket) do
    # Get the current user's characters
    user_chars = socket.assigns.current_user.characters

    # Search for alliances
    result = search_alliance_names(user_chars, search)

    # Format the response
    response = case result do
      {:ok, results} ->
        %{results: results}
      _ ->
        %{results: []}
    end

    {:reply, response, socket}
  end

  # Handle UI events for getting corporation ticker
  def handle_ui_event("get_corporation_ticker", %{"corp_id" => corp_id}, socket) do
    case WandererApp.Esi.get_corporation_info(corp_id) do
      {:ok, %{"ticker" => ticker}} ->
        {:reply, %{ticker: ticker}, socket}

      error ->
        {:reply, %{ticker: nil}, socket}
    end
  end

  # Handle UI events for getting alliance ticker
  def handle_ui_event("get_alliance_ticker", %{"alliance_id" => alliance_id}, socket) do
    case WandererApp.Esi.get_alliance_info(alliance_id) do
      {:ok, %{"ticker" => ticker}} ->
        {:reply, %{ticker: ticker}, socket}

      error ->
        {:reply, %{ticker: nil}, socket}
    end
  end

  # Catch-all for UI events NOT handled by specific clauses above
  def handle_ui_event(event, params, socket) do
    Logger.warn("[MapSystemsEventHandler - UNMATCHED] Received event: #{inspect(event)}, Params: #{inspect(params)}, Assigns: #{inspect(socket.assigns)}")
    # Forward to the core event handler as a fallback
    MapCoreEventHandler.handle_ui_event(event, params, socket)
  end
end
