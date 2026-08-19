defmodule WandererApp.Metrics.PromExPluginTest do
  @moduledoc """
  Guards the tracking instrumentation's ability to answer the question it exists
  for: "why did *this* character stop being tracked?"

  Three counters shipped with `tags: []` and a `get_empty_tag_values/1` that
  discarded the `character_id` their call sites already provide. The counters
  could therefore report that a freeze happened N times but never to whom, which
  is the only form the question is ever asked in. Three further events were
  emitted at their call sites with no handler attached at all, so they never
  reached Prometheus; `:online_transition` is emitted for the first time by the
  same change these tests cover.

  These tests fail if either regression is reintroduced.
  """

  use ExUnit.Case, async: true

  alias WandererApp.Metrics.PromExPlugin

  defp metrics do
    []
    |> PromExPlugin.event_metrics()
    |> List.wrap()
    |> Enum.flat_map(& &1.metrics)
  end

  defp find!(name) do
    case Enum.find(metrics(), &(&1.name == name)) do
      nil -> flunk("no metric registered for #{inspect(name)}")
      metric -> metric
    end
  end

  # Every metric whose whole purpose is diagnosing lost tracking.
  @tracking_metrics [
    [:wanderer_app, :character, :tracking, :location_flag_cleared, :count],
    [:wanderer_app, :character, :tracking, :location_flag_repaired, :count],
    [:wanderer_app, :character, :tracking, :location_skipped_while_active, :count],
    [:wanderer_app, :character, :tracking, :stopped, :count],
    [:wanderer_app, :character, :tracking, :permission_revoked, :count],
    [:wanderer_app, :character, :tracking, :online_transition, :count],
    [:wanderer_app, :character, :tracker, :stopped, :count],
    [:wanderer_app, :character, :tracker, :untracked_from_map, :count],
    [:wanderer_app, :map, :character_settings, :untracked, :count],
    [:wanderer_app, :token, :refresh_failed, :count]
  ]

  describe "metric names are unique" do
    # A duplicate metric name is not an error: the Prometheus registry logs a
    # warning and skips one of the two definitions, so the loser silently never
    # records. [:character, :tracker, :stopped] is the live trap here — it is
    # declared by character_event_metrics/0 and is one letter away from the
    # :tracking event names.
    test "no two registered metrics share a name" do
      names = Enum.map(metrics(), & &1.name)
      duplicates = names -- Enum.uniq(names)

      assert duplicates == [],
             "duplicate metric names #{inspect(Enum.uniq(duplicates))}; the registry would " <>
               "silently skip one definition"
    end
  end

  describe "tag_values / tags contract" do
    # TelemetryMetricsPrometheus.Core.Counter drops the event entirely when
    # tag_values/1 omits any declared tag (validate_tags_in_tag_values/2), and
    # reports it only via Logger.debug — which production never sees, since it
    # runs at :info. A tag added to `tags:` without a matching key in the
    # tag_values function would therefore silently stop the metric recording,
    # which is the exact failure mode this instrumentation exists to escape.
    test "every tracking metric returns all of its declared tags, even for empty metadata" do
      for name <- @tracking_metrics do
        metric = find!(name)
        returned = metric.tag_values.(%{})
        missing = Enum.reject(metric.tags, &Map.has_key?(returned, &1))

        assert missing == [],
               "#{inspect(name)} declares tags #{inspect(metric.tags)} but tag_values/1 " <>
                 "omitted #{inspect(missing)}; the Prometheus reporter would silently drop " <>
                 "every event for this metric"
      end
    end
  end

  describe "location tracking defect counters" do
    test "carry character_id so a counter can be traced to a pilot" do
      for event <- [
            :location_flag_cleared,
            :location_flag_repaired,
            :location_skipped_while_active
          ] do
        metric = find!([:wanderer_app, :character, :tracking, event, :count])

        assert :character_id in metric.tags,
               "#{event} dropped its character_id tag; it can no longer name the affected pilot"
      end
    end

    test "tag_values actually propagates character_id from event metadata" do
      metric = find!([:wanderer_app, :character, :tracking, :location_flag_repaired, :count])

      assert %{character_id: "char-1"} = metric.tag_values.(%{character_id: "char-1"})
    end

    test "tag_values does not crash on metadata missing character_id" do
      metric = find!([:wanderer_app, :character, :tracking, :location_flag_cleared, :count])

      assert %{character_id: "unknown"} = metric.tag_values.(%{})
    end
  end

  describe "previously unhandled tracking lifecycle events" do
    test "tracking stopped is registered and keeps the reason" do
      metric = find!([:wanderer_app, :character, :tracking, :stopped, :count])

      assert :reason in metric.tags
      assert :character_id in metric.tags

      assert %{reason: :presence_expired, character_id: "char-1"} =
               metric.tag_values.(%{reason: :presence_expired, character_id: "char-1"})
    end

    test "permission revoked is tagged by map, since it reports a batch" do
      metric = find!([:wanderer_app, :character, :tracking, :permission_revoked, :count])

      # The event carries :character_ids (a list), so there is no single
      # character to name — tagging by character_id here would be a silent lie.
      assert :map_id in metric.tags
      refute :character_id in metric.tags
    end

    test "permission revoked sums the batch size instead of counting events" do
      metric = find!([:wanderer_app, :character, :tracking, :permission_revoked, :count])

      # A Counter ignores measurements and increments by 1 per event, so an ACL
      # sweep removing 40 characters would register as 1 — while :stopped fires
      # 40 times for that same sweep. The two are meant to be read against each
      # other, so this must be a Sum over the :count measurement.
      assert %Telemetry.Metrics.Sum{} = metric
      assert metric.measurement == :count
    end

    test "the tracker-level untrack path is registered too" do
      # One letter from :tracking — the delayed untrack queue, previously with
      # no handler at all.
      metric = find!([:wanderer_app, :character, :tracker, :untracked_from_map, :count])

      assert :character_id in metric.tags
      assert :reason in metric.tags
    end

    test "tracker stopped keeps the character and reason it already emitted" do
      metric = find!([:wanderer_app, :character, :tracker, :stopped, :count])

      assert :character_id in metric.tags

      assert %{reason: :garbage_collection, character_id: "char-1"} =
               metric.tag_values.(%{reason: :garbage_collection, character_id: "char-1"})
    end

    test "online transition records direction and whether maps were active" do
      metric = find!([:wanderer_app, :character, :tracking, :online_transition, :count])

      assert :online in metric.tags
      assert :has_active_maps in metric.tags

      assert %{online: false, has_active_maps: true} =
               metric.tag_values.(%{
                 character_id: "char-1",
                 online: false,
                 has_active_maps: true
               })
    end

    test "token refresh failure is registered with its error type" do
      metric = find!([:wanderer_app, :token, :refresh_failed, :count])

      assert :error_type in metric.tags

      assert %{error_type: "invalid_grant", character_id: "char-1"} =
               metric.tag_values.(%{
                 character_id: "char-1",
                 error_type: "invalid_grant",
                 time_since_expiry: 12
               })
    end

    test "the database uncheck is registered and names the code path" do
      # Every writer of tracked=false funnels through
      # MapCharacterSettingsRepo.untrack/1, so this counter sees an uncheck no
      # matter which path caused it. :source is what makes it diagnostic rather
      # than just a count.
      metric = find!([:wanderer_app, :map, :character_settings, :untracked, :count])

      assert :source in metric.tags
      assert :character_id in metric.tags

      assert %{source: :acl_sweep, character_id: "char-1"} =
               metric.tag_values.(%{
                 character_id: "char-1",
                 map_id: "map-1",
                 source: :acl_sweep
               })
    end
  end
end
