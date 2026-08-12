defmodule WandererApp.ExternalEvents.Discord.RouteScout do
  @moduledoc """
  Resolves the character to credit on a route alert, from the map audit trail.

  ## Why the audit trail and not `MapSystem`

  `MapSystem` cannot answer "who added this, and when". `added_at` is written
  by nothing in `lib/` (and is in `default_accept`, so an API caller could set
  it to anything); `inserted_at` records the first-ever add, because `:upsert`
  reuses the row via `upsert_identity :map_solar_system_id`; `updated_at`
  tracks any edit at all; and there is no character relationship on the
  resource. The `user_activity_v1` rows are the only record carrying a map
  change and its author together.

  ## Why recency, and why both event types

  Route alerts are re-evaluated on five event types
  (`DiscordDispatcher.do_dispatch/2`), only two of which are adds. A route can
  open because someone cleared a crit label on an existing connection, or
  linked two systems mapped hours ago. Crediting "the newest system on the
  path" would then put a name and a portrait on work that person did not do,
  in a channel their corp reads — so the winning row must be an *add*, and it
  must be recent. Nothing recent enough means nobody is named.

  ## Best-effort by construction

  Every failure returns `nil` and the alert posts with its plain author line.
  This module must never raise into `RouteWatcher`: an attribution problem is
  not worth losing a delivery over.
  """

  require Logger

  alias WandererApp.Api.UserActivity

  @attribution_window_ms 15 * 60 * 1000

  @type scout :: %{name: String.t(), eve_id: String.t()}

  @spec attribution_window_ms() :: pos_integer()
  def attribution_window_ms, do: @attribution_window_ms

  @spec resolve(binary(), [integer()]) :: scout() | nil
  def resolve(map_id, path) when is_binary(map_id) and is_list(path) and path != [] do
    since = DateTime.add(DateTime.utc_now(), -@attribution_window_ms, :millisecond)

    case UserActivity.read_route_attribution(%{
           map_id: map_id,
           since: since,
           system_event_data: system_event_data(path),
           connection_event_data: connection_event_data(path)
         }) do
      {:ok, [%{character: %{name: name, eve_id: eve_id}}]}
      when is_binary(name) and is_binary(eve_id) ->
        %{name: name, eve_id: eve_id}

      # No row, a row whose character_id was nil (systems added through the API
      # record no character — `SecurityAudit.track_map_event/2` no-ops without
      # both character_id and user_id), or a deleted character.
      _ ->
        nil
    end
  rescue
    error ->
      Logger.debug(fn ->
        "[RouteScout] attribution lookup failed for map #{inspect(map_id)}: #{inspect(error)}"
      end)

      nil
  end

  def resolve(_map_id, _path), do: nil

  # String keys, matching what is actually stored: `sanitize_metadata/1`
  # stringifies every key before `Jason.encode!/1`. Two maps with identical key
  # sets encode to identical JSON, which is what makes an exact match sound.
  defp system_event_data(path) do
    Enum.map(path, &Jason.encode!(%{"solar_system_id" => &1}))
  end

  # Both orientations per adjacent pair: the recorded source/target follow the
  # direction the character jumped, not the direction the solved route runs.
  defp connection_event_data(path) do
    path
    |> Enum.zip(Enum.drop(path, 1))
    |> Enum.flat_map(fn {a, b} ->
      [
        Jason.encode!(%{"solar_system_source_id" => a, "solar_system_target_id" => b}),
        Jason.encode!(%{"solar_system_source_id" => b, "solar_system_target_id" => a})
      ]
    end)
  end
end
