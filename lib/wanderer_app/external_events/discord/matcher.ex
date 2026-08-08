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

  Membership rule: every character registered on the map, whether or not
  their location tracker is running.

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
  rescue
    # `Cachex.get/2` and the `Cachex.put/4` in `build_and_cache/1` RAISE against
    # an unstarted cache rather than returning an error tuple — the same Cachex
    # contract `invalidate_tracked/1` below rescues. This is the read side, and
    # its caller is `DiscordDispatcher.partition/3`: letting the raise through
    # would lose the entire killmail batch, not just this map's tracked set.
    # The documented "never raises" contract above is what makes the
    # conservative empty-MapSet fallback safe for every caller.
    error ->
      Logger.warning(
        "[Discord.Matcher] tracked-set cache unavailable for map #{map_id}: #{inspect(error)}"
      )

      MapSet.new()
  end

  @doc """
  Drops the cached set for `map_id`. Must be called by every writer of
  `map.characters`.
  """
  @spec invalidate_tracked(String.t()) :: :ok
  def invalidate_tracked(map_id) do
    # Bumping the version inside the same transaction as the delete is what
    # makes the delete stick. Without it, a build already in flight would
    # `Cachex.put/4` its pre-delete set back afterwards and the stale entry
    # would survive the full TTL — the exact failure the invalidation exists to
    # prevent. The build re-reads the version under this same lock and discards
    # itself if it changed.
    Cachex.transaction(@cache, [cache_key(map_id), version_key(map_id)], fn worker ->
      Cachex.incr(worker, version_key(map_id), 1)
      Cachex.del(worker, cache_key(map_id))
    end)

    :ok
  rescue
    # Same contract as `DiscordDispatcher.invalidate_cache/1`, which drops the
    # same cache: Cachex RAISES against an unstarted cache rather than
    # returning an error tuple. Both are called from core map writes
    # (`WandererApp.Map`'s three writers of `characters:`), so a context without
    # the cache must not turn adding a character into a crash.
    _ -> :ok
  end

  @doc false
  # Public only as a test seam, and only for the `build_fun` argument.
  #
  # The compare-and-set below is the whole point of `version_key/1`, and it can
  # only be exercised by an `invalidate_tracked/1` that lands *after* the
  # version read and *before* the write. A real `build/1` completes in
  # microseconds and holds no lock a test could queue behind, so there is no
  # way to hit that window from the outside; injecting the build makes the
  # interleaving exact instead of hoping for it. Production always calls
  # `build_and_cache/1`.
  def build_and_cache(map_id, build_fun \\ &build/1) do
    # Read the version BEFORE building. `build/1` is slow (it hydrates every
    # character on the map), so it deliberately runs outside the lock; the
    # version read here plus the re-check in `cache_put/3` is what turns that
    # into a compare-and-set rather than a blind write.
    version = read_version(map_id)

    case build_fun.(map_id) do
      {:ok, ids} ->
        cache_put(map_id, ids, version)
        ids

      :error ->
        # Deliberately NOT cached: a transient failure must not be pinned for
        # the TTL, or every kill on this map is misrouted for five minutes.
        MapSet.new()
    end
  end

  defp read_version(map_id) do
    case Cachex.get(@cache, version_key(map_id)) do
      {:ok, version} when is_integer(version) -> version
      _ -> 0
    end
  end

  # Rescued separately from `tracked_eve_ids/1` rather than under its rescue:
  # the set has already been built at this point, so a cache that cannot store
  # it must still not cost us the answer. Failing to cache is a performance
  # problem; returning an empty set would be a routing error.
  #
  # The write is conditional on the version being unchanged since the build
  # started. An `invalidate_tracked/1` that landed mid-build has already bumped
  # it, so this build's set is known-stale and is dropped rather than written.
  # The caller still returns it for THIS killmail — it was current when the
  # build began — but the next killmail rebuilds instead of reading it back.
  defp cache_put(map_id, ids, version) do
    Cachex.transaction(@cache, [cache_key(map_id), version_key(map_id)], fn worker ->
      if read_version_with(worker, map_id) == version do
        Cachex.put(worker, cache_key(map_id), ids, ttl: @ttl)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp read_version_with(worker, map_id) do
    case Cachex.get(worker, version_key(map_id)) do
      {:ok, version} when is_integer(version) -> version
      _ -> 0
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
          # `list_characters/1` can return `nil` entries for character ids on
          # the map whose backing record no longer resolves
          # (`Character.get_map_character!/2` logs and returns `nil` rather
          # than raising). One stale id must cost one pilot, not the whole
          # map's set.
          |> Enum.reject(&is_nil/1)
          |> Enum.map(& &1.eve_id)
          |> Enum.map(&parse_eve_id/1)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        {:ok, ids}

      {:error, _reason} ->
        # :debug, not :warning. The failure is deliberately not cached (see
        # `build_and_cache/1`), so this line runs once per killmail — a busy map
        # that is briefly absent from `:map_cache` would flood the log at
        # warning level and bury real problems. The routing consequence is
        # already conservative and visible in the notifications themselves.
        Logger.debug(fn ->
          "[Discord.Matcher] Map #{map_id} is not running; no tracked pilots"
        end)

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

  # Intentionally never expires. It is a monotonic counter, not data: if it
  # aged out while a build held an older value, that build's stale set would
  # compare equal to the reset counter and be written back.
  defp version_key(map_id), do: "map:#{map_id}:tracked_eve_ids:version"

  @type verdict :: {:involved, :victim} | {:involved, :attacker} | :not_involved

  @doc """
  Decides whether a killmail involves this map's own pilots.

  Order is load-bearing (spec section 3): victim checks precede attacker checks,
  so a kill where both sides are tracked renders as a *loss*. Losses are the
  more urgent signal.

  `focus_corp_ids` widens "tracked" rather than acting as a separate routing
  concept, so corporation focus earns the same colouring and the same routing
  carve-outs as character tracking.
  """
  @spec involvement(map(), MapSet.t(integer()), [integer()]) :: verdict()
  def involvement(kill, tracked_eve_ids, focus_corp_ids) when is_list(focus_corp_ids) do
    cond do
      MapSet.member?(tracked_eve_ids, parse_eve_id(kill["victim_char_id"])) ->
        {:involved, :victim}

      parse_eve_id(kill["victim_corp_id"]) in focus_corp_ids ->
        {:involved, :victim}

      attacker_match?(kill, tracked_eve_ids, focus_corp_ids) ->
        {:involved, :attacker}

      true ->
        :not_involved
    end
  end

  # ABSENT is not EMPTY. Nested-format payloads always carry the attacker keys
  # (possibly as empty lists); flat-format payloads omit them entirely. Treating
  # a missing key as `[]` would assert "there were no tracked attackers", which
  # we do not know. This is a compatibility behaviour for a payload shape we
  # cannot enrich, not a normalization: admitting the data is unknown is better
  # than pretending it is empty.
  #
  # Victim matching still runs normally either way — `victim_char_id` and
  # `victim_corp_id` exist in both shapes. When the victim does not match and
  # the attacker data is unknown, the verdict is `:not_involved`, which routes
  # to the system webhook: the same conservative destination a matching-cache
  # failure produces.
  #
  # `attacker_char_ids` / `attacker_corp_ids` are normalized to integers by
  # `collect_ids/2` (message_handler.ex) at flatten time — but only on the
  # *nested* branch (reached via `add_attacker_identity_data/2`). The flat
  # branch returns the payload unmodified and applies no key whitelist and no
  # coercion, so if a flat payload ever does carry these keys as binaries
  # (nothing today enforces that it can't), `parse_eve_id/1` is the backstop.
  # It passes integers straight through, so this costs nothing on the
  # already-normalized nested path.
  defp attacker_match?(kill, tracked_eve_ids, focus_corp_ids) do
    if Map.has_key?(kill, "attacker_char_ids") or Map.has_key?(kill, "attacker_corp_ids") do
      Enum.any?(
        kill["attacker_char_ids"] || [],
        &MapSet.member?(tracked_eve_ids, parse_eve_id(&1))
      ) or
        Enum.any?(kill["attacker_corp_ids"] || [], &(parse_eve_id(&1) in focus_corp_ids))
    else
      log_attacker_divergence(kill)
      false
    end
  end

  # Logged once per occurrence, at debug, with the killmail id. If flat-format
  # payloads turn out to be common in production this is visible in the logs
  # rather than inferred from notifications that never arrived.
  defp log_attacker_divergence(kill) do
    Logger.debug(fn ->
      "[Discord] killmail #{kill["killmail_id"]}: attacker data absent from payload; " <>
        "involvement decided on the victim alone"
    end)
  end
end
