defmodule WandererApp.ExternalEvents.Discord.MatcherTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.ExternalEvents.Discord.Matcher

  setup do
    map = WandererAppWeb.Factory.insert(:map, %{})
    Matcher.invalidate_tracked(map.id)
    on_exit(fn -> Matcher.invalidate_tracked(map.id) end)
    %{map: map}
  end

  describe "tracked_eve_ids/1" do
    test "returns a MapSet of INTEGER eve ids, not strings", %{map: map} do
      start_map_with_characters(map, ["95465499", "91000001"])

      ids = Matcher.tracked_eve_ids(map.id)

      assert %MapSet{} = ids
      assert MapSet.member?(ids, 95_465_499)
      assert MapSet.member?(ids, 91_000_001)

      # The whole point of this task: a string-keyed set would satisfy the
      # `member?` calls above only if the caller also passed strings, which it
      # never does. Assert the element type directly.
      assert Enum.all?(ids, &is_integer/1)
      refute MapSet.member?(ids, "95465499")
    end

    test "a character whose eve_id is a numeric string is found by integer id", %{map: map} do
      start_map_with_characters(map, ["2117994022"])

      assert MapSet.member?(Matcher.tracked_eve_ids(map.id), 2_117_994_022)
    end

    test "returns an empty MapSet for a map that is not running" do
      unknown_map_id = Ecto.UUID.generate()

      assert Matcher.tracked_eve_ids(unknown_map_id) == MapSet.new()
    end

    test "does not cache the empty result of a failed lookup" do
      unknown_map_id = Ecto.UUID.generate()

      assert Matcher.tracked_eve_ids(unknown_map_id) == MapSet.new()

      assert {:ok, nil} =
               Cachex.get(:discord_notification_cache, "map:#{unknown_map_id}:tracked_eve_ids")
    end
  end

  describe "invalidation" do
    test "add_character/2 invalidates the cached set", %{map: map} do
      start_map_with_characters(map, ["95465499"])
      assert MapSet.size(Matcher.tracked_eve_ids(map.id)) == 1

      {:ok, newcomer} =
        WandererApp.Api.Character.create(%{eve_id: "91000005", name: "Newcomer"})

      WandererApp.Map.add_character(map.id, newcomer)

      ids = Matcher.tracked_eve_ids(map.id)
      assert MapSet.member?(ids, 91_000_005)
      assert MapSet.size(ids) == 2
    end

    test "remove_character/2 invalidates the cached set", %{map: map} do
      [first | _] = start_map_with_characters(map, ["95465499", "91000001"])
      assert MapSet.size(Matcher.tracked_eve_ids(map.id)) == 2

      WandererApp.Map.remove_character(map.id, first.id)

      ids = Matcher.tracked_eve_ids(map.id)
      refute MapSet.member?(ids, 95_465_499)
      assert MapSet.size(ids) == 1
    end

    test "add_characters!/2 (the bulk startup path) invalidates the cached set", %{map: map} do
      start_map_with_characters(map, ["95465499"])
      # Warm the cache so a missing invalidation is observable.
      assert MapSet.size(Matcher.tracked_eve_ids(map.id)) == 1

      {:ok, bulk_one} =
        WandererApp.Api.Character.create(%{eve_id: "91000006", name: "Bulk One"})

      {:ok, bulk_two} =
        WandererApp.Api.Character.create(%{eve_id: "91000007", name: "Bulk Two"})

      map.id
      |> WandererApp.Map.get_map!()
      |> WandererApp.Map.add_characters!([
        %{character_id: bulk_one.id},
        %{character_id: bulk_two.id}
      ])

      ids = Matcher.tracked_eve_ids(map.id)
      assert MapSet.member?(ids, 91_000_006)
      assert MapSet.member?(ids, 91_000_007)
    end

    test "invalidate_tracked/1 is idempotent and safe on a cold cache", %{map: map} do
      assert Matcher.invalidate_tracked(map.id) == :ok
      assert Matcher.invalidate_tracked(map.id) == :ok
    end
  end

  # Seeds the in-memory map cache entry that `WandererApp.Map`'s cache-backed
  # functions (`get_map!/1`, `update_map/2`, `list_characters/1`) read and
  # write directly — there is no map GenServer to start; `add_character/2`,
  # `remove_character/2` and `add_characters!/2` all operate on `:map_cache`
  # via `Cachex.get_and_update/3`, not via a process call. Characters are then
  # registered via the same public writer production uses, so the test
  # exercises the real invalidation path.
  defp start_map_with_characters(map, eve_ids) do
    Cachex.put(:map_cache, map.id, %{map_id: map.id, characters: []})

    characters =
      Enum.map(eve_ids, fn eve_id ->
        {:ok, character} =
          WandererApp.Api.Character.create(%{
            eve_id: eve_id,
            name: "Pilot #{eve_id}"
          })

        WandererApp.Map.add_character(map.id, character)
        character
      end)

    Matcher.invalidate_tracked(map.id)
    characters
  end
end
