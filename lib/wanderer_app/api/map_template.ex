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
    define(:read, get_by: [:id], action: :read)
    define(:read_public, action: :list_public)
    define(:read_by_author, action: :list_by_author)
    define(:read_by_category, action: :list_by_category)
    define(:update_metadata, action: :update_metadata)
    define(:update_content, action: :update_content)
    define(:destroy, action: :destroy)
    define(:read_all_for_map, action: :read_all_for_map)
  end

  actions do
    defaults [:read, :update, :destroy]

    create :create do
      accept [
        :name,
        :description,
        :category,
        :author_eve_id,
        :source_map_id,
        :is_public,
        :systems,
        :connections,
        :metadata
      ]
    end

    read :list_public do
      filter(expr(is_public == true))
    end

    read :list_by_author do
      argument(:author_eve_id, :string, allow_nil?: false)
      filter(expr(author_eve_id == ^arg(:author_eve_id)))
    end

    read :list_by_category do
      argument(:category, :string, allow_nil?: false)
      filter(expr(category == ^arg(:category)))
    end

    read :read_all_for_map do
      argument :source_map_id, :uuid, allow_nil?: false
      filter expr(source_map_id == ^arg(:source_map_id))
    end

    update :update_metadata do
      accept [
        :name,
        :description,
        :category,
        :is_public
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

    # The ID of the EVE character that created this template
    attribute :author_eve_id, :string do
      allow_nil? true
    end

    attribute :source_map_id, :uuid do
      allow_nil? true
    end

    attribute :is_public, :boolean do
      allow_nil? false
      default false
    end

    # Template content (stored as JSON arrays)
    attribute :systems, {:array, :map} do
      allow_nil? false
    end

    attribute :connections, {:array, :map} do
      allow_nil? false
    end

    attribute :metadata, :map do
      allow_nil? true
      default %{}
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :source_map, WandererApp.Api.Map do
      attribute_writable? true
      source_attribute :source_map_id
      destination_attribute :id
      allow_nil? true
    end
  end
end
