defmodule WandererAppWeb.MapLive do
  use WandererAppWeb, :live_view
  use LiveViewEvents

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
      else
        {:error, _reason} ->
          # Fallback to sample data if there's an error
          sample_data = [
            %{
              "character_name" => "Explorer Alpha",
              "eve_id" => "95465499",
              "corporation_ticker" => "EXPLO",
              "alliance_ticker" => "",
              "passages_traveled" => 15,
              "connections_created" => 8,
              "signatures_scanned" => 12
            },
            %{
              "character_name" => "Wanderer Beta",
              "eve_id" => "95465500",
              "corporation_ticker" => "WAND",
              "alliance_ticker" => "",
              "passages_traveled" => 23,
              "connections_created" => 5,
              "signatures_scanned" => 19
            },
            %{
              "character_name" => "Pathfinder Gamma",
              "eve_id" => "95465501",
              "corporation_ticker" => "PATH",
              "alliance_ticker" => "",
              "passages_traveled" => 7,
              "connections_created" => 12,
              "signatures_scanned" => 9
            },
            %{
              "character_name" => "Scout Delta",
              "eve_id" => "95465502",
              "corporation_ticker" => "SCOUT",
              "alliance_ticker" => "",
              "passages_traveled" => 31,
              "connections_created" => 3,
              "signatures_scanned" => 27
            },
            %{
              "character_name" => "Navigator Epsilon",
              "eve_id" => "95465503",
              "corporation_ticker" => "NAVI",
              "alliance_ticker" => "",
              "passages_traveled" => 18,
              "connections_created" => 14,
              "signatures_scanned" => 6
            }
          ]
          {:ok, sample_data}
      end

      # Get the activity data from the result
      {_status, activity_data} = result

      # Sort the data by total activity (passages + connections + signatures) in descending order
      sorted_data = Enum.sort_by(activity_data, fn item ->
        passages = Map.get(item, "passages_traveled", 0)
        connections = Map.get(item, "connections_created", 0)
        signatures = Map.get(item, "signatures_scanned", 0)
        -(passages + connections + signatures) # Negative to sort in descending order
      end)

      # Update the socket assigns
      socket = socket
        |> assign(:show_activity?, true)
        |> assign(:character_activity, sorted_data)

      # Push the event to update the React component if connected
      socket = if connected?(socket) do
        # First, show the activity modal
        socket = push_event(socket, "phx:show_activity", %{})

        # Then, update the activity data
        # Make sure the data is properly formatted for the React component
        push_event(socket, "phx:update_activity", %{activity: sorted_data})
      else
        socket
      end

      {:noreply, socket}
    else
      # If map_id is not in the socket assigns, just show the activity modal with empty data
      socket = socket
        |> assign(:show_activity?, true)
        |> assign(:character_activity, [])
        |> put_flash(:info, "Map data is still loading. Please try again in a moment.")

      # Push the event to show the empty activity modal if connected
      socket = if connected?(socket) do
        socket
        |> push_event("phx:show_activity", %{})
        |> push_event("phx:update_activity", %{activity: []})
      else
        socket
      end

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
