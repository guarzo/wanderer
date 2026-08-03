defmodule WandererApp.Repo.Migrations.DiscordWebhookSplitTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapDiscordNotification
  alias WandererApp.Api.MapDiscordWebhook
  alias WandererAppWeb.Factory

  defp valid_url, do: "https://discord.com/api/webhooks/123456789/abcdefTOKEN"

  test "a pre-split row migrates to exactly one :system child with its state intact" do
    map = Factory.insert(:map, %{})

    {:ok, notification} =
      MapDiscordNotification.create(%{map_id: map.id, webhook_url: valid_url()})

    # Reproduce a pre-split row: failure state and enabled? on the parent, with
    # the child not yet existing. Raw SQL, because these columns no longer exist
    # on the resource — this is the only place in the suite that bypasses Ash.
    {:ok, [system_hook]} = MapDiscordWebhook.by_notification(notification.id)
    ciphertext = fetch_ciphertext(system_hook.id)
    :ok = MapDiscordWebhook.destroy(system_hook)

    {:ok, _} =
      WandererApp.Repo.query(
        """
        ALTER TABLE map_discord_notifications_v1
          ADD COLUMN IF NOT EXISTS encrypted_webhook_url bytea,
          ADD COLUMN IF NOT EXISTS last_delivery_at timestamp,
          ADD COLUMN IF NOT EXISTS last_error text,
          ADD COLUMN IF NOT EXISTS last_error_at timestamp,
          ADD COLUMN IF NOT EXISTS consecutive_failures bigint DEFAULT 0
        """,
        []
      )

    {:ok, _} =
      WandererApp.Repo.query(
        """
        UPDATE map_discord_notifications_v1
        SET encrypted_webhook_url = $1,
            "enabled?" = false,
            last_error = 'boom',
            last_error_at = now() AT TIME ZONE 'utc',
            consecutive_failures = 10
        WHERE id = $2
        """,
        [ciphertext, Ecto.UUID.dump!(notification.id)]
      )

    # The migration's data step, verbatim.
    {:ok, _} =
      WandererApp.Repo.query(
        """
        INSERT INTO map_discord_webhooks_v1 (
          id, notification_id, role, encrypted_webhook_url, "enabled?",
          last_delivery_at, last_error, last_error_at, consecutive_failures,
          inserted_at, updated_at
        )
        SELECT
          gen_random_uuid(), n.id, 'system', n.encrypted_webhook_url, n."enabled?",
          n.last_delivery_at, n.last_error, n.last_error_at, n.consecutive_failures,
          (now() AT TIME ZONE 'utc'), (now() AT TIME ZONE 'utc')
        FROM map_discord_notifications_v1 n
        WHERE n.id = $1
        """,
        [Ecto.UUID.dump!(notification.id)]
      )

    assert {:ok, [migrated]} = MapDiscordWebhook.by_notification(notification.id)
    assert migrated.role == :system

    # Ciphertext copied between tables still decrypts — the assumption the SQL
    # data step rests on (AshCloak binds neither table nor row into the cipher).
    assert migrated.webhook_url == valid_url()

    # Failure state moved down verbatim.
    assert migrated.consecutive_failures == 10
    assert migrated.last_error == "boom"
    assert migrated.last_error_at != nil

    # enabled? is copied to BOTH rows: the migration cannot distinguish a
    # user-disable from a failure-auto-disable, and staying silent is the
    # conservative direction.
    assert migrated.enabled? == false
    assert fetch_parent_enabled(notification.id) == false
  end

  defp fetch_ciphertext(webhook_id) do
    {:ok, %{rows: [[ciphertext]]}} =
      WandererApp.Repo.query(
        "SELECT encrypted_webhook_url FROM map_discord_webhooks_v1 WHERE id = $1",
        [Ecto.UUID.dump!(webhook_id)]
      )

    ciphertext
  end

  defp fetch_parent_enabled(notification_id) do
    {:ok, %{rows: [[enabled]]}} =
      WandererApp.Repo.query(
        "SELECT \"enabled?\" FROM map_discord_notifications_v1 WHERE id = $1",
        [Ecto.UUID.dump!(notification_id)]
      )

    enabled
  end
end
