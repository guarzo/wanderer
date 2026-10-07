defmodule WandererApp.Repo.Migrations.HandLockedByFkeyToUpstream do
  @moduledoc """
  Zoo-only shim: drops `map_chain_v1_locked_by_id_fkey` so upstream's
  `20260808152615_add_map_connection_locked_by_fk.exs` can create it.

  Zoo added this constraint first, in `20260804180000_add_map_chain_locked_by_fkey.exs`.
  Upstream later shipped its own migration for the same constraint, which uses a
  plain `modify ... references(...)` and so fails with `duplicate_object` on any
  database where the zoo migration already ran -- production included. The zoo
  migration has already run there, so editing it cannot help; dropping the
  constraint here, timestamped just before upstream's, lets upstream's migration
  run unmodified on both existing and fresh databases.

  The column and its data are untouched; only the constraint is briefly absent
  between this migration and the next.
  """

  use Ecto.Migration

  def up do
    drop_if_exists constraint(:map_chain_v1, "map_chain_v1_locked_by_id_fkey")
  end

  # Upstream's migration rolls back first (it is later) and drops the
  # constraint; restoring it here returns the schema to the state left by the
  # zoo migration, which deliberately leaves `on_delete` unset.
  def down do
    alter table(:map_chain_v1) do
      modify :locked_by_id,
             references(:character_v1,
               column: :id,
               name: "map_chain_v1_locked_by_id_fkey",
               type: :uuid
             )
    end
  end
end
