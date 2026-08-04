defmodule WandererApp.ExternalEvents do
  @moduledoc """
  External event system for SSE and webhook delivery.

  This system is completely separate from the internal Phoenix PubSub
  event system and does NOT modify any existing event flows.

  External events are delivered to:
  - SSE clients via Server-Sent Events
  - HTTP webhooks via WebhookDispatcher

  ## Usage

      # From event producers, call this in ADDITION to existing broadcasts
      WandererApp.ExternalEvents.broadcast("map_123", :add_system, %{
        system_id: "0198f0a1-2222-7000-8000-000000000002",
        solar_system_id: 31000199,
        name: "J123456",
        position_x: 100,
        position_y: 200
      })

  This is additive-only and does not replace any existing functionality.
  """

  alias WandererApp.ExternalEvents.{Event, MapEventRelay}

  require Logger

  @doc """
  Broadcasts an event to external clients only.

  This does NOT affect internal PubSub or LiveView handlers.
  It only delivers events to:
  - SSE clients via Server-Sent Events
  - Configured webhook endpoints

  ## Parameters

  - `map_id`: The map identifier (string)
  - `event_type`: The event type atom (see Event.event_type/0)
  - `payload`: The event payload (map)

  ## Examples

      # System events - see map_server_systems_impl.ex
      WandererApp.ExternalEvents.broadcast("map_123", :add_system, %{
        system_id: "0198f0a1-2222-7000-8000-000000000002",
        solar_system_id: 31000199,
        name: "J123456",
        position_x: 100,
        position_y: 200
      })

      # Kill events carry a BATCH of killmails, not a single kill -
      # see kills/message_handler.ex:126
      WandererApp.ExternalEvents.broadcast("map_123", :map_kill, %{
        "solar_system_id" => 31000199,
        "killmails" => [%{"killmail_id" => 98765, "victim_ship_name" => "Rifter"}],
        "timestamp" => "2026-08-04T12:00:00Z",
        "type" => :killmail_update
      })
  """
  @spec broadcast(String.t(), Event.event_type(), map()) :: :ok
  def broadcast(map_id, event_type, payload) when is_binary(map_id) and is_map(payload) do
    log_message = "ExternalEvents.broadcast called - map: #{map_id}, type: #{event_type}"

    Logger.debug(fn -> log_message end)

    # Validate event type
    if Event.valid_event_type?(event_type) do
      # Create normalized event
      event = Event.new(map_id, event_type, payload)

      # Emit telemetry for monitoring
      :telemetry.execute(
        [:wanderer_app, :external_events, :broadcast],
        %{count: 1},
        %{map_id: map_id, event_type: event_type}
      )

      # Check if MapEventRelay is alive before sending
      if Process.whereis(MapEventRelay) do
        # Use cast for async delivery to avoid blocking the caller
        # This is critical for performance in hot paths (character updates)
        GenServer.cast(MapEventRelay, {:deliver_event, event})
        :ok
      else
        Logger.debug(fn -> "MapEventRelay not available for event delivery (map: #{map_id})" end)
        {:error, :relay_not_available}
      end
    else
      Logger.warning("Invalid external event type: #{inspect(event_type)}")
      {:error, :invalid_event_type}
    end
  end

  @doc """
  Lists all supported event types.
  """
  @spec supported_event_types() :: [Event.event_type()]
  def supported_event_types do
    Event.supported_event_types()
  end

  @doc """
  Validates an event type atom.
  """
  @spec valid_event_type?(atom()) :: boolean()
  def valid_event_type?(event_type) do
    Event.valid_event_type?(event_type)
  end
end
