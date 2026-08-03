defmodule WandererApp.ExternalEvents.Discord.Matcher do
  @moduledoc """
  Decides whether a killmail involves a map's tracked pilots.

  The tracked-pilot set is cached per map because `WandererApp.Map.list_characters/1`
  hydrates every character on every call, which is far too expensive to run once
  per killmail.
  """

  require Logger

  @cache :discord_notification_cache
  # A backstop only: correctness comes from `invalidate_tracked/1`, fired by
  # every writer of `map.characters`. The TTL bounds the damage of a missed
  # invalidation to five minutes rather than the lifetime of the node.
  @ttl :timer.minutes(5)

  @doc """
  The EVE character ids tracked on `map_id`, as **integers**.

  `WandererApp.Api.Character`'s `eve_id` is a string; killmail payloads carry
  integers. The conversion happens here, once per cache build, so that no
  comparison site anywhere else has to think about it.

  Returns an empty `MapSet` if the map cannot be read (e.g. its server is not
  running). Callers must treat that as "no tracked pilots" and fall back to
  their conservative destination — this function never raises.
  """
  @spec tracked_eve_ids(String.t()) :: MapSet.t(integer())
  def tracked_eve_ids(map_id) do
    case Cachex.get(@cache, cache_key(map_id)) do
      {:ok, %MapSet{} = ids} ->
        ids

      _ ->
        build_and_cache(map_id)
    end
  end

  @doc """
  Drops the cached set for `map_id`. Must be called by every writer of
  `map.characters`.
  """
  @spec invalidate_tracked(String.t()) :: :ok
  def invalidate_tracked(map_id) do
    Cachex.del(@cache, cache_key(map_id))
    :ok
  end

  defp build_and_cache(map_id) do
    case build(map_id) do
      {:ok, ids} ->
        Cachex.put(@cache, cache_key(map_id), ids, ttl: @ttl)
        ids

      :error ->
        # Deliberately NOT cached: a transient failure must not be pinned for
        # the TTL, or every kill on this map is misrouted for five minutes.
        MapSet.new()
    end
  end

  defp build(map_id) do
    # `WandererApp.Map.list_characters/1` calls `get_map!/1`, which does not
    # raise when the map is absent from `:map_cache` — it logs and returns
    # `%{}`, which `list_characters/1` would silently read as "zero
    # characters" and we would (wrongly) cache as a valid empty set. Check
    # the map's presence explicitly via the non-raising `get_map/1` so a map
    # that isn't running is treated as a failed lookup, not a real empty map.
    case WandererApp.Map.get_map(map_id) do
      {:ok, _map} ->
        ids =
          map_id
          |> WandererApp.Map.list_characters()
          |> Enum.map(& &1.eve_id)
          |> Enum.map(&parse_eve_id/1)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        {:ok, ids}

      {:error, _reason} ->
        Logger.warning("[Discord.Matcher] Map #{map_id} is not running; no tracked pilots")
        :error
    end
  rescue
    error ->
      Logger.warning(
        "[Discord.Matcher] Failed to build tracked set for map #{map_id}: #{inspect(error)}"
      )

      :error
  end

  defp parse_eve_id(eve_id) when is_integer(eve_id), do: eve_id

  defp parse_eve_id(eve_id) when is_binary(eve_id) do
    case Integer.parse(eve_id) do
      {id, ""} ->
        id

      _ ->
        Logger.warning("[Discord.Matcher] Non-numeric eve_id skipped: #{inspect(eve_id)}")
        nil
    end
  end

  defp parse_eve_id(_), do: nil

  defp cache_key(map_id), do: "map:#{map_id}:tracked_eve_ids"
end
