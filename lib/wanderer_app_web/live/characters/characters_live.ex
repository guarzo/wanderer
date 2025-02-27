defmodule WandererAppWeb.CharactersLive do
  use WandererAppWeb, :live_view

  import Pathex
  alias BetterNumber, as: Number

  @impl true
  def mount(_params, %{"user_id" => user_id} = _session, socket)
      when not is_nil(user_id) do
    {:ok, characters} = WandererApp.Api.Character.active_by_user(%{user_id: user_id})

    # Subscribe to updates for each character
    characters
    |> Enum.map(& &1.id)
    |> Enum.each(fn character_id ->
      Phoenix.PubSub.subscribe(WandererApp.PubSub, "character:#{character_id}:alliance")
      Phoenix.PubSub.subscribe(WandererApp.PubSub, "character:#{character_id}:corporation")
      :ok = WandererApp.Character.TrackerManager.start_tracking(character_id)
    end)

    # Load the current user (assumes primary_character_id is set on the user struct)
    current_user = WandererApp.Api.User.by_id!(user_id)

    {:ok,
     socket
     |> assign(
       show_characters_add_alert: true,
       mode: :blocks,
       wallet_tracking_enabled?: WandererApp.Env.wallet_tracking_enabled?(),
       characters:
         characters
         |> Enum.sort_by(& &1.name, :asc)
         |> Enum.map(&map_ui_character(&1, current_user)),
       user_id: user_id,
       current_user: current_user
     )}
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, characters: [], user_id: nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("restore_show_characters_add_alert", %{"value" => value}, socket) do
    {:noreply, assign(socket, show_characters_add_alert: value)}
  end

  @impl true
  def handle_event("authorize", form, socket) do
    track_wallet = Map.get(form, "track_wallet", false)
    token = UUID.uuid4(:default)
    WandererApp.Cache.put("invite_#{token}", true, ttl: :timer.minutes(30))
    {:noreply, push_navigate(socket, to: ~p"/auth/eve?invite=#{token}&w=#{track_wallet}")}
  end

  @impl true
  def handle_event("delete", %{"character_id" => character_id}, socket) do
    socket.assigns.characters
    |> Enum.find(&(&1.id == character_id))
    |> WandererApp.Api.Character.mark_as_deleted!()

    {:ok, characters} =
      WandererApp.Api.Character.active_by_user(%{user_id: socket.assigns.user_id})

    {:noreply,
     assign(socket,
       characters: Enum.map(characters, &map_ui_character(&1, socket.assigns.current_user))
     )}
  end

  @impl true
  def handle_event("show_table", %{"value" => "on"}, socket) do
    {:noreply, assign(socket, mode: :table)}
  end

  @impl true
  def handle_event("show_table", _, socket) do
    {:noreply, assign(socket, mode: :blocks)}
  end

  @impl true
  def handle_event("set_primary", %{"character_id" => character_id}, socket) do
    user = socket.assigns.current_user

    case WandererApp.Api.User.set_primary_character(user, %{primary_character_id: character_id}) do
      {:ok, updated_user} ->

        {:ok, characters} =
          WandererApp.Api.Character.active_by_user(%{user_id: socket.assigns.user_id})

        updated_characters = Enum.map(characters, &map_ui_character(&1, updated_user))

        {:noreply,
         socket
         |> assign(current_user: updated_user, characters: updated_characters)
         |> put_flash(:info, "Primary character updated")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to set primary character: #{Kernel.inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:character_alliance, _update}, socket) do
    {:ok, characters} =
      WandererApp.Api.Character.active_by_user(%{user_id: socket.assigns.user_id})

    {:noreply,
     assign(socket,
       characters: Enum.map(characters, &map_ui_character(&1, socket.assigns.current_user))
     )}
  end

  @impl true
  def handle_info({:character_corporation, _update}, socket) do
    {:ok, characters} =
      WandererApp.Api.Character.active_by_user(%{user_id: socket.assigns.user_id})

    {:noreply,
     assign(socket,
       characters: Enum.map(characters, &map_ui_character(&1, socket.assigns.current_user))
     )}
  end

  @impl true
  def handle_info({:character_wallet_balance, _character_id}, socket) do
    {:ok, characters} =
      WandererApp.Api.Character.active_by_user(%{user_id: socket.assigns.user_id})

    {:noreply,
     assign(socket,
       characters: Enum.map(characters, &map_ui_character(&1, socket.assigns.current_user))
     )}
  end

  @impl true
  def handle_info({:character_activity, _update}, socket) do
    user_with_activities =
      socket.assigns.current_user
      |> Ash.load!([:combined_activities, characters: [:name]])

    {:noreply,
     socket
     |> assign(character_activity: user_with_activities.combined_activities)}
  end

  @impl true
  def handle_info(_event, socket) do
    {:noreply, socket}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(active_page: :characters)
    |> assign(page_title: "Characters")
  end

  defp apply_action(socket, :authorize, _params) do
    socket
    |> assign(active_page: :characters)
    |> assign(page_title: "Authorize Character - Characters")
    |> assign(form: to_form(%{"track_wallet" => false}))
  end

  # Updated to compare IDs as strings.
  defp map_ui_character(character, current_user) do
    can_track_wallet? = WandererApp.Character.can_track_wallet?(character)

    character
    |> Map.take([
      :id,
      :eve_id,
      :name,
      :corporation_id,
      :corporation_name,
      :corporation_ticker,
      :alliance_id,
      :alliance_name,
      :alliance_ticker
    ])
    |> Map.put(:primary, to_string(current_user.primary_character_id) == to_string(character.id))
    |> Map.put_new(:show_wallet_balance?, can_track_wallet?)
    |> maybe_add_wallet_balance(character, can_track_wallet?)
    |> Map.put_new(:ship, WandererApp.Character.get_ship(character))
    |> Map.put_new(:location, WandererApp.Character.get_location(character))
    |> Map.put_new(:invalid_token, is_nil(character.access_token))
  end

  defp maybe_add_wallet_balance(map, character, true) do
    case WandererApp.Character.can_track_wallet?(character) do
      true ->
        {:ok, %{eve_wallet_balance: eve_wallet_balance}} =
          character |> Ash.load([:eve_wallet_balance])

        Map.put_new(map, :eve_wallet_balance, eve_wallet_balance)

      _ ->
        Map.put_new(map, :eve_wallet_balance, 0.0)
    end
  end

  defp maybe_add_wallet_balance(map, _character, _can_track_wallet?),
    do: Map.put_new(map, :eve_wallet_balance, 0.0)

  defp reload_characters(socket) do
    case WandererApp.Api.Character.load_user_characters(
      socket.assigns.user_id,
      socket.assigns.current_user
    ) do
      {:ok, characters} -> assign(socket, characters: characters)
      _ -> socket
    end
  end
end
