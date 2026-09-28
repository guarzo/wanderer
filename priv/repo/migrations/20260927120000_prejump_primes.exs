defmodule WandererApp.Repo.Migrations.PrejumpPrimes do
  @moduledoc """
  Prime credential reuse of map_integration_tokens_v1 (new scope) and the
  durable, TTL-bounded pre-jump prime store consumed by the movement flow.
  """

  use Ecto.Migration

  def up do
    # One active token per user+map+scope: prime credentials must coexist with
    # read credentials for the same user+map. The old index (user_id, map_id
    # WHERE active) is strictly coarser; all pre-existing rows share the read
    # scope, so recreating with scope preserves its semantics exactly.
    drop_if_exists unique_index(:map_integration_tokens_v1, [:user_id, :map_id],
                     name: "map_integration_tokens_v1_active_user_map_index"
                   )

    create unique_index(:map_integration_tokens_v1, [:user_id, :map_id, :scope],
             name: "map_integration_tokens_v1_active_user_map_scope_index",
             where: "(revoked_at IS NULL)"
           )

    create table(:prejump_primes_v1, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :map_id,
          references(:maps_v1, column: :id, type: :uuid, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:user_v1, column: :id, type: :uuid, on_delete: :delete_all),
          null: false

      add :event_id, :uuid, null: false
      add :eve_character_id, :bigint, null: false
      add :source_solar_system_id, :bigint, null: false
      add :system_name, :text, null: false
      add :flags_eol, :boolean, null: false, default: false
      add :flags_half_mass, :boolean, null: false, default: false
      add :flags_critical, :boolean, null: false, default: false
      add :flags_frigate, :boolean, null: false, default: false
      add :consumed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    # One active prime per character+map: newest Set Root wins.
    create unique_index(:prejump_primes_v1, [:map_id, :eve_character_id],
             name: "prejump_primes_v1_active_character_map_index",
             where: "(consumed_at IS NULL)"
           )

    create index(:prejump_primes_v1, [:map_id, :eve_character_id],
             where: "(consumed_at IS NULL)",
             name: "prejump_primes_v1_lookup_index"
           )

    create index(:prejump_primes_v1, [:expires_at], name: "prejump_primes_v1_expiry_index")
  end

  def down do
    drop_if_exists table(:prejump_primes_v1)

    drop_if_exists unique_index(:map_integration_tokens_v1, [:user_id, :map_id, :scope],
                     name: "map_integration_tokens_v1_active_user_map_scope_index"
                   )

    create unique_index(:map_integration_tokens_v1, [:user_id, :map_id],
             name: "map_integration_tokens_v1_active_user_map_index",
             where: "(revoked_at IS NULL)"
           )
  end
end
