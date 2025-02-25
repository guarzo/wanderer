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

      push_event(socket, "update_activity", %{activity: activity_data})
    else
      socket
    end
  end

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

  def handle_ui_event(
        "show_activity",
        _,
        %{assigns: %{map_id: map_id, current_user: current_user}} = socket
      ) do
    Logger.info("Show activity UI event triggered for map #{map_id}")

    {:noreply,
     socket
     |> assign(:show_activity?, true)
     |> assign_async(:character_activity, fn ->
       get_character_activity(map_id, current_user)
     end)}
  end

  def handle_ui_event("hide_activity", _, socket) do
    Logger.info("Hide activity UI event triggered")
    {:noreply, socket |> assign(show_activity?: false)}
  end

  def handle_ui_event(event, body, socket),
    do: MapCoreEventHandler.handle_ui_event(event, body, socket)

  defp get_character_activity(map_id, _current_user) do
    # Use a 30-day window for activity to show more historical data
    hours_ago = 720  # 30 days * 24 hours

    Logger.info("Starting character activity retrieval for map #{map_id} with #{hours_ago} hours window")

    with {:ok, passages} <- WandererApp.Api.MapChainPassages.get_passages_by_character(map_id),
         {:ok, activities} <-
           WandererApp.Api.UserActivity.base_activity_query(map_id, 50_000, hours_ago)
           |> tap(fn query -> Logger.info("Activity query built: #{inspect(query)}") end)
           |> WandererApp.Api.read() do

      Logger.info("Retrieved #{map_size(passages)} passages and #{length(activities.results)} activities")

      # Pass nil as the limit to ensure all results are returned
      summaries = WandererApp.Api.UserActivity.merge_passages(activities, passages, nil)
      Logger.info("Final character activity summaries count: #{length(summaries)}")

      # Log each character in the final result
      Enum.each(summaries, fn summary ->
        Logger.info("Character in final result: #{summary.character.name} - Passages: #{summary.passages}, Connections: #{summary.connections}, Signatures: #{summary.signatures}")
      end)

      # Return a map with character_activity as the key instead of summaries
      {:ok, %{character_activity: summaries}}
    else
      error ->
        Logger.error("Failed to get activities: #{inspect(error)}")
        {:error, "Failed to get activities"}
    end
  end
end
