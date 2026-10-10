defmodule WandererApp.Map.TradeHubTags do
  @moduledoc """
  Auto-tags highsec systems with their gate-jump distance to the nearest major
  trade hub, as `<jumps><letter>` (e.g. `"5-J"`), per
  github.com/elboaf/wanderer#3.

  Rules:
  - Only highsec systems are tagged (threshold shared with the route-alert
    evaluator's deliberately-cautious 0.45 — see
    `WandererApp.Map.RouteAlert.Evaluator.highsec_threshold/0`).
  - Closest hub wins; ties break Jita > Dodixie > Amarr > Hek > Rens.
  - More than `@max_jumps` (10) from every hub leaves the tag untouched. So
    does an existing (e.g. manually-set) tag: we only populate, never
    overwrite.
  - Transient failures (ESI rate-limit storms, solver outages, cache misses)
    are retried with backoff, so a system added during a storm eventually gets
    its tag without anyone noticing the storm. Deterministic non-results (lowsec,
    out of range, manual tag) are terminal and never retried.
  """

  require Logger

  # In tie-break preference order (issue #3 rule 3). IDs match
  # priv/repo/data/route_by_systems/trade_hubs.json.
  @trade_hubs [
    {30_000_142, "J"},
    {30_002_659, "D"},
    {30_002_187, "A"},
    {30_002_053, "H"},
    {30_002_510, "R"}
  ]

  @max_jumps 10

  # Transient failures (ESI rate-limit storms, solver outages) are retried with
  # backoff: three attempts, ~5s then ~30s apart. Long enough to ride out a
  # typical rate-limit window, short enough that the tag still lands while the
  # user is looking at the map. Terminal outcomes (:skip, lowsec, manual tag)
  # are never retried — they'd fail identically forever.
  @retry_backoffs_ms [5_000, 30_000]

  def trade_hubs, do: @trade_hubs
  def max_jumps, do: @max_jumps

  # Test seam: tests swap this to skip the real backoff sleeps. Not
  # Application env — the retry cadence is a code constant, not operator config.
  defp sleep_fn, do: Application.get_env(:wanderer_app, :trade_hub_tags_sleep_fn, &Process.sleep/1)

  @doc """
  Computes and writes the tag for `solar_system_id` on `map_id`. Fire-and-forget:
  transient failures are retried with backoff, deterministic non-results are
  terminal, and the tag is written only when the system is highsec, within
  `max_jumps` of some hub, and its tag is empty.
  """
  def maybe_tag_system(map_id, solar_system_id) do
    case compute_tag(map_id, solar_system_id) do
      {:ok, tag} ->
        write_label(map_id, solar_system_id, tag)

      :skip ->
        :ok

      {:error, :terminal, reason} ->
        Logger.warning(
          "[TradeHubTags] Not tagging system #{solar_system_id} on map #{map_id}: #{inspect(reason)}"
        )

        :ok

      {:error, :transient, reason} ->
        retry(map_id, solar_system_id, @retry_backoffs_ms, reason)
    end
  end

  defp retry(map_id, solar_system_id, [delay_ms | rest], last_reason) do
    Logger.warning(
      "[TradeHubTags] Transient failure tagging system #{solar_system_id} on map #{map_id} " <>
        "(#{inspect(last_reason)}), retrying in #{delay_ms}ms"
    )

    sleep_fn().(delay_ms)

    case compute_tag(map_id, solar_system_id) do
      {:ok, tag} ->
        write_label(map_id, solar_system_id, tag)

      :skip ->
        :ok

      {:error, :terminal, reason} ->
        Logger.warning(
          "[TradeHubTags] Not tagging system #{solar_system_id} on map #{map_id}: #{inspect(reason)}"
        )

        :ok

      {:error, :transient, reason} ->
        retry(map_id, solar_system_id, rest, reason)
    end
  end

  defp retry(map_id, solar_system_id, [], last_reason) do
    Logger.error(
      "[TradeHubTags] Giving up tagging system #{solar_system_id} on map #{map_id} " <>
        "after #{length(@retry_backoffs_ms) + 1} attempts: #{inspect(last_reason)}"
    )

    :ok
  end

  defp compute_tag(map_id, solar_system_id) do
    with {:ok, %{security: security}} <- system_info(solar_system_id) |> classify(:system_info),
         {:ok, security_value} <- parse_security(security) |> classify(:invalid_security),
         true <-
           security_value >= WandererApp.Map.RouteAlert.Evaluator.highsec_threshold()
           |> classify(:not_highsec),
         {:ok, %{routes: routes}} <-
           WandererApp.Map.Routes.find(
             map_id,
             Enum.map(@trade_hubs, fn {id, _letter} -> Integer.to_string(id) end),
             Integer.to_string(solar_system_id),
             %{},
             false
           )
           |> classify(:route_lookup),
         {:ok, tag} <- pick_tag(routes) do
      {:ok, tag}
    else
      # `pick_tag/1` returning :skip means "no hub in range" — that's a
      # deterministic no, not a failure to retry.
      :skip -> :skip
      false -> {:error, :terminal, :not_highsec}
      {:error, _kind, _reason} = failure -> failure
    end
  end

  # Wraps a step result as `{:error, kind, reason}` so the retry loop knows
  # which failures are worth repeating. Terminal kinds: the outcome can't
  # change on a retry, because the inputs are static (security class) or
  # user-owned (an existing label).
  defp classify({:ok, value}, _kind), do: {:ok, value}
  defp classify(true, _kind), do: true

  defp classify({:error, :not_found}, :system_info),
    do: {:error, :terminal, :system_info_not_found}

  defp classify({:error, :invalid_security} = error, :invalid_security),
    do: {:error, :terminal, error}

  defp classify(false, :not_highsec), do: {:error, :terminal, :not_highsec}

  defp classify({:error, reason}, kind), do: {:error, :transient, {kind, reason}}

  defp write_label(map_id, solar_system_id, tag) do
    labels =
      case WandererApp.MapSystemRepo.get_by_map_and_solar_system_id(map_id, solar_system_id) do
        {:ok, system} -> system.labels
        _ -> nil
      end

    # The distance lives in `labels.customLabel` — the same slot the map
    # client's System settings "Tag" field edits (`LabelsManager`), rendered
    # as trailing text after the system name on the zoo node. Merge into the
    # existing label JSON so user labels survive; don't touch the `tag`
    # attribute (that's the Occupied badge).
    merged_labels =
      case labels do
        labels when is_binary(labels) and labels != "" ->
          case Jason.decode(labels) do
            {:ok, %{} = map} -> map |> Map.put("customLabel", tag) |> Jason.encode!()
            _ -> Jason.encode!(%{customLabel: tag, labels: String.split(labels, ",")})
          end

        _ ->
          Jason.encode!(%{customLabel: tag, labels: []})
      end

    WandererApp.Map.Server.update_system_labels(map_id, %{
      solar_system_id: solar_system_id,
      labels: merged_labels
    })

    :ok
  end
        case WandererApp.MapSystemRepo.get_by_map_and_solar_system_id(map_id, solar_system_id) do
          {:ok, system} -> system.labels
          _ -> nil
        end

      # The distance lives in `labels.customLabel` — the same slot the map
      # client's System settings "Tag" field edits (`LabelsManager`), rendered
      # as trailing text after the system name on the zoo node. Merge into the
      # existing label JSON so user labels survive; don't touch the `tag`
      # attribute (that's the Occupied badge).
      merged_labels =
        case labels do
          labels when is_binary(labels) and labels != "" ->
            case Jason.decode(labels) do
              {:ok, %{} = map} -> map |> Map.put("customLabel", tag) |> Jason.encode!()
              _ -> Jason.encode!(%{customLabel: tag, labels: String.split(labels, ",")})
            end

          _ ->
            Jason.encode!(%{customLabel: tag, labels: []})
        end

      WandererApp.Map.Server.update_system_labels(map_id, %{
        solar_system_id: solar_system_id,
        labels: merged_labels
      })

      :ok
    else
      false ->
        :ok

      :skip ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[TradeHubTags] Skipping tag for system #{solar_system_id} on map #{map_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Pure tag selection over normalized `Routes.find/5` route maps
  (`%{destination, systems, success}` — `systems` excludes the origin).

  Returns `{:ok, "<jumps><letter>"}` for the closest successful hub, `:skip`
  when nothing qualifies (no successful route, or every distance above
  `max_jumps`). Ties among equal jump counts follow the `@trade_hubs` order.
  """
  @spec pick_tag([map()]) :: {:ok, String.t()} | :skip
  def pick_tag(routes) do
    successful =
      Enum.filter(routes, fn
        %{success: true, systems: systems, destination: destination} when is_list(systems) ->
          Enum.any?(@trade_hubs, fn {id, _letter} -> id == destination end)

        _ ->
          false
      end)

    case successful do
      [] ->
        :skip

      _ ->
        hub_index = Map.new(@trade_hubs |> Enum.with_index(fn {id, _letter}, i -> {id, i} end))

        %{destination: destination, systems: systems} =
          Enum.min_by(successful, fn %{destination: destination, systems: systems} ->
            {length(systems), Map.get(hub_index, destination, 999)}
          end)

        jumps = length(systems)

        if jumps <= @max_jumps do
          {:ok, "#{jumps}-#{hub_letter(destination)}"}
        else
          :skip
        end
    end
  end

  defp hub_letter(destination) do
    {_, letter} = Enum.find(@trade_hubs, fn {id, _} -> id == destination end)
    letter
  end

  defp system_info(solar_system_id) do
    case WandererApp.CachedInfo.get_system_static_info(solar_system_id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, info} -> {:ok, info}
      error -> error
    end
  end

  # Same strict parse as `RouteAlert.Evaluator.parse_security/1` — only a fully
  # consumed parse counts, so a corrupt record can't read as highsec.
  defp parse_security(security) when is_float(security), do: {:ok, security}
  defp parse_security(security) when is_integer(security), do: {:ok, security * 1.0}

  defp parse_security(security) when is_binary(security) do
    case Float.parse(String.trim(security)) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_security}
    end
  end

  defp parse_security(_security), do: {:error, :invalid_security}
end
