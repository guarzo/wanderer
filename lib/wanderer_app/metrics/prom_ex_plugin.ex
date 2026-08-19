defmodule WandererApp.Metrics.PromExPlugin do
  use PromEx.Plugin

  @character_tracker_event [:wanderer_app, :character, :tracker]
  @character_tracker_started_event [:wanderer_app, :character, :tracker, :started]
  @character_tracker_stopped_event [:wanderer_app, :character, :tracker, :stopped]
  @user_registered_event [:wanderer_app, :user, :registered]
  @user_character_registered_event [:wanderer_app, :user, :character, :registered]
  @map_character_added_event [:wanderer_app, :map, :character, :added]
  @map_character_jump_event [:wanderer_app, :map, :character, :jump]
  @map_created_event [:wanderer_app, :map, :created]
  @map_started_event [:wanderer_app, :map, :started]
  @map_stopped_event [:wanderer_app, :map, :stopped]
  @map_subscription_new_event [:wanderer_app, :map, :subscription, :new]
  @map_subscription_renew_event [:wanderer_app, :map, :subscription, :renew]
  @map_subscription_update_event [:wanderer_app, :map, :subscription, :update]
  @map_subscription_cancel_event [:wanderer_app, :map, :subscription, :cancel]
  @map_subscription_expired_event [:wanderer_app, :map, :subscription, :expired]

  # Location-tracking defect instrumentation. These three counters are read
  # together to validate the maybe_start_location_tracking/2 fix:
  #
  #   cleared  - the (is_online: true, track_location: false) pair was created
  #   repaired - a character who WOULD have frozen was restored by the fix
  #   skipped  - a character is frozen right now; must stay at zero post-fix
  #
  # repaired > 0 with skipped == 0 confirms both the mechanism and the fix.
  # skipped > 0 means a route to the frozen state the fix does not cover.
  @location_flag_cleared_event [:wanderer_app, :character, :tracking, :location_flag_cleared]
  @location_flag_repaired_event [:wanderer_app, :character, :tracking, :location_flag_repaired]
  @location_skipped_while_active_event [
    :wanderer_app,
    :character,
    :tracking,
    :location_skipped_while_active
  ]

  # Tracking-lifecycle instrumentation. The three location_flag counters above
  # only cover the flag defect fixed in #146; these cover the neighbouring paths
  # that could stop a character updating on the map.
  #
  # The first three were already being emitted at their call sites with no
  # handler attached anywhere, so nothing was reaching Prometheus. The fourth,
  # online_transition, is emitted for the first time by this change.
  #
  #   stopped            - tracking ended. `reason` is threaded from the caller
  #                        (:presence_expired, :permission_revoked,
  #                        :user_untracked); it used to be hardcoded to
  #                        :presence_expired for all three causes
  #   permission_revoked - ACL check removed characters (no grace period).
  #                        A sum, not a counter: one event carries a whole batch
  #   token_refresh_failed - ESI refresh failed. Only the invalid_grant variety
  #                        wipes a token, and only 3 within the 2h counter TTL
  #   online_transition  - update_online/1 rewrote track_location because EVE
  #                        online status flipped. A genuine logout lands here
  #                        too and is NOT a defect (see update_location/1's
  #                        comment); this counter exists to show the rate and
  #                        catch spurious offline reports, not to be alerted on
  @tracking_stopped_event [:wanderer_app, :character, :tracking, :stopped]
  @tracking_permission_revoked_event [
    :wanderer_app,
    :character,
    :tracking,
    :permission_revoked
  ]
  @tracking_online_transition_event [
    :wanderer_app,
    :character,
    :tracking,
    :online_transition
  ]
  @token_refresh_failed_event [:wanderer_app, :token, :refresh_failed]

  # Named :tracker, not :tracking — one letter from the events above, and just
  # as capable of ending a character's location updates.
  #
  # Its sibling [:character, :tracker, :stopped] is NOT declared here: it is
  # already registered by character_event_metrics/0. Declaring it again would
  # collide on the metric name, and the registry resolves a collision by logging
  # a warning and skipping one of them.
  @tracker_untracked_from_map_event [
    :wanderer_app,
    :character,
    :tracker,
    :untracked_from_map
  ]

  # ESI-related events
  @esi_rate_limited_event [:wanderer_app, :esi, :rate_limited]
  @esi_error_event [:wanderer_app, :esi, :error]

  # JSON:API v1 related events
  @json_api_request_event [:wanderer_app, :json_api, :request]
  @json_api_response_event [:wanderer_app, :json_api, :response]
  @json_api_auth_event [:wanderer_app, :json_api, :auth]
  @json_api_error_event [:wanderer_app, :json_api, :error]

  @impl true
  def event_metrics(_opts) do
    base_metrics = [
      user_event_metrics(),
      map_event_metrics(),
      map_subscription_metrics(),
      # Registered as base metrics on purpose: this instrumentation exists to
      # catch rare, hard-to-reproduce defects, so it must not be switched off by
      # WANDERER_BASE_METRICS_ONLY.
      #
      # Most of these carry a :character_id tag (permission_revoked is the
      # exception — it reports a batch, so it is tagged by :map_id). That is a
      # deliberate reversal of the original "no tags" choice: an untagged
      # counter can say a freeze happened N times but never which character, and
      # every report these exist to serve names one pilot.
      #
      # Cardinality is roughly (characters x ~10), since online_transition and
      # token_refresh_failed each multiply by their own small tag sets. That is
      # fine at this deployment's size but is NOT free: series are never
      # reclaimed, so characters that have since been deleted keep their rows
      # for the life of the VM. Revisit if the character count grows by orders
      # of magnitude. online_transition in particular fires on every EVE login
      # and logout, so unlike the defect counters it is not rare.
      location_tracking_defect_metrics(),
      tracking_lifecycle_metrics()
    ]

    advanced_metrics = [
      character_event_metrics(),
      characters_distribution_event_metrics(),
      esi_event_metrics(),
      json_api_metrics()
    ]

    if WandererApp.Env.base_metrics_only() do
      base_metrics
    else
      base_metrics ++ advanced_metrics
    end
  end

  defp location_tracking_defect_metrics do
    Event.build(
      :wanderer_app_location_tracking_defect_metrics,
      [
        counter(
          @location_flag_cleared_event ++ [:count],
          event_name: @location_flag_cleared_event,
          description:
            "Times location tracking was cleared while the character was still online in EVE",
          tags: [:character_id],
          tag_values: &get_character_tag_values/1
        ),
        counter(
          @location_flag_repaired_event ++ [:count],
          event_name: @location_flag_repaired_event,
          description:
            "Times an online character's location tracking was restored on map re-entry, " <>
              "each of which would previously have frozen on the map",
          tags: [:character_id],
          tag_values: &get_character_tag_values/1
        ),
        counter(
          @location_skipped_while_active_event ++ [:count],
          event_name: @location_skipped_while_active_event,
          description:
            "Character-minutes during which an online, map-active character had location " <>
              "tracking disabled; expected to be zero",
          tags: [:character_id],
          tag_values: &get_character_tag_values/1
        )
      ]
    )
  end

  defp user_event_metrics do
    Event.build(
      :wanderer_app_user_event_metrics,
      [
        counter(
          @user_registered_event ++ [:count],
          event_name: @user_registered_event,
          description: "The number of users registered events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        ),
        counter(
          @user_character_registered_event ++ [:count],
          event_name: @user_character_registered_event,
          description: "The number of users character registered events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        )
      ]
    )
  end

  defp character_event_metrics do
    Event.build(
      :wanderer_app_character_event_metrics,
      [
        counter(
          @character_tracker_started_event ++ [:count],
          event_name: @character_tracker_started_event,
          description: "The number of character tracker started events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        ),
        # Tagged for the same reason as the tracking-lifecycle counters: this
        # event already carries character_id and reason (:garbage_collection),
        # and a tracker stopping is one of the ways a character silently stops
        # being polled.
        counter(
          @character_tracker_stopped_event ++ [:count],
          event_name: @character_tracker_stopped_event,
          description: "The number of character tracker stopped events that have occurred",
          tags: [:character_id, :reason],
          tag_values: &get_tracking_stopped_tag_values/1
        )
      ]
    )
  end

  defp map_event_metrics do
    Event.build(
      :wanderer_app_map_event_metrics,
      [
        counter(
          @map_created_event ++ [:count],
          event_name: @map_created_event,
          description: "The number of map created events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        ),
        counter(
          @map_started_event ++ [:count],
          event_name: @map_started_event,
          description: "The number of map started events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        ),
        counter(
          @map_stopped_event ++ [:count],
          event_name: @map_stopped_event,
          description: "The number of map stopped events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        ),
        counter(
          @map_character_added_event ++ [:count],
          event_name: @map_character_added_event,
          description: "The number of map character added events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        ),
        counter(
          @map_character_jump_event ++ [:count],
          event_name: @map_character_jump_event,
          description: "The number of map character jump events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        )
      ]
    )
  end

  defp map_subscription_metrics do
    Event.build(
      :wanderer_app_map_subscription_metrics,
      [
        counter(
          @map_subscription_new_event ++ [:count],
          event_name: @map_subscription_new_event,
          description: "The number of new map subscription events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        ),
        counter(
          @map_subscription_renew_event ++ [:count],
          event_name: @map_subscription_renew_event,
          description: "The number of map subscription renew events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        ),
        counter(
          @map_subscription_update_event ++ [:count],
          event_name: @map_subscription_update_event,
          description: "The number of map subscription update events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        ),
        counter(
          @map_subscription_cancel_event ++ [:count],
          event_name: @map_subscription_cancel_event,
          description:
            "The number of map character subscription cancel events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        ),
        counter(
          @map_subscription_expired_event ++ [:count],
          event_name: @map_subscription_expired_event,
          description:
            "The number of map character subscription expired events that have occurred",
          tags: [],
          tag_values: &get_empty_tag_values/1
        )
      ]
    )
  end

  defp characters_distribution_event_metrics do
    Event.build(
      :wanderer_app_characters_distribution_event_metrics,
      [
        distribution(
          @character_tracker_event ++ [:duration],
          event_name: @character_tracker_event,
          description: "The time spent in hours before disconnecting from the mapper.",
          reporter_options: [buckets: [1, 2, 4, 8, 16, 32]]
        )
      ]
    )
  end

  defp esi_event_metrics do
    Event.build(
      :wanderer_app_esi_event_metrics,
      [
        counter(
          @esi_rate_limited_event ++ [:count],
          event_name: @esi_rate_limited_event,
          description: "The number of ESI rate limiting incidents that have occurred",
          tags: [:endpoint, :method, :tracking_pool],
          tag_values: &get_esi_tag_values/1
        ),
        distribution(
          @esi_rate_limited_event ++ [:reset_duration],
          event_name: @esi_rate_limited_event,
          description: "ESI rate limit reset duration in milliseconds",
          tags: [:endpoint, :method, :tracking_pool],
          tag_values: &get_esi_tag_values/1,
          reporter_options: [buckets: [1000, 5000, 10000, 30000, 60000, 300_000]]
        ),
        counter(
          @esi_error_event ++ [:count],
          event_name: @esi_error_event,
          description: "The number of ESI API errors that have occurred",
          tags: [:endpoint, :error_type, :tracking_pool],
          tag_values: &get_esi_error_tag_values/1
        )
      ]
    )
  end

  defp get_esi_tag_values(metadata) do
    %{
      endpoint: Map.get(metadata, :endpoint, "unknown"),
      method: Map.get(metadata, :method, "unknown"),
      tracking_pool: Map.get(metadata, :tracking_pool, "unknown")
    }
  end

  defp get_esi_error_tag_values(metadata) do
    %{
      endpoint: Map.get(metadata, :endpoint, "unknown"),
      error_type: inspect(Map.get(metadata, :error_type, "unknown")),
      tracking_pool: Map.get(metadata, :tracking_pool, "default")
    }
  end

  defp tracking_lifecycle_metrics do
    Event.build(
      :wanderer_app_tracking_lifecycle_metrics,
      [
        counter(
          @tracking_stopped_event ++ [:count],
          event_name: @tracking_stopped_event,
          description:
            "Times tracking was stopped for a character on a map, tagged with the cause: " <>
              "presence_expired (browser gone past the grace period, not an EVE logout), " <>
              "permission_revoked (ACL sweep) or user_untracked (clicked in the UI)",
          tags: [:character_id, :reason],
          tag_values: &get_tracking_stopped_tag_values/1
        ),
        # sum/2, not counter/2: this event fires once per batch and carries the
        # batch size in its :count measurement. A counter ignores measurements
        # entirely, so an ACL sweep removing 40 characters would increment it by
        # 1 — and this metric is meant to be read against :stopped, which fires
        # 40 times for that same sweep.
        sum(
          @tracking_permission_revoked_event ++ [:count],
          event_name: @tracking_permission_revoked_event,
          measurement: :count,
          description:
            "Characters removed from a map by the ACL permission check, which untracks them " <>
              "in the database with no grace period",
          tags: [:map_id, :reason],
          tag_values: &get_permission_revoked_tag_values/1
        ),
        counter(
          @tracking_online_transition_event ++ [:count],
          event_name: @tracking_online_transition_event,
          description:
            "Times EVE online status flipped for a character, rewriting track_location. " <>
              "online=false with active maps is a silent pause in location updates",
          tags: [:character_id, :online, :has_active_maps],
          tag_values: &get_online_transition_tag_values/1
        ),
        counter(
          @token_refresh_failed_event ++ [:count],
          event_name: @token_refresh_failed_event,
          description:
            "ESI token refresh failures. Three consecutive invalid_grant results wipe the " <>
              "token, after which every poll for that character skips silently",
          tags: [:character_id, :error_type],
          tag_values: &get_token_refresh_tag_values/1
        ),
        counter(
          @tracker_untracked_from_map_event ++ [:count],
          event_name: @tracker_untracked_from_map_event,
          description:
            "Characters untracked from a map by the tracker manager's delayed untrack queue",
          tags: [:character_id, :reason],
          tag_values: &get_tracking_stopped_tag_values/1
        )
      ]
    )
  end

  defp get_character_tag_values(metadata) do
    %{character_id: Map.get(metadata, :character_id, "unknown")}
  end

  defp get_tracking_stopped_tag_values(metadata) do
    %{
      character_id: Map.get(metadata, :character_id, "unknown"),
      reason: Map.get(metadata, :reason, "unknown")
    }
  end

  # Tagged by map rather than character: this event reports a batch removal and
  # carries :character_ids (a list), so there is no single character to name.
  #
  # `reason` is inspected here but passed through raw for :stopped. That is not
  # an oversight: :stopped emits a plain atom, while this event's reason reaches
  # permission_removal_reason_to_string/1's catch-all clause, which exists
  # precisely because the value is not guaranteed to be an atom.
  defp get_permission_revoked_tag_values(metadata) do
    %{
      map_id: Map.get(metadata, :map_id, "unknown"),
      reason: inspect(Map.get(metadata, :reason, "unknown"))
    }
  end

  defp get_online_transition_tag_values(metadata) do
    %{
      character_id: Map.get(metadata, :character_id, "unknown"),
      online: Map.get(metadata, :online, "unknown"),
      has_active_maps: Map.get(metadata, :has_active_maps, "unknown")
    }
  end

  defp get_token_refresh_tag_values(metadata) do
    %{
      character_id: Map.get(metadata, :character_id, "unknown"),
      error_type: Map.get(metadata, :error_type, "unknown")
    }
  end

  defp get_empty_tag_values(_) do
    %{}
  end

  defp json_api_metrics do
    Event.build(
      :wanderer_app_json_api_metrics,
      [
        # Request metrics
        counter(
          @json_api_request_event ++ [:count],
          event_name: @json_api_request_event,
          description: "The number of JSON:API v1 requests that have occurred",
          tags: [:resource, :action, :method],
          tag_values: &get_json_api_request_tag_values/1
        ),
        distribution(
          @json_api_request_event ++ [:duration],
          event_name: @json_api_request_event,
          description: "The time spent processing JSON:API v1 requests in milliseconds",
          tags: [:resource, :action, :method],
          tag_values: &get_json_api_request_tag_values/1,
          reporter_options: [buckets: [50, 100, 200, 500, 1000, 2000, 5000, 10000]]
        ),
        distribution(
          @json_api_request_event ++ [:payload_size],
          event_name: @json_api_request_event,
          description: "The size of JSON:API v1 request payloads in bytes",
          tags: [:resource, :action, :method],
          tag_values: &get_json_api_request_tag_values/1,
          reporter_options: [buckets: [1024, 10240, 51200, 102_400, 512_000, 1_048_576]]
        ),

        # Response metrics
        counter(
          @json_api_response_event ++ [:count],
          event_name: @json_api_response_event,
          description: "The number of JSON:API v1 responses that have occurred",
          tags: [:resource, :action, :method, :status_code],
          tag_values: &get_json_api_response_tag_values/1
        ),
        distribution(
          @json_api_response_event ++ [:payload_size],
          event_name: @json_api_response_event,
          description: "The size of JSON:API v1 response payloads in bytes",
          tags: [:resource, :action, :method, :status_code],
          tag_values: &get_json_api_response_tag_values/1,
          reporter_options: [buckets: [1024, 10240, 51200, 102_400, 512_000, 1_048_576]]
        ),

        # Authentication metrics
        counter(
          @json_api_auth_event ++ [:count],
          event_name: @json_api_auth_event,
          description: "The number of JSON:API v1 authentication events that have occurred",
          tags: [:auth_type, :result],
          tag_values: &get_json_api_auth_tag_values/1
        ),
        distribution(
          @json_api_auth_event ++ [:duration],
          event_name: @json_api_auth_event,
          description: "The time spent on JSON:API v1 authentication in milliseconds",
          tags: [:auth_type, :result],
          tag_values: &get_json_api_auth_tag_values/1,
          reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000]]
        ),

        # Error metrics
        counter(
          @json_api_error_event ++ [:count],
          event_name: @json_api_error_event,
          description: "The number of JSON:API v1 errors that have occurred",
          tags: [:resource, :error_type, :status_code],
          tag_values: &get_json_api_error_tag_values/1
        )
      ]
    )
  end

  defp get_json_api_request_tag_values(metadata) do
    %{
      resource: Map.get(metadata, :resource, "unknown"),
      action: Map.get(metadata, :action, "unknown"),
      method: Map.get(metadata, :method, "unknown")
    }
  end

  defp get_json_api_response_tag_values(metadata) do
    %{
      resource: Map.get(metadata, :resource, "unknown"),
      action: Map.get(metadata, :action, "unknown"),
      method: Map.get(metadata, :method, "unknown"),
      status_code: to_string(Map.get(metadata, :status_code, "unknown"))
    }
  end

  defp get_json_api_auth_tag_values(metadata) do
    %{
      auth_type: Map.get(metadata, :auth_type, "unknown"),
      result: Map.get(metadata, :result, "unknown")
    }
  end

  defp get_json_api_error_tag_values(metadata) do
    %{
      resource: Map.get(metadata, :resource, "unknown"),
      error_type: to_string(Map.get(metadata, :error_type, "unknown")),
      status_code: to_string(Map.get(metadata, :status_code, "unknown"))
    }
  end
end
