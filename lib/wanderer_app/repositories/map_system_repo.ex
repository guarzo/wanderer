defmodule WandererApp.MapSystemRepo do
  use WandererApp, :repository

  alias WandererApp.Repositories.MapContextHelper

  def create(system) do
    context = MapContextHelper.build_context(system)
    WandererApp.Api.MapSystem.create(system, context)
  end

  def upsert(system) do
    system |> WandererApp.Api.MapSystem.upsert()
  end

  def get_by_map_and_solar_system_id(map_id, solar_system_id) do
    WandererApp.Api.MapSystem.read_by_map_and_solar_system(%{
      map_id: map_id,
      solar_system_id: solar_system_id
    })
    |> case do
      {:ok, system} ->
        {:ok, system}

      _error ->
        {:error, :not_found}
    end
  end

  def get_all_by_map(map_id) do
    WandererApp.Api.MapSystem.read_all_by_map(%{map_id: map_id})
  end

  def get_all_by_maps(map_ids) when is_list(map_ids) do
    # Since there's no bulk query, we need to query each map individually
    map_ids
    |> Enum.flat_map(fn map_id ->
      case get_all_by_map(map_id) do
        {:ok, systems} -> systems
        _ -> []
      end
    end)
    |> Enum.uniq_by(& &1.solar_system_id)
  end

  def get_visible_by_map(map_id) do
    WandererApp.Api.MapSystem.read_visible_by_map(%{map_id: map_id})
  end

  def remove_from_map(map_id, solar_system_id) do
    WandererApp.Api.MapSystem.read_by_map_and_solar_system!(%{
      map_id: map_id,
      solar_system_id: solar_system_id
    })
    |> WandererApp.Api.MapSystem.update_visible(%{visible: false})
  rescue
    error ->
      {:error, error}
  end

  def cleanup_labels!(%{labels: labels} = system, opts) do
    store_custom_labels? =
      Keyword.get(opts, :store_custom_labels)

    labels = get_filtered_labels(labels, store_custom_labels?)

    system
    |> update_labels!(%{
      labels: labels
    })
  end

  def cleanup_tags(system) do
    system
    |> WandererApp.Api.MapSystem.update_tag(%{
      tag: nil
    })
  end

  def cleanup_tags!(system) do
    system
    |> WandererApp.Api.MapSystem.update_tag!(%{
      tag: nil
    })
  end

  def cleanup_temporary_name(system) do
    system
    |> WandererApp.Api.MapSystem.update_temporary_name(%{
      temporary_name: nil
    })
  end

  def cleanup_temporary_name!(system) do
    system
    |> WandererApp.Api.MapSystem.update_temporary_name!(%{
      temporary_name: nil
    })
  end

  def cleanup_linked_sig_eve_id!(system) do
    system
    |> WandererApp.Api.MapSystem.update_linked_sig_eve_id!(%{
      linked_sig_eve_id: nil
    })
  end

  @doc """
  Compare-and-set a trade-hub distance tag into `labels.customLabel`.

  Runs inside a transaction with a `FOR UPDATE` row lock on the map system:
  the stored labels are re-read *at the persistence boundary* and the tag is
  written only when there is still no non-empty `customLabel`. A user label
  saved between the tagger's earlier read and this write therefore wins —
  we populate, never overwrite (issue #3 rule: manual labels are terminal).

  Returns:

  - `{:ok, {updated_system, :written}}` — the row had no custom label and the
    tag was merged in (other label data preserved, `tag` attribute untouched);
    the updated system record is returned so callers can refresh caches and
    broadcast.
  - `{:ok, :kept}` — a non-empty custom label already exists; nothing changed.
  - `{:error, :not_found}` — the system row is gone (deleted mid-flight);
    nothing to tag.

  Any unexpected persistence error is returned as `{:error, reason}`.
  """
  @spec tag_trade_hub_distance(String.t() | integer(), integer(), String.t()) ::
          {:ok, {WandererApp.Api.MapSystem.t(), :written}}
          | {:ok, :kept}
          | {:error, :not_found}
          | {:error, term()}
  def tag_trade_hub_distance(map_id, solar_system_id, tag) do
    Ash.transaction(WandererApp.Api.MapSystem, fn ->
      with {:ok, system} <- locked_system(map_id, solar_system_id) do
        maybe_write_tag(system, tag)
      else
        {:error, :not_found} = skip -> skip
        {:error, reason} -> Ash.DataLayer.rollback(WandererApp.Api.MapSystem, reason)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp locked_system(map_id, solar_system_id) do
    require Ash.Query

    # `read :read` has a `FilterSystemsByActorMap` preparation keyed on an
    # `ActorWithMap` in the context — without it the preparation filters
    # everything out. Passing it here scopes the locked read to the same map,
    # preserving the resource's security posture for this internal call.
    actor = %WandererApp.Api.ActorWithMap{user: nil, map: %{id: map_id}}

    WandererApp.Api.MapSystem
    |> Ash.Query.for_read(:read, %{}, actor: actor, authorize?: false)
    |> Ash.Query.filter(map_id == ^map_id and solar_system_id == ^solar_system_id)
    |> Ash.Query.select([:labels])
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, system} -> {:ok, system}
      {:error, reason} -> {:error, reason}
    end
  end

  # The row is locked, so the check-then-write below is atomic against any
  # other writer of `labels` (map client LabelManager edits included).
  defp maybe_write_tag(system, tag) do
    case custom_label(system.labels) do
      label when is_binary(label) and label != "" ->
        {:ok, :kept}

      _ ->
        updated_system =
          system
          |> WandererApp.Api.MapSystem.update_labels!(%{labels: merge_tag(system.labels, tag)},
            authorize?: false
          )

        {:ok, {updated_system, :written}}
    end
  end

  defp custom_label(labels) when is_binary(labels) and labels != "" do
    case Jason.decode(labels) do
      {:ok, %{"customLabel" => custom_label}} -> custom_label
      _ -> nil
    end
  end

  defp custom_label(_labels), do: nil

  # Same merge rules as before the CAS rewrite: the distance lives in
  # `labels.customLabel` — the slot the map client's System settings "Tag"
  # field edits (LabelsManager), rendered as trailing text after the system
  # name. Merge into the existing label JSON so user labels survive; don't
  # touch the `tag` attribute (that's the Occupied badge).
  defp merge_tag(labels, tag) when is_binary(labels) and labels != "" do
    case Jason.decode(labels) do
      {:ok, %{} = map} -> map |> Map.put("customLabel", tag) |> Jason.encode!()
      _ -> Jason.encode!(%{customLabel: tag, labels: String.split(labels, ",")})
    end
  end

  defp merge_tag(_labels, tag), do: Jason.encode!(%{customLabel: tag, labels: []})

  def get_filtered_labels(labels, true) when is_binary(labels) do
    labels
    |> Jason.decode!()
    |> case do
      %{"customLabel" => customLabel} when is_binary(customLabel) ->
        %{"customLabel" => customLabel, "labels" => []}
        |> Jason.encode!()

      _ ->
        nil
    end
  end

  def get_filtered_labels(_, _store_custom_labels), do: nil

  def update_name(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_name(update)

  def update_description(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_description(update)

  def update_locked(system, update) do
    case WandererApp.Api.MapSystem.update_locked(system, update) do
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} ->
        WandererApp.Api.MapSystem.by_id!(system.id)
        |> WandererApp.Api.MapSystem.update_locked(update)

      {:ok, system} ->
        {:ok, system}
    end
  end

  def update_status(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_status(update)

  def update_tag(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_tag(update)

  def update_temporary_name(system, update) do
    system
    |> WandererApp.Api.MapSystem.update_temporary_name(update)
  end

  def update_custom_name(system, update) do
    system
    |> WandererApp.Api.MapSystem.update_custom_name(update)
  end

  def update_owner(system, update) do
    # Convert empty strings to nil for owner_ticker
    ticker =
      case Map.get(update, :owner_ticker) do
        "" -> nil
        ticker -> ticker
      end

    clean_update = %{
      owner_id: Map.get(update, :owner_id),
      owner_type: Map.get(update, :owner_type),
      owner_ticker: ticker
    }

    WandererApp.Api.MapSystem.update_owner(system, clean_update)
  end

  def update_custom_flags(system, update) do
    system
    |> WandererApp.Api.MapSystem.update_custom_flags(update)
  end

  def update_labels(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_labels(update)

  def update_labels!(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_labels!(update)

  def update_linked_sig_eve_id(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_linked_sig_eve_id(update)

  def update_linked_sig_eve_id!(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_linked_sig_eve_id!(update)

  def update_position(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_position(update)

  def update_position!(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_position!(update)

  def update_visible(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_visible(update)

  def update_visible!(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_visible!(update)
end
