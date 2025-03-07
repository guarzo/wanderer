defmodule WandererApp.Repo.Migrations.MigrateResources1 do
  @moduledoc """
  Updates resources based on their most recent snapshots.

  This file was autogenerated with `mix ash_postgres.generate_migrations`
  """

  use Ecto.Migration

  def up do
    alter table(:map_character_settings_v1) do
      add :followed, :boolean, default: false
    end
  end

  def down do
    alter table(:map_character_settings_v1) do
      remove :followed
    end
  end
end
