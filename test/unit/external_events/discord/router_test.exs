defmodule WandererApp.ExternalEvents.Discord.RouterTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.ExternalEvents.Discord.Router
  alias WandererAppWeb.Factory

  @wh_system 31_000_005
  @ks_system 30_000_142

  setup do
    Cachex.put(:system_static_info_cache, @wh_system, %{
      solar_system_id: @wh_system,
      solar_system_name: "J115405",
      system_class: 3
    })

    Cachex.put(:system_static_info_cache, @ks_system, %{
      solar_system_id: @ks_system,
      solar_system_name: "Jita",
      system_class: 0
    })

    on_exit(fn ->
      Cachex.del(:system_static_info_cache, @wh_system)
      Cachex.del(:system_static_info_cache, @ks_system)
    end)

    map = Factory.insert(:map, %{})

    # `create` takes `webhook_url` as a required argument and seeds the `:system`
    # child through `manage_relationship` in the same transaction, so the system
    # webhook already exists here. Creating a second `:system` row would violate
    # the (notification_id, role) identity.
    {:ok, notification} =
      MapDiscordNotification.create(%{
        map_id: map.id,
        webhook_url: "https://discord.com/api/webhooks/1/sys"
      })

    notification = Ash.load!(notification, :webhooks)
    system_wh = Enum.find(notification.webhooks, &(&1.role == :system))

    %{map: map, notification: notification, system_wh: system_wh}
  end

  defp with_webhooks(notification), do: Ash.load!(notification, :webhooks)

  defp add_character_webhook(notification) do
    {:ok, wh} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: "https://discord.com/api/webhooks/2/chr"
      })

    wh
  end

  defp kill(system_id), do: %{"killmail_id" => 1, "solar_system_id" => system_id}

  test "rule 4: an uninvolved kill goes to the system webhook", %{
    notification: n,
    system_wh: system_wh
  } do
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    assert {:ok, %{id: id}} = Router.route(kill(@ks_system), with_webhooks(n), :not_involved)
    assert id == system_wh.id
  end

  test "rule 3: an involved kill goes to the character webhook", %{notification: n} do
    character_wh = add_character_webhook(n)
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    assert {:ok, %{id: id}} =
             Router.route(kill(@ks_system), with_webhooks(n), {:involved, :victim})

    assert id == character_wh.id
  end

  # The compatibility guarantee: every existing single-webhook config keeps
  # working untouched.
  test "rule 3 falls back to the system webhook when no character row exists", %{
    notification: n,
    system_wh: system_wh
  } do
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    assert {:ok, %{id: id}} =
             Router.route(kill(@ks_system), with_webhooks(n), {:involved, :attacker})

    assert id == system_wh.id
  end

  test "rule 1: an excluded system drops when not involved", %{notification: n} do
    {:ok, n} =
      MapDiscordNotification.update(n, %{wh_only: false, excluded_systems: [@ks_system]})

    assert Router.route(kill(@ks_system), with_webhooks(n), :not_involved) == :drop
  end

  test "rule 1 does not apply to an involved kill", %{notification: n} do
    character_wh = add_character_webhook(n)

    {:ok, n} =
      MapDiscordNotification.update(n, %{wh_only: false, excluded_systems: [@ks_system]})

    assert {:ok, %{id: id}} =
             Router.route(kill(@ks_system), with_webhooks(n), {:involved, :victim})

    assert id == character_wh.id
  end

  test "rule 2: wh_only drops known space when not involved", %{notification: n} do
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: true})

    assert Router.route(kill(@ks_system), with_webhooks(n), :not_involved) == :drop
  end

  test "rule 2 does not apply to an involved kill", %{notification: n} do
    character_wh = add_character_webhook(n)
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: true})

    assert {:ok, %{id: id}} =
             Router.route(kill(@ks_system), with_webhooks(n), {:involved, :attacker})

    assert id == character_wh.id
  end

  test "wh_only still delivers wormhole kills", %{notification: n, system_wh: system_wh} do
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: true})

    assert {:ok, %{id: id}} = Router.route(kill(@wh_system), with_webhooks(n), :not_involved)
    assert id == system_wh.id
  end

  # `:unknown` means involvement could not be determined — the tracked-set
  # cache was unavailable, or the payload carried no attacker data. Rules 1 and
  # 2 must not fire on it: they are filters that only a positive "this kill is
  # not ours" earns. If these two tests go to `:drop`, a Cachex outage silently
  # swallows every k-space kill on every map with the default `wh_only`, and the
  # only evidence is one log line.
  test "an unknown verdict bypasses the excluded-system filter", %{
    notification: n,
    system_wh: system_wh
  } do
    {:ok, n} =
      MapDiscordNotification.update(n, %{wh_only: false, excluded_systems: [@ks_system]})

    assert {:ok, %{id: id}} = Router.route(kill(@ks_system), with_webhooks(n), :unknown)
    assert id == system_wh.id
  end

  test "an unknown verdict bypasses the wormhole-only filter", %{
    notification: n,
    system_wh: system_wh
  } do
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: true})

    assert {:ok, %{id: id}} = Router.route(kill(@ks_system), with_webhooks(n), :unknown)
    assert id == system_wh.id
  end

  # It bypasses the filters, but it is NOT involvement. An undetermined kill
  # must not reach the character channel, which is commonly public and is
  # supposed to mean "these are ours".
  test "an unknown verdict goes to the system webhook even when a character one exists", %{
    notification: n,
    system_wh: system_wh
  } do
    _character_wh = add_character_webhook(n)
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    assert {:ok, %{id: id}} = Router.route(kill(@ks_system), with_webhooks(n), :unknown)
    assert id == system_wh.id
  end

  # DROP, NOT REROUTE. Turning this into `{:ok, system_wh}` would post kills
  # involving the user's own pilots into a channel they did not choose.
  test "a disabled character webhook drops rather than rerouting", %{notification: n} do
    character_wh = add_character_webhook(n)
    {:ok, _} = MapDiscordWebhook.set_enabled(character_wh, %{enabled?: false})
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    assert Router.route(kill(@ks_system), with_webhooks(n), {:involved, :victim}) == :drop
  end

  test "a disabled system webhook drops rather than rerouting", %{
    notification: n,
    system_wh: system_wh
  } do
    _character_wh = add_character_webhook(n)
    {:ok, _} = MapDiscordWebhook.set_enabled(system_wh, %{enabled?: false})
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    assert Router.route(kill(@ks_system), with_webhooks(n), :not_involved) == :drop
  end

  # A disabled `:system` destination must not spill uninvolved kills into the
  # character channel either. Both roles are present and enabled-state differs,
  # so a reroute in either direction shows up here.
  test "a disabled system webhook does not fall back to the character webhook", %{
    notification: n,
    system_wh: system_wh
  } do
    character_id = add_character_webhook(n).id
    {:ok, _} = MapDiscordWebhook.set_enabled(system_wh, %{enabled?: false})
    {:ok, n} = MapDiscordNotification.update(n, %{wh_only: false})

    result = Router.route(kill(@ks_system), with_webhooks(n), :not_involved)

    assert result == :drop
    refute match?({:ok, %{id: ^character_id}}, result)
  end

  # `:webhooks` is a relationship, so a notification that reached the router
  # without `Ash.load!/2` carries `%Ash.NotLoaded{}` here. Reading `.role` off
  # that would raise on the dispatch path; the `is_list` guard in `webhook/2`
  # turns it into "no destination" and drops, which is the conservative
  # direction. Nothing else covers that clause — without this test, deleting
  # the guard leaves the whole suite green.
  test "an unloaded :webhooks relationship drops instead of raising", %{notification: n} do
    {:ok, _} = MapDiscordNotification.update(n, %{wh_only: false})

    # Re-read rather than reusing the update's return value: `update/2` carries
    # the loaded relationship through, and this test is about the record a
    # caller gets when it never loaded one.
    {:ok, unloaded} = MapDiscordNotification.by_id(n.id)
    assert %Ash.NotLoaded{} = unloaded.webhooks

    assert Router.route(kill(@ks_system), unloaded, :not_involved) == :drop
    assert Router.route(kill(@wh_system), unloaded, {:involved, :kill}) == :drop
  end

  describe "route_destination/1" do
    defp add_route_webhook(notification) do
      {:ok, wh} =
        MapDiscordWebhook.create(%{
          notification_id: notification.id,
          role: :route,
          webhook_url: "https://discord.com/api/webhooks/3/route"
        })

      wh
    end

    test "a :route webhook is selected when present and enabled", %{notification: n} do
      route_wh = add_route_webhook(n)

      assert {:ok, %{id: id}} = Router.route_destination(with_webhooks(n))
      assert id == route_wh.id
    end

    # Compatibility guarantee, mirroring rule 3's fallback: every map with only
    # a :system webhook keeps working with no user action once route alerts
    # ship.
    test "falls back to the system webhook when no :route row exists", %{
      notification: n,
      system_wh: system_wh
    } do
      assert {:ok, %{id: id}} = Router.route_destination(with_webhooks(n))
      assert id == system_wh.id
    end

    # DROP, NOT REROUTE — the same rule `RouterTest` asserts for the character
    # webhook in "a disabled character webhook drops rather than rerouting".
    # A route alert *is* the chain topology (see the Router moduledoc); posting
    # it to a channel the user did not choose for this purpose is a privacy
    # violation, not a convenience.
    test "a disabled :route webhook drops rather than falling back to :system", %{
      notification: n
    } do
      route_wh = add_route_webhook(n)
      {:ok, _} = MapDiscordWebhook.set_enabled(route_wh, %{enabled?: false})

      assert Router.route_destination(with_webhooks(n)) == :drop
    end

    test "drops when neither :route nor :system exists" do
      # `MapDiscordNotification.create/1` always seeds a :system webhook
      # (see the module setup), so simulate "neither configured" the same way
      # the unloaded-relationship test does: a notification struct whose
      # webhooks list is empty rather than absent.
      empty = %{webhooks: []}

      assert Router.route_destination(empty) == :drop
    end

    test "an unloaded :webhooks relationship drops instead of raising", %{notification: n} do
      {:ok, unloaded} = MapDiscordNotification.by_id(n.id)
      assert %Ash.NotLoaded{} = unloaded.webhooks

      assert Router.route_destination(unloaded) == :drop
    end
  end
end
