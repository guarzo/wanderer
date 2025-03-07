defmodule WandererApp.Repo.Migrations.AddSignatureType do
  @moduledoc """
  Updates resources based on their most recent snapshots.

  This file was autogenerated with `mix ash_postgres.generate_migrations`
  """

  use Ecto.Migration

  def up do
    alter table(:map_system_signatures_v1) do
      add :type, :text
    end
  end

  def down do
    alter table(:map_system_signatures_v1) do
      remove :type
    end
  end
end
