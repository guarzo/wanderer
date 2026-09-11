defmodule WandererApp.Api.MapIntegrationToken do
  @moduledoc false
  use Ash.Resource, domain: WandererApp.Api, data_layer: AshPostgres.DataLayer

  postgres do
    repo WandererApp.Repo
    table "map_integration_tokens_v1"

    references do
      reference :map, on_delete: :delete
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
      accept [:id, :map_id, :name, :digest]
    end

    read :by_map do
      argument :map_id, :uuid, allow_nil?: false
      filter expr(map_id == ^arg(:map_id))
    end

    update :replace do
      accept [:digest]
      change increment(:generation)
    end

    update :revoke do
      accept []
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
      change increment(:generation)
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 64]

    attribute :scope, :string,
      allow_nil?: false,
      default: "tracked_character_locations:read",
      writable?: false

    attribute :digest, :binary, allow_nil?: false, sensitive?: true
    attribute :generation, :integer, allow_nil?: false, default: 1
    attribute :revoked_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :map, WandererApp.Api.Map, allow_nil?: false, attribute_writable?: true
  end
end
