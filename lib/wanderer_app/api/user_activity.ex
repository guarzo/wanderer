defmodule WandererApp.Api.UserActivity do
  @moduledoc false

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  import Ash.Query
  import Ash.Expr

  postgres do
    repo(WandererApp.Repo)
    table("user_activity_v1")

    custom_indexes do
      index [:entity_id, :event_type, :inserted_at], unique: true
    end
  end

  code_interface do
    define(:new, action: :new)
    define(:read, action: :read)
  end

  actions do
    default_accept [
      :entity_id,
      :entity_type,
      :event_type,
      :event_data
    ]

    defaults [:create, :update, :destroy]

    read :read do
      primary?(true)
      pagination(offset?: true, keyset?: true)
    end

    create :new do
      accept [:entity_id, :entity_type, :event_type, :event_data]
      primary?(true)

      argument :user_id, :uuid, allow_nil?: false
      argument :character_id, :uuid, allow_nil?: true

      change manage_relationship(:user_id, :user, on_lookup: :relate, on_no_match: nil)
      change manage_relationship(:character_id, :character, on_lookup: :relate, on_no_match: nil)
    end

    destroy :archive do
      soft? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :entity_id, :string do
      allow_nil? false
    end

    attribute :entity_type, :atom do
      default "map"

      constraints(
        one_of: [
          :map,
          :access_list
        ]
      )

      allow_nil?(false)
    end

    attribute :event_type, :atom do
      default "custom"

      constraints(
        one_of: [
          :custom,
          :hub_added,
          :hub_removed,
          :system_added,
          :systems_removed,
          :system_updated,
          :character_added,
          :character_removed,
          :character_updated,
          :map_added,
          :map_removed,
          :map_updated,
          :map_acl_added,
          :map_acl_removed,
          :map_acl_updated,
          :map_acl_member_added,
          :map_acl_member_removed,
          :map_acl_member_updated,
          :map_connection_added,
          :map_connection_updated,
          :map_connection_removed,
          :signatures_added,
          :signatures_removed
        ]
      )

      allow_nil?(false)
    end

    attribute :event_data, :string

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :character, WandererApp.Api.Character do
      allow_nil? true
      attribute_writable? true
    end

    belongs_to :user, WandererApp.Api.User do
      source_attribute :user_id
      allow_nil? false
      attribute_writable? true
    end
  end

  calculations do
    calculate :character_activity_summary, :map, fn records, _opts ->
      # Ensure character relationship is loaded with all needed fields
      records =
        Ash.load!(records, character: [:id, :name, :corporation_ticker, :alliance_ticker, :eve_id])

      records
      |> Enum.group_by(& &1.character)
      |> Enum.reject(fn {character, _} -> is_nil(character) end)
      |> Enum.map(fn {character, char_activities} ->
        %{
          character: %{
            id: character.id,
            name: character.name,
            corporation_ticker: character.corporation_ticker,
            alliance_ticker: character.alliance_ticker,
            eve_id: character.eve_id
          },
          connections: Enum.count(char_activities, &(&1.event_type == :map_connection_added)),
          signatures: Enum.count(char_activities, &(&1.event_type == :signatures_added))
        }
      end)
      |> Enum.sort_by(& &1.character.name)
    end
  end

  def base_activity_query(map_id, limit \\ 10_000) do
    __MODULE__
    |> filter(expr(entity_id == ^map_id and entity_type == :map))
    |> load(character: [:name, :corporation_ticker, :alliance_ticker, :eve_id])
    |> load(:character_activity_summary)
    |> sort(inserted_at: :desc)
    |> page(limit: limit)
  end

  def merge_passages(activities, passages_map) do
    require Logger

    Logger.debug("Activities: #{inspect(activities)}")
    Logger.debug("Passages map: #{inspect(passages_map)}")

    summaries =
      activities.results
      |> tap(&Logger.debug("Results: #{inspect(&1)}"))
      |> Enum.map(& &1.character_activity_summary)
      |> tap(&Logger.debug("After map: #{inspect(&1)}"))
      |> List.flatten()
      |> tap(&Logger.debug("After flatten: #{inspect(&1)}"))
      |> Enum.map(fn summary ->
        Map.put(summary, :passages, Map.get(passages_map, summary.character.id, 0))
      end)
      |> tap(&Logger.debug("Final summaries: #{inspect(&1)}"))

    summaries
  end
end
