defmodule WandererApp.Repo.Migrations.AddTemporaryName do
  @moduledoc """
  Updates resources based on their most recent snapshots.

  This file was autogenerated with `mix ash_postgres.generate_migrations`
  """

  use Ecto.Migration

  def up do
    alter table(:map_system_v1) do
      add :temporary_name, :text
    end
  end

  def down do
    alter table(:map_system_v1) do
      remove :temporary_name
    end
  end
end
