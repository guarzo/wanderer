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
  because that is what the schema actually models: kill notifications (kill
  channel, optional character-kill-channel split, filters) and route alerts (a
  separate feature borrowing the same webhook plumbing — its own toggle,
  channel, home system, max jumps and mentions).

  Neither feature gates the other. There is no "no record yet" screen asking
  for a kill webhook first: the policy row is created lazily by whichever
  control the operator touches first (`upsert/2`, `ensure_notification/1`), and
  `MapDiscordNotification`'s `create` takes an optional `webhook_url` for
  exactly that reason. An operator who wants route alerts and nothing else
  configures route alerts and nothing else.

  The organising rule is *show what is true now; everything that changes it
  goes behind an edit*. At rest the tab is a short list of statements — which
  destinations exist, where they post, whether they are delivering — and the
  controls that would change any of that are one click away. This is a hard
  constraint, not a preference: the settings dialog has no height of its own,
  so an expanded-by-default tab is a tab whose lower half cannot be reached on
  a laptop.

  Layout:

    Kill notifications — the two map-level switches (which apply on change),
                         then the kill channel and the character kill channel
                         as truth lines with an Edit/Add affordance, then a
                         "Kill filters" disclosure. The switches sit above both
                         rows because they govern both.
    Route alerts       — the toggle, home system and max jumps as one form
                         (they are validated against each other, so they commit
                         together) with the one Save that commits them, then
                         the route channel, then a "Mentions" disclosure.
    Message region     — the foot of the tab. Every control reports here.

  Every control acts on the thing it sits next to; the tab has no global
  buttons. The route trio is the only group with a Save at all, and it has one
  because those three fields cannot commit on change: `route_max_jumps` is
  typed (a per-keystroke save submits "" mid-edit against an `allow_nil? false`
  attribute) and the toggle is validated against the home system, so committing
  it alone reports a missing field the operator has not reached yet. There is
  deliberately no wholesale "remove everything": each destination has its own
  Remove, and a policy row with no destinations delivers nothing.

  Warnings and results never render inside a disclosure: something inside a
  collapsed body has not been shown to anyone.

  Disclosure state (`@open_sections`) and per-row edit state
  (`@replacing_url?`) both live on the server. Client-only `JS.toggle_class`
  was tried first and is wrong here: this component re-renders on saves,
  PubSub ticks and background channel-identity refreshes, each of which
  re-sends the literal collapsed markup and slams an open section shut.
  """

  use WandererAppWeb, :live_component

  require Logger

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.Api.MapSolarSystem
  alias WandererApp.Esi.CorporationSearch
  alias WandererApp.ExternalEvents.Discord.ChannelInfo
  alias WandererApp.ExternalEvents.Discord.Guild
  alias WandererApp.ExternalEvents.Discord.Mentions

  @excluded_select_id "excluded_system_live_select_component"
  @focus_corp_select_id "focus_corp_live_select_component"
  @home_system_select_id "home_system_live_select_component"
  @mention_user_select_id "mention_user_live_select_component"
  @mention_role_select_id "mention_role_live_select_component"
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
  def update(%{channel_info_refreshed: true}, socket) do
    # A background channel-identity refresh landed and the cache is now warm.
    # Only the hints are recomputed: the refresh wrote cached identity and
    # nothing else, so reloading the record here would throw away whatever the
    # operator has typed into the forms since the tab was opened.
    {:ok,
     socket
     |> assign_channel_hints(socket.assigns.webhooks)
     |> assign_mention_guild(socket.assigns.webhooks[:route])
     |> request_guild_roles()}
  end

  # The guild's role list landed. Only accepted for the guild currently on
  # screen: an operator who repointed the route destination while the request
  # was in flight must not get the previous guild's roles offered as if they
  # were valid here — they would save cleanly and ping nobody.
  def update(%{guild_roles: {guild_id, result}}, socket) do
    if guild_id == socket.assigns[:mention_guild_id] do
      {:ok,
       socket
       |> assign(:guild_roles, result)
       |> learn_role_labels(result)}
    else
      {:ok, socket}
    end
  end

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
     |> assign(:mention_user_select_id, @mention_user_select_id)
     |> assign(:mention_role_select_id, @mention_role_select_id)
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
     # Which disclosures are open. `assign_new`, so the set survives every
     # `update/2` the parent triggers — a save, a PubSub tick or a background
     # channel-identity refresh must not close a section the operator is
     # working inside.
     |> assign_new(:open_sections, fn -> MapSet.new() end)
     # Labels are decoration accumulated from whatever Discord has answered so
     # far, and they deliberately survive `assign_notification/2`: a chip that
     # reads "Scouts" must not flip back to a raw snowflake because the
     # operator saved an unrelated field. Ids are the state; see the mention
     # helpers below.
     |> assign_new(:mention_labels, fn -> %{} end)
     |> assign_new(:guild_roles, fn -> nil end)
     |> assign_new(:mention_user_options, fn -> [] end)
     |> assign_new(:mention_role_options, fn -> [] end)
     |> assign_new(:mention_search_error, fn -> nil end)
     |> assign_new(:mention_error, fn -> nil end)
     |> assign_notification(notification)}
  end

  # --- Kill switches (`#kill-toggles-form`) -------------------------------

  # The two kill switches apply on change, with no Save of their own. They are
  # independent booleans with nothing to validate them against, they render as
  # switches (`.input type="checkbox"` is a PrimeReact switch in this app), and
  # the chip lists beside them — excluded systems, focus corporations, mention
  # targets — have always saved immediately. A Save button for two switches was
  # the third of the five Saves the tab used to carry.
  #
  # The route toggle is deliberately NOT in here: it is validated against
  # `home_system_id`, so it commits together with the home system and the jump
  # limit through the Save inside the route section. See `save-settings`.
  @impl true
  def handle_event("toggle-setting", %{"notification" => params}, socket) do
    case upsert(socket, notification_attrs(params)) do
      {:ok, rec} ->
        {:noreply, assign_notification(socket, rec)}

      {:error, error} ->
        # Re-assigning the unchanged record is what puts the switch back where
        # it was: a checkbox renders `checked` from its form value, so
        # rebuilding the form from the record reverts the optimistic flip the
        # browser already painted.
        {:noreply,
         socket
         |> assign_notification(socket.assigns.notification)
         |> put_message(:error, humanize_error(error))}
    end
  end

  # --- Route alerts and their Save (`#notification-settings-form`) ---------

  def handle_event("save-settings", %{"notification" => params}, socket) do
    case resolve_home_system(params) do
      {:ok, params} ->
        case upsert(socket, notification_attrs(params)) do
          {:ok, rec} ->
            {:noreply,
             socket
             |> assign_notification(rec)
             |> assign(:home_system_error, nil)
             |> put_message(:info, "Saved.")}

          {:error, error} ->
            {:noreply, put_message(socket, :error, humanize_error(error))}
        end

      {:error, message} ->
        {:noreply, put_home_system_error(socket, message)}
    end
  end

  # Three jobs on every change of the settings form: keep `route_toggle` (which
  # fields below are enabled — D4, disable rather than hide) in step with the
  # unsaved checkbox state, rebuild the form so the tick survives the
  # round-trip (#130 — a checkbox renders `checked` from its form value, so
  # re-rendering against the unchanged form patches the user's tick back out
  # and Save then posts `false`), and keep the Save button's dirty gate honest.
  # All three are purely client-display; the persisted values only ever change
  # through "save-settings".
  #
  # Rebuilt from `params` rather than by patching one key, so anything already
  # typed into `home_system_id` / `route_max_jumps` is preserved instead of
  # being reset to the last-saved record on every tick. This form carries no
  # `webhook_url`, so #130's credential-blanking step has nothing to do here.
  def handle_event("settings-change", %{"notification" => params}, socket) do
    rec = socket.assigns.notification

    dirty? =
      changed?(params, "route_alerts_enabled", current_route_alerts?(rec), &checked?/1) or
        changed?(params, "home_system_id", current_home_system_id(rec), &parse_home_system_id/1) or
        changed?(
          params,
          "route_max_jumps",
          current_route_max_jumps(rec),
          &parse_route_max_jumps/1
        )

    {:noreply,
     socket
     |> assign(:route_toggle, checked?(params["route_alerts_enabled"]))
     |> assign(:settings_form, rebuild_form(params, route_form_values(rec)))
     |> assign(:dirty, dirty?)}
  end

  # --- Webhook destinations (system / character / route rows) ------------

  def handle_event("toggle-section", %{"section" => section}, socket) do
    open = socket.assigns.open_sections

    open =
      if MapSet.member?(open, section),
        do: MapSet.delete(open, section),
        else: MapSet.put(open, section)

    {:noreply, assign(socket, :open_sections, open)}
  end

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

  # Creates the policy row on demand. Any destination can be the first one
  # configured on a map — including `:route`, which is the whole point of the
  # resource's `webhook_url` argument having become optional. Before that, the
  # only way to reach this screen's route half was to configure a kill channel
  # you might not want.
  def handle_event("save-webhook", %{"role" => role, "webhook" => params}, socket) do
    role = parse_role(role)

    with {:ok, rec} <- ensure_notification(socket),
         {:ok, _} <- save_webhook(rec, socket.assigns.webhooks[role], role, params) do
      {:noreply,
       socket
       |> assign_notification(reload_notification(socket.assigns.map_id))
       |> put_message(:info, "Saved.")}
    else
      {:error, error} ->
        {:noreply, put_message(socket, :error, humanize_error(error))}
    end
  end

  def handle_event("remove-webhook", %{"role" => role}, socket) do
    # All three destinations are removable. `:system` used to be exempt on the
    # grounds that "removing notifications entirely means deleting the parent
    # record" — true while a pane-level destroy existed and while `create`
    # required a kill webhook, and false now that neither does. Leaving it
    # exempt would have made the kill channel the one destination on the tab
    # that could be added but never taken away.
    #
    # Removing `:character` falls back to `:system`; removing `:route` does
    # NOT — route alerts stop entirely, because the Router deliberately has no
    # fallback for chain topology. Removing `:system` stops kill delivery for
    # systems on the map, and `Router.usable/1` drops the destination rather
    # than routing elsewhere.
    role = parse_role(role)

    case {role, socket.assigns.webhooks[role]} do
      {role, %{} = webhook} when role in [:system, :character, :route] ->
        case MapDiscordWebhook.destroy(webhook) do
          :ok ->
            {:noreply,
             socket
             |> assign_notification(reload_notification(socket.assigns.map_id))
             |> put_message(:info, "#{role_label(role)} destination removed.")}

          {:error, error} ->
            {:noreply, put_message(socket, :error, humanize_error(error))}
        end

      _ ->
        {:noreply, put_message(socket, :error, "That destination is not configured.")}
    end
  end

  # --- Mention targets ---------------------------------------------------
  #
  # Four events, mirroring `add-excluded` / `remove-excluded` exactly: each one
  # rewrites both lists and saves immediately, so there is no unsaved mention
  # state and no dirty gate to reason about.

  def handle_event("add-mention-user", %{"mention_user" => %{"mention_user" => raw}}, socket) do
    add_mention(socket, :user, raw)
  end

  def handle_event("add-mention-role", %{"mention_role" => %{"mention_role" => raw}}, socket) do
    add_mention(socket, :role, raw)
  end

  # The D7 manual fallback. Same validation, same save — the only difference is
  # where the id came from, which is why it converges on `add_mention/3` rather
  # than carrying its own path to the resource.
  def handle_event("add-mention-id", %{"kind" => kind, "mention_id" => %{"value" => raw}}, socket) do
    add_mention(socket, mention_kind(kind), raw)
  end

  def handle_event("remove-mention", %{"kind" => kind, "id" => id}, socket) do
    case mention_kind(kind) do
      :user ->
        save_mentions(
          socket,
          List.delete(socket.assigns.mention_users, id),
          socket.assigns.mention_roles
        )

      :role ->
        save_mentions(
          socket,
          socket.assigns.mention_users,
          List.delete(socket.assigns.mention_roles, id)
        )
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

  # Roles are filtered in memory: `Guild.roles/1` already returned the whole
  # list, so a keystroke here is a `String.contains?` rather than a request.
  def handle_event(
        "live_select_change",
        %{"id" => @mention_role_select_id, "text" => text},
        socket
      ) do
    options =
      case socket.assigns.guild_roles do
        {:ok, roles} -> role_options(roles, text)
        _unavailable -> []
      end

    send_update(LiveSelect.Component, id: @mention_role_select_id, options: options)

    {:noreply, assign(socket, :mention_role_options, options)}
  end

  # Members, unlike roles, cannot be listed — the search IS the lookup, so this
  # one does go to Discord per keystroke (debounced by the picker).
  def handle_event(
        "live_select_change",
        %{"id" => @mention_user_select_id, "text" => text},
        socket
      ) do
    {options, error} = search_members(socket.assigns[:mention_guild_id], text)

    send_update(LiveSelect.Component, id: @mention_user_select_id, options: options)

    {:noreply,
     socket
     |> assign(:mention_user_options, options)
     |> assign(:mention_search_error, error)
     |> learn_labels(:user, member_entries(options))}
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
      _ -> {:noreply, put_message(socket, :error, "Pick a system from the list.")}
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
      _ -> {:noreply, put_message(socket, :error, "Could not remove that system.")}
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
      _ -> {:noreply, put_message(socket, :error, "Pick a corporation from the list.")}
    end
  end

  def handle_event("remove-focus-corp", %{"corp_id" => raw}, socket) do
    with %{} = rec <- socket.assigns.notification,
         {id, ""} <- Integer.parse(to_string(raw)) do
      update_focus_corps(socket, rec, Enum.reject(rec.focus_corp_ids, &(&1 == id)))
    else
      _ -> {:noreply, put_message(socket, :error, "Could not remove that corporation.")}
    end
  end

  def handle_event("send-test", %{"webhook_id" => webhook_id}, socket) do
    case send_test(socket, webhook_id) do
      # `:ok` means the message was ENQUEUED — the last hop is an async cast, so
      # this must not claim Discord accepted it.
      :ok ->
        {:noreply, put_message(socket, :info, "Test message queued.")}

      {:error, :notifications_disabled} ->
        {:noreply,
         put_message(
           socket,
           :error,
           "Discord notifications are disabled on this server. Ask an administrator to enable them."
         )}

      {:error, :webhook_disabled} ->
        {:noreply,
         put_message(
           socket,
           :error,
           "This destination is disabled. Enable it and save before sending a test message."
         )}

      # Two distinct dispatcher answers, one message on purpose: "no such row"
      # and "row with no usable URL" are worth telling apart in a log or a test,
      # but a user can do nothing about either except save a URL, and this
      # wording is brief-mandated verbatim.
      {:error, reason} when reason in [:webhook_not_found, :webhook_url_missing] ->
        {:noreply, put_message(socket, :error, "Save a webhook URL first.")}

      {:error, other} ->
        # `inspect(other)` here put the raw failure term — which can carry the
        # webhook URL — into the LiveView diff. Log a shape summary instead.
        Logger.warning("[MapNotifications] test message failed: #{error_summary(other)}")

        {:noreply,
         put_message(
           socket,
           :error,
           "Could not send a test message. Check the webhook URL and try again."
         )}
    end
  end

  # There is deliberately no "remove everything" event. Each destination has its
  # own Remove, and a policy row with no destinations delivers nothing — so the
  # only thing a wholesale destroy did that the per-row removes do not was
  # discard invisible filter and mention state, at the cost of parking the
  # tab's most destructive control in a permanent action bar.

  # One message region for the whole pane, at its foot. It used to be two
  # (`scope: :kills | :route`), which only made sense while the tab had a Save
  # per section and the two sections were far enough apart that a result had to
  # land next to the control that produced it.
  defp put_message(socket, kind, text) do
    assign(socket, :message, %{kind: kind, text: text})
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

  # `mention_targets` is deliberately absent from every branch here. It left
  # this form in D3 and is now chip state saved by its own events — passing it
  # would mean reading a field the form no longer renders, i.e. `nil`, i.e.
  # every URL edit silently wiping the map's configured pings.
  defp save_webhook(rec, nil, role, %{"webhook_url" => url})
       when is_binary(url) and url != "" do
    MapDiscordWebhook.create(%{
      notification_id: rec.id,
      role: role,
      webhook_url: url
    })
  end

  defp save_webhook(_rec, nil, _role, _params), do: {:error, "Enter a webhook URL first."}

  defp save_webhook(_rec, webhook, _role, %{"webhook_url" => url} = params)
       when is_binary(url) and url != "" do
    MapDiscordWebhook.update(webhook, %{
      webhook_url: url,
      enabled?: checked?(params["enabled"])
    })
  end

  # This branch used to call `MapDiscordWebhook.set_enabled/2`, whose accept
  # list is `[:enabled?]` only. It goes through the general `update` action
  # instead — `set_enabled` itself is untouched and still used by other callers
  # (see `router_test.exs`, `worker_test.exs`), this is only this handler's own
  # dispatch.
  defp save_webhook(_rec, webhook, _role, params) do
    MapDiscordWebhook.update(webhook, %{enabled?: checked?(params["enabled"])})
  end

  # Every write on this tab funnels through here: the policy row is created
  # lazily by whichever control the operator touched first, with no webhook
  # attached. `create`'s `webhook_url` argument is optional for exactly this
  # (map_discord_notification.ex) — the destinations are then added through
  # "save-webhook" like any later one.
  defp upsert(socket, attrs) do
    case socket.assigns.notification do
      nil -> attrs |> Map.put(:map_id, socket.assigns.map_id) |> MapDiscordNotification.create()
      rec -> MapDiscordNotification.update(rec, attrs)
    end
  end

  defp ensure_notification(socket) do
    case socket.assigns.notification do
      nil -> MapDiscordNotification.create(%{map_id: socket.assigns.map_id})
      rec -> {:ok, rec}
    end
  end

  # Record-or-default readers, so the dirty gate and the form values work the
  # same before and after the policy row exists. Each mirrors the resource's
  # own default for the attribute.
  defp current_route_alerts?(nil), do: false
  defp current_route_alerts?(%{route_alerts_enabled?: value}), do: value

  defp current_home_system_id(nil), do: nil
  defp current_home_system_id(%{home_system_id: value}), do: value

  defp current_route_max_jumps(nil), do: @default_route_max_jumps
  defp current_route_max_jumps(%{route_max_jumps: value}), do: value

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
        {:noreply, put_message(socket, :error, humanize_error(error))}
    end
  end

  defp update_focus_corps(socket, rec, corp_ids) do
    case MapDiscordNotification.update(rec, %{focus_corp_ids: corp_ids}) do
      {:ok, updated} ->
        {:noreply, assign_notification(socket, updated)}

      {:error, error} ->
        {:noreply, put_message(socket, :error, humanize_error(error))}
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
    |> assign(:route_toggle, current_route_alerts?(notification))
    |> assign(:dirty, false)
    |> assign(:excluded_systems, excluded_system_labels(notification))
    |> assign(:focus_corps, focus_corp_labels(notification))
    |> assign(:home_system_options, home_system_options(notification))
    |> assign(:kills_form, kills_form(notification))
    |> assign(:settings_form, route_form(notification))
    |> assign(:webhook_forms, webhook_forms(webhooks))
    |> assign(:excluded_form, to_form(%{"excluded_system" => nil}, as: :excluded))
    |> assign(:focus_corp_form, to_form(%{"focus_corp" => nil}, as: :focus_corp))
    |> assign_replacing(webhooks)
    |> assign_channel_hints(webhooks)
    |> assign_mentions(webhooks)
    |> request_guild_roles()
  end

  ## Mention targets (D3) --------------------------------------------------
  #
  # Stored as `["user:<id>", "role:<id>", ...]` on the route webhook. On screen
  # they are two independent chip lists edited by discrete events that save
  # immediately, exactly like excluded systems and focus corporations — not a
  # form field, so they are outside the dirty gate and cannot be wiped by a
  # save that never rendered them.
  #
  # **The id is the state; the label is decoration.** The chip lists here are
  # ids only, split out of what is stored, with no lookup involved. That is the
  # property that makes a target impossible to lose: recombination writes the
  # same ids back, so an entry whose name was never resolved round-trips
  # byte-identically instead of being silently dropped for lacking one.

  defp assign_mentions(socket, webhooks) do
    route = Map.get(webhooks, :route)
    targets = (route && route.mention_targets) || []

    socket
    |> assign(:mention_users, mention_ids(targets, "user"))
    |> assign(:mention_roles, mention_ids(targets, "role"))
    |> assign_mention_guild(route)
    |> assign(:mention_error, nil)
  end

  # The cached hint is preferred over the stored column because it is the
  # fresher of the two: a background `ChannelInfo` refresh writes the row and
  # warms the cache, but the record already in this socket predates it. Reading
  # the hint is what lets the pickers come alive on the same refresh that names
  # the channel, instead of on the next full reload.
  defp assign_mention_guild(socket, route) do
    guild_id =
      case socket.assigns[:channel_hints][:route] do
        %{guild_id: guild_id} when is_binary(guild_id) -> guild_id
        _no_hint -> route && route.guild_id
      end

    assign(socket, :mention_guild_id, guild_id)
  end

  defp mention_ids(targets, prefix) do
    for target <- targets,
        [^prefix, id] <- [String.split(target, ":", parts: 2)],
        do: id
  end

  # Fetches the guild's roles off the render path, for the same reason
  # `ChannelInfo.describe/2` refuses to block: this is an HTTP call with a
  # multi-second leash, and the settings dialog must open now. The reply comes
  # back through `MapsLive` as `{:discord_guild_roles, guild_id, result}` — a
  # three-tuple for the same reason the channel-refresh message is one.
  #
  # Requested once per guild. `assign_notification/2` runs on every save, and
  # re-asking each time would put a request behind every button on the tab.
  defp request_guild_roles(socket) do
    guild_id = socket.assigns[:mention_guild_id]
    pid = self()

    cond do
      is_nil(guild_id) ->
        assign(socket, :guild_roles, {:error, :no_guild})

      socket.assigns[:guild_roles_requested_for] == guild_id ->
        socket

      true ->
        Task.Supervisor.start_child(WandererApp.TaskSupervisor, fn ->
          send(pid, {:discord_guild_roles, guild_id, Guild.roles(guild_id)})
        end)

        socket
        |> assign(:guild_roles_requested_for, guild_id)
        |> assign(:guild_roles, :loading)
    end
  end

  defp learn_role_labels(socket, {:ok, roles}) do
    learn_labels(socket, :role, roles)
  end

  defp learn_role_labels(socket, _result), do: socket

  defp learn_labels(socket, kind, entries) do
    labels =
      Enum.reduce(entries, socket.assigns.mention_labels, fn %{id: id, name: name}, acc ->
        Map.put(acc, {kind, id}, name)
      end)

    assign(socket, :mention_labels, labels)
  end

  # Whether the typeahead can work at all. Both pickers need the same bot token
  # and the same guild membership, so one signal drives both: a guild we cannot
  # read roles from is one we cannot search members in either, and asking the
  # operator to discover that by typing into a dropdown that stays empty is
  # exactly the failure D7 exists to prevent.
  defp mention_picker_available?(%{guild_roles: {:error, reason}}),
    do: not Guild.unavailable?(reason)

  defp mention_picker_available?(_assigns), do: true

  # Every one of these is read by an operator who is mid-task and wants to know
  # whether they can proceed. So each says what still works (typing ids always
  # does), and the one with an actionable cause names it: searching by name
  # needs a bot token, `DISCORD_BOT_TOKEN`, set on the server — which is a
  # deployment change, not something this screen can offer a button for.
  defp mention_unavailable_reason(%{guild_roles: {:error, :no_bot_token}}),
    do:
      "Searching Discord names needs a bot token (DISCORD_BOT_TOKEN) on the server, and this " <>
        "one has none. Mentions still work — paste the user or role id instead."

  defp mention_unavailable_reason(%{guild_roles: {:error, :no_guild}}),
    do:
      "The Discord server behind this channel is not known yet. It resolves once the bot can " <>
        "see the channel; until then, paste ids instead."

  defp mention_unavailable_reason(%{guild_roles: {:error, _reason}}),
    do: "The bot cannot read this Discord server, so names cannot be searched. Paste ids instead."

  defp mention_unavailable_reason(_assigns), do: nil

  # Chip text. A target whose name was never resolved renders as its raw id
  # rather than being hidden — it is saved, it pings, and it must be removable.
  defp mention_label(labels, kind, id) do
    case Map.get(labels, {kind, id}) do
      nil -> id
      name -> name
    end
  end

  defp mention_labelled?(labels, kind, id), do: Map.has_key?(labels, {kind, id})

  # Takes a bare snowflake from the manual fallback and validates it through
  # the same `Mentions.valid_target?/1` the dispatcher uses, without asking the
  # operator to retype a `user:`/`role:` prefix the input they typed into
  # already implies.
  defp add_mention(socket, kind, raw) do
    case parse_mention_id(kind, raw) do
      {:ok, id} ->
        users = socket.assigns.mention_users
        roles = socket.assigns.mention_roles

        case kind do
          :user -> save_mentions(socket, Enum.uniq(users ++ [id]), roles)
          :role -> save_mentions(socket, users, Enum.uniq(roles ++ [id]))
        end

      {:error, message} ->
        {:noreply, assign(socket, :mention_error, message)}
    end
  end

  defp mention_kind("role"), do: :role
  defp mention_kind(_kind), do: :user

  defp parse_mention_id(kind, raw) when is_binary(raw) do
    target = "#{kind}:#{String.trim(raw)}"

    if Mentions.valid_target?(target) do
      {:ok, String.trim(raw)}
    else
      {:error,
       "That is not a Discord id. Copy the numeric id (17-20 digits) from Discord — " <>
         "handles like @name do not work here."}
    end
  end

  defp parse_mention_id(_kind, _raw), do: {:error, "Enter a Discord id."}

  # Writes both lists back as one `mention_targets` value. Ids only: nothing
  # here can consult a label, so nothing here can drop a target for missing
  # one.
  defp save_mentions(socket, users, roles) do
    case socket.assigns.webhooks[:route] do
      nil ->
        {:noreply,
         put_message(socket, :error, "Add a route alert channel before setting mentions.")}

      webhook ->
        targets =
          Enum.map(users, &"user:#{&1}") ++ Enum.map(roles, &"role:#{&1}")

        case MapDiscordWebhook.update(webhook, %{mention_targets: targets}) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign_notification(reload_notification(socket.assigns.map_id))
             |> assign(:mention_error, nil)}

          {:error, error} ->
            {:noreply, put_message(socket, :error, humanize_error(error))}
        end
    end
  end

  # Resolved into an assign rather than called from the template, for two
  # reasons. The template re-renders on every typeahead keystroke and this is a
  # cache read per destination each time; and, more importantly, an assign is
  # something LiveView's change tracking can see — a hint computed inside the
  # template depends only on `@webhook`, so a background refresh landing would
  # update the cache and change nothing on screen.
  #
  # `notify: self()` is the other half: inside a LiveComponent callback `self()`
  # is the parent LiveView's pid, which is what routes the refresh back through
  # `MapsLive` to `send_update/3`.
  defp assign_channel_hints(socket, webhooks) do
    hints =
      Map.new(@roles, fn role ->
        {role, describe_channel(Map.get(webhooks, role))}
      end)

    assign(socket, :channel_hints, hints)
  end

  defp describe_channel(nil), do: nil

  defp describe_channel(webhook) do
    case ChannelInfo.describe(webhook, notify: self()) do
      {:ok, info} -> info
      {:error, _reason} -> nil
    end
  end

  # A destination is in entry mode only when the operator asked for it, via
  # "Add" (no webhook yet) or "Edit" (replacing a stored URL). It used to open
  # automatically for every unconfigured role, which was invisible while the
  # character and route rows were themselves hidden behind a link and a
  # disclosure. Now that all three rows always render, auto-opening would put
  # three credential fields on screen before the operator has asked for one.
  defp assign_replacing(socket, _webhooks) do
    assign(socket, :replacing_url?, Map.new(@roles, &{&1, false}))
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
    |> to_form(as: :notification)
  end

  defp kills_form(notification), do: to_form(kills_form_values(notification), as: :notification)

  # No `webhook_url` here any more. It existed for the old "no record yet"
  # create form, which asked for a kill webhook before the tab would show
  # anything else. Destinations are now added through their own rows, at any
  # time, in any order.
  defp kills_form_values(notification) do
    %{
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
      "route_alerts_enabled" => current_route_alerts?(notification),
      "home_system_id" => home_system_id_value(notification),
      "route_max_jumps" => current_route_max_jumps(notification)
    }
  end

  defp home_system_id_value(nil), do: ""
  defp home_system_id_value(%{home_system_id: nil}), do: ""
  defp home_system_id_value(%{home_system_id: id}), do: to_string(id)

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
            "enabled" => is_nil(webhook) or webhook.enabled?
          },
          as: :webhook
        )

      {role, form}
    end)
  end

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

  # Role search is local — the whole list is already in `@guild_roles`. A blank
  # query lists everything, which is the useful behaviour for a guild with a
  # handful of roles and the reason this picker has no minimum length.
  defp role_options(roles, text) do
    wanted = text |> to_string() |> String.trim() |> String.downcase()

    roles
    |> Enum.filter(fn %{name: name} ->
      wanted == "" or String.contains?(String.downcase(name), wanted)
    end)
    |> Enum.take(@max_search_results)
    |> Enum.map(fn %{id: id, name: name} -> {name, id} end)
  end

  # Member search does go to Discord. Failures render next to the box rather
  # than only in the log: an empty dropdown is indistinguishable from a guild
  # with no matching members, which is the ambiguity D7 exists to remove.
  defp search_members(guild_id, text) when is_binary(guild_id) do
    case Guild.search_members(guild_id, text, limit: @max_search_results) do
      {:ok, members} ->
        {Enum.map(members, fn %{id: id, name: name} -> {name, id} end), nil}

      {:error, reason} ->
        {[], member_search_error(reason)}
    end
  end

  defp search_members(_guild_id, _text), do: {[], nil}

  defp member_search_error(reason) do
    if Guild.unavailable?(reason) do
      "Add the bot to this guild to search names. You can still add ids manually."
    else
      "Member search is unavailable right now. Try again in a moment. (#{inspect(reason)})"
    end
  end

  defp member_entries(options), do: Enum.map(options, fn {name, id} -> %{id: id, name: name} end)

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
  # Whichever tier answered, the string is safe to show: a `:channel` label is
  # the channel's own "#name", and the fallback is a truncated non-reversible
  # digest that is never derived from the token.
  #
  # The label is spoken plainly, with no "Channel:" / "Webhook:" prefix. Whether
  # Discord answered from the channel or from the webhook's own nickname is a
  # distinction about how the name was *fetched*, not about where the messages
  # land — and the operator has nothing to do differently either way. `source`
  # is still persisted (`channel_label_source`) because it separates a masked
  # fingerprint from a known name, which is what `masked?` below turns on.
  defp channel_label(%{label: label}) when is_binary(label), do: label
  defp channel_label(_no_info), do: nil

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

  defp status_line(nil, _channel_info), do: nil

  # The channel half is dropped rather than rendered empty when the identity is
  # not resolved: "Posting to channel  · no kills yet" reads as a missing value,
  # and the identity is genuinely unknown often enough (no bot, a webhook whose
  # channel was deleted, a refresh still in flight) for that to be the common
  # first impression rather than an edge case.
  defp status_line(webhook, channel_info) do
    case channel_label(channel_info) do
      nil -> last_kill_text(webhook)
      destination -> "Posting to #{destination} · #{last_kill_text(webhook)}"
    end
  end

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

  # The only surviving disclosure starts collapsed unconditionally (D2), so the
  # badge is the whole signal: it has to report a problem inside the body as
  # well as a count, or a failed search is invisible until someone happens to
  # open the section.
  defp filters_badge(excluded_systems, focus_corps, system_search_error, corp_search_error) do
    [
      excluded_count_label(length(excluded_systems)),
      focus_corp_count_label(length(focus_corps)),
      if(system_search_error || corp_search_error, do: "needs attention")
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

  # --- Function components ---------------------------------------------

  # Open/closed lives in `@open_sections` on the server, not in a
  # `JS.toggle_class` on the client. The client-only version was the pattern
  # copied from characters_live.html.heex, and it is wrong for this panel: every
  # save, every background channel-identity refresh and every PubSub-driven
  # re-render re-sends this markup with its literal `hidden` and its literal
  # `aria-expanded="false"`, slamming an open section shut mid-edit and leaving
  # the toggled attribute claiming the opposite of what is on screen. Round-trip
  # cost is one small diff; the alternative is state that silently desyncs.
  #
  # Sections start collapsed. They used to start open whenever the body held a
  # problem, which made the initial state depend on transient message state; the
  # cause is gone instead — results render in a card-level message region that
  # is never collapsed, and `@badge` reports trouble inside the body.
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :badge, :string, default: nil
  attr :open?, :boolean, default: false
  attr :myself, :any, required: true
  slot :inner_block, required: true

  defp disclosure(assigns) do
    ~H"""
    <div class="rounded border border-white/10">
      <button
        type="button"
        aria-expanded={to_string(@open?)}
        aria-controls={"#{@id}-body"}
        phx-click="toggle-section"
        phx-value-section={@id}
        phx-target={@myself}
        class="flex w-full items-center justify-between gap-2 px-3 py-2 text-left"
      >
        <span class="flex items-center gap-2 text-sm font-semibold">
          <span
            aria-hidden="true"
            class={["inline-block transition-transform", @open? && "rotate-90"]}
          >
            ▸
          </span>
          {@title}
        </span>
        <span :if={@badge} class="text-xs opacity-70">{@badge}</span>
      </button>

      <%!-- Toggled by class, not by `:if`: `aria-controls` above must resolve
            to a real element even while collapsed, and the LiveSelect hooks
            inside these bodies would be destroyed and re-mounted if the markup
            left the DOM. The `hidden` class rather than the HTML attribute,
            because a utility-layer `flex` would win over preflight's
            `[hidden] { display: none }`. --%>
      <div
        id={"#{@id}-body"}
        class={[
          "flex-col gap-3 border-t border-white/10 p-3",
          if(@open?, do: "flex", else: "hidden")
        ]}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # One message region for the whole tab, at its foot. It used to be two, keyed
  # by a `scope` on the message — which only made sense while the tab had a Save
  # per section and those sections were far enough apart that a result had to
  # land next to the control that produced it. Every control now acts where it
  # stands, so there is one place a result belongs, in view from all of them.
  attr :message, :any, default: nil

  defp panel_message(assigns) do
    ~H"""
    <p :if={@message} id="panel-message" class={message_class(@message.kind)}>
      {@message.text}
    </p>
    """
  end

  defp message_class(:error), do: "text-sm text-red-400"
  # Deliberately not green. Green is already spoken for by `status_class/1`'s
  # `:delivering` pill, and a transient "Saved." in the same colour a few lines
  # away reads as a second status rather than an acknowledgement.
  defp message_class(:info), do: "text-sm text-sky-400"

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
    <li class="badge badge-ghost badge-sm gap-1">
      <span>{@label}</span>
      <button
        type="button"
        class="opacity-70 hover:opacity-100"
        aria-label={"Remove #{@label}"}
        {@rest}
      >
        ✕
      </button>
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
  # Why an operator would want this destination, in one line. Shown whenever
  # the row is not configured — the state in which that question is actually
  # being asked — and while editing, where it explains what is being replaced.
  # Suppressed on a configured, closed row, where the channel name on the same
  # line already answers it.
  attr :help, :string, default: nil
  attr :webhook, :any, required: true
  attr :form, :any, required: true
  attr :replacing?, :boolean, required: true
  attr :removable?, :boolean, required: true
  # The kill row's delivery status is promoted to the card level (P1
  # hierarchy) — the status line and failure line live just above this
  # component, so repeating them here would be the exact "identical to the help
  # text above it" problem being fixed. The other rows keep their own status.
  attr :show_status?, :boolean, default: true
  # What the status block says when nothing has ever been delivered. The
  # default is the kill wording because two of the three rows are kill
  # destinations; the route row overrides it, because "No kills delivered yet"
  # under a channel that only ever carries route alerts reads as a fault.
  attr :empty_status_text, :string, default: "No kills delivered yet."
  attr :myself, :any, required: true

  # Resolved identity for `@webhook`, or nil. Passed in rather than looked up
  # here so that a background refresh landing has an assign to invalidate.
  attr :channel_info, :map, default: nil

  defp webhook_row(assigns) do
    ~H"""
    <div id={"webhook-row-#{@role}"} class="flex flex-col gap-1">
      <%!-- Closed — configured or not. One line of truth: what this row is,
            where it posts (or that it does not), whether that is working, and
            the one control that opens everything else. The URL field, the
            enabled toggle, Save, test and remove all live behind Edit/Add,
            because none of them describe the current state and all of them
            cost vertical space on every render of a tab that already does not
            fit.

            An unconfigured row renders here too, rather than opening its form
            on sight. All three destinations are always listed now, and three
            credential fields on arrival is not an introduction to a feature —
            it is a form nobody asked for.

            A degraded or disabled destination still says so here rather than
            auto-expanding: expanding would put a credential field on screen
            unasked, and the operator needs to read the fault before deciding
            to touch the URL. --%>
      <div :if={!@replacing?} class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <h4 class="text-sm font-semibold">{@title}</h4>

        <span :if={@webhook && channel_label(@channel_info)} class="text-sm opacity-70">
          {channel_label(@channel_info)}
        </span>
        <span :if={is_nil(@webhook)} class="text-sm opacity-50">Not set</span>

        <span
          :if={@webhook && @show_status?}
          class={["text-xs font-semibold", status_class(status_state(@webhook))]}
        >
          ● {status_label(status_state(@webhook))}
        </span>

        <.button
          type="button"
          variant={:ghost}
          phx-click="replace-url"
          phx-value-role={@role}
          phx-target={@myself}
        >
          {if @webhook, do: "Edit", else: "Add"}
        </.button>
      </div>

      <p
        :if={@webhook && !@replacing? && @show_status? && @webhook.last_error}
        class="text-sm text-amber-400"
      >
        Last error: {@webhook.last_error}
        <span :if={@webhook.consecutive_failures > 0}>
          ({@webhook.consecutive_failures} consecutive failures)
        </span>
      </p>

      <p :if={@help && (is_nil(@webhook) || @replacing?)} class="text-xs opacity-70">{@help}</p>

      <.form
        :let={wf}
        :if={@replacing?}
        for={@form}
        id={"webhook-form-#{@role}"}
        phx-submit="save-webhook"
        phx-value-role={@role}
        phx-target={@myself}
        class="flex flex-col gap-2 pt-1"
      >
        <.input
          field={wf[:webhook_url]}
          type="password"
          label="Discord webhook URL"
          placeholder={
            if @webhook,
              do: "Leave blank to keep the current URL",
              else: "https://discord.com/api/webhooks/..."
          }
          autocomplete="off"
        />

        <.input :if={@webhook} field={wf[:enabled]} type="checkbox" label="Enabled" />

        <div :if={@webhook} class="text-sm opacity-70">
          <span :if={@webhook.last_delivery_at}>
            Last delivered: {Calendar.strftime(@webhook.last_delivery_at, "%Y-%m-%d %H:%M UTC")}
          </span>
          <span :if={is_nil(@webhook.last_delivery_at)}>{@empty_status_text}</span>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <.button type="submit" variant={:primary}>
            {if @webhook, do: "Save", else: "Add"}
          </.button>
          <.button
            type="button"
            variant={:ghost}
            phx-click="cancel-replace"
            phx-value-role={@role}
            phx-target={@myself}
          >
            Cancel
          </.button>
          <.button
            :if={@webhook}
            type="button"
            phx-click="send-test"
            phx-value-webhook_id={@webhook.id}
            phx-target={@myself}
          >
            Send test message
          </.button>
          <.button
            :if={@webhook && @removable?}
            type="button"
            variant={:danger}
            phx-click="remove-webhook"
            phx-value-role={@role}
            phx-target={@myself}
            data-confirm="Remove this Discord destination?"
          >
            Remove
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  # Mention targets for the route alert channel. Rendered as chips plus two
  # pickers rather than a CSV field: a Discord mention of an id that does not
  # exist in this guild renders as inert text with no error, so the only
  # reliable defence is to source ids from the guild itself.
  attr :users, :list, required: true
  attr :roles, :list, required: true
  attr :labels, :map, required: true
  attr :guild_roles, :any, required: true
  attr :picker_available?, :boolean, required: true
  attr :unavailable_reason, :string, default: nil
  attr :user_select_id, :string, required: true
  attr :role_select_id, :string, required: true
  attr :user_options, :list, required: true
  attr :role_options, :list, required: true
  attr :search_error, :string, default: nil
  attr :error, :string, default: nil
  attr :myself, :any, required: true

  defp mentions_section(assigns) do
    ~H"""
    <div id="route-mentions" class="flex flex-col gap-3">
      <%!-- No heading or border of its own: this now renders inside the
            "Mentions" disclosure, which supplies both. --%>
      <p class="text-xs opacity-70">
        Who to ping when a route opens. Leave both empty to post with no ping.
      </p>

      <.mention_group
        kind={:role}
        title="Roles"
        chips={@roles}
        labels={@labels}
        empty="No roles pinged."
        myself={@myself}
      />
      <.mention_group
        kind={:user}
        title="Users"
        chips={@users}
        labels={@labels}
        empty="No users pinged."
        myself={@myself}
      />

      <div :if={@picker_available?} class="flex flex-col gap-2">
        <.form
          :let={f}
          for={to_form(%{}, as: :mention_role)}
          id="mention-role-form"
          phx-change="add-mention-role"
          phx-target={@myself}
        >
          <.live_select
            field={f[:mention_role]}
            id={@role_select_id}
            phx-target={@myself}
            label="Add a role"
            mode={:single}
            compact={true}
            debounce={150}
            update_min_len={0}
            options={@role_options}
            dropdown_extra_class="!h-24"
            placeholder={
              if @guild_roles == :loading, do: "Loading roles…", else: "Search roles in this server"
            }
          />
        </.form>

        <.form
          :let={f}
          for={to_form(%{}, as: :mention_user)}
          id="mention-user-form"
          phx-change="add-mention-user"
          phx-target={@myself}
        >
          <.live_select
            field={f[:mention_user]}
            id={@user_select_id}
            phx-target={@myself}
            label="Add a user"
            mode={:single}
            compact={true}
            debounce={250}
            update_min_len={2}
            options={@user_options}
            dropdown_extra_class="!h-24"
            placeholder="Search members in this server"
          />
        </.form>

        <p :if={@search_error} class="text-sm text-amber-400">{@search_error}</p>
      </div>

      <%!-- D7's fallback. Reached whenever the guild cannot be read at all —
            no bot on this instance, no resolved guild yet, or a bot that is
            not in this operator's server. Typing an id is still the whole
            feature, so the section stays usable rather than disappearing. --%>
      <div :if={!@picker_available?} class="flex flex-col gap-2">
        <p :if={@unavailable_reason} class="text-sm opacity-70">{@unavailable_reason}</p>

        <.mention_manual_form kind="role" label="Add a role by id" myself={@myself} />
        <.mention_manual_form kind="user" label="Add a user by id" myself={@myself} />
      </div>

      <p :if={@error} class="text-sm text-red-400">{@error}</p>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :title, :string, required: true
  attr :chips, :list, required: true
  attr :labels, :map, required: true
  attr :empty, :string, required: true
  attr :myself, :any, required: true

  defp mention_group(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <span class="text-xs uppercase tracking-wide opacity-60">{@title}</span>
      <p :if={@chips == []} class="text-sm opacity-70">{@empty}</p>
      <div :if={@chips != []} class="flex flex-wrap gap-1">
        <span :for={id <- @chips} class="badge badge-ghost badge-sm gap-1">
          <%!-- The label is decoration over the id, which is the state. An id
                with no learned name still renders — as the id — rather than
                vanishing from a list the operator saved. --%>
          <span title={if mention_labelled?(@labels, @kind, id), do: id}>
            @{mention_label(@labels, @kind, id)}
          </span>
          <button
            type="button"
            class="opacity-70 hover:opacity-100"
            aria-label={"Remove #{@kind} #{mention_label(@labels, @kind, id)}"}
            phx-click="remove-mention"
            phx-value-kind={@kind}
            phx-value-id={id}
            phx-target={@myself}
          >
            ✕
          </button>
        </span>
      </div>
    </div>
    """
  end

  attr :kind, :string, required: true
  attr :label, :string, required: true
  attr :myself, :any, required: true

  defp mention_manual_form(assigns) do
    ~H"""
    <.form
      :let={f}
      for={to_form(%{}, as: :mention_id)}
      id={"mention-manual-#{@kind}"}
      phx-submit="add-mention-id"
      phx-value-kind={@kind}
      phx-target={@myself}
      class="flex items-end gap-2"
    >
      <.input field={f[:value]} type="text" label={@label} placeholder="17-20 digit id" />
      <.button type="submit">Add</.button>
    </.form>
    """
  end

  attr :notification, :any, required: true
  attr :webhooks, :any, required: true
  attr :route_toggle, :boolean, required: true

  # D4's reachable warning: both halves of "disable, don't hide". The
  # alerts-on-but-no-channel case is the pre-existing guard; the
  # alerts-off-but-configured case is the P0 this rework was written for.
  #
  # Neither carries an action button any more. "Enable route alerts" was a
  # second, differently-shaped control for a checkbox that is now three lines
  # away and always visible — two places to do one thing, one of which
  # committed immediately while the other waited for Save.
  defp route_alert_banner(assigns) do
    ~H"""
    <p
      :if={route_alert_on_no_channel?(@notification, @webhooks[:route], @route_toggle)}
      class="text-sm text-amber-400"
    >
      Route alerts are on, but no route alert channel is ready — nothing is being sent.
    </p>

    <p :if={route_inert?(@notification, @webhooks[:route])} class="text-sm text-amber-400">
      Route alerts are switched off, but this channel is configured — nothing is being sent to it.
    </p>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex max-w-3xl flex-col gap-4">
      <%!-- One card, two subsections, no global controls. There is no longer a
            separate "no record yet" screen asking for a kill webhook before
            anything else appears: kills and route alerts are independent
            features that happen to share a policy row, and gating the second
            on the first made an implementation detail into a setup step. The
            row is created lazily by whichever control is touched first (see
            `upsert/2`). --%>
      <div class="flex flex-col gap-4 rounded border border-white/10 p-3">
        <div class="flex flex-col gap-3">
          <h3 class="text-base font-semibold">Kill notifications</h3>

          <%!-- The two switches sit ABOVE both destination rows, because they
                govern both. Underneath the character row — where they used to
                be — they read as that row's settings, which is exactly
                backwards for "Send kill notifications": it is the map-level
                master switch.

                They apply on change, with no Save of their own. A checkbox
                whose effect is deferred to a button somewhere below the fold
                is a checkbox that lies about its own state, and these two are
                the controls an operator reaches for in a hurry. The route
                fields cannot do this — they are validated against each other
                — which is what the one Save at the bottom is for. --%>
          <.form
            :let={f}
            for={@kills_form}
            id="kill-toggles-form"
            phx-change="toggle-setting"
            phx-target={@myself}
            class="flex flex-col gap-2"
          >
            <.input field={f[:enabled]} type="checkbox" label="Send kill notifications" />
            <.input field={f[:wh_only]} type="checkbox" label="Only wormhole kills" />
          </.form>

          <p :if={@webhooks[:system]} class="text-sm opacity-70">
            {status_line(@webhooks[:system], @channel_hints[:system])}
          </p>
          <p :if={@webhooks[:system] && @webhooks[:system].last_error} class="text-sm text-amber-400">
            Last error: {@webhooks[:system].last_error}
            <span :if={@webhooks[:system].consecutive_failures > 0}>
              ({@webhooks[:system].consecutive_failures} consecutive failures)
            </span>
          </p>

          <div class="flex flex-col gap-3">
            <.webhook_row
              role={:system}
              title="Kill channel"
              help="Where kills on this map are posted."
              webhook={@webhooks[:system]}
              channel_info={@channel_hints[:system]}
              form={@webhook_forms[:system]}
              replacing?={@replacing_url?[:system]}
              removable?={true}
              show_status?={false}
              myself={@myself}
            />
            <.collision_warning role={:system} collisions={@collisions} />

            <%!-- Always listed, rather than hidden behind "+ Add a separate
                  channel". That link asked the operator to commit before it
                  would say what they were committing to, and the row it
                  revealed was titled differently from the link that revealed
                  it. A named row with "Not set" beside it answers the
                  question — is there one, and what would it do — without
                  costing anything but a line. --%>
            <.webhook_row
              role={:character}
              title="Character kill channel"
              help="Optional second channel for kills involving characters tracked on this map, wherever they happen. Leave it unset and those kills go to the kill channel with the rest."
              webhook={@webhooks[:character]}
              channel_info={@channel_hints[:character]}
              form={@webhook_forms[:character]}
              replacing?={@replacing_url?[:character]}
              removable?={true}
              myself={@myself}
            />
            <.collision_warning role={:character} collisions={@collisions} />
          </div>

          <.disclosure
            id="filters-disclosure"
            title="Kill filters"
            open?={MapSet.member?(@open_sections, "filters-disclosure")}
            myself={@myself}
            badge={
              filters_badge(@excluded_systems, @focus_corps, @system_search_error, @corp_search_error)
            }
          >
            <%!-- The one sentence kept from the tab's old intro paragraph. It
                  sits here rather than at the top because it disambiguates these
                  filters specifically, and at the top it was answering a question
                  nobody had yet asked about a section that was collapsed. --%>
            <p class="text-xs opacity-70">
              Separate from the Kills widget's own filters, which are per-user and only
              change what you see on the map. Neither applies to route alerts.
            </p>

            <div class="flex flex-col gap-2">
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
                  label="Exclude a system"
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
              <%!-- Two sentences, by D10. The full routing rules — that a
                    corporation match replaces the tracked-character test rather
                    than widening it, and bypasses the excluded-system and
                    wormhole-only filters — are in docs/ZOO-FORK.md under
                    "Kill filter semantics". A four-sentence paragraph next to an
                    input is not read; it is scrolled past. --%>
              <p class="text-xs opacity-70">
                When set, the character kill channel follows these corporations instead of
                this map's tracked characters. Leave it empty to use the tracked characters.
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
                  label="Add a corporation"
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
          </.disclosure>
        </div>

        <div class="flex flex-col gap-3 border-t border-white/10 pt-4">
          <h3 class="text-base font-semibold">Route alerts</h3>

          <.route_alert_banner
            notification={@notification}
            webhooks={@webhooks}
            route_toggle={@route_toggle}
          />

          <%!-- The three route fields are one form because they are validated
                against each other: enabling alerts without a home system is
                rejected by the resource, so the toggle cannot commit on change
                the way the kill switches do. This is the form the Save button
                at the bottom of the pane submits, via `form=` — it is a submit
                button, so no hidden-companion or event-bubbling caveat
                applies, and a nested <form> would have been dropped by the
                browser outright. --%>
          <.form
            :let={rf}
            for={@settings_form}
            id="notification-settings-form"
            phx-submit="save-settings"
            phx-change="settings-change"
            phx-target={@myself}
            class="flex flex-col gap-2"
          >
            <%!-- A checkbox, not a button. "Enable route alerts" was a button
                  because the fields below it needed a home system before they
                  could be saved — but that is what the disabled fieldset and
                  the validation are for, and the operator was left with two
                  differently-shaped controls for one boolean. --%>
            <.input
              field={rf[:route_alerts_enabled]}
              type="checkbox"
              label="Send route alerts"
              phx-change="settings-change"
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
                <%!-- The visible text; the associated label on the combobox
                    itself is screen-reader-only (see `live_select/1`), so this
                    is hidden from AT to avoid announcing the name twice. --%>
                <span class="text-sm" aria-hidden="true">Home system</span>
                <.live_select
                  field={rf[:home_system_id]}
                  id={@home_system_select_id}
                  phx-target={@myself}
                  label="Home system"
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

            <%!-- Inside the form it commits, not in a pane-level action bar. The
                  three fields above are the only ones on this tab that cannot
                  apply on change: `route_max_jumps` is typed, so a per-keystroke
                  save would submit "" mid-edit against an `allow_nil? false`
                  attribute, and the toggle and home system are interdependent —
                  `validate_home_system_required/2` rejects "enabled with no home
                  system", so committing the tick on its own is exactly how an
                  operator gets told off for a field they have not reached yet.
                  Everything else on the tab acts where it stands. --%>
            <div>
              <.button type="submit" variant={:primary} disabled={not @dirty}>
                Save route alerts
              </.button>
            </div>
          </.form>

          <.webhook_row
            role={:route}
            title="Route alert channel"
            help="Where route alerts are posted. Alerts name every system on the route, unredacted — treat this channel as trusted."
            webhook={@webhooks[:route]}
            channel_info={@channel_hints[:route]}
            form={@webhook_forms[:route]}
            replacing?={@replacing_url?[:route]}
            removable?={true}
            empty_status_text="No route alerts delivered yet."
            myself={@myself}
          />
          <.collision_warning role={:route} collisions={@collisions} />

          <.disclosure
            :if={@webhooks[:route]}
            id="mentions-disclosure"
            title="Mentions"
            open?={MapSet.member?(@open_sections, "mentions-disclosure")}
            myself={@myself}
            badge={mentions_badge(@mention_users, @mention_roles)}
          >
            <.mentions_section
              users={@mention_users}
              roles={@mention_roles}
              labels={@mention_labels}
              guild_roles={@guild_roles}
              picker_available?={mention_picker_available?(assigns)}
              unavailable_reason={mention_unavailable_reason(assigns)}
              user_select_id={@mention_user_select_id}
              role_select_id={@mention_role_select_id}
              user_options={@mention_user_options}
              role_options={@mention_role_options}
              search_error={@mention_search_error}
              error={@mention_error}
              myself={@myself}
            />
          </.disclosure>
        </div>
      </div>

      <%!-- The message region is shared: every control on this tab reports here,
            not just the one Save. It sits at the foot because that is the one
            place in view from any of them. --%>
      <div class="flex flex-wrap items-center gap-3">
        <.panel_message message={@message} />
      </div>
    </div>
    """
  end

  defp mentions_badge([], []), do: "None"

  defp mentions_badge(users, roles) do
    [count_label(length(roles), "role"), count_label(length(users), "user")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp count_label(0, _noun), do: nil
  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(n, noun), do: "#{n} #{noun}s"
end
