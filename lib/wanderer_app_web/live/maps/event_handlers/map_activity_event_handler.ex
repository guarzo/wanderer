defmodule WandererAppWeb.MapActivityEventHandler do
  @moduledoc """
  Handles events related to character activity in maps.
  """
  use WandererAppWeb, :live_component
  use Phoenix.Component
  require Logger

  alias WandererAppWeb.MapCoreEventHandler

  def handle_server_event(
        %{
          event: :character_activity,
          payload: character_activity
        },
        socket
      ) do
    socket = socket |> assign(:character_activity, character_activity)

    if connected?(socket) do
      activity_data = cond do
        is_map(character_activity) && Map.has_key?(character_activity, :character_activity) ->
          character_activity.character_activity
        is_map(character_activity) && Map.has_key?(character_activity, :summaries) ->
          character_activity.summaries
        true ->
          character_activity
      end
      push_event(socket, "update_activity", %{activity: activity_data})
    else
      socket
    end
  end

  def handle_server_event(socket, :push_activity_data, %{summaries: summaries}) do
    if connected?(socket) do
      formatted_activity = Enum.map(summaries, fn summary ->
        %{
          character_name: summary.character.name,
          passages: format_passages(summary.passages),
          connections: format_connections(summary.connections),
          signatures: format_signatures(summary.signatures)
        }
      end)
      push_event(socket, "update_activity", %{activity: formatted_activity})
    end

    {:noreply, socket}
  end

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

  def handle_ui_event(
        %{
          event: "show_activity",
          payload: %{"character_id" => _character_id}
        },
        socket
      ) do
    socket = assign(socket, :show_activity?, true)
    Task.start(fn ->
      summaries = []

      formatted_activity = Enum.map(summaries, fn summary ->
        %{
          character_name: summary.character.name,
          passages: format_passages(summary.passages),
          connections: format_connections(summary.connections),
          signatures: format_signatures(summary.signatures)
        }
      end)
      send(self(), {:push_activity_data, %{summaries: formatted_activity}})
    end)

    socket
  end

  def handle_ui_event("hide_activity", _, socket) do
    {:noreply, socket |> assign(show_activity?: false)}
  end

  def handle_ui_event(event, body, socket),
    do: MapCoreEventHandler.handle_ui_event(event, body, socket)

  defp _get_character_activity(map_id, _current_user) do
    with {:ok, passages} <- WandererApp.Api.MapChainPassages.get_passages_by_character(map_id),
         {:ok, activities} <-
           WandererApp.Api.UserActivity.base_activity_query(map_id, 50_000, 720)
           |> WandererApp.Api.read() do
      summaries = WandererApp.Api.UserActivity.merge_passages(activities, passages, nil)
      {:ok, %{character_activity: summaries}}
    else
      error ->
        Logger.error("Failed to get activities: #{inspect(error)}")
        {:error, "Failed to get activities"}
    end
  end

  defp _typeof(term) when is_nil(term), do: "nil"
  defp _typeof(term) when is_binary(term), do: "binary"
  defp _typeof(term) when is_boolean(term), do: "boolean"
  defp _typeof(term) when is_number(term), do: "number"
  defp _typeof(term) when is_atom(term), do: "atom"
  defp _typeof(term) when is_list(term), do: "list"
  defp _typeof(term) when is_map(term), do: "map"
  defp _typeof(term) when is_tuple(term), do: "tuple"
  defp _typeof(term) when is_function(term), do: "function"
  defp _typeof(term) when is_pid(term), do: "pid"
  defp _typeof(term) when is_port(term), do: "port"
  defp _typeof(term) when is_reference(term), do: "reference"
  defp _typeof(_term), do: "unknown"

  defp format_passages(count) when is_integer(count) do
    ["#{count} passage(s) traveled"]
  end

  defp format_passages(passages) when is_list(passages) do
    passages
  end

  defp format_connections(count) when is_integer(count) do
    ["#{count} connection(s) created"]
  end

  defp format_connections(connections) when is_list(connections) do
    connections
  end

  defp format_signatures(count) when is_integer(count) do
    ["#{count} signature(s) scanned"]
  end

  defp format_signatures(signatures) when is_list(signatures) do
    signatures
  end
end
