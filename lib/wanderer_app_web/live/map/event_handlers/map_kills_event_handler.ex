defmodule WandererAppWeb.MapKillsEventHandler do
  @moduledoc """
  Handles kills-related UI and server events.
  """

  use WandererAppWeb, :live_component
  require Logger

  alias WandererAppWeb.{MapEventHandler, MapCoreEventHandler}
  alias WandererApp.Zkb.Provider.{Cache, Fetcher}

  # — Server events —

  def handle_server_event(%{event: :init_kills}, %{assigns: %{map_id: map_id}} = socket) do
    case Cache.get_map_kill_counts(map_id) do
      {:ok, kills_map} ->
        kills_map
        |> filter_positive_kills()
        |> Enum.map(&map_ui_kill/1)
        |> then(fn kills ->
          socket |> MapEventHandler.push_map_event("map_updated", %{kills: kills})
        end)
      {:error, reason} ->
        Logger.error("[MapKillsEventHandler] Failed to get kill counts: #{inspect(reason)}")
        socket
    end
  end

  def handle_server_event(%{event: :update_kills}, %{assigns: %{map_id: map_id}} = socket) do
    case Cache.get_map_kill_counts(map_id) do
      {:ok, kills_map} ->
        socket
        |> assign(kills_map: kills_map)
        |> MapEventHandler.push_map_event("kills_updated", normalize_items(kills_map))
      {:error, reason} ->
        Logger.error("[MapKillsEventHandler] Failed to get kill counts: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_server_event(%{event: :kills_updated, payload: payload}, socket) do
    payload
    |> normalize_items()
    |> then(&MapEventHandler.push_map_event(socket, "kills_updated", &1))
  end

  def handle_server_event(
        %{event: :detailed_kills_updated, payload: payload},
        %{assigns: %{map_id: map_id}} = socket
      ) do
    case WandererApp.Map.is_subscription_active?(map_id) do
      {:ok, true} ->
        processed =
          for {sid, items} <- payload, into: %{} do
            {sid, normalize_items(items)}
          end

        socket
        |> MapEventHandler.push_map_event("detailed_kills_updated", processed)

      _ ->
        socket
    end
  end

  def handle_server_event(%{event: event, payload: payload}, socket)
      when event in [
             :fetch_system_kills_error,
             :systems_kills_error,
             :system_kills_error
           ] do
    log_error(event, payload)
    socket
  end

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

  # — UI events —

  def handle_ui_event("get_system_kills", %{"system_id" => sid, "since_hours" => sh} = payload, socket) do
    with {:ok, system_id}   <- parse_id(sid),
         {:ok, since_hours} <- parse_id(sh) do
      reply = %{kills: Cache.get_killmails_for_system(system_id) || []}

      Task.Supervisor.async_nolink(WandererApp.TaskSupervisor, fn ->
        case Fetcher.fetch_killmails_for_system(system_id, since_hours: since_hours) do
          {:ok, fresh} ->
            {:detailed_kills_updated, %{system_id => fresh}}

          {:error, reason} ->
            Logger.warning(fn ->
              "[MapKillsEventHandler] fetch_kills_for_system => error=#{inspect(reason)}"
            end)

            {:system_kills_error, {system_id, reason}}
        end
      end)

      {:reply, reply, socket}
    else
      _ ->
        Logger.warning(fn ->
          "[MapKillsEventHandler] Invalid get_system_kills payload: #{inspect(payload)}"
        end)

        {:reply, %{kills: []}, socket}
    end
  end

  def handle_ui_event("get_systems_kills", %{"system_ids" => ids, "since_hours" => sh} = payload, socket) do
    with {:ok, system_ids}   <- parse_system_ids(ids),
         {:ok, since_hours} <- parse_id(sh),
         true                <- system_ids != [] do
      systems_kills =
        for id <- system_ids, into: %{} do
          case Fetcher.fetch_killmails_for_system(id, since_hours: since_hours) do
            {:ok, kills} -> {id, kills}
            {:error, reason} ->
              Logger.warning(fn ->
                "[MapKillsEventHandler] Failed to fetch kills for system #{id}: #{inspect(reason)}"
              end)

              {id, []}
          end
        end

      {:reply, %{systems_kills: systems_kills}, socket}
    else
      _ ->
        Logger.warning(fn ->
          "[MapKillsEventHandler] Invalid get_systems_kills payload: #{inspect(payload)}"
        end)

        {:reply, %{systems_kills: %{}}, socket}
    end
  end

  def handle_ui_event(event, payload, socket),
    do: MapCoreEventHandler.handle_ui_event(event, payload, socket)

  # — Private helpers —

  defp normalize_items(items) when is_list(items) do
    items
    |> Enum.map(&normalize_item/1)
    |> Enum.reject(&is_nil/1)
  end
  defp normalize_items(items) when is_map(items) do
    items
    |> Enum.reject(fn {_k, v} -> is_nil(normalize_item(v)) end)
    |> Enum.map(fn {k, v} -> {k, normalize_item(v)} end)
  end
  defp normalize_item({:ok, v}),        do: v
  defp normalize_item([ok: v]),          do: v
  defp normalize_item(v) when is_map(v), do: v
  defp normalize_item(_),                do: nil

  defp filter_positive_kills(%{} = km),
    do: Enum.filter(km, fn {_id, count} -> count > 0 end)

  defp log_error(:fetch_system_kills_error, {sid, reason}) do
    Logger.warning(
      "[#{__MODULE__}] fetch_kills_for_system failed for sid=#{sid}: #{inspect(reason)}"
    )
  end
  defp log_error(:systems_kills_error, {sids, reason}) do
    Logger.warning(
      "[#{__MODULE__}] fetch_kills_for_systems => error=#{inspect(reason)}, systems=#{inspect(sids)}"
    )
  end
  defp log_error(:system_kills_error, {sid, reason}) do
    Logger.warning(
      "[#{__MODULE__}] fetch_kills_for_system => error=#{inspect(reason)} for system=#{sid}"
    )
  end

  defp parse_id(val) when is_binary(val) do
    case Integer.parse(val) do
      {i, ""} -> {:ok, i}
      _       -> :error
    end
  end
  defp parse_id(val) when is_integer(val), do: {:ok, val}
  defp parse_id(_),                      do: :error

  # Rewritten to avoid a guard with an &-fun
  defp parse_system_ids(ids) when is_list(ids) do
    parsed = Enum.map(ids, &parse_id/1)

    if Enum.all?(parsed, fn
         {:ok, _} -> true
         _        -> false
       end) do
      {:ok, Enum.map(parsed, fn {:ok, i} -> i end)}
    else
      :error
    end
  end
  defp parse_system_ids(_), do: :error

  defp map_ui_kill({sid, kills}) when is_integer(sid) and is_integer(kills) do
    %{solar_system_id: sid, kills: kills}
  end
  defp map_ui_kill(_), do: %{}
end
