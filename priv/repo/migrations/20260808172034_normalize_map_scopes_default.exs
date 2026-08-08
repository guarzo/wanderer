defmodule WandererApp.Repo.Migrations.NormalizeMapScopesDefault do
  @moduledoc ~S"""
  Re-records the `maps_v1.scopes` default in the resource snapshot so
  `mix ash.codegen --check` stops reporting pending changes.

  `20260406213852_add_character_description.exs` wrote the default as the
  charlist literal `'{wormholes}'`, which is how ash_postgres serialized array
  defaults at the time. Current ash_postgres renders the same default as the
  Elixir list `["wormholes"]`, so every codegen run since has seen a diff that
  nobody committed.

  This is a no-op against the database. Both forms compile to the identical
  column default (`ARRAY['wormholes']` and `'{wormholes}'` are the same
  `text[]` value), and the type is unchanged, so Postgres takes a brief
  ACCESS EXCLUSIVE lock without rewriting the table. It is committed only so
  the snapshot on disk matches what codegen generates.
  """

  use Ecto.Migration

  def up do
    alter table(:maps_v1) do
      modify :scopes, {:array, :text}, default: ["wormholes"]
    end
  end

  def down do
    alter table(:maps_v1) do
      modify :scopes, {:array, :text}, default: ~c"{wormholes}"
    end
  end
end
