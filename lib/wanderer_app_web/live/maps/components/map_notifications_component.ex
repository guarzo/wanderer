defmodule WandererAppWeb.MapNotificationsComponent do
  @moduledoc """
  Settings tab for per-map Discord kill notifications.

  A map has one notification record and up to two destinations: a `:system`
  webhook (kills in systems on the map) and an optional `:character` webhook
  (kills involving characters tracked on the map). Each destination has its own
  URL, enable flag, delivery status and test button, because an owner needs to
  be able to diagnose one channel without touching the other.

  Webhook URLs are credentials: stored encrypted, only ever rendered as a masked
  hint with a replace flow, like a password field.
  """

  use WandererAppWeb, :live_component

  require Logger

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.Api.MapSolarSystem
  alias WandererApp.Esi.CorporationSearch

  @excluded_select_id "excluded_system_live_select_component"
  @focus_corp_select_id "focus_corp_live_select_component"
  @min_search_length 2
  @max_search_results 20

  @roles [:system, :character]

  @impl true
  def update(%{map_id: map_id} = assigns, socket) do
    notification =
      case MapDiscordNotification.by_map(map_id) do
        {:ok, rec} -> rec
        _ -> nil
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:excluded_select_id, @excluded_select_id)
     |> assign(:focus_corp_select_id, @focus_corp_select_id)
     |> assign(:min_search_length, @min_search_length)
     |> assign(:corp_min_search_length, CorporationSearch.min_search_length())
     |> assign_new(:system_options, fn -> [] end)
     |> assign_new(:corp_options, fn -> [] end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:flash_message, fn -> nil end)
     |> assign_notification(notification)}
  end

  @impl true
  def handle_event("save", %{"notification" => params}, socket) do
    # `.input type="checkbox"` renders a hidden "false" before the box, so a
    # rendered field always submits a value and Phoenix keeps the last one.
    attrs = %{
      wh_only: checked?(params["wh_only"]),
      enabled?: checked?(params["enabled"])
    }

    result =
      case socket.assigns.notification do
        nil ->
          create_with_system_webhook(socket.assigns.map_id, attrs, params["webhook_url"])

        rec ->
          # Deliberately NOT `webhook_url`: that moved to the child resource and
          # is no longer an accepted input here — passing it raises NoSuchInput
          # at runtime. URLs are saved through "save-webhook".
          MapDiscordNotification.update(rec, attrs)
      end

    case result do
      {:ok, rec} ->
        {:noreply,
         socket
         |> assign_notification(rec)
         |> assign(:error, nil)
         |> assign(:flash_message, "Saved.")}

      {:error, error} ->
        {:noreply, socket |> assign(:error, humanize_error(error)) |> assign(:flash_message, nil)}
    end
  end

  def handle_event("replace-url", %{"role" => role}, socket) do
    {:noreply, put_replacing(socket, parse_role(role), true)}
  end

  def handle_event("save-webhook", %{"role" => role, "webhook" => params}, socket) do
    role = parse_role(role)

    with %{} = rec <- socket.assigns.notification,
         {:ok, _} <- save_webhook(rec, socket.assigns.webhooks[role], role, params) do
      {:noreply,
       socket
       |> assign_notification(reload_notification(socket.assigns.map_id))
       |> assign(:error, nil)
       |> assign(:flash_message, "Saved.")}
    else
      {:error, error} ->
        {:noreply, socket |> assign(:error, humanize_error(error)) |> assign(:flash_message, nil)}

      _ ->
        {:noreply, assign(socket, :error, "Save the map's notification settings first.")}
    end
  end

  def handle_event("remove-webhook", %{"role" => role}, socket) do
    # Only the `:character` destination is removable. `:system` is required —
    # removing notifications entirely means deleting the parent record.
    role = parse_role(role)

    case {role, socket.assigns.webhooks[role]} do
      {:character, %{} = webhook} ->
        case MapDiscordWebhook.destroy(webhook) do
          :ok ->
            {:noreply,
             socket
             |> assign_notification(reload_notification(socket.assigns.map_id))
             |> assign(:error, nil)
             |> assign(:flash_message, "Character destination removed.")}

          {:error, error} ->
            {:noreply,
             socket |> assign(:error, humanize_error(error)) |> assign(:flash_message, nil)}
        end

      _ ->
        {:noreply, assign(socket, :error, "The system destination cannot be removed.")}
    end
  end

  # LiveSelect's search callback: users know systems and corporations by name,
  # not by numeric id.
  #
  # This must be handled HERE and not by the parent LiveView, whose own
  # `live_select_change` handler answers unconditionally with access-list
  # options. `phx-target={@myself}` on each live_select is what keeps the event
  # in this component.
  #
  # Two pickers now share this handler, so it MUST dispatch on the id that
  # fired. Answering unconditionally with system options would fill the
  # corporation dropdown with solar systems.
  def handle_event("live_select_change", %{"id" => @focus_corp_select_id, "text" => text}, socket) do
    options = search_corporations(socket.assigns[:current_user], text)

    send_update(LiveSelect.Component, id: @focus_corp_select_id, options: options)

    {:noreply, assign(socket, :corp_options, options)}
  end

  def handle_event("live_select_change", %{"id" => id, "text" => text}, socket) do
    options = search_systems(text)

    send_update(LiveSelect.Component, id: id, options: options)

    {:noreply, assign(socket, :system_options, options)}
  end

  def handle_event("add-excluded", %{"excluded" => %{"excluded_system" => raw}}, socket) do
    with %{} = rec <- socket.assigns.notification,
         {id, ""} <- Integer.parse(to_string(raw)) do
      update_excluded(socket, rec, Enum.uniq([id | rec.excluded_systems]))
    else
      _ -> {:noreply, assign(socket, :error, "Pick a system from the list.")}
    end
  end

  # Guarded the same way as `add-excluded`: only reachable from a rendered
  # button today, but the two handlers should not disagree about whether a
  # missing record or a non-numeric id is survivable.
  def handle_event("remove-excluded", %{"system_id" => raw}, socket) do
    with %{} = rec <- socket.assigns.notification,
         {id, ""} <- Integer.parse(to_string(raw)) do
      update_excluded(socket, rec, Enum.reject(rec.excluded_systems, &(&1 == id)))
    else
      _ -> {:noreply, assign(socket, :error, "Could not remove that system.")}
    end
  end

  # Guarded the same way as `add-excluded`: only reachable from a rendered
  # record, and only for an id that parses cleanly. LiveSelect hands back the
  # corporation eve id as a STRING (`character.ex:365`), while `focus_corp_ids`
  # stores integers.
  def handle_event("add-focus-corp", %{"focus_corp" => %{"focus_corp" => raw}}, socket) do
    with %{} = rec <- socket.assigns.notification,
         {id, ""} <- Integer.parse(to_string(raw)) do
      update_focus_corps(socket, rec, Enum.uniq(rec.focus_corp_ids ++ [id]))
    else
      _ -> {:noreply, assign(socket, :error, "Pick a corporation from the list.")}
    end
  end

  def handle_event("remove-focus-corp", %{"corp_id" => raw}, socket) do
    with %{} = rec <- socket.assigns.notification,
         {id, ""} <- Integer.parse(to_string(raw)) do
      update_focus_corps(socket, rec, Enum.reject(rec.focus_corp_ids, &(&1 == id)))
    else
      _ -> {:noreply, assign(socket, :error, "Could not remove that corporation.")}
    end
  end

  def handle_event("send-test", %{"webhook_id" => webhook_id}, socket) do
    case send_test(socket, webhook_id) do
      # `:ok` means the message was ENQUEUED — the last hop is an async cast, so
      # this must not claim Discord accepted it.
      :ok ->
        {:noreply,
         socket |> assign(:flash_message, "Test message queued.") |> assign(:error, nil)}

      {:error, :notifications_disabled} ->
        {:noreply,
         socket
         |> assign(
           :error,
           "Discord notifications are disabled on this server. Ask an administrator to enable them."
         )
         |> assign(:flash_message, nil)}

      {:error, :webhook_disabled} ->
        {:noreply,
         socket
         |> assign(
           :error,
           "This destination is disabled. Enable it and save before sending a test message."
         )
         |> assign(:flash_message, nil)}

      {:error, :not_configured} ->
        {:noreply,
         socket |> assign(:error, "Save a webhook URL first.") |> assign(:flash_message, nil)}

      {:error, other} ->
        {:noreply,
         socket
         |> assign(:error, "Could not send a test message: #{inspect(other)}")
         |> assign(:flash_message, nil)}
    end
  end

  def handle_event("delete", _params, socket) do
    case socket.assigns.notification do
      nil ->
        {:noreply, socket}

      rec ->
        # The resource's custom destroy invalidates the config cache and stops
        # the delivery workers; the webhook children cascade with the parent.
        case Ash.destroy(rec) do
          :ok ->
            {:noreply,
             socket
             |> assign_notification(nil)
             |> assign(:error, nil)
             |> assign(:flash_message, "Removed.")}

          {:error, error} ->
            {:noreply,
             socket |> assign(:error, humanize_error(error)) |> assign(:flash_message, nil)}
        end
    end
  end

  # `send_test_message/1` collapses "no such webhook", "no URL" and "this
  # destination is disabled" into a single `:not_configured`, whose copy ("Save
  # a webhook URL first.") is a lie for a saved-but-disabled destination. The
  # component already knows which webhook the button belongs to, so it separates
  # the disabled case here rather than widening the dispatcher's return type.
  defp send_test(socket, webhook_id) do
    disabled? =
      socket.assigns.webhooks
      |> Map.values()
      |> Enum.any?(&match?(%{id: ^webhook_id, enabled?: false}, &1))

    if disabled? do
      {:error, :webhook_disabled}
    else
      WandererApp.ExternalEvents.DiscordDispatcher.send_test_message(webhook_id)
    end
  end

  defp save_webhook(rec, nil, role, %{"webhook_url" => url}) when is_binary(url) and url != "" do
    MapDiscordWebhook.create(%{notification_id: rec.id, role: role, webhook_url: url})
  end

  defp save_webhook(_rec, nil, _role, _params), do: {:error, "Enter a webhook URL first."}

  defp save_webhook(_rec, webhook, _role, %{"webhook_url" => url} = params)
       when is_binary(url) and url != "" do
    MapDiscordWebhook.update(webhook, %{
      webhook_url: url,
      enabled?: checked?(params["enabled"])
    })
  end

  defp save_webhook(_rec, webhook, _role, params) do
    MapDiscordWebhook.set_enabled(webhook, %{enabled?: checked?(params["enabled"])})
  end

  # Creating the config and its required `:system` destination is one user
  # action. Task 2's `create` takes `webhook_url` as a required argument and
  # creates the `:system` child through `manage_relationship` in the SAME
  # transaction, so there is no window in which a parent exists without a
  # destination. Do not split this into two calls with a compensating cleanup:
  # the two-step version fails outright (`create` rejects a missing
  # `webhook_url`) and its explicit child create would collide with Task 1's
  # (notification_id, role) identity.
  defp create_with_system_webhook(map_id, attrs, url) do
    attrs
    |> Map.put(:map_id, map_id)
    |> Map.put(:webhook_url, url)
    |> MapDiscordNotification.create()
  end

  defp put_replacing(socket, role, value) do
    assign(socket, :replacing_url?, Map.put(socket.assigns.replacing_url?, role, value))
  end

  defp parse_role("character"), do: :character
  defp parse_role(:character), do: :character
  defp parse_role(_), do: :system

  defp reload_notification(map_id) do
    case MapDiscordNotification.by_map(map_id) do
      {:ok, rec} -> rec
      _ -> nil
    end
  end

  defp update_excluded(socket, rec, excluded) do
    case MapDiscordNotification.update(rec, %{excluded_systems: excluded}) do
      {:ok, updated} ->
        {:noreply, socket |> assign_notification(updated) |> assign(:error, nil)}

      {:error, error} ->
        {:noreply, assign(socket, :error, humanize_error(error))}
    end
  end

  defp update_focus_corps(socket, rec, corp_ids) do
    case MapDiscordNotification.update(rec, %{focus_corp_ids: corp_ids}) do
      {:ok, updated} ->
        {:noreply, socket |> assign_notification(updated) |> assign(:error, nil)}

      {:error, error} ->
        {:noreply, assign(socket, :error, humanize_error(error))}
    end
  end

  # Resolves excluded-system names and focus-corporation labels once per change,
  # not once per render: both run lookups, and the template re-renders on every
  # live_select keystroke. Also rebuilds every form so values follow the record.
  defp assign_notification(socket, notification) do
    webhooks = load_webhooks(notification)

    socket
    |> assign(:notification, notification)
    |> assign(:webhooks, webhooks)
    |> assign(:excluded_systems, excluded_system_labels(notification))
    |> assign(:focus_corps, focus_corp_labels(notification))
    |> assign(:form, notification_form(notification))
    |> assign(:webhook_forms, webhook_forms(webhooks))
    |> assign(:excluded_form, to_form(%{"excluded_system" => nil}, as: :excluded))
    |> assign(:focus_corp_form, to_form(%{"focus_corp" => nil}, as: :focus_corp))
    |> assign_replacing(webhooks)
  end

  # A destination with no stored URL is always in "replace" (i.e. entry) mode;
  # one with a URL starts masked. Recomputed on every record change so that
  # saving a URL collapses the field back to the masked hint.
  defp assign_replacing(socket, webhooks) do
    replacing =
      Map.new(@roles, fn role ->
        {role, is_nil(Map.get(webhooks, role))}
      end)

    assign(socket, :replacing_url?, replacing)
  end

  defp load_webhooks(nil), do: %{system: nil, character: nil}

  defp load_webhooks(%{id: notification_id}) do
    records =
      case MapDiscordWebhook.by_notification(notification_id) do
        {:ok, list} -> list
        _ -> []
      end

    Map.new(@roles, fn role -> {role, Enum.find(records, &(&1.role == role))} end)
  end

  defp notification_form(notification) do
    to_form(
      %{
        "webhook_url" => "",
        "wh_only" => is_nil(notification) or notification.wh_only,
        "enabled" => is_nil(notification) or notification.enabled?
      },
      as: :notification
    )
  end

  defp webhook_forms(webhooks) do
    Map.new(@roles, fn role ->
      webhook = Map.get(webhooks, role)

      form =
        to_form(
          %{
            "webhook_url" => "",
            "enabled" => is_nil(webhook) or webhook.enabled?
          },
          as: :webhook
        )

      {role, form}
    end)
  end

  # Mirrors the ACL live_select pattern in maps_live: search server-side, feed
  # `{label, value}` options back into the component.
  defp search_systems(text) when is_binary(text) and byte_size(text) >= @min_search_length do
    case MapSolarSystem.find_by_name(%{name: text}) do
      {:ok, systems} ->
        systems
        |> Enum.take(@max_search_results)
        |> Enum.map(&{"#{&1.solar_system_name} (#{&1.region_name})", &1.solar_system_id})

      _ ->
        []
    end
  end

  defp search_systems(_), do: []

  # `CorporationSearch.search/2` enforces its own minimum length and returns
  # `{:ok, []}` for a user with no characters, so no length guard is needed here.
  #
  # The rescue is not belt-and-braces: the search runs as one of the user's
  # characters, and a character whose ESI token has never been refreshed makes
  # `Character.search/2` raise. Unrescued that kills the LiveView on a keystroke
  # in the corporation box, taking the whole settings tab with it. An empty
  # dropdown is the right degradation for a lookup this component cannot fix.
  defp search_corporations(%{characters: characters}, text) when is_list(characters) do
    case CorporationSearch.search(characters, text) do
      {:ok, results} ->
        results
        |> Enum.take(@max_search_results)
        |> Enum.map(&{&1.formatted, &1.id})

      _ ->
        []
    end
  rescue
    error ->
      Logger.warning("[MapNotifications] corporation search failed: #{inspect(error)}")
      []
  end

  defp search_corporations(_current_user, _text), do: []

  # One query for every excluded system, not one per system. Falls back to the
  # bare id for anything the lookup did not return, and keeps the stored order.
  defp excluded_system_labels(nil), do: []
  defp excluded_system_labels(%{excluded_systems: []}), do: []

  defp excluded_system_labels(%{excluded_systems: ids}) do
    labels =
      case MapSolarSystem.by_solar_system_ids(ids) do
        {:ok, systems} ->
          Map.new(
            systems,
            &{&1.solar_system_id, "#{&1.solar_system_name} (#{&1.solar_system_id})"}
          )

        _ ->
          %{}
      end

    Enum.map(ids, &{&1, Map.get(labels, &1, to_string(&1))})
  end

  # `label_for/1` already degrades to the bare id, so a chip is never dropped
  # because ESI is unreachable — the user must always be able to remove what
  # they saved.
  defp focus_corp_labels(nil), do: []
  defp focus_corp_labels(%{focus_corp_ids: []}), do: []

  defp focus_corp_labels(%{focus_corp_ids: ids}),
    do: Enum.map(ids, &{&1, CorporationSearch.label_for(&1)})

  defp checked?("true"), do: true
  defp checked?(true), do: true
  defp checked?(_), do: false

  defp humanize_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", fn
      %{message: message} when is_binary(message) -> message
      other -> inspect(other)
    end)
  end

  defp humanize_error(other), do: inspect(other)

  defp masked_url(nil), do: ""

  defp masked_url(url) when is_binary(url) do
    case String.split(url, "/", trim: true) do
      parts when length(parts) >= 2 ->
        [token, id | _] = Enum.reverse(parts)
        ".../#{id}/#{String.slice(token, 0, 4)}••••"

      _ ->
        "••••"
    end
  end

  defp masked_url(_), do: "••••"

  attr :role, :atom, required: true
  attr :title, :string, required: true
  attr :help, :string, required: true
  attr :webhook, :any, required: true
  attr :form, :any, required: true
  attr :replacing?, :boolean, required: true
  attr :removable?, :boolean, required: true
  attr :myself, :any, required: true

  defp webhook_row(assigns) do
    ~H"""
    <div id={"webhook-row-#{@role}"} class="flex flex-col gap-2 rounded border border-white/10 p-3">
      <h4 class="text-sm font-semibold">{@title}</h4>
      <p class="text-xs opacity-70">{@help}</p>

      <.form
        :let={wf}
        for={@form}
        id={"webhook-form-#{@role}"}
        phx-submit="save-webhook"
        phx-value-role={@role}
        phx-target={@myself}
        class="flex flex-col gap-2"
      >
        <.input
          :if={@replacing?}
          field={wf[:webhook_url]}
          type="password"
          label="Discord webhook URL"
          placeholder="https://discord.com/api/webhooks/..."
          autocomplete="off"
        />

        <div :if={!@replacing? && @webhook} class="flex items-center gap-2">
          <span class="text-sm opacity-70">URL: {masked_url(@webhook.webhook_url)}</span>
          <.button type="button" phx-click="replace-url" phx-value-role={@role} phx-target={@myself}>
            Replace
          </.button>
        </div>

        <.input :if={@webhook} field={wf[:enabled]} type="checkbox" label="Enabled" />

        <.button type="submit">{if @webhook, do: "Save", else: "Add"}</.button>
      </.form>

      <div :if={@webhook} class="flex items-center gap-2">
        <.button
          type="button"
          phx-click="send-test"
          phx-value-webhook_id={@webhook.id}
          phx-target={@myself}
        >
          Send test message
        </.button>
        <.button
          :if={@removable?}
          type="button"
          class="btn-error"
          phx-click="remove-webhook"
          phx-value-role={@role}
          phx-target={@myself}
          data-confirm="Remove this Discord destination?"
        >
          Remove
        </.button>
      </div>

      <div :if={@webhook} class="flex flex-col gap-1 text-sm">
        <span :if={@webhook.last_delivery_at} class="opacity-70">
          Last delivered: {Calendar.strftime(@webhook.last_delivery_at, "%Y-%m-%d %H:%M UTC")}
        </span>
        <span :if={is_nil(@webhook.last_delivery_at)} class="opacity-70">
          No kills delivered yet.
        </span>

        <span :if={@webhook.last_error} class="text-amber-400">
          Last error: {@webhook.last_error}
          <span :if={@webhook.consecutive_failures > 0}>
            ({@webhook.consecutive_failures} consecutive failures)
          </span>
        </span>
        <span :if={!@webhook.enabled?} class="text-amber-400">
          This destination is disabled and is not delivering.
        </span>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-4">
      <p class="text-sm opacity-70">
        Posts kills to Discord. These filters are separate from the Kills widget's
        own filters, which are per-user and only affect what you see in the map UI.
      </p>

      <p :if={@error} class="text-sm text-red-400">{@error}</p>
      <p :if={@flash_message} class="text-sm text-green-400">{@flash_message}</p>

      <.form
        :let={f}
        for={@form}
        id="discord-notification-form"
        phx-submit="save"
        phx-target={@myself}
        class="flex flex-col gap-3"
      >
        <.input
          :if={is_nil(@notification)}
          field={f[:webhook_url]}
          type="password"
          label="Discord webhook URL (system channel)"
          placeholder="https://discord.com/api/webhooks/..."
          autocomplete="off"
        />

        <.input field={f[:wh_only]} type="checkbox" label="Only wormhole kills" />
        <.input field={f[:enabled]} type="checkbox" label="Enabled for this map" />

        <.button type="submit">Save</.button>
      </.form>

      <.webhook_row
        :if={@notification}
        role={:system}
        title="System channel"
        help="Receives kills that happen in systems on this map."
        webhook={@webhooks[:system]}
        form={@webhook_forms[:system]}
        replacing?={@replacing_url?[:system]}
        removable?={false}
        myself={@myself}
      />

      <.webhook_row
        :if={@notification}
        role={:character}
        title="Character channel (optional)"
        help={
          "Receives kills involving characters tracked on this map, wherever they happen. " <>
            "Leave it unset and those kills go to the system channel instead."
        }
        webhook={@webhooks[:character]}
        form={@webhook_forms[:character]}
        replacing?={@replacing_url?[:character]}
        removable?={true}
        myself={@myself}
      />

      <div :if={@notification} class="flex flex-col gap-2">
        <h4 class="text-sm font-semibold">Excluded systems</h4>

        <ul class="flex flex-col gap-1">
          <li :for={{system_id, label} <- @excluded_systems} class="flex items-center gap-2 text-sm">
            <span>{label}</span>
            <.button
              type="button"
              phx-click="remove-excluded"
              phx-value-system_id={system_id}
              phx-target={@myself}
            >
              Remove
            </.button>
          </li>
        </ul>

        <.form
          :let={ef}
          for={@excluded_form}
          id="excluded-system-form"
          phx-submit="add-excluded"
          phx-target={@myself}
          class="grid items-end gap-2"
          style="grid-template-columns: 1fr auto"
        >
          <.live_select
            field={ef[:excluded_system]}
            id={@excluded_select_id}
            phx-target={@myself}
            dropdown_extra_class="!h-24"
            debounce={250}
            update_min_len={@min_search_length}
            mode={:single}
            options={@system_options}
            placeholder="Search a system by name"
          />
          <.button type="submit">Add</.button>
        </.form>
      </div>

      <div :if={@notification} class="flex flex-col gap-2">
        <h4 class="text-sm font-semibold">Focus corporations</h4>
        <p class="text-xs opacity-70">
          Kills involving these corporations are treated as relevant even when the
          system or wormhole-only filters would otherwise drop them.
        </p>

        <ul class="flex flex-wrap gap-2">
          <li
            :for={{corp_id, label} <- @focus_corps}
            class="flex items-center gap-2 rounded-full bg-white/10 px-3 py-1 text-sm"
          >
            <span>{label}</span>
            <.button
              type="button"
              phx-click="remove-focus-corp"
              phx-value-corp_id={corp_id}
              phx-target={@myself}
            >
              Remove
            </.button>
          </li>
        </ul>

        <p :if={@current_user.characters in [nil, []]} class="text-sm text-amber-400">
          Add a character to this account to search corporations.
        </p>

        <.form
          :let={cf}
          :if={@current_user.characters not in [nil, []]}
          for={@focus_corp_form}
          id="focus-corp-form"
          phx-submit="add-focus-corp"
          phx-target={@myself}
          class="grid items-end gap-2"
          style="grid-template-columns: 1fr auto"
        >
          <.live_select
            field={cf[:focus_corp]}
            id={@focus_corp_select_id}
            phx-target={@myself}
            dropdown_extra_class="!h-24"
            debounce={250}
            update_min_len={@corp_min_search_length}
            mode={:single}
            options={@corp_options}
            placeholder="Search a corporation by name"
          />
          <.button type="submit">Add</.button>
        </.form>
      </div>

      <div :if={@notification} class="flex items-center gap-2">
        <.button
          type="button"
          class="btn-error"
          phx-click="delete"
          phx-target={@myself}
          data-confirm="Remove Discord notifications for this map?"
        >
          Remove all Discord notifications
        </.button>
      </div>
    </div>
    """
  end
end
