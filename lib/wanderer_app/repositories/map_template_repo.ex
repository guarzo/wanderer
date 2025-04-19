defmodule WandererApp.MapTemplateRepo do
  @moduledoc """
  Repository for map templates operations.
  """

  use WandererApp, :repository

  alias WandererApp.Api.MapTemplate
  alias WandererApp.MapSystemRepo
  alias WandererApp.MapConnectionRepo

  @doc """
  Creates a new template.
  """
  def create(template_params) do
    MapTemplate.create(template_params)
  end

  @doc """
  Gets a template by ID.
  """
  def get(id) do
    MapTemplate.get(id)
  end

  @doc """
  Lists all public templates.
  """
  def list_public do
    MapTemplate.list_public()
  end

  @doc """
  Lists templates created by a specific author.
  """
  def list_by_author(author_id) do
    MapTemplate.list_by_author(%{author_id: author_id})
  end

  @doc """
  Lists templates of a specific category.
  """
  def list_by_category(category) do
    MapTemplate.list_by_category(%{category: category})
  end

  @doc """
  Updates the metadata of a template.
  """
  def update_metadata(template, params) do
    MapTemplate.update_metadata(template, params)
  end

  @doc """
  Updates the content of a template.
  """
  def update_content(template, params) do
    MapTemplate.update_content(template, params)
  end

  @doc """
  Deletes a template.
  """
  def destroy(template) do
    MapTemplate.destroy(template)
  end

  @doc """
  Creates a template from an existing map.

  Takes a map ID and template parameters, extracts the systems and connections,
  and creates a new template.
  """
  def create_from_map(map_id, template_params) do
    with {:ok, systems} <- MapSystemRepo.get_all_by_map(map_id),
         {:ok, connections} <- MapConnectionRepo.get_by_map(map_id) do

      # Filter systems based on selection parameters
      selected_systems = filter_systems_by_selection(systems, template_params)

      # Get only connections between selected systems
      selected_connections = filter_connections_for_selected_systems(connections, selected_systems)

      # Transform systems to template format with relative positions
      systems_data = prepare_systems_for_template(selected_systems)

      # Transform connections to template format using system indices
      connections_data = prepare_connections_for_template(selected_connections, selected_systems)

      # Create template record
      template_data = %{
        name: Map.get(template_params, "name", "Unnamed Template"),
        description: Map.get(template_params, "description", ""),
        category: Map.get(template_params, "category", "custom"),
        author_id: Map.get(template_params, "author_id"),
        source_map_id: map_id,
        is_public: Map.get(template_params, "is_public", false),
        systems: systems_data,
        connections: connections_data,
        metadata: Map.get(template_params, "metadata", %{})
      }

      create(template_data)
    end
  end

  @doc """
  Applies a template to a map.

  Takes a map ID, template ID, and options, and applies the template to the map.
  """
  def apply_template(map_id, template_id, options \\ %{}) do
    with {:ok, template} <- get(template_id),
         {:ok, existing_systems} <- MapSystemRepo.get_all_by_map(map_id) do

      # Calculate position offset based on strategy
      position_offset = calculate_position_offset(template, existing_systems, options)

      # Apply transformations (scaling, rotation) if specified
      transformed_systems = apply_transformations(template.systems, options)

      # Create new systems with adjusted positions
      {:ok, created_systems} = create_systems_from_template(
        map_id,
        transformed_systems,
        position_offset,
        Map.get(options, "merge_strategy", "skip_existing")
      )

      # Create connections between the new systems
      {:ok, created_connections} = create_connections_from_template(
        map_id,
        template.connections,
        created_systems
      )

      {:ok, %{
        systems: created_systems,
        connections: created_connections,
        summary: %{
          systems_added: length(created_systems),
          connections_added: length(created_connections)
        }
      }}
    end
  end

  # Filter systems based on selection parameters
  defp filter_systems_by_selection(systems, params) do
    cond do
      # Option 1: Explicit system IDs provided
      not is_nil(Map.get(params, "system_ids")) ->
        system_ids = Map.get(params, "system_ids")
        Enum.filter(systems, &(&1.id in system_ids))

      # Option 2: Bounding box selection
      not is_nil(Map.get(params, "bounds")) ->
        bounds = Map.get(params, "bounds")
        Enum.filter(systems, fn system ->
          system.position_x >= bounds["min_x"] and
          system.position_x <= bounds["max_x"] and
          system.position_y >= bounds["min_y"] and
          system.position_y <= bounds["max_y"]
        end)

      # Option 3: System type/category filter
      not is_nil(Map.get(params, "filter")) ->
        filter = Map.get(params, "filter")
        Enum.filter(systems, fn system ->
          cond do
            not is_nil(filter["region_id"]) ->
              # Filter by region (would need to look up solar_system_id -> region mapping)
              region_for_system(system.solar_system_id) == filter["region_id"]

            not is_nil(filter["security_class"]) ->
              # Filter by security status (highsec, lowsec, nullsec, wormhole)
              security_class_for_system(system.solar_system_id) == filter["security_class"]

            not is_nil(filter["tag"]) ->
              # Filter by system tag
              system.tag == filter["tag"]

            true -> false
          end
        end)

      # Default: Include all systems
      true ->
        systems
    end
  end

  # Get only connections between selected systems
  defp filter_connections_for_selected_systems(connections, selected_systems) do
    # Create a set of system IDs for quick lookup
    system_ids = MapSet.new(selected_systems, & &1.id)

    # Keep only connections where both source and target are in selected systems
    Enum.filter(connections, fn connection ->
      source_system = Enum.find(selected_systems, &(&1.solar_system_id == connection.solar_system_source))
      target_system = Enum.find(selected_systems, &(&1.solar_system_id == connection.solar_system_target))

      not is_nil(source_system) and not is_nil(target_system)
    end)
  end

  # Prepare systems for template - calculate relative positions
  defp prepare_systems_for_template(systems) do
    # Find the center of the selected systems
    {center_x, center_y} = calculate_center(systems)

    # Convert systems to template format with relative positions
    systems
    |> Enum.map(fn system ->
      %{
        solar_system_id: system.solar_system_id,
        relative_position_x: system.position_x - center_x,
        relative_position_y: system.position_y - center_y,
        custom_properties: extract_system_custom_properties(system)
      }
    end)
  end

  # Calculate the center point of a set of systems
  defp calculate_center(systems) do
    if Enum.empty?(systems) do
      {0, 0}
    else
      sum_x = Enum.sum(Enum.map(systems, & &1.position_x))
      sum_y = Enum.sum(Enum.map(systems, & &1.position_y))
      count = length(systems)

      {div(sum_x, count), div(sum_y, count)}
    end
  end

  # Extract custom properties from a system
  defp extract_system_custom_properties(system) do
    properties = %{}

    properties = if not is_nil(system.custom_name), do: Map.put(properties, "custom_name", system.custom_name), else: properties
    properties = if not is_nil(system.description), do: Map.put(properties, "description", system.description), else: properties
    properties = if not is_nil(system.tag), do: Map.put(properties, "tag", system.tag), else: properties
    properties = if not is_nil(system.temporary_name), do: Map.put(properties, "temporary_name", system.temporary_name), else: properties
    properties = if not is_nil(system.labels), do: Map.put(properties, "labels", system.labels), else: properties
    properties = if not is_nil(system.status), do: Map.put(properties, "status", system.status), else: properties

    properties
  end

  # Prepare connections for template - convert to use indices instead of IDs
  defp prepare_connections_for_template(connections, systems) do
    # Create a map of solar_system_id to index
    system_indices = Map.new(Enum.with_index(systems), fn {system, index} -> {system.solar_system_id, index} end)

    # Convert connections to template format with system indices
    connections
    |> Enum.map(fn connection ->
      source_index = Map.get(system_indices, connection.solar_system_source)
      target_index = Map.get(system_indices, connection.solar_system_target)

      if not is_nil(source_index) and not is_nil(target_index) do
        %{
          source_index: source_index,
          target_index: target_index,
          type: connection.type,
          custom_properties: extract_connection_custom_properties(connection)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Extract custom properties from a connection
  defp extract_connection_custom_properties(connection) do
    properties = %{}

    properties = if not is_nil(connection.mass_status), do: Map.put(properties, "mass_status", connection.mass_status), else: properties
    properties = if not is_nil(connection.time_status), do: Map.put(properties, "time_status", connection.time_status), else: properties
    properties = if not is_nil(connection.ship_size_type), do: Map.put(properties, "ship_size_type", connection.ship_size_type), else: properties
    properties = if not is_nil(connection.wormhole_type), do: Map.put(properties, "wormhole_type", connection.wormhole_type), else: properties
    properties = if not is_nil(connection.custom_info), do: Map.put(properties, "custom_info", connection.custom_info), else: properties

    properties
  end

  # Calculate the position offset for the template based on the strategy
  defp calculate_position_offset(template, existing_systems, options) do
    strategy = Map.get(options, "position_strategy", "center")

    case strategy do
      "center" ->
        # Place template at the center of existing systems
        {center_x, center_y} = calculate_center(existing_systems)
        {center_x, center_y}

      "north" ->
        # Place template north of existing systems
        {center_x, min_y} = calculate_north_position(existing_systems)
        {center_x, min_y - 300}  # Add some padding

      "preserve" ->
        # Use original positions as stored in the template
        {0, 0}

      "absolute" ->
        # Use specific coordinates provided in options
        x = Map.get(options, "position_x", 0)
        y = Map.get(options, "position_y", 0)
        {x, y}

      "relative" ->
        # Position relative to a specific system
        reference_system_id = Map.get(options, "reference_system_id")
        reference_system = Enum.find(existing_systems, &(&1.id == reference_system_id))

        if reference_system do
          {reference_system.position_x, reference_system.position_y}
        else
          {0, 0}
        end
    end
  end

  # Calculate the northernmost position of existing systems
  defp calculate_north_position(systems) do
    if Enum.empty?(systems) do
      {0, 0}
    else
      min_y = Enum.min_by(systems, & &1.position_y).position_y
      sum_x = Enum.sum(Enum.map(systems, & &1.position_x))
      count = length(systems)

      {div(sum_x, count), min_y}
    end
  end

  # Apply transformations to template systems
  defp apply_transformations(systems, options) do
    scale_factor = Map.get(options, "scale_factor", 1.0)
    rotation_degrees = Map.get(options, "rotation_degrees", 0)

    if scale_factor == 1.0 and rotation_degrees == 0 do
      # No transformation needed
      systems
    else
      # Apply scaling and rotation
      systems
      |> Enum.map(fn system ->
        # Apply scaling
        scaled_x = system["relative_position_x"] * scale_factor
        scaled_y = system["relative_position_y"] * scale_factor

        # Apply rotation if needed
        {final_x, final_y} = if rotation_degrees != 0 do
          rotation_radians = :math.pi() * rotation_degrees / 180
          cos_theta = :math.cos(rotation_radians)
          sin_theta = :math.sin(rotation_radians)

          rotated_x = scaled_x * cos_theta - scaled_y * sin_theta
          rotated_y = scaled_x * sin_theta + scaled_y * cos_theta

          {rotated_x, rotated_y}
        else
          {scaled_x, scaled_y}
        end

        # Update the system with transformed coordinates
        system
        |> Map.put("relative_position_x", round(final_x))
        |> Map.put("relative_position_y", round(final_y))
      end)
    end
  end

  # Create systems from a template
  defp create_systems_from_template(map_id, template_systems, {offset_x, offset_y}, merge_strategy) do
    # Convert template systems to maps for bulk creation
    systems_to_create = template_systems
    |> Enum.map(fn system ->
      # Basic system properties
      system_map = %{
        map_id: map_id,
        solar_system_id: system["solar_system_id"],
        position_x: system["relative_position_x"] + offset_x,
        position_y: system["relative_position_y"] + offset_y,
        visible: true
      }

      # Add custom properties if present
      custom_props = Map.get(system, "custom_properties", %{})

      system_map = if Map.has_key?(custom_props, "custom_name"), do: Map.put(system_map, :custom_name, custom_props["custom_name"]), else: system_map
      system_map = if Map.has_key?(custom_props, "description"), do: Map.put(system_map, :description, custom_props["description"]), else: system_map
      system_map = if Map.has_key?(custom_props, "tag"), do: Map.put(system_map, :tag, custom_props["tag"]), else: system_map
      system_map = if Map.has_key?(custom_props, "temporary_name"), do: Map.put(system_map, :temporary_name, custom_props["temporary_name"]), else: system_map
      system_map = if Map.has_key?(custom_props, "labels"), do: Map.put(system_map, :labels, custom_props["labels"]), else: system_map
      system_map = if Map.has_key?(custom_props, "status"), do: Map.put(system_map, :status, custom_props["status"]), else: system_map

      system_map
    end)

    # Create systems
    case MapSystemRepo.bulk_create(systems_to_create) do
      {:ok, created_systems} -> {:ok, created_systems}
      error -> error
    end
  end

  # Create connections from a template
  defp create_connections_from_template(map_id, template_connections, created_systems) do
    # Create a map of index to created system ID
    system_map = Map.new(Enum.with_index(created_systems), fn {system, index} -> {index, system} end)

    # Convert template connections to maps for bulk creation
    connections_to_create = template_connections
    |> Enum.map(fn connection ->
      source_system = Map.get(system_map, connection["source_index"])
      target_system = Map.get(system_map, connection["target_index"])

      if not is_nil(source_system) and not is_nil(target_system) do
        # Basic connection properties
        connection_map = %{
          map_id: map_id,
          solar_system_source: source_system.solar_system_id,
          solar_system_target: target_system.solar_system_id,
          type: connection["type"]
        }

        # Add custom properties if present
        custom_props = Map.get(connection, "custom_properties", %{})

        connection_map = if Map.has_key?(custom_props, "mass_status"), do: Map.put(connection_map, :mass_status, custom_props["mass_status"]), else: connection_map
        connection_map = if Map.has_key?(custom_props, "time_status"), do: Map.put(connection_map, :time_status, custom_props["time_status"]), else: connection_map
        connection_map = if Map.has_key?(custom_props, "ship_size_type"), do: Map.put(connection_map, :ship_size_type, custom_props["ship_size_type"]), else: connection_map
        connection_map = if Map.has_key?(custom_props, "wormhole_type"), do: Map.put(connection_map, :wormhole_type, custom_props["wormhole_type"]), else: connection_map
        connection_map = if Map.has_key?(custom_props, "custom_info"), do: Map.put(connection_map, :custom_info, custom_props["custom_info"]), else: connection_map

        connection_map
      end
    end)
    |> Enum.reject(&is_nil/1)

    # Create connections
    case MapConnectionRepo.bulk_create(connections_to_create) do
      {:ok, created_connections} -> {:ok, created_connections}
      error -> error
    end
  end

  # Helper functions for region and security class lookups
  defp region_for_system(solar_system_id) do
    # This would need to be implemented using a lookup from EVE data
    # For now, return nil
    nil
  end

  defp security_class_for_system(solar_system_id) do
    # This would need to be implemented using a lookup from EVE data
    # For now, return nil
    nil
  end
end
