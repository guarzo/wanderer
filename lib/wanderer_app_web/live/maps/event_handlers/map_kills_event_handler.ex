defmodule WandererAppWeb.MapKillsEventHandler do
  @moduledoc """
  Handles UI/Server events related to retrieving kills data.

  We now respond to UI events by returning only cached data immediately,
  then trigger an async fetch that broadcasts fresh kills if/when available.
  """

  use WandererAppWeb, :live_component
  use Phoenix.Component
  require Logger

  alias WandererAppWeb.MapCoreEventHandler
  alias WandererAppWeb.MapEventHandler
  alias WandererApp.Zkb.KillsProvider
  alias WandererApp.Zkb.KillsProvider.KillsCache

  def handle_server_event(%{event: :detailed_kills_updated, payload: payload}, socket) do
    socket = MapEventHandler.push_map_event(socket, "detailed_kills_updated", payload)
    socket
  end

  def handle_server_event(%{event: :fetch_new_system_kills, payload: system}, socket) do
    Task.start(fn ->
      sid = system.solar_system_id
      map_id = socket.assigns.map_id

      case KillsProvider.fetch_kills_for_system(sid, 24, %{calls_count: 0}) do
        {:ok, kills, _state} ->
          kills_map = %{sid => kills}
          Phoenix.PubSub.broadcast!(
            WandererApp.PubSub,
            map_id,
            %{event: :detailed_kills_updated, payload: kills_map}
          )

        {:error, reason, _state} ->
          Logger.warning(
            "[MapKillsEventHandler] Failed to fetch kills for system=#{sid}: #{inspect(reason)}"
          )
      end
    end)

    socket
  end

  def handle_server_event(%{event: :fetch_new_map_kills, payload: %{map_id: map_id}}, socket) do
    Task.start(fn ->
      case WandererApp.MapSystemRepo.get_visible_by_map(map_id) do
        {:ok, map_systems} ->
          system_ids = Enum.map(map_systems, & &1.solar_system_id)

          case KillsProvider.fetch_kills_for_systems(system_ids, 24, %{calls_count: 0}) do
            {:ok, systems_map} ->
              Phoenix.PubSub.broadcast!(
                WandererApp.PubSub,
                map_id,
                %{event: :detailed_kills_updated, payload: systems_map}
              )

            {:error, reason} ->
              Logger.warning(
                "[MapKillsEventHandler] Failed to fetch kills for map=#{map_id}, reason=#{inspect(reason)}"
              )
          end

        {:error, reason} ->
          Logger.warning("[MapKillsEventHandler] get_visible_by_map failed => #{inspect(reason)}")
      end
    end)

    socket
  end

  def handle_server_event(event, socket) do
    updated_socket =
      case MapCoreEventHandler.handle_server_event(event, socket) do
        {:noreply, new_socket} -> new_socket
        {:reply, _payload, new_socket} -> new_socket
        new_socket when is_map(new_socket) -> new_socket
      end

    updated_socket
  end

  def handle_ui_event("get_system_kills", %{"system_id" => sid, "since_hours" => sh} = payload, socket) do
    with {:ok, system_id} <- parse_id(sid),
         {:ok, since_hours} <- parse_id(sh) do
      # 1) Immediately reply with whatever is in the cache
      kills_from_cache = KillsCache.fetch_cached_kills(system_id)

      reply_payload = %{
        "system_id" => system_id,
        "kills" => kills_from_cache
      }

      # 2) Asynchronously fetch fresh kills, then broadcast results
      map_id = socket.assigns.map_id

      Task.start(fn ->
        case KillsProvider.fetch_kills_for_system(system_id, since_hours, %{calls_count: 0}) do
          {:ok, fresh_kills, _new_state} ->
            # Once we get new kills, broadcast them
            Phoenix.PubSub.broadcast!(
              WandererApp.PubSub,
              map_id,
              %{
                event: :detailed_kills_updated,
                payload: %{system_id => fresh_kills}
              }
            )

          {:error, reason, _new_state} ->
            Logger.warning("[MapKillsEventHandler] fetch_kills_for_system => error=#{inspect(reason)}")
        end
      end)

      {:reply, reply_payload, socket}
    else
      :error ->
        Logger.warning("[MapKillsEventHandler] Invalid input: #{inspect(payload)}")
        {:reply, %{"error" => "invalid_input"}, socket}
    end
  end

  def handle_ui_event("get_systems_kills", %{"system_ids" => sids, "since_hours" => sh} = payload, socket) do
    with {:ok, since_hours} <- parse_id(sh),
         {:ok, parsed_ids} <- parse_system_ids(sids) do

      # 1) Immediately gather cached kills for each system
      cached_map =
        parsed_ids
        |> Enum.reduce(%{}, fn sid, acc ->
          kills_list = KillsCache.fetch_cached_kills(sid)
          Map.put(acc, sid, kills_list)
        end)

      # 2) Reply with the cached data
      reply_payload = %{"systems_kills" => cached_map}

      # 3) Asynchronously do a fresh fetch, then broadcast
      map_id = socket.assigns.map_id

      Task.start(fn ->
        case KillsProvider.fetch_kills_for_systems(parsed_ids, since_hours, %{calls_count: 0}) do
          {:ok, systems_map} ->
            # Broadcast the newly fetched kills
            Phoenix.PubSub.broadcast!(
              WandererApp.PubSub,
              map_id,
              %{event: :detailed_kills_updated, payload: systems_map}
            )

          {:error, reason} ->
            Logger.warning("[MapKillsEventHandler] fetch_kills_for_systems => error=#{inspect(reason)}")
        end
      end)

      {:reply, reply_payload, socket}
    else
      :error ->
        Logger.warning("[MapKillsEventHandler] Invalid multiple-systems input: #{inspect(payload)}")
        {:reply, %{"error" => "invalid_input"}, socket}
    end
  end

  def handle_ui_event(event, payload, socket) do
    MapCoreEventHandler.handle_ui_event(event, payload, socket)
  end

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(value) when is_integer(value), do: {:ok, value}
  defp parse_id(_), do: :error

  defp parse_system_ids(ids) when is_list(ids) do
    parsed =
      Enum.reduce_while(ids, [], fn sid, acc ->
        case parse_id(sid) do
          {:ok, int_id} -> {:cont, [int_id | acc]}
          :error -> {:halt, :error}
        end
      end)

    case parsed do
      :error -> :error
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp parse_system_ids(_), do: :error
end
