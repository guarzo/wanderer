defmodule WandererAppWeb.MapActivityEventHandler do
  @moduledoc """
  Handles events related to character activity in maps.
  """
  use WandererAppWeb, :live_component
  use Phoenix.Component
  require Logger

  alias WandererAppWeb.MapCoreEventHandler

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

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

  # Helper functions for formatting data
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
