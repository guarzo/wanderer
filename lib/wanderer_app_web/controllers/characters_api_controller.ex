defmodule WandererAppWeb.CharactersAPIController do
  @moduledoc """
  Exposes an endpoint for listing characters in the database with pagination
  """

  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use WandererAppWeb.JsonAction

  alias WandererApp.Api.Character
  alias WandererAppWeb.Schemas
  alias WandererAppWeb.Helpers.PaginationHelpers
  alias OpenApiSpex.Schema

  @character_list_item_schema %Schema{
    type: :object,
    properties: %{
      eve_id: %Schema{type: :string},
      name: %Schema{type: :string},
      corporation_id: %Schema{type: :string},
      corporation_ticker: %Schema{type: :string},
      alliance_id: %Schema{type: :string},
      alliance_ticker: %Schema{type: :string}
    },
    required: ["eve_id", "name"]
  }

  @characters_index_response_schema WandererAppWeb.Schemas.ApiSchemas.paginated_response(%Schema{
                                      type: :array,
                                      items: @character_list_item_schema
                                    })

  @doc """
  GET /api/characters
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:index,
    summary: "List Characters",
    description: "Lists characters in the database with pagination support.",
    parameters: [
      page: [
        in: :query,
        type: :integer,
        description: "Page number (default: 1)",
        example: 1
      ],
      page_size: [
        in: :query,
        type: :integer,
        description: "Items per page (default: 20, max: 100)",
        example: 20
      ]
    ],
    responses: [
      ok: {
        "Paginated list of characters",
        "application/json",
        @characters_index_response_schema
      },
      unprocessable_entity: {
        "Validation error",
        "application/json",
        WandererAppWeb.Schemas.ApiSchemas.error_response("Invalid pagination parameters")
      }
    ]
  )

  def index(conn, params) do
    # Build base query
    query = Character

    # Apply pagination
    case PaginationHelpers.paginate_query(query, params, WandererApp.Api) do
      {:ok, {characters, pagination_meta}} ->
        # Transform character data
        character_data =
          Enum.map(characters, &WandererAppWeb.MapEventHandler.map_ui_character_stat/1)

        # Format paginated response
        response = PaginationHelpers.format_paginated_response(character_data, pagination_meta)

        # Add pagination headers and send response
        conn
        |> PaginationHelpers.add_pagination_headers(pagination_meta, conn.request_path)
        |> put_status(:ok)
        |> json(response)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(WandererAppWeb.Validations.ApiValidations.format_errors(changeset))
    end
  end
end
