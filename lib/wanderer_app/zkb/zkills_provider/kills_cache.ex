defmodule WandererApp.Zkb.KillsProvider.KillsCache do
  @moduledoc """
  Provides helper functions for putting/fetching kill data
  """

  require Logger
  alias WandererApp.Cache
  alias WandererApp.Zkb.Key

  @killmail_ttl :timer.hours(24)
  @system_kills_ttl :timer.hours(1)

  # Base (average) expiry of 15 minutes for "recently fetched" systems
  @base_full_fetch_expiry_ms 900_000
  @jitter_percent 0.1

  def killmail_ttl, do: @killmail_ttl
  def system_kills_ttl, do: @system_kills_ttl

  @doc """
  Store the killmail data, keyed by killmail_id, with a 24h TTL.
  """
  def put_killmail(killmail_id, kill_data) do
    Logger.debug(fn -> "[KillsCache] Storing killmail => killmail_id=#{killmail_id}" end)
    Cache.put(Key.killmail_key(killmail_id), kill_data, ttl: @killmail_ttl)
  end

  @doc """
  Fetch kills for `system_id` from the local cache only.
  Returns a list of killmail maps (could be empty).
  """
  def fetch_cached_kills(system_id) do
    killmail_ids = get_system_killmail_ids(system_id)
    Logger.debug(fn -> "[KillsCache] fetch_cached_kills => system_id=#{system_id}, count=#{length(killmail_ids)}" end)

    killmail_ids
    |> Enum.map(&get_killmail/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Fetch cached kills for multiple solar system IDs.
  Returns a map of `%{ solar_system_id => list_of_kills }`.
  """
  def fetch_cached_kills_for_systems(system_ids) when is_list(system_ids) do
    Enum.reduce(system_ids, %{}, fn sid, acc ->
      kills_list = fetch_cached_kills(sid)
      Map.put(acc, sid, kills_list)
    end)
  end

  @doc """
  Fetch the killmail data (if any) from the cache, by killmail_id.
  """
  def get_killmail(killmail_id) do
    Cache.get(Key.killmail_key(killmail_id))
  end

  @doc """
  Adds `killmail_id` to the list of killmail IDs for the system
  if it's not already present. The TTL is 24 hours.
  """
  def add_killmail_id_to_system_list(solar_system_id, killmail_id) do
    Cache.update(
      Key.system_kills_list_key(solar_system_id),
      [],
      fn existing_list ->
        existing_list = existing_list || []
        if killmail_id in existing_list do
          existing_list
        else
          existing_list ++ [killmail_id]
        end
      end,
      ttl: @killmail_ttl
    )
  end

  @doc """
  Returns a list of killmail IDs for the given system, or [] if none.
  """
  def get_system_killmail_ids(solar_system_id) do
    Cache.get(Key.system_kills_list_key(solar_system_id)) || []
  end

  @doc """
  Increments the kill count for a system by `amount`. The TTL is 1 hour.
  """
  def incr_system_kill_count(solar_system_id, amount \\ 1) do
    Cache.incr(
      Key.system_kills_key(solar_system_id),
      amount,
      default: 0,
      ttl: @system_kills_ttl
    )
  end

  @doc """
  Returns the integer count of kills for this system in the last hour, or 0.
  """
  def get_system_kill_count(solar_system_id) do
    Cache.get(Key.system_kills_key(solar_system_id)) || 0
  end

  @doc """
  Check if the system is still in its "recently fetched" window.
  We store an `expires_at` timestamp (in ms). If `now < expires_at`,
  this system is still considered "recently fetched".
  """
  def recently_fetched?(system_id) do
    case Cache.lookup(Key.fetched_timestamp_key(system_id)) do
      {:ok, expires_at_ms} when is_integer(expires_at_ms) ->
        now_ms = Key.current_time_ms()
        now_ms < expires_at_ms

      _ ->
        false
    end
  end

  @doc """
  Puts a jittered `expires_at` in the cache for `system_id`,
  marking it as fully fetched for ~15 minutes (+/- 10%).
  """
  def put_full_fetched_timestamp(system_id) do
    base_expiry = @base_full_fetch_expiry_ms
    jitter = trunc(base_expiry * @jitter_percent)
    jittered_expiry = base_expiry + :rand.uniform(jitter * 2) - jitter
    expires_at = Key.current_time_ms() + jittered_expiry

    Cache.put(Key.fetched_timestamp_key(system_id), expires_at, ttl: jittered_expiry)
  end
end
