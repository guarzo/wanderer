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

  # Throttle for the flat-payload warning below. Shares `@cache` because the
  # entry is the same kind of thing: derived, per-node, and safe to lose.
  @divergence_log_key "discord:attacker-divergence-warned"
  @divergence_log_interval :timer.minutes(5)

  @doc """
  The EVE character ids tracked on `map_id`, as **integers**.

  Membership rule: every character registered on the map, whether or not
  their location tracker is running.

  `WandererApp.Api.Character`'s `eve_id` is a string; killmail payloads carry
  integers. The conversion happens here, once per cache build, so that no
  comparison site anywhere else has to think about it.

  Returns `:unavailable` — never an empty `MapSet` — if the map cannot be read
  (e.g. its server is not running, or the cache is down). An empty set is a
  factual claim that nobody is tracked, and `involvement/3` acts on it: every
  kill would be `:not_involved`, which is what *enables* the `excluded_systems`
  and `wh_only` filters. With `wh_only` defaulting to true, a moment of cache
  unavailability would therefore drop every k-space kill on the map silently.
  `:unavailable` is propagated into an `:unknown` verdict instead, which
  bypasses those filters and delivers to the system webhook.

  This function never raises.
  """
  @spec tracked_eve_ids(String.t()) :: MapSet.t(integer()) | :unavailable
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
    # `:unavailable` fallback safe for every caller.
    error ->
      Logger.warning(
        "[Discord.Matcher] tracked-set cache unavailable for map #{map_id}: #{inspect(error)}"
      )

      :unavailable
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
        # `:unavailable`, not an empty set — see `tracked_eve_ids/1`.
        :unavailable
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

  @type verdict ::
          {:involved, :victim} | {:involved, :attacker} | :not_involved | :unknown

  @doc """
  Decides whether a killmail is one the character channel is for.

  ## Which criterion applies

  `focus_corp_ids` **replaces** the tracked-character check rather than widening
  it. When it is non-empty, membership of one of those corporations is the only
  thing that sends a kill to the character channel; the map's tracked pilots are
  not consulted at all, and their kills follow the ordinary system rules. When
  it is empty, the map's tracked characters decide, which is the original
  behaviour and the default.

  It is deliberately one criterion or the other. A union would mean that turning
  the corporation filter on could only ever *add* notifications, so an admin who
  wants "the character channel is for my corp, not for whoever happens to be on
  the map" would have no way to express it.

  ## Ordering

  Victim checks precede attacker checks, so a kill where both sides match
  renders as a *loss*. Losses are the more urgent signal.

  ## Verdicts

  `:not_involved` is a positive finding — we looked and this kill is not ours.
  It is what *enables* the `excluded_systems` and `wh_only` filters in
  `Router`, so it must never be used to mean "could not tell". That case is
  `:unknown`, which bypasses those filters and delivers to the system webhook.
  """
  @spec involvement(map(), MapSet.t(integer()) | :unavailable, [integer()]) :: verdict()
  def involvement(kill, tracked_eve_ids, focus_corp_ids) when is_list(focus_corp_ids) do
    if focus_corp_ids == [] do
      character_involvement(kill, tracked_eve_ids)
    else
      corporation_involvement(kill, focus_corp_ids)
    end
  end

  # No tracked set to compare against. Answering `:not_involved` here would
  # assert that none of the map's pilots were in this fight, which is exactly
  # what we failed to determine — and under the default `wh_only` that assertion
  # drops the kill. Note the corporation-filter path above never reaches this:
  # it does not need the tracked set, so a cache outage does not degrade it.
  defp character_involvement(_kill, :unavailable), do: :unknown

  defp character_involvement(kill, tracked_eve_ids) do
    if MapSet.member?(tracked_eve_ids, parse_eve_id(kill["victim_char_id"])) do
      {:involved, :victim}
    else
      match_attackers(kill, "attacker_char_ids", &MapSet.member?(tracked_eve_ids, &1))
    end
  end

  defp corporation_involvement(kill, focus_corp_ids) do
    if parse_eve_id(kill["victim_corp_id"]) in focus_corp_ids do
      {:involved, :victim}
    else
      match_attackers(kill, "attacker_corp_ids", &(&1 in focus_corp_ids))
    end
  end

  # ABSENT is not EMPTY. Nested-format payloads always carry the attacker keys
  # (possibly as empty lists); flat-format payloads omit them entirely. Treating
  # a missing key as `[]` would assert "there were no attackers of ours", which
  # we do not know — and the assertion is not free: it means a flat-format
  # payload can only ever produce a loss, so *kills* by tracked pilots in
  # k-space were dropped outright under the default `wh_only`. Reporting
  # `:unknown` costs a kill in the system channel instead of no kill at all.
  #
  # `attacker_char_ids` / `attacker_corp_ids` are normalized to integers by
  # `collect_ids/2` (message_handler.ex) at flatten time — but only on the
  # *nested* branch (reached via `add_attacker_identity_data/2`). The flat
  # branch returns the payload unmodified and applies no key whitelist and no
  # coercion, so if a flat payload ever does carry these keys as binaries
  # (nothing today enforces that it can't), `parse_eve_id/1` is the backstop.
  # It passes integers straight through, so this costs nothing on the
  # already-normalized nested path.
  defp match_attackers(kill, key, match_fun) do
    if Map.has_key?(kill, "attacker_char_ids") or Map.has_key?(kill, "attacker_corp_ids") do
      if Enum.any?(kill[key] || [], &match_fun.(parse_eve_id(&1))),
        do: {:involved, :attacker},
        else: :not_involved
    else
      log_attacker_divergence(kill)
      :unknown
    end
  end

  # At warning, not debug: this is now the reason a kill lands in the system
  # channel instead of the character channel, which is user-visible and worth
  # explaining. Throttled to one line per interval because it fires per kill,
  # and if flat payloads are the norm on some feed it would otherwise be the
  # only thing in the log.
  defp log_attacker_divergence(kill) do
    if divergence_log_allowed?() do
      Logger.warning(
        "[Discord] killmail #{kill["killmail_id"]}: attacker data absent from payload; " <>
          "involvement decided on the victim alone, so kills by tracked pilots are " <>
          "reported as :unknown and delivered to the system webhook. " <>
          "(throttled to one line per #{div(@divergence_log_interval, 60_000)}m)"
      )
    end

    :ok
  end

  @doc false
  # Exposed only so tests can clear the throttle between cases. A warning
  # suppressed by a previous test would make these assertions depend on run
  # order, which is exactly the kind of flake that gets a real assertion deleted.
  def divergence_log_key, do: @divergence_log_key

  defp divergence_log_allowed?() do
    case Cachex.get(@cache, @divergence_log_key) do
      {:ok, nil} ->
        Cachex.put(@cache, @divergence_log_key, true, ttl: @divergence_log_interval)
        true

      _ ->
        false
    end
  rescue
    # The cache is the throttle, not the signal. If it is unavailable, log —
    # suppressing a warning because the suppression mechanism broke is the
    # wrong direction, and a cache that is down is itself already warning here.
    _ -> true
  end
end
