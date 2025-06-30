defmodule WandererAppWeb.Api.EventsController do
  @moduledoc """
  Controller for Server-Sent Events (SSE) streaming.

  Provides real-time event streaming for maps with support for:
  - Event filtering by type
  - Initial state delivery on connection
  - Historical event replay
  - Automatic reconnection support
  """

  use WandererAppWeb, :controller

  require Logger
  alias WandererApp.ExternalEvents.{EventFilter, SseConnectionTracker, SseStreamManager}
  alias WandererAppWeb.SSE
  alias WandererApp.Api

  # 30 seconds
  @keepalive_interval 30_000

  @doc """
  Establishes an SSE connection for streaming map events.

  Query parameters:
  - events: Comma-separated event types or "*" for all events
  - include_state: "true" to receive current state on connection
  - since: ULID to receive events after this ID
  - token: API authentication token (alternative to Bearer header)
  """
  def stream(conn, %{"map_identifier" => map_id} = params) do
    with {:ok, map} <- get_map(map_id),
         :ok <- authorize_map_access(conn, map),
         api_key <- get_api_key(conn),
         :ok <- SseConnectionTracker.check_limits(map.id, api_key) do
      # Parse event filter
      event_filter = EventFilter.parse(params["events"])

      # Track this connection
      SseConnectionTracker.track_connection(map.id, api_key, self())

      # Set up SSE headers
      conn = SSE.send_headers(conn)

      # Register with stream manager
      {:ok, _} = SseStreamManager.add_client(map.id, self(), event_filter)

      # Send initial state if requested
      conn =
        if params["include_state"] == "true" do
          send_initial_state(conn, map, event_filter)
        else
          conn
        end

      # Send historical events if requested
      conn =
        if params["since"] do
          send_historical_events(conn, map.id, params["since"], event_filter)
        else
          conn
        end

      # Enter streaming loop
      stream_events(conn, map.id, api_key)
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Map not found"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Unauthorized"})

      {:error, :map_connection_limit_exceeded} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Too many connections to this map"})

      {:error, :api_key_connection_limit_exceeded} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Too many connections for this API key"})
    end
  end

  # Private functions

  defp get_map(map_id) do
    # Try by ID first
    case Api.Map.by_id(map_id) do
      {:ok, map} ->
        {:ok, map}

      {:error, _} ->
        # Try by slug
        case Api.Map.get_map_by_slug(map_id) do
          {:ok, map} -> {:ok, map}
          {:error, _} -> {:error, :not_found}
        end
    end
  end

  defp authorize_map_access(conn, map) do
    # Check if the API key has access to this map
    api_key = get_api_key(conn)

    if api_key == map.public_api_key do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp get_api_key(conn) do
    # Get API key from assigns (set by ApiAuthPlug)
    conn.assigns[:api_key] || ""
  end

  defp send_initial_state(conn, map, event_filter) do
    Logger.debug("Sending initial state for map #{map.id}")

    conn =
      if :add_system in event_filter or :system_metadata_changed in event_filter do
        send_current_systems(conn, map)
      else
        conn
      end

    conn =
      if :connection_added in event_filter do
        send_current_connections(conn, map)
      else
        conn
      end

    conn =
      if :character_added in event_filter do
        send_current_characters(conn, map)
      else
        conn
      end

    conn
  end

  defp send_current_systems(conn, map) do
    {:ok, systems} = Api.MapSystem.read_all_by_map(map.id)

    Enum.reduce(systems, conn, fn system, conn ->
      event = %{
        id: Ulid.generate(),
        type: :add_system,
        map_id: map.id,
        ts: DateTime.utc_now() |> DateTime.to_iso8601(),
        payload: %{
          id: system.id,
          solar_system_id: system.solar_system_id,
          name: system.name,
          description: system.description,
          status: system.status,
          tag: system.tag,
          labels: system.labels,
          locked: system.locked,
          visible: system.visible,
          position_x: system.position_x,
          position_y: system.position_y
        },
        initial_state: true
      }

      case SSE.send_event(conn, event) do
        {:ok, conn} -> conn
        {:error, _} -> conn
      end
    end)
  end

  defp send_current_connections(conn, map) do
    {:ok, connections} = Api.MapConnection.read_by_map(map.id)

    Enum.reduce(connections, conn, fn connection, conn ->
      event = %{
        id: Ulid.generate(),
        type: :connection_added,
        map_id: map.id,
        ts: DateTime.utc_now() |> DateTime.to_iso8601(),
        payload: %{
          id: connection.id,
          from_solar_system_id: connection.from_solar_system_id,
          to_solar_system_id: connection.to_solar_system_id,
          mass_status: connection.mass_status,
          ship_size_type: connection.ship_size_type,
          locked: connection.locked,
          time_status: connection.time_status
        },
        initial_state: true
      }

      case SSE.send_event(conn, event) do
        {:ok, conn} -> conn
        {:error, _} -> conn
      end
    end)
  end

  defp send_current_characters(conn, map) do
    # Get tracked characters for this map
    {:ok, character_settings} = Api.MapCharacterSettings.tracked_by_map_all(map.id)

    # Get full character data for each tracked character
    character_ids = Enum.map(character_settings, & &1.character_id)

    characters =
      Enum.map(character_ids, fn char_id ->
        case Api.Character.by_eve_id(char_id) do
          {:ok, char} -> char
          _ -> nil
        end
      end)
      |> Enum.filter(& &1)

    Enum.reduce(characters, conn, fn character, conn ->
      # Get character's ready status
      ready = is_character_ready?(map, character.eve_id)

      event = %{
        id: Ulid.generate(),
        type: :character_added,
        map_id: map.id,
        ts: DateTime.utc_now() |> DateTime.to_iso8601(),
        payload: %{
          character_id: character.eve_id,
          character_name: character.name,
          online: character.online,
          location: %{
            solar_system_id: character.solar_system_id,
            solar_system_name: get_system_name(character.solar_system_id),
            station_id: character.station_id,
            structure_id: character.structure_id
          },
          ship: %{
            ship: character.ship,
            ship_name: character.ship_name,
            ship_item_id: character.ship_item_id
          },
          ready: ready,
          corporation: %{
            corporation_id: character.corporation_id,
            corporation_name: character.corporation_name,
            corporation_ticker: character.corporation_ticker
          },
          alliance:
            if character.alliance_id do
              %{
                alliance_id: character.alliance_id,
                alliance_name: character.alliance_name,
                alliance_ticker: character.alliance_ticker
              }
            else
              nil
            end
        },
        initial_state: true
      }

      case SSE.send_event(conn, event) do
        {:ok, conn} -> conn
        {:error, _} -> conn
      end
    end)
  end

  defp send_historical_events(conn, map_id, since_id, event_filter) do
    # Get events from MapEventRelay's ring buffer
    case WandererApp.ExternalEvents.MapEventRelay.get_events_since_ulid(map_id, since_id) do
      {:ok, events} ->
        # Filter and send events
        Enum.reduce(events, conn, fn event, conn ->
          if EventFilter.matches?(event.type, event_filter) do
            case SSE.send_event(conn, event) do
              {:ok, conn} -> conn
              {:error, _} -> conn
            end
          else
            conn
          end
        end)

      {:error, _} ->
        conn
    end
  end

  defp stream_events(conn, map_id, api_key) do
    receive do
      {:sse_event, event} ->
        case SSE.send_event(conn, event) do
          {:ok, conn} ->
            stream_events(conn, map_id, api_key)

          {:error, reason} ->
            Logger.debug("SSE send failed: #{inspect(reason)}")
            cleanup_connection(map_id, api_key)
        end

      :keepalive ->
        case SSE.send_keepalive(conn) do
          {:ok, conn} ->
            schedule_keepalive()
            stream_events(conn, map_id, api_key)

          {:error, reason} ->
            Logger.debug("SSE keepalive failed: #{inspect(reason)}")
            cleanup_connection(map_id, api_key)
        end
    after
      @keepalive_interval ->
        send(self(), :keepalive)
        stream_events(conn, map_id, api_key)
    end
  rescue
    error ->
      Logger.error("SSE stream error for map #{map_id}: #{inspect(error)}")
      cleanup_connection(map_id, api_key)
  end

  defp cleanup_connection(map_id, api_key) do
    SseStreamManager.remove_client(map_id, self())
    SseConnectionTracker.remove_connection(map_id, api_key, self())
  end

  defp schedule_keepalive do
    Process.send_after(self(), :keepalive, @keepalive_interval)
  end

  defp is_character_ready?(map, character_id) do
    # Get map options to check ready status
    case WandererApp.Map.get_options(map.id) do
      {:ok, options} when is_map(options) ->
        ready_characters = Map.get(options, "readyCharacters", [])
        character_id_str = to_string(character_id)
        character_id_str in ready_characters

      _ ->
        false
    end
  end

  defp get_system_name(nil), do: nil

  defp get_system_name(solar_system_id) do
    case WandererApp.CachedInfo.get_system_static_info(solar_system_id) do
      {:ok, info} -> info["name"]
      _ -> nil
    end
  end
end
