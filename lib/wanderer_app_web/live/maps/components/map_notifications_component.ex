defmodule WandererAppWeb.MapNotificationsComponent do
  @moduledoc """
  Settings tab for per-map Discord kill notifications.

  A map has one notification record and up to three destinations: a `:system`
  webhook (kills in systems on the map), an optional `:character` webhook
  (kills involving characters tracked on the map) and an optional `:route`
  webhook (highsec-route-to-Jita alerts). Each destination has its own
  URL, enable flag, delivery status and test button, because an owner needs to
  be able to diagnose one channel without touching the other.

  Webhook URLs are credentials: stored encrypted, only ever rendered as a masked
  hint with a replace flow, like a password field.

  The tab is organised around TWO features rather than three peer destinations,
  because that is what the schema actually models: kill notifications (system
  channel, required; optional character-channel split; filters) and route
  alerts (a separate feature borrowing the same webhook plumbing — its own
  toggle, channel, home system, max jumps and mentions). Four progressive
  disclosure levels:

    L0 (no record)  — one URL field, one Connect button.
    L1 (configured) — status, the wormhole-only toggle, and two collapsed
                       disclosures (below) plus the danger action.
    L2 (disclosure) — "Filters and routing": excluded systems, corporation
                       filter, and the optional character channel.
    L3 (disclosure) — "Route alerts": toggle, channel, home system, max jumps,
                       mentions — all in one self-contained section, so its
                       toggle and its channel can never again end up hundreds
                       of pixels apart.
  """

  use WandererAppWeb, :live_component

  require Logger

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.Api.MapSolarSystem
  alias WandererApp.Esi.CorporationSearch
  alias WandererApp.ExternalEvents.Discord.ChannelInfo
  alias WandererApp.ExternalEvents.Discord.Mentions

  @excluded_select_id "excluded_system_live_select_component"
  @focus_corp_select_id "focus_corp_live_select_component"
  @home_system_select_id "home_system_live_select_component"
  @min_search_length 2
  @max_search_results 20

  @roles [:system, :character, :route]

  # Mirrors the resource's own default (map_discord_notification.ex:166), so a
  # blank/non-numeric max-jumps input falls back to the same number a brand new
  # record would get rather than an unrelated magic value.
  @default_route_max_jumps 5
  # Mirrors the resource's `constraints min: 1, max: 20` (map_discord_notification.ex:173).
  @min_route_max_jumps 1
  @max_route_max_jumps 20

  # Shown under the corporation box when the lookup itself failed, as opposed to
  # succeeding with no matches.
  @corp_search_error "Corporation search is unavailable right now. This lookup runs as one of your characters — if it keeps failing, re-authorise a character and try again."

  # The failure reason is rendered alongside the message rather than only logged.
  # This surface is map-admin-only and the reasons are ESI status atoms
  # (`:forbidden`, `:not_found`, `:timeout`, `:error_limited`), not secrets.
  # Without it the banner is identical for "this character needs re-authorising"
  # and "ESI is rate-limiting us", which is the difference between a user-fixable
  # problem and one they should wait out — and it makes the failure diagnosable
  # from a screenshot instead of requiring server log access.
  #
  # The character is named for the same reason. `CorporationSearch.search/3` runs
  # as the FIRST of the user's characters and only that one, so on a
  # multi-character account a single stale token breaks the feature while every
  # other character is fine. Telling the user to "re-authorise a character" is
  # then actively misleading: re-authorising any of the others changes nothing.
  # Naming it also distinguishes the two failures that look identical from the
  # outside — a character-specific token problem versus ESI being down for
  # everything.
  defp corp_search_error(reason, characters) do
    case CorporationSearch.search_character(characters) do
      {:ok, %{name: name}} when is_binary(name) and name != "" ->
        "Corporation search is unavailable right now. It runs as #{name}, so re-authorise" <>
          " that character specifically — re-authorising a different one will not help." <>
          " (#{inspect(reason)})"

      _ ->
        "#{@corp_search_error} (#{inspect(reason)})"
    end
  end

  # Shown under the excluded-systems box when the lookup itself failed. Unlike the
  # corporation search this one never leaves the app, so a failure here means the
  # database or the Ash read is unhealthy rather than anything the user can fix.
  @system_search_error "System search is unavailable right now. Try again in a moment."

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
     |> assign(:home_system_select_id, @home_system_select_id)
     |> assign(:min_search_length, @min_search_length)
     |> assign(:min_route_max_jumps, @min_route_max_jumps)
     |> assign(:max_route_max_jumps, @max_route_max_jumps)
     |> assign(:corp_min_search_length, CorporationSearch.min_search_length())
     |> assign_new(:system_options, fn -> [] end)
     |> assign_new(:system_search_error, fn -> nil end)
     |> assign_new(:home_system_search_error, fn -> nil end)
     |> assign_new(:home_system_error, fn -> nil end)
     |> assign_new(:corp_options, fn -> [] end)
     |> assign_new(:corp_search_error, fn -> nil end)
     |> assign_new(:message, fn -> nil end)
     |> assign_notification(notification)}
  end

  # --- Kill-notification settings (`#discord-notification-form`) ---------

  # Handles BOTH the L0 create submit (webhook_url present, notification nil)
  # and the L1 settings submit (wh_only only). `notification_attrs/1` reading
  # `params` rather than a hardcoded field list is what makes this safe for
  # both: L0's form never renders wh_only, so it is simply absent from
  # `params` and the resource default (`wh_only: true`) applies untouched. See
  # `notification_attrs/1`.
  @impl true
  def handle_event("save", %{"notification" => params}, socket) do
    attrs = notification_attrs(params)

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
        {:noreply, socket |> assign_notification(rec) |> put_message(:kills, :info, "Saved.")}

      {:error, error} ->
        {:noreply, put_message(socket, :kills, :error, humanize_error(error))}
    end
  end

  # Purely client-display dirty tracking for the L1 settings form: the only
  # signal Save needs is "does this differ from the persisted record", so it
  # is computed here rather than persisted. Fires on every keystroke/tick in
  # `#discord-notification-form`, which at L1 holds only `wh_only`.
  #
  # The form is rebuilt from `params`, not left alone — #130. A checkbox
  # renders `checked` from its form value, so re-rendering against the
  # unchanged form emits the box UNCHECKED and LiveView patches the user's
  # tick straight back out. Nothing here is persisted; `wh_only` is still
  # only ever written by "save".
  #
  # Unlike #130 this needs no `webhook_url` blanking: the L1 form does not
  # render that field at all. The credential lives on the mutually exclusive
  # L0 create form (`is_nil(@notification)`), which deliberately carries no
  # `phx-change`, so no submitted params containing a webhook URL ever reach
  # a `to_form/2` call.
  def handle_event("kills-form-change", %{"notification" => params}, socket) do
    rec = socket.assigns.notification

    dirty? =
      changed?(params, "enabled", rec.enabled?, &checked?/1) or
        changed?(params, "wh_only", rec.wh_only, &checked?/1)

    {:noreply,
     socket
     |> assign(:form, rebuild_form(params, kills_form_values(rec)))
     |> assign(:dirty, Map.put(socket.assigns.dirty, :kills, dirty?))}
  end

  # --- Route alerts (`#route-alerts-form`) --------------------------------

  def handle_event("save-route", %{"notification" => params}, socket) do
    case socket.assigns.notification do
      nil ->
        {:noreply,
         put_message(socket, :route, :error, "Save the map's kill notification settings first.")}

      rec ->
        case resolve_home_system(params) do
          {:ok, params} -> save_route(socket, rec, params)
          {:error, message} -> {:noreply, put_home_system_error(socket, message)}
        end
    end
  end

  # Three jobs on every change of the route form: keep `route_toggle` (which
  # fields below are enabled — D4, disable rather than hide) in step with the
  # unsaved checkbox state, rebuild the form so the tick survives the
  # round-trip (#130 — a checkbox renders `checked` from its form value, so
  # re-rendering against the unchanged form patches the user's tick back out
  # and Save then posts `false`), and keep the route Save button's dirty gate
  # honest. All three are purely client-display; the persisted values only
  # ever change through "save-route".
  #
  # Rebuilt from `params` rather than by patching one key, so anything already
  # typed into `home_system_id` / `route_max_jumps` is preserved instead of
  # being reset to the last-saved record on every tick. This form carries no
  # `webhook_url`, so #130's credential-blanking step has nothing to do here.
  def handle_event("route-form-change", %{"notification" => params}, socket) do
    rec = socket.assigns.notification

    dirty? =
      changed?(params, "route_alerts_enabled", rec.route_alerts_enabled?, &checked?/1) or
        changed?(params, "home_system_id", rec.home_system_id, &parse_home_system_id/1) or
        changed?(params, "route_max_jumps", rec.route_max_jumps, &parse_route_max_jumps/1)

    {:noreply,
     socket
     |> assign(:route_toggle, checked?(params["route_alerts_enabled"]))
     |> assign(:route_form, rebuild_form(params, route_form_values(rec)))
     |> assign(:dirty, Map.put(socket.assigns.dirty, :route, dirty?))}
  end

  # The inline remedy on the "switched off, but this channel is configured"
  # warning (D4.2): saves immediately rather than only flipping the unsaved
  # checkbox, because the warning exists precisely because a config can sit in
  # this state indefinitely without anyone pressing Save. If `home_system_id`
  # is nil the Ash "required when enabled" validation fires and lands in the
  # route panel — that is correct, not a bug: enabling from here does not
  # bypass the same validation the settings form is subject to.
  def handle_event("enable-route-alerts", _params, socket) do
    case socket.assigns.notification do
      nil ->
        {:noreply, socket}

      rec ->
        case MapDiscordNotification.update(rec, %{route_alerts_enabled?: true}) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign_notification(updated)
             |> put_message(:route, :info, "Route alerts enabled.")}

          {:error, error} ->
            {:noreply, put_message(socket, :route, :error, humanize_error(error))}
        end
    end
  end

  # --- Webhook destinations (system / character / route rows) ------------

  def handle_event("replace-url", %{"role" => role}, socket) do
    {:noreply, put_replacing(socket, parse_role(role), true)}
  end

  # Undoes "replace-url" without saving anything. Before this existed, a
  # misclick on Edit/Replace discarded the masked view with no way back short
  # of re-pasting a credential the user does not have on hand, or closing and
  # reopening the whole dialog.
  def handle_event("cancel-replace", %{"role" => role}, socket) do
    {:noreply, put_replacing(socket, parse_role(role), false)}
  end

  def handle_event("save-webhook", %{"role" => role, "webhook" => params}, socket) do
    role = parse_role(role)
    scope = webhook_scope(role)

    with %{} = rec <- socket.assigns.notification,
         {:ok, _} <- save_webhook(rec, socket.assigns.webhooks[role], role, params) do
      {:noreply,
       socket
       |> assign_notification(reload_notification(socket.assigns.map_id))
       |> put_message(scope, :info, "Saved.")}
    else
      {:error, error} ->
        {:noreply, put_message(socket, scope, :error, humanize_error(error))}

      _ ->
        {:noreply,
         put_message(socket, scope, :error, "Save the map's notification settings first.")}
    end
  end

  def handle_event("remove-webhook", %{"role" => role}, socket) do
    # `:character` and `:route` are removable; `:system` is required —
    # removing notifications entirely means deleting the parent record.
    # Removing `:character` falls back to `:system`; removing `:route` does
    # NOT — route alerts stop entirely, because the Router deliberately has no
    # fallback for chain topology.
    role = parse_role(role)
    scope = webhook_scope(role)

    case {role, socket.assigns.webhooks[role]} do
      {role, %{} = webhook} when role in [:character, :route] ->
        case MapDiscordWebhook.destroy(webhook) do
          :ok ->
            {:noreply,
             socket
             |> assign_notification(reload_notification(socket.assigns.map_id))
             |> put_message(scope, :info, "#{role_label(role)} destination removed.")}

          {:error, error} ->
            {:noreply, put_message(socket, scope, :error, humanize_error(error))}
        end

      _ ->
        {:noreply,
         put_message(socket, scope, :error, "The system destination cannot be removed.")}
    end
  end

  # Field-level validation for the mentions box (Minors: validated on change,
  # not only on submit). Purely advisory — nothing here saves anything; the
  # actual save still runs `parse_mention_targets/1` inside `save_webhook/4`
  # and would reject the same input. `phx-target={@myself}` on the input
  # keeps this in this component, same as every other event on this form.
  def handle_event(
        "validate-mentions",
        %{"role" => role, "webhook" => %{"mention_targets" => raw}},
        socket
      ) do
    role = parse_role(role)

    error =
      case parse_mention_targets(raw) do
        {:ok, _targets} -> nil
        {:error, message} -> message
      end

    {:noreply,
     assign(socket, :mention_errors, Map.put(socket.assigns.mention_errors, role, error))}
  end

  # LiveSelect's search callback: users know systems and corporations by name,
  # not by numeric id.
  #
  # This must be handled HERE and not by the parent LiveView, whose own
  # `live_select_change` handler answers unconditionally with access-list
  # options. `phx-target={@myself}` on each live_select is what keeps the event
  # in this component.
  #
  # Three pickers share this handler, so it MUST dispatch on the id that
  # fired. Answering unconditionally with system options would fill the
  # corporation dropdown with solar systems.
  def handle_event("live_select_change", %{"id" => @focus_corp_select_id, "text" => text}, socket) do
    {options, corp_search_error} = search_corporations(socket.assigns[:current_user], text)

    send_update(LiveSelect.Component, id: @focus_corp_select_id, options: options)

    {:noreply,
     socket
     |> assign(:corp_options, options)
     |> assign(:corp_search_error, corp_search_error)}
  end

  # The home-system picker searches the same way the excluded-systems one does
  # but keeps its own options and error assigns, so a failed lookup is reported
  # under the box the user is typing in rather than under the other one. It also
  # clears the "no system by that name" error from the previous save attempt:
  # the user is now picking from the list, which is the fix for it.
  def handle_event(
        "live_select_change",
        %{"id" => @home_system_select_id, "text" => text},
        socket
      ) do
    {options, home_system_search_error} = search_systems(text)
    options = maybe_prepend_numeric_system(options, text)

    send_update(LiveSelect.Component, id: @home_system_select_id, options: options)

    {:noreply,
     socket
     |> assign(:home_system_options, options)
     |> assign(:home_system_search_error, home_system_search_error)
     |> assign(:home_system_error, nil)}
  end

  def handle_event("live_select_change", %{"id" => id, "text" => text}, socket) do
    {options, system_search_error} = search_systems(text)

    send_update(LiveSelect.Component, id: id, options: options)

    {:noreply,
     socket
     |> assign(:system_options, options)
     |> assign(:system_search_error, system_search_error)}
  end

  def handle_event("add-excluded", %{"excluded" => %{"excluded_system" => raw}}, socket) do
    with %{} = rec <- socket.assigns.notification,
         {id, ""} <- Integer.parse(to_string(raw)) do
      update_excluded(socket, rec, Enum.uniq([id | rec.excluded_systems]))
    else
      _ -> {:noreply, put_message(socket, :filters, :error, "Pick a system from the list.")}
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
      _ -> {:noreply, put_message(socket, :filters, :error, "Could not remove that system.")}
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
      _ -> {:noreply, put_message(socket, :filters, :error, "Pick a corporation from the list.")}
    end
  end

  def handle_event("remove-focus-corp", %{"corp_id" => raw}, socket) do
    with %{} = rec <- socket.assigns.notification,
         {id, ""} <- Integer.parse(to_string(raw)) do
      update_focus_corps(socket, rec, Enum.reject(rec.focus_corp_ids, &(&1 == id)))
    else
      _ -> {:noreply, put_message(socket, :filters, :error, "Could not remove that corporation.")}
    end
  end

  def handle_event("send-test", %{"webhook_id" => webhook_id}, socket) do
    scope = webhook_scope(role_for_webhook_id(socket.assigns.webhooks, webhook_id))

    case send_test(socket, webhook_id) do
      # `:ok` means the message was ENQUEUED — the last hop is an async cast, so
      # this must not claim Discord accepted it.
      :ok ->
        {:noreply, put_message(socket, scope, :info, "Test message queued.")}

      {:error, :notifications_disabled} ->
        {:noreply,
         put_message(
           socket,
           scope,
           :error,
           "Discord notifications are disabled on this server. Ask an administrator to enable them."
         )}

      {:error, :webhook_disabled} ->
        {:noreply,
         put_message(
           socket,
           scope,
           :error,
           "This destination is disabled. Enable it and save before sending a test message."
         )}

      # Two distinct dispatcher answers, one message on purpose: "no such row"
      # and "row with no usable URL" are worth telling apart in a log or a test,
      # but a user can do nothing about either except save a URL, and this
      # wording is brief-mandated verbatim.
      {:error, reason} when reason in [:webhook_not_found, :webhook_url_missing] ->
        {:noreply, put_message(socket, scope, :error, "Save a webhook URL first.")}

      {:error, other} ->
        # `inspect(other)` here put the raw failure term — which can carry the
        # webhook URL — into the LiveView diff. Log a shape summary instead.
        Logger.warning("[MapNotifications] test message failed: #{error_summary(other)}")

        {:noreply,
         put_message(
           socket,
           scope,
           :error,
           "Could not send a test message. Check the webhook URL and try again."
         )}
    end
  end

  def handle_event("delete", _params, socket) do
    case socket.assigns.notification do
      nil ->
        {:noreply, socket}

      rec ->
        # The resource's custom destroy invalidates the config cache and stops
        # the delivery workers; the webhook children cascade with the parent.
        case WandererApp.Api.MapDiscordNotification.destroy(rec) do
          :ok ->
            {:noreply,
             socket |> assign_notification(nil) |> put_message(:kills, :info, "Removed.")}

          {:error, error} ->
            {:noreply, put_message(socket, :kills, :error, humanize_error(error))}
        end
    end
  end

  defp put_message(socket, scope, kind, text) do
    assign(socket, :message, %{scope: scope, kind: kind, text: text})
  end

  # `webhook_id` arrives from the client as `phx-value-webhook_id`, and
  # `send_test_message/1` resolves it by id alone — across every map in the
  # installation. So the id MUST be matched against this map's own destinations
  # before it is dispatched; without that, anyone who can open a settings tab
  # can post the test message into any other map's Discord channel.
  #
  # The `enabled?` check that rides along STAYS even though `send_test_message/1`
  # now reports the disabled case itself, and the ordering is the reason. The
  # dispatcher checks the global kill-switch first, so with webhooks disabled
  # server-wide it answers `:notifications_disabled` and never looks at the row —
  # a user who unticked one destination would be told the whole server is off.
  # Checking here keeps the more specific message. `map_notifications_test.exs`
  # fails if either half of this is removed.
  defp send_test(socket, webhook_id) do
    socket.assigns.webhooks
    |> Map.values()
    |> Enum.find(&match?(%{id: ^webhook_id}, &1))
    |> case do
      nil -> {:error, :webhook_not_found}
      %{enabled?: false} -> {:error, :webhook_disabled}
      _webhook -> WandererApp.ExternalEvents.DiscordDispatcher.send_test_message(webhook_id)
    end
  end

  # Which role a webhook id belongs to, so a message produced by "send-test"
  # (which only receives the id) lands in the panel that contains that
  # destination. `nil` (id not found / not yet known) falls back to the kills
  # panel — every send-test button is reachable from a row that lives inside
  # either the kills card or one of its disclosures, and the kills panel is
  # the only one always on screen.
  defp role_for_webhook_id(webhooks, webhook_id) do
    Enum.find_value(webhooks, fn {role, wh} -> match?(%{id: ^webhook_id}, wh) && role end)
  end

  # Maps a destination to the message panel that contains it (D2): a
  # channel's own save/test/remove result must land where the user is looking,
  # not at the top of a two-thousand-pixel page.
  defp webhook_scope(:system), do: :kills
  defp webhook_scope(:character), do: :filters
  defp webhook_scope(:route), do: :route
  defp webhook_scope(nil), do: :kills

  defp save_webhook(rec, nil, role, %{"webhook_url" => url} = params)
       when is_binary(url) and url != "" do
    with {:ok, targets} <- parse_mention_targets(params["mention_targets"]) do
      MapDiscordWebhook.create(%{
        notification_id: rec.id,
        role: role,
        webhook_url: url,
        mention_targets: targets
      })
    end
  end

  defp save_webhook(_rec, nil, _role, _params), do: {:error, "Enter a webhook URL first."}

  defp save_webhook(_rec, webhook, _role, %{"webhook_url" => url} = params)
       when is_binary(url) and url != "" do
    with {:ok, targets} <- parse_mention_targets(params["mention_targets"]) do
      MapDiscordWebhook.update(webhook, %{
        webhook_url: url,
        enabled?: checked?(params["enabled"]),
        mention_targets: targets
      })
    end
  end

  # This branch used to call `MapDiscordWebhook.set_enabled/2`, whose accept
  # list is `[:enabled?]` only. Now that this row can also carry
  # `mention_targets`, it goes through the general `update` action instead so
  # a mention-only edit (no URL change) still saves — `set_enabled` itself is
  # untouched and still used by other callers (see `router_test.exs`,
  # `worker_test.exs`, etc.), this is only this handler's own dispatch.
  defp save_webhook(_rec, webhook, _role, params) do
    with {:ok, targets} <- parse_mention_targets(params["mention_targets"]) do
      MapDiscordWebhook.update(webhook, %{
        enabled?: checked?(params["enabled"]),
        mention_targets: targets
      })
    end
  end

  # Empty/whitespace entries are dropped silently — that is not "the silent
  # drop" the task warns against, which is about a MALFORMED entry (one that
  # does not match `Mentions.valid_target?/1`) disappearing without telling
  # the user. A blank entry from "role:123, " trailing-comma typing is not
  # malformed input, it is nothing.
  defp parse_mention_targets(raw) when is_binary(raw) do
    targets =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.find(targets, &(not Mentions.valid_target?(&1))) do
      nil ->
        {:ok, targets}

      bad ->
        {:error,
         "\"#{bad}\" is not a valid mention target. Use user:<id> or role:<id> with the " <>
           "Discord id (17-20 digits) — handles like @name do not work here."}
    end
  end

  defp parse_mention_targets(_), do: {:ok, []}

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

  # Mirrors `Router.usable/1`, which drops on BOTH a missing `:route` row and a
  # configured-but-disabled one. Scoping the hint to the missing-row case only
  # would leave the disabled case as the same silent dead end, and disabling a
  # destination is a click — much easier to do by accident than never creating
  # one.
  defp route_destination_ready?(nil), do: false
  defp route_destination_ready?(%{enabled?: enabled?}), do: enabled?

  defp parse_role("character"), do: :character
  defp parse_role(:character), do: :character
  defp parse_role("route"), do: :route
  defp parse_role(:route), do: :route
  defp parse_role(_), do: :system

  defp role_label(:character), do: "Character"
  defp role_label(:route), do: "Route"

  defp reload_notification(map_id) do
    case MapDiscordNotification.by_map(map_id) do
      {:ok, rec} -> rec
      _ -> nil
    end
  end

  defp update_excluded(socket, rec, excluded) do
    case MapDiscordNotification.update(rec, %{excluded_systems: excluded}) do
      {:ok, updated} ->
        {:noreply, assign_notification(socket, updated)}

      {:error, error} ->
        {:noreply, put_message(socket, :filters, :error, humanize_error(error))}
    end
  end

  defp update_focus_corps(socket, rec, corp_ids) do
    case MapDiscordNotification.update(rec, %{focus_corp_ids: corp_ids}) do
      {:ok, updated} ->
        {:noreply, assign_notification(socket, updated)}

      {:error, error} ->
        {:noreply, put_message(socket, :filters, :error, humanize_error(error))}
    end
  end

  # D1 — the single most load-bearing change in this rework. Two independent
  # callers need "absent key means keep current, never clear":
  #
  #   * The route settings form's fields are `disabled={not @route_toggle}`
  #     rather than hidden (D4) — but a rendered-and-disabled input still
  #     submits NOTHING, same as an unrendered one. The old blanket
  #     `params["home_system_id"]` read would parse that absence as `nil` and
  #     wipe a saved home system on every Save made with route alerts off.
  #   * L0's create form has no `wh_only`/`enabled` checkboxes at all (moved to
  #     L1). `checked?(nil)` is `false`, which is exactly the regression this
  #     guards against — every new config being born disabled with no visible
  #     control to contradict it.
  #
  # Present-but-blank still clears: that is the user emptying a field, which
  # is a different thing from the field never having been on the page.
  defp notification_attrs(params) do
    %{}
    |> put_param(params, "wh_only", :wh_only, &checked?/1)
    |> put_param(params, "enabled", :enabled?, &checked?/1)
    |> put_param(params, "route_alerts_enabled", :route_alerts_enabled?, &checked?/1)
    |> put_param(params, "home_system_id", :home_system_id, &parse_home_system_id/1)
    |> put_param(params, "route_max_jumps", :route_max_jumps, &parse_route_max_jumps/1)
  end

  defp put_param(attrs, params, key, attr, parse) do
    if Map.has_key?(params, key), do: Map.put(attrs, attr, parse.(params[key])), else: attrs
  end

  defp changed?(params, key, current, parse),
    do: Map.has_key?(params, key) and parse.(params[key]) != current

  # Resolves excluded-system names and focus-corporation labels once per change,
  # not once per render: both run lookups, and the template re-renders on every
  # live_select keystroke. Also rebuilds every form so values follow the record,
  # and resets the purely-client dirty/mention-error state: a freshly (re)loaded
  # record is by definition not dirty against itself, and any mention-field
  # complaint was about input that either just got saved or just got replaced.
  defp assign_notification(socket, notification) do
    webhooks = load_webhooks(notification)

    socket
    |> assign(:notification, notification)
    |> assign(:webhooks, webhooks)
    |> assign(:collisions, ChannelInfo.colliding_roles(webhooks))
    |> assign(:route_toggle, !is_nil(notification) and notification.route_alerts_enabled?)
    |> assign(:dirty, %{kills: false, route: false})
    |> assign(:mention_errors, %{})
    |> assign(:excluded_systems, excluded_system_labels(notification))
    |> assign(:focus_corps, focus_corp_labels(notification))
    |> assign(:home_system_options, home_system_options(notification))
    |> assign(:form, kills_form(notification))
    |> assign(:route_form, route_form(notification))
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

  defp load_webhooks(nil), do: %{system: nil, character: nil, route: nil}

  defp load_webhooks(%{id: notification_id}) do
    records =
      case MapDiscordWebhook.by_notification(notification_id) do
        {:ok, list} -> list
        _ -> []
      end

    Map.new(@roles, fn role -> {role, Enum.find(records, &(&1.role == role))} end)
  end

  # Rebuilds a form from submitted params WITHOUT losing fields the payload
  # did not mention.
  #
  # #130 established that these change handlers must rebuild the form at all
  # (a checkbox renders `checked` from its form value, so re-rendering against
  # the unchanged form patches the user's tick back out). Rebuilding straight
  # from `params` then introduces the opposite failure: a payload carrying
  # only the field that changed blanks every other field in the form, and the
  # next Save posts those blanks.
  #
  # A real browser serialises the whole form even for an input-level
  # `phx-change`, so in production the merge is a no-op — including for
  # unticking, where the hidden "false" companion keeps the key present. It
  # matters for any partial payload, and it means the base values fall back to
  # the persisted record rather than to empty.
  #
  # `webhook_url` is forced back to "" last, keeping #130's defence even
  # though no form that carries a credential has a `phx-change` any more: the
  # generic `.input` writes `value=` for password inputs too, so a submitted
  # URL reaching `to_form/2` would be printed into the server-rendered HTML.
  defp rebuild_form(params, base) do
    base
    |> Map.merge(params)
    |> Map.put("webhook_url", "")
    |> to_form(as: :notification)
  end

  defp kills_form(notification), do: to_form(kills_form_values(notification), as: :notification)

  defp kills_form_values(notification) do
    %{
      "webhook_url" => "",
      "enabled" => is_nil(notification) or notification.enabled?,
      "wh_only" => is_nil(notification) or notification.wh_only
    }
  end

  defp route_form(notification), do: to_form(route_form_values(notification), as: :notification)

  defp route_form_values(notification) do
    %{
      # Unlike wh_only/enabled, this one defaults OFF (Task 3: `default:
      # false`) — `is_nil(notification) or ...` would default it ON, which
      # is backwards for this field.
      "route_alerts_enabled" => !is_nil(notification) and notification.route_alerts_enabled?,
      "home_system_id" => home_system_id_value(notification),
      "route_max_jumps" => route_max_jumps_value(notification)
    }
  end

  defp home_system_id_value(nil), do: ""
  defp home_system_id_value(%{home_system_id: nil}), do: ""
  defp home_system_id_value(%{home_system_id: id}), do: to_string(id)

  defp route_max_jumps_value(nil), do: @default_route_max_jumps
  defp route_max_jumps_value(%{route_max_jumps: n}), do: n

  # Blank or non-numeric input clears the home system rather than raising —
  # the Ash "required when enabled" validation is what reports that, not this
  # parse step, matching how `add-excluded`/`add-focus-corp` already leave
  # rejection to a later stage rather than crashing on bad input here.
  defp parse_home_system_id(raw) do
    case Integer.parse(to_string(raw || "")) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp save_route(socket, rec, params) do
    case MapDiscordNotification.update(rec, notification_attrs(params)) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign_notification(updated)
         |> assign(:home_system_error, nil)
         |> put_message(:route, :info, "Saved.")}

      {:error, error} ->
        {:noreply, put_message(socket, :route, :error, humanize_error(error))}
    end
  end

  # What the form posts for the home system, resolved to the integer id the
  # resource stores. Returns the params back with `home_system_id` rewritten,
  # so `notification_attrs/1` keeps being the single place that decides which
  # attributes a save touches.
  #
  # LiveSelect submits two inputs: the hidden `home_system_id` (the picked
  # option's value) and the visible `home_system_id_text_input`. Normally only
  # the first matters. The text is the fallback for the user who types a full
  # name and hits Save without opening the dropdown — resolving it here is what
  # keeps that from posting `nil` and coming back as the generic "is required
  # when route alerts are enabled", which says nothing about the name they
  # typed.
  #
  # With route alerts off the picker sits inside a `disabled` fieldset, so it
  # submits NOTHING — neither input is in `params`. That absence is D1's
  # "keep the current value", and it must not be turned into a nil here: it is
  # exactly what stops Save-with-alerts-off from wiping a saved home system.
  defp resolve_home_system(params) when not is_map_key(params, "home_system_id"),
    do: {:ok, params}

  defp resolve_home_system(params) do
    case parse_home_system_id(params["home_system_id"]) do
      id when is_integer(id) ->
        {:ok, Map.put(params, "home_system_id", id)}

      nil ->
        with {:ok, id} <-
               resolve_home_system_name(
                 params["home_system_id_text_input"],
                 checked?(params["route_alerts_enabled"])
               ) do
          {:ok, Map.put(params, "home_system_id", id)}
        end
    end
  end

  defp resolve_home_system_name(raw, true) when is_binary(raw) do
    case String.trim(raw) do
      "" -> {:ok, nil}
      name -> lookup_home_system_name(name)
    end
  end

  defp resolve_home_system_name(_raw, _route_alerts_enabled?), do: {:ok, nil}

  # `find_by_name` is a substring search (`map_solar_system.ex:104`), so it can
  # answer with several systems for a typed prefix. Only an exact name is
  # accepted: picking "Jitanenba" for someone who typed "Jita" would silently
  # watch the wrong system, and the dropdown is right there for choosing
  # between near-misses.
  defp lookup_home_system_name(name) do
    wanted = String.downcase(name)

    case MapSolarSystem.find_by_name(%{name: name}) do
      {:ok, systems} ->
        case Enum.find(systems, &(String.downcase(&1.solar_system_name) == wanted)) do
          %{solar_system_id: id} ->
            {:ok, id}

          nil ->
            {:error,
             "No solar system is named \"#{name}\". Pick one from the search results below the box."}
        end

      other ->
        Logger.warning("[MapNotifications] home system lookup failed: #{inspect(other)}")
        {:error, @system_search_error}
    end
  end

  # Field-level, next to the picker: the generic banner at the top of the tab
  # is far enough from this box that "no system is named X" reads as being
  # about something else. Clears the "Saved." flash for the same reason it
  # clears on any other failed save — nothing was written.
  defp put_home_system_error(socket, message) do
    socket
    |> assign(:home_system_error, message)
    |> assign(:message, nil)
  end

  # Falls back to the column default on blank/non-numeric input rather than
  # sending `nil` into an `allow_nil?: false` attribute, which Ash would
  # reject outright.
  defp parse_route_max_jumps(raw) do
    case Integer.parse(to_string(raw || "")) do
      {n, ""} -> n
      _ -> @default_route_max_jumps
    end
  end

  # D7's numeric fallback: an all-digits query becomes a usable option even
  # when it matches no system name (or matches nothing at all, e.g. an id for
  # a system this instance's SDE snapshot doesn't carry). `Integer.parse`
  # requiring a full match (`{id, ""}`) is the "all-digits" check — "31k" or
  # "J1234" fall through untouched.
  #
  # The value is a STRING for the reason `search_systems/1` explains: LiveSelect
  # re-derives its selection by matching `field.value`, which round-trips
  # through the browser as a string.
  defp maybe_prepend_numeric_system(options, text) do
    case Integer.parse(text) do
      {id, ""} -> [{"Solar system #{id}", to_string(id)} | options]
      _ -> options
    end
  end

  defp webhook_forms(webhooks) do
    Map.new(@roles, fn role ->
      webhook = Map.get(webhooks, role)

      form =
        to_form(
          %{
            "webhook_url" => "",
            "enabled" => is_nil(webhook) or webhook.enabled?,
            "mention_targets" => mention_targets_value(webhook)
          },
          as: :webhook
        )

      {role, form}
    end)
  end

  defp mention_targets_value(nil), do: ""
  defp mention_targets_value(%{mention_targets: targets}), do: Enum.join(targets, ", ")

  # Mirrors the ACL live_select pattern in maps_live: search server-side, feed
  # `{label, value}` options back into the component.
  #
  # Returns `{options, error_message_or_nil}` for the same reason
  # `search_corporations/2` does: this is a database lookup that can fail, and an
  # empty dropdown reads as "there is no system by that name".
  #
  # Option VALUES are strings, not the integer solar system ids. LiveSelect
  # re-derives its selection by matching `field.value` against its options
  # (`component.ex:561-572`), and a form field's value round-trips through the
  # browser as a string — so integer values would stop matching the moment the
  # form is rebuilt from params and the picker would show a bare id where it had
  # shown "Jita (The Forge)". Both consumers parse the value back to an integer
  # (`add-excluded`, `resolve_home_system/1`), so nothing downstream cares.
  defp search_systems(text) when is_binary(text) and byte_size(text) >= @min_search_length do
    case MapSolarSystem.find_by_name(%{name: text}) do
      {:ok, systems} ->
        {systems
         |> Enum.take(@max_search_results)
         |> Enum.map(&{system_option_label(&1), to_string(&1.solar_system_id)}), nil}

      other ->
        Logger.warning("[MapNotifications] system search failed: #{inspect(other)}")
        {[], @system_search_error}
    end
  end

  defp search_systems(_), do: {[], nil}

  defp system_option_label(%{solar_system_name: name, region_name: region})
       when is_binary(region) and region != "",
       do: "#{name} (#{region})"

  defp system_option_label(%{solar_system_name: name}), do: name

  # Seeds the home-system picker with the option it is already showing, so a
  # saved home system renders as "Jita (The Forge)" and not as the raw id the
  # form field holds. LiveSelect can only put a label on a value it has seen as
  # an option, and on the first render its options are whatever this assign
  # says (it ignores the assign on later re-renders and carries the selection
  # instead, `component.ex:121-127`).
  #
  # Degrades to the bare id rather than dropping the option, for the same
  # reason `focus_corp_labels/1` does: the user must be able to see and change
  # what is saved even when the lookup is unavailable.
  defp home_system_options(nil), do: []
  defp home_system_options(%{home_system_id: nil}), do: []

  defp home_system_options(%{home_system_id: id}) do
    value = to_string(id)

    case MapSolarSystem.by_solar_system_ids([id]) do
      {:ok, [system | _]} -> [{system_option_label(system), value}]
      _ -> [{value, value}]
    end
  end

  # `CorporationSearch.search/3` enforces its own minimum length and returns
  # `{:ok, []}` for a user with no characters, so no length guard is needed here.
  #
  # Returns `{options, error_message_or_nil}`. The distinction matters: this
  # lookup leaves the app and can fail for reasons the user can act on (an ESI
  # outage, a character whose token needs re-authorising), and an empty dropdown
  # is indistinguishable from "that corporation does not exist". Reporting only
  # into the log is what made a crash in the token-refresh path present as a
  # typeahead that silently did nothing.
  #
  # The rescue is not belt-and-braces: the search runs as one of the user's
  # characters, and `Character.search/2` reaches ESI's token-refresh path.
  # Unrescued, a raise there kills the LiveView on a keystroke in the
  # corporation box, taking the whole settings tab with it.
  defp search_corporations(%{characters: characters}, text) when is_list(characters) do
    case CorporationSearch.search(characters, text) do
      {:ok, results} ->
        {results |> Enum.take(@max_search_results) |> Enum.map(&{&1.formatted, &1.id}), nil}

      {:error, reason} ->
        Logger.warning(
          "[MapNotifications] corporation search failed as #{inspect(search_character_name(characters))}: #{inspect(reason)}"
        )

        {[], corp_search_error(reason, characters)}
    end
  rescue
    error ->
      Logger.warning(
        "[MapNotifications] corporation search crashed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      {[], corp_search_error(error.__struct__, characters)}
  end

  defp search_corporations(_current_user, _text), do: {[], nil}

  # Log-only; the rendered message goes through `corp_search_error/2`.
  defp search_character_name(characters) do
    case CorporationSearch.search_character(characters) do
      {:ok, %{name: name}} -> name
      _ -> nil
    end
  end

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

  defp humanize_error(message) when is_binary(message), do: message

  defp humanize_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &error_sentence/1)
  end

  defp humanize_error(other), do: fallback_message(other)

  # Ash carries validation copy as a template plus a `vars` bag — a max-length
  # violation's `message` is the literal `length must be less than or equal to
  # %{max}`. Rendering the raw field shows the user the placeholder, so
  # substitute before display.
  defp error_sentence(%{message: message} = error) when is_binary(message) do
    error
    |> Map.get(:vars)
    |> List.wrap()
    |> Enum.reduce(message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", var_string(value))
    end)
  end

  defp error_sentence(other), do: fallback_message(other)

  # Anything without a message is an error shape we did not anticipate. Its
  # fields are not user-facing copy, so it is logged rather than rendered — but
  # only its TYPE. The struct itself must never be inspected into the log: an
  # `Ash.Error.Invalid` raised by a create carries the submitted value in
  # `InvalidArgument`/`InvalidAttribute`'s `value:` field, and `sensitive? true`
  # on the attribute does NOT redact that — so `inspect/1` here would write the
  # webhook URL, a credential, into the log in full. The type is enough to
  # identify the shape and add a clause for it.
  defp fallback_message(error) do
    Logger.warning("[MapNotifications] unrecognised error shape: #{error_summary(error)}")
    "Something went wrong. Please try again."
  end

  # Struct name for structs, the atom itself for atom reasons (those are code
  # constants, never user input), and the bare kind for anything else. None of
  # these can carry a submitted value.
  defp error_summary(%module{}), do: inspect(module)
  defp error_summary(error) when is_atom(error), do: inspect(error)
  defp error_summary(error) when is_tuple(error), do: "#{tuple_size(error)}-tuple"
  defp error_summary(error) when is_list(error), do: "#{length(error)}-element list"
  defp error_summary(error) when is_map(error), do: "plain map"
  defp error_summary(_error), do: "unrecognised term"

  defp var_string(value) when is_binary(value), do: value
  defp var_string(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp var_string(value), do: inspect(value)

  # D6's webhook identity, replacing the old `masked_url/1` (which rendered the
  # channel snowflake in full and the first four characters of the token).
  # `ChannelInfo.describe/1` answers from cache, then the label persisted on the
  # row, then a masked hint — never blocking and never doing I/O on this render
  # path, which matters because the tab re-renders on every typeahead keystroke.
  # Whichever tier answers, the string is safe to show: a resolved label is the
  # channel's own "#name", and the fallback is a truncated non-reversible digest
  # that is never derived from the token.
  defp channel_hint(webhook) do
    case ChannelInfo.describe(webhook) do
      {:ok, %{label: label}} -> label
      {:error, _reason} -> nil
    end
  end

  # Roles whose destination resolves to the same Discord channel as `role`.
  # `ChannelInfo.colliding_roles/1` groups on the resolved `channel_id` where it
  # has one, so this catches two DISTINCT webhook URLs pointing at the same
  # channel — not merely the same URL pasted twice.
  defp collision_partners(collisions, role) do
    collisions
    |> Enum.find([], &(role in &1))
    |> List.delete(role)
  end

  # The route wording is deliberately not the generic one. A route alert names
  # every system between the home system and Jita, and the channel's own help
  # text asks the map owner to treat it as trusted — so a route channel shared
  # with the kill feed is a disclosure, not just untidy configuration.
  defp collision_text(:route, partners),
    do:
      "Route alerts post to the same Discord channel as #{role_names(partners)}. " <>
        "Anyone who can read that channel can see this map's home system and the " <>
        "route to it."

  defp collision_text(_role, partners),
    do: "This channel is also used by #{role_names(partners)} on this map."

  defp role_names(partners), do: partners |> Enum.map(&role_name/1) |> to_sentence()

  defp role_name(:system), do: "the system channel"
  defp role_name(:character), do: "the character channel"
  defp role_name(:route), do: "route alerts"

  defp to_sentence([one]), do: one

  defp to_sentence(names) do
    {rest, [last]} = Enum.split(names, -1)
    "#{Enum.join(rest, ", ")} and #{last}"
  end

  # --- Status (P1 hierarchy) -----------------------------------------------

  defp status_state(nil), do: :never
  defp status_state(%{enabled?: false}), do: :disabled

  defp status_state(%{last_error: error, consecutive_failures: n})
       when not is_nil(error) and n > 0,
       do: :degraded

  defp status_state(%{last_delivery_at: nil}), do: :never
  defp status_state(_webhook), do: :delivering

  defp status_label(:delivering), do: "Delivering"
  defp status_label(:degraded), do: "Degraded"
  defp status_label(:disabled), do: "Disabled"
  defp status_label(:never), do: "Never delivered"

  defp status_class(:delivering), do: "text-emerald-400"
  defp status_class(:degraded), do: "text-amber-400"
  defp status_class(:disabled), do: "text-red-400"
  defp status_class(:never), do: "opacity-70"

  defp status_line(nil), do: nil

  defp status_line(webhook),
    do: "Posting to channel #{channel_hint(webhook)} · #{last_kill_text(webhook)}"

  defp last_kill_text(%{last_delivery_at: nil}), do: "no kills yet"

  defp last_kill_text(%{last_delivery_at: dt}),
    do: "last kill #{Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")}"

  # --- Route-alerts P0: the reachable inert warning (D4) -------------------

  # Alerts ON, no usable channel — the guard that already existed, now
  # reachable at any time rather than only while a client-toggled `hidden`
  # class happened to be off.
  #
  # `toggle?` is the UNSAVED checkbox state, and it is ORed with the persisted
  # flag on purpose: ticking the box is exactly the moment the map owner needs
  # to be told there is no channel to send to, and making them press Save
  # first to learn it is the delayed-feedback version of the same bug.
  defp route_alert_on_no_channel?(notification, route_webhook, toggle?) do
    (toggle? or match?(%{route_alerts_enabled?: true}, notification)) and
      not route_destination_ready?(route_webhook)
  end

  # Alerts OFF, channel fully configured — the P0 this rework exists for: a
  # reachable channel with nothing telling the map owner it is not being used.
  defp route_inert?(%{route_alerts_enabled?: false}, route_webhook),
    do: route_destination_ready?(route_webhook)

  defp route_inert?(_notification, _route_webhook), do: false

  # --- Disclosure badges (D5) — computed server-side so a client-only toggle
  # cannot defeat what the badge reports. ------------------------------------

  defp filters_badge(excluded_systems, focus_corps) do
    [
      excluded_count_label(length(excluded_systems)),
      focus_corp_count_label(length(focus_corps))
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp excluded_count_label(0), do: nil
  defp excluded_count_label(1), do: "1 system excluded"
  defp excluded_count_label(n), do: "#{n} systems excluded"

  defp focus_corp_count_label(0), do: nil
  defp focus_corp_count_label(1), do: "1 corporation"
  defp focus_corp_count_label(n), do: "#{n} corporations"

  # Never collapse a problem: auto-expand when there is anything to fix or
  # already configured, collapse only when the section is genuinely empty and
  # untouched.
  # "Never collapse a problem" (D5). The message scope is part of that: a
  # save result rendered inside a collapsed body is exactly the silent-flash
  # failure this rework exists to remove, so anything addressed to this panel
  # forces it open.
  defp filters_expanded?(
         excluded_systems,
         focus_corps,
         character_webhook,
         sys_err,
         corp_err,
         message,
         collisions
       ) do
    excluded_systems != [] or
      focus_corps != [] or
      not is_nil(character_webhook) or
      not is_nil(sys_err) or
      not is_nil(corp_err) or
      collision_partners(collisions, :character) != [] or
      match?(%{scope: :filters}, message)
  end

  defp route_badge(nil, _route_webhook), do: "Off"

  defp route_badge(%{route_alerts_enabled?: true}, route_webhook) do
    if route_destination_ready?(route_webhook), do: "On", else: "On — no channel ready"
  end

  defp route_badge(%{route_alerts_enabled?: false}, route_webhook) do
    if route_destination_ready?(route_webhook), do: "Off — channel configured", else: "Off"
  end

  defp route_expanded?(nil, _route_webhook, _collisions), do: false

  defp route_expanded?(%{route_alerts_enabled?: enabled?}, route_webhook, collisions) do
    problem? =
      (enabled? and not route_destination_ready?(route_webhook)) or
        (not enabled? and route_destination_ready?(route_webhook)) or
        collision_partners(collisions, :route) != []

    # `and`, not `&&`: this feeds `expanded?`, a `:boolean` attr that is used
    # as `not @expanded?` in the disclosure body's class list. `&&` would
    # return the nil webhook itself when there is no route destination, and
    # `not nil` is an ArgumentError at render time rather than a falsy value.
    problem? or (not is_nil(route_webhook) and not is_nil(route_webhook.last_error))
  end

  # --- Function components ---------------------------------------------

  # D5's disclosure mechanism: client-side only (`JS.toggle_class`), following
  # the one existing precedent in the app
  # (characters_live.html.heex:92) rather than inventing a parallel pattern or
  # round-tripping open/closed state through the server. The SERVER decides
  # the initial `hidden`/caret class via `@expanded?` — computed by the
  # `*_expanded?/*` helpers above from persisted state, so a section holding a
  # problem always starts open no matter what a previous client toggle did.
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :badge, :string, default: nil
  attr :expanded?, :boolean, default: false
  slot :inner_block, required: true

  defp disclosure(assigns) do
    ~H"""
    <div class="rounded border border-white/10">
      <button
        type="button"
        class="flex w-full items-center justify-between gap-2 px-3 py-2 text-left"
        phx-click={
          JS.toggle_class("hidden", to: "##{@id}-body")
          |> JS.toggle_class("rotate-90", to: "##{@id}-caret")
        }
      >
        <span class="flex items-center gap-2 text-sm font-semibold">
          <span
            id={"#{@id}-caret"}
            class={["inline-block transition-transform", @expanded? && "rotate-90"]}
          >
            ▸
          </span>
          {@title}
        </span>
        <span :if={@badge} class="text-xs opacity-70">{@badge}</span>
      </button>

      <div
        id={"#{@id}-body"}
        class={["flex flex-col gap-3 border-t border-white/10 p-3", not @expanded? && "hidden"]}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # D2's per-panel flash: one `@message` assign shaped
  # `%{scope:, kind:, text:}`, rendered once per panel via `scope`. Only the
  # panel that matches `@message.scope` ever shows anything, so a save on one
  # channel cannot be mistaken for a save on another.
  attr :message, :any, default: nil
  attr :scope, :atom, required: true

  defp panel_message(assigns) do
    ~H"""
    <p :if={@message && @message.scope == @scope} class={message_class(@message.kind)}>
      {@message.text}
    </p>
    """
  end

  defp message_class(:error), do: "text-sm text-red-400"
  defp message_class(:info), do: "text-sm text-green-400"

  # Unifies excluded-systems and focus-corporation removal onto one visual
  # treatment (Minors: chips) — both used to render the same semantics two
  # different ways (a bare `<ul><li>` versus a rounded chip) sitting one
  # panel apart. `:rest` picks up `phx-click`/`phx-value-*`/`phx-target`
  # unchanged (they're all `phx-`-prefixed, in the global attribute set by
  # default), so each call site is just the label plus its own removal event.
  attr :label, :string, required: true
  attr :rest, :global

  defp chip(assigns) do
    ~H"""
    <li class="flex items-center gap-2 rounded-full bg-white/10 px-3 py-1 text-sm">
      <span>{@label}</span>
      <.button type="button" variant={:ghost} {@rest}>Remove</.button>
    </li>
    """
  end

  attr :role, :atom, required: true
  attr :collisions, :list, required: true

  defp collision_warning(assigns) do
    assigns = assign(assigns, :partners, collision_partners(assigns.collisions, assigns.role))

    ~H"""
    <p :if={@partners != []} id={"collision-#{@role}"} class="text-sm text-amber-400">
      {collision_text(@role, @partners)}
    </p>
    """
  end

  attr :role, :atom, required: true
  attr :title, :string, required: true
  attr :help, :string, required: true
  attr :webhook, :any, required: true
  attr :form, :any, required: true
  attr :replacing?, :boolean, required: true
  attr :removable?, :boolean, required: true
  attr :show_mentions?, :boolean, default: false
  # The system row's own delivery status is promoted to the card level (P1
  # hierarchy) — the status line and failure line live just above this
  # component in L1, so repeating them here would be the exact "identical to
  # the help text above it" problem being fixed. Character/route rows have no
  # card-level equivalent and keep their own status block.
  attr :show_status?, :boolean, default: true
  attr :mention_error, :string, default: nil
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
          <span class="text-sm opacity-70">Channel: {channel_hint(@webhook)}</span>
          <.button
            type="button"
            variant={:ghost}
            phx-click="replace-url"
            phx-value-role={@role}
            phx-target={@myself}
          >
            Edit
          </.button>
        </div>

        <.button
          :if={@replacing? && @webhook}
          type="button"
          variant={:ghost}
          class="self-start"
          phx-click="cancel-replace"
          phx-value-role={@role}
          phx-target={@myself}
        >
          Cancel
        </.button>

        <.input :if={@webhook} field={wf[:enabled]} type="checkbox" label="Enabled" />

        <div class={["flex-col gap-1", if(@show_mentions?, do: "flex", else: "hidden")]}>
          <.input
            field={wf[:mention_targets]}
            type="text"
            label="Mentions (optional)"
            placeholder="role:123456789012345678, user:234567890123456789"
            phx-change="validate-mentions"
            phx-value-role={@role}
            phx-target={@myself}
          />
          <p :if={@mention_error} class="text-sm text-red-400">{@mention_error}</p>
          <p class="text-xs opacity-70">
            Comma-separated <code>user:&lt;id&gt;</code>
            or <code>role:&lt;id&gt;</code>
            Discord snowflakes to ping when a route opens. Handles like <code>@name</code>
            do not work; Discord requires the numeric id. Leave empty to post with no ping.
          </p>
        </div>

        <.button type="submit" variant={:primary} class="self-start">
          {if @webhook, do: "Save", else: "Add"}
        </.button>
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
          variant={:danger}
          class="self-start"
          phx-click="remove-webhook"
          phx-value-role={@role}
          phx-target={@myself}
          data-confirm="Remove this Discord destination?"
        >
          Remove
        </.button>
      </div>

      <div :if={@webhook && @show_status?} class="flex flex-col gap-1 text-sm">
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

  attr :notification, :any, required: true
  attr :webhooks, :any, required: true
  attr :route_toggle, :boolean, required: true
  attr :myself, :any, required: true

  # D4's reachable warning, rendered at card level OUTSIDE either disclosure so
  # a configured-but-inert route destination is visible without opening
  # anything. Both halves of the "disable, don't hide" fix live here: the
  # alerts-on-but-no-channel case is the pre-existing guard made reachable at
  # all times, and the alerts-off-but-configured case is the P0 this rework
  # was written for.
  defp route_alert_banner(assigns) do
    ~H"""
    <p
      :if={route_alert_on_no_channel?(@notification, @webhooks[:route], @route_toggle)}
      class="text-sm text-amber-400"
    >
      Route alerts are on, but no Route alert channel is ready — nothing is being sent.
    </p>

    <div
      :if={route_inert?(@notification, @webhooks[:route])}
      class="flex items-center gap-2 text-sm text-amber-400"
    >
      <span>
        Route alerts are switched off, but this channel is configured — nothing is being sent to it.
      </span>
      <.button type="button" phx-click="enable-route-alerts" phx-target={@myself}>
        Enable route alerts
      </.button>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex max-w-3xl flex-col gap-4">
      <p class="text-sm opacity-70">
        Posts kills to Discord. These filters are separate from the Kills widget's
        own filters, which are per-user and only affect what you see in the map UI.
      </p>

      <div :if={is_nil(@notification)} class="flex flex-col gap-3 rounded border border-white/10 p-3">
        <h3 class="text-base font-semibold">Kill notifications</h3>

        <.panel_message message={@message} scope={:kills} />

        <.form
          :let={f}
          for={@form}
          id="discord-notification-form"
          phx-submit="save"
          phx-target={@myself}
          class="flex flex-col gap-3"
        >
          <.input
            field={f[:webhook_url]}
            type="password"
            label="Discord webhook URL"
            placeholder="https://discord.com/api/webhooks/..."
            autocomplete="off"
          />

          <.button type="submit" variant={:primary} class="self-start">Connect</.button>
        </.form>
      </div>

      <div :if={@notification} class="flex flex-col gap-3 rounded border border-white/10 p-3">
        <div class="flex items-center justify-between gap-2">
          <h3 class="text-base font-semibold">Kill notifications</h3>
          <span class={["text-xs font-semibold", status_class(status_state(@webhooks[:system]))]}>
            ● {status_label(status_state(@webhooks[:system]))}
          </span>
        </div>

        <p class="text-sm opacity-70">{status_line(@webhooks[:system])}</p>
        <p :if={@webhooks[:system] && @webhooks[:system].last_error} class="text-sm text-amber-400">
          Last error: {@webhooks[:system].last_error}
          <span :if={@webhooks[:system].consecutive_failures > 0}>
            ({@webhooks[:system].consecutive_failures} consecutive failures)
          </span>
        </p>
        <.collision_warning role={:system} collisions={@collisions} />

        <.webhook_row
          role={:system}
          title="System channel"
          help="Receives kills that happen in systems on this map."
          webhook={@webhooks[:system]}
          form={@webhook_forms[:system]}
          replacing?={@replacing_url?[:system]}
          removable?={false}
          show_status?={false}
          myself={@myself}
        />

        <.panel_message message={@message} scope={:kills} />

        <.form
          :let={f}
          for={@form}
          id="discord-notification-form"
          phx-submit="save"
          phx-change="kills-form-change"
          phx-target={@myself}
          class="flex flex-col gap-2"
        >
          <%!-- The record-level master switch. It is deliberately still here
                at L1 and not folded into the per-destination `enabled?` on the
                webhook rows: this one stops kill notifications for the whole
                map in one tick, and without it the only way to stop delivery
                would be "Remove all Discord notifications", which also throws
                away every filter and channel the user has configured. --%>
          <.input field={f[:enabled]} type="checkbox" label="Send kill notifications" />
          <.input field={f[:wh_only]} type="checkbox" label="Only wormhole kills" />

          <.button type="submit" variant={:primary} class="self-start" disabled={not @dirty.kills}>
            Save
          </.button>
        </.form>

        <.route_alert_banner
          notification={@notification}
          webhooks={@webhooks}
          route_toggle={@route_toggle}
          myself={@myself}
        />

        <.disclosure
          id="filters-disclosure"
          title="Filters and routing"
          badge={filters_badge(@excluded_systems, @focus_corps)}
          expanded?={
            filters_expanded?(
              @excluded_systems,
              @focus_corps,
              @webhooks[:character],
              @system_search_error,
              @corp_search_error,
              @message,
              @collisions
            )
          }
        >
          <div class="flex flex-col gap-2">
            <.panel_message message={@message} scope={:filters} />

            <h4 class="text-sm font-semibold">Excluded systems</h4>

            <ul class="flex flex-wrap gap-2">
              <li :for={{system_id, label} <- @excluded_systems}>
                <.chip
                  label={label}
                  phx-click="remove-excluded"
                  phx-value-system_id={system_id}
                  phx-target={@myself}
                />
              </li>
            </ul>

            <%!-- Height matching, without predicting either box: `compact` makes the
                  field wrapper exactly as tall as its input, `!py-0` drops the
                  button's vertical padding so its intrinsic height (one line of
                  text) is always shorter than the input's, and the grid row is
                  therefore sized by the field. `items-stretch` then gives the
                  button that exact height. Nothing here depends on the button and
                  the input agreeing on font size, padding or line-height, which
                  they do not. --%>
            <.form
              :let={ef}
              for={@excluded_form}
              id="excluded-system-form"
              phx-submit="add-excluded"
              phx-target={@myself}
              class="grid items-stretch gap-2"
              style="grid-template-columns: 1fr auto"
            >
              <.live_select
                field={ef[:excluded_system]}
                id={@excluded_select_id}
                phx-target={@myself}
                dropdown_extra_class="!h-24"
                compact={true}
                debounce={250}
                update_min_len={@min_search_length}
                mode={:single}
                options={@system_options}
                placeholder="Search a system by name"
              />
              <.button type="submit" class="!py-0 inline-flex items-center justify-center">
                Add
              </.button>
            </.form>

            <p :if={@system_search_error} class="text-sm text-amber-400">{@system_search_error}</p>
          </div>

          <div class="flex flex-col gap-2">
            <h4 class="text-sm font-semibold">Corporation filter</h4>
            <p class="text-xs opacity-70">
              When set, only kills involving these corporations go to the character
              channel, instead of your map-tracked characters. Everything else follows
              the normal system rules. Leave empty to use map-tracked characters.
              These kills ignore the excluded-system and wormhole-only filters.
            </p>

            <ul class="flex flex-wrap gap-2">
              <li :for={{corp_id, label} <- @focus_corps}>
                <.chip
                  label={label}
                  phx-click="remove-focus-corp"
                  phx-value-corp_id={corp_id}
                  phx-target={@myself}
                />
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
              class="grid items-stretch gap-2"
              style="grid-template-columns: 1fr auto"
            >
              <.live_select
                field={cf[:focus_corp]}
                id={@focus_corp_select_id}
                phx-target={@myself}
                dropdown_extra_class="!h-24"
                compact={true}
                debounce={250}
                update_min_len={@corp_min_search_length}
                mode={:single}
                options={@corp_options}
                placeholder="Search a corporation by name"
              />
              <.button type="submit" class="!py-0 inline-flex items-center justify-center">
                Add
              </.button>
            </.form>

            <p :if={@corp_search_error} class="text-sm text-amber-400">{@corp_search_error}</p>
          </div>

          <div class="flex flex-col gap-2">
            <%!-- Nested toggle: collapsed to a single link when no character
                  channel exists (the common case, per the shared brief — the
                  minimum viable config is one pasted URL), auto-expanded the
                  moment one does. CSS-only, same JS.toggle_class mechanism as
                  the outer disclosures, so the row stays in the DOM either way
                  and `#webhook-form-character` keeps existing for tests. --%>
            <button
              type="button"
              id="character-channel-toggle"
              class={[
                "text-left text-sm underline opacity-80 hover:opacity-100",
                @webhooks[:character] && "hidden"
              ]}
              phx-click={
                JS.toggle_class("hidden", to: "#character-channel-toggle")
                |> JS.toggle_class("hidden", to: "#character-channel-body")
              }
            >
              + Add a separate channel
            </button>

            <div
              id="character-channel-body"
              class={["flex flex-col gap-2", is_nil(@webhooks[:character]) && "hidden"]}
            >
              <.webhook_row
                role={:character}
                title="Character channel"
                help={
                  "Receives kills involving characters tracked on this map, wherever they happen. " <>
                    "Leave it unset and those kills go to the system channel instead."
                }
                webhook={@webhooks[:character]}
                form={@webhook_forms[:character]}
                replacing?={@replacing_url?[:character]}
                removable?={true}
                mention_error={@mention_errors[:character]}
                myself={@myself}
              />

              <.collision_warning role={:character} collisions={@collisions} />
            </div>
          </div>
        </.disclosure>

        <.disclosure
          id="route-disclosure"
          title="Route alerts"
          badge={route_badge(@notification, @webhooks[:route])}
          expanded?={route_expanded?(@notification, @webhooks[:route], @collisions)}
        >
          <.panel_message message={@message} scope={:route} />

          <.form
            :let={rf}
            for={@route_form}
            id="route-alerts-form"
            phx-submit="save-route"
            phx-change="route-form-change"
            phx-target={@myself}
            class="flex flex-col gap-2"
          >
            <%!-- The same `phx-change` as the enclosing form, declared on the
                  checkbox itself as well. An input-level `phx-change` still
                  serialises the whole form, so the handler receives exactly
                  the same params either way — but it makes the toggle
                  independently addressable, which is how both the tests and
                  the #130 regression drive it. --%>
            <.input
              field={rf[:route_alerts_enabled]}
              type="checkbox"
              label="Route alerts (highsec route to Jita)"
              phx-change="route-form-change"
              phx-target={@myself}
            />

            <%!-- Disabled rather than hidden (upstream checklist §5), and disabled
                  through a <fieldset> rather than per-input for two reasons. It
                  natively disables every descendant control including
                  LiveSelect's own text and hidden inputs — `live_select/1`
                  declares no `disabled` attr, and adding one belongs to
                  core_components' owner, not this file. And it is a real
                  disable: keyboard and AT see it, unlike a pointer-events or
                  opacity trick.

                  Nothing here submits while disabled, which is safe only
                  because `notification_attrs/1` treats an absent key as "leave
                  this field alone" — otherwise pressing Save with alerts off
                  would clear a saved home system. --%>
            <fieldset disabled={not @route_toggle} class="flex flex-col gap-2 border-0 p-0">
              <div class="flex flex-col gap-1">
                <span class="text-sm">Home system</span>
                <.live_select
                  field={rf[:home_system_id]}
                  id={@home_system_select_id}
                  phx-target={@myself}
                  dropdown_extra_class="!h-24"
                  compact={true}
                  debounce={250}
                  update_min_len={@min_search_length}
                  mode={:single}
                  options={@home_system_options}
                  placeholder="Search a system by name, or enter its solar system ID"
                />
                <p :if={@home_system_error} class="text-sm text-red-400">{@home_system_error}</p>
                <p :if={@home_system_search_error} class="text-sm text-amber-400">
                  {@home_system_search_error}
                </p>
              </div>

              <.input
                field={rf[:route_max_jumps]}
                type="number"
                min={@min_route_max_jumps}
                max={@max_route_max_jumps}
                label="Max jumps to Jita (inclusive)"
              />
            </fieldset>

            <p class="text-xs opacity-70">
              Posts when a highsec-only route this length or shorter opens from the home
              system to Jita. Wormhole hops on the way don't count against "highsec" —
              only k-space systems on the path do.
            </p>

            <.button type="submit" variant={:primary} class="self-start" disabled={not @dirty.route}>
              Save
            </.button>
          </.form>

          <.webhook_row
            role={:route}
            title="Route alert channel"
            help={
              "Receives an alert when a highsec-only route opens from the home system to Jita. " <>
                "This message names every system on the route in order. Treat this channel as " <>
                "trusted; there is no redacted version of it. Route alerts are sent here and " <>
                "nowhere else — leave it unset and no route alerts are sent at all."
            }
            webhook={@webhooks[:route]}
            form={@webhook_forms[:route]}
            replacing?={@replacing_url?[:route]}
            removable?={true}
            show_mentions?={true}
            mention_error={@mention_errors[:route]}
            myself={@myself}
          />

          <.collision_warning role={:route} collisions={@collisions} />
        </.disclosure>

        <div class="flex items-center gap-2">
          <.button
            type="button"
            variant={:danger}
            class="self-start"
            phx-click="delete"
            phx-target={@myself}
            data-confirm="Remove Discord notifications for this map?"
          >
            Remove all Discord notifications
          </.button>
        </div>
      </div>
    </div>
    """
  end
end
