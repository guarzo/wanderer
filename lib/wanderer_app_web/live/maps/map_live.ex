defmodule WandererAppWeb.MapLive do
  use WandererAppWeb, :live_view
  use LiveViewEvents

  require Logger

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
       user_permissions: nil
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
       user_permissions: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

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
  def handle_event(event, body, socket),
    do: WandererAppWeb.MapEventHandler.handle_ui_event(event, body, socket)

  def handle_info({:show_activity, _}, %{assigns: %{map_id: map_id}} = socket) do
    Logger.info("Show activity called for map #{map_id}")

    {:noreply,
     socket
     |> assign(:show_activity?, true)
     |> assign_async(:character_activity, fn ->
       Logger.info("Starting async activity load for map #{map_id}")
       with {:ok, passages} <- WandererApp.Api.MapChainPassages.get_passages_by_character(map_id),
            {:ok, activities} <-
              WandererApp.Api.UserActivity.base_activity_query(map_id)
              |> tap(fn query -> Logger.info("Activity query built: #{inspect(query)}") end)
              |> WandererApp.Api.read() do
         Logger.info("Got passages: #{inspect(passages)}")
         Logger.info("Got activities: #{inspect(activities)}")
         summaries = WandererApp.Api.UserActivity.merge_passages(activities, passages)
         Logger.info("Generated summaries: #{inspect(summaries)}")
         {:ok, summaries}
       else
         error ->
           Logger.error("Failed to get activities: #{inspect(error)}")
           {:error, "Failed to get activities"}
       end
     end)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:active_page, :map)
  end
end
