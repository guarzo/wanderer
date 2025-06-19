defmodule WandererAppWeb.Controllers.Behaviours.Paginated do
  @moduledoc """
  Behaviour for controllers that need pagination functionality.

  This module provides:
  - Consistent OpenAPI parameter definitions
  - Standardized pagination pipeline  
  - Response formatting helpers
  - Error handling patterns

  ## Usage

      defmodule MyAPIController do
        use WandererAppWeb, :controller
        use WandererAppWeb.Controllers.Behaviours.Paginated
        
        def index(conn, params) do
          paginated_response(conn, params) do
            query = MyResource
            {query, &transform_item/1}
          end
        end
        
        defp transform_item(item), do: %{id: item.id, name: item.name}
      end
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias WandererAppWeb.Helpers.PaginationHelpers
  alias WandererAppWeb.Validations.ApiValidations
  alias WandererAppWeb.Schemas.ApiSchemas

  @callback transform_item(any()) :: map()
  @optional_callbacks [transform_item: 1]

  defmacro __using__(_opts) do
    quote do
      @behaviour WandererAppWeb.Controllers.Behaviours.Paginated

      import WandererAppWeb.Controllers.Behaviours.Paginated

      # Can be overridden by implementing controllers
      def transform_item(item), do: item

      defoverridable transform_item: 1
    end
  end

  @doc """
  Returns default pagination parameters for OpenAPI specs.
  """
  def pagination_parameters do
    [
      page: [
        in: :query,
        type: :integer,
        description: "Page number (default: 1)",
        example: 1,
        required: false
      ],
      page_size: [
        in: :query,
        type: :integer,
        description: "Items per page (default: 20, max: 100)",
        example: 20,
        required: false
      ]
    ]
  end

  @doc """
  Returns pagination response schema.
  """
  def pagination_response_schema(item_schema) do
    ApiSchemas.paginated_response(item_schema)
  end

  @doc """
  Executes a paginated response pipeline.

  The block should return either:
  - `{query, transform_fn}` - Query will be paginated, items transformed
  - `{query}` - Query will be paginated, items returned as-is
  - `query` - Query will be paginated, items returned as-is

  ## Examples

      paginated_response(conn, params) do
        query = MyResource |> MyResource.for_user(user_id)
        {query, &MyController.transform_item/1}
      end
      
      paginated_response(conn, params) do
        Character |> Character.active()
      end
  """
  defmacro paginated_response(conn, params, do: block) do
    quote do
      case ApiValidations.validate_pagination(unquote(params)) do
        {:ok, pagination_params} ->
          merged_params = Map.merge(unquote(params), pagination_params)

          result = unquote(block)

          {query, transform_fn} =
            case result do
              {query, transform_fn} when is_function(transform_fn, 1) ->
                {query, transform_fn}

              {query} ->
                {query, &__MODULE__.transform_item/1}

              query ->
                {query, &__MODULE__.transform_item/1}
            end

          case PaginationHelpers.paginate_query(query, merged_params, WandererApp.Api) do
            {:ok, {data, pagination_meta}} ->
              # Transform data using the provided function
              transformed_data = Enum.map(data, transform_fn)

              # Format paginated response
              response =
                PaginationHelpers.format_paginated_response(transformed_data, pagination_meta)

              # Add pagination headers and send response
              unquote(conn)
              |> PaginationHelpers.add_pagination_headers(
                pagination_meta,
                unquote(conn).request_path
              )
              |> put_status(200)
              |> json(response)

            {:error, changeset} ->
              unquote(conn)
              |> put_status(422)
              |> json(ApiValidations.format_errors(changeset))
          end

        {:error, changeset} ->
          unquote(conn)
          |> put_status(400)
          |> json(ApiValidations.format_errors(changeset))
      end
    end
  end

  @doc """
  Executes a paginated response for lists (not Ash queries).

  The block should return a list that will be paginated in memory.
  Use sparingly - prefer database-level pagination when possible.
  """
  defmacro paginated_list_response(conn, params, do: block) do
    quote do
      case ApiValidations.validate_pagination(unquote(params)) do
        {:ok, pagination_params} ->
          merged_params = Map.merge(unquote(params), pagination_params)

          data_list = unquote(block)

          case PaginationHelpers.paginate_list(data_list, merged_params) do
            {:ok, {data, pagination_meta}} ->
              # Transform data using the transform_item function
              transformed_data = Enum.map(data, &__MODULE__.transform_item/1)

              # Format paginated response
              response =
                PaginationHelpers.format_paginated_response(transformed_data, pagination_meta)

              # Add pagination headers and send response
              unquote(conn)
              |> PaginationHelpers.add_pagination_headers(
                pagination_meta,
                unquote(conn).request_path
              )
              |> put_status(200)
              |> json(response)

            {:error, reason} ->
              unquote(conn)
              |> put_status(400)
              |> json(%{error: reason})
          end

        {:error, changeset} ->
          unquote(conn)
          |> put_status(400)
          |> json(ApiValidations.format_errors(changeset))
      end
    end
  end

  @doc """
  Helper to create OpenAPI operation with pagination parameters.

  ## Example

      @operation_with_pagination %{
        summary: "List characters",
        responses: %{
          200 => paginated_operation_response("Successful response", CharacterSchema)
        }
      }
      def index(conn, params), do: # ...
  """
  def paginated_operation_response(description, item_schema) do
    %{
      description: description,
      content: %{
        "application/json" => %{
          schema: ApiSchemas.paginated_response(item_schema)
        }
      },
      headers: %{
        "X-Page" => %{
          description: "Current page number",
          schema: %{type: :integer}
        },
        "X-Total-Pages" => %{
          description: "Total number of pages",
          schema: %{type: :integer}
        },
        "X-Total-Count" => %{
          description: "Total number of items",
          schema: %{type: :integer}
        },
        "Link" => %{
          description: "Pagination links (first, prev, next, last)",
          schema: %{type: :string}
        }
      }
    }
  end
end
