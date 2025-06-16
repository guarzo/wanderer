defmodule WandererAppWeb.CharactersAPIController do
  @moduledoc """
  Exposes an endpoint for listing ALL characters in the database
  """

  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use WandererAppWeb.JsonAction

  alias WandererApp.Api.Character
  alias WandererAppWeb.Schemas
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

  @characters_index_response_schema Schemas.index_response_schema(
    @character_list_item_schema,
    "List of all characters in the database"
  )

  @doc """
  GET /api/characters
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:index,
    summary: "List Characters",
    description: "Lists ALL characters in the database.",
    responses: [
      ok: {
        "List of characters",
        "application/json",
        @characters_index_response_schema
      }
    ]
  )

  def index(conn, _params) do
    json_action_with(conn,
      do: WandererApp.Api.read(Character),
      with: fn characters ->
        Enum.map(characters, &WandererAppWeb.MapEventHandler.map_ui_character_stat/1)
      end
    )
  end
end
