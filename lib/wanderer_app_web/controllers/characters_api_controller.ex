defmodule WandererAppWeb.CharactersAPIController do
  @moduledoc """
  Exposes an endpoint for listing ALL characters in the database.
  """
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.Api.Character

  @characters_index_response_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            id: %OpenApiSpex.Schema{type: :string},
            eve_id: %OpenApiSpex.Schema{type: :string},
            name: %OpenApiSpex.Schema{type: :string},
            corporation_name: %OpenApiSpex.Schema{type: :string},
            alliance_name: %OpenApiSpex.Schema{type: :string}
          },
          required: ["id", "eve_id", "name"]
        }
      }
    },
    required: ["data"]
  }

  @doc """
  GET /api/characters
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :index,
    summary: "List Characters",
    description: "Lists ALL characters in the database.",
    responses: [
      ok: {"List of characters", "application/json", @characters_index_response_schema}
    ]
  def index(conn, _params) do
    with {:ok, characters} <- WandererApp.Api.read(Character) do
      result =
        Enum.map(characters, fn ch ->
          %{
            id: ch.id,
            eve_id: ch.eve_id,
            name: ch.name,
            corporation_name: ch.corporation_name,
            alliance_name: ch.alliance_name
          }
        end)

      json(conn, %{data: result})
    else
      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: inspect(error)})
    end
  end
end
