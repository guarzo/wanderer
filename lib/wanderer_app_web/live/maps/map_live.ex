defmodule WandererAppWeb.MapLive do
  use WandererAppWeb, :live_view
  use LiveViewEvents
  require Logger

  alias WandererApp.Api.MapChainPassages
  alias WandererApp.Api.UserActivity
  alias WandererAppWeb.MapPicker
  alias WandererAppWeb.MapLoader

  @impl true
  def mount(%{"slug" => map_slug} = _params, _session, socket) when is_connected?(socket) do
    Process.send_after(self(), %{event: :load_map}, Enum.random(10..800))

    {:ok,
     socket
     |> assign(
       map_slug: map_slug,
       map_loaded?: false,
       server_online: false,
       selected_subscription: nil,
       user_permissions: nil,
       show_activity?: false,
       character_activity: []
     )
     |> push_event("js-exec", %{
       to: "#map-loader",
       attr: "data-loading",
       timeout: 2000
     })}
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       map_slug: nil,
       map_loaded?: false,
       server_online: false,
       selected_subscription: nil,
       user_permissions: nil,
       show_activity?: false,
       character_activity: []
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Always reset the show_activity? state when navigating
    socket = assign(socket, :show_activity?, false)

    # Then apply the action
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_info(
        {"change_map", map_slug},
        %{assigns: %{map_id: map_id}} = socket
      ) do
    Phoenix.PubSub.unsubscribe(WandererApp.PubSub, map_id)
    {:noreply, socket |> push_navigate(to: ~p"/#{map_slug}")}
  end

  @impl true
  def handle_info(:character_token_invalid, socket),
    do:
      {:noreply,
       socket
       |> put_flash(
         :error,
         "One of your characters has expired token. Please refresh it on characters page."
       )}

  def handle_info(:no_access, socket),
    do:
      {:noreply,
       socket
       |> put_flash(:error, "You don't have an access to this map.")
       |> push_navigate(to: ~p"/maps")}

  def handle_info(:no_permissions, socket),
    do:
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permissions to use this map.")
       |> push_navigate(to: ~p"/maps")}

  def handle_info(:not_all_characters_tracked, %{assigns: %{map_slug: map_slug}} = socket),
    do:
      WandererAppWeb.MapEventHandler.handle_ui_event(
        "add_character",
        nil,
        socket
        |> put_flash(
          :error,
          "You should enable tracking for all characters that have access to this map first!"
        )
        |> push_navigate(to: ~p"/tracking/#{map_slug}")
      )

  @impl true
  def handle_info(info, socket),
    do:
      {:noreply,
       socket
       |> WandererAppWeb.MapEventHandler.handle_event(info)}

  @impl true
  def handle_event("show_activity", _params, socket) do
    # Check if map_id is in the socket assigns
    if Map.has_key?(socket.assigns, :map_id) do
      # Get the map_id from the socket assigns
      map_id = socket.assigns.map_id

      # Fetch real activity data
      result = with {:ok, passages} <- WandererApp.Api.MapChainPassages.get_passages_by_character(map_id),
                    {:ok, activities} <-
                      WandererApp.Api.UserActivity.base_activity_query(map_id, 50_000, 720) # Last 30 days
                      |> WandererApp.Api.read() do

        # The merge_passages function now returns data in the correct format for the React component
        summaries = WandererApp.Api.UserActivity.merge_passages(activities, passages, nil)
        {:ok, summaries}
      end

      case result do
        {:ok, summaries} ->
          # Log the summaries for debugging
          Logger.info("Character activity summaries count: #{inspect(length(summaries))}")

          # Log a sample of the summaries
          if length(summaries) > 0 do
            Logger.info("Sample summary: #{inspect(Enum.at(summaries, 0), pretty: true)}")
          end

          # Ensure summaries is a list
          summaries = if is_list(summaries), do: summaries, else: []

          # Send the activity data to the client
          socket = socket
            |> assign(:character_activity, %{summaries: summaries})
            |> push_event("update_activity", %{activity: summaries})
          {:noreply, socket}
        _ ->
          # Handle error case
          socket = socket
            |> assign(:character_activity, %{summaries: []})
            |> push_event("update_activity", %{activity: []})
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("hide_activity", _params, socket) do
    {:noreply, assign(socket, :show_activity?, false)}
  end

  @impl true
  def handle_event("reset_activity_modal", _params, socket) do
    {:noreply, assign(socket, show_activity?: false)}
  end

  @impl true
  def handle_event(event, body, socket) do
    WandererAppWeb.MapEventHandler.handle_ui_event(event, body, socket)
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:active_page, :map)
    |> assign(:show_activity?, false)
  end
end
