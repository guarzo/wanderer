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
        Ash.load!(records, [
          character: [:id, :name, :corporation_ticker, :alliance_ticker, :eve_id],
          user: [:primary_character, characters: [:id]]
        ])

      records
      |> Enum.group_by(& &1.user_id)
      |> Enum.reject(fn {user_id, _} -> is_nil(user_id) end)
      |> Enum.map(fn {user_id, user_activities} ->
        # Get the user from the first activity
        user = user_activities |> Enum.at(0) |> Map.get(:user)

        # Try to get the primary character first, then fall back to any character from activities
        display_character = cond do
          user && user.primary_character -> user.primary_character
          first_with_char = Enum.find(user_activities, & &1.character) -> first_with_char.character
          true -> nil
        end

        if is_nil(display_character) do
          nil
        else
          # Get all character IDs for this user
          user_character_ids = user.characters |> Enum.map(& &1.id)

          # Get all activities for all characters of this user
          all_user_activities = records
            |> Enum.filter(& &1.user_id == user_id)

          %{
            character: %{
              id: display_character.id,
              name: display_character.name,
              corporation_ticker: display_character.corporation_ticker,
              alliance_ticker: display_character.alliance_ticker,
              eve_id: display_character.eve_id
            },
            passages: 0,  # This gets overridden by merge_passages later
            connections: Enum.count(all_user_activities, &(&1.event_type == :map_connection_added)),
            signatures: Enum.count(all_user_activities, &(&1.event_type == :signatures_added))
          }
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.character.name)
    end
  end

  def base_activity_query(map_id, limit \\ 10_000) do
    __MODULE__
    |> filter(expr(entity_id == ^map_id and entity_type == :map))
    |> load([
      character: [:id, :name, :corporation_ticker, :alliance_ticker, :eve_id],
      user: [
        :primary_character,
        characters: [:id, :name, :corporation_ticker, :alliance_ticker, :eve_id]
      ]
    ])
    |> load(:character_activity_summary)
    |> sort(inserted_at: :desc)
    |> page(limit: limit)
  end

  def merge_passages(activities, passages_map) do
    summaries =
      activities.results
      |> Enum.map(& &1.character_activity_summary)
      |> List.flatten()
      |> Enum.map(fn %{character: %{id: primary_char_id}} = summary ->
        # Get all character IDs for this user from the activities
        user_character_ids = activities.results
          |> Enum.find(& &1.character_id == primary_char_id)
          |> case do
            nil -> []
            activity -> activity.user |> Map.get(:characters, []) |> Enum.map(& &1.id)
          end

        # Sum up passages for all characters belonging to this user
        total_passages = passages_map
          |> Enum.filter(fn {char_id, _count} ->
            char_id in user_character_ids
          end)
          |> Enum.map(fn {_char_id, count} -> count end)
          |> Enum.sum()

        Map.put(summary, :passages, total_passages)
      end)

    summaries
  end
end
