defmodule WandererApp.Domain.Maps do
  @moduledoc """
  Domain logic for Map operations.

  This module contains business logic that goes beyond basic CRUD operations
  for maps, including activity tracking, character management, and kill statistics.
  """

  alias WandererApp.Map
  alias WandererApp.MapSystemRepo
  alias WandererApp.Zkb.KillsProvider.KillsCache

  @doc """
  Gets aggregated character activity for a map over a specified time period.

  Aggregates activity (passages, connections, signatures) by user,
  selecting the character with the most activity as the representative.

  ## Parameters
    - map_id: The map ID
    - days: Number of days to look back (default: 7)

  ## Returns
    List of activity summaries grouped by user
  """
  def get_character_activity_summary(map_id, days \\ 7) do
    raw_activity = Map.get_character_activity(map_id, days)

    if raw_activity == [] do
      []
    else
      raw_activity
      |> Enum.group_by(fn activity -> activity.character.user_id end)
      |> Enum.map(&summarize_user_activity/1)
    end
  end

  @doc """
  Gets kill statistics for visible systems in a map.

  Fetches cached kill data and optionally filters by time window.

  ## Parameters
    - map_id: The map ID
    - hours_ago: Optional hours to filter kills (nil = no filter)

  ## Returns
    List of systems with their kill data
  """
  def get_systems_kills(map_id, hours_ago \\ nil) do
    with {:ok, systems} <- MapSystemRepo.get_visible_by_map(map_id) do
      solar_ids = Enum.map(systems, & &1.solar_system_id)
      kills_map = KillsCache.fetch_cached_kills_for_systems(solar_ids)

      data = Enum.map(systems, fn sys ->
        kills = Kernel.get_in(kills_map, [sys.solar_system_id]) || []
        filtered_kills = maybe_filter_kills_by_time(kills, hours_ago)

        %{
          solar_system_id: sys.solar_system_id,
          solar_system_name: sys.solar_system_name,
          kills: filtered_kills
        }
      end)

      {:ok, data}
    end
  end

  @doc """
  Gets tracked characters for a map.

  Returns all characters that are actively being tracked on the specified map,
  including their character details.

  ## Parameters
    - map_id: The map ID

  ## Returns
    - {:ok, characters} on success
    - {:error, reason} on failure
  """
  def get_tracked_characters(map_id) do
    import Ash.Query

    query =
      WandererApp.Api.MapCharacterSettings
      |> filter(map_id == ^map_id and tracked == true)
      |> load(:character)

    case WandererApp.Api.read(query) do
      {:ok, settings} ->
        characters = Enum.map(settings, fn setting ->
          character = setting.character

          %{
            id: character.id,
            eve_id: character.eve_id,
            name: character.name,
            corporation_id: character.corporation_id,
            corporation_name: character.corporation_name,
            corporation_ticker: character.corporation_ticker,
            alliance_id: character.alliance_id,
            alliance_name: character.alliance_name,
            alliance_ticker: character.alliance_ticker
          }
        end)

        {:ok, characters}

      error ->
        error
    end
  end

  @doc """
  Gets all characters grouped by user for a map.

  Groups characters by their user, identifying main characters.

  ## Parameters
    - map_id: The map ID

  ## Returns
    List of users with their characters
  """
  def get_user_characters(map_id) do
    case WandererApp.Map.get_system_characters(map_id, :all) do
      {:ok, characters} ->
        grouped = characters
        |> Enum.group_by(& &1.user_id)
        |> Enum.map(fn {user_id, user_chars} ->
          sorted_chars = Enum.sort_by(user_chars, & &1.inserted_at)
          main_char = List.first(sorted_chars)

          %{
            user_id: user_id,
            main_character: character_summary(main_char),
            characters: Enum.map(user_chars, &character_summary/1)
          }
        end)

        {:ok, grouped}

      error ->
        error
    end
  end

  # Private functions

  defp summarize_user_activity({_user_id, user_activities}) do
    representative_activity =
      user_activities
      |> Enum.max_by(fn act -> act.passages + act.connections + act.signatures end)

    total_passages = Enum.sum(Enum.map(user_activities, & &1.passages))
    total_connections = Enum.sum(Enum.map(user_activities, & &1.connections))
    total_signatures = Enum.sum(Enum.map(user_activities, & &1.signatures))

    %{
      character: character_summary(representative_activity.character),
      passages: total_passages,
      connections: total_connections,
      signatures: total_signatures,
      timestamp: representative_activity.timestamp
    }
  end

  defp character_summary(character) do
    %{
      id: character.id,
      eve_id: character.eve_id,
      name: character.name,
      corporation_id: character.corporation_id,
      corporation_name: character.corporation_name,
      corporation_ticker: character.corporation_ticker,
      alliance_id: character.alliance_id,
      alliance_name: character.alliance_name,
      alliance_ticker: character.alliance_ticker
    }
  end

  defp maybe_filter_kills_by_time(kills, nil), do: kills
  defp maybe_filter_kills_by_time(kills, hours_ago) when is_integer(hours_ago) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours_ago * 3600, :second)

    Enum.filter(kills, fn kill ->
      kill_time = kill["kill_time"]

      case kill_time do
        %DateTime{} = dt ->
          DateTime.compare(dt, cutoff) != :lt

        time when is_binary(time) ->
          case DateTime.from_iso8601(time) do
            {:ok, dt, _} -> DateTime.compare(dt, cutoff) != :lt
            _ -> false
          end

        _ ->
          false
      end
    end)
  end
end
