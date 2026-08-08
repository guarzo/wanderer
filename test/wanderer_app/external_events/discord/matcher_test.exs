defmodule WandererApp.ExternalEvents.Discord.MatcherTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.ExternalEvents.Discord.Matcher

  setup do
    map = WandererAppWeb.Factory.insert(:map, %{})
    Matcher.invalidate_tracked(map.id)

    on_exit(fn ->
      Matcher.invalidate_tracked(map.id)
      Cachex.del(:map_cache, map.id)
    end)

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

    test "an unresolvable character id costs one pilot, not the whole map's set", %{map: map} do
      start_map_with_characters(map, ["95465499"])

      # Simulate a stale id in `map.characters` whose backing character
      # record no longer resolves (`get_map_character!/2` logs and returns
      # `nil` for it rather than raising).
      Cachex.get_and_update(:map_cache, map.id, fn stored_map ->
        {:commit, Map.update!(stored_map, :characters, &[Ecto.UUID.generate() | &1])}
      end)

      Matcher.invalidate_tracked(map.id)

      ids = Matcher.tracked_eve_ids(map.id)
      assert MapSet.member?(ids, 95_465_499)
      assert MapSet.size(ids) == 1
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

    # The race the version stamp exists to close, driven deterministically: a
    # build reads the tracked set, an `invalidate_tracked/1` lands while that
    # build is still in flight, and the build then tries to write. Before the
    # version check, that write put the PRE-delete set back and the stale entry
    # survived the full five-minute TTL — an invalidation that silently did
    # nothing, which is the worst possible outcome for a routing cache.
    test "an invalidation during a build is not undone by that build's write", %{map: map} do
      stale = MapSet.new([95_465_499])

      build_fun = fn _map_id ->
        # Lands after the version read, before the write. Exactly the window.
        Matcher.invalidate_tracked(map.id)
        {:ok, stale}
      end

      # The caller still gets the set — it was current when the build began,
      # and this killmail has to route somewhere.
      assert Matcher.build_and_cache(map.id, build_fun) == stale

      # But it must NOT be readable afterwards: the next killmail rebuilds.
      assert {:ok, nil} =
               Cachex.get(:discord_notification_cache, "map:#{map.id}:tracked_eve_ids")
    end

    # The control for the test above. If `cache_put/3` rejected every write,
    # that test would pass while the cache never worked at all.
    test "an uninterrupted build does write its set back", %{map: map} do
      fresh = MapSet.new([95_465_499])

      assert Matcher.build_and_cache(map.id, fn _ -> {:ok, fresh} end) == fresh

      assert {:ok, ^fresh} =
               Cachex.get(:discord_notification_cache, "map:#{map.id}:tracked_eve_ids")
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
