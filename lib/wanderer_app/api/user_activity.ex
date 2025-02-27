defmodule WandererApp.Api.UserActivity do
  @moduledoc false

  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer

  import Ash.Query
  import Ash.Expr
  require Logger

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

      # Get all unique user IDs from the records
      all_user_ids = records
        |> Enum.map(& &1.user_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      # First, build a comprehensive map of user_id -> all character IDs
      user_to_character_ids = %{}
      user_to_character_ids = Enum.reduce(records, user_to_character_ids, fn record, acc ->
        if record.user_id && record.user && record.user.characters do
          character_ids = record.user.characters |> Enum.map(& &1.id)
          Map.put(acc, record.user_id, character_ids)
        else
          acc
        end
      end)

      # Next, determine the display character for each user (primary or oldest)
      user_to_display_character = %{}
      user_to_display_character = Enum.reduce(all_user_ids, user_to_display_character, fn user_id, acc ->
        # Get all records for this user
        user_records = Enum.filter(records, & &1.user_id == user_id)

        # Get the first record with a user that has a primary_character
        record_with_primary = Enum.find(user_records, fn r ->
          r.user && r.user.primary_character
        end)

        display_character = cond do
          # Use primary character if available
          record_with_primary ->
            record_with_primary.user.primary_character

          # Otherwise use the first character with a record
          first_with_char = Enum.find(user_records, & &1.character) ->
            first_with_char.character

          # Fallback to nil if no character found
          true ->
            nil
        end

        if display_character do
          Map.put(acc, user_id, display_character)
        else
          acc
        end
      end)

      # Now create summaries for each user
      Enum.map(all_user_ids, fn user_id ->
        # Get the display character for this user
        display_character = Map.get(user_to_display_character, user_id)

        # Skip if no display character found
        if is_nil(display_character) do
          nil
        else
          # Get all character IDs for this user
          user_character_ids = Map.get(user_to_character_ids, user_id, [])

          # Get all activities for all characters of this user
          all_user_activities = records
            |> Enum.filter(& &1.user_id == user_id)

          # Count activities by type
          connections_count = Enum.count(all_user_activities, &(&1.event_type == :map_connection_added))
          signatures_count = Enum.count(all_user_activities, &(&1.event_type == :signatures_added))

          # Create the summary
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

  def merge_passages(activities, passages_map, _limit \\ nil) do
    activity_summaries = activities.results
      |> Enum.map(& &1.character_activity_summary)
      |> List.flatten()

    # First, check for duplicate characters across all users
    # Extract all character IDs from all users
    all_character_ids = activity_summaries
      |> Enum.flat_map(& &1.character_ids)

    # Find duplicate character IDs (characters that appear in multiple users)
    _duplicate_character_ids = all_character_ids
      |> Enum.frequencies()
      |> Enum.filter(fn {_, count} -> count > 1 end)
      |> Enum.map(fn {id, count} -> {id, count} end)

    # Group summaries by character name to detect duplicates
    _character_name_groups = activity_summaries
      |> Enum.group_by(& &1.character.name)


    # Group summaries by user_id to ensure we have one summary per user
    user_summaries = activity_summaries
      |> Enum.group_by(& &1.user_id)

    # Convert to consolidated summaries - one per user
    user_summaries = user_summaries
      |> Enum.map(fn {user_id, summaries} ->
        # Find the primary summary for this user
        # Sort summaries to prioritize those with primary characters
        sorted_summaries = Enum.sort_by(summaries, fn summary ->
          # Prioritize summaries where the character is the primary character
          # This ensures we use the primary character as the display character
          is_primary = Enum.any?(summaries, fn s ->
            s.user_id == user_id &&
            s.character &&
            summary.character &&
            s.character.id == summary.character.id
          end)
          if is_primary, do: 0, else: 1
        end)

        primary_summary = List.first(sorted_summaries)

        # Collect all character IDs across all summaries for this user
        all_character_ids = summaries
          |> Enum.flat_map(& &1.character_ids)
          |> Enum.uniq()

        %{
          primary_summary |
          character_ids: all_character_ids,
          connections: Enum.sum(Enum.map(summaries, & &1.connections)),
          signatures: Enum.sum(Enum.map(summaries, & &1.signatures))
        }
      end)

    # Create a map of character IDs to their summaries for quick lookup
    char_id_to_summary = %{}

    # Add mappings for all character IDs to their respective user summary
    char_id_to_summary = Enum.reduce(user_summaries, char_id_to_summary, fn summary, acc ->
      # First add the primary character mapping
      acc = Map.put(acc, summary.character.id, summary)

      # Then add mappings for all other character IDs to the same summary
      result = Enum.reduce(summary.character_ids, acc, fn char_id, inner_acc ->
        if char_id != summary.character.id do
          Map.put_new(inner_acc, char_id, summary)
        else
          inner_acc
        end
      end)

      result
    end)

    # Find characters in passages_map that aren't in char_id_to_summary
    missing_chars = Map.keys(passages_map) -- Map.keys(char_id_to_summary)
    missing_summaries = if length(missing_chars) > 0 do
      # Load the missing characters to create summaries for them
      missing_char_data = load_missing_characters(missing_chars)
      associated_missing_chars = associate_missing_characters(missing_char_data, char_id_to_summary)

      # Create summaries only for truly missing characters (not associated with any user)
      truly_missing_chars = missing_char_data -- associated_missing_chars

      summaries = create_summaries_for_missing_characters(truly_missing_chars, passages_map)
      summaries
    else
      []
    end

    # Process user summaries to add passage counts
    processed_user_summaries = user_summaries
      |> Enum.map(fn summary ->
        # Get all character IDs for this summary
        user_character_ids = summary.character_ids

        # Find the relevant passages
        relevant_passages = passages_map
          |> Enum.filter(fn {char_id, _count} -> char_id in user_character_ids end)

        # Sum up passages for all characters belonging to this user
        total_passages = relevant_passages
          |> Enum.map(fn {_char_id, count} -> count end)
          |> Enum.sum()

        # Remove the temporary fields we added
        summary
        |> Map.put(:passages, total_passages)
        |> Map.drop([:user_id, :character_ids])
      end)

    # Combine processed user summaries with missing character summaries
    result = processed_user_summaries ++ missing_summaries

    # Transform the result for the React component
    transformed_result = Enum.map(result, fn summary ->
      %{
        "character_name" => summary.character.name,
        "eve_id" => summary.character.eve_id,
        "corporation_ticker" => summary.character.corporation_ticker || "",
        "alliance_ticker" => summary.character.alliance_ticker || "",
        "passages_traveled" => summary.passages,
        "connections_created" => summary.connections,
        "signatures_scanned" => summary.signatures
      }
    end)

    transformed_result
  end

  # Helper function to associate missing characters with existing users if possible
  defp associate_missing_characters(missing_char_data, char_id_to_summary) do

    # Try to load user information for missing characters
    missing_char_data_with_users = missing_char_data
      |> Enum.filter(& &1.user_id)

    # Find characters that can be associated with existing summaries
    associated_chars = Enum.filter(missing_char_data_with_users, fn char ->
      # Check if any existing summary is for the same user
      result = Enum.any?(char_id_to_summary, fn {_, summary} ->
        summary.user_id == char.user_id
      end)
      result
    end)

    associated_chars
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
          |> Ash.read!()
        rescue
          e ->
            # Log error but continue processing
            Logger.error("Error loading batch of missing characters: #{inspect(e)}")
            []
        end
      end)
    end
  end

  # Helper function to create summaries for characters with passages but no activity
  defp create_summaries_for_missing_characters(characters, passages_map) do
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
            corporation_ticker: character.corporation_ticker || "",
            alliance_ticker: character.alliance_ticker || "",
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
  end
end
