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

      # Return error if no systems are selected
      if Enum.empty?(selected_systems) do
        {:error, :no_systems_selected}
      else
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
  end

  @doc """
  Applies a template to a map.

  Takes a map ID, template ID, and applies the template to the map.
  """
  def apply_template(map_id, template_id, _options \\ %{}) do
    with {:ok, template} <- get(template_id),
         {:ok, _existing_systems} <- MapSystemRepo.get_all_by_map(map_id) do

      # Create new systems
      {:ok, created_systems} = create_systems_from_template(
        map_id,
        template.systems
      )

      # Create connections between the new systems
      {:ok, created_connections} = create_connections_from_template(
        map_id,
        template.connections,
        created_systems
      )

      {:ok, %{
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

      # Default: Include all systems
      true ->
        systems
    end
  end

  # Get only connections between selected systems
  defp filter_connections_for_selected_systems(connections, selected_systems) do
    # Create a set of solar system IDs for quick lookup
    system_solar_ids = MapSet.new(selected_systems, & &1.solar_system_id)

    # Keep only connections where both source and target are in selected systems
    Enum.filter(connections, fn connection ->
      MapSet.member?(system_solar_ids, connection.solar_system_source) and
      MapSet.member?(system_solar_ids, connection.solar_system_target)
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
        solar_system_id: system.solar_system_id
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

  # Prepare connections for template
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
          type: connection.type
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Create systems from a template
  defp create_systems_from_template(map_id, template_systems) do
    # Convert template systems to maps for bulk creation
    systems_to_create = template_systems
    |> Enum.map(fn system ->
      # Basic system properties
      %{
        map_id: map_id,
        solar_system_id: system["solar_system_id"],
        position_x: rand_position(),
        position_y: rand_position(),
        visible: true
      }
    end)

    # Create systems
    case MapSystemRepo.bulk_create(systems_to_create) do
      {:ok, created_systems} -> {:ok, created_systems}
      error -> error
    end
  end

  # Generate a random position for a system
  defp rand_position do
    :rand.uniform(1000) - 500
  end

  # Create connections from a template
  defp create_connections_from_template(map_id, template_connections, created_systems) do
    # Create a map of index to created system
    system_by_index = created_systems
                      |> Enum.with_index()
                      |> Enum.map(fn {system, index} -> {index, system} end)
                      |> Map.new()

    # Create a map of solar_system_id to created system for safer lookup
    system_by_solar_id = Map.new(created_systems, fn system -> {system.solar_system_id, system} end)

    # Convert template connections to maps for bulk creation
    connections_to_create = template_connections
    |> Enum.map(fn connection ->
      source_system = Map.get(system_by_index, connection["source_index"])
      target_system = Map.get(system_by_index, connection["target_index"])

      if not is_nil(source_system) and not is_nil(target_system) do
        # Basic connection properties
        %{
          map_id: map_id,
          solar_system_source: source_system.solar_system_id,
          solar_system_target: target_system.solar_system_id,
          type: connection["type"]
        }
      end
    end)
    |> Enum.reject(&is_nil/1)

    # Create connections
    case MapConnectionRepo.bulk_create(connections_to_create) do
      {:ok, created_connections} -> {:ok, created_connections}
      error -> error
    end
  end
end
