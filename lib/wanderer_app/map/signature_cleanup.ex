defmodule WandererApp.Map.SignatureCleanup do
  @moduledoc """
  On-demand signature cleanup for expired signatures.
  Runs per-system when signatures are viewed or updated.
  """

  require Logger

  @doc """
  Cleans up expired signatures for a system asynchronously.
  Returns :ok immediately without blocking the caller.
  """
  def cleanup_async(system_id) do
    Task.Supervisor.start_child(WandererApp.TaskSupervisor, fn -> cleanup(system_id) end)
    :ok
  end

  @doc """
  Cleans up expired signatures for a system synchronously.
  """
  def cleanup(system_id) do
    case WandererApp.Api.MapSystem.by_id(system_id) do
      {:ok, system} ->
        do_cleanup(system)

      {:error, reason} ->
        Logger.warning("Signature cleanup: system #{system_id} not found: #{inspect(reason)}")
        :ok
    end
  end

  defp do_cleanup(system) do
    map_id = system.map_id

    wormhole_expiration_hours =
      Application.get_env(:wanderer_app, :signatures)[:wormhole_expiration_hours] || 24

    default_expiration_hours =
      Application.get_env(:wanderer_app, :signatures)[:default_expiration_hours] || 72

    preserve_connected =
      Application.get_env(:wanderer_app, :signatures)[:preserve_connected] || true

    max_age_hours =
      Application.get_env(:wanderer_app, :signature_cleanup)[:max_age_hours] || 24

    signatures = WandererApp.Api.MapSystemSignature.by_system_id!(system.id)

    wormhole_cutoff =
      if wormhole_expiration_hours > 0,
        do: DateTime.utc_now() |> DateTime.add(-wormhole_expiration_hours, :hour),
        else: nil

    default_cutoff =
      if default_expiration_hours > 0,
        do: DateTime.utc_now() |> DateTime.add(-default_expiration_hours, :hour),
        else: nil

    old_cutoff = DateTime.utc_now() |> DateTime.add(-max_age_hours, :hour)

    if wormhole_expiration_hours == 0 && default_expiration_hours == 0 do
      Logger.debug("Signature expiration is disabled via environment variables")
      cleanup_very_old_signatures(signatures, old_cutoff, preserve_connected, system, map_id)
    else
      expired_signatures =
        signatures
        |> Enum.filter(fn sig ->
          if preserve_connected && not is_nil(sig.linked_system_id) do
            false
          else
            cutoff = if sig.group == "Wormhole", do: wormhole_cutoff, else: default_cutoff
            not is_nil(cutoff) && DateTime.compare(sig.updated_at, cutoff) == :lt
          end
        end)

      process_expired_signatures(expired_signatures, system, map_id)
      cleanup_very_old_signatures(signatures, old_cutoff, preserve_connected, system, map_id)
    end
  end

  defp cleanup_very_old_signatures(signatures, old_cutoff, preserve_connected, system, map_id) do
    very_old_signatures =
      signatures
      |> Enum.filter(fn sig ->
        if preserve_connected && not is_nil(sig.linked_system_id) do
          false
        else
          DateTime.compare(sig.updated_at, old_cutoff) == :lt
        end
      end)

    process_expired_signatures(very_old_signatures, system, map_id)
  end

  defp process_expired_signatures(expired_signatures, system, map_id) do
    if not Enum.empty?(expired_signatures) do
      count = length(expired_signatures)

      Logger.info("Cleaning up #{count} expired signatures from system #{system.solar_system_id}")

      expired_signatures
      |> Enum.each(fn sig ->
        if not is_nil(sig.linked_system_id) do
          map_id
          |> WandererApp.Map.Server.update_system_linked_sig_eve_id(%{
            solar_system_id: sig.linked_system_id,
            linked_sig_eve_id: nil
          })
        end

        case Ash.destroy(sig) do
          :ok ->
            Logger.debug(
              "Deleted expired signature #{sig.eve_id} from system #{system.solar_system_id}"
            )

          {:ok, _} ->
            Logger.debug(
              "Deleted expired signature #{sig.eve_id} from system #{system.solar_system_id}"
            )

          {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} ->
            Logger.debug("Signature #{sig.eve_id} already deleted by another process")

          {:error, error} ->
            Logger.warning("Failed to delete signature #{sig.eve_id}: #{inspect(error)}")
        end
      end)

      :telemetry.execute(
        [:wanderer_app, :signature_cleanup, :completed],
        %{count: count},
        %{
          system_id: system.id,
          solar_system_id: system.solar_system_id,
          map_id: map_id,
          trigger: :on_demand
        }
      )

      Phoenix.PubSub.broadcast!(WandererApp.PubSub, map_id, %{
        event: :signatures_updated,
        payload: system.solar_system_id
      })
    end
  end
end
