defmodule WandererAppWeb.WebhookController do
  use WandererAppWeb, :controller
  require Logger

  alias WandererApp.Kills.PubSubSubscriber

    def kills(conn, payload) do
    webhook_type = Map.get(payload, "type", "unknown")
    Logger.info("[WebhookController] 📨 Received webhook: type=#{webhook_type}")
    Logger.info("[WebhookController] 🔍 Full webhook payload: #{inspect(payload, pretty: true, limit: :infinity)}")

    # Forward the webhook payload to the PubSubSubscriber
    PubSubSubscriber.handle_webhook(payload)

    json(conn, %{status: "received"})
  end
end
