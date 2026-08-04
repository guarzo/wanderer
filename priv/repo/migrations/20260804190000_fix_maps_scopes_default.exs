defmodule WandererApp.Repo.Migrations.FixMapsScopesDefault do
  @moduledoc ~S"""
  Repairs the `maps_v1.scopes` column default.

  `20260331192521_add_mass_to_map_chain_passages.exs` and
  `20260406213852_add_character_description.exs` both carry

      modify :scopes, {:array, :text}, default: ~c"{wormholes}"

  `~c"{wormholes}"` is a charlist, so Ecto rendered it as a list of code
  points. The resulting default is

      ARRAY['123','119','111','114','109','104','111','108','101','115','125']

  — the characters of `{wormholes}` as eleven separate array elements — where
  the resource's `migration_defaults scopes: "'{wormholes}'"` (api/map.ex:17)
  and the snapshot both intend the single-element array `{wormholes}`.

  Reachability is narrow but real: `Api.Map` declares `default([:wormholes])`,
  so every map written through Ash supplies `scopes` explicitly and never sees
  the column default. Any insert that does not — raw SQL, a seed, a manual
  `INSERT` during an incident — gets a map whose scopes are eleven junk atoms,
  and `scopes` drives connection validity.

  The two source migrations are left untouched. They are already applied
  everywhere, so editing them would fix nothing that this migration does not
  fix, while breaking the rule that applied migrations are immutable history.
  """
  use Ecto.Migration

  def up do
    execute("ALTER TABLE maps_v1 ALTER COLUMN scopes SET DEFAULT '{wormholes}'")
  end

  # Deliberately restores the mangled default rather than dropping it: `down`
  # must reproduce the state this migration found, not an improved one.
  def down do
    execute(
      "ALTER TABLE maps_v1 ALTER COLUMN scopes SET DEFAULT " <>
        "ARRAY['123','119','111','114','109','104','111','108','101','115','125']::text[]"
    )
  end
end
