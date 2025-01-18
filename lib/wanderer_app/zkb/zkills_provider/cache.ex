defmodule WandererApp.Zkb.KillsProvider.KillsCache do
  @moduledoc """
  Provides helper functions for putting/fetching kill data
  in the Nebulex cache, so the calling code doesn't have to worry
  about the exact cache key structure or TTL logic.

  Also handles checks for "recently fetched" systems (timestamp caching)
  with a random jitter on expiry to avoid refetching all systems at once.
  """

  alias WandererApp.Cache

  @killmail_ttl :timer.hours(24)
  @system_kills_ttl :timer.hours(1)

  # Base (average) expiry of 15 minutes (900_000 ms).
  # We'll add +/- 10% jitter by default => ±90,000 ms.
  @base_full_fetch_expiry_ms 900_000
  @jitter_percent 0.1

  @doc """
  Store the killmail data, keyed by killmail_id, with a 24h TTL.
  """
  def put_killmail(killmail_id, kill_data) do
    Cache.put(killmail_key(killmail_id), kill_data, ttl: @killmail_ttl)
  end

  @doc """
  Fetch kills for `system_id` from the local cache only.
  Returns a list of killmail maps (could be empty).
  """
  def fetch_cached_kills(system_id) do
    system_id
    |> get_system_killmail_ids()
    |> Enum.map(&get_killmail/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Fetch the killmail data (if any) from the cache, by killmail_id.
  """
  def get_killmail(killmail_id) do
    Cache.get(killmail_key(killmail_id))
  end

  @doc """
  Adds `killmail_id` to the list of killmail IDs for the system
  if it’s not already present. The TTL is 24 hours.
  """
  def add_killmail_id_to_system_list(solar_system_id, killmail_id) do
    Cache.update(
      system_kills_list_key(solar_system_id),
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
    Cache.get(system_kills_list_key(solar_system_id)) || []
  end

  @doc """
  Increments the kill count for a system by `amount`. The TTL is 1 hour.
  """
  def incr_system_kill_count(solar_system_id, amount \\ 1) do
    Cache.incr(system_kills_key(solar_system_id), amount,
      default: 0,
      ttl: @system_kills_ttl
    )
  end

  @doc """
  Returns the integer count of kills for this system in the last hour, or 0.
  """
  def get_system_kill_count(solar_system_id) do
    Cache.get(system_kills_key(solar_system_id)) || 0
  end

  # ------------------------------------------------------------------
  # Jittered "recently fetched" logic
  # ------------------------------------------------------------------

  @doc """
  Check if the system is still in its "recently fetched" window.

  We store an `expires_at` timestamp (in ms). If `now < expires_at`, then
  this system is still considered "recently fetched".
  """
  def recently_fetched?(system_id) do
    case Cache.lookup(fetched_timestamp_key(system_id)) do
      {:ok, expires_at_ms} when is_integer(expires_at_ms) ->
        now_ms = current_time_ms()
        now_ms < expires_at_ms

      _ ->
        false
    end
  end

  @doc """
  Puts a jittered `expires_at` in the cache for `system_id`,
  marking it as fully fetched.

  We start with `@base_full_fetch_expiry_ms` (15 minutes by default),
  then add a random offset ±10% to avoid fetching everything at once.
  """
  def put_full_fetched_timestamp(system_id) do
    now_ms = current_time_ms()

    # e.g. if base is 900_000 => 15 min => ± 90_000 ms
    max_jitter = round(@base_full_fetch_expiry_ms * @jitter_percent)

    # random offset in the range [-max_jitter..+max_jitter]
    # For example, if max_jitter=90000 => offset is from -90000..+90000
    offset = :rand.uniform(2 * max_jitter + 1) - (max_jitter + 1)

    # add the offset to the base
    final_expiry_ms = @base_full_fetch_expiry_ms + offset
    # ensure at least 1 minute so we never expire *instantly*
    min_expiry_ms = 60_000
    final_expiry_ms = max(final_expiry_ms, min_expiry_ms)

    expires_at_ms = now_ms + final_expiry_ms
    Cache.put(fetched_timestamp_key(system_id), expires_at_ms)
  end

  @doc """
  Returns how many ms remain until this system's "recently fetched" window ends.
  If it's already expired (or doesn't exist), returns -1.
  """
  def fetch_age_ms(system_id) do
    now_ms = current_time_ms()

    case Cache.lookup(fetched_timestamp_key(system_id)) do
      {:ok, expires_at_ms} when is_integer(expires_at_ms) ->
        if now_ms < expires_at_ms do
          expires_at_ms - now_ms
        else
          -1
        end

      _ ->
        -1
    end
  end

  # ------------------------------------------------------------------
  # Private Helpers
  # ------------------------------------------------------------------

  defp killmail_key(killmail_id), do: "zkb_killmail_#{killmail_id}"
  defp system_kills_key(solar_system_id), do: "zkb_kills_#{solar_system_id}"
  defp system_kills_list_key(solar_system_id), do: "zkb_kills_list_#{solar_system_id}"

  defp fetched_timestamp_key(system_id), do: "zkb_system_fetched_at_#{system_id}"

  defp current_time_ms() do
    # Could use System.monotonic_time(:millisecond) if you prefer,
    # but System.os_time(:millisecond) is typically fine for "wall clock" checks
    DateTime.utc_now() |> DateTime.to_unix(:millisecond)
  end
end
