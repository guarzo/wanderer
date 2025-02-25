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
      ),
      do: socket |> assign(:character_activity, character_activity)

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

  def handle_ui_event(
        "show_activity",
        _,
        %{assigns: %{map_id: map_id, current_user: current_user}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:show_activity?, true)
     |> assign_async(:character_activity, fn ->
       get_character_activity(map_id, current_user)
     end)}
  end

  def handle_ui_event("hide_activity", _, socket),
    do: {:noreply, socket |> assign(show_activity?: false)}

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

      {:ok, %{character_activity: summaries}}
    else
      error ->
        Logger.error("Failed to get activities: #{inspect(error)}")
        {:error, "Failed to get activities"}
    end
  end
end
