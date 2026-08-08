# Loaded explicitly: migration files under `priv/repo/migrations` are not part
# of `elixirc_paths` (see mix.exs), so the module is not compiled into the app
# by default. Requiring it here — the real file, not a hand-typed copy of its
# SQL — is what lets this test prove the code that will actually run in
# production, per the review that flagged the previous version of this file.
Code.require_file(
  "priv/repo/migrations/20260803210357_split_discord_webhooks.exs",
  File.cwd!()
)

defmodule WandererApp.Repo.Migrations.DiscordWebhookSplitTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererAppWeb.Factory

  @version 20_260_803_210_357
  @migration WandererApp.Repo.Migrations.SplitDiscordWebhooks

  defp valid_url, do: "https://discord.com/api/webhooks/123456789/abcdefTOKEN"
  defp character_url, do: "https://discord.com/api/webhooks/222/othertok"

  # Runs the migration module's real up/0 or down/0 directly in the calling
  # process (rather than through `Ecto.Migrator.up/down`, which always wraps
  # the call in `Task.async` — a process the sandbox's shared-mode connection
  # is not reliably reachable from, causing connection-checkout timeouts).
  # `Ecto.Migration.Runner.run/8` is the same primitive `Ecto.Migrator` uses
  # internally to execute a migration once the transaction/task plumbing is
  # stripped away, so this still runs the actual `up/0`/`down/0` bodies.
  defp run_migration(direction) do
    Ecto.Migration.Runner.run(
      WandererApp.Repo,
      WandererApp.Repo.config(),
      @version,
      @migration,
      :forward,
      direction,
      direction,
      log: false
    )
  end

  defp fetch_parent_row(notification_id) do
    {:ok, %{rows: [row], columns: columns}} =
      WandererApp.Repo.query(
        """
        SELECT encrypted_webhook_url, "enabled?", last_delivery_at, last_error,
               last_error_at, consecutive_failures
        FROM map_discord_notifications_v1
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(notification_id)]
      )

    columns |> Enum.zip(row) |> Map.new()
  end

  defp count_system_rows(notification_id) do
    {:ok, %{rows: [[count]]}} =
      WandererApp.Repo.query(
        "SELECT count(*) FROM map_discord_webhooks_v1 WHERE notification_id = $1 AND role = 'system'",
        [Ecto.UUID.dump!(notification_id)]
      )

    count
  end

  # Postgres delivers `RAISE WARNING`/`RAISE NOTICE` output as protocol notice
  # messages attached to the `Postgrex.Result` of the query that produced them
  # (deps/postgrex/lib/postgrex/protocol.ex: `msg_notice` accumulates into
  # `result.messages`). Ecto surfaces that same result via the
  # `[:wanderer_app, :repo, :query]` telemetry event's `result` metadata
  # (deps/ecto_sql/lib/ecto/adapters/sql.ex `log/5`), regardless of whether the
  # query ran through a plain `Repo.query!` or — as here — through
  # `Ecto.Migration.Runner.run/8`. Attaching a telemetry handler is therefore
  # the only way to observe the warning text without hand-typing the SQL
  # ourselves: `execute/1` inside a migration discards its return value.
  defp with_pg_notices(fun) do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:wanderer_app, :repo, :query],
      fn _event, _measurements, %{result: result}, _config ->
        case result do
          {:ok, %{messages: [_ | _] = messages}} ->
            send(test_pid, {:pg_notice_messages, messages})

          _ ->
            :ok
        end
      end,
      nil
    )

    # try/after: a raise inside fun.() would otherwise leave the handler
    # attached for the rest of the suite, sending {:pg_notice_messages, _} to a
    # finished test process on every repo query.
    return_value =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    notices =
      Stream.unfold(:start, fn _ ->
        receive do
          {:pg_notice_messages, messages} -> {messages, :cont}
        after
          0 -> nil
        end
      end)
      |> Enum.to_list()
      |> List.flatten()

    {return_value, notices}
  end

  test "down/0 copies a webhook's state onto the parent and deletes it; up/0 splits it back out, leaving :character rows untouched throughout" do
    map = Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    {:ok, [system_hook]} = MapDiscordWebhook.by_notification(notification.id)

    {:ok, character_hook} =
      MapDiscordWebhook.create(%{
        notification_id: notification.id,
        role: :character,
        webhook_url: character_url()
      })

    # Give the :system destination real failure state and a disabled flag, so
    # the round trip has something non-default to prove is carried correctly.
    {:ok, system_hook} = MapDiscordWebhook.record_failure(system_hook, "boom")
    {:ok, system_hook} = MapDiscordWebhook.set_enabled(system_hook, %{enabled?: false})

    # -- down/0, for real --------------------------------------------------

    :ok = run_migration(:down)

    # The :system row's state moved onto the parent (raw SQL: down/0 drops the
    # very column the resource depends on to read `focus_corp_ids`, so an
    # Ash-level read of the parent is not valid again until up/0 restores it).
    parent = fetch_parent_row(notification.id)

    assert parent["enabled?"] == false
    assert parent["last_error"] == "boom"
    assert parent["last_error_at"] != nil
    assert parent["consecutive_failures"] == 1
    assert parent["encrypted_webhook_url"] != nil

    # The :system row itself is gone — down/0's DELETE ran for real.
    assert count_system_rows(notification.id) == 0
    assert {:error, _} = MapDiscordWebhook.by_id(system_hook.id)

    # The :character row was never derived from the parent and down/0 must
    # not have touched it.
    assert {:ok, untouched} = MapDiscordWebhook.by_id(character_hook.id)
    assert untouched.webhook_url == character_url()
    assert untouched.enabled? == true

    # -- up/0, for real ------------------------------------------------------

    :ok = run_migration(:up)

    assert {:ok, hooks} = MapDiscordWebhook.by_notification(notification.id)
    assert Enum.map(hooks, & &1.role) |> Enum.sort() == [:character, :system]

    migrated_system = Enum.find(hooks, &(&1.role == :system))

    # Ciphertext survived a real round trip through both migration directions
    # and still decrypts — the assumption the whole SQL data step rests on.
    assert migrated_system.webhook_url == valid_url()
    assert migrated_system.consecutive_failures == 1
    assert migrated_system.last_error == "boom"
    assert migrated_system.last_error_at != nil
    assert migrated_system.enabled? == false

    # A fresh row (up/0 always mints a new id via gen_random_uuid()), not the
    # original one down/0 deleted.
    refute migrated_system.id == system_hook.id

    # The parent's own `focus_corp_ids` — restored by up/0's `add` — is back
    # at its default; readable again because up/0 recreated the schema shape
    # the resource expects.
    assert {:ok, reloaded_notification} = MapDiscordNotification.by_map(map.id)
    assert reloaded_notification.focus_corp_ids == []

    # The :character row is exactly as it was before either migration ran.
    still_untouched = Enum.find(hooks, &(&1.role == :character))
    assert still_untouched.id == character_hook.id
    assert still_untouched.webhook_url == character_url()

    # -- up/0's idempotency guard --------------------------------------------
    #
    # Roll back once more, then plant a :system row for this notification
    # by hand — a hand-repaired row, or a partially-applied prior deploy —
    # *before* up/0 runs. Without the `WHERE NOT EXISTS` guard, up/0's INSERT
    # would collide with the child's unique (notification_id, role) identity
    # and abort the whole migration.
    :ok = run_migration(:down)

    pre_existing_id = Ecto.UUID.generate()

    {:ok, _} =
      WandererApp.Repo.query(
        """
        INSERT INTO map_discord_webhooks_v1
          (id, notification_id, role, encrypted_webhook_url, "enabled?", consecutive_failures, inserted_at, updated_at)
        VALUES ($1, $2, 'system', $3, true, 0, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        """,
        [
          Ecto.UUID.dump!(pre_existing_id),
          Ecto.UUID.dump!(notification.id),
          <<0, 0, 0>>
        ]
      )

    # up/0 must not abort just because it's skipping this row — and it must
    # say so in a `RAISE WARNING` naming the notification, since the parent's
    # `encrypted_webhook_url` (still non-null after the `:down` above restored
    # it) is about to be dropped without ever reaching this hand-planted
    # :system row.
    {migration_result, notices} = with_pg_notices(fn -> run_migration(:up) end)

    assert migration_result == :ok

    warning = Enum.find(notices, &(&1.severity == "WARNING"))
    assert warning, "expected a RAISE WARNING notice, got: #{inspect(notices)}"
    assert warning.message =~ "split_discord_webhooks"
    assert warning.message =~ to_string(notification.id)

    # No duplicate: still exactly one :system row for this notification.
    assert count_system_rows(notification.id) == 1

    # And it is the pre-existing row, untouched — proving the guard actually
    # skipped the INSERT rather than, say, silently overwriting it.
    {:ok, %{rows: [[stored_id]]}} =
      WandererApp.Repo.query(
        "SELECT id FROM map_discord_webhooks_v1 WHERE notification_id = $1 AND role = 'system'",
        [Ecto.UUID.dump!(notification.id)]
      )

    assert Ecto.UUID.load!(stored_id) == pre_existing_id
  end

  test "down/0 raises a legible error naming the notification when it has no :system webhook to restore from" do
    map = Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    {:ok, [system_hook]} = MapDiscordWebhook.by_notification(notification.id)

    # Destroy the only :system webhook this notification has. down/0's
    # reverse UPDATE joins on `role = 'system'`; with no such row to join to,
    # the parent's `encrypted_webhook_url` is left NULL, and the preflight
    # check must abort with a message naming this notification rather than
    # letting `SET NOT NULL` fail with Postgres' generic, id-less error.
    :ok = MapDiscordWebhook.destroy(system_hook)

    assert_raise Postgrex.Error, ~r/#{notification.id}/, fn ->
      run_migration(:down)
    end
  end
end
