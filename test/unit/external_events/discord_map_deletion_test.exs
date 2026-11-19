defmodule WandererApp.ExternalEvents.DiscordMapDeletionTest do
  @moduledoc """
  Map deletion and cluster invalidation for the Discord delivery path (the
  fork-model port of upstream 38b773e9's `invalidate_cache/2` and
  `for_delivery`): deleting a map must stop its per-webhook workers, and an
  invalidation published by another node must evict this node's cache and stop
  its workers.
  """
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.{MapDiscordNotification, MapDiscordWebhook}
  alias WandererApp.ExternalEvents.Discord.{HttpStub, WorkerSupervisor}
  alias WandererApp.ExternalEvents.DiscordDispatcher
  alias WandererAppWeb.Factory

  @cache :discord_notification_cache
  @topic "discord_notifications:config"

  setup do
    original = Application.get_env(:wanderer_app, :external_events, [])

    Application.put_env(
      :wanderer_app,
      :external_events,
      Keyword.put(original, :webhooks_enabled, true)
    )

    on_exit(fn -> Application.put_env(:wanderer_app, :external_events, original) end)

    HttpStub.start()
    HttpStub.reset()
    start_supervised!(WorkerSupervisor)
    start_supervised!(DiscordDispatcher)

    map = Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{
        map_id: map.id,
        webhook_url: "https://discord.com/api/webhooks/123/tok"
      })

    {:ok, [webhook]} = MapDiscordWebhook.by_notification(notification.id)
    %{map: map, notification: notification, webhook: webhook}
  end

  defp message, do: %{"embeds" => [%{"title" => "test"}]}

  # Parks a request in flight so the worker is demonstrably alive and busy.
  defp hold_worker(webhook) do
    parent = self()

    HttpStub.set_responses([
      fn _, _ ->
        send(parent, {:held, self()})

        receive do
          :release -> {:ok, 204, []}
        end
      end
    ])

    WorkerSupervisor.deliver(webhook.id, [message()])
    assert_receive {:held, task}, 2_000
    on_exit(fn -> send(task, :release) end)
    [{pid, _}] = Registry.lookup(WorkerSupervisor.registry(), webhook.id)
    pid
  end

  test "soft-deleting a map stops its delivery workers", %{map: map, webhook: webhook} do
    pid = hold_worker(webhook)
    ref = Process.monitor(pid)

    assert {:ok, _} = WandererApp.Api.Map.mark_as_deleted(map)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    assert Registry.lookup(WorkerSupervisor.registry(), webhook.id) == []
  end

  test "hard-destroying a map stops workers whose rows the cascade removed", %{
    map: map,
    webhook: webhook
  } do
    pid = hold_worker(webhook)
    ref = Process.monitor(pid)

    assert :ok = Ash.destroy(map, authorize?: false)

    assert {:error, _} = MapDiscordWebhook.by_id(webhook.id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
  end

  test "the delivery read path skips a soft-deleted map", %{map: map, webhook: webhook} do
    assert {:ok, _} = MapDiscordWebhook.for_delivery(webhook.id)
    assert {:ok, _} = WandererApp.Api.Map.mark_as_deleted(map)

    assert {:error, _} = MapDiscordWebhook.for_delivery(webhook.id)
    # The settings path still sees the row; only delivery is gated.
    assert {:ok, _} = MapDiscordWebhook.by_id(webhook.id)

    # A late enqueue restarts a worker but must not post anything.
    WorkerSupervisor.deliver(webhook.id, [message()])
    [{pid, _}] = Registry.lookup(WorkerSupervisor.registry(), webhook.id)
    :sys.get_state(pid)
    :sys.get_state(pid)
    assert HttpStub.requests() == []
    assert {:ok, %{last_delivery_at: nil}} = MapDiscordWebhook.by_id(webhook.id)
  end

  test "invalidate_cache/1 keeps working and does not stop workers", %{
    map: map,
    webhook: webhook
  } do
    pid = hold_worker(webhook)
    Cachex.put(@cache, map.id, :none)

    assert :ok = DiscordDispatcher.invalidate_cache(map.id)

    assert {:ok, nil} = Cachex.get(@cache, map.id)
    assert Process.alive?(pid)
  end

  test "invalidate_cache/2 publishes the invalidation with the resolved webhook ids", %{
    map: map,
    webhook: webhook
  } do
    Phoenix.PubSub.subscribe(WandererApp.PubSub, @topic)
    node = node()

    assert :ok = DiscordDispatcher.invalidate_cache(map.id, true)
    assert_receive {:discord_notification_config_changed, map_id, [id], ^node}
    assert map_id == map.id
    assert id == webhook.id

    assert :ok = DiscordDispatcher.invalidate_cache(map.id)
    assert_receive {:discord_notification_config_changed, _, [], ^node}
  end

  test "an invalidation from another node evicts the cache and stops workers", %{
    map: map,
    webhook: webhook
  } do
    pid = hold_worker(webhook)
    ref = Process.monitor(pid)
    Cachex.put(@cache, map.id, :none)

    Phoenix.PubSub.broadcast(
      WandererApp.PubSub,
      @topic,
      {:discord_notification_config_changed, map.id, [webhook.id], :other@elsewhere}
    )

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    assert {:ok, nil} = Cachex.get(@cache, map.id)
  end

  test "an invalidation from this node is not applied a second time", %{
    map: map,
    webhook: webhook
  } do
    pid = hold_worker(webhook)
    Cachex.put(@cache, map.id, :none)

    Phoenix.PubSub.broadcast(
      WandererApp.PubSub,
      @topic,
      {:discord_notification_config_changed, map.id, [webhook.id], node()}
    )

    # Synchronise on the dispatcher having handled the message.
    :sys.get_state(DiscordDispatcher)

    assert Process.alive?(pid)
    assert {:ok, :none} = Cachex.get(@cache, map.id)
  end
end
