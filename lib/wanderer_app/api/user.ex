defmodule WandererApp.Api.User do
  @moduledoc false

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak]

  postgres do
    repo(WandererApp.Repo)
    table("user_v1")
  end

  code_interface do
    define(:by_id, get_by: [:id], action: :read)
    define(:by_hash, get_by: [:hash], action: :read)
    define(:update_last_map, action: :update_last_map)
    define(:update_balance, action: :update_balance)
    define(:set_primary_character, action: :set_primary_character)
  end

  actions do
    default_accept [:name, :hash]

    create :create

    read :read do
      primary? true
    end

    update :update
    destroy :destroy

    defaults [:create, :read, :update, :destroy]

    update :update_last_map do
      accept([:last_map_id])
    end

    update :update_balance do
      require_atomic? false
      accept([:balance])
    end

    update :set_primary_character do
      accept([:primary_character_id])
      defaults []
    end
  end

  cloak do
    vault(WandererApp.Vault)
    attributes([:balance])
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string
    attribute :hash, :string
    attribute :last_map_id, :uuid

    # Primary character foreign key (must refer to one of the user's characters)
    attribute :primary_character_id, :uuid do
      allow_nil? true
    end

    attribute :balance, :float do
      default 0.0
      allow_nil?(true)
    end
  end

  relationships do
    has_many :characters, WandererApp.Api.Character

    belongs_to :primary_character, WandererApp.Api.Character,
      source_attribute: :primary_character_id,
      attribute_writable?: true,
      allow_nil?: true

    has_many :activities, WandererApp.Api.UserActivity do
      destination_attribute :user_id
      source_attribute :id
    end
  end

  identities do
    identity :unique_hash, [:hash] do
      pre_check?(false)
    end
  end

  # Add this calculation to help find the default character
  calculations do
    calculate :default_character_id,
              :uuid,
              expr(
                coalesce(
                  primary_character_id,
                  first(sort(characters, created_at, :asc)).id
                )
              )

    calculate :activity_stats,
              :map,
              expr(%{
                connections: length(filter(activities, event_type == :map_connection_added)),
                passages: length(filter(activities, event_type == :jumps)),
                signatures: length(filter(activities, event_type == :signatures_added))
              })
  end
end
