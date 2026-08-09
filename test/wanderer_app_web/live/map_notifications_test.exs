defmodule WandererAppWeb.MapNotificationsTest do
  use WandererAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererApp.ExternalEvents.Discord.ChannelInfo
  alias WandererAppWeb.Factory

  setup %{conn: conn} do
    # `Api.Map.owner_id` points at a CHARACTER, not a user, and
    # `Factory.create_map/1` passes `owner_id` straight through. Passing a user
    # id here would fail the foreign key.
    user = Factory.insert(:user, %{})
    character = Factory.insert(:character, %{user_id: user.id})
    map = Factory.insert(:map, %{owner_id: character.id})

    %{conn: log_in_user(conn, user), map: map, user: user, character: character}
  end

  # The app has no `log_in_user/2` test helper: `UserAuth.on_mount/4` reads
  # `session["user_id"]` directly, so seeding the test session is enough.
  defp log_in_user(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  defp open_notifications(conn, map) do
    {:ok, view, _html} = live(conn, ~p"/maps/#{map.slug}/settings")
    view |> element("[phx-value-tab='notifications']") |> render_click()
    view
  end

  @home_select "home_system_live_select_component"
  @route_checkbox "input[name='notification[route_alerts_enabled]'][type='checkbox']"

  defp insert_jita do
    Factory.insert(:solar_system, %{
      solar_system_id: 30_000_142,
      solar_system_name: "Jita",
      region_name: "The Forge"
    })
  end

  # Drives the home-system typeahead the way a user does: type, then click the
  # first result. Both steps go through the component (`with_target/2` routes
  # the same way `phx-target={@myself}` does at runtime) because LiveSelect
  # installs its dropdown click handler from JS — there is no DOM click for
  # LiveViewTest to fire.
  defp pick_home_system(view, text) do
    view
    |> with_target("##{@home_select}")
    |> render_change("change", %{"text" => text})

    view
    |> with_target("#map-notifications")
    |> render_change("live_select_change", %{
      "id" => @home_select,
      "text" => text,
      "field" => "home_system_id"
    })

    view
    |> with_target("##{@home_select}")
    |> render_change("option_click", %{"idx" => "0"})

    view
  end

  # `create`'s `webhook_url` is optional but still seeds the `:system` child in
  # the same transaction when given, so `roles` here only controls whether a
  # `:character`/`:route` row is added on top. Passing `:system` in `roles`
  # would violate the (notification_id, role) identity from Task 1.
  defp notification_with_webhooks(map, roles) do
    {:ok, rec} =
      MapDiscordNotification.create(%{
        map_id: map.id,
        webhook_url: "https://discord.com/api/webhooks/#{:erlang.unique_integer([:positive])}/tok"
      })

    for role <- roles, role != :system do
      {:ok, _} =
        MapDiscordWebhook.create(%{
          notification_id: rec.id,
          role: role,
          webhook_url:
            "https://discord.com/api/webhooks/#{:erlang.unique_integer([:positive])}/tok"
        })
    end

    rec
  end

  defp system_webhook(rec) do
    {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
    Enum.find(webhooks, &(&1.role == :system))
  end

  test "owner sees the notifications tab", %{conn: conn, map: map} do
    {:ok, view, _html} = live(conn, ~p"/maps/#{map.slug}/settings")

    assert has_element?(view, "[phx-value-tab='notifications']")
  end

  test "adding the first kill webhook creates the record", %{conn: conn, map: map} do
    view = open_notifications(conn, map)

    # There is no create form any more. The kill channel is a destination row
    # like the other two, listed as "Not set" with an Add button, and adding it
    # is what brings the policy row into existence (`ensure_notification/1`).
    edit_row(view, :system)

    view
    |> form("#webhook-form-system", %{
      "webhook" => %{"webhook_url" => "https://discord.com/api/webhooks/123/tok"}
    })
    |> render_submit()

    assert {:ok, rec} = MapDiscordNotification.by_map(map.id)

    # The lazily-created parent takes the resource defaults. Nothing in the add
    # flow submits `enabled`/`wh_only`, and that is the point: a key that was
    # never submitted must not be read as `false`.
    assert rec.enabled? == true
    assert rec.wh_only == true

    assert {:ok, [webhook]} = MapDiscordWebhook.by_notification(rec.id)
    assert webhook.role == :system
  end

  test "route alerts can be configured with no kill webhook at all", %{conn: conn, map: map} do
    view = open_notifications(conn, map)

    # The regression this guards: `create` used to require `webhook_url`, and
    # the tab used to render nothing but that one field until it was supplied.
    # Route alerts are a separate feature and must not be gated behind a kill
    # channel the operator may not want.
    assert has_element?(view, "#notification-settings-form")
    assert has_element?(view, "#webhook-row-route button[phx-click='replace-url']")

    edit_row(view, :route)

    view
    |> form("#webhook-form-route", %{
      "webhook" => %{"webhook_url" => "https://discord.com/api/webhooks/456/tok"}
    })
    |> render_submit()

    assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
    assert {:ok, [webhook]} = MapDiscordWebhook.by_notification(rec.id)
    assert webhook.role == :route
  end

  test "an invalid url is rejected with a message", %{conn: conn, map: map} do
    view = open_notifications(conn, map)

    edit_row(view, :system)

    html =
      view
      |> form("#webhook-form-system", %{
        "webhook" => %{"webhook_url" => "https://evil.example.com/x"}
      })
      |> render_submit()

    # The resource's own validation message, not the form's <label> — asserting
    # on the label would pass even if the error were discarded entirely.
    assert html =~ "must be a Discord webhook URL"

    # The parent row is created before the destination is validated, so a
    # rejected URL can leave an empty policy behind. That is harmless — a
    # policy with no destinations delivers nothing (`Router.route/3` drops a
    # nil destination in `usable/1`) — but no webhook may survive it.
    assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
    assert {:ok, []} = MapDiscordWebhook.by_notification(rec.id)
  end

  test "unchecking 'enabled' actually disables", %{conn: conn, map: map} do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    # The two kill switches apply on change, in their own small form — they are
    # not part of the bottom Save. An unchecked checkbox submits NO value at
    # all; the hidden companion input is what makes "off" distinguishable from
    # "field absent", without which the record would silently re-enable itself.
    view
    |> form("#kill-toggles-form", %{
      "notification" => %{"enabled" => "false", "wh_only" => "false"}
    })
    |> render_change()

    assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
    assert rec.enabled? == false
    assert rec.wh_only == false
  end

  test "re-checking 'enabled' turns it back on", %{conn: conn, map: map} do
    rec = notification_with_webhooks(map, [:system])

    {:ok, _} = MapDiscordNotification.update(rec, %{enabled?: false})

    view = open_notifications(conn, map)

    # A checked box wins: the browser sends both hidden "false" and "true",
    # and Phoenix keeps the last value.
    view
    |> form("#kill-toggles-form", %{
      "notification" => %{"enabled" => "true", "wh_only" => "true"}
    })
    |> render_change()

    assert {:ok, updated} = MapDiscordNotification.by_map(map.id)
    assert updated.enabled? == true
  end

  test "saving map policy does not send webhook_url to the parent resource", %{
    conn: conn,
    map: map
  } do
    # `webhook_url` moved to `MapDiscordWebhook` in Task 2 and is no longer an
    # accepted input on the parent's `update`. It compiles either way, so only a
    # test that drives the REAL save action with the key present catches a
    # handler that still forwards it: Ash raises `NoSuchInput` and takes the
    # LiveView process down. Pushed at the component rather than through
    # `form/3` because no rendered form carries that key — but a handler must
    # not depend on the template to stay correct.
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    view
    |> with_target("#map-notifications")
    |> render_change("toggle-setting", %{
      "notification" => %{
        "webhook_url" => "https://discord.com/api/webhooks/999/NEWTOKEN",
        "enabled" => "true",
        "wh_only" => "true"
      }
    })

    assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
    assert rec.wh_only == true
  end

  test "with no configuration at all, all three rows render unset", %{conn: conn, map: map} do
    view = open_notifications(conn, map)

    # Every destination is listed from the start, closed, so the tab states what
    # is possible without putting three credential fields on screen unasked.
    for role <- [:system, :character, :route] do
      assert has_element?(view, "#webhook-row-#{role} button[phx-click='replace-url']")
      refute has_element?(view, "#webhook-form-#{role}")
    end

    assert render(view) =~ "Not set"
  end

  test "with only a system webhook, the character row offers to add one", %{
    conn: conn,
    map: map
  } do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    # The configured system row is a truth line at rest — no form until Edit.
    refute has_element?(view, "#webhook-form-system")
    assert has_element?(view, "#webhook-row-system button[phx-click='replace-url']")

    # The character destination is unset, so it renders closed too, and offers
    # nothing destructive: no test or remove control for a webhook that does not
    # exist. Both refutes are scoped to `#webhook-row-character` rather than to
    # its form, because those buttons live in a sibling <div> of the <form> and a
    # form-descendant selector would make the refute pass unconditionally.
    refute has_element?(view, "#webhook-form-character")
    refute has_element?(view, "#webhook-row-character button[phx-click='remove-webhook']")
    refute has_element?(view, "#webhook-row-character button[phx-click='send-test']")

    # …and it says so, rather than being silently absent.
    assert has_element?(view, "#webhook-row-character button[phx-click='replace-url']")

    edit_row(view, :character)
    assert has_element?(view, "#webhook-form-character input[type='password']")
  end

  # A configured destination now renders as a truth line — its name, its status,
  # and an Edit button. The URL field and the destructive/test controls live in
  # the form behind that button, so anything asserting on them has to open the
  # row first, exactly as a user does.
  defp edit_row(view, role) do
    view
    |> element("#webhook-row-#{role} button[phx-click='replace-url']")
    |> render_click()

    view
  end

  test "with both webhooks, each row has its own test and status controls", %{
    conn: conn,
    map: map
  } do
    notification_with_webhooks(map, [:system, :character])

    view = open_notifications(conn, map)

    # At rest, each configured row shows its identity and an Edit affordance —
    # and nothing else. This is the change the whole rework turns on: five
    # simultaneously-expanded destinations is what made the tab taller than the
    # dialog could ever show.
    assert has_element?(view, "#webhook-row-system button[phx-click='replace-url']")
    assert has_element?(view, "#webhook-row-character button[phx-click='replace-url']")
    refute has_element?(view, "#webhook-row-system button[phx-click='send-test']")

    assert has_element?(
             edit_row(view, :system),
             "#webhook-row-system button[phx-click='send-test']"
           )

    assert has_element?(
             edit_row(view, :character),
             "#webhook-row-character button[phx-click='send-test']"
           )

    # Distinct webhook ids, so the two buttons target different destinations.
    assert has_element?(view, "#webhook-row-character button[phx-click='remove-webhook']")
  end

  test "neither saved url is ever rendered in full", %{conn: conn, map: map} do
    # `create` seeds the `:system` webhook itself — see the note on
    # `notification_with_webhooks/2` above.
    {:ok, rec} =
      MapDiscordNotification.create(%{
        map_id: map.id,
        webhook_url: "https://discord.com/api/webhooks/123/SYSTEMSECRET"
      })

    {:ok, _} =
      MapDiscordWebhook.create(%{
        notification_id: rec.id,
        role: :character,
        webhook_url: "https://discord.com/api/webhooks/456/CHARACTERSECRET"
      })

    view = open_notifications(conn, map)
    html = render(view)

    refute html =~ "SYSTEMSECRET"
    refute html =~ "CHARACTERSECRET"
  end

  test "replacing a destination's url saves the new url", %{conn: conn, map: map} do
    rec = notification_with_webhooks(map, [:system])
    original = system_webhook(rec)

    view = open_notifications(conn, map)

    # A saved destination renders as a truth line, so the URL field only appears
    # after asking to edit it — the same two-step a user goes through. The Edit
    # button sits in the row rather than the form: the form is what it reveals.
    refute has_element?(view, "#webhook-form-system input[type='password']")

    edit_row(view, :system)

    html =
      view
      |> form("#webhook-form-system", %{
        "webhook" => %{
          "webhook_url" => "https://discord.com/api/webhooks/777/REPLACEMENT",
          "enabled" => "true"
        }
      })
      |> render_submit()

    assert html =~ "Saved."

    {:ok, reloaded} = MapDiscordWebhook.by_id(original.id)
    assert reloaded.webhook_url == "https://discord.com/api/webhooks/777/REPLACEMENT"
    # …and the new secret is still not echoed back into the page.
    refute render(view) =~ "REPLACEMENT"
  end

  test "adding a character destination creates the second webhook", %{conn: conn, map: map} do
    rec = notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    edit_row(view, :character)

    view
    |> form("#webhook-form-character", %{
      "webhook" => %{"webhook_url" => "https://discord.com/api/webhooks/888/chartok"}
    })
    |> render_submit()

    {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
    assert %{role: :character} = Enum.find(webhooks, &(&1.role == :character))
    # A row that has become configured collapses to its truth line, so the
    # on-screen proof is the Edit affordance, not the remove button behind it.
    assert has_element?(view, "#webhook-row-character button[phx-click='replace-url']")

    assert has_element?(
             edit_row(view, :character),
             "#webhook-row-character button[phx-click='remove-webhook']"
           )
  end

  test "removing the character destination leaves the system one alone", %{conn: conn, map: map} do
    rec = notification_with_webhooks(map, [:system, :character])

    view = open_notifications(conn, map)

    view
    |> edit_row(:character)
    |> element("#webhook-row-character button[phx-click='remove-webhook']")
    |> render_click()

    {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
    assert Enum.map(webhooks, & &1.role) == [:system]
    refute has_element?(view, "#webhook-row-character button[phx-click='remove-webhook']")
    # …and it is genuinely back to unconfigured, not merely collapsed: the row
    # is still listed, but as "Not set" with nothing behind it.
    refute has_element?(view, "#webhook-form-character")
    assert has_element?(view, "#webhook-row-character button[phx-click='replace-url']")
    assert has_element?(view, "#webhook-row-system button[phx-click='replace-url']")
  end

  test "a plain-string error renders as a sentence, not an inspected term", %{
    conn: conn,
    map: map
  } do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)
    edit_row(view, :character)

    # The component's own guard returns a bare binary. Passing that through
    # `inspect/1` would show the user literal quote marks around the sentence.
    html =
      view
      |> form("#webhook-form-character", %{"webhook" => %{"webhook_url" => ""}})
      |> render_submit()

    assert html =~ "Enter a webhook URL first."
    refute html =~ "&quot;Enter a webhook URL first.&quot;"
  end

  test "an ash validation message is rendered with its variables substituted", %{
    conn: conn,
    map: map
  } do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)
    edit_row(view, :character)

    # Well-formed enough to clear the Discord-host validation, long enough to
    # trip `max_length: 2000` on the attribute.
    long_url = "https://discord.com/api/webhooks/123/" <> String.duplicate("t", 2000)

    html =
      view
      |> form("#webhook-form-character", %{"webhook" => %{"webhook_url" => long_url}})
      |> render_submit()

    # Ash stores the copy as a template plus a `vars` bag; rendering `message`
    # raw would show the user the placeholder itself.
    refute html =~ "%{max}"
    assert html =~ "length must be less than or equal to 2000"
  end

  test "a disabled destination is not told to save a webhook url it already has", %{
    conn: conn,
    map: map
  } do
    rec = notification_with_webhooks(map, [:system])
    {:ok, _} = MapDiscordWebhook.set_enabled(system_webhook(rec), %{enabled?: false})

    view = open_notifications(conn, map)

    html = view |> edit_row(:system) |> element("button[phx-click='send-test']") |> render_click()

    # What this proves: a saved-but-disabled destination gets the remedy that
    # matches its actual state. The assert is the whole test — assert the
    # specific remedy sentence, not the word "disabled", because the row's own
    # truth line already reads "● Disabled" and a looser match would pass
    # without the error copy changing at all.
    #
    # The refute below is a belt-and-braces guard against the production
    # wording bug it names, but it does NOT demonstrate coverage of it here:
    # `send_test_message/1` checks the global kill switch first
    # (`discord_dispatcher.ex:100`) and `config/test.exs` leaves webhooks off,
    # so `:not_configured` — whose stock copy is "Save a webhook URL first." —
    # is unreachable in this environment.
    refute html =~ "Save a webhook URL first."
    assert html =~ "Enable it and save before sending a test message."
  end

  # The test above runs with the global kill-switch OFF, so the dispatcher
  # short-circuits and the component's own `send_test/2` produces the copy. This
  # one turns the switch ON so the request reaches `send_test_message/1` and the
  # component's mapping of the dispatcher's answers is what gets exercised —
  # without it, the `:webhook_not_found` / `:webhook_url_missing` clause is
  # unreachable in this file and could be deleted with everything still green.
  test "a destination deleted in another session is told to save a url", %{conn: conn, map: map} do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, :webhooks_enabled, true)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)

    rec = notification_with_webhooks(map, [:system])
    webhook = system_webhook(rec)

    view = open_notifications(conn, map)
    # Send test lives behind the row's Edit affordance now; open it while the
    # webhook still exists, so the rendered button carries the real id.
    edit_row(view, :system)

    # Destroyed AFTER render, so the button still carries the now-dead id —
    # the stale-page case `:webhook_not_found` exists for.
    :ok = MapDiscordWebhook.destroy(webhook)

    html = view |> element("button[phx-click='send-test']") |> render_click()

    assert html =~ "Save a webhook URL first."
    # Not the raw atom: `{:error, other}` renders `inspect/1`, so a missing
    # clause would still put the word "webhook" on the page.
    refute html =~ "webhook_not_found"
  end

  test "the excluded-systems picker searches by system name", %{conn: conn, map: map} do
    Factory.insert(:solar_system, %{
      solar_system_id: 30_000_142,
      solar_system_name: "Jita",
      region_name: "The Forge"
    })

    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    # LiveSelect keeps its dropdown hidden until the user types, so open it
    # first; otherwise the options are in state but never rendered.
    view
    |> with_target("#excluded_system_live_select_component")
    |> render_change("change", %{"text" => "Jita"})

    # Drive the search event AT THE COMPONENT. Sending it to `view` would go to
    # the parent LiveView, whose existing ACL `live_select_change` handler
    # answers unconditionally with ACL options — the test would pass while
    # proving nothing about our component. `with_target/2` routes to the
    # component the same way `phx-target={@myself}` does at runtime, so this
    # test actually covers the hijack risk.
    view
    |> with_target("#map-notifications")
    |> render_change("live_select_change", %{
      "id" => "excluded_system_live_select_component",
      "text" => "Jita",
      "field" => "excluded_system"
    })

    # `with_target/2` proves our handler produces system options, but it routes
    # by hand. What proves the event will not escape to the PARENT at runtime is
    # the DOM: LiveSelect pushes `live_select_change` to `data-phx-target`, and
    # `phx-target={@myself}` is what makes that a component ref rather than the
    # root LiveView. Without it this attribute is the root and the parent's ACL
    # handler would answer instead.
    component_ref =
      view
      |> element("#map-notifications")
      |> render()
      |> then(&Regex.run(~r/data-phx-component="(\d+)"/, &1))
      |> Enum.at(1)

    assert has_element?(
             view,
             "#excluded_system_live_select_component[data-phx-target='#{component_ref}']"
           )

    # Options are pushed into the component; assert the search found Jita by
    # name rather than requiring the user to know id 30000142. The region
    # suffix is produced only by this component's option formatter.
    assert render(view) =~ "Jita (The Forge)"
    # And assert we did NOT get the parent's ACL options instead.
    refute render(view) =~ "access list"
  end

  test "excluded systems can be added and removed", %{conn: conn, map: map} do
    Factory.insert(:solar_system, %{
      solar_system_id: 30_000_142,
      solar_system_name: "Jita",
      region_name: "The Forge"
    })

    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    # NOTE: `form("#excluded-system-form", ...)` cannot drive this form.
    # LiveSelect renders `excluded[excluded_system]` as a hidden input, and
    # LiveViewTest refuses to set any value other than "" on a hidden input.
    # Push the event at the component instead.
    view
    |> with_target("#map-notifications")
    |> render_submit("add-excluded", %{"excluded" => %{"excluded_system" => "30000142"}})

    assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
    assert rec.excluded_systems == [30_000_142]
    # And it is rendered back with a resolved name, not a bare id.
    assert render(view) =~ "Jita (30000142)"

    view
    |> element("button[phx-click='remove-excluded'][phx-value-system_id='30000142']")
    |> render_click()

    assert {:ok, after_remove} = MapDiscordNotification.by_map(map.id)
    assert after_remove.excluded_systems == []
    refute render(view) =~ "Jita (30000142)"
  end

  test "focus corporations can be added and removed", %{conn: conn, map: map} do
    rec = notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    # LiveSelect renders `focus_corp[focus_corp]` as a hidden input, and
    # LiveViewTest refuses to set any value other than "" on a hidden input, so
    # push the event at the component rather than driving the form.
    view
    |> with_target("#map-notifications")
    |> render_submit("add-focus-corp", %{"focus_corp" => %{"focus_corp" => "98000001"}})

    assert {:ok, reloaded} = MapDiscordNotification.by_id(rec.id)
    # Persisted as an INTEGER: `Character.search/2` yields string eve ids
    # (`character.ex:365`) while `focus_corp_ids` is an integer list.
    assert reloaded.focus_corp_ids == [98_000_001]

    view
    |> element("button[phx-click='remove-focus-corp'][phx-value-corp_id='98000001']")
    |> render_click()

    assert {:ok, after_remove} = MapDiscordNotification.by_id(rec.id)
    assert after_remove.focus_corp_ids == []
  end

  test "a saved focus corporation renders as a removable chip even when ESI cannot name it",
       %{conn: conn, map: map} do
    rec = notification_with_webhooks(map, [:system])
    {:ok, _} = MapDiscordNotification.update(rec, %{focus_corp_ids: [98_000_001]})

    view = open_notifications(conn, map)

    # ESI is unreachable in the test environment, so `label_for/1` degrades to
    # the bare id. The chip must still be there — a vanishing chip looks like
    # the setting was lost and invites a duplicate re-add.
    assert render(view) =~ "98000001"

    assert has_element?(
             view,
             "button[phx-click='remove-focus-corp'][phx-value-corp_id='98000001']"
           )
  end

  test "a non-numeric focus corporation is rejected with a message", %{conn: conn, map: map} do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    html =
      view
      |> with_target("#map-notifications")
      |> render_submit("add-focus-corp", %{"focus_corp" => %{"focus_corp" => "not-an-id"}})

    assert html =~ "Pick a corporation from the list."
  end

  test "a user with no characters is told why corporation search is unavailable", %{map: map} do
    notification_with_webhooks(map, [:system])

    # Rendered directly rather than driven through the LiveView, because the
    # mounted LiveView cannot reach this state:
    #
    #   * `UserAuth.on_mount/4` builds `@current_user` with
    #     `User.by_id!(user_id) |> Ash.load!(:characters)`
    #     (`lib/wanderer_app_web/controllers/user_auth.ex:15`), so `characters`
    #     is always a loaded list there — never `%Ash.NotLoaded{}`.
    #   * `setup` gives the map an `owner_id` pointing at THIS user's character,
    #     so deleting that character to force an empty list would take the map's
    #     owner with it and the request would fail on authorization long before
    #     reaching this branch.
    #
    # The branch is still worth covering — it is what a freshly-registered
    # account with no linked characters sees — so assert on the component with
    # the assign set explicitly.
    html =
      render_component(WandererAppWeb.MapNotificationsComponent,
        id: "map-notifications",
        map_id: map.id,
        current_user: %WandererApp.Api.User{characters: []}
      )

    assert html =~ "Add a character to this account to search corporations."
    refute html =~ "focus_corp_live_select_component"
  end

  test "the two live_selects have distinct ids and the corp search does not return systems", %{
    conn: conn,
    map: map
  } do
    Factory.insert(:solar_system, %{
      solar_system_id: 30_000_142,
      solar_system_name: "Jita",
      region_name: "The Forge"
    })

    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    assert has_element?(view, "#excluded_system_live_select_component")
    assert has_element?(view, "#focus_corp_live_select_component")

    # Open the corporation dropdown first. LiveSelect renders nothing until the
    # user has typed, so without this the assertion below is vacuous: options
    # would sit in component state, unrendered, and the refute would pass even
    # if the handler answered the corporation box with solar systems.
    view
    |> with_target("#focus_corp_live_select_component")
    |> render_change("change", %{"text" => "Jita"})

    # A corporation-box keystroke must not be answered with solar systems.
    view
    |> with_target("#map-notifications")
    |> render_change("live_select_change", %{
      "id" => "focus_corp_live_select_component",
      "text" => "Jita",
      "field" => "focus_corp"
    })

    refute render(view) =~ "Jita (The Forge)"
  end

  test "a corporation keystroke reports a failed lookup instead of an empty dropdown", %{
    conn: conn,
    map: map,
    character: character
  } do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    # `Factory.create_character/1` builds through the `:link` action, which accepts
    # only [:eve_id, :name, :user_id] — so the character has no access token and a
    # nil `expires_at`, exactly like an account that never completed an OAuth
    # exchange. `is_access_token_expired?/1` reports nil as expired, so this
    # keystroke goes down ESI's refresh-and-retry path.
    #
    # That path used to compute its log timing with `DateTime.from_unix!(nil)` and
    # raise FunctionClauseError, which `search_corporations/2` rescued into `[]`.
    # The dropdown then looked exactly like a search with no matches, which is why
    # the typeahead appeared to do nothing at all rather than to be broken.
    log =
      capture_log(fn ->
        view
        |> with_target("#map-notifications")
        |> render_change("live_select_change", %{
          "id" => "focus_corp_live_select_component",
          "text" => "Hard Knocks",
          "field" => "focus_corp"
        })
      end)

    refute log =~ "FunctionClauseError"
    refute log =~ "DateTime.from_unix"

    # Unconditional on purpose. `setup` gives this user exactly one character and
    # it has no access token, so the lookup cannot succeed however the test host
    # is configured — with no network egress the HTTP call fails, and with egress
    # EVE SSO rejects the nil refresh token. Guarding this assertion on the log
    # contents would let it pass vacuously the moment the keystroke stopped
    # reaching the search at all, which is the exact regression it guards.
    assert render(view) =~ "Corporation search is unavailable right now."

    # The reason has to reach the page, not just the log. The generic sentence
    # alone cannot distinguish "re-authorise this character" from "ESI is
    # rate-limiting us", and reading it off a screenshot is the only diagnostic
    # available for a deployment whose logs we cannot see. Asserting on the
    # parenthesised suffix rather than a specific atom keeps this independent of
    # whichever failure the test host produces.
    assert render(view) =~ ~r/Corporation search is unavailable right now\..*\(.+\)/s

    # The search runs as ONE character. On a multi-character account the generic
    # advice to "re-authorise a character" sends the user to re-authorise the
    # wrong one and conclude the feature is simply broken, so the message has to
    # name the character whose token was actually used.
    assert render(view) =~ character.name
  end

  test "send test message reports the global kill-switch", %{conn: conn, map: map} do
    notification_with_webhooks(map, [:system])

    # `config/test.exs` leaves webhooks disabled, which is exactly the
    # production kill-switch case: the worker Registry does not exist, so this
    # must return an error rather than crash the LiveView.
    view = open_notifications(conn, map)

    # The fixture is `[:system]` only, so exactly one Send test button exists
    # once that row is opened for editing.
    html = view |> edit_row(:system) |> element("button[phx-click='send-test']") |> render_click()

    assert html =~ "disabled on this server"
  end

  test "the tab offers no wholesale remove", %{conn: conn, map: map} do
    notification_with_webhooks(map, [:system, :character, :route])

    view = open_notifications(conn, map)

    # Deliberate: each destination has its own Remove behind its Edit, and a
    # policy row with no destinations delivers nothing. A pane-level destroy
    # only added the ability to discard invisible filter and mention state, and
    # put the tab's most destructive control permanently on screen to do it.
    refute has_element?(view, "button[phx-click='delete']")

    for role <- ~w(system character route) do
      assert has_element?(
               edit_row(view, role),
               "#webhook-row-#{role} button[phx-click='remove-webhook']"
             )
    end
  end

  # Asserting the button EXISTS is not the same as asserting it works, and the
  # difference was a crash: `role_label/1` had no `:system` clause while
  # `remove-webhook` refused that role, and widening the handler without
  # widening the label raised FunctionClauseError — after the destroy had
  # committed, so the destination was gone and the tab was down with it. Every
  # role is clicked here, not just listed.
  test "every destination can actually be removed", %{conn: conn, map: map} do
    rec = notification_with_webhooks(map, [:system, :character, :route])

    view = open_notifications(conn, map)

    for {role, label} <- [
          {"system", "Kill channel"},
          {"character", "Character kill channel"},
          {"route", "Route alert channel"}
        ] do
      html =
        view
        |> edit_row(role)
        |> element("#webhook-row-#{role} button[phx-click='remove-webhook']")
        |> render_click()

      # The confirmation names the row the operator clicked, not an internal
      # role name that appears nowhere on screen.
      assert html =~ "#{label} removed."
    end

    # The policy row outlives its destinations — nothing here deletes it, and a
    # row with no destinations simply delivers nothing.
    assert {:ok, []} = MapDiscordWebhook.by_notification(rec.id)
    assert {:ok, _} = MapDiscordNotification.by_map(map.id)
  end

  test "a rejected URL does not poison the retry", %{conn: conn, map: map} do
    view = open_notifications(conn, map)

    # First save on a map with no policy row yet: `ensure_notification/1`
    # commits the row, then the webhook write is rejected. The row is now real
    # even though the operator saw only an error.
    edit_row(view, :route)

    bad =
      view
      |> form("#webhook-form-route", %{"webhook" => %{"webhook_url" => "not-a-url"}})
      |> render_submit()

    refute bad =~ "Saved."

    # The correction must succeed. It used to fail with the identity error from
    # a second `create` for the same map, because the failed attempt left
    # `@notification` nil.
    good =
      view
      |> form("#webhook-form-route", %{
        "webhook" => %{"webhook_url" => "https://discord.com/api/webhooks/456/tok"}
      })
      |> render_submit()

    assert good =~ "Saved."
    refute good =~ "already been taken"

    {:ok, rec} = MapDiscordNotification.by_map(map.id)
    assert {:ok, [webhook]} = MapDiscordWebhook.by_notification(rec.id)
    assert webhook.role == :route
  end

  # Both of the tests below drive `humanize_error/1` and `fallback_message/1`
  # through an error that carries no message of its own. They used to go through
  # the pane-level destroy; with that gone, the trigger is a destination removed
  # out from under the mounted view, so the row's Remove destroys a stale record.
  #
  # NOT the route Save, which was the obvious substitute and is wrong: `upsert/2`
  # creates when the parent is missing, so destroying the policy row and saving
  # re-creates it and reports "Saved." — a self-healing trigger that would have
  # left the test asserting nothing. There is no such recreate path for a
  # specific webhook id.
  defp stale_remove(view, map, role) do
    # Edit BEFORE the row is destroyed: opening the row is what renders its
    # Remove button, and the component keeps the (about to be stale) struct in
    # its own assigns until something re-reads the map's notification.
    view = edit_row(view, role)

    {:ok, rec} = MapDiscordNotification.by_map(map.id)
    {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
    :ok = webhooks |> Enum.find(&(&1.role == role)) |> Ash.destroy()

    view
    |> element("#webhook-row-#{role} button[phx-click='remove-webhook']")
    |> render_click()
  end

  test "a failed removal is reported instead of raising", %{conn: conn, map: map} do
    notification_with_webhooks(map, [:system, :character])

    view = open_notifications(conn, map)
    html = stale_remove(view, map, :character)

    refute html =~ "destination removed."
    assert render(view) =~ "class=\"text-sm text-red-400\""
    # `StaleRecord` carries no message, so it reaches `humanize_error/1`'s
    # catch-all. That branch must not render the term: an unanticipated error
    # shape can carry the submitted URL, and the credential invariant must not
    # rest on `sensitive?` happening to redact whatever turns up there.
    refute html =~ "StaleRecord"
    assert html =~ "Something went wrong. Please try again."
  end

  test "a non-owner cannot reach map settings", %{conn: conn} do
    other_user = Factory.insert(:user, %{})
    other_character = Factory.insert(:character, %{user_id: other_user.id})
    other_map = Factory.insert(:map, %{owner_id: other_character.id})

    assert {:error, _} = live(conn, ~p"/maps/#{other_map.slug}/settings")
  end

  test "send-test refuses a webhook id belonging to another map", %{conn: conn, map: map} do
    notification_with_webhooks(map, [:system])

    # A second map, with its own Discord destination, that this user does not
    # own. `send_test_message/1` resolves a webhook by id ALONE, so nothing but
    # the component's own membership check stands between a hand-crafted
    # `phx-value-webhook_id` and someone else's Discord channel.
    other_user = Factory.insert(:user, %{})
    other_character = Factory.insert(:character, %{user_id: other_user.id})
    other_map = Factory.insert(:map, %{owner_id: other_character.id})
    other_webhook = system_webhook(notification_with_webhooks(other_map, [:system]))

    view = open_notifications(conn, map)

    html =
      view
      |> edit_row(:system)
      |> element("button[phx-click='send-test']")
      |> render_click(%{"webhook_id" => other_webhook.id})

    # The id is not one of this map's destinations, so the component answers
    # `:webhook_not_found` without ever calling the dispatcher.
    assert html =~ "Save a webhook URL first."
    # Both of the replies the dispatcher could have produced for a foreign id
    # that does exist: "queued" if the worker tree is up, and the global
    # kill-switch message (this environment) if it is not. Either one means the
    # request reached the dispatcher, which is the bug.
    refute html =~ "Test message queued."
    refute html =~ "disabled on this server"
  end

  test "an unrecognised error shape is logged by type, never inspected", %{
    conn: conn,
    map: map
  } do
    notification_with_webhooks(map, [:system, :character])

    view = open_notifications(conn, map)

    log =
      capture_log(fn ->
        # Same trigger as "a failed removal is reported instead of raising": the
        # destination is deleted under the mounted view, so the destroy fails
        # with a `StaleRecord`, which carries no message of its own and reaches
        # `fallback_message/1`.
        html = stale_remove(view, map, :character)
        assert html =~ "Something went wrong. Please try again."
      end)

    assert log =~ "unrecognised error shape: Ash.Error.Changes.StaleRecord"

    # `inspect/1` of the error would print every field it carries. On a create
    # those fields include `InvalidAttribute.value` — the submitted webhook URL,
    # verbatim, which `sensitive? true` does NOT redact (empirically confirmed).
    # A credential must not be reachable from a log line, so nothing beyond the
    # struct's own name may be logged.
    refute log =~ "%Ash.Error.Changes.StaleRecord{"
    refute log =~ "resource:"
    refute log =~ "bread_crumbs:"
  end

  describe "channel collisions" do
    test "the route channel sharing a Discord channel with the kill feed is warned about", %{
      conn: conn,
      map: map
    } do
      rec = notification_with_webhooks(map, [:route])
      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)

      # Two DISTINCT webhook URLs resolved to the SAME channel — the case the
      # old same-URL check could not see, and the one that actually leaks the
      # home system into the kill feed's audience.
      for wh <- webhooks do
        {:ok, _} =
          MapDiscordWebhook.cache_channel_info(wh, %{
            channel_id: "987650001234500777",
            channel_label: "#kills"
          })
      end

      html = conn |> open_notifications(map) |> render()

      assert html =~ "Route alerts post to the same Discord channel as the system channel."
      assert html =~ "route to it"

      # The generic counterpart on the kill-notification card, naming the other
      # side rather than "another destination".
      assert html =~ "This channel is also used by route alerts on this map."

      # D6: the resolved label is what identifies a destination now. The
      # snowflake itself is never rendered.
      assert html =~ "#kills"
      refute html =~ "987650001234500777"
    end

    test "distinct channels produce no warning", %{conn: conn, map: map} do
      notification_with_webhooks(map, [:route])

      html = conn |> open_notifications(map) |> render()

      refute html =~ "also used by"
      refute html =~ "Route alerts post to the same Discord channel"
    end
  end

  describe "route alerts" do
    test "enabling route alerts without a home system surfaces the Ash validation error", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      # Route settings now live on their own form with their own submit, so
      # this no longer rides along with the kill-notification Save. Pushed at
      # the component rather than through `form/3` because `home_system_id` is
      # a LiveSelect hidden input, which LiveViewTest refuses to set (same
      # reason as the excluded-systems and focus-corp tests above).
      html =
        view
        |> with_target("#map-notifications")
        |> render_submit("save-settings", %{
          "notification" => %{
            "route_alerts_enabled" => "true",
            "home_system_id" => "",
            "route_max_jumps" => "5"
          }
        })

      # The message has to NAME the field. A field-scoped Ash error alone
      # surfaced in the panel's message region as the orphan sentence "is
      # required when route alerts are enabled", with no indication which of
      # the three route fields it meant.
      assert html =~ "Home system is required when route alerts are enabled"

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      refute rec.route_alerts_enabled?
      assert rec.home_system_id == nil
    end

    test "saving valid route settings persists the toggle, home system, and max jumps", %{
      conn: conn,
      map: map
    } do
      insert_jita()
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> element(@route_checkbox)
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      pick_home_system(view, "Jita")

      # Only `route_max_jumps` is supplied. The home system comes from the
      # DOM — LiveSelect's hidden input, holding the id behind the name the
      # user picked — which is the whole point of the picker.
      view
      |> form("#notification-settings-form", %{
        "notification" => %{
          "route_alerts_enabled" => "true",
          "route_max_jumps" => "3"
        }
      })
      |> render_submit()

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      assert rec.route_alerts_enabled? == true
      assert rec.home_system_id == 30_000_142
      assert rec.route_max_jumps == 3
    end

    test "the kill switches and the Save each write only their own fields", %{
      conn: conn,
      map: map
    } do
      rec = notification_with_webhooks(map, [:system])

      {:ok, _} =
        MapDiscordNotification.update(rec, %{
          wh_only: true,
          route_alerts_enabled?: true,
          home_system_id: 30_000_142,
          route_max_jumps: 3
        })

      view = open_notifications(conn, map)

      # P0 (four saves, one flash, no scope): one control must not touch
      # another's fields. Before the split, ticking a box in one section and
      # pressing the wrong Save reported "Saved." and silently reverted the
      # tick, because every Save submitted the whole tab. The kill switches now
      # apply on change and carry only their own two keys.
      view
      |> form("#kill-toggles-form", %{
        "notification" => %{"enabled" => "true", "wh_only" => "false"}
      })
      |> render_change()

      assert {:ok, after_kills} = MapDiscordNotification.by_map(map.id)
      assert after_kills.wh_only == false
      # Untouched by the kills Save, not reset to their defaults.
      assert after_kills.route_alerts_enabled? == true
      assert after_kills.home_system_id == 30_000_142
      assert after_kills.route_max_jumps == 3

      view
      |> with_target("#map-notifications")
      |> render_submit("save-settings", %{
        "notification" => %{
          "route_alerts_enabled" => "true",
          "home_system_id" => "30000144",
          "route_max_jumps" => "7"
        }
      })

      assert {:ok, after_route} = MapDiscordNotification.by_map(map.id)
      assert after_route.home_system_id == 30_000_144
      assert after_route.route_max_jumps == 7
      # And the route Save did not resurrect the wh_only default.
      assert after_route.wh_only == false
      assert after_route.enabled? == true
    end

    test "the route fields are disabled while the toggle is off, not hidden or removed", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      # Off by default (route_alerts_enabled? defaults to false per Task 3).
      # These fields used to be wrapped in a `hidden` div, which is what made
      # the "configured but switched off" warning unreachable: the one state
      # that needed a warning rendered it inside the container that was
      # hidden. They are now DISABLED instead (upstream checklist §5), via a
      # <fieldset> so the disable reaches LiveSelect's own inputs too.
      #
      # Asserting on the fieldset rather than the input because that is where
      # the attribute lives; `input[disabled]` would not match a descendant
      # disabled by an ancestor fieldset.
      assert has_element?(
               view,
               "#notification-settings-form fieldset[disabled] input[name='notification[home_system_id]']"
             )

      view
      |> element("input[name='notification[route_alerts_enabled]'][type='checkbox']")
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      refute has_element?(
               view,
               "#notification-settings-form fieldset[disabled] input[name='notification[home_system_id]']"
             )

      # Still in the DOM either way — never `:if`-ed out.
      assert has_element?(
               view,
               "#notification-settings-form input[name='notification[home_system_id]']"
             )
    end

    test "a disabled route field does not wipe the saved value on the next save", %{
      conn: conn,
      map: map
    } do
      rec = notification_with_webhooks(map, [:system])

      {:ok, _} =
        MapDiscordNotification.update(rec, %{
          route_alerts_enabled?: true,
          home_system_id: 30_000_142,
          route_max_jumps: 3
        })

      view = open_notifications(conn, map)

      # Turning the toggle off disables the fields below it, and a disabled
      # input submits NOTHING — not even the hidden "false" companion. If
      # `notification_attrs/1` read the key unconditionally it would parse the
      # absent value as nil and clear a home system the user never touched.
      view
      |> with_target("#map-notifications")
      |> render_submit("save-settings", %{"notification" => %{"route_alerts_enabled" => "false"}})

      assert {:ok, saved} = MapDiscordNotification.by_map(map.id)
      assert saved.route_alerts_enabled? == false
      assert saved.home_system_id == 30_000_142
      assert saved.route_max_jumps == 3
    end

    # The two save tests above hand `render_submit` an explicit params map, so
    # they never exercise the rendered checkbox — they passed while ticking the
    # box in a browser did nothing. `checked` is rendered from the form's
    # value, so a handler that updates only `:route_toggle` re-renders the box
    # UNCHECKED, and LiveView patches the real one back. The tests below drive
    # the DOM instead: no params for the checkbox, ever.
    test "ticking the route alerts box leaves it checked in the re-render", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      refute has_element?(
               view,
               "input[name='notification[route_alerts_enabled]'][type='checkbox'][checked]"
             )

      view
      |> element("input[name='notification[route_alerts_enabled]'][type='checkbox']")
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      assert has_element?(
               view,
               "input[name='notification[route_alerts_enabled]'][type='checkbox'][checked]"
             )
    end

    test "toggling route alerts keeps values already typed into the form", %{
      conn: conn,
      map: map
    } do
      insert_jita()
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> element(@route_checkbox)
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      pick_home_system(view, "Jita")

      # A real browser posts every input in the form with the change event, so
      # a re-render that rebuilds the form from anything BUT those params
      # silently discards the system already picked and the jumps already typed.
      view
      |> element(@route_checkbox)
      |> render_change(%{
        "notification" => %{
          "route_alerts_enabled" => "true",
          "home_system_id" => "30000142",
          "home_system_id_text_input" => "Jita (The Forge)",
          "route_max_jumps" => "4"
        }
      })

      assert has_element?(view, "input[name='notification[home_system_id]'][value='30000142']")
      assert has_element?(view, "input[name='notification[route_max_jumps]'][value='4']")

      # And the picker still shows the NAME. LiveSelect re-derives its selection
      # from the form value on every re-render and can only label a value it has
      # seen as an option, so a form value that no longer matches the option it
      # came from leaves the user staring at a bare id.
      assert has_element?(
               view,
               "input[name='notification[home_system_id_text_input]'][value='Jita (The Forge)']"
             )
    end

    test "ticking the box and saving persists the toggle", %{conn: conn, map: map} do
      insert_jita()
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> element("input[name='notification[route_alerts_enabled]'][type='checkbox']")
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      pick_home_system(view, "Jita")

      # No params at all — the checkbox and the picked home system both come
      # from the rendered DOM, which is the whole point: this is what the
      # browser actually posts.
      view |> form("#notification-settings-form") |> render_submit()

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      assert rec.route_alerts_enabled? == true
      assert rec.home_system_id == 30_000_142
    end

    test "picking a system by name persists its integer id", %{conn: conn, map: map} do
      insert_jita()
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> element(@route_checkbox)
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      # Nobody knows solar system ids. Typing the NAME must be enough, and the
      # dropdown labels it with its region so near-identical names can be told
      # apart.
      view
      |> with_target("##{@home_select}")
      |> render_change("change", %{"text" => "Jita"})

      view
      |> with_target("#map-notifications")
      |> render_change("live_select_change", %{
        "id" => @home_select,
        "text" => "Jita",
        "field" => "home_system_id"
      })

      assert render(view) =~ "Jita (The Forge)"

      view
      |> with_target("##{@home_select}")
      |> render_change("option_click", %{"idx" => "0"})

      view
      |> form("#notification-settings-form", %{
        "notification" => %{"route_alerts_enabled" => "true"}
      })
      |> render_submit()

      # Storage is unchanged: the resource still holds an integer id, and the
      # route watcher and dispatcher still read it as one.
      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      assert rec.home_system_id == 30_000_142

      # Reopened, the saved id renders as the name again rather than as itself.
      reopened = open_notifications(conn, map)

      assert has_element?(
               reopened,
               "input[name='notification[home_system_id_text_input]'][value='Jita (The Forge)']"
             )
    end

    test "a typed name that matches no system is rejected with a visible error", %{
      conn: conn,
      map: map
    } do
      insert_jita()
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> element(@route_checkbox)
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      # Typed, never picked from the dropdown, so the hidden id is empty and
      # only the text survives. Submitting `nil` here would come back as the
      # resource's generic "is required when route alerts are enabled", which
      # says nothing about the name that was actually typed.
      html =
        view
        |> form("#notification-settings-form", %{
          "notification" => %{
            "route_alerts_enabled" => "true",
            "home_system_id_text_input" => "Jitaaa"
          }
        })
        |> render_submit()

      assert html =~ "No solar system is named"
      assert html =~ "Jitaaa"
      refute html =~ "is required when route alerts are enabled"

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      refute rec.route_alerts_enabled?
      assert rec.home_system_id == nil
    end

    test "a fully typed system name saves without opening the dropdown", %{conn: conn, map: map} do
      insert_jita()
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> element(@route_checkbox)
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      view
      |> form("#notification-settings-form", %{
        "notification" => %{
          "route_alerts_enabled" => "true",
          "home_system_id_text_input" => "jita"
        }
      })
      |> render_submit()

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      assert rec.home_system_id == 30_000_142
    end

    # `find_by_name` is a substring search, so "Jita" also matches "Jitanenba".
    # Guessing between them would silently watch a system the user never named.
    test "a typed prefix with several matches is rejected rather than guessed", %{
      conn: conn,
      map: map
    } do
      insert_jita()

      Factory.insert(:solar_system, %{
        solar_system_id: 30_000_143,
        solar_system_name: "Jitanenba",
        region_name: "The Forge"
      })

      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> element(@route_checkbox)
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      html =
        view
        |> form("#notification-settings-form", %{
          "notification" => %{
            "route_alerts_enabled" => "true",
            "home_system_id_text_input" => "Jit"
          }
        })
        |> render_submit()

      assert html =~ "No solar system is named"

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      assert rec.home_system_id == nil
    end

    # The other half of the picker's state: LiveSelect holds the selection in
    # its own component state and re-derives it from the form value on every
    # re-render, so a parent re-render while `@form` still says "" blanks the
    # hidden input and Save posts nothing. The form's own `phx-change` — which
    # LiveSelect's hook fires by dispatching an input event on that hidden
    # input — is what keeps `@form` in step.
    test "a picked home system survives a re-render caused by another widget", %{
      conn: conn,
      map: map
    } do
      insert_jita()
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> element(@route_checkbox)
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      pick_home_system(view, "Jita")

      # What the browser does on selection: post the form as the DOM now has it.
      view |> form("#notification-settings-form") |> render_change()

      # An unrelated widget re-renders the component.
      view
      |> with_target("#map-notifications")
      |> render_change("live_select_change", %{
        "id" => "excluded_system_live_select_component",
        "text" => "Jita",
        "field" => "excluded_system"
      })

      assert has_element?(view, "input[name='notification[home_system_id]'][value='30000142']")

      view |> form("#notification-settings-form") |> render_submit()

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      assert rec.home_system_id == 30_000_142
    end

    test "no form carrying a webhook url has a change handler that could echo it", %{
      conn: conn,
      map: map
    } do
      # #130's fix was to blank `webhook_url` before rebuilding the form on
      # change, because the route toggle and the create-path URL field shared
      # one form and the generic `.input` writes `value=` for password inputs
      # too. The IA split removes the shared form entirely: the credential now
      # lives ONLY on the per-row webhook forms, none of which carry a
      # `phx-change`. This asserts the structural property rather than the old
      # symptom, so it fails if a change handler is ever added back to a form
      # holding a URL — or if a URL field is ever added to one of the two forms
      # that DO have a change handler.
      notification_with_webhooks(map, [:system, :character, :route])

      view = open_notifications(conn, map)

      for form_id <- ~w(kill-toggles-form notification-settings-form) do
        refute has_element?(view, "##{form_id} input[name='notification[webhook_url]']")
      end

      # Configured rows are truth lines until opened, so each form has to be
      # revealed before there is a `<form>` tag to inspect at all.
      for role <- ~w(system character route), do: edit_row(view, role)
      html = render(view)

      for role <- ~w(system character route) do
        [form_tag] = Regex.run(~r/<form[^>]*id="webhook-form-#{role}"[^>]*>/, html)
        assert has_element?(view, "#webhook-form-#{role} input[name='webhook[webhook_url]']")
        refute form_tag =~ "phx-change"
      end
    end

    test "the route webhook url can be added", %{conn: conn, map: map} do
      rec = notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      edit_row(view, :route)

      view
      |> form("#webhook-form-route", %{
        "webhook" => %{"webhook_url" => "https://discord.com/api/webhooks/999/routetok"}
      })
      |> render_submit()

      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
      assert %{role: :route, enabled?: true} = Enum.find(webhooks, &(&1.role == :route))
      # Saved, so the row has collapsed to its truth line.
      assert has_element?(view, "#webhook-row-route button[phx-click='replace-url']")

      assert has_element?(
               edit_row(view, :route),
               "#webhook-row-route button[phx-click='remove-webhook']"
             )
    end

    # Mentions left the webhook form in this rework: they are chip state saved
    # by their own events. With no bot token and no resolved guild — the state
    # every test runs in — the pickers degrade to the manual add-by-id forms,
    # which is what these drive.
    test "a mention id that is not a snowflake shows an inline error and saves nothing", %{
      conn: conn,
      map: map
    } do
      rec = notification_with_webhooks(map, [:system, :route])
      view = open_notifications(conn, map)

      html =
        view
        |> form("#mention-manual-role", %{"mention_id" => %{"value" => "not-a-target"}})
        |> render_submit()

      assert html =~ "not a Discord id"

      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
      assert Enum.find(webhooks, &(&1.role == :route)).mention_targets == []
    end

    test "roles and users are saved as one prefixed list and render as chips", %{
      conn: conn,
      map: map
    } do
      rec = notification_with_webhooks(map, [:system, :route])
      view = open_notifications(conn, map)

      view
      |> form("#mention-manual-role", %{"mention_id" => %{"value" => " 123456789012345678 "}})
      |> render_submit()

      html =
        view
        |> form("#mention-manual-user", %{"mention_id" => %{"value" => "234567890123456789"}})
        |> render_submit()

      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
      route_wh = Enum.find(webhooks, &(&1.role == :route))

      assert route_wh.mention_targets == ["user:234567890123456789", "role:123456789012345678"]

      # No name is known for either id without a guild, so the chip falls back
      # to the id rather than rendering blank.
      assert html =~ "123456789012345678"
      assert html =~ "234567890123456789"
    end

    test "removing a mention chip rewrites the list", %{conn: conn, map: map} do
      rec = notification_with_webhooks(map, [:system, :route])
      view = open_notifications(conn, map)

      view
      |> form("#mention-manual-role", %{"mention_id" => %{"value" => "123456789012345678"}})
      |> render_submit()

      view
      |> element("button[phx-click='remove-mention'][phx-value-id='123456789012345678']")
      |> render_click()

      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
      assert Enum.find(webhooks, &(&1.role == :route)).mention_targets == []
    end

    # The dead end `Router.route_destination/1`'s no-fallback rule creates: the
    # form lets an owner enable route alerts, set a home system and max jumps,
    # and save successfully while every alert is silently dropped for want of a
    # destination. The hint is the only feedback in that state.
    @hint "Route alerts are on, but no route alert channel is ready"

    test "enabling route alerts with no route channel warns that nothing will be sent", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      html =
        view
        |> element("input[name='notification[route_alerts_enabled]'][type='checkbox']")
        |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      assert html =~ @hint
    end

    # The half that stops the hint becoming a permanent nag: once a usable
    # destination exists it must go away.
    test "the warning is gone once a route channel is configured", %{conn: conn, map: map} do
      notification_with_webhooks(map, [:system, :route])
      view = open_notifications(conn, map)

      html =
        view
        |> element("input[name='notification[route_alerts_enabled]'][type='checkbox']")
        |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      refute html =~ @hint
    end

    # A disabled `:route` row drops exactly like a missing one — `Router.usable/1`
    # returns :drop for both — so the hint must key off usability, not existence.
    test "a disabled route channel warns too, not just a missing one", %{conn: conn, map: map} do
      rec = notification_with_webhooks(map, [:system, :route])

      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
      route_wh = Enum.find(webhooks, &(&1.role == :route))
      {:ok, _} = MapDiscordWebhook.set_enabled(route_wh, %{enabled?: false})

      view = open_notifications(conn, map)

      html =
        view
        |> element("input[name='notification[route_alerts_enabled]'][type='checkbox']")
        |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      assert html =~ @hint
    end
  end

  # Every one of these messages used to be scoped `:filters` and rendered
  # inside the filters disclosure. That disclosure now starts collapsed
  # unconditionally and no longer auto-expands on a problem (D2), so a message
  # left in the old place would be invisible: the owner sees their click do
  # nothing. There is now ONE `#panel-message`, in the action bar at the foot of
  # the tab beside the single Save — the assertions check the LOCATION, which is
  # the actual regression risk, not merely that the text exists somewhere in the
  # document.
  describe "kill-filter messages render on the card, not inside the collapsed body" do
    defp assert_in_kills_card(view, text) do
      assert has_element?(view, "#panel-message", text)

      # Not swallowed by the collapsed body.
      refute has_element?(view, "#filters-disclosure-body #panel-message")
    end

    setup %{conn: conn, map: map} do
      notification_with_webhooks(map, [:system])
      %{view: open_notifications(conn, map), map: map}
    end

    test "an unparseable excluded system", %{view: view} do
      view
      |> with_target("#map-notifications")
      |> render_submit("add-excluded", %{"excluded" => %{"excluded_system" => "not-a-system"}})

      assert_in_kills_card(view, "Pick a system from the list.")
    end

    test "an unparseable excluded-system removal", %{view: view} do
      view
      |> with_target("#map-notifications")
      |> render_click("remove-excluded", %{"system_id" => "not-a-system"})

      assert_in_kills_card(view, "Could not remove that system.")
    end

    test "an unparseable focus corporation", %{view: view} do
      view
      |> with_target("#map-notifications")
      |> render_submit("add-focus-corp", %{"focus_corp" => %{"focus_corp" => "not-a-corp"}})

      assert_in_kills_card(view, "Pick a corporation from the list.")
    end

    test "an unparseable focus-corporation removal", %{view: view} do
      view
      |> with_target("#map-notifications")
      |> render_click("remove-focus-corp", %{"corp_id" => "not-a-corp"})

      assert_in_kills_card(view, "Could not remove that corporation.")
    end

    # The two save-failure paths. Deleting the record out from under the
    # mounted view makes the Ash update fail on a stale record, the same trick
    # the destroy test uses.
    test "a failed excluded-systems save", %{view: view, map: map} do
      {:ok, rec} = MapDiscordNotification.by_map(map.id)
      :ok = Ash.destroy(rec)

      view
      |> with_target("#map-notifications")
      |> render_submit("add-excluded", %{"excluded" => %{"excluded_system" => "30000142"}})

      assert_in_kills_card(view, "Something went wrong. Please try again.")
    end

    test "a failed focus-corporation save", %{view: view, map: map} do
      {:ok, rec} = MapDiscordNotification.by_map(map.id)
      :ok = Ash.destroy(rec)

      view
      |> with_target("#map-notifications")
      |> render_submit("add-focus-corp", %{"focus_corp" => %{"focus_corp" => "98000001"}})

      assert_in_kills_card(view, "Something went wrong. Please try again.")
    end
  end

  describe "channel identity in a destination row" do
    test "a resolved channel name is what identifies the destination", %{conn: conn, map: map} do
      rec = notification_with_webhooks(map, [:system])

      {:ok, _} =
        MapDiscordWebhook.cache_channel_info(system_webhook(rec), %{
          channel_id: "987650001234500777",
          channel_label: "#kill-feed",
          channel_label_source: :channel,
          guild_id: "112233445566778899"
        })

      html = conn |> open_notifications(map) |> render()

      assert html =~ "#kill-feed"
      # The card-level status line is built from the same identity.
      assert html =~ "Posting to #kill-feed"
      # Neither snowflake is a label.
      refute html =~ "987650001234500777"
      refute html =~ "112233445566778899"
    end

    # `channel_label_source` still records whether Discord answered from the
    # channel itself or from the webhook's own nickname, and `ChannelInfo` still
    # uses it to separate a known name from a masked fingerprint. The UI no
    # longer *speaks* the difference: it is a fact about how the name was
    # fetched, not about where messages land, and the operator has nothing to do
    # differently either way.
    test "a webhook nickname is shown plainly, with no source prefix", %{
      conn: conn,
      map: map
    } do
      rec = notification_with_webhooks(map, [:system])

      {:ok, _} =
        MapDiscordWebhook.cache_channel_info(system_webhook(rec), %{
          channel_id: "987650001234500777",
          channel_label: "Kill bot",
          channel_label_source: :webhook_name
        })

      html = conn |> open_notifications(map) |> render()

      assert html =~ "Kill bot"
      refute html =~ "Webhook: Kill bot"
      refute html =~ "Channel: Kill bot"

      # The sentence that used to explain the prefix is gone, and must stay
      # gone. It was also wrong more often than not: `bot_channel/1` returns
      # nil for a missing token, a 403, a 404, a rate limit and a plain cache
      # miss alike, and `persist/2` freezes that result for an hour — so
      # instances whose bot *is* in the server routinely read that it was not.
      # HEEx escapes the apostrophe, so match the half either side of it.
      refute html =~ "This is the webhook"
      refute html =~ "s bot is in that server"
    end

    # A row written before `channel_label_source` existed. The label is still
    # worth showing, but nothing is known about where it came from, so the UI
    # must claim neither — guessing from a leading "#" is exactly the inference
    # the source column exists to stop.
    test "a legacy label with no recorded source is shown with no claim", %{
      conn: conn,
      map: map
    } do
      rec = notification_with_webhooks(map, [:system])

      {:ok, _} =
        MapDiscordWebhook.cache_channel_info(system_webhook(rec), %{
          channel_id: "987650001234500777",
          channel_label: "#kill-feed",
          channel_label_source: nil
        })

      html = conn |> open_notifications(map) |> render()

      assert html =~ "#kill-feed"
      refute html =~ "Channel: #kill-feed"
      refute html =~ "Webhook: #kill-feed"
    end

    # No identity at all — the ordinary state on an instance with no bot token,
    # which is every test run and many real installs. `ChannelInfo` still
    # produces a masked hint rather than nothing, so the row identifies the
    # destination and the status line never renders an empty channel clause.
    test "an unresolved destination falls back to a masked hint, never a blank label", %{
      conn: conn,
      map: map
    } do
      rec = notification_with_webhooks(map, [:system])
      hint = String.slice(ChannelInfo.fingerprint(system_webhook(rec).webhook_url), 0, 4)

      html = conn |> open_notifications(map) |> render()

      assert html =~ "Posting to •••• #{hint}"
      # A masked hint makes no claim about being a channel or a webhook name.
      refute html =~ "Channel: ••••"
      refute html =~ "Webhook: ••••"
      refute html =~ "Posting to channel"
      refute html =~ "Posting to webhook"
      # A blank label would render as the separator with nothing before it.
      refute html =~ "Posting to  "
    end

    test "the route row says route alerts, not kills, when nothing has been sent", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system, :route])

      view = open_notifications(conn, map)

      # At rest the truth line uses the role-neutral state word, which is
      # correct for every row: "Never delivered" is a fact about deliveries, not
      # about what kind of thing was never delivered.
      assert render(view) =~ "Never delivered"
      refute render(view) =~ "No kills delivered yet."

      # The role-specific wording lives in the open form, where "No kills
      # delivered yet." under a channel that only ever carries route alerts
      # would read as a fault rather than an empty state.
      html = view |> edit_row(:route) |> render()

      assert html =~ "No route alerts delivered yet."
      refute html =~ "No kills delivered yet."
    end
  end

  describe "disclosure state" do
    # The reason `@open_sections` lives on the server rather than in
    # `JS.toggle_class`. This component re-renders on saves, on PubSub ticks and
    # on background channel-identity refreshes; a client-only toggle means every
    # one of those re-sends the literal collapsed markup and slams an open
    # section shut under the operator's hands. `edit_row/2` here is just a cheap
    # way to force a real re-render — any of the three would do.
    test "an opened section stays open across a re-render", %{conn: conn, map: map} do
      notification_with_webhooks(map, [:system])

      view = open_notifications(conn, map)

      assert has_element?(view, "#filters-disclosure-body.hidden")

      view
      |> element("button[phx-value-section='filters-disclosure']")
      |> render_click()

      assert has_element?(view, "#filters-disclosure-body.flex")

      assert has_element?(
               view,
               "button[phx-value-section='filters-disclosure'][aria-expanded='true']"
             )

      # Re-render the whole component.
      edit_row(view, :system)

      assert has_element?(view, "#filters-disclosure-body.flex")
    end

    # The body is toggled by class rather than by `:if` so that `aria-controls`
    # resolves to a real element while collapsed, and so the LiveSelect hooks
    # inside it are not destroyed and re-mounted on every toggle.
    test "a collapsed section is still in the document, and still addressed", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])

      view = open_notifications(conn, map)

      assert has_element?(
               view,
               "button[phx-value-section='filters-disclosure'][aria-controls='filters-disclosure-body'][aria-expanded='false']"
             )

      assert has_element?(view, "#filters-disclosure-body")
    end

    # D4's whole point: a configured-but-inert route destination is a warning,
    # and a warning inside a collapsed body has not been shown to anyone. Route
    # alerts are no longer a disclosure at all — they are the tab's second
    # section, always expanded — but the banner still has to sit outside the one
    # disclosure that section does have.
    test "the route warning renders outside any collapsed disclosure", %{
      conn: conn,
      map: map
    } do
      # `route_alerts_enabled?` defaults to false, so a route channel added
      # without turning alerts on is inert the moment it is saved — which is
      # precisely the trap this banner exists to name.
      notification_with_webhooks(map, [:system, :route])

      view = open_notifications(conn, map)

      assert has_element?(view, "#mentions-disclosure-body.hidden")
      refute has_element?(view, "#mentions-disclosure-body p", "Route alerts are switched off")
      assert render(view) =~ "Route alerts are switched off, but this channel is configured"
    end
  end

  describe "mention pickers degrade" do
    # With no bot token configured — the state of the test environment and of
    # any instance that has not set one up — `Discord.Guild` answers
    # `:no_bot_token`, which `unavailable?/1` treats as "cannot search this
    # guild". The section must then stay usable by id rather than disappearing,
    # because typing an id is the whole feature.
    test "to manual entry, with a reason, when the guild cannot be read", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system, :route])

      view = open_notifications(conn, map)

      assert has_element?(view, "#mention-manual-role")
      assert has_element?(view, "#mention-manual-user")
      refute has_element?(view, "#mention-role-form")
      refute has_element?(view, "#mention-user-form")
    end

    test "and the section is absent entirely with no route destination", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])

      view = open_notifications(conn, map)

      refute has_element?(view, "#route-mentions")
    end
  end
end
