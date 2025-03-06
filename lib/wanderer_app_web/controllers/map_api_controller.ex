defmodule WandererAppWeb.MapAPIController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import Ash.Query, only: [filter: 2]
  require Logger

  alias WandererApp.Api
  alias WandererApp.Api.{Character, MapSolarSystem}
  alias WandererApp.MapSystemRepo
  alias WandererApp.MapCharacterSettingsRepo
  alias WandererApp.Zkb.KillsProvider.KillsCache

  alias WandererAppWeb.UtilAPIController, as: Util


  @map_system_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string},
      map_id: %OpenApiSpex.Schema{type: :string},
      solar_system_id: %OpenApiSpex.Schema{type: :integer},
      original_name: %OpenApiSpex.Schema{type: :string},
      name: %OpenApiSpex.Schema{type: :string},
      custom_name: %OpenApiSpex.Schema{type: :string},
      temporary_name: %OpenApiSpex.Schema{type: :string},
      description: %OpenApiSpex.Schema{type: :string},
      tag: %OpenApiSpex.Schema{type: :string},
      labels: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string}},
      locked: %OpenApiSpex.Schema{type: :boolean},
      visible: %OpenApiSpex.Schema{type: :boolean},
      status: %OpenApiSpex.Schema{type: :string},
      position_x: %OpenApiSpex.Schema{type: :integer},
      position_y: %OpenApiSpex.Schema{type: :integer},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time}
    },
    required: ["id", "solar_system_id", "original_name", "name"]
  }

  @list_map_systems_response_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: @map_system_schema
      }
    },
    required: ["data"]
  }

  @show_map_system_response_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{data: @map_system_schema},
    required: ["data"]
  }

  @character_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string},
      eve_id: %OpenApiSpex.Schema{type: :string},
      name: %OpenApiSpex.Schema{type: :string},
      corporation_id: %OpenApiSpex.Schema{type: :string},
      corporation_name: %OpenApiSpex.Schema{type: :string},
      corporation_ticker: %OpenApiSpex.Schema{type: :string},
      alliance_id: %OpenApiSpex.Schema{type: :string},
      alliance_name: %OpenApiSpex.Schema{type: :string},
      alliance_ticker: %OpenApiSpex.Schema{type: :string},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time}
    },
    required: ["id", "eve_id", "name"]
  }

  @tracked_char_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string},
      map_id: %OpenApiSpex.Schema{type: :string},
      character_id: %OpenApiSpex.Schema{type: :string},
      tracked: %OpenApiSpex.Schema{type: :boolean},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
      character: @character_schema
    },
    required: ["id", "map_id", "character_id", "tracked"]
  }

  @tracked_characters_response_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: @tracked_char_schema
      }
    },
    required: ["data"]
  }

  @structure_timer_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      system_id: %OpenApiSpex.Schema{type: :string},
      solar_system_name: %OpenApiSpex.Schema{type: :string},
      solar_system_id: %OpenApiSpex.Schema{type: :integer},
      structure_type_id: %OpenApiSpex.Schema{type: :integer},
      structure_type: %OpenApiSpex.Schema{type: :string},
      character_eve_id: %OpenApiSpex.Schema{type: :string},
      name: %OpenApiSpex.Schema{type: :string},
      notes: %OpenApiSpex.Schema{type: :string},
      owner_name: %OpenApiSpex.Schema{type: :string},
      owner_ticker: %OpenApiSpex.Schema{type: :string},
      owner_id: %OpenApiSpex.Schema{type: :string},
      status: %OpenApiSpex.Schema{type: :string},
      end_time: %OpenApiSpex.Schema{type: :string, format: :date_time}
    },
    required: ["system_id", "solar_system_id", "name", "status"]
  }

  @structure_timers_response_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: @structure_timer_schema
      }
    },
    required: ["data"]
  }

  @kill_item_schema %OpenApiSpex.Schema{
    type: :object,
    description: "Kill detail object",
    properties: %{
      kill_id: %OpenApiSpex.Schema{type: :integer, description: "Unique identifier for the kill"},
      kill_time: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Time when the kill occurred"},
      victim_id: %OpenApiSpex.Schema{type: :integer, description: "ID of the victim character"},
      victim_name: %OpenApiSpex.Schema{type: :string, description: "Name of the victim character"},
      ship_type_id: %OpenApiSpex.Schema{type: :integer, description: "Type ID of the destroyed ship"},
      ship_name: %OpenApiSpex.Schema{type: :string, description: "Name of the destroyed ship"}
    }
  }

  @system_kills_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      solar_system_id: %OpenApiSpex.Schema{type: :integer},
      kills: %OpenApiSpex.Schema{
        type: :array,
        items: @kill_item_schema
      }
    },
    required: ["solar_system_id", "kills"]
  }

  @systems_kills_response_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: @system_kills_schema
      }
    },
    required: ["data"]
  }


  @doc """
  GET /api/map/systems

  Requires either `?map_id=<UUID>` OR `?slug=<map-slug>` in the query params.
  Only "visible" systems are returned.
  """
  @spec list_systems(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :list_systems,
    summary: "List Map Systems",
    description: "Lists all visible systems for a map. Requires either 'map_id' or 'slug' as a query parameter to identify the map.",
    parameters: [
      map_id: [in: :query, description: "Map identifier (UUID)", type: :string, required: false, example: ""],
      slug:   [in: :query, description: "Map slug", type: :string, required: false, example: "map-name"]
    ],
    responses: [
      ok: {"List of map systems", "application/json", @list_map_systems_response_schema},
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{error: %OpenApiSpex.Schema{type: :string}},
        required: ["error"],
        example: %{"error" => "Must provide either ?map_id=UUID or ?slug=SLUG"}
      }}
    ]
  def list_systems(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, systems} <- MapSystemRepo.get_visible_by_map(map_id) do
      systems
      |> Enum.map(&map_system_to_json/1)
      |> then(&json(conn, %{data: &1}))
    else
      {:error, msg} when is_binary(msg) ->
        conn |> put_status(:bad_request) |> json(%{error: msg})
      {:error, reason} ->
        conn |> put_status(:not_found) |> json(%{error: "Could not fetch systems: #{inspect(reason)}"})
    end
  end

  @doc """
  GET /api/map/system

  Requires 'id' (the solar_system_id) and either ?map_id=<UUID> or ?slug=<map-slug>.
  """
  @spec show_system(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :show_system,
    summary: "Show Map System",
    description: "Retrieves details for a specific map system (by solar_system_id + map). Requires either 'map_id' or 'slug' as a query parameter to identify the map.",
    parameters: [
      id:     [in: :query, description: "System ID", type: :string, required: true, example: "30000142"],
      map_id: [in: :query, description: "Map identifier (UUID)", type: :string, required: false, example: ""],
      slug:   [in: :query, description: "Map slug", type: :string, required: false, example: "map-name"]
    ],
    responses: [
      ok: {"Map system details", "application/json", @show_map_system_response_schema},
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{error: %OpenApiSpex.Schema{type: :string}},
        required: ["error"],
        example: %{"error" => "Must provide either ?map_id=UUID or ?slug=SLUG as a query parameter"}
      }},
      not_found: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{error: %OpenApiSpex.Schema{type: :string}},
        required: ["error"],
        example: %{"error" => "System not found"}
      }}
    ]
  def show_system(conn, params) do
    with {:ok, solar_system_str} <- Util.require_param(params, "id"),
         {:ok, solar_system_id} <- Util.parse_int(solar_system_str),
         {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, system} <- MapSystemRepo.get_by_map_and_solar_system_id(map_id, solar_system_id) do
      json(conn, %{data: map_system_to_json(system)})
    else
      {:error, msg} when is_binary(msg) ->
        conn |> put_status(:bad_request) |> json(%{error: msg})
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "System not found"})
      {:error, reason} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "Could not load system: #{inspect(reason)}"})
    end
  end

  @doc """
  GET /api/map/tracked_characters_with_info

  Returns a list of tracked records along with their full `character` data.
  """
  @spec tracked_characters_with_info(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :tracked_characters_with_info,
    summary: "List Tracked Characters with Info",
    description: "Lists all tracked characters for a map with their information. Requires either 'map_id' or 'slug' as a query parameter to identify the map.",
    parameters: [
      map_id: [in: :query, description: "Map identifier (UUID)", type: :string, required: false, example: ""],
      slug:   [in: :query, description: "Map slug", type: :string, required: false, example: "map-name"]
    ],
    responses: [
      ok: {"List of tracked characters", "application/json", @tracked_characters_response_schema},
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{error: %OpenApiSpex.Schema{type: :string}},
        required: ["error"],
        example: %{"error" => "Must provide either ?map_id=UUID or ?slug=SLUG"}
      }}
    ]
    def tracked_characters_with_info(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
        {:ok, settings_list} <- get_tracked_by_map_ids(map_id),
        {:ok, char_list} <- read_characters_by_ids_wrapper(Enum.map(settings_list, & &1.character_id)) do
      chars_by_id = Map.new(char_list, &{&1.id, &1})
      data =
        Enum.map(settings_list, fn setting ->
          %{
            id: setting.id,
            map_id: setting.map_id,
            character_id: setting.character_id,
            tracked: setting.tracked,
            inserted_at: setting.inserted_at,
            updated_at: setting.updated_at,
            character:
              Map.get(chars_by_id, setting.character_id, %{})
              |> character_to_json()
          }
        end)
      json(conn, %{data: data})
    else
      {:error, "Must provide either ?map_id=UUID or ?slug=SLUG"} ->
        conn |> put_status(:bad_request) |> json(%{error: "Must provide either ?map_id=UUID or ?slug=SLUG as a query parameter"})
      {:error, :map_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Map not found. Please provide a valid map_id or slug as a query parameter."})
      {:error, :get_tracked_error, reason} ->
        conn |> put_status(:not_found) |> json(%{error: "No tracked records found for map_id: #{inspect(reason)}"})
      {:error, :read_characters_by_ids_error, reason} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "Could not load Character records: #{inspect(reason)}"})
      {:error, message} ->
        conn |> put_status(:bad_request) |> json(%{error: message})
    end
  end


  @doc """
  GET /api/map/structure_timers

  Returns structure timers for visible systems on the map
  or for a specific system if `system_id` is provided.
  """
  @spec show_structure_timers(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :show_structure_timers,
    summary: "Show Structure Timers",
    description: "Retrieves structure timers for a map. Requires either 'map_id' or 'slug' as a query parameter to identify the map.",
    parameters: [
      map_id: [in: :query, description: "Map identifier (UUID)", type: :string, required: false, example: ""],
      slug:   [in: :query, description: "Map slug", type: :string, required: false, example: "map-name"],
      system_id: [in: :query, description: "System ID", type: :string, required: false, example: "30000142"]
    ],
    responses: [
      ok: {"Structure timers", "application/json", @structure_timers_response_schema},
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{error: %OpenApiSpex.Schema{type: :string}},
        required: ["error"],
        example: %{"error" => "Must provide either ?map_id=UUID or ?slug=SLUG as a query parameter"}
      }}
    ]
  def show_structure_timers(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params) do
      case params["system_id"] do
        nil ->
          handle_all_structure_timers(conn, map_id)
        system_id_str ->
          with {:ok, system_id} <- Util.parse_int(system_id_str) do
            handle_single_structure_timers(conn, map_id, system_id)
          else
            {:error, reason} ->
              conn
              |> put_status(:bad_request)
              |> json(%{error: "system_id must be int: #{reason}"})
          end
      end
    else
      {:error, msg} ->
        conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  @doc """
  GET /api/map/systems_kills

  Returns kills data for all visible systems on the map, optionally filtered by hours.
  """
  @spec list_systems_kills(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :list_systems_kills,
    summary: "List Systems Kills",
    description: "Returns kills data for all visible systems on the map, optionally filtered by hours. Requires either 'map_id' or 'slug' as a query parameter to identify the map.",
    parameters: [
      map_id: [in: :query, description: "Map identifier (UUID)", type: :string, required: false, example: ""],
      slug:   [in: :query, description: "Map slug", type: :string, required: false, example: "map-name"],
      hours:  [in: :query, description: "Number of hours to look back for kills", type: :string, required: false, example: "24"]
    ],
    responses: [
      ok: {"Systems kills data", "application/json", @systems_kills_response_schema},
      bad_request: {"Error", "application/json", %OpenApiSpex.Schema{
        type: :object,
        properties: %{error: %OpenApiSpex.Schema{type: :string}},
        required: ["error"],
        example: %{"error" => "Must provide either ?map_id=UUID or ?slug=SLUG as a query parameter"}
      }}
    ]
  def list_systems_kills(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, systems} <- MapSystemRepo.get_visible_by_map(map_id) do
      hours_ago = parse_hours_ago(params["hours_ago"] || params["hour_ago"] || params["hours"])
      solar_ids = Enum.map(systems, & &1.solar_system_id)
      kills_map = KillsCache.fetch_cached_kills_for_systems(solar_ids)
      data =
        Enum.map(systems, fn sys ->
          kills = Map.get(kills_map, sys.solar_system_id, [])
          filtered_kills = maybe_filter_kills_by_time(kills, hours_ago)
          %{solar_system_id: sys.solar_system_id, kills: filtered_kills}
        end)
      json(conn, %{data: data})
    else
      {:error, msg} when is_binary(msg) ->
        Logger.warning("[list_systems_kills] Bad request: #{msg}")
        conn |> put_status(:bad_request) |> json(%{error: msg})
      {:error, reason} ->
        Logger.error("[list_systems_kills] Could not fetch systems: #{inspect(reason)}")
        conn |> put_status(:not_found) |> json(%{error: "Could not fetch systems: #{inspect(reason)}"})
    end
  end

  #------------------------------------------------------------------------------
  # Private Helper Functions
  #------------------------------------------------------------------------------
  defp parse_hours_ago(nil), do: nil

  defp parse_hours_ago(hours_str) do
    result =
      case Integer.parse(hours_str) do
        {num, ""} when num > 0 ->
          num
        {num, rest} ->
          nil
        :error ->
          nil
      end
    result
  end

  defp maybe_filter_kills_by_time(kills, hours_ago) when is_integer(hours_ago) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours_ago * 3600, :second)
    filtered = Enum.filter(kills, fn kill ->
      kill_time = kill["kill_time"]
      result =
        case kill_time do
          %DateTime{} = dt -> DateTime.compare(dt, cutoff) != :lt
          time when is_binary(time) ->
            case DateTime.from_iso8601(time) do
              {:ok, dt, _} -> DateTime.compare(dt, cutoff) != :lt
              _ -> false
            end
          _ -> false
        end
      result
    end)
    filtered
  end

  defp maybe_filter_kills_by_time(kills, nil), do: kills

  defp handle_all_structure_timers(conn, map_id) do
    case MapSystemRepo.get_visible_by_map(map_id) do
      {:ok, systems} ->
        systems
        |> Enum.flat_map(&get_timers_for_system/1)
        |> then(&json(conn, %{data: &1}))
      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Could not fetch visible systems for map_id=#{map_id}: #{inspect(reason)}"})
    end
  end

  defp handle_single_structure_timers(conn, map_id, system_id) do
    case MapSystemRepo.get_by_map_and_solar_system_id(map_id, system_id) do
      {:ok, map_system} ->
        json(conn, %{data: get_timers_for_system(map_system)})
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "No system with solar_system_id=#{system_id} in map=#{map_id}"})
      {:error, reason} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "Failed to retrieve system: #{inspect(reason)}"})
    end
  end

  defp get_timers_for_system(map_system) do
    WandererApp.Api.MapSystemStructure.by_system_id!(map_system.id)
    |> Enum.filter(&timer_needed?/1)
    |> Enum.map(&structure_to_timer_json/1)
  end

  defp timer_needed?(structure) do
    structure.status in ["Anchoring", "Reinforced"] and not is_nil(structure.end_time)
  end

  defp structure_to_timer_json(s) do
    Map.take(s, [
      :system_id,
      :solar_system_name,
      :solar_system_id,
      :structure_type_id,
      :structure_type,
      :character_eve_id,
      :name,
      :notes,
      :owner_name,
      :owner_ticker,
      :owner_id,
      :status,
      :end_time
    ])
  end

  defp get_tracked_by_map_ids(map_id) do
    case MapCharacterSettingsRepo.get_tracked_by_map_all(map_id) do
      {:ok, settings_list} -> {:ok, settings_list}
      {:error, reason}     -> {:error, :get_tracked_error, reason}
    end
  end

  defp read_characters_by_ids_wrapper(ids) do
    case read_characters_by_ids(ids) do
      {:ok, char_list} -> {:ok, char_list}
      {:error, reason} -> {:error, :read_characters_by_ids_error, reason}
    end
  end

  defp read_characters_by_ids(ids) when is_list(ids) do
    if ids == [] do
      {:ok, []}
    else
      query =
        Character
        |> filter(id in ^ids)

      Api.read(query)
    end
  end

  defp map_system_to_json(system) do
    original_name = get_original_system_name(system.solar_system_id)
    result = Map.take(system, [
      :id,
      :map_id,
      :solar_system_id,
      :custom_name,
      :temporary_name,
      :description,
      :tag,
      :labels,
      :locked,
      :visible,
      :status,
      :position_x,
      :position_y,
      :inserted_at,
      :updated_at
    ])
    result = Map.put(result, :original_name, original_name)
    display_name = cond do
      not is_nil(system.temporary_name) and system.temporary_name != "" ->
        system.temporary_name
      not is_nil(system.custom_name) and system.custom_name != "" ->
        system.custom_name
      true ->
        original_name
    end
    Map.put(result, :name, display_name)
  end

  defp get_original_system_name(solar_system_id) do
    case WandererApp.Api.MapSolarSystem.by_solar_system_id(solar_system_id) do
      {:ok, system} -> system.solar_system_name
      _ -> "Unknown System"
    end
  end

  defp character_to_json(%Ash.NotLoaded{}), do: %{}
  defp character_to_json(ch) when is_map(ch) do
    Map.take(ch, [
      :id,
      :eve_id,
      :name,
      :corporation_id,
      :corporation_name,
      :corporation_ticker,
      :alliance_id,
      :alliance_name,
      :alliance_ticker,
      :inserted_at,
      :updated_at
    ])
  end

end
