defmodule WandererApp.Repo.Migrations.AddBotLicenses do
  @moduledoc """
  Updates resources based on their most recent snapshots.

  This file was autogenerated with `mix ash_postgres.generate_migrations`
  """

  use Ecto.Migration

  def up do
    create table(:map_licenses_v1, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :license_key, :text, null: false
      add :is_valid, :boolean, null: false, default: true
      add :expire_at, :utc_datetime

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :map_id,
          references(:maps_v1,
            column: :id,
            name: "map_licenses_v1_map_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end
  end

  def down do
    drop constraint(:map_licenses_v1, "map_licenses_v1_map_id_fkey")

    drop table(:map_licenses_v1)
  end
end
