defmodule WandererAppWeb.MapSignaturesEventHandler do
  use WandererAppWeb, :live_component
  use Phoenix.Component
  require Logger

  alias WandererAppWeb.{MapEventHandler, MapCoreEventHandler}
  alias WandererApp.Utils.EVEUtil

  def handle_server_event(
        %{
          event: :maybe_link_signature,
          payload: %{
            character_id: character_id,
            solar_system_source: solar_system_source,
            solar_system_target: solar_system_target
          }
        },
        %{
          assigns: %{
            current_user: current_user,
            map_id: map_id,
            map_user_settings: map_user_settings
          }
        } = socket
      ) do
    is_user_character =
      current_user.characters |> Enum.map(& &1.id) |> Enum.member?(character_id)

    is_link_signature_on_splash =
      map_user_settings
      |> WandererApp.MapUserSettingsRepo.to_form_data!()
      |> WandererApp.MapUserSettingsRepo.get_boolean_setting("link_signature_on_splash")

    {:ok, signatures} =
      WandererApp.Api.MapSystem.read_by_map_and_solar_system(%{
        map_id: map_id,
        solar_system_id: solar_system_source
      })
      |> case do
        {:ok, system} ->
          {:ok,
           get_system_signatures(system.id)
           |> Enum.filter(fn signature ->
             is_nil(signature.linked_system) && signature.group == "Wormhole"
           end)}

        _ ->
          {:ok, []}
      end

    (is_user_character && is_link_signature_on_splash && not (signatures |> Enum.empty?()))
    |> case do
      true ->
        socket
        |> MapEventHandler.push_map_event("link_signature_to_system", %{
          solar_system_source: solar_system_source,
          solar_system_target: solar_system_target
        })

      false ->
        socket
    end
  end

  def handle_server_event(
        %{event: :signatures_updated, payload: solar_system_id},
        socket
      ),
      do:
        socket
        |> MapEventHandler.push_map_event(
          "signatures_updated",
          solar_system_id
        )

  def handle_server_event(
        %{event: :remove_signatures, payload: {solar_system_id, removed_signatures}},
        %{
          assigns: %{
            current_user: %{id: current_user_id},
            main_character_id: main_character_id,
            map_id: map_id,
            map_user_settings: map_user_settings,
            removed_sig_eve_ids: removed_sig_eve_ids
          }
        } = socket
      ) do
    solar_system_id = get_integer(solar_system_id)

    delete_connection_with_sigs =
      map_user_settings
      |> WandererApp.MapUserSettingsRepo.to_form_data!()
      |> WandererApp.MapUserSettingsRepo.get_boolean_setting("delete_connection_with_sigs")

    to_remove =
      removed_signatures
      |> Enum.filter(fn %{"eve_id" => eve_id} -> eve_id in removed_sig_eve_ids end)

    to_remove_eve_ids =
      to_remove
      |> Enum.map(fn %{"eve_id" => eve_id} -> eve_id end)

    map_id
    |> WandererApp.Map.Server.update_signatures(%{
      solar_system_id: solar_system_id,
      character_id: main_character_id,
      user_id: current_user_id,
      delete_connection_with_sigs: delete_connection_with_sigs,
      added_signatures: [],
      updated_signatures: [],
      removed_signatures: to_remove
    })

    socket
    |> assign(
      removed_sig_eve_ids:
        removed_sig_eve_ids |> Enum.reject(fn sig_id -> sig_id in to_remove_eve_ids end)
    )
  end

  def handle_server_event(event, socket),
    do: MapCoreEventHandler.handle_server_event(event, socket)

  def handle_ui_event(
        "load_signatures",
        _event,
        %{
          assigns: %{
            map_id: map_id
          }
        } = socket
      ) do
    {:ok, systems} = map_id |> WandererApp.Map.list_systems()

    system_signatures =
      systems
      |> Enum.reduce(%{}, fn %{id: system_id, solar_system_id: solar_system_id}, acc ->
        signatures =
          system_id
          |> get_system_signatures()
          |> Enum.filter(fn signature ->
            is_nil(signature.linked_system) && signature.group == "Wormhole"
          end)

        acc |> Map.put(solar_system_id, signatures)
      end)

    {:noreply,
     socket
     |> MapEventHandler.push_map_event(
       "map_updated",
       %{system_signatures: system_signatures}
     )}
  end

  def handle_ui_event(
        "update_signatures",
        %{
          "system_id" => solar_system_id,
          "added" => added_signatures,
          "updated" => updated_signatures,
          "removed" => removed_signatures,
          "deleteTimeout" => delete_timeout
        },
        %{
          assigns:
            %{
              current_user: %{id: current_user_id},
              map_id: map_id,
              main_character_id: main_character_id,
              map_user_settings: map_user_settings,
              user_permissions: %{update_system: true}
            } = assigns
        } = socket
      )
      when not is_nil(main_character_id) do
    solar_system_id = get_integer(solar_system_id)

    old_removed_sig_eve_ids = Map.get(assigns, :removed_sig_eve_ids, [])

    new_removed_sig_eve_ids =
      removed_signatures
      |> Enum.map(fn %{"eve_id" => eve_id} -> eve_id end)

    Process.send_after(
      self(),
      %{event: :remove_signatures, payload: {solar_system_id, removed_signatures}},
      delete_timeout
    )

    # Get the system to clean up expired signatures
    case WandererApp.Api.MapSystem.read_by_map_and_solar_system(%{
           map_id: map_id,
           solar_system_id: solar_system_id
         }) do
      {:ok, system} ->
        # Clean up expired signatures before updating
        cleanup_expired_signatures(system.id)
      _ ->
        :ok
    end

    map_id
    |> WandererApp.Map.Server.update_signatures(%{
      solar_system_id: solar_system_id,
      character_id: main_character_id,
      user_id: current_user_id,
      delete_connection_with_sigs: false,
      added_signatures: added_signatures,
      updated_signatures: updated_signatures,
      removed_signatures: []
    })

    {:noreply,
     socket
     |> assign(
       removed_sig_eve_ids: (old_removed_sig_eve_ids ++ new_removed_sig_eve_ids) |> Enum.uniq()
     )}
  end

  def handle_ui_event(
        "get_signatures",
        %{"system_id" => solar_system_id},
        %{
          assigns:
            %{
              map_id: map_id
            } = assigns
        } = socket
      ) do
    case WandererApp.Api.MapSystem.read_by_map_and_solar_system(%{
           map_id: map_id,
           solar_system_id: get_integer(solar_system_id)
         }) do
      {:ok, system} ->
        # Clean up expired signatures before returning them
        cleanup_expired_signatures(system.id)

        removed_sig_eve_ids = Map.get(assigns, :removed_sig_eve_ids, [])

        system_signatures =
          get_system_signatures(system.id)
          |> Enum.map(fn sig ->
            if sig.eve_id in removed_sig_eve_ids do
              sig |> Map.put(:deleted, true)
            else
              sig
            end
          end)

        {:reply, %{signatures: system_signatures}, socket}

      _ ->
        {:reply, %{signatures: []}, socket}
    end
  end

  def handle_ui_event(
        "link_signature_to_system",
        %{
          "signature_eve_id" => signature_eve_id,
          "solar_system_source" => solar_system_source,
          "solar_system_target" => solar_system_target
        },
        %{
          assigns: %{
            map_id: map_id,
            main_character_id: main_character_id,
            has_tracked_characters?: true,
            user_permissions: %{update_system: true}
          }
        } = socket
      )
      when not is_nil(main_character_id) and not is_nil(solar_system_source) and
             not is_nil(solar_system_target) do
    with solar_system_source <- get_integer(solar_system_source),
         solar_system_target <- get_integer(solar_system_target),
         source_system when not is_nil(source_system) <-
           WandererApp.Map.find_system_by_location(
             map_id,
             %{solar_system_id: solar_system_source}
           ),
         signature when not is_nil(signature) <-
           WandererApp.Api.MapSystemSignature.by_system_id!(source_system.id)
           |> Enum.find(fn s -> s.eve_id == signature_eve_id end),
         target_system when not is_nil(target_system) <-
           WandererApp.Map.find_system_by_location(
             map_id,
             %{solar_system_id: solar_system_target}
           ) do
      signature
      |> WandererApp.Api.MapSystemSignature.update_group!(%{group: "Wormhole"})
      |> WandererApp.Api.MapSystemSignature.update_linked_system(%{
        linked_system_id: solar_system_target
      })

      if is_nil(target_system.linked_sig_eve_id) do
        map_id
        |> WandererApp.Map.Server.update_system_linked_sig_eve_id(%{
          solar_system_id: solar_system_target,
          linked_sig_eve_id: signature_eve_id
        })

        if not is_nil(signature.temporary_name) do
          map_id
          |> WandererApp.Map.Server.update_system_temporary_name(%{
            solar_system_id: solar_system_target,
            temporary_name: signature.temporary_name
          })
        end

        signature_time_status =
          if not is_nil(signature.custom_info) do
            signature.custom_info |> Jason.decode!() |> Map.get("time_status")
          else
            nil
          end

        if not is_nil(signature_time_status) do
          map_id
          |> WandererApp.Map.Server.update_connection_time_status(%{
            solar_system_source_id: solar_system_source,
            solar_system_target_id: solar_system_target,
            time_status: signature_time_status
          })
        end

        signature_ship_size_type = EVEUtil.get_wh_size(signature.type)

        if not is_nil(signature_ship_size_type) do
          map_id
          |> WandererApp.Map.Server.update_connection_ship_size_type(%{
            solar_system_source_id: solar_system_source,
            solar_system_target_id: solar_system_target,
            ship_size_type: signature_ship_size_type
          })
        end
      end

      WandererApp.Map.Server.Impl.broadcast!(map_id, :signatures_updated, solar_system_source)

      {:noreply, socket}
    else
      _ ->
        {:noreply, socket}
    end
  end

  def handle_ui_event(
        "unlink_signature",
        %{
          "signature_eve_id" => signature_eve_id,
          "solar_system_source" => solar_system_source
        },
        %{
          assigns: %{
            map_id: map_id,
            main_character_id: main_character_id,
            has_tracked_characters?: true,
            user_permissions: %{update_system: true}
          }
        } = socket
      )
      when not is_nil(main_character_id) do
    solar_system_source = get_integer(solar_system_source)

    case WandererApp.Api.MapSystem.read_by_map_and_solar_system(%{
           map_id: map_id,
           solar_system_id: solar_system_source
         }) do
      {:ok, system} ->
        WandererApp.Api.MapSystemSignature.by_system_id!(system.id)
        |> Enum.filter(fn s -> s.eve_id == signature_eve_id end)
        |> Enum.each(fn s ->
          map_id
          |> WandererApp.Map.Server.update_system_linked_sig_eve_id(%{
            solar_system_id: s.linked_system_id,
            linked_sig_eve_id: nil
          })

          s
          |> WandererApp.Api.MapSystemSignature.update_linked_system(%{
            linked_system_id: nil
          })
        end)

        WandererApp.Map.Server.Impl.broadcast!(map_id, :signatures_updated, solar_system_source)

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_ui_event(
        "undo_delete_signatures",
        %{"system_id" => solar_system_id, "eve_ids" => eve_ids} = payload,
        %{
          assigns: %{
            map_id: map_id,
            main_character_id: main_character_id,
            user_permissions: %{update_system: true},
            removed_sig_eve_ids: removed_sig_eve_ids
          }
        } = socket
      )
      when not is_nil(main_character_id) do
    WandererApp.Map.Server.Impl.broadcast!(map_id, :signatures_updated, solar_system_id)

    {:noreply,
     socket
     |> assign(
       removed_sig_eve_ids: removed_sig_eve_ids |> Enum.reject(fn sig_id -> sig_id in eve_ids end)
     )}
  end

  def handle_ui_event(event, body, socket),
    do: MapCoreEventHandler.handle_ui_event(event, body, socket)

  def get_system_signatures(system_id),
    do:
      system_id
      |> WandererApp.Api.MapSystemSignature.by_system_id!()
      |> Enum.map(fn %{
                       inserted_at: inserted_at,
                       updated_at: updated_at,
                       linked_system_id: linked_system_id
                     } = s ->
        s
        |> Map.take([
          :eve_id,
          :character_eve_id,
          :name,
          :temporary_name,
          :description,
          :kind,
          :group,
          :type,
          :custom_info
        ])
        |> Map.put(:linked_system, MapEventHandler.get_system_static_info(linked_system_id))
        |> Map.put(:inserted_at, inserted_at |> Calendar.strftime("%Y/%m/%d %H:%M:%S"))
        |> Map.put(:updated_at, updated_at |> Calendar.strftime("%Y/%m/%d %H:%M:%S"))
      end)

  @doc """
  Checks for and removes signatures that have expired based on their age.

  Wormhole signatures expire after the configured wormhole_expiration_hours (default 24, 0 means never expire).
  Other signatures expire after the configured default_expiration_hours (default 72, 0 means never expire).
  Signatures with connections are preserved if preserve_connected is true.

  Also removes very old signatures based on the signature_cleanup configuration.
  """
  def cleanup_expired_signatures(system_id) do
    # Get the system for checking map settings
    system = WandererApp.Api.MapSystem.by_id!(system_id)
    map_id = system.map_id

    # Get configuration
    wormhole_expiration_hours = Application.get_env(:wanderer_app, :signatures)[:wormhole_expiration_hours] || 24
    default_expiration_hours = Application.get_env(:wanderer_app, :signatures)[:default_expiration_hours] || 72
    preserve_connected = Application.get_env(:wanderer_app, :signatures)[:preserve_connected] || true

    # Get the max age for very old signatures (default 24 hours)
    max_age_hours = Application.get_env(:wanderer_app, :signature_cleanup)[:max_age_hours] || 24

    # Get all signatures for this system
    signatures = WandererApp.Api.MapSystemSignature.by_system_id!(system_id)

    # Calculate cutoff times
    wormhole_cutoff = if wormhole_expiration_hours > 0,
                       do: DateTime.utc_now() |> DateTime.add(-wormhole_expiration_hours, :hour),
                       else: nil

    default_cutoff = if default_expiration_hours > 0,
                      do: DateTime.utc_now() |> DateTime.add(-default_expiration_hours, :hour),
                      else: nil

    # Calculate the cutoff time for very old signatures
    old_cutoff = DateTime.utc_now() |> DateTime.add(-max_age_hours, :hour)

    # Skip processing if both expiration times are set to 0 (never expire)
    if wormhole_expiration_hours == 0 && default_expiration_hours == 0 do
      Logger.debug("Signature expiration is disabled via environment variables")

      # Even if normal expiration is disabled, we still clean up very old signatures
      cleanup_very_old_signatures(signatures, old_cutoff, preserve_connected, system, map_id)
    else
      # Find expired signatures based on type-specific rules
      expired_signatures = signatures
      |> Enum.filter(fn sig ->
        # Skip signatures with connections if preserve_connected is true
        if preserve_connected && not is_nil(sig.linked_system_id) do
          false
        else
          # Check if signature is expired based on its type
          cutoff = if sig.group == "Wormhole", do: wormhole_cutoff, else: default_cutoff

          # If cutoff is nil (expiration disabled for this type), don't expire
          not is_nil(cutoff) && DateTime.compare(sig.updated_at, cutoff) == :lt
        end
      end)

      # Process expired signatures
      process_expired_signatures(expired_signatures, system, map_id)

      # Also clean up very old signatures
      cleanup_very_old_signatures(signatures, old_cutoff, preserve_connected, system, map_id)
    end
  end

  # Helper function to clean up very old signatures regardless of type
  defp cleanup_very_old_signatures(signatures, old_cutoff, preserve_connected, system, map_id) do
    # Find very old signatures (regardless of type)
    very_old_signatures = signatures
    |> Enum.filter(fn sig ->
      # Skip signatures with connections if preserve_connected is true
      if preserve_connected && not is_nil(sig.linked_system_id) do
        false
      else
        # Check if signature is older than the cutoff time
        DateTime.compare(sig.updated_at, old_cutoff) == :lt
      end
    end)

    # Process very old signatures
    process_expired_signatures(very_old_signatures, system, map_id)
  end

  # Helper function to process and delete expired signatures
  defp process_expired_signatures(expired_signatures, system, map_id) do
    # If we found expired signatures, delete them and broadcast the update
    if not Enum.empty?(expired_signatures) do
      # Log what we're doing
      Logger.info("Cleaning up #{length(expired_signatures)} expired signatures from system #{system.solar_system_id}")

      # Delete each expired signature
      expired_signatures
      |> Enum.each(fn sig ->
        # If signature has a linked system, handle that first
        if not is_nil(sig.linked_system_id) do
          # Update the linked system to remove the signature reference
          WandererApp.Map.Server.update_system_linked_sig_eve_id(%{
            map_id: map_id,
            solar_system_id: sig.linked_system_id,
            linked_sig_eve_id: nil
          })
        end

        # Delete the signature
        Ash.destroy!(sig)

        Logger.debug("Deleted expired signature #{sig.eve_id} from system #{system.solar_system_id}")
      end)

      # Broadcast that signatures were updated for this system
      Phoenix.PubSub.broadcast!(WandererApp.PubSub, map_id, %{
        event: :signatures_updated,
        payload: system.solar_system_id
      })
    end
  end

  defp get_integer(nil), do: nil
  defp get_integer(value) when is_binary(value), do: String.to_integer(value)
  defp get_integer(value), do: value
end
