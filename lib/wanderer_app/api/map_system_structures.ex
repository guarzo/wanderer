defmodule WandererApp.Api.MapSystemStructures do
  @moduledoc false

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("map_system_structures_v1")
  end

  code_interface do
    define(:all_active, action: :all_active)
    define(:create, action: :create)
    define(:update, action: :update)
    define(:update_type, action: :update_type)
    define(:update_group, action: :update_group)

    define(:by_id,
      get_by: [:id],
      action: :read
    )

    define(:by_system_id, action: :by_system_id, args: [:system_id])
  end

  actions do
    # Allow these fields by default if you like:
    default_accept [
      :system_id,
      :solar_system_name,
      :solar_system_id,
      :type_id,
      :character_eve_id,
      :name,
      :description,
      :kind,
      :group,
      :type,
      :owner,
      :owner_ticker,
      :owner_id,
      :status,
      :end_time
    ]

    # The usual read & destroy
    defaults [:read, :destroy]

    read :all_active do
      prepare build(sort: [updated_at: :desc])
    end

    create :create do
      primary? true

      accept [
        :system_id,
        :solar_system_name,
        :solar_system_id,
        :type_id,
        :character_eve_id,
        :name,
        :description,
        :kind,
        :group,
        :type,
        :custom_info,
        :updated,
        :owner,
        :owner_ticker,
        :owner_id,
        :status,
        :end_time
      ]

      argument :system_id, :uuid, allow_nil?: false

      change manage_relationship(:system_id, :system,
        on_lookup: :relate,
        on_no_match: nil
      )
    end

    update :update do
      accept [
        :system_id,
        :solar_system_name,
        :solar_system_id,
        :type_id,
        :character_eve_id,
        :name,
        :description,
        :kind,
        :group,
        :type,
        :custom_info,
        :updated,
        :owner,
        :owner_ticker,
        :owner_id,
        :status,
        :end_time
      ]

      primary? true
      require_atomic? false
    end

    update :update_type do
      accept [:type]
    end

    update :update_group do
      accept [:group]
    end

    read :by_system_id do
      argument :system_id, :string, allow_nil?: false
      filter(expr(system_id == ^arg(:system_id)))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :type_id, :string do
      allow_nil? false
    end

    attribute :character_eve_id, :string do
      allow_nil? false
    end

    attribute :solar_system_name, :string do
      allow_nil? false
    end

    attribute :solar_system_id, :integer do
      allow_nil? false
    end

    attribute :name, :string do
      allow_nil? true
    end

    attribute :description, :string do
      allow_nil? true
    end

    attribute :type, :string
    attribute :kind, :string
    attribute :group, :string

    attribute :custom_info, :string do
      allow_nil? true
    end

    attribute :updated, :integer

    attribute :owner, :string do
      allow_nil? true
    end

    attribute :owner_ticker, :string do
      allow_nil? true
    end

    attribute :owner_id, :string do
      allow_nil? true
    end

    attribute :status, :string do
      allow_nil? true
    end

    attribute :end_time, :utc_datetime_usec do
      allow_nil? true
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :system, WandererApp.Api.MapSystem do
      attribute_writable? true
    end
  end

end
