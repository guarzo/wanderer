defmodule WandererAppWeb.UtilAPIController do
  @moduledoc """
  Utility functions for parameter handling, fetch helpers, and shared JSON conversion methods.

  This module provides common functionality used across API controllers, including:
  - Parameter validation and fetching
  - Map ID resolution from slugs
  - UUID validation
  - Error formatting
  - JSON conversion utilities
  """

  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.Api
  alias WandererAppWeb.Schemas.ApiSchemas
  alias WandererAppWeb.Schemas.ResponseSchemas

  # -----------------------------------------------------------------
  # Schema Definitions
  # -----------------------------------------------------------------

  # Common utility schemas used across multiple controllers
  @error_schema ApiSchemas.error_response("Utility operation failed")

  @map_lookup_param_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      map_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        description: "Map ID (UUID format)",
        example: "466e922b-e758-485e-9b86-afae06b88363"
      },
      slug: %OpenApiSpex.Schema{
        type: :string,
        description: "Map slug (alternative to map_id)",
        example: "my-wormhole-map"
      }
    },
    description: "Parameters for identifying a map - requires either map_id or slug"
  }

  @map_system_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, description: "System ID", example: "466e922b-e758-485e-9b86-afae06b88363"},
      map_id: %OpenApiSpex.Schema{type: :string, description: "Map ID", example: "466e922b-e758-485e-9b86-afae06b88363"},
      solar_system_id: %OpenApiSpex.Schema{type: :string, description: "EVE solar system ID", example: "30000142"},
      original_name: %OpenApiSpex.Schema{type: :string, description: "Original EVE solar system name", example: "Jita"},
      name: %OpenApiSpex.Schema{type: :string, description: "Display name for the system", example: "J-Space Entry"},
      custom_name: %OpenApiSpex.Schema{type: :string, description: "User-defined system name", example: "J-Space Entry"},
      temporary_name: %OpenApiSpex.Schema{type: :string, description: "Temporary system name", example: "Unknown System"},
      description: %OpenApiSpex.Schema{type: :string, description: "System description", example: "Class 5 wormhole system"},
      tag: %OpenApiSpex.Schema{type: :string, description: "System tag", example: "C5"},
      labels: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string}, description: "System labels", example: ["dangerous", "occupied"]},
      locked: %OpenApiSpex.Schema{type: :boolean, description: "Whether the system is locked", example: false},
      visible: %OpenApiSpex.Schema{type: :boolean, description: "Whether the system is visible", example: true},
      status: %OpenApiSpex.Schema{type: :string, description: "System status", example: "active"},
      position_x: %OpenApiSpex.Schema{type: :number, description: "X position", example: 100},
      position_y: %OpenApiSpex.Schema{type: :number, description: "Y position", example: 200},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Creation timestamp"},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Last update timestamp"}
    },
    required: ["id", "map_id", "solar_system_id"],
    description: "Map system data structure with rendering information"
  }

  @connection_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, description: "Connection ID", example: "466e922b-e758-485e-9b86-afae06b88363"},
      map_id: %OpenApiSpex.Schema{type: :string, description: "Map ID", example: "466e922b-e758-485e-9b86-afae06b88363"},
      solar_system_source: %OpenApiSpex.Schema{type: :string, description: "Source system ID", example: "30000142"},
      solar_system_target: %OpenApiSpex.Schema{type: :string, description: "Target system ID", example: "31000005"},
      mass_status: %OpenApiSpex.Schema{type: :string, description: "Mass status", example: "stable"},
      time_status: %OpenApiSpex.Schema{type: :string, description: "Time status", example: "stable"},
      ship_size_type: %OpenApiSpex.Schema{type: :string, description: "Ship size restriction", example: "medium"},
      type: %OpenApiSpex.Schema{type: :string, description: "Connection type", example: "wormhole"},
      wormhole_type: %OpenApiSpex.Schema{type: :string, description: "Wormhole type code", example: "K162"},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Creation timestamp"},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Last update timestamp"}
    },
    required: ["id", "map_id", "solar_system_source", "solar_system_target"],
    description: "Connection between two systems"
  }

  # -----------------------------------------------------------------
  # Map ID Resolution Functions
  # -----------------------------------------------------------------

  @doc """
  Fetches a map ID from parameters, either directly using the 'map_id' key
  or by looking up the map using its slug.

  Returns:
    - `{:ok, map_id}` - When map_id is found directly or via slug
    - `{:error, reason}` - When map_id cannot be resolved
  """
  def fetch_map_id(%{"map_id" => mid}) when is_binary(mid) and mid != "" do
    {:ok, mid}
  end

  def fetch_map_id(%{"slug" => slug}) when is_binary(slug) and slug != "" do
    case Api.Map.get_map_by_slug(slug) do
      {:ok, map} ->
        {:ok, map.id}

      {:error, _reason} ->
        {:error, "No map found for slug=#{slug}"}
    end
  end

  def fetch_map_id(_),
    do: {:error, "Must provide either ?map_id=UUID or ?slug=SLUG"}

  # -----------------------------------------------------------------
  # Parameter Validation Functions
  # -----------------------------------------------------------------

  @doc """
  Ensures a required parameter is present and non-empty.

  Returns:
    - `{:ok, value}` - When param exists and is not empty
    - `{:error, reason}` - When param is missing or empty
  """
  def require_param(params, key) do
    case params[key] do
      nil -> {:error, "Missing required param: #{key}"}
      "" -> {:error, "Param #{key} cannot be empty"}
      val -> {:ok, val}
    end
  end

  @doc """
  Parses a string into an integer.

  Returns:
    - `{:ok, integer}` - When string can be parsed as an integer
    - `{:error, reason}` - When string cannot be parsed
  """
  def parse_int(str) do
    case Integer.parse(str) do
      {num, ""} -> {:ok, num}
      _ -> {:error, "Invalid integer for param id=#{str}"}
    end
  end

  @doc """
  Parses a string into an integer, raising an error if parsing fails.

  Returns:
    - `integer` - When string can be parsed as an integer
    - Raises an error when string cannot be parsed
  """
  def parse_int!(str) do
    case Integer.parse(str) do
      {num, ""} -> num
      _ -> raise "Invalid integer for param id=#{str}"
    end
  end

  @doc """
  Validates that a string is a valid UUID.

  Returns:
    - `{:ok, uuid}` - When the string is a valid UUID
    - `{:error, reason}` - When the string is not a valid UUID
  """
  def validate_uuid(nil), do: {:error, "ID cannot be nil"}

  def validate_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> {:ok, id}
      :error -> {:error, "Invalid UUID format"}
    end
  end

  def validate_uuid(_), do: {:error, "ID must be a string"}

  # -----------------------------------------------------------------
  # Error Handling Functions
  # -----------------------------------------------------------------

  @doc """
  Creates a standardized error response following the API standards.

  ## Parameters
    - conn: The connection struct
    - status: HTTP status code (e.g., :bad_request, :not_found)
    - error: Brief error message
    - details: Optional detailed explanation of the error
    - code: Optional error code for client applications

  ## Returns
    - A connection with the appropriate status and JSON error response
  """
  def standardized_error_response(conn, status, error, details \\ nil, code \\ nil) do
    response = %{error: error}

    # Add details if provided
    response = if details, do: Map.put(response, :details, details), else: response

    # Add code if provided
    response = if code, do: Map.put(response, :code, code), else: response

    conn
    |> put_status(status)
    |> json(response)
  end

  @doc """
  Formats error responses in a standardized way.

  This function handles various error types and converts them to
  human-readable error messages.
  """
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(:not_found), do: "Resource not found"
  def format_error({:not_found, resource}), do: "#{resource} not found"
  def format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_error(_reason), do: "An error occurred"

  @doc """
  Handles the result of destroy operations.

  This handles various result formats from destroy operations to
  provide a consistent return value.

  Returns:
    - `:ok` - When destruction was successful
    - `{:error, reason}` - When destruction failed
  """
  def handle_destroy_result(:ok), do: :ok
  def handle_destroy_result({:ok, _}), do: :ok
  # Handle Ash bulk result structs specifically
  def handle_destroy_result(%Ash.BulkResult{status: :success}), do: :ok
  def handle_destroy_result(%Ash.BulkResult{status: :error, errors: errors}), do: {:error, errors}
  # Catch-all for other potential error tuples/values
  def handle_destroy_result(error), do: {:error, error}

  # -----------------------------------------------------------------
  # JSON Conversion Functions
  # -----------------------------------------------------------------

  @doc """
  Converts a map with string keys to a map with atom keys.

  Only converts keys that are in the allowed_keys list to prevent
  atom table pollution.
  """
  def atomize_keys(map) do
    allowed_keys = [
      :id,
      :solar_system_id,
      :position_x,
      :position_y,
      :status,
      :description,
      :map_id,
      :locked,
      :visible,
      :solar_system_source,
      :solar_system_target,
      :type,
      :name,
      :author_id,
      :author_eve_id,
      :category,
      :is_public,
      :source_map_id,
      :systems,
      :connections,
      :metadata,
      :mass_status,
      :time_status,
      :ship_size_type,
      :wormhole_type,
      :count_of_passage,
      :custom_info,
      :tag,
      :custom_name,
      :temporary_name,
      :labels
    ]

    # First normalize author_eve_id to author_id if present
    normalized_map =
      if Map.has_key?(map, "author_eve_id") do
        author_id = Map.get(map, "author_eve_id")

        map
        |> Map.put("author_id", author_id)
        |> Map.delete("author_eve_id")
      else
        map
      end

    normalized_map
    |> Enum.flat_map(fn
      {k, v} when is_binary(k) ->
        try do
          key_atom = String.to_existing_atom(k)

          if Enum.member?(allowed_keys, key_atom) do
            [{key_atom, v}]
          else
            []
          end
        rescue
          ArgumentError -> []
        end

      entry ->
        [entry]
    end)
    |> Map.new()
  end

  @doc """
  Converts a map system struct to a JSON-compatible map.

  Adds the original system name and determines the displayed name
  according to priority rules.
  """
  def map_system_to_json(system) do
    # Check if we're dealing with a temporary system (from error handling)
    if Map.get(system, :temporary) do
      # For temporary systems, just pass through the basic fields and mark as temporary
      result = Map.take(system, [
        :id,
        :map_id,
        :solar_system_id,
        :name,
        :description,
        :position_x,
        :position_y,
        :status,
        :visible
      ])
      Map.put(result, :temporary, true)
    else
      # Normal system processing for database-stored systems
      # Get the original system name from the database
      original_name = get_original_system_name(system.solar_system_id)

      # Start with the basic system data
      result =
        Map.take(system, [
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

      # Add the original name
      result = Map.put(result, :original_name, original_name)

      # Set the name field based on the display priority:
      # 1. If temporary_name is set, use that
      # 2. If custom_name is set, use that
      # 3. Otherwise, use the original system name
      display_name =
        cond do
          not is_nil(system.temporary_name) and system.temporary_name != "" ->
            system.temporary_name

          not is_nil(system.custom_name) and system.custom_name != "" ->
            system.custom_name

          true ->
            original_name
        end

      # Add the display name as the "name" field
      Map.put(result, :name, display_name)
    end
  end

  @doc """
  Converts a connection struct to a JSON-compatible map.
  """
  def connection_to_json(connection) do
    # Handle maps, structs, and our temporary connection objects
    base_fields = [
      :id,
      :map_id,
      :solar_system_source,
      :solar_system_target,
      :mass_status,
      :time_status,
      :ship_size_type,
      :type,
      :wormhole_type,
      :inserted_at,
      :updated_at
    ]

    # For our placeholder temporary connections, we may not have all fields
    result = Map.take(connection, base_fields)

    # If this is a temporary connection (created as a placeholder during error handling),
    # we need to add the temporary flag
    if Map.get(connection, :temporary) do
      Map.put(result, :temporary, true)
    else
      result
    end
  end

  # -----------------------------------------------------------------
  # Private Helper Functions
  # -----------------------------------------------------------------

  # Get original system name
  defp get_original_system_name(solar_system_id) do
    # Fetch the original system name from the MapSolarSystem resource
    case WandererApp.Api.MapSolarSystem.by_solar_system_id(solar_system_id) do
      {:ok, system} ->
        system.solar_system_name

      _error ->
        "Unknown System"
    end
  end

  @doc """
  Creates a standardized not found error response.

  ## Parameters
    - conn: The connection struct
    - message: Brief error message

  ## Returns
    - A connection with 404 status and JSON error response
  """
  def error_not_found(conn, message) do
    standardized_error_response(conn, :not_found, message, "The requested resource could not be found")
  end
end
