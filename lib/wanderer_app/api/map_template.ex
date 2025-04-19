defmodule WandererApp.Api.MapTemplate do
  @moduledoc """
  Template resource for storing and managing map templates.

  Templates contain a set of systems and connections that can be applied to maps.
  They can represent common patterns like wormhole chains, regions, or user-defined layouts.
  """

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(WandererApp.Repo)
    table("map_template_v1")
  end

  code_interface do
    define(:create, action: :create)
    define(:get, get_by: [:id], action: :read)
    define(:list_public, action: :list_public)
    define(:list_by_author, action: :list_by_author)
    define(:list_by_category, action: :list_by_category)
    define(:update_metadata, action: :update_metadata)
    define(:update_content, action: :update_content)
    define(:destroy, action: :destroy)
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    read :list_public do
      filter(expr(is_public == true))
    end

    read :list_by_author do
      argument(:author_id, :string, allow_nil?: false)
      filter(expr(author_id == ^arg(:author_id)))
    end

    read :list_by_category do
      argument(:category, :string, allow_nil?: false)
      filter(expr(category == ^arg(:category)))
    end

    update :update_metadata do
      accept [
        :name,
        :description,
        :category,
        :is_public,
        :allow_merge,
        :allow_override,
        :position_strategy
      ]
    end

    update :update_content do
      accept [
        :systems,
        :connections,
        :metadata
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    # Template metadata
    attribute :name, :string do
      allow_nil? false
    end

    attribute :description, :string do
      allow_nil? true
    end

    attribute :category, :string do
      allow_nil? false
      default "custom"
    end

    attribute :author_id, :string do
      allow_nil? true
    end

    attribute :source_map_id, :string do
      allow_nil? true
    end

    attribute :is_public, :boolean do
      allow_nil? false
      default false
    end

    # Template content (stored as JSON)
    attribute :systems, :map do
      allow_nil? false
    end

    attribute :connections, :map do
      allow_nil? false
    end

    attribute :metadata, :map do
      allow_nil? true
      default %{}
    end

    # Application options
    attribute :allow_merge, :boolean do
      allow_nil? false
      default true
    end

    attribute :allow_override, :boolean do
      allow_nil? false
      default false
    end

    attribute :position_strategy, :string do
      allow_nil? false
      default "center"
      constraints [one_of: ["center", "north", "preserve", "absolute", "relative"]]
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :author, WandererApp.Api.User do
      attribute_writable? true
      source_attribute :author_id
      destination_attribute :id
      allow_nil? true
    end

    belongs_to :source_map, WandererApp.Api.Map do
      attribute_writable? true
      source_attribute :source_map_id
      destination_attribute :id
      allow_nil? true
    end
  end
end
