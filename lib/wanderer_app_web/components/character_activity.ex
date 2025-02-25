defmodule WandererAppWeb.CharacterActivity do
  use WandererAppWeb, :live_component
  use LiveViewEvents
  require Logger

  @impl true
  def mount(socket) do
    {:ok, assign(socket, sort_by: :character_name, sort_dir: :asc)}
  end

  @impl true
  def update(assigns, socket) do
    Logger.info("CharacterActivity component received #{length(assigns.activity)} activity entries")

    # Log each character in the received activity
    Enum.each(assigns.activity, fn summary ->
      Logger.info("Activity entry received: #{summary.character.name} - Passages: #{summary.passages}, Connections: #{summary.connections}, Signatures: #{summary.signatures}")
    end)

    socket = assign(socket, assigns)
    sorted_activity = sort_activity(assigns.activity, socket.assigns.sort_by, socket.assigns.sort_dir)

    Logger.info("CharacterActivity component sorted #{length(sorted_activity)} activity entries")

    {:ok, assign(socket, sorted_activity: sorted_activity)}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4 h-[60vh] pr-4">
      <div id="activity-virtual-scroll" phx-hook="VirtualScroll" class="overflow-y-auto overflow-x-hidden h-full">
        <.table id="activity-tbl" rows={@sorted_activity} sort_by={@sort_by} sort_dir={@sort_dir} myself={@myself} class="relative">
          <:col :let={row} label="Character" sortable sort_by={:character_name}>
            <div class="flex items-center gap-2 whitespace-nowrap">
              <.character_item character={row.character} />
            </div>
          </:col>
          <:col :let={row} label="Passages" sortable sort_by={:passages} class="text-center">
            <%= Map.get(row, :passages, 0) %>
          </:col>
          <:col :let={row} label="Connections" sortable sort_by={:connections} class="text-center">
            <%= Map.get(row, :connections, 0) %>
          </:col>
          <:col :let={row} label="Signatures" sortable sort_by={:signatures} class="text-center">
            <%= Map.get(row, :signatures, 0) %>
          </:col>
        </.table>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    {sort_by, sort_dir} = get_sort_params(field, socket.assigns)
    sorted_activity = sort_activity(socket.assigns.activity, sort_by, sort_dir)

    {:noreply, assign(socket, sorted_activity: sorted_activity, sort_by: sort_by, sort_dir: sort_dir)}
  end

  defp get_sort_params(field, %{sort_by: current_field, sort_dir: current_dir}) do
    field = String.to_atom(field)
    case {field, current_field, current_dir} do
      {field, field, :asc} -> {field, :desc}
      _ -> {field, :asc}
    end
  end

  defp sort_activity(activity, :character_name, dir) do
    Enum.sort_by(activity, & &1.character.name, dir)
  end

  defp sort_activity(activity, field, dir) do
    Enum.sort_by(activity, &Map.get(&1, field, 0), dir)
  end

  def format_event_type(:map_connection_added), do: "Connection Added"
  def format_event_type(:jumps), do: "Passage"
  def format_event_type(:signatures_added), do: "Signatures Added"
  def format_event_type(type), do: type |> to_string() |> String.capitalize()

  def format_event_data(data) when is_map(data) do
    case data do
      %{"count" => count} -> "#{count} items"
      %{"source" => source, "target" => target} -> "#{source} → #{target}"
      %{"system" => system} -> "in #{system}"
      _ -> ""
    end
  end
  def format_event_data(_), do: ""

  def character_item(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <%= if @character.eve_id do %>
        <div class="avatar">
          <div class="rounded-md w-12 h-12">
            <img src={member_icon_url(@character.eve_id)} alt={@character.name} />
          </div>
        </div>
      <% else %>
        <div class="avatar placeholder">
          <div class="rounded-md w-12 h-12 bg-neutral-focus text-neutral-content">
            <span class="text-xl">T</span>
          </div>
        </div>
      <% end %>
      <%= @character.name %>
    </div>
    """
  end
end
