defmodule WandererAppWeb.MapAPIController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import Ash.Query, only: [filter: 2]
  require Logger

  alias WandererApp.Api
  alias WandererApp.Api.Character
  alias WandererApp.MapSystemRepo
  alias WandererApp.MapCharacterSettingsRepo
  alias WandererApp.Zkb.KillsProvider.KillsCache
  alias WandererAppWeb.UtilAPIController, as: Util

  # -----------------------------------------------------------------
  # Inline Schemas
  # -----------------------------------------------------------------

  @map_system_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string},
      map_id: %OpenApiSpex.Schema{type: :string},
      solar_system_id: %OpenApiSpex.Schema{type: :integer},
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
    required: ["id", "solar_system_id", "name"]
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
    properties: %{
      data: @map_system_schema
    },
    required: ["data"]
  }

  # For operation :tracked_characters_with_info
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

  # For operation :show_structure_timers
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

  # For operation :list_systems_kills
  @kill_item_schema %OpenApiSpex.Schema{
    # Could refine if you know the shape
    type: :object,
    description: "Kill detail object"
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

  # -----------------------------------------------------------------
  # ENDPOINTS
  # -----------------------------------------------------------------

  @doc """
  GET /api/map/systems

  Requires either `?map_id=<UUID>` **OR** `?slug=<map-slug>`.
  """
  @spec list_systems(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :list_systems,
    summary: "List Map Systems",
    description: "Retrieves visible systems for a given map.",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID)",
        type: :string,
        required: false
      ],
      slug: [
        in: :query,
        description: "Map slug",
        type: :string,
        required: false
      ]
    ],
    responses: [
      ok: {
        "List of map systems",
        "application/json",
        @list_map_systems_response_schema
      }
    ]
  def list_systems(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, systems} <- MapSystemRepo.get_visible_by_map(map_id) do
      data = Enum.map(systems, &map_system_to_json/1)
      json(conn, %{data: data})
    else
      {:error, msg} when is_binary(msg) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Could not fetch systems: #{inspect(reason)}"})
    end
  end

  @doc """
  GET /api/map/system

  Requires 'id' (the solar_system_id) plus either ?map_id=<UUID> or ?slug=<map-slug>.
  """
  @spec show_system(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :show_system,
    summary: "Show Map System",
    description: "Retrieves details for a specific map system (by solar_system_id + map).",
    parameters: [
      id: [
        in: :query,
        description: "Solar system ID",
        type: :string,
        required: true,
        example: "31002229"
      ],
      map_id: [
        in: :query,
        description: "Map identifier (UUID)",
        type: :string,
        required: false
      ],
      slug: [
        in: :query,
        description: "Map slug",
        type: :string,
        required: false
      ]
    ],
    responses: [
      ok: {
        "Map system details",
        "application/json",
        @show_map_system_response_schema
      }
    ]
  def show_system(conn, params) do
    with {:ok, solar_system_str} <- Util.require_param(params, "id"),
         {:ok, solar_system_id} <- Util.parse_int(solar_system_str),
         {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, system} <- MapSystemRepo.get_by_map_and_solar_system_id(map_id, solar_system_id) do
      data = map_system_to_json(system)
      json(conn, %{data: data})
    else
      {:error, msg} when is_binary(msg) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "System not found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Could not load system: #{inspect(reason)}"})
    end
  end

  @doc """
  GET /api/map/tracked_characters_with_info
  """
  @spec tracked_characters_with_info(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :tracked_characters_with_info,
    summary: "List Tracked Characters with Info",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID)",
        type: :string,
        required: false
      ],
      slug: [
        in: :query,
        description: "Map slug",
        type: :string,
        required: false
      ]
    ],
    responses: [
      ok: {
        "Tracked characters with info",
        "application/json",
        @tracked_characters_response_schema
      }
    ]
  def tracked_characters_with_info(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, settings_list} <- get_tracked_by_map_ids(map_id),
         {:ok, char_list} <- read_characters_by_ids_wrapper(Enum.map(settings_list, & &1.character_id)) do
      chars_by_id = Map.new(char_list, &{&1.id, &1})

      data =
        Enum.map(settings_list, fn setting ->
          found_char = Map.get(chars_by_id, setting.character_id)

          %{
            id: setting.id,
            map_id: setting.map_id,
            character_id: setting.character_id,
            tracked: setting.tracked,
            inserted_at: setting.inserted_at,
            updated_at: setting.updated_at,
            character:
              if found_char do
                character_to_json(found_char)
              else
                %{}
              end
          }
        end)

      json(conn, %{data: data})
    else
      {:error, :get_tracked_error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No tracked records found for map_id: #{inspect(reason)}"})

      {:error, :read_characters_by_ids_error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Could not load Character records: #{inspect(reason)}"})

      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})
    end
  end

  @doc """
  GET /api/map/structure_timers
  """
  @spec show_structure_timers(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :show_structure_timers,
    summary: "Show Structure Timers",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID)",
        type: :string,
        required: true
      ],
      slug: [
        in: :query,
        description: "Map slug",
        type: :string,
        required: false
      ],
      system_id: [
        in: :query,
        description: "Solar system ID (optional)",
        type: :string,
        required: false,
        example: "31002229"
      ]
    ],
    responses: [
      ok: {
        "Structure timers",
        "application/json",
        @structure_timers_response_schema
      }
    ]
  def show_structure_timers(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params) do
      system_id_str = params["system_id"]

      case system_id_str do
        nil ->
          handle_all_structure_timers(conn, map_id)

        _ ->
          case Util.parse_int(system_id_str) do
            {:ok, system_id} ->
              handle_single_structure_timers(conn, map_id, system_id)

            {:error, reason} ->
              conn
              |> put_status(:bad_request)
              |> json(%{error: "system_id must be int: #{reason}"})
          end
      end
    else
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})
    end
  end

  @doc """
  GET /api/map/systems_kills

  Returns kills data for all *visible* systems on the map.
  """
  @spec list_systems_kills(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :list_systems_kills,
    summary: "List Systems Kills",
    description: "Returns kills data for all visible systems on the map, optionally filtered by hours_ago.",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID)",
        type: :string,
        required: false
      ],
      slug: [
        in: :query,
        description: "Map slug",
        type: :string,
        required: false
      ],
      hours_ago: [
        in: :query,
        description: "Optional number of hours to filter kills",
        type: :string,
        required: false
      ]
    ],
    responses: [
      ok: {
        "Systems kills data",
        "application/json",
        @systems_kills_response_schema
      }
    ]
  def list_systems_kills(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         {:ok, systems} <- MapSystemRepo.get_visible_by_map(map_id) do

      Logger.debug(fn ->
        "[list_systems_kills] Found #{length(systems)} visible systems for map_id=#{map_id}"
      end)

      hours_ago = parse_hours_ago(params["hours_ago"])

      solar_ids = Enum.map(systems, & &1.solar_system_id)
      kills_map = KillsCache.fetch_cached_kills_for_systems(solar_ids)

      data =
        Enum.map(systems, fn sys ->
          kills = Map.get(kills_map, sys.solar_system_id, [])
          filtered_kills = maybe_filter_kills_by_time(kills, hours_ago)

          Logger.debug(fn ->
            "[list_systems_kills] system_id=#{sys.solar_system_id}, total=#{length(kills)}, filtered=#{length(filtered_kills)}"
          end)

          %{
            solar_system_id: sys.solar_system_id,
            kills: filtered_kills
          }
        end)

      json(conn, %{data: data})
    else
      {:error, msg} when is_binary(msg) ->
        Logger.warning("[list_systems_kills] Bad request: #{msg}")
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, reason} ->
        Logger.error("[list_systems_kills] Could not fetch systems: #{inspect(reason)}")
        conn
        |> put_status(:not_found)
        |> json(%{error: "Could not fetch systems: #{inspect(reason)}"})
    end
  end

  # -----------------------------------------------------------------
  # Private helpers
  # -----------------------------------------------------------------

  defp parse_hours_ago(nil), do: nil
  defp parse_hours_ago(hours_str) do
    case Integer.parse(hours_str) do
      {num, ""} when num > 0 -> num
      _ -> nil
    end
  end

  defp maybe_filter_kills_by_time(kills, hours_ago) when is_integer(hours_ago) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours_ago * 3600, :second)

    Enum.filter(kills, fn kill ->
      kill_time = kill["kill_time"]
      case kill_time do
        %DateTime{} = dt -> DateTime.compare(dt, cutoff) != :lt
        _ -> false
      end
    end)
  end

  defp maybe_filter_kills_by_time(kills, nil), do: kills

  defp handle_all_structure_timers(conn, map_id) do
    case MapSystemRepo.get_visible_by_map(map_id) do
      {:ok, systems} ->
        all_timers =
          systems
          |> Enum.flat_map(&get_timers_for_system/1)

        json(conn, %{data: all_timers})

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Could not fetch visible systems for map_id=#{map_id}: #{inspect(reason)}"})
    end
  end

  defp handle_single_structure_timers(conn, map_id, system_id) do
    case MapSystemRepo.get_by_map_and_solar_system_id(map_id, system_id) do
      {:ok, map_system} ->
        timers = get_timers_for_system(map_system)
        json(conn, %{data: timers})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No system with solar_system_id=#{system_id} in map=#{map_id}"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to retrieve system: #{inspect(reason)}"})
    end
  end

  defp get_timers_for_system(map_system) do
    structures = WandererApp.Api.MapSystemStructure.by_system_id!(map_system.id)

    structures
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
      {:ok, char_list} ->
        {:ok, char_list}

      {:error, reason} ->
        {:error, :read_characters_by_ids_error, reason}
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
    Map.take(system, [
      :id,
      :map_id,
      :solar_system_id,
      :name,
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
  end

  defp character_to_json(ch) do
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
