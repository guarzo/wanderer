defmodule WandererAppWeb.MapKillsEventHandler do
  @moduledoc """
  Handles kills-related UI/server events.
  """

  use WandererAppWeb, :live_component
  require Logger

  alias WandererAppWeb.MapCoreEventHandler
  alias WandererApp.Zkb.KillsProvider
  alias WandererApp.Zkb.KillsProvider.KillsCache


  def handle_server_event(%{event: :detailed_kills_updated, payload: payload}, socket) do
    Phoenix.LiveView.push_event(socket, "detailed_kills_updated", payload)
  end

  def handle_server_event(%{event: :fetch_new_system_kills, payload: system}, socket) do
    parent_pid = self()
    ref = make_ref()

    Task.start(fn ->
      sid = system.solar_system_id
      case KillsProvider.Fetcher.fetch_kills_for_system(sid, 24, %{calls_count: 0}) do
        {:ok, kills, _state} ->
          kills_map = %{sid => kills}
          send(parent_pid, {ref, {:detailed_kills_updated, kills_map}})

        {:error, reason, _state} ->
          Logger.warning(
            "[MapKillsEventHandler] Failed to fetch kills for system=#{sid}: #{inspect(reason)}"
          )
      end
    end)

    socket
  end

  def handle_server_event(%{event: :fetch_new_map_kills, payload: %{map_id: map_id}}, socket) do
    parent_pid = self()
    ref = make_ref()

    Task.start(fn ->
      with {:ok, map_systems} <- WandererApp.MapSystemRepo.get_visible_by_map(map_id),
           system_ids <- Enum.map(map_systems, & &1.solar_system_id),
           {:ok, systems_map} <-
             KillsProvider.Fetcher.fetch_kills_for_systems(system_ids, 24, %{calls_count: 0})
      do
        send(parent_pid, {ref, {:detailed_kills_updated, systems_map}})
      else
        {:error, reason} ->
          Logger.warning(
            "[MapKillsEventHandler] Failed to fetch kills for map=#{map_id}, reason=#{inspect(reason)}"
          )
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
      kills_from_cache = KillsCache.fetch_cached_kills(system_id)
      reply_payload = %{"system_id" => system_id, "kills" => kills_from_cache}

      parent_pid = self()
      ref = make_ref()

      Task.start(fn ->
        case KillsProvider.Fetcher.fetch_kills_for_system(system_id, since_hours, %{calls_count: 0}) do
          {:ok, fresh_kills, _new_state} ->
            send(parent_pid, {ref, {:detailed_kills_updated, %{system_id => fresh_kills}}})

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
      cached_map =
        Enum.reduce(parsed_ids, %{}, fn sid, acc ->
          kills_list = KillsCache.fetch_cached_kills(sid)
          Map.put(acc, sid, kills_list)
        end)

      reply_payload = %{"systems_kills" => cached_map}

      parent_pid = self()
      ref = make_ref()

      Task.start(fn ->
        case KillsProvider.Fetcher.fetch_kills_for_systems(parsed_ids, since_hours, %{calls_count: 0}) do
          {:ok, systems_map} ->
            send(parent_pid, {ref, {:detailed_kills_updated, systems_map}})

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
