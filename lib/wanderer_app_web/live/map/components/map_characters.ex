defmodule WandererAppWeb.MapCharacters do
  use WandererAppWeb, :live_component
  use LiveViewEvents

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(
        assigns,
        socket
      ) do
    {:ok,
     socket
     |> handle_info_or_assign(assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <ul :for={group <- @groups} class="border-t border-b border-gray-200 py-0">
        <li :for={character <- group.characters}>
          <div class="flex items-center justify-between w-full space-x-2 p-1 hover:bg-gray-900">
            <.character_entry character={character} />

            <div class="flex items-center gap-2">
              <.link
                :if={has_auth_issue?(character.id)}
                href={~p"/auth/eve?return_to=/map"}
                class="btn btn-sm btn-warning py-1 flex items-center gap-1"
              >
                <.icon name="hero-key" class="h-4 w-4" /> Authenticate
              </.link>

              <button
                :if={character.tracked}
                phx-click="untrack"
                phx-value-event-data={character.id}
                class="btn btn-sm btn-icon py-1"
              >
                <.icon name="hero-eye-slash" class="h-5 w-5" /> Untrack
              </button>

              <span :if={not character.tracked} class="text-white rounded-full px-2">
                Viewer
              </span>
            </div>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  attr(:character, :any, required: true)

  defp character_entry(assigns) do
    ~H"""
    <div class="flex items-center gap-3 text-sm w-[450px]">
      <div class="flex flex-col p-4 items-center gap-2 tooltip tooltip-top" data-tip="Active from">
        <span class="text-green-500 rounded-full px-2 py-1 whitespace-nowrap">
          <.local_time id={@character.id} at={@character.from} />
        </span>
      </div>

      <div class="avatar">
        <div class="rounded-md w-8 h-8">
          <img src={member_icon_url(@character.eve_id)} alt={@character.name} />
        </div>
      </div>
      <span class="whitespace-nowrap">{@character.name}</span>
      <span :if={@character.alliance_ticker} class="whitespace-nowrap">
        [{@character.alliance_ticker}]
      </span>
      <span :if={@character.corporation_ticker} class="whitespace-nowrap">
        [{@character.corporation_ticker}]
      </span>

      <span :if={is_online?(@character.id)} class="text-green-500 rounded-full px-2 py-1">
        Online
      </span>
      <span :if={not is_online?(@character.id)} class="text-red-500 rounded-full px-2 py-1">
        Offline
      </span>

      <span :if={has_auth_issue?(@character.id)} class="text-orange-500 rounded-full px-2 py-1 tooltip tooltip-top" data-tip="Authentication required">
        <.icon name="hero-exclamation-triangle" class="h-4 w-4 inline" /> Auth Required
      </span>

      <span :if={@character.tracked} class="text-green-500 rounded-full px-2 py-1">
        Tracked
      </span>

      <span :if={not @character.tracked} class="text-red-500 rounded-full px-2 py-1 whitespace-nowrap">
        Not Tracked
      </span>
    </div>
    """
  end

  defp has_auth_issue?(character_id) do
    case WandererApp.Character.get_character_state(character_id) do
      {:ok, %{auth_invalid: flag}} -> flag
      _ -> false
    end
  end

  @impl true
  def handle_event("undo", %{"event-data" => _event_data} = _params, socket) do
    # notify_to(socket.assigns.notify_to, socket.assigns.event_name, map_slug)

    {:noreply, socket}
  end

  defp is_online?(character_id) do
    case WandererApp.Character.get_character_state(character_id) do
      {:ok, %{is_online: status}} -> status
      _ -> false
    end
  end
end
