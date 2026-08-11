defmodule WandererApp.Character.TrackerUpdateSettingsTest do
  @moduledoc """
  Regression tests for `WandererApp.Character.Tracker.update_settings/2`.

  Production incident: characters were present on a map with `tracked: true` in
  the database, yet the map never updated as they moved through systems.

  Root cause: `TrackingUtils.track_character/4` starts map tracking by calling
  `update_track_settings(character_id, %{map_id: map_id, track: true})`. That
  settings map carries no `track_location` key, so `maybe_start_location_tracking/2`
  never matched and `track_location` stayed `false`. `update_location/1` only
  matches `%{track_location: true, is_online: true}`, so location polling was
  silently skipped for the character's entire session.

  The only other writer of `track_location` is `update_online/1`, which is gated
  on an online-status *transition*. A character already online when map tracking
  begins never produces that transition, so the flag stayed `false` indefinitely.
  """

  use ExUnit.Case, async: false

  alias WandererApp.Character.Tracker

  setup do
    character_id = "test-char-#{System.unique_integer([:positive])}"
    map_id = "test-map-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Cachex.del(:character_state_cache, character_id)
      WandererApp.Cache.delete("character:#{character_id}:map:#{map_id}:tracking_start_time")
    end)

    %{character_id: character_id, map_id: map_id}
  end

  defp seed_state(character_id, overrides) do
    state =
      Tracker.new(%{character_id: character_id})
      |> Map.merge(overrides)

    Cachex.put(:character_state_cache, character_id, state)
    state
  end

  describe "update_settings/2 when map tracking starts" do
    test "enables location tracking for a character who is already online", %{
      character_id: character_id,
      map_id: map_id
    } do
      # Exact state observed in production: the character is online in EVE and
      # online tracking is active, but location tracking was previously cleared
      # by maybe_stop_tracking/2 when they left all maps.
      seed_state(character_id, %{
        is_online: true,
        track_online: true,
        track_location: false,
        track_ship: false,
        active_maps: []
      })

      {:ok, state} = Tracker.update_settings(character_id, %{map_id: map_id, track: true})

      assert map_id in state.active_maps,
             "map should be registered as active"

      assert state.track_location,
             """
             track_location must be enabled when map tracking starts.

             While false, update_location/1 falls through to its catch-all clause
             and returns {:error, :skipped} silently, so the character's location
             is never fetched from ESI and the map never updates as they move.
             """
    end

    test "enables ship tracking for a character who is already online", %{
      character_id: character_id,
      map_id: map_id
    } do
      seed_state(character_id, %{
        is_online: true,
        track_online: true,
        track_location: false,
        track_ship: false,
        active_maps: []
      })

      {:ok, state} = Tracker.update_settings(character_id, %{map_id: map_id, track: true})

      assert state.track_ship,
             "track_ship must be enabled when map tracking starts, for the same reason"
    end

    test "enables location tracking even when the character is currently offline", %{
      character_id: character_id,
      map_id: map_id
    } do
      # track_location is an intent flag, not a liveness flag. update_location/1
      # independently requires is_online: true, so setting it while offline is
      # safe and avoids depending on an online transition that may never come.
      seed_state(character_id, %{
        is_online: false,
        track_online: true,
        track_location: false,
        track_ship: false,
        active_maps: []
      })

      {:ok, state} = Tracker.update_settings(character_id, %{map_id: map_id, track: true})

      assert state.track_location
    end

    test "is idempotent when tracking is already active for the map", %{
      character_id: character_id,
      map_id: map_id
    } do
      seed_state(character_id, %{
        is_online: true,
        track_online: true,
        track_location: true,
        track_ship: true,
        active_maps: [map_id]
      })

      {:ok, state} = Tracker.update_settings(character_id, %{map_id: map_id, track: true})

      assert state.track_location
      assert state.track_ship
      assert state.active_maps == [map_id], "map should not be duplicated in active_maps"
    end
  end

  describe "update_settings/2 when map tracking stops" do
    test "clears location and ship tracking once no maps remain active", %{
      character_id: character_id,
      map_id: map_id
    } do
      seed_state(character_id, %{
        is_online: true,
        track_online: true,
        track_location: true,
        track_ship: true,
        active_maps: [map_id]
      })

      {:ok, state} = Tracker.update_settings(character_id, %{map_id: map_id, track: false})

      refute state.track_location
      refute state.track_ship
    end
  end

  describe "update_location/1 diagnostics" do
    test "warns when an online character on a map has location tracking disabled", %{
      character_id: character_id,
      map_id: map_id
    } do
      on_exit(fn ->
        WandererApp.Cache.delete("character:#{character_id}:location_skip_logged")
      end)

      state =
        Tracker.new(%{character_id: character_id})
        |> Map.merge(%{
          is_online: true,
          track_location: false,
          active_maps: [map_id]
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :skipped} = Tracker.update_location(state)
        end)

      assert log =~ "update_location skipped for online character #{character_id}"
      assert log =~ "track_location=false"
    end

    test "does not warn for an offline character, which is expected", %{
      character_id: character_id,
      map_id: map_id
    } do
      state =
        Tracker.new(%{character_id: character_id})
        |> Map.merge(%{
          is_online: false,
          track_location: false,
          active_maps: [map_id]
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :skipped} = Tracker.update_location(state)
        end)

      refute log =~ "update_location skipped"
    end

    test "throttles the warning to once per character", %{
      character_id: character_id,
      map_id: map_id
    } do
      on_exit(fn ->
        WandererApp.Cache.delete("character:#{character_id}:location_skip_logged")
      end)

      state =
        Tracker.new(%{character_id: character_id})
        |> Map.merge(%{
          is_online: true,
          track_location: false,
          active_maps: [map_id]
        })

      ExUnit.CaptureLog.capture_log(fn -> Tracker.update_location(state) end)

      # update_location/1 runs on a per-second tick; an unthrottled warning here
      # would bury the log it is meant to make visible.
      second_log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :skipped} = Tracker.update_location(state)
        end)

      refute second_log =~ "update_location skipped"
    end
  end

  describe "defect instrumentation" do
    setup %{character_id: character_id} do
      events = [
        [:wanderer_app, :character, :tracking, :location_flag_cleared],
        [:wanderer_app, :character, :tracking, :location_flag_repaired],
        [:wanderer_app, :character, :tracking, :location_skipped_while_active]
      ]

      handler_id = "test-handler-#{character_id}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits :location_flag_repaired only for a character who would have frozen", %{
      character_id: character_id,
      map_id: map_id
    } do
      seed_state(character_id, %{
        is_online: true,
        track_location: false,
        active_maps: []
      })

      {:ok, _state} = Tracker.update_settings(character_id, %{map_id: map_id, track: true})

      assert_receive {:telemetry, [:wanderer_app, :character, :tracking, :location_flag_repaired],
                      %{count: 1}, %{character_id: ^character_id}}
    end

    test "does not emit :location_flag_repaired on a normal fresh-tracker start", %{
      character_id: character_id,
      map_id: map_id
    } do
      # A new tracker defaults to is_online: false and picks up location tracking
      # via update_online/1's transition. That is the ordinary path, not a repair,
      # and counting it would drown the signal this metric exists to carry.
      seed_state(character_id, %{
        is_online: false,
        track_location: false,
        active_maps: []
      })

      {:ok, _state} = Tracker.update_settings(character_id, %{map_id: map_id, track: true})

      refute_receive {:telemetry, [:wanderer_app, :character, :tracking, :location_flag_repaired],
                      _, _}
    end

    test "does not emit :location_flag_repaired when tracking is already healthy", %{
      character_id: character_id,
      map_id: map_id
    } do
      seed_state(character_id, %{
        is_online: true,
        track_location: true,
        active_maps: [map_id]
      })

      {:ok, _state} = Tracker.update_settings(character_id, %{map_id: map_id, track: true})

      refute_receive {:telemetry, [:wanderer_app, :character, :tracking, :location_flag_repaired],
                      _, _}
    end

    test "emits :location_flag_cleared when an online character leaves their last map", %{
      character_id: character_id,
      map_id: map_id
    } do
      seed_state(character_id, %{
        is_online: true,
        track_location: true,
        active_maps: [map_id]
      })

      {:ok, _state} = Tracker.update_settings(character_id, %{map_id: map_id, track: false})

      assert_receive {:telemetry, [:wanderer_app, :character, :tracking, :location_flag_cleared],
                      %{count: 1}, %{character_id: ^character_id}}
    end

    test "does not emit :location_flag_cleared for an offline character", %{
      character_id: character_id,
      map_id: map_id
    } do
      # An offline character's cleared flag is restored by update_online/1 on the
      # next online transition, so it never becomes the stuck pair.
      seed_state(character_id, %{
        is_online: false,
        track_location: true,
        active_maps: [map_id]
      })

      {:ok, _state} = Tracker.update_settings(character_id, %{map_id: map_id, track: false})

      refute_receive {:telemetry, [:wanderer_app, :character, :tracking, :location_flag_cleared],
                      _, _}
    end

    test "does not emit :location_flag_cleared when the flag was already false", %{
      character_id: character_id,
      map_id: map_id
    } do
      # A repeat untrack clears nothing. Counting it would measure calls to
      # maybe_stop_tracking/2 rather than transitions into the stuck state, and
      # inflate this metric against :location_flag_repaired.
      seed_state(character_id, %{
        is_online: true,
        track_location: false,
        active_maps: []
      })

      {:ok, _state} = Tracker.update_settings(character_id, %{map_id: map_id, track: false})

      refute_receive {:telemetry, [:wanderer_app, :character, :tracking, :location_flag_cleared],
                      _, _}
    end

    test "emits :location_skipped_while_active alongside the stuck-state warning", %{
      character_id: character_id,
      map_id: map_id
    } do
      on_exit(fn ->
        WandererApp.Cache.delete("character:#{character_id}:location_skip_logged")
      end)

      state =
        Tracker.new(%{character_id: character_id})
        |> Map.merge(%{is_online: true, track_location: false, active_maps: [map_id]})

      ExUnit.CaptureLog.capture_log(fn -> Tracker.update_location(state) end)

      assert_receive {:telemetry,
                      [:wanderer_app, :character, :tracking, :location_skipped_while_active],
                      %{count: 1}, %{character_id: ^character_id}}
    end
  end
end
