defmodule WandererAppWeb.ExampleController do
  @moduledoc """
  Example controller demonstrating the OpenAPI standardization pattern.

  This is a reference implementation that should not be used in production.
  It shows the proper structure and organization for controllers following
  the OpenAPI standards defined in our guidelines.
  """

  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias WandererAppWeb.Schemas.{ApiSchemas, ResponseSchemas}
  alias WandererAppWeb.UtilAPIController, as: Util

  # Schema Definitions
  @example_entity_schema %OpenApiSpex.Schema{
    title: "Example Entity",
    description: "A sample entity that demonstrates schema organization",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Unique identifier"},
      name: %OpenApiSpex.Schema{type: :string, description: "Name of the entity"},
      description: %OpenApiSpex.Schema{type: :string, description: "Optional description", nullable: true},
      created_at: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Creation timestamp"},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time, description: "Last update timestamp"}
    },
    required: ["id", "name", "created_at", "updated_at"],
    example: %{
      "id" => "123e4567-e89b-12d3-a456-426614174000",
      "name" => "Example Entity",
      "description" => "This is a sample entity",
      "created_at" => "2023-01-01T00:00:00Z",
      "updated_at" => "2023-01-02T00:00:00Z"
    }
  }

  @example_create_request_schema %OpenApiSpex.Schema{
    title: "Create Example Request",
    description: "Request body for creating a new example entity",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{type: :string, description: "Name of the entity"},
      description: %OpenApiSpex.Schema{type: :string, description: "Optional description", nullable: true}
    },
    required: ["name"],
    example: %{
      "name" => "New Example Entity",
      "description" => "This is a new entity"
    }
  }

  @example_update_request_schema %OpenApiSpex.Schema{
    title: "Update Example Request",
    description: "Request body for updating an existing example entity",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{type: :string, description: "Updated name", nullable: true},
      description: %OpenApiSpex.Schema{type: :string, description: "Updated description", nullable: true}
    },
    example: %{
      "name" => "Updated Entity Name",
      "description" => "This description has been updated"
    }
  }

  @example_index_response_schema ApiSchemas.data_wrapper(
    %OpenApiSpex.Schema{
      type: :array,
      items: @example_entity_schema
    }
  )

  @example_show_response_schema ApiSchemas.data_wrapper(@example_entity_schema)
  @example_create_response_schema ApiSchemas.data_wrapper(@example_entity_schema)
  @example_update_response_schema ApiSchemas.data_wrapper(@example_entity_schema)

  # Operations
  operation :index,
    summary: "List Examples",
    description: "Retrieves a list of all example entities",
    parameters: [
      page: [
        in: :query,
        description: "Page number for pagination",
        type: :integer,
        example: 1,
        required: false
      ],
      per_page: [
        in: :query,
        description: "Number of items per page",
        type: :integer,
        example: 10,
        required: false
      ]
    ],
    responses: ResponseSchemas.standard_responses(
      @example_index_response_schema,
      "List of examples retrieved successfully"
    )

  @doc """
  Lists all example entities with optional pagination.

  GET /api/examples
  """
  def index(conn, params) do
    # Example implementation - would be replaced with actual data retrieval
    page = String.to_integer(params["page"] || "1")
    per_page = String.to_integer(params["per_page"] || "10")

    examples = [
      %{
        id: "123e4567-e89b-12d3-a456-426614174000",
        name: "Example 1",
        description: "First example entity",
        created_at: "2023-01-01T00:00:00Z",
        updated_at: "2023-01-01T00:00:00Z"
      },
      %{
        id: "223e4567-e89b-12d3-a456-426614174000",
        name: "Example 2",
        description: "Second example entity",
        created_at: "2023-01-02T00:00:00Z",
        updated_at: "2023-01-02T00:00:00Z"
      }
    ]

    json(conn, %{data: examples})
  end

  operation :show,
    summary: "Get Example",
    description: "Retrieves a specific example entity by ID",
    parameters: [
      id: [
        in: :path,
        description: "Example entity ID (UUID)",
        type: :string,
        example: "123e4567-e89b-12d3-a456-426614174000",
        required: true
      ]
    ],
    responses: ResponseSchemas.standard_responses(
      @example_show_response_schema,
      "Example retrieved successfully"
    )

  @doc """
  Retrieves a specific example entity by ID.

  GET /api/examples/:id
  """
  def show(conn, %{"id" => id}) do
    # Example implementation - would be replaced with actual data retrieval
    example = %{
      id: id,
      name: "Example Entity",
      description: "This is an example entity",
      created_at: "2023-01-01T00:00:00Z",
      updated_at: "2023-01-01T00:00:00Z"
    }

    json(conn, %{data: example})
  rescue
    # Example error handling
    _ ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Example with ID #{id} not found"})
  end

  operation :create,
    summary: "Create Example",
    description: "Creates a new example entity",
    request_body: {"Example creation parameters", "application/json", @example_create_request_schema},
    responses: ResponseSchemas.create_responses(
      @example_create_response_schema,
      "Example created successfully"
    )

  @doc """
  Creates a new example entity.

  POST /api/examples
  """
  def create(conn, params) do
    with {:ok, name} <- Util.require_param(params, "name") do
      # Example implementation - would be replaced with actual data creation
      example = %{
        id: "123e4567-e89b-12d3-a456-426614174000",
        name: name,
        description: params["description"],
        created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      conn
      |> put_status(:created)
      |> json(%{data: example})
    else
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: Util.format_error(msg)})
    end
  end

  operation :update,
    summary: "Update Example",
    description: "Updates an existing example entity",
    parameters: [
      id: [
        in: :path,
        description: "Example entity ID (UUID)",
        type: :string,
        example: "123e4567-e89b-12d3-a456-426614174000",
        required: true
      ]
    ],
    request_body: {"Example update parameters", "application/json", @example_update_request_schema},
    responses: ResponseSchemas.update_responses(
      @example_update_response_schema,
      "Example updated successfully"
    )

  @doc """
  Updates an existing example entity.

  PUT /api/examples/:id
  """
  def update(conn, %{"id" => id} = params) do
    # Example implementation - would be replaced with actual data update
    example = %{
      id: id,
      name: params["name"] || "Default Name",
      description: params["description"],
      created_at: "2023-01-01T00:00:00Z",
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    json(conn, %{data: example})
  rescue
    # Example error handling
    _ ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Example with ID #{id} not found"})
  end

  operation :delete,
    summary: "Delete Example",
    description: "Deletes an example entity",
    parameters: [
      id: [
        in: :path,
        description: "Example entity ID (UUID)",
        type: :string,
        example: "123e4567-e89b-12d3-a456-426614174000",
        required: true
      ]
    ],
    responses: ResponseSchemas.delete_responses()

  @doc """
  Deletes an example entity.

  DELETE /api/examples/:id
  """
  def delete(conn, %{"id" => id}) do
    # Example implementation - would be replaced with actual deletion
    json(conn, %{data: %{deleted: true, id: id}})
  rescue
    # Example error handling
    _ ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Example with ID #{id} not found"})
  end
end
