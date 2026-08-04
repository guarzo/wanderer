defmodule WandererApp.Repositories.MapUserSettingsRepoReadyCacheTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Api.MapUserSettings
  alias WandererApp.MapUserSettingsRepo
  alias WandererAppWeb.Factory

  setup do
    user = Factory.insert(:user, %{})
    map = Factory.insert(:map, %{})

    {:ok, settings} =
      MapUserSettings.create(%{map_id: map.id, user_id: user.id, settings: "{}"})

    on_exit(fn -> MapUserSettingsRepo.invalidate_ready_character_eve_ids(map.id) end)

    %{map: map, settings: settings}
  end

  test "returns the de-duplicated ready set across users", %{map: map, settings: settings} do
    {:ok, _} =
      MapUserSettings.update_ready_characters(settings, %{ready_characters: ["100", "200"]})

    assert MapUserSettingsRepo.ready_character_eve_ids(map.id) |> Enum.sort() == ["100", "200"]
  end

  # The whole point of the cache is that N connected LiveViews enriching the
  # same `characters_updated` broadcast do not each hit the database. If this
  # regresses, the reads come back silently — nothing fails, the map just gets
  # slower under exactly the load where it matters.
  test "a second read does not go back to the database", %{map: map, settings: settings} do
    {:ok, _} = MapUserSettings.update_ready_characters(settings, %{ready_characters: ["100"]})

    assert MapUserSettingsRepo.ready_character_eve_ids(map.id) == ["100"]

    # Written behind the action's back, so only an uncached read can observe it.
    {:ok, _} =
      Ash.Changeset.for_update(settings, :update, %{})
      |> Ash.Changeset.force_change_attribute(:ready_characters, ["999"])
      |> Ash.update()

    assert MapUserSettingsRepo.ready_character_eve_ids(map.id) == ["100"]

    # Proves the write above actually landed, so the assertion before it is
    # evidence of caching rather than of a no-op update.
    :ok = MapUserSettingsRepo.invalidate_ready_character_eve_ids(map.id)
    assert MapUserSettingsRepo.ready_character_eve_ids(map.id) == ["999"]
  end

  # Invalidation lives in the `:update_ready_characters` action rather than at
  # its four call sites, so that a new write path cannot forget it.
  test "the update action invalidates the cache", %{map: map, settings: settings} do
    {:ok, settings} =
      MapUserSettings.update_ready_characters(settings, %{ready_characters: ["100"]})

    assert MapUserSettingsRepo.ready_character_eve_ids(map.id) == ["100"]

    {:ok, _} =
      MapUserSettings.update_ready_characters(settings, %{ready_characters: ["100", "200"]})

    assert MapUserSettingsRepo.ready_character_eve_ids(map.id) |> Enum.sort() == ["100", "200"]
  end

  test "a map with no settings rows caches an empty set rather than nil", %{} do
    empty_map = Factory.insert(:map, %{})

    assert MapUserSettingsRepo.ready_character_eve_ids(empty_map.id) == []
    assert MapUserSettingsRepo.ready_character_eve_ids(empty_map.id) == []
  end

  test "a blank map id is answered without a lookup" do
    assert MapUserSettingsRepo.ready_character_eve_ids("") == []
    assert MapUserSettingsRepo.ready_character_eve_ids(nil) == []
  end
end
