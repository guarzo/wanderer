defmodule WandererAppWeb.MapActivityEventHandler do
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
      # Push the updated activity data to the React component
      # Ensure we're sending the data in the expected format
      activity_data = cond do
        is_map(character_activity) && Map.has_key?(character_activity, :character_activity) ->
          character_activity.character_activity
        is_map(character_activity) && Map.has_key?(character_activity, :summaries) ->
          character_activity.summaries
        true ->
          character_activity
      end

      # Log the activity data to help with debugging
      Logger.debug("Pushing activity data to client: #{inspect(activity_data, pretty: true, limit: 2)}")
      Logger.debug("Activity data type: #{inspect(typeof(activity_data))}")
      Logger.debug("Activity data length: #{inspect(length(activity_data))}")

      push_event(socket, "update_activity", %{activity: activity_data})
    else
      socket
    end
  end

  def handle_server_event(socket, :push_activity_data, %{summaries: summaries}) do
    Logger.debug("Handling push_activity_data event with #{length(summaries)} summaries")

    if connected?(socket) do
      # Format the activity data for the client
      formatted_activity = Enum.map(summaries, fn summary ->
        %{
          character_name: summary.character.name,
          passages: format_passages(summary.passages),
          connections: format_connections(summary.connections),
          signatures: format_signatures(summary.signatures)
        }
      end)

      Logger.debug("Pushing #{length(formatted_activity)} formatted activity items to client")
      push_event(socket, "update_activity", %{activity: formatted_activity})
    else
      Logger.debug("Socket not connected, not pushing activity data")
    end

    {:noreply, socket}
  end

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

  def handle_ui_event(
        %{
          event: "show_activity",
          payload: %{"character_id" => character_id}
        },
        socket
      ) do
    Logger.debug("Showing activity for character #{character_id}")

    # Assign show_activity? to true to show the modal
    socket = assign(socket, :show_activity?, true)

    # Load character activity data asynchronously
    Task.start(fn ->
      Logger.debug("Loading character activity data for #{character_id}")

      # Simulate loading character activity data
      # In a real application, this would call a function to load the data from the database
      Process.sleep(500)  # Simulate loading time

      # Create some sample activity data
      summaries = [
        %{
          character: %{name: "Character 1"},
          passages: 5,
          connections: 3,
          signatures: 2
        },
        %{
          character: %{name: "Character 2"},
          passages: 2,
          connections: 1,
          signatures: 4
        }
      ]

      # Format the activity data for the client
      formatted_activity = Enum.map(summaries, fn summary ->
        %{
          character_name: summary.character.name,
          passages: format_passages(summary.passages),
          connections: format_connections(summary.connections),
          signatures: format_signatures(summary.signatures)
        }
      end)

      Logger.debug("Formatted #{length(formatted_activity)} activity items")

      # Send a message to push the activity data to the client after a short delay
      # to ensure the modal is shown first
      Process.sleep(100)
      send(self(), {:push_activity_data, %{summaries: formatted_activity}})
    end)

    socket
  end

  def handle_ui_event("hide_activity", _, socket) do
    {:noreply, socket |> assign(show_activity?: false)}
  end

  def handle_ui_event(event, body, socket),
    do: MapCoreEventHandler.handle_ui_event(event, body, socket)

  defp get_character_activity(map_id, _current_user) do
    Logger.debug("Loading character activity data for map_id: #{map_id}, hours_ago: #{720}")

    with {:ok, passages} <- WandererApp.Api.MapChainPassages.get_passages_by_character(map_id),
         {:ok, activities} <-
           WandererApp.Api.UserActivity.base_activity_query(map_id, 50_000, 720)
           |> WandererApp.Api.read() do

      Logger.debug("Successfully loaded passages (#{map_size(passages)}) and activities (#{length(activities.results)})")

      # Pass nil as the limit to ensure all results are returned
      summaries = WandererApp.Api.UserActivity.merge_passages(activities, passages, nil)
      Logger.debug("Generated #{length(summaries)} activity summaries")

      # Return a map with character_activity as the key instead of summaries
      {:ok, %{character_activity: summaries}}
    else
      error ->
        Logger.error("Failed to get activities: #{inspect(error)}")
        {:error, "Failed to get activities"}
    end
  end

  # Helper function to get the type of a value
  defp typeof(term) when is_nil(term), do: "nil"
  defp typeof(term) when is_binary(term), do: "binary"
  defp typeof(term) when is_boolean(term), do: "boolean"
  defp typeof(term) when is_number(term), do: "number"
  defp typeof(term) when is_atom(term), do: "atom"
  defp typeof(term) when is_list(term), do: "list"
  defp typeof(term) when is_map(term), do: "map"
  defp typeof(term) when is_tuple(term), do: "tuple"
  defp typeof(term) when is_function(term), do: "function"
  defp typeof(term) when is_pid(term), do: "pid"
  defp typeof(term) when is_port(term), do: "port"
  defp typeof(term) when is_reference(term), do: "reference"
  defp typeof(_term), do: "unknown"

  # Helper functions to format the data
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
