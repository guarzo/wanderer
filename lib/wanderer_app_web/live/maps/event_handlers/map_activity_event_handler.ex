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
    with {:ok, passages} <- WandererApp.Api.MapChainPassages.get_passages_by_character(map_id),
         {:ok, activities} <-
           WandererApp.Api.UserActivity.base_activity_query(map_id)
           |> WandererApp.Api.read() do

      summaries = WandererApp.Api.UserActivity.merge_passages(activities, passages)
      {:ok, %{character_activity: summaries}}
    else
      error ->
        Logger.error("Failed to get activities: #{inspect(error)}")
        {:error, "Failed to get activities"}
    end
  end
end
