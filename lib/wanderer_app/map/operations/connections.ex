defmodule WandererApp.Map.Operations.Connections do
  @moduledoc """
  Operations for managing map connections, including creation, updates, and deletions.
  Handles special cases like C1 wormhole sizing rules and unique constraint handling.
  """

  require Logger
  alias WandererApp.Map.Server
  alias WandererApp.MapConnectionRepo

  # Connection type constants
  @connection_type_wormhole 0
  @connection_type_stargate 1

  # Ship size constants
  @small_ship_size  0
  @medium_ship_size 1
  @large_ship_size  2
  @xlarge_ship_size 3

  # System class constants
  @c1_system_class "C1"

  @doc """
  Creates a connection between two systems, applying special rules for C1 wormholes.
  Handles parsing of input parameters, validates system information, and manages
  unique constraint violations gracefully.
  """
  def create(%{assigns: %{map_id: map_id, owner_character_id: char_id}} = _conn, attrs) do
    do_create(attrs, map_id, char_id)
  end
  def create(_conn, _attrs), do: {:error, :missing_params}

  @doc """
  Creates a connection with explicit parameters (used internally and for testing).
  """
  def create(attrs, map_id, char_id) do
    do_create(attrs, map_id, char_id)
  end

  defp do_create(attrs, map_id, char_id) do
    with {:ok, source} <- parse_int(attrs["solar_system_source"], "solar_system_source"),
         {:ok, target} <- parse_int(attrs["solar_system_target"], "solar_system_target"),
         {:ok, src_info} <- WandererApp.CachedInfo.get_system_static_info(source),
         {:ok, tgt_info} <- WandererApp.CachedInfo.get_system_static_info(target) do
      build_and_add_connection(attrs, map_id, char_id, src_info, tgt_info)
    else
      {:error, reason} -> handle_precondition_error(reason, attrs)
      {:ok, []}      -> {:error, :inconsistent_state}
      other          -> {:error, :unexpected_precondition_error, other}
    end
  end

  defp build_and_add_connection(_attrs, map_id, char_id, src_info, tgt_info) do
    info = %{
      solar_system_source_id: src_info.id,
      solar_system_target_id: tgt_info.id,
      character_id: char_id
    }

    case Server.add_connection(map_id, info) do
      :ok -> {:ok, info}
      {:error, :already_exists} -> {:skip, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_int(value, field) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> {:ok, int}
      :error -> {:error, "Invalid #{field}: #{value}"}
    end
  end
  defp parse_int(value, field), do: {:error, "Invalid #{field}: #{inspect(value)}"}

  defp handle_precondition_error(reason, _attrs) do
    Logger.error("[create_connection] Precondition error: #{inspect(reason)}")
    {:error, "Failed to create connection: #{inspect(reason)}"}
  end

  @spec update_connection(Plug.Conn.t(), integer(), map()) :: {:ok, map()} | {:error, atom()}
  def update_connection(%{assigns: %{map_id: map_id, owner_character_id: char_id}} = _conn, conn_id, attrs) do
    with {:ok, conn_struct} <- MapConnectionRepo.get_by_id(map_id, conn_id),
         result <- (
           try do
             _allowed_keys = [
               :mass_status,
               :ship_size_type,
               :type
             ]
             _update_map =
               attrs
               |> Enum.filter(fn {k, _v} -> k in ["mass_status", "ship_size_type", "type"] end)
               |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
               |> Enum.into(%{})
             res = apply_connection_updates(map_id, conn_struct, attrs, char_id)
             res
           rescue
             error ->
               Logger.error("[update_connection] Exception: #{inspect(error)}")
               {:error, :exception}
           end
         ),
         :ok <- result,
         {:ok, updated_conn} <- MapConnectionRepo.get_by_id(map_id, conn_id) do
      {:ok, updated_conn}
    else
      {:error, err} -> {:error, err}
      _ -> {:error, :unexpected_error}
    end
  end
  def update_connection(_conn, _conn_id, _attrs), do: {:error, :missing_params}

  @spec delete_connection(Plug.Conn.t(), integer(), integer()) :: :ok | {:error, atom()}
  def delete_connection(%{assigns: %{map_id: map_id}} = _conn, src, tgt) do
    case Server.delete_connection(map_id, %{solar_system_source_id: src, solar_system_target_id: tgt}) do
      :ok -> :ok
      {:error, :not_found} ->
        Logger.warning("[delete_connection] Connection not found: source=#{inspect(src)}, target=#{inspect(tgt)}")
        {:error, :not_found}
      {:error, _} = err ->
        Logger.error("[delete_connection] Server error: #{inspect(err)}")
        {:error, :server_error}
      _ ->
        Logger.error("[delete_connection] Unknown error")
        {:error, :unknown}
    end
  end
  def delete_connection(_conn, _src, _tgt), do: {:error, :missing_params}

  @spec get_connection_by_systems(String.t(), integer(), integer()) :: {:ok, map()} | {:error, String.t()}
  def get_connection_by_systems(map_id, source, target) do
    with {:ok, conn} <- WandererApp.Map.find_connection(map_id, source, target) do
      if conn, do: {:ok, conn}, else: WandererApp.Map.find_connection(map_id, target, source)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets all connections for a map.
  """
  @spec get_connections(String.t()) :: [map()]
  def get_connections(map_id) do
    case MapConnectionRepo.get_by_map(map_id) do
      {:ok, connections} -> connections
      {:error, _} -> []
    end
  end

  @doc """
  Gets all connections for a specific system in a map.
  """
  @spec get_connections_for_system(String.t(), integer()) :: [map()]
  def get_connections_for_system(map_id, system_id) do
    case MapConnectionRepo.get_by_system(map_id, system_id) do
      {:ok, connections} -> connections
      {:error, _} -> []
    end
  end

  @doc """
  Gets a connection by its ID.
  """
  @spec get_connection_by_id(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def get_connection_by_id(map_id, connection_id) do
    case MapConnectionRepo.get_by_id(map_id, connection_id) do
      {:ok, connection} -> {:ok, connection}
      {:error, reason} -> {:error, "Failed to get connection: #{inspect(reason)}"}
    end
  end

  @doc """
  Upserts (creates or updates) a single connection.
  Returns {:ok, :created}, {:ok, :updated}, or {:error, reason}.
  """
  @spec upsert_single(Plug.Conn.t(), map()) :: {:ok, :created | :updated} | {:error, term()}
  def upsert_single(%{assigns: %{map_id: _map_id, owner_character_id: _char_id}} = conn, conn_data) do
    case create(conn, conn_data) do
      {:ok, _} -> {:ok, :created}
      {:skip, :exists} -> {:ok, :updated}  # Connection already exists, consider it updated
      {:error, reason} -> {:error, reason}
    end
  end
  def upsert_single(_conn, _conn_data), do: {:error, :missing_params}

  # -- Helpers ---------------------------------------------------------------

  defp apply_connection_updates(map_id, conn, attrs, _char_id) do
    Enum.reduce_while(attrs, :ok, fn {key, val}, _acc ->
      result =
        case key do
          "mass_status" -> maybe_update_mass_status(map_id, conn, val)
          "ship_size_type" -> maybe_update_ship_size_type(map_id, conn, val)
          "type" -> maybe_update_type(map_id, conn, val)
          _ -> :ok
        end
      if result == :ok do
        {:cont, :ok}
      else
        {:halt, result}
      end
    end)
    |> case do
      :ok -> :ok
      err -> err
    end
  end

  defp maybe_update_mass_status(_map_id, _conn, nil), do: :ok
  defp maybe_update_mass_status(map_id, conn, value) do
    Server.update_connection_mass_status(map_id, %{
      solar_system_source_id: conn.solar_system_source,
      solar_system_target_id: conn.solar_system_target,
      mass_status: value
    })
  end

  defp maybe_update_ship_size_type(_map_id, _conn, nil), do: :ok
  defp maybe_update_ship_size_type(map_id, conn, value) do
    Server.update_connection_ship_size_type(map_id, %{
      solar_system_source_id: conn.solar_system_source,
      solar_system_target_id: conn.solar_system_target,
      ship_size_type: value
    })
  end

  defp maybe_update_type(_map_id, _conn, nil), do: :ok
  defp maybe_update_type(map_id, conn, value) do
    Server.update_connection_type(map_id, %{
      solar_system_source_id: conn.solar_system_source,
      solar_system_target_id: conn.solar_system_target,
      type: value
    })
  end
end
