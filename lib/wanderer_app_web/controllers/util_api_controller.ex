defmodule WandererAppWeb.UtilAPIController do
  @moduledoc """
  Utility functions for parameter handling, fetch helpers, etc.
  """

  alias WandererApp.Api

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

  # Require a given param to be present and non-empty
  def require_param(params, key) do
    case params[key] do
      nil -> {:error, "Missing required param: #{key}"}
      "" -> {:error, "Param #{key} cannot be empty"}
      val -> {:ok, val}
    end
  end

  # Parse a string into an integer
  def parse_int(str) do
    case Integer.parse(str) do
      {num, ""} -> {:ok, num}
      _ -> {:error, "Invalid integer for param id=#{str}"}
    end
  end

  # Validate that an ID is a valid UUID
  def validate_uuid(nil), do: {:error, "ID cannot be nil"}

  def validate_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> {:ok, id}
      :error -> {:error, "Invalid UUID format"}
    end
  end

  def validate_uuid(_), do: {:error, "ID must be a string"}

  # Format an error response with a standardized structure
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(:not_found), do: "Resource not found"
  def format_error({:not_found, resource}), do: "#{resource} not found"
  def format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_error(_reason), do: "An error occurred"

  # Convert string keys to atoms (safely)
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

  # JSON conversion for map systems
  def map_system_to_json(system) do
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

  # JSON conversion for connections
  def connection_to_json(connection) do
    Map.take(connection, [
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
    ])
  end

  # Helper to handle different return values from destroy operations
  def handle_destroy_result(:ok), do: :ok
  def handle_destroy_result({:ok, _}), do: :ok
  # Handle Ash bulk result structs specifically
  def handle_destroy_result(%Ash.BulkResult{status: :success}), do: :ok
  def handle_destroy_result(%Ash.BulkResult{status: :error, errors: errors}), do: {:error, errors}
  # Catch-all for other potential error tuples/values
  def handle_destroy_result(error), do: {:error, error}
end
