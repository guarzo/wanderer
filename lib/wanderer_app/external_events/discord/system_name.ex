defmodule WandererApp.ExternalEvents.Discord.SystemName do
  @moduledoc """
  Resolves the system name shown on a killmail embed, per destination role.

  Map-local system names (`temporary_name`, then `custom_name`) appear on the
  system webhook only. The character webhook always shows the canonical EVE name.

  This is a privacy boundary, not a formatting preference. Corporations commonly
  keep the character-kill channel public so members without map access can see
  kills and losses. Map-local chain naming in that channel leaks the map's
  private naming to people who were deliberately not granted map access, and a
  message posted to a public channel cannot be recalled.

  Resolution order on the system webhook: `temporary_name` -> `custom_name` ->
  canonical name.

  This rule looks like an inconsistency and will invite a "fix." It gets a
  regression test named for the constraint, and this paragraph is the reason a
  reviewer should find when they go looking.
  """

  require Logger

  alias WandererApp.Api.MapSystem

  @type role :: :system | :character | :route

  @doc """
  The system name to render for `role`.

  Returns `nil` when no name can be resolved at all; the formatter renders
  "Unknown system" in that case rather than guessing.
  """
  @spec display_name(String.t(), integer(), role()) :: String.t() | nil
  def display_name(_map_id, solar_system_id, :character), do: canonical_name(solar_system_id)

  def display_name(map_id, solar_system_id, :system) do
    map_local_name(map_id, solar_system_id) || canonical_name(solar_system_id)
  end

  # Route alerts carry the same map-local-names privacy boundary as :system:
  # the whole message is the map's own chain, so the resolution order matches
  # :system exactly rather than falling through to :character's canonical-only
  # behavior.
  def display_name(map_id, solar_system_id, :route) do
    map_local_name(map_id, solar_system_id) || canonical_name(solar_system_id)
  end

  defp map_local_name(map_id, solar_system_id)
       when is_binary(map_id) and is_integer(solar_system_id) do
    # NOTE: `read_by_map_and_solar_system`, not `by_map_id_and_solar_system_id`.
    # The latter targets the primary `:read` action, whose
    # `FilterSystemsByActorMap` preparation filters to nothing when there is no
    # actor in context — and there never is one here, because the dispatcher
    # runs from a GenServer. It would return nil for every system and silently
    # collapse the two roles into one.
    case MapSystem.read_by_map_and_solar_system(%{
           map_id: map_id,
           solar_system_id: solar_system_id
         }) do
      {:ok, %{} = system} ->
        present(system.temporary_name) || present(system.custom_name)

      _ ->
        nil
    end
  rescue
    error ->
      Logger.debug(fn ->
        "[SystemName] map-local lookup failed for #{map_id}/#{solar_system_id}: #{inspect(error)}"
      end)

      nil
  end

  defp map_local_name(_map_id, _solar_system_id), do: nil

  defp canonical_name(solar_system_id) do
    case WandererApp.CachedInfo.get_system_static_info(solar_system_id) do
      {:ok, %{solar_system_name: name}} -> present(name)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
end
