defmodule WandererApp.Api.MapScopesDefaultTest do
  use WandererApp.DataCase, async: false

  alias WandererApp.Repo
  alias WandererAppWeb.Factory

  # `Api.Map` supplies `default([:wormholes])`, so anything written through Ash
  # never reads the column default. Inserts that bypass Ash do - and one of
  # them, `SlugRecoveryTest`'s `insert_map_directly/4`, failed for months
  # because of it: `20260331192521` and `20260406213852` both set the default
  # with the charlist `~c"{wormholes}"`, which Postgres stored as the eleven
  # code points of the string. Reading such a row back through Ash blew up
  # casting `'123'` into the `{:array, :atom}` `one_of` constraint, and
  # `get_map_by_slug_safely/1` surfaced it as `{:error, :unknown_error}`.
  test "a map inserted without scopes gets [:wormholes], not the charlist code points" do
    owner = Factory.insert(:character, %{})

    {:ok, result} =
      Repo.query(
        """
        INSERT INTO maps_v1 (id, slug, name, owner_id, deleted, scope, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, $3, false, 'wormholes', NOW(), NOW())
        RETURNING id
        """,
        ["scopes-default-test", "Scopes Default", Ecto.UUID.dump!(owner.id)]
      )

    [[id]] = result.rows

    assert {:ok, map} = WandererApp.Api.Map.by_id(Ecto.UUID.load!(id))
    assert map.scopes == [:wormholes]
  end
end
