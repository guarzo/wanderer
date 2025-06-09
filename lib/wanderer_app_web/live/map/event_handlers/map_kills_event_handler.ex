defmodule WandererAppWeb.MapKillsEventHandler do
  @moduledoc """
  Handles kills-related UI/server events.
  Uses cache data populated by the WandererKills WebSocket service.
  """

  use WandererAppWeb, :live_component
  require Logger

  alias WandererAppWeb.{MapEventHandler, MapCoreEventHandler}

  defp get_detailed_kills_cache_key(map_id), do: "map_#{map_id}:zkb_detailed_kills"

  def handle_server_event(
        %{event: :init_kills},
        %{assigns: %{map_id: map_id}} = socket
      ) do
    # Get kill counts from cache
    case WandererApp.Map.get_map(map_id) do
      {:ok, %{systems: systems}} ->
        kill_counts =
          systems
          |> Enum.into(%{}, fn {solar_system_id, _system} ->
            kills_count = WandererApp.Cache.get("zkb_kills_#{solar_system_id}") || 0
            {solar_system_id, kills_count}
          end)
          |> Enum.filter(fn {_system_id, count} -> count > 0 end)
          |> Enum.into(%{})

        socket
        |> MapEventHandler.push_map_event(
          "map_updated",
          %{
            kills:
              kill_counts
              |> Enum.map(fn {system_id, kills} ->
                %{solar_system_id: system_id, kills: kills}
              end)
          }
        )

      _ ->
        socket
    end
  end

  def handle_server_event(%{event: :kills_updated, payload: kills}, socket) do
    kills =
      kills
      |> Enum.map(fn {system_id, count} ->
        %{solar_system_id: system_id, kills: count}
      end)

    socket
    |> MapEventHandler.push_map_event(
      "kills_updated",
      kills
    )
  end

  def handle_server_event(
        %{event: :detailed_kills_updated, payload: payload},
        %{
          assigns: %{
            map_id: map_id
          }
        } = socket
      ) do
    case WandererApp.Map.is_subscription_active?(map_id) do
      {:ok, true} ->
        socket
        |> MapEventHandler.push_map_event(
          "detailed_kills_updated",
          payload
        )

      _ ->
        socket
    end
  end

  def handle_server_event(
        %{event: :fetch_system_kills_error, payload: {system_id, reason}},
        socket
      ) do
    Logger.warning(
      "[#{__MODULE__}] fetch_kills_for_system failed for sid=#{system_id}: #{inspect(reason)}"
    )

    socket
  end

  def handle_server_event(%{event: :systems_kills_error, payload: {system_ids, reason}}, socket) do
    Logger.warning(
      "[#{__MODULE__}] fetch_kills_for_systems => error=#{inspect(reason)}, systems=#{inspect(system_ids)}"
    )

    socket
  end

  def handle_server_event(%{event: :system_kills_error, payload: {system_id, reason}}, socket) do
    Logger.warning(
      "[#{__MODULE__}] fetch_kills_for_system => error=#{inspect(reason)} for system=#{system_id}"
    )

    socket
  end

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

  def handle_ui_event(
        "get_system_kills",
        %{"system_id" => sid, "since_hours" => sh} = payload,
        socket
      ) do
    handle_get_system_kills(sid, sh, payload, socket)
  end

  def handle_ui_event(
        "get_systems_kills",
        %{"system_ids" => sids, "since_hours" => sh} = payload,
        socket
      ) do
    handle_get_systems_kills(sids, sh, payload, socket)
  end

  def handle_ui_event(event, payload, socket) do
    MapCoreEventHandler.handle_ui_event(event, payload, socket)
  end

  defp handle_get_system_kills(sid, sh, payload, socket) do
    with {:ok, system_id} <- parse_id(sid),
         {:ok, _since_hours} <- parse_id(sh) do
      # Read from local cache
      cached_map =
        WandererApp.Cache.get(get_detailed_kills_cache_key(socket.assigns.map_id)) || %{}

      cached_kills = Map.get(cached_map, system_id, [])

      reply_payload = %{"system_id" => system_id, "kills" => cached_kills}

      Logger.debug(fn ->
        "[#{__MODULE__}] get_system_kills => system_id=#{system_id}, cached_kills=#{length(cached_kills)}"
      end)

      {:reply, reply_payload, socket}
    else
      :error ->
        Logger.warning("[#{__MODULE__}] Invalid input to get_system_kills: #{inspect(payload)}")
        {:reply, %{"error" => "invalid_input"}, socket}
    end
  end

  defp handle_get_systems_kills(sids, sh, payload, socket) do
    with {:ok, _since_hours} <- parse_id(sh),
         {:ok, parsed_ids} <- parse_system_ids(sids) do
      Logger.debug(fn ->
        "[#{__MODULE__}] get_systems_kills => system_ids=#{inspect(parsed_ids)}"
      end)

      # Read from local cache
      cached_map =
        WandererApp.Cache.get(get_detailed_kills_cache_key(socket.assigns.map_id)) || %{}

      filtered_map = Map.take(cached_map, parsed_ids)

      reply_payload = %{"systems_kills" => filtered_map}

      Logger.debug(fn ->
        "[#{__MODULE__}] get_systems_kills => returning #{map_size(filtered_map)} systems from cache"
      end)

      {:reply, reply_payload, socket}
    else
      :error ->
        Logger.warning("[#{__MODULE__}] Invalid multiple-systems input: #{inspect(payload)}")
        {:reply, %{"error" => "invalid_input"}, socket}
    end
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
