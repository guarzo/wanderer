# OpenAPI Specification Guidelines

This document outlines the standards and patterns to follow when defining OpenAPI specifications in the Wanderer application. Adhering to these guidelines ensures consistency across all API endpoints.

## Schema Definition Location

- Define schemas as module attributes at the top of controller modules
- Group schema definitions under a clear comment header like `# Schema Definitions`
- Use the shared schema modules (`ApiSchemas` and `ResponseSchemas`) where possible to avoid duplication

Example:
```elixir
defmodule WandererAppWeb.SampleController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs
  
  alias WandererAppWeb.Schemas.{ApiSchemas, ResponseSchemas}
  
  # Schema Definitions
  @sample_response_schema ApiSchemas.data_wrapper(
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        id: %OpenApiSpex.Schema{type: :string},
        name: %OpenApiSpex.Schema{type: :string}
      },
      required: ["id", "name"]
    }
  )
  
  # Rest of the controller...
end
```

## Naming Conventions

- Module attributes: `@[entity]_[operation]_[request/response]_schema`
- Example: `@user_index_response_schema`, `@map_create_request_schema`
- Be descriptive and consistent with naming
- Use snake_case for schema names

## Schema Organization

- Group schemas by entity type
- Keep request/response pairs together
- Document schemas with comments
- Follow this order:
  1. Basic entity schemas
  2. Request schemas
  3. Response schemas
  4. Other specialized schemas

## Required Fields

- Mark fields as required if:
  - They are necessary for the operation to succeed
  - They are always included in the response
- Include the fields in the `required` list with their exact string names
- Be consistent about which fields are required across similar entities

## Error Responses

- Always document at least the following error responses for operations:
  - 400 Bad Request (validation errors)
  - 404 Not Found (for resource lookups)
  - 500 Internal Server Error (for unexpected errors)
- Use the `ResponseSchemas` module helpers to standardize error responses
- Add additional error responses based on endpoint-specific requirements

Example:
```elixir
operation :show,
  summary: "Get Resource",
  description: "Retrieves a specific resource by ID",
  parameters: [
    id: [in: :path, type: :string, required: true]
  ],
  responses: [
    ok: ResponseSchemas.ok(@resource_response_schema),
    bad_request: ResponseSchemas.bad_request("Invalid ID format"),
    not_found: ResponseSchemas.not_found("Resource not found"),
    internal_server_error: ResponseSchemas.internal_server_error()
  ]
```

Or using the helper method:

```elixir
operation :show,
  summary: "Get Resource",
  description: "Retrieves a specific resource by ID",
  parameters: [
    id: [in: :path, type: :string, required: true]
  ],
  responses: ResponseSchemas.standard_responses(@resource_response_schema)
```

## Parameter Documentation

- Include for each parameter:
  - Description of purpose
  - Data type
  - Example value when helpful
  - Whether it's required
- Use consistent formats for similar parameters across controllers
- Document query parameters, path parameters, and request body fields

Example:
```elixir
parameters: [
  id: [
    in: :path,
    description: "Resource identifier (UUID)",
    type: :string,
    example: "123e4567-e89b-12d3-a456-426614174000",
    required: true
  ],
  filter: [
    in: :query,
    description: "Filter results by a specific field",
    type: :string,
    required: false
  ]
]
```

## Validation Approach

- Use `Util.require_param/2` for string parameters
- Use `Util.parse_int/1` for integer conversions
- Use pattern matching with clear error messages
- Follow consistent validation patterns:

```elixir
def show(conn, params) do
  with {:ok, id} <- Util.require_param(params, "id"),
       {:ok, resource} <- Resource.get(id) do
    # Success path
    json(conn, %{data: resource})
  else
    {:error, :missing_param, param} ->
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing required parameter: #{param}"})
    
    {:error, :not_found} ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Resource not found"})
      
    {:error, reason} ->
      Logger.error("Error fetching resource: #{inspect(reason)}")
      conn
      |> put_status(:internal_server_error)
      |> json(%{error: "An unexpected error occurred"})
  end
end
```

## Documentation Comments

- Include descriptive `@doc` comments for each controller function
- Specify the HTTP method and endpoint path in the comment
- Add examples of request/response if helpful for complex endpoints

Example:
```elixir
@doc """
GET /api/resources/:id

Retrieves a specific resource by its ID.
"""
```

By following these guidelines consistently across all controllers, we'll create a more maintainable and developer-friendly API layer. 