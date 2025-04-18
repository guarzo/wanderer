defmodule WandererApp.Repo.Migrations.AddCharacterStationId do
  @moduledoc """
  Updates resources based on their most recent snapshots.

  This file was autogenerated with `mix ash_postgres.generate_migrations`
  """

  use Ecto.Migration

  def up do
    alter table(:character_v1) do
      add :encrypted_station_id, :binary
    end
  end

  def down do
    alter table(:character_v1) do
      remove :encrypted_station_id
    end
  end
end
