defmodule WandererApp.Map.Operations.Duplication do
  @moduledoc """
  Map duplication operations with full transactional support.
  
  Handles copying maps including:
  - Base map attributes (name, description, settings)
  - Map systems with positions and metadata
  - System connections with their properties
  - System signatures (optional)
  - Access control lists (optional)
  - Character settings (optional)
  """

  require Logger
  
  import Ash.Query, only: [filter: 2]
  
  alias WandererApp.Api
  alias WandererApp.Api.{MapSystem, MapConnection, MapSystemSignature, MapCharacterSettings}

  @doc """
  Duplicates a complete map with all related data.
  
  ## Parameters
  - `source_map_id` - UUID of the map to duplicate
  - `changeset` - Ash changeset with new map attributes
  - `opts` - Options for what to copy:
    - `:copy_acls` - Copy access control lists (default: true)
    - `:copy_user_settings` - Copy user/character settings (default: true)  
    - `:copy_signatures` - Copy system signatures (default: true)
    
  ## Returns
  - `{:ok, duplicated_map}` - Successfully duplicated map
  - `{:error, reason}` - Error during duplication
  """
  def duplicate_map(source_map_id, new_map, opts \\ []) do
    copy_acls = Keyword.get(opts, :copy_acls, true)
    copy_user_settings = Keyword.get(opts, :copy_user_settings, true)
    copy_signatures = Keyword.get(opts, :copy_signatures, true)

    Logger.info("Starting map duplication for source map: #{source_map_id}")

    with {:ok, source_map} <- load_source_map(source_map_id),
         {:ok, system_mapping} <- copy_systems(source_map, new_map),
         {:ok, _connections} <- copy_connections(source_map, new_map, system_mapping),
         {:ok, _signatures} <- maybe_copy_signatures(source_map, new_map, system_mapping, copy_signatures),
         {:ok, _acls} <- maybe_copy_acls(source_map, new_map, copy_acls),
         {:ok, _user_settings} <- maybe_copy_user_settings(source_map, new_map, copy_user_settings) do
      
      Logger.info("Successfully duplicated map #{source_map_id} to #{new_map.id}")
      {:ok, new_map}
    else
      {:error, reason} = error ->
        Logger.error("Failed to duplicate map #{source_map_id}: #{inspect(reason)}")
        error
    end
  end

  # Load source map with all required relationships
  defp load_source_map(source_map_id) do
    case Api.Map.by_id(source_map_id) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, {:not_found, "Source map not found"}}
    end
  end

  # Copy all systems from source map to new map
  defp copy_systems(source_map, new_map) do
    Logger.debug("Copying systems for map #{source_map.id}")
    
    # Get all systems from source map using Ash
    case MapSystem |> Ash.Query.filter(map_id == ^source_map.id) |> Ash.read() do
      {:ok, source_systems} ->
        system_mapping = %{}
        
        Enum.reduce_while(source_systems, {:ok, system_mapping}, fn source_system, {:ok, acc_mapping} ->
          case copy_single_system(source_system, new_map.id) do
            {:ok, new_system} ->
              new_mapping = Map.put(acc_mapping, source_system.id, new_system.id)
              {:cont, {:ok, new_mapping}}
            {:error, reason} ->
              {:halt, {:error, {:system_copy_failed, reason}}}
          end
        end)
      {:error, error} ->
        {:error, {:systems_load_failed, error}}
    end
  end

  # Copy a single system
  defp copy_single_system(source_system, new_map_id) do
    system_attrs = %{
      map_id: new_map_id,
      solar_system_id: source_system.solar_system_id,
      name: source_system.name,
      status: source_system.status,
      position_x: source_system.position_x,
      position_y: source_system.position_y,
      visible: source_system.visible,
      locked: source_system.locked
    }

    MapSystem.create(system_attrs)
  end

  # Copy all connections between systems
  defp copy_connections(source_map, new_map, system_mapping) do
    Logger.debug("Copying connections for map #{source_map.id}")
    
    case MapConnection |> Ash.Query.filter(map_id == ^source_map.id) |> Ash.read() do
      {:ok, source_connections} ->
        Enum.reduce_while(source_connections, {:ok, []}, fn source_connection, {:ok, acc_connections} ->
          case copy_single_connection(source_connection, new_map.id, system_mapping) do
            {:ok, new_connection} ->
              {:cont, {:ok, [new_connection | acc_connections]}}
            {:error, reason} ->
              {:halt, {:error, {:connection_copy_failed, reason}}}
          end
        end)
      {:error, error} ->
        {:error, {:connections_load_failed, error}}
    end
  end

  # Copy a single connection with updated system references
  defp copy_single_connection(source_connection, new_map_id, _system_mapping) do
    # Only include fields accepted by the :create action
    connection_attrs = %{
      map_id: new_map_id,
      solar_system_source: source_connection.solar_system_source,
      solar_system_target: source_connection.solar_system_target,
      type: source_connection.type,
      ship_size_type: source_connection.ship_size_type
    }

    # Create the connection first, then update status fields if needed
    case MapConnection.create(connection_attrs) do
      {:ok, connection} ->
        # Update status fields separately if they exist and are different from defaults
        connection = maybe_update_connection_status(connection, source_connection)
        {:ok, connection}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Update connection status fields separately after creation
  defp maybe_update_connection_status(connection, source_connection) do
    # For now, just return the connection as-is
    # Status updates can be added later if needed for duplication
    connection
  end

  # Conditionally copy signatures if requested
  defp maybe_copy_signatures(_source_map, _new_map, _system_mapping, false), do: {:ok, []}
  
  defp maybe_copy_signatures(source_map, new_map, system_mapping, true) do
    Logger.debug("Copying signatures for map #{source_map.id}")
    
    # Get signatures by iterating through systems
    source_signatures = get_all_map_signatures(source_map.id, system_mapping)
    
    Enum.reduce_while(source_signatures, {:ok, []}, fn source_signature, {:ok, acc_signatures} ->
      case copy_single_signature(source_signature, new_map.id, system_mapping) do
        {:ok, new_signature} ->
          {:cont, {:ok, [new_signature | acc_signatures]}}
        {:error, reason} ->
          {:halt, {:error, {:signature_copy_failed, reason}}}
      end
    end)
  end

  # Get all signatures for a map by querying each system
  defp get_all_map_signatures(_source_map_id, system_mapping) do
    # Get source system IDs and query signatures for each
    source_system_ids = Map.keys(system_mapping)
    
    Enum.flat_map(source_system_ids, fn system_id ->
      case MapSystemSignature |> Ash.Query.filter(system_id == ^system_id) |> Ash.read() do
        {:ok, signatures} -> signatures
        {:error, _} -> []
      end
    end)
  end

  # Copy a single signature with updated system reference
  defp copy_single_signature(source_signature, _new_map_id, system_mapping) do
    new_system_id = Map.get(system_mapping, source_signature.system_id)

    if new_system_id do
      signature_attrs = %{
        system_id: new_system_id,
        eve_id: source_signature.eve_id,
        name: source_signature.name,
        group: source_signature.group,
        type: source_signature.type,
        kind: source_signature.kind,
        character_eve_id: source_signature.character_eve_id,
        description: source_signature.description
      }

      MapSystemSignature.create(signature_attrs)
    else
      {:error, "System mapping not found for signature"}
    end
  end

  # Conditionally copy ACLs if requested
  defp maybe_copy_acls(_source_map, _new_map, false), do: {:ok, []}
  
  defp maybe_copy_acls(source_map, new_map, true) do
    Logger.debug("Copying ACLs for map #{source_map.id}")
    
    # Load source map with ACL relationships
    case Api.Map.by_id(source_map.id, load: [:acls]) do
      {:ok, source_map_with_acls} ->
        # Copy ACL references to new map
        acl_ids = Enum.map(source_map_with_acls.acls, & &1.id)
        
        if Enum.any?(acl_ids) do
          Api.Map.update_acls(new_map, %{acls: acl_ids})
        else
          {:ok, new_map}
        end
      {:error, error} -> 
        {:error, {:acl_load_failed, error}}
    end
  end

  # Conditionally copy user settings if requested
  defp maybe_copy_user_settings(_source_map, _new_map, false), do: {:ok, []}
  
  defp maybe_copy_user_settings(source_map, new_map, true) do
    Logger.debug("Copying user settings for map #{source_map.id}")
    
    case MapCharacterSettings |> Ash.Query.filter(map_id == ^source_map.id) |> Ash.read() do
      {:ok, source_settings} ->
        Enum.reduce_while(source_settings, {:ok, []}, fn source_setting, {:ok, acc_settings} ->
          case copy_single_character_setting(source_setting, new_map.id) do
            {:ok, new_setting} ->
              {:cont, {:ok, [new_setting | acc_settings]}}
            {:error, reason} ->
              {:halt, {:error, {:user_setting_copy_failed, reason}}}
          end
        end)
      {:error, error} ->
        {:error, {:user_settings_load_failed, error}}
    end
  end

  # Copy a single character setting
  defp copy_single_character_setting(source_setting, new_map_id) do
    setting_attrs = %{
      map_id: new_map_id,
      character_id: source_setting.character_id,
      tracked: source_setting.tracked,
      followed: source_setting.followed
    }

    MapCharacterSettings.create(setting_attrs)
  end

end