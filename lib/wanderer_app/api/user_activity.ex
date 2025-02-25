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
      require Logger
      # Ensure character relationship is loaded with all needed fields
      records =
        Ash.load!(records, [
          character: [:id, :name, :corporation_ticker, :alliance_ticker, :eve_id],
          user: [:primary_character, characters: [:id, :name, :corporation_ticker, :alliance_ticker, :eve_id]]
        ])

      # Create a comprehensive user_id -> characters map first
      user_to_characters = records
        |> Enum.reduce(%{}, fn record, acc ->
          if record.user_id && record.user && record.user.characters do
            Map.put(acc, record.user_id, record.user.characters)
          else
            acc
          end
        end)

      Logger.info("Found #{map_size(user_to_characters)} users with characters")

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
          Logger.warn("No display character found for user #{user_id}")
          nil
        else
          # Get all character IDs for this user from our comprehensive map
          user_character_ids = Map.get(user_to_characters, user_id, []) |> Enum.map(& &1.id)

          Logger.debug("User #{user_id} has #{length(user_character_ids)} characters")

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
            user_id: user_id,
            character_ids: user_character_ids,
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

  def base_activity_query(map_id, limit \\ 50_000, hours_ago \\ nil) do
    query = __MODULE__
    |> filter(expr(entity_id == ^map_id and entity_type == :map))

    # Apply time filter if hours_ago is provided
    query = if hours_ago do
      cutoff = DateTime.utc_now() |> DateTime.add(-hours_ago * 3600, :second)
      query |> filter(expr(inserted_at >= ^cutoff))
    else
      query
    end

    query
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
    require Logger

    # Log the input data
    Logger.info("Merging passages - Activities count: #{length(activities.results)}")
    Logger.info("Merging passages - Passages map count: #{map_size(passages_map)}")

    # Log passage map keys to help debug
    passage_char_ids = Map.keys(passages_map)
    Logger.debug("Passage character IDs (first 10): #{inspect(Enum.take(passage_char_ids, 10))}")

    # Get the activity summaries
    summaries = activities.results
      |> Enum.map(& &1.character_activity_summary)
      |> List.flatten()

    Logger.info("Flattened summaries count: #{length(summaries)}")

    # Create a map of character IDs to their summaries for quick lookup
    char_id_to_summary = summaries
      |> Enum.reduce(%{}, fn summary, acc ->
        # Add the primary character ID mapping
        acc = Map.put(acc, summary.character.id, summary)

        # Add mappings for all character IDs associated with this user
        Enum.reduce(Map.get(summary, :character_ids, []), acc, fn char_id, inner_acc ->
          if char_id != summary.character.id do
            Map.put_new(inner_acc, char_id, summary)
          else
            inner_acc
          end
        end)
      end)

    Logger.info("Character ID to summary map size: #{map_size(char_id_to_summary)}")

    # Check for characters in passages_map that aren't in char_id_to_summary
    missing_chars = passage_char_ids -- Map.keys(char_id_to_summary)
    if length(missing_chars) > 0 do
      Logger.warning("Found #{length(missing_chars)} characters with passages but no activity summary")
      Logger.debug("Missing character IDs (first 10): #{inspect(Enum.take(missing_chars, 10))}")

      # Load the missing characters to create summaries for them
      missing_char_data = load_missing_characters(missing_chars)
      Logger.info("Loaded #{length(missing_char_data)} missing characters")

      # Create summaries for missing characters
      missing_summaries = create_summaries_for_missing_characters(missing_char_data, passages_map)
      Logger.info("Created #{length(missing_summaries)} additional summaries for characters with passages")

      # Add the new summaries to our existing ones
      summaries = summaries ++ missing_summaries
    end

    # Process each summary
    result = summaries
      |> Enum.map(fn summary ->
        # Use the character_ids directly from the summary
        user_character_ids = Map.get(summary, :character_ids, [])

        # Log character mapping
        Logger.debug("User with character #{summary.character.name} has #{length(user_character_ids)} associated characters")

        # Sum up passages for all characters belonging to this user
        total_passages = passages_map
          |> Enum.filter(fn {char_id, _count} -> char_id in user_character_ids end)
          |> Enum.map(fn {char_id, count} ->
            Logger.debug("Character #{char_id} has #{count} passages")
            count
          end)
          |> Enum.sum()

        Logger.debug("Total passages for #{summary.character.name}: #{total_passages}")

        # Remove the temporary fields we added
        summary
        |> Map.put(:passages, total_passages)
        |> Map.drop([:user_id, :character_ids])
      end)

    Logger.info("Final activity summaries count: #{length(result)}")
    result
  end

  # Helper function to load character data for characters with passages but no activity
  defp load_missing_characters(character_ids) do
    require Logger

    if Enum.empty?(character_ids) do
      []
    else
      # Take only the first 100 characters to avoid overloading the query
      ids_to_load = Enum.take(character_ids, 100)
      Logger.info("Loading data for #{length(ids_to_load)} missing characters")

      try do
        WandererApp.Api.Character
        |> Ash.Query.filter(id in ^ids_to_load)
        |> Ash.Query.load([:user])
        |> WandererApp.Api.read!()
      rescue
        e ->
          Logger.error("Error loading missing characters: #{inspect(e)}")
          []
      end
    end
  end

  # Helper function to create summaries for characters with passages but no activity
  defp create_summaries_for_missing_characters(characters, passages_map) do
    require Logger

    characters
    |> Enum.map(fn character ->
      # Only create summaries for characters that have passages
      if Map.has_key?(passages_map, character.id) do
        passage_count = Map.get(passages_map, character.id, 0)

        # Create a basic summary with just the character and passage count
        %{
          character: %{
            id: character.id,
            name: character.name,
            corporation_ticker: character.corporation_ticker,
            alliance_ticker: character.alliance_ticker,
            eve_id: character.eve_id
          },
          user_id: character.user_id,
          character_ids: [character.id],
          passages: passage_count,
          connections: 0,
          signatures: 0
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
