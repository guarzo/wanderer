defmodule WandererApp.Repositories.MapCharacterSettingsRepoUntrackTest do
  @moduledoc """
  Covers the provenance instrumentation on `MapCharacterSettingsRepo.untrack/1`.

  Users report their tracking box unchecking itself while none of the three
  known callers — the UI toggle, the ACL permission sweep, and character
  deletion — appears responsible. Every one of them funnels through
  `untrack/1`, so it is the single point that can observe an uncheck regardless
  of which path caused it, and the `:source` tag is what turns the count into a
  diagnosis.

  The transition guard matters as much as the emit: a repeat untrack of an
  already-untracked character changes nothing, and counting it would inflate the
  metric against the reports it exists to explain.
  """

  use WandererApp.DataCase, async: false

  alias WandererApp.MapCharacterSettingsRepo

  @event [:wanderer_app, :map, :character_settings, :untracked]

  setup do
    handler_id = "untrack-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @event,
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "untrack/1 instrumentation" do
    test "emits when a tracked character is unchecked" do
      %{map_id: map_id, character_id: character_id} = tracked_settings()

      {:ok, _} = MapCharacterSettingsRepo.untrack(%{map_id: map_id, character_id: character_id})

      assert_receive {:telemetry, %{count: 1},
                      %{character_id: ^character_id, map_id: ^map_id, source: source}}

      # Called directly from a test process, so no known caller module appears in
      # the stack. :unknown is the honest answer and is exactly the value that
      # should prompt a look at the accompanying log line.
      assert source == :unknown
    end

    test "does not emit when the character was already untracked" do
      %{map_id: map_id, character_id: character_id} = tracked_settings()

      {:ok, _} = MapCharacterSettingsRepo.untrack(%{map_id: map_id, character_id: character_id})
      assert_receive {:telemetry, _, _}

      {:ok, _} = MapCharacterSettingsRepo.untrack(%{map_id: map_id, character_id: character_id})

      refute_receive {:telemetry, _, _}, 200
    end

    test "leaves the character untracked" do
      %{map_id: map_id, character_id: character_id} = tracked_settings()

      {:ok, updated} =
        MapCharacterSettingsRepo.untrack(%{map_id: map_id, character_id: character_id})

      assert updated.tracked == false
    end
  end

  describe "update/3 cannot bypass the instrumentation" do
    test "reports an uncheck made through the generic update path" do
      %{map_id: map_id, character_id: character_id} = tracked_settings()

      {:ok, _} = MapCharacterSettingsRepo.update(map_id, character_id, %{tracked: false})

      assert_receive {:telemetry, %{count: 1}, %{character_id: ^character_id, map_id: ^map_id}}
    end

    test "does not report when the update leaves tracking alone" do
      %{map_id: map_id, character_id: character_id} = tracked_settings()

      {:ok, _} = MapCharacterSettingsRepo.update(map_id, character_id, %{ship_name: "Loki"})

      refute_receive {:telemetry, _, _}, 200
    end

    test "does not report when the update sets tracking on" do
      %{map_id: map_id, character_id: character_id} = tracked_settings()

      {:ok, _} = MapCharacterSettingsRepo.update(map_id, character_id, %{tracked: true})

      refute_receive {:telemetry, _, _}, 200
    end
  end

  defp tracked_settings do
    map = WandererAppWeb.Factory.insert(:map, %{})
    character = WandererAppWeb.Factory.insert(:character, %{})

    {:ok, _settings} =
      WandererApp.Api.MapCharacterSettings.create(%{
        map_id: map.id,
        character_id: character.id,
        tracked: true
      })

    %{map_id: map.id, character_id: character.id}
  end
end
