defmodule WandererAppWeb.CharacterActivity do
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

  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <.table id="activity-tbl" rows={@activity}>
        <:col :let={row} label="Character">
          <div class="flex items-center gap-2 whitespace-nowrap">
            <.character_item character={row.character} />
          </div>
        </:col>
        <:col :let={row} label="Connections">
          <%= Map.get(row, :connections, 0) %>
        </:col>
        <:col :let={row} label="Passages">
          <%= Map.get(row, :passages, 0) %>
        </:col>
        <:col :let={row} label="Signatures">
          <%= Map.get(row, :signatures, 0) %>
        </:col>
      </.table>
    </div>
    """
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
