defmodule WandererAppWeb.MapNotificationsTest do
  use WandererAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
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

  # Task 2's `create` takes `webhook_url` as a required argument and seeds the
  # `:system` child in the same transaction, so `roles` here only controls
  # whether a `:character` row is added on top. Passing `:system` in `roles`
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

  test "saving a valid webhook url creates the record", %{conn: conn, map: map} do
    view = open_notifications(conn, map)

    view
    |> form("#discord-notification-form", %{
      "notification" => %{
        "webhook_url" => "https://discord.com/api/webhooks/123/tok",
        "wh_only" => "true",
        "enabled" => "true"
      }
    })
    |> render_submit()

    assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
    assert rec.wh_only == true
    # Regression guard: the Enabled checkbox must render during creation too.
    # When it was hidden behind `:if={@notification}` the param was absent, so
    # `params["enabled"] == "true"` was false and every new config was born
    # disabled — invisibly, because the UI showed no checkbox to contradict it.
    assert rec.enabled? == true

    # The create action seeds the required `:system` destination in the same
    # transaction; a parent with no destination would deliver nothing.
    assert {:ok, [webhook]} = MapDiscordWebhook.by_notification(rec.id)
    assert webhook.role == :system
  end

  test "a new configuration is enabled when the box is left checked", %{conn: conn, map: map} do
    view = open_notifications(conn, map)

    # Submit exactly what the browser sends for a checked box rendered with a
    # preceding hidden "false": both keys, last one winning.
    view
    |> form("#discord-notification-form", %{
      "notification" => %{"webhook_url" => "https://discord.com/api/webhooks/123/tok"}
    })
    |> render_submit()

    assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
    assert rec.enabled? == true
  end

  test "an invalid url is rejected with a message", %{conn: conn, map: map} do
    view = open_notifications(conn, map)

    html =
      view
      |> form("#discord-notification-form", %{
        "notification" => %{"webhook_url" => "https://evil.example.com/x"}
      })
      |> render_submit()

    # Assert the resource's actual validation message, NOT the string
    # "Discord webhook URL" — that is the create form's own <label>, which
    # renders whenever there is no record, i.e. in this scenario always.
    # Asserting on it would pass even if the error were discarded entirely.
    assert html =~ "must be a Discord webhook URL"
    assert {:error, _} = MapDiscordNotification.by_map(map.id)
  end

  test "unchecking 'enabled' actually disables", %{conn: conn, map: map} do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    # An unchecked checkbox submits NO value at all. The hidden companion input
    # is what makes "off" distinguishable from "field absent"; without it the
    # record would silently re-enable itself on every save.
    view
    |> form("#discord-notification-form", %{
      "notification" => %{"enabled" => "false", "wh_only" => "false"}
    })
    |> render_submit()

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
    |> form("#discord-notification-form", %{
      "notification" => %{"enabled" => "true", "wh_only" => "true"}
    })
    |> render_submit()

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
    # `form/3` because the create-only URL field is not rendered once a record
    # exists — but a handler must not depend on the template to stay correct.
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    html =
      view
      |> with_target("#map-notifications")
      |> render_submit("save", %{
        "notification" => %{
          "webhook_url" => "https://discord.com/api/webhooks/999/NEWTOKEN",
          "enabled" => "true",
          "wh_only" => "true"
        }
      })

    assert html =~ "Saved."
    assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
    assert rec.wh_only == true
  end

  test "with no configuration at all, only the create form renders", %{conn: conn, map: map} do
    view = open_notifications(conn, map)

    assert has_element?(view, "#discord-notification-form")
    refute has_element?(view, "#webhook-form-character")
  end

  test "with only a system webhook, the character row offers to add one", %{
    conn: conn,
    map: map
  } do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    assert has_element?(view, "#webhook-form-system")
    assert has_element?(view, "#webhook-form-character")
    # The character destination is unset, so its form must be in add mode: a
    # URL field, and no test/remove buttons for a webhook that does not exist.
    # Both refutes are scoped to `#webhook-row-character`, not to the form:
    # those buttons live in a sibling <div> of the <form>, so a form-descendant
    # selector never matches them and the refute would pass unconditionally.
    assert has_element?(view, "#webhook-form-character input[type='password']")
    refute has_element?(view, "#webhook-row-character button[phx-click='remove-webhook']")
    refute has_element?(view, "#webhook-row-character button[phx-click='send-test']")
  end

  test "with both webhooks, each row has its own test and status controls", %{
    conn: conn,
    map: map
  } do
    notification_with_webhooks(map, [:system, :character])

    view = open_notifications(conn, map)

    assert has_element?(view, "#webhook-row-system button[phx-click='send-test']")
    assert has_element?(view, "#webhook-row-character button[phx-click='send-test']")
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

    # A saved destination renders masked, so the URL field only appears after
    # asking to replace it — the same two-step a user goes through.
    refute has_element?(view, "#webhook-form-system input[type='password']")

    view
    |> element("#webhook-form-system button[phx-click='replace-url']")
    |> render_click()

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

    view
    |> form("#webhook-form-character", %{
      "webhook" => %{"webhook_url" => "https://discord.com/api/webhooks/888/chartok"}
    })
    |> render_submit()

    {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
    assert %{role: :character} = Enum.find(webhooks, &(&1.role == :character))
    assert has_element?(view, "#webhook-row-character button[phx-click='remove-webhook']")
  end

  test "removing the character destination leaves the system one alone", %{conn: conn, map: map} do
    rec = notification_with_webhooks(map, [:system, :character])

    view = open_notifications(conn, map)

    view
    |> element("#webhook-row-character button[phx-click='remove-webhook']")
    |> render_click()

    {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
    assert Enum.map(webhooks, & &1.role) == [:system]
    refute has_element?(view, "#webhook-row-character button[phx-click='remove-webhook']")
  end

  test "a plain-string error renders as a sentence, not an inspected term", %{
    conn: conn,
    map: map
  } do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

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

    html = view |> element("button[phx-click='send-test']") |> render_click()

    # What this proves: a saved-but-disabled destination gets the remedy that
    # matches its actual state. The assert is the whole test — assert the
    # specific remedy sentence, not the word "disabled", because the row's own
    # status line already says "This destination is disabled and is not
    # delivering." and a looser match would pass without the error copy
    # changing at all.
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

    # The fixture is `[:system]` only, so exactly one Send test button exists.
    html = view |> element("button[phx-click='send-test']") |> render_click()

    assert html =~ "disabled on this server"
  end

  test "removing the configuration deletes the record", %{conn: conn, map: map} do
    notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    html = view |> element("button[phx-click='delete']") |> render_click()

    assert html =~ "Removed."
    assert {:error, _} = MapDiscordNotification.by_map(map.id)
    # Back to the create form, so the tab is usable again without a reload.
    assert has_element?(view, "#discord-notification-form")
  end

  test "a failed removal is reported instead of raising", %{conn: conn, map: map} do
    rec = notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    # Delete the row out from under the mounted view. The destroy then fails on
    # a stale record — with `Ash.destroy!` this raised and took the LiveView
    # down; it must surface as a message instead.
    :ok = Ash.destroy(rec)

    html = view |> element("button[phx-click='delete']") |> render_click()

    refute html =~ "Removed."
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
    rec = notification_with_webhooks(map, [:system])

    view = open_notifications(conn, map)

    # Same trigger as "a failed removal is reported instead of raising": the
    # row is deleted under the mounted view, so the destroy fails with a
    # `StaleRecord`, which carries no message and reaches `fallback_message/1`.
    :ok = Ash.destroy(rec)

    log =
      capture_log(fn ->
        html = view |> element("button[phx-click='delete']") |> render_click()
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

  describe "route alerts" do
    test "enabling route alerts without a home system surfaces the Ash validation error", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      html =
        view
        |> form("#discord-notification-form", %{
          "notification" => %{
            "enabled" => "true",
            "wh_only" => "true",
            "route_alerts_enabled" => "true",
            "home_system_id" => "",
            "route_max_jumps" => "5"
          }
        })
        |> render_submit()

      # Exact wording is Task 3's to define; this asserts on it because a
      # substring match loose enough to survive any wording would also survive
      # the validation being silently removed. If Task 3 ships different
      # copy, update this one line to match it — do not weaken the match.
      assert html =~ "is required when route alerts are enabled"

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      refute rec.route_alerts_enabled?
      assert rec.home_system_id == nil
    end

    test "saving valid route settings persists the toggle, home system, and max jumps", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> form("#discord-notification-form", %{
        "notification" => %{
          "enabled" => "true",
          "wh_only" => "true",
          "route_alerts_enabled" => "true",
          "home_system_id" => "30000142",
          "route_max_jumps" => "3"
        }
      })
      |> render_submit()

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      assert rec.route_alerts_enabled? == true
      assert rec.home_system_id == 30_000_142
      assert rec.route_max_jumps == 3
    end

    test "the route fields are hidden while the toggle is off, not removed from the form", %{
      conn: conn,
      map: map
    } do
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      # Off by default (route_alerts_enabled? defaults to false per Task 3) —
      # the wrapper carries the "hidden" class, and the inputs are still
      # present in the DOM so their values still post on save. Scoped to
      # `#discord-notification-form` because the settings dialog itself also
      # renders with a (JS-toggled, not LiveView-toggled) "hidden" class in
      # the static test render — an unscoped `div.hidden` selector matches
      # that outer wrapper too and would pass/fail for the wrong reason.
      assert has_element?(
               view,
               "#discord-notification-form div.hidden input[name='notification[home_system_id]']"
             )

      view
      |> element("input[name='notification[route_alerts_enabled]'][type='checkbox']")
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      refute has_element?(
               view,
               "#discord-notification-form div.hidden input[name='notification[home_system_id]']"
             )
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
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      # A real browser posts every input in the form with the change event, so
      # a re-render that rebuilds the form from anything BUT those params
      # silently discards whatever the user had already typed.
      view
      |> element("input[name='notification[route_alerts_enabled]'][type='checkbox']")
      |> render_change(%{
        "notification" => %{
          "route_alerts_enabled" => "true",
          "home_system_id" => "30000142",
          "route_max_jumps" => "4"
        }
      })

      assert has_element?(view, "input[name='notification[home_system_id]'][value='30000142']")
      assert has_element?(view, "input[name='notification[route_max_jumps]'][value='4']")
    end

    test "ticking the box and saving persists the toggle", %{conn: conn, map: map} do
      notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> element("input[name='notification[route_alerts_enabled]'][type='checkbox']")
      |> render_change(%{"notification" => %{"route_alerts_enabled" => "true"}})

      # Only `home_system_id` is supplied — the value the user types. Everything
      # else, the checkbox included, comes from the rendered DOM, which is the
      # whole point: this is what the browser actually posts.
      view
      |> form("#discord-notification-form", %{
        "notification" => %{"home_system_id" => "30000142"}
      })
      |> render_submit()

      assert {:ok, rec} = MapDiscordNotification.by_map(map.id)
      assert rec.route_alerts_enabled? == true
      assert rec.home_system_id == 30_000_142
    end

    test "toggling route alerts never renders a submitted webhook url", %{conn: conn, map: map} do
      # No notification yet, so the create path renders the webhook URL field
      # alongside the route toggle. The change event carries whatever is typed
      # into it, and the generic `.input` writes `value=` for password inputs
      # too — so a form rebuilt straight from those params would print a live
      # credential into the HTML.
      view = open_notifications(conn, map)

      url = "https://discord.com/api/webhooks/1534657087244603394/supersecrettoken"

      html =
        view
        |> element("input[name='notification[route_alerts_enabled]'][type='checkbox']")
        |> render_change(%{
          "notification" => %{"route_alerts_enabled" => "true", "webhook_url" => url}
        })

      refute html =~ "supersecrettoken"
      refute html =~ url
    end

    test "the route webhook url can be added", %{conn: conn, map: map} do
      rec = notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> form("#webhook-form-route", %{
        "webhook" => %{"webhook_url" => "https://discord.com/api/webhooks/999/routetok"}
      })
      |> render_submit()

      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
      assert %{role: :route, enabled?: true} = Enum.find(webhooks, &(&1.role == :route))
      assert has_element?(view, "#webhook-row-route button[phx-click='remove-webhook']")
    end

    test "an invalid mention target shows an inline error and does not persist the webhook", %{
      conn: conn,
      map: map
    } do
      rec = notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      html =
        view
        |> form("#webhook-form-route", %{
          "webhook" => %{
            "webhook_url" => "https://discord.com/api/webhooks/999/routetok",
            "mention_targets" => "role:123456789012345678, not-a-target"
          }
        })
        |> render_submit()

      assert html =~ "not-a-target"
      assert html =~ "not a valid mention target"

      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
      refute Enum.any?(webhooks, &(&1.role == :route))
    end

    test "valid mention targets are saved, comma-separated and trimmed", %{conn: conn, map: map} do
      rec = notification_with_webhooks(map, [:system])
      view = open_notifications(conn, map)

      view
      |> form("#webhook-form-route", %{
        "webhook" => %{
          "webhook_url" => "https://discord.com/api/webhooks/999/routetok",
          "mention_targets" => "role:123456789012345678,  user:234567890123456789 "
        }
      })
      |> render_submit()

      {:ok, webhooks} = MapDiscordWebhook.by_notification(rec.id)
      route_wh = Enum.find(webhooks, &(&1.role == :route))
      assert route_wh.mention_targets == ["role:123456789012345678", "user:234567890123456789"]
    end

    # The dead end `Router.route_destination/1`'s no-fallback rule creates: the
    # form lets an owner enable route alerts, set a home system and max jumps,
    # and save successfully while every alert is silently dropped for want of a
    # destination. The hint is the only feedback in that state.
    @hint "Route alerts need an enabled Route alert channel below"

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
end
