defmodule WandererApp.MapCharacterSettingsRepo do
  use WandererApp, :repository

  require Logger

  def get(map_id, character_id) do
    case WandererApp.Api.MapCharacterSettings.read_by_map_and_character(%{
           map_id: map_id,
           character_id: character_id
         }) do
      {:ok, settings} when not is_nil(settings) ->
        {:ok, settings}

      _ ->
        WandererApp.Api.MapCharacterSettings.create(%{
          character_id: character_id,
          map_id: map_id,
          tracked: false
        })
    end
  end

  def create(settings) do
    WandererApp.Api.MapCharacterSettings.create(settings)
  end

  def update(map_id, character_id, updated_settings) do
    case get(map_id, character_id) do
      {:ok, settings} when not is_nil(settings) ->
        settings
        |> WandererApp.Api.MapCharacterSettings.update(updated_settings)

      _ ->
        {:ok, nil}
    end
  end

  def get_tracked_by_map_filtered(map_id, character_ids),
    do:
      WandererApp.Api.MapCharacterSettings.tracked_by_map_filtered(%{
        map_id: map_id,
        character_ids: character_ids
      })

  def get_by_map_filtered(map_id, character_ids),
    do:
      WandererApp.Api.MapCharacterSettings.by_map_filtered(%{
        map_id: map_id,
        character_ids: character_ids
      })

  def get_all_by_map(map_id),
    do: WandererApp.Api.MapCharacterSettings.read_by_map(%{map_id: map_id})

  def get_tracked_by_map_all(map_id),
    do: WandererApp.Api.MapCharacterSettings.tracked_by_map_all(%{map_id: map_id})

  def track(%{map_id: map_id, character_id: character_id}) do
    # First ensure the record exists (get creates if not exists)
    case get(map_id, character_id) do
      {:ok, settings} when not is_nil(settings) ->
        # Now update the tracked field
        settings
        |> WandererApp.Api.MapCharacterSettings.update(%{tracked: true})

      error ->
        Logger.error(
          "Failed to track character: #{character_id} on map: #{map_id}, #{inspect(error)}"
        )

        {:error, error}
    end
  end

  # Every path that unchecks a character's tracking box in the database funnels
  # through here: the UI toggle (TrackingUtils), the ACL permission sweep
  # (CharactersImpl) and character deletion (CharactersLive) all call this, and
  # untrack!/1 delegates to it. It is therefore the one place that can observe an
  # uncheck regardless of which path caused it.
  #
  # That matters because users report their tracking box unchecking itself while
  # none of the known callers appears responsible. Reasoning backwards from the
  # call sites could not settle it; recording the caller at the moment of the
  # write does. The stacktrace is the payload — it names the path even if the
  # path is one nobody has thought of yet.
  def untrack(%{map_id: map_id, character_id: character_id}) do
    # First ensure the record exists (get creates if not exists)
    case get(map_id, character_id) do
      {:ok, settings} when not is_nil(settings) ->
        # Captured before the update, so this reports the true -> false
        # transition rather than every call. A repeat untrack of an already
        # untracked character changes nothing and must not be counted, or the
        # metric stops meaning "a box was unchecked".
        was_tracked = Map.get(settings, :tracked) == true

        settings
        |> WandererApp.Api.MapCharacterSettings.update(%{tracked: false})
        |> case do
          {:ok, _updated} = result ->
            if was_tracked, do: report_untrack(map_id, character_id)
            result

          error ->
            error
        end

      error ->
        Logger.error(
          "Failed to untrack character: #{character_id} on map: #{map_id}, #{inspect(error)}"
        )

        {:error, error}
    end
  end

  # Known callers, mapped to a bounded set of sources so the metric can be
  # grouped in Grafana. Anything else is :unknown — which is exactly the case
  # worth looking at, and the log line carries the raw stack for it.
  @untrack_sources %{
    WandererApp.Character.TrackingUtils => :ui_toggle,
    WandererApp.Map.Server.CharactersImpl => :acl_sweep,
    WandererAppWeb.CharactersLive => :character_deleted
  }

  defp report_untrack(map_id, character_id) do
    {source, stack} = untrack_source()

    Logger.warning(
      "[MapCharacterSettings] Untracked character #{character_id} on map #{map_id} " <>
        "(source: #{source}). Caller: #{stack}",
      character_id: character_id,
      map_id: map_id
    )

    :telemetry.execute(
      [:wanderer_app, :map, :character_settings, :untracked],
      %{count: 1, system_time: System.system_time()},
      %{character_id: character_id, map_id: map_id, source: source}
    )
  end

  defp untrack_source do
    case Process.info(self(), :current_stacktrace) do
      {:current_stacktrace, stack} ->
        {classify_stack(stack), format_stack(stack)}

      _ ->
        {:unknown, "unavailable"}
    end
  end

  defp classify_stack(stack) do
    Enum.find_value(stack, :unknown, fn {module, _fun, _arity, _loc} ->
      Map.get(@untrack_sources, module)
    end)
  end

  # Only frames outside this module, and only a handful: enough to name the
  # caller without dumping an entire LiveView stack into the log. Process is
  # dropped too — it is the Process.info/2 call that captured the stack, not a
  # caller, and it would otherwise head every line.
  defp format_stack(stack) do
    stack
    |> Enum.reject(fn {module, _fun, _arity, _loc} ->
      module in [__MODULE__, Process]
    end)
    |> Enum.take(6)
    |> Enum.map_join(" <- ", fn {module, fun, arity, loc} ->
      file = loc |> Keyword.get(:file, ~c"?") |> to_string()
      line = Keyword.get(loc, :line, 0)
      "#{inspect(module)}.#{fun}/#{arity} (#{file}:#{line})"
    end)
  end

  def track!(settings) do
    case track(settings) do
      {:ok, result} -> result
      error -> raise "Failed to track: #{inspect(error)}"
    end
  end

  def untrack!(settings) do
    case untrack(settings) do
      {:ok, result} -> result
      error -> raise "Failed to untrack: #{inspect(error)}"
    end
  end

  def follow(%{map_id: map_id, character_id: character_id} = _settings) do
    # First ensure the record exists (get creates if not exists)
    case get(map_id, character_id) do
      {:ok, settings} when not is_nil(settings) ->
        settings
        |> WandererApp.Api.MapCharacterSettings.update(%{followed: true})

      error ->
        Logger.error(
          "Failed to follow character: #{character_id} on map: #{map_id}, #{inspect(error)}"
        )

        {:error, error}
    end
  end

  def unfollow(%{map_id: map_id, character_id: character_id} = _settings) do
    # First ensure the record exists (get creates if not exists)
    case get(map_id, character_id) do
      {:ok, settings} when not is_nil(settings) ->
        settings
        |> WandererApp.Api.MapCharacterSettings.update(%{followed: false})

      error ->
        Logger.error(
          "Failed to unfollow character: #{character_id} on map: #{map_id}, #{inspect(error)}"
        )

        {:error, error}
    end
  end

  def follow!(settings) do
    case follow(settings) do
      {:ok, result} -> result
      error -> raise "Failed to follow: #{inspect(error)}"
    end
  end

  def unfollow!(settings) do
    case unfollow(settings) do
      {:ok, result} -> result
      error -> raise "Failed to unfollow: #{inspect(error)}"
    end
  end

  def destroy!(settings) do
    case Ash.destroy(settings) do
      :ok -> settings
      {:error, error} -> raise "Failed to destroy: #{inspect(error)}"
    end
  end
end
