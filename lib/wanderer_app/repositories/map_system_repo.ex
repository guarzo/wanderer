defmodule WandererApp.MapSystemRepo do
  use WandererApp, :repository

  def create(system) do
    system |> WandererApp.Api.MapSystem.create()
  end

  def get_by_map_and_solar_system_id(map_id, solar_system_id) do
    WandererApp.Api.MapSystem.by_map_id_and_solar_system_id(map_id, solar_system_id)
    |> case do
      {:ok, system} ->
        {:ok, system}

      _ ->
        {:error, :not_found}
    end
  end

  def get_all_by_map(map_id) do
    WandererApp.Api.MapSystem.read_all_by_map(%{map_id: map_id})
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

  def update_locked(system, update),
    do:
      system
      |> WandererApp.Api.MapSystem.update_locked(update)

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

  @doc """
  Bulk create multiple systems at once.
  Returns {:ok, created_systems} on success or {:error, reason} on failure.
  """
  def bulk_create(systems) do
    WandererApp.Api.MapSystem.bulk_create(systems)
    |> case do
      %Ash.BulkResult{status: :success} = result ->
        {:ok, result.records}

      %Ash.BulkResult{status: :error, errors: errors} ->
        {:error, errors}

      error ->
        {:error, error}
    end
  end

  @doc """
  Bulk update multiple systems at once.
  Each system in the list should be a tuple of {system, updates}.
  Returns {:ok, updated_systems} on success or {:error, reason} on failure.
  """
  def bulk_update(system_updates) do
    WandererApp.Api.MapSystem.bulk_update(system_updates)
    |> case do
      %Ash.BulkResult{status: :success} = result ->
        {:ok, result.records}

      %Ash.BulkResult{status: :error, errors: errors} ->
        {:error, errors}

      error ->
        {:error, error}
    end
  end

  @doc """
  Update a system by its ID.
  Returns {:ok, updated_system} on success or {:error, reason} on failure.
  """
  def update_by_id(system_id, updates) do
    case WandererApp.Api.MapSystem.by_id(system_id) do
      {:ok, system} ->
        # Call the appropriate update function based on the fields being updated
        # This assumes all updates are valid for a single action, which might not be the case
        # If needed, this could be enhanced to call different update actions based on the updates
        cond do
          Map.has_key?(updates, :position_x) || Map.has_key?(updates, :position_y) ->
            update_position(system, Map.take(updates, [:position_x, :position_y]))

          Map.has_key?(updates, :labels) ->
            update_labels(system, Map.take(updates, [:labels]))

          Map.has_key?(updates, :status) ->
            update_status(system, Map.take(updates, [:status]))

          Map.has_key?(updates, :description) ->
            update_description(system, Map.take(updates, [:description]))

          Map.has_key?(updates, :tag) ->
            update_tag(system, Map.take(updates, [:tag]))

          Map.has_key?(updates, :visible) ->
            update_visible(system, Map.take(updates, [:visible]))

          Map.has_key?(updates, :temporary_name) ->
            update_temporary_name(system, Map.take(updates, [:temporary_name]))

          Map.has_key?(updates, :linked_sig_eve_id) ->
            update_linked_sig_eve_id(system, Map.take(updates, [:linked_sig_eve_id]))

          Map.has_key?(updates, :locked) ->
            update_locked(system, Map.take(updates, [:locked]))

          true ->
            # If no specific update fields match, use a generic update
            {:ok, Map.merge(system, updates)}
        end

      error -> error
    end
  end
end
