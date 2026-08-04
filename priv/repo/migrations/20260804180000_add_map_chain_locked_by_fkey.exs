defmodule WandererApp.Repo.Migrations.AddMapChainLockedByFkey do
  @moduledoc ~S"""
  Creates the `map_chain_v1_locked_by_id_fkey` constraint that
  `MapConnection`'s `belongs_to :locked_by` has always implied but no database
  has ever had.

  `20260425000000_add_map_connection_locked_by.exs` added `locked_by_id` as a
  bare `:binary_id` with no `references(...)`, so the column has been an
  unenforced pointer since it was introduced. The resource snapshot declares
  the constraint, which means every future `mix ash.codegen` run treats the
  gap as already closed and will never re-surface it.

  Backfill is a no-op by construction: connection locking writes
  `locked_by_id` only to the `map_#{map_id}:conn_#{id}:locked_info` cache entry
  (`map_server_connections_impl.ex`), never to this column, so every row's
  value is NULL. The migration is still written to fail loudly rather than
  silently skip if that assumption is ever wrong on a deployment.

  `on_delete` is deliberately unset, matching the resource: destroying a
  Character that holds a lock should raise rather than silently drop the
  reference or the connection.
  """
  use Ecto.Migration

  def up do
    alter table(:map_chain_v1) do
      modify :locked_by_id,
             references(:character_v1,
               column: :id,
               name: "map_chain_v1_locked_by_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end
  end

  def down do
    drop constraint(:map_chain_v1, "map_chain_v1_locked_by_id_fkey")

    alter table(:map_chain_v1) do
      modify :locked_by_id, :uuid
    end
  end
end
