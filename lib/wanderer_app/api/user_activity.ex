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
      records =
        Ash.load!(records, [
          character: [:id, :name, :corporation_ticker, :alliance_ticker, :eve_id],
          user: [:primary_character, characters: [:id, :name, :corporation_ticker, :alliance_ticker, :eve_id]]
        ])

      # Log all users found in the records
      all_user_ids = records
        |> Enum.map(& &1.user_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      # Create a comprehensive user_id -> characters map first
      user_to_characters = records
        |> Enum.reduce(%{}, fn record, acc ->
          if record.user_id && record.user && record.user.characters do
            Map.put(acc, record.user_id, record.user.characters)
          else
            acc
          end
        end)

      # Group activities by user_id
      user_activities = records
        |> Enum.group_by(& &1.user_id)
        |> Enum.reject(fn {user_id, _} -> is_nil(user_id) end)

      user_activities
      |> Enum.map(fn {user_id, user_activities} ->
        # Get the user from the first activity
        user = user_activities |> Enum.at(0) |> Map.get(:user)

        # Try to get the primary character first, then fall back to any character from activities
        display_character = cond do
          user && user.primary_character ->
            user.primary_character
          first_with_char = Enum.find(user_activities, & &1.character) ->
            first_with_char.character
          true ->
            nil
        end

        if is_nil(display_character) do
          nil
        else
          # Get all character IDs for this user from our comprehensive map
          user_character_ids = Map.get(user_to_characters, user_id, []) |> Enum.map(& &1.id)

          # Get all activities for all characters of this user
          all_user_activities = records
            |> Enum.filter(& &1.user_id == user_id)

          connections_count = Enum.count(all_user_activities, &(&1.event_type == :map_connection_added))
          signatures_count = Enum.count(all_user_activities, &(&1.event_type == :signatures_added))


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
            connections: connections_count,
            signatures: signatures_count
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

  def merge_passages(activities, passages_map, limit \\ nil) do
    require Logger

    # Log passage map keys to help debug
    passage_char_ids = Map.keys(passages_map)
    Logger.debug("Passage map contains #{length(passage_char_ids)} character IDs")

    # Get the activity summaries
    activity_summaries = activities.results
      |> Enum.map(& &1.character_activity_summary)
      |> List.flatten()

    Logger.debug("Activity summaries count: #{length(activity_summaries)}")

    # Get unique user IDs from summaries
    unique_user_ids = activity_summaries |> Enum.map(& &1.user_id) |> Enum.uniq()
    Logger.debug("Unique user IDs count: #{length(unique_user_ids)}")

    # Log details about each user and their characters
    Enum.each(activity_summaries, fn summary ->
      user_id = summary.user_id
      character_ids = Map.get(summary, :character_ids, [])
      character_name = summary.character.name
      Logger.debug("User #{user_id} has character #{character_name} with #{length(character_ids)} associated character IDs")
    end)

    # Create a map of character IDs to their summaries for quick lookup
    char_id_to_summary = activity_summaries
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

    # Check for characters in passages_map that aren't in char_id_to_summary
    missing_chars = passage_char_ids -- Map.keys(char_id_to_summary)
    Logger.debug("Found #{length(missing_chars)} characters with passages but no activity summary")

    # Get missing character summaries
    missing_summaries = if length(missing_chars) > 0 do
      Logger.debug("Loading missing characters: #{inspect(missing_chars, limit: 5)}")

      # Log the total number of characters with passages
      Logger.debug("Total characters with passages: #{length(passage_char_ids)}")

      # Log the distribution of passage counts
      passage_counts = passages_map |> Enum.map(fn {_, count} -> count end) |> Enum.sort(:desc)
      Logger.debug("Passage counts distribution: #{inspect(passage_counts, limit: 10)}")

      # Load the missing characters to create summaries for them
      missing_char_data = load_missing_characters(missing_chars)
      Logger.debug("Loaded #{length(missing_char_data)} missing characters")

      # Log details about missing characters
      Enum.each(missing_char_data, fn character ->
        passage_count = Map.get(passages_map, character.id, 0)
        Logger.debug("Missing character #{character.name} has #{passage_count} passages")
      end)

      # Create summaries for missing characters
      summaries = create_summaries_for_missing_characters(missing_char_data, passages_map)
      Logger.debug("Created #{length(summaries)} summaries for missing characters")
      summaries
    else
      []
    end

    # Process activity summaries to add passage counts
    processed_activity_summaries = activity_summaries
      |> Enum.map(fn summary ->
        # Use the character_ids directly from the summary
        user_character_ids = Map.get(summary, :character_ids, [])
        Logger.debug("Processing summary for character #{summary.character.name} with #{length(user_character_ids)} character IDs")

        # Sum up passages for all characters belonging to this user
        total_passages = passages_map
          |> Enum.filter(fn {char_id, _count} -> char_id in user_character_ids end)
          |> Enum.map(fn {_char_id, count} -> count end)
          |> Enum.sum()

        Logger.debug("Character #{summary.character.name} has #{total_passages} total passages")

        # Remove the temporary fields we added
        summary
        |> Map.put(:passages, total_passages)
        |> Map.drop([:user_id, :character_ids])
      end)

    # Combine the processed activity summaries with the missing character summaries
    result = processed_activity_summaries ++ missing_summaries
    Logger.debug("Combined result count: #{length(result)}")

    # Sort the results by total activity (passages + connections + signatures) in descending order
    sorted_result = result
      |> Enum.sort_by(fn summary ->
        summary.passages + summary.connections + summary.signatures
      end, :desc)

    # Apply limit if specified
    final_result = if limit do
      Logger.debug("Applying limit of #{limit} to result")
      Enum.take(sorted_result, limit)
    else
      sorted_result
    end

    # Log final result details
    Logger.debug("Final result count: #{length(final_result)}")
    if length(final_result) > 0 do
      first_item = List.first(final_result)
      Logger.debug("First item in result: #{inspect(first_item, pretty: true)}")
    end

    final_result
  end

  # Helper function to load character data for characters with passages but no activity
  defp load_missing_characters(character_ids) do
    if Enum.empty?(character_ids) do
      []
    else
      character_ids
      |> Enum.chunk_every(50)  # Process in batches of 50
      |> Enum.flat_map(fn batch ->
        try do
          WandererApp.Api.Character
          |> Ash.Query.filter(id in ^batch)
          |> Ash.Query.load([:user])
          |> WandererApp.Api.read!()
        rescue
          e ->
            Logger.error("Error loading batch of missing characters: #{inspect(e)}")
            []
        end
      end)
    end
  end

  # Helper function to create summaries for characters with passages but no activity
  defp create_summaries_for_missing_characters(characters, passages_map) do

    result = characters
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
          passages: passage_count,
          connections: 0,
          signatures: 0
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    result
  end
end
