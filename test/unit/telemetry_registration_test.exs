defmodule WandererApp.TelemetryRegistrationTest do
  @moduledoc """
  Keeps the emitted telemetry events and the registered PromEx metrics in sync,
  in both directions.

  Each direction fails silently in its own way, and this investigation produced
  one live instance of each:

    * Registered but never emitted — `[:wanderer_app, :esi, :error]` had a
      counter declared and no `:telemetry.execute/3` anywhere in `lib/`. The
      series never materializes, so a dashboard panel reads "no data" and an
      alert on it can never fire. Indistinguishable from "no errors are
      happening".

    * Emitted but never registered — `[:wanderer_app, :character, :tracking,
      :stopped]` was emitted on every untrack and collected nowhere. The
      instrumentation cost is paid and the data is discarded.

  Both are static properties of the source, so this test reads the source rather
  than starting the app: an event that is only reachable at runtime under rare
  conditions still has to be declared in both places.
  """

  use ExUnit.Case, async: true

  @plugin_path "lib/wanderer_app/metrics/prom_ex_plugin.ex"
  @lib_root "lib"

  # Events that are deliberately registered without a direct emitter in this
  # repository. Each entry needs a reason; an unexplained entry here is the same
  # silent gap this test exists to catch.
  @registered_without_emitter %{
    # Prefix used to build the character-tracker distribution metrics from the
    # :started/:stopped events below it, not itself an event name.
    [:wanderer_app, :character, :tracker] => "metric name prefix, not an event"
  }

  # Events emitted with no PromEx registration at the time this test was added.
  # Every one of them pays the emission cost and is dropped on the floor. They
  # are listed rather than fixed so the test can hold the line today: nothing new
  # may join this list without a deliberate decision, and the list is meant to
  # shrink. Registering one is a matter of adding a counter to the plugin and
  # deleting the line here.
  @emitted_without_registration_baseline [
    [:wanderer_app, :acl, :member, :add],
    [:wanderer_app, :acl, :member, :update],
    [:wanderer_app, :api, :request, :exception],
    [:wanderer_app, :api, :request, :start],
    [:wanderer_app, :api, :request, :stop],
    [:wanderer_app, :api_versioning],
    [:wanderer_app, :ash, :preparation, :filter_by_map],
    [:wanderer_app, :ash, :preparation, :filter_by_map, :no_context],
    [:wanderer_app, :character, :location_update, :complete],
    [:wanderer_app, :character, :location_update, :race_condition],
    [:wanderer_app, :character, :location_update, :start],
    [:wanderer_app, :character, :tracker, :garbage_collection],
    [:wanderer_app, :character, :tracker, :untracked_from_map],
    [:wanderer_app, :character, :tracker_pool, :queue_buildup],
    [:wanderer_app, :character, :tracking, :permission_revoked],
    [:wanderer_app, :connection, :auto_downgrade],
    [:wanderer_app, :connection, :manual_status_change],
    [:wanderer_app, :discord, :corp_tickers],
    [:wanderer_app, :discord, :notable_items],
    [:wanderer_app, :discord, :route_alert],
    [:wanderer_app, :discord_dispatcher, :dispatched],
    [:wanderer_app, :discord_dispatcher, :killmail_dropped],
    [:wanderer_app, :discord_dispatcher, :not_delivered],
    [:wanderer_app, :external_events, :broadcast],
    [:wanderer_app, :external_events, :relay, :delivered],
    [:wanderer_app, :external_events, :relay, :received],
    [:wanderer_app, :finch, :pool_exhausted],
    [:wanderer_app, :finch, :pool_timeout],
    [:wanderer_app, :map, :character, :removed],
    [:wanderer_app, :map, :characters_cleanup, :removal_complete],
    [:wanderer_app, :map, :characters_cleanup, :removal_started],
    [:wanderer_app, :map, :cleanup_connections, :cache_miss],
    [:wanderer_app, :map, :cleanup_systems, :cache_miss],
    [:wanderer_app, :map, :connection_cleanup, :delete],
    [:wanderer_app, :map, :duplicate_slug_detected],
    [:wanderer_app, :map, :full_recovery, :complete],
    [:wanderer_app, :map, :full_recovery, :start],
    [:wanderer_app, :map, :index_created],
    [:wanderer_app, :map, :map_pool, :queue_buildup],
    [:wanderer_app, :map, :presence, :characters_left],
    [:wanderer_app, :map, :reconciliation],
    [:wanderer_app, :map, :reconciliation, :cache_fixed],
    [:wanderer_app, :map, :reconciliation, :orphan_fixed],
    [:wanderer_app, :map, :reconciliation, :zombie_cleanup],
    [:wanderer_app, :map, :slow_init],
    [:wanderer_app, :map, :slug_fallback_used],
    [:wanderer_app, :map, :slug_recovery, :complete],
    [:wanderer_app, :map, :slug_recovery, :error],
    [:wanderer_app, :map, :slug_recovery, :start],
    [:wanderer_app, :map, :slug_suffix_used],
    [:wanderer_app, :map, :system_addition, :complete],
    [:wanderer_app, :map, :system_addition, :error],
    [:wanderer_app, :map, :system_addition, :start],
    [:wanderer_app, :map, :tracked_characters, :count],
    [:wanderer_app, :map, :tracking_reconciliation, :restored],
    [:wanderer_app, :map, :update_characters, :complete],
    [:wanderer_app, :map, :update_characters, :error],
    [:wanderer_app, :map, :update_characters, :start],
    [:wanderer_app, :map_pool, :init_failed],
    [:wanderer_app, :map_pool, :recovery, :complete],
    [:wanderer_app, :map_pool, :recovery, :map_failed],
    [:wanderer_app, :map_pool, :recovery, :start],
    [:wanderer_app, :map_pool, :slow_init],
    [:wanderer_app, :presence, :grace_period_cancelled],
    [:wanderer_app, :presence, :grace_period_expired],
    [:wanderer_app, :presence, :grace_period_started],
    [:wanderer_app, :request_validation],
    [:wanderer_app, :security_audit],
    [:wanderer_app, :security_audit, :async_flush_failure],
    [:wanderer_app, :security_audit, :async_flush_partial],
    [:wanderer_app, :security_audit, :bulk_operation],
    [:wanderer_app, :security_audit, :events_dropped],
    [:wanderer_app, :security_audit, :storage_error],
    [:wanderer_app, :security_audit, :threat_detected],
    [:wanderer_app, :signature_cleanup, :completed],
    [:wanderer_app, :token, :refresh_failed],
    [:wanderer_app, :tracker_pool, :info_skipped],
    [:wanderer_app, :tracker_pool, :location_lag],
    [:wanderer_app, :tracker_pool, :location_update],
    [:wanderer_app, :tracker_pool, :ship_skipped],
    [:wanderer_app, :user, :wallet_balance, :changed],
    [:wanderer_app, :webhook_dispatcher, :batch_received],
    [:wanderer_app, :webhook_dispatcher, :delivery_failure],
    [:wanderer_app, :webhook_dispatcher, :delivery_success],
    [:wanderer_app, :webhook_dispatcher, :event_received]
  ]

  defp source_files do
    Path.wildcard(Path.join(@lib_root, "**/*.ex"))
  end

  defp parse_event_list(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.trim_leading(&1, ":"))
    |> Enum.map(&String.to_atom/1)
  end

  defp registered_events do
    plugin = File.read!(@plugin_path)

    ~r/@[a-z_]+_event\s+\[([^\]]*)\]/
    |> Regex.scan(plugin, capture: :all_but_first)
    |> Enum.map(fn [raw] -> parse_event_list(raw) end)
    |> Enum.filter(&match?([:wanderer_app | _], &1))
    |> MapSet.new()
  end

  defp emitted_events do
    source_files()
    |> Enum.flat_map(fn path ->
      ~r/:telemetry\.execute\(\s*\[([^\]]*)\]/
      |> Regex.scan(File.read!(path), capture: :all_but_first)
      |> Enum.map(fn [raw] -> parse_event_list(raw) end)
    end)
    |> Enum.filter(&match?([:wanderer_app | _], &1))
    |> MapSet.new()
  end

  test "every registered metric has an emitter" do
    exempt = @registered_without_emitter |> Map.keys() |> MapSet.new()

    unemitted =
      registered_events()
      |> MapSet.difference(emitted_events())
      |> MapSet.difference(exempt)
      |> MapSet.to_list()

    assert unemitted == [],
           """
           These events are registered in #{@plugin_path} but never emitted:

           #{Enum.map_join(unemitted, "\n", &"  #{inspect(&1)}")}

           The series will never exist, so any panel or alert reading it sits at
           "no data" forever — which looks exactly like a healthy zero.

           Either emit the event where the condition it names occurs, or, if it
           is genuinely not applicable, add it to @registered_without_emitter
           with the reason.
           """
  end

  test "every emitted event is registered as a metric" do
    exempt = MapSet.new(@emitted_without_registration_baseline)

    unregistered =
      emitted_events()
      |> MapSet.difference(registered_events())
      |> MapSet.difference(exempt)
      |> MapSet.to_list()

    assert unregistered == [],
           """
           These events are emitted in #{@lib_root}/ but registered nowhere in
           #{@plugin_path}:

           #{Enum.map_join(unregistered, "\n", &"  #{inspect(&1)}")}

           The emission cost is paid and the data is dropped on the floor.

           Register a counter for it in the plugin. Adding it to
           @emitted_without_registration_baseline instead is allowed only as a
           deliberate decision — that list exists to be shortened, not extended.
           """
  end

  test "the unregistered baseline has no stale entries" do
    stale =
      @emitted_without_registration_baseline
      |> MapSet.new()
      |> MapSet.intersection(registered_events())
      |> MapSet.to_list()

    assert stale == [],
           """
           These events are listed in @emitted_without_registration_baseline but
           are now registered:

           #{Enum.map_join(stale, "\n", &"  #{inspect(&1)}")}

           Delete them from the list. Left in place, the list stops describing
           the gap and starts hiding a regression: re-removing the registration
           later would not fail this test.
           """
  end
end
