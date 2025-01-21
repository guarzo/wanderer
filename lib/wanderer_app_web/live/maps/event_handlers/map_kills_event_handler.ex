defmodule WandererAppWeb.MapKillsEventHandler do
  @moduledoc """
  Handles kills-related UI/server events.
  """

  use WandererAppWeb, :live_component
  require Logger

  alias WandererAppWeb.MapCoreEventHandler
  alias WandererApp.Zkb.KillsProvider
  alias WandererApp.Zkb.KillsProvider.KillsCache

  @doc """
  Handles a 'server event' specific to kills operations
  """
  def handle_server_event(%{event: :detailed_kills_updated, payload: payload}, socket) do
    Phoenix.LiveView.push_event(socket, "detailed_kills_updated", payload)
  end

  def handle_server_event(%{event: :fetch_new_system_kills, payload: system}, socket) do
    solar_system_id = system.solar_system_id

    Task.async(fn ->
      case KillsProvider.Fetcher.fetch_kills_for_system(solar_system_id, 24, %{calls_count: 0}) do
        {:ok, kills, _state} ->
          {:detailed_kills_updated, %{solar_system_id => kills}}

        {:error, reason, _state} ->
          Logger.warning("[#{__MODULE__}] Failed to fetch kills for system=#{solar_system_id}: #{inspect(reason)}")
          {:fetch_system_kills_error, solar_system_id, reason}
      end
    end)

    socket
  end

  def handle_server_event(%{event: :fetch_new_map_kills, payload: %{map_id: map_id}}, socket) do
    Task.async(fn ->
      with {:ok, map_systems} <- WandererApp.MapSystemRepo.get_visible_by_map(map_id),
           system_ids         <- Enum.map(map_systems, & &1.solar_system_id),
           {:ok, systems_map} <-
             KillsProvider.Fetcher.fetch_kills_for_systems(system_ids, 24, %{calls_count: 0}) do
        {:detailed_kills_updated, systems_map}
      else
        {:error, reason} ->
          Logger.warning("[#{__MODULE__}] Failed to fetch kills for map=#{map_id}, reason=#{inspect(reason)}")
          {:fetch_map_kills_error, map_id, reason}
      end
    end)

    socket
  end

  @doc """
  Fallback for any unknown server event. If MapCoreEventHandler can handle it,
  delegate there, otherwise just return the socket unmodified.
  """
  def handle_server_event(event, socket) do
    updated_socket =
      case MapCoreEventHandler.handle_server_event(event, socket) do
        {:noreply, new_socket} ->
          new_socket

        {:reply, _payload, new_socket} ->
          new_socket

        new_socket when is_map(new_socket) ->
          new_socket
      end

    updated_socket
  end

  def handle_ui_event("get_system_kills", %{"system_id" => sid, "since_hours" => sh} = payload, socket) do
    with {:ok, system_id}   <- parse_id(sid),
         {:ok, since_hours} <- parse_id(sh) do
      # Pull from cache for immediate data
      kills_from_cache = KillsCache.fetch_cached_kills(system_id)
      reply_payload = %{"system_id" => system_id, "kills" => kills_from_cache}

      # Kick off async fetch so we can update the client if there are new kills
      Task.async(fn ->
        case KillsProvider.Fetcher.fetch_kills_for_system(system_id, since_hours, %{calls_count: 0}) do
          {:ok, fresh_kills, _new_state} ->
            {:detailed_kills_updated, %{system_id => fresh_kills}}

          {:error, reason, _new_state} ->
            Logger.warning("[#{__MODULE__}] fetch_kills_for_system => error=#{inspect(reason)}")
            {:system_kills_error, system_id, reason}
        end
      end)

      {:reply, reply_payload, socket}
    else
      :error ->
        Logger.warning("[#{__MODULE__}] Invalid input to get_system_kills: #{inspect(payload)}")
        {:reply, %{"error" => "invalid_input"}, socket}
    end
  end

  def handle_ui_event("get_systems_kills", %{"system_ids" => sids, "since_hours" => sh} = payload, socket) do
    with {:ok, since_hours} <- parse_id(sh),
         {:ok, parsed_ids}  <- parse_system_ids(sids) do
      # Build a quick response from cache
      cached_map =
        Enum.reduce(parsed_ids, %{}, fn sid, acc ->
          kills_list = KillsCache.fetch_cached_kills(sid)
          Map.put(acc, sid, kills_list)
        end)

      reply_payload = %{"systems_kills" => cached_map}

      # Kick off async fetch for fresh data
      Task.async(fn ->
        case KillsProvider.Fetcher.fetch_kills_for_systems(parsed_ids, since_hours, %{calls_count: 0}) do
          {:ok, systems_map} ->
            {:detailed_kills_updated, systems_map}

          {:error, reason} ->
            Logger.warning("[#{__MODULE__}] fetch_kills_for_systems => error=#{inspect(reason)}")
            {:systems_kills_error, parsed_ids, reason}
        end
      end)

      {:reply, reply_payload, socket}
    else
      :error ->
        Logger.warning("[#{__MODULE__}] Invalid multiple-systems input: #{inspect(payload)}")
        {:reply, %{"error" => "invalid_input"}, socket}
    end
  end

  def handle_ui_event(event, payload, socket) do
    MapCoreEventHandler.handle_ui_event(event, payload, socket)
  end

  def handle_info({ref, {:detailed_kills_updated, kills_map}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    # Push the updated kills info to the client
    Phoenix.LiveView.push_event(socket, "detailed_kills_updated", kills_map)

    {:noreply, socket}
  end

  # single system fetch error
  def handle_info({ref, {:fetch_system_kills_error, system_id, reason}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.warning("[#{__MODULE__}] fetch_kills_for_system failed for sid=#{system_id}: #{inspect(reason)}")
    {:noreply, socket}
  end

  # map fetch error
  def handle_info({ref, {:fetch_map_kills_error, map_id, reason}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.warning("[#{__MODULE__}] fetch_kills_for_map failed for map=#{map_id}: #{inspect(reason)}")
    {:noreply, socket}
  end

  # multiple systems kills error
  def handle_info({ref, {:systems_kills_error, system_ids, reason}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.warning("[#{__MODULE__}] fetch_kills_for_systems => error=#{inspect(reason)}, systems=#{inspect(system_ids)}")
    {:noreply, socket}
  end

  # single system kills error (from UI event)
  def handle_info({ref, {:system_kills_error, system_id, reason}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.warning("[#{__MODULE__}] fetch_kills_for_system => error=#{inspect(reason)} for system=#{system_id}")
    {:noreply, socket}
  end

  def handle_info(msg, socket) do
    Logger.debug("[#{__MODULE__}] Unexpected message received: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _         -> :error
    end
  end

  defp parse_id(value) when is_integer(value), do: {:ok, value}
  defp parse_id(_), do: :error

  defp parse_system_ids(ids) when is_list(ids) do
    parsed =
      Enum.reduce_while(ids, [], fn sid, acc ->
        case parse_id(sid) do
          {:ok, int_id} -> {:cont, [int_id | acc]}
          :error        -> {:halt, :error}
        end
      end)

    case parsed do
      :error -> :error
      list   -> {:ok, Enum.reverse(list)}
    end
  end

  defp parse_system_ids(_), do: :error
end
