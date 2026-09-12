defmodule WandererApp.Api.MapIntegrationToken do
  @moduledoc false
  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo WandererApp.Repo
    table "map_integration_tokens_v1"
    identity_wheres_to_sql active_user_map: "revoked_at IS NULL"

    references do
      reference :map, on_delete: :delete, index?: true
      reference :user, on_delete: :delete, index?: true
    end

    check_constraints do
      check_constraint [:user_id, :encrypted_value], "personal_credential",
        check: "revoked_at IS NOT NULL OR (user_id IS NOT NULL AND encrypted_value IS NOT NULL)"
    end
  end

  code_interface do
    define :issue, action: :issue
    define :replace, action: :replace
    define :revoke, action: :revoke
    define :by_id, action: :read, get_by: [:id]
    define :by_map, action: :by_map, args: [:map_id]
  end

  actions do
    defaults [:read]

    create :issue do
      accept [:id, :map_id, :user_id, :digest, :encrypted_value]
      validate present([:user_id, :encrypted_value])
    end

    read :by_map do
      argument :map_id, :uuid, allow_nil?: false
      filter expr(map_id == ^arg(:map_id))
    end

    update :replace do
      accept [:digest, :encrypted_value]
      validate present([:digest, :encrypted_value])
      require_atomic? false
      validate attribute_equals(:revoked_at, nil)
      change increment(:generation)
    end

    update :revoke do
      accept []
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
      change increment(:generation)
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    # Retain historical names on invalidated map-only rows; new tokens have no name.
    attribute :name, :string, writable?: false

    attribute :scope, :string,
      allow_nil?: false,
      default: "tracked_character_locations:read",
      writable?: false

    attribute :digest, :binary, allow_nil?: false, sensitive?: true
    # Nullable only for historical, revoked credentials. Issue/replace require a value.
    attribute :encrypted_value, :binary, sensitive?: true
    attribute :generation, :integer, allow_nil?: false, default: 1
    attribute :revoked_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :active_user_map, [:user_id, :map_id], where: expr(is_nil(revoked_at))
  end

  relationships do
    belongs_to :map, WandererApp.Api.Map, allow_nil?: false, attribute_writable?: true
    belongs_to :user, WandererApp.Api.User, attribute_writable?: true
  end
end
