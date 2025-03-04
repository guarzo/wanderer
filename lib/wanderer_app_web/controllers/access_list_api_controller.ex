defmodule WandererAppWeb.MapAccessListAPIController do
  @moduledoc """
  API endpoints for managing Access Lists.

  Endpoints:
    - GET /api/map/acls?map_id=... or ?slug=...   (list ACLs)
    - POST /api/map/acls                         (create ACL)
    - GET /api/acls/:id                          (show ACL)
    - PUT /api/acls/:id                          (update ACL)
  """

  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.Api.{AccessList, Character}
  alias WandererAppWeb.UtilAPIController, as: Util
  import Ash.Query
  require Logger

  # ------------------------------------------------------------------------
  # Inline Schemas for OpenApiSpex
  # ------------------------------------------------------------------------

  # Used in operation :index => the response "List of ACLs"
  @acl_index_response_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            id: %OpenApiSpex.Schema{type: :string},
            name: %OpenApiSpex.Schema{type: :string},
            description: %OpenApiSpex.Schema{type: :string},
            owner_eve_id: %OpenApiSpex.Schema{type: :string},
            inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
            updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time}
          },
          required: ["id", "name"]
        }
      }
    },
    required: ["data"]
  }

  # Used in operation :create => the request body "ACL parameters"
  @acl_create_request_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      acl: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          owner_eve_id: %OpenApiSpex.Schema{type: :string},
          name: %OpenApiSpex.Schema{type: :string},
          description: %OpenApiSpex.Schema{type: :string}
        },
        required: ["owner_eve_id"]
      }
    },
    required: ["acl"]
  }

  # Used in operation :create => the response "Created ACL"
  @acl_create_response_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          id: %OpenApiSpex.Schema{type: :string},
          name: %OpenApiSpex.Schema{type: :string},
          description: %OpenApiSpex.Schema{type: :string},
          owner_id: %OpenApiSpex.Schema{type: :string},
          api_key: %OpenApiSpex.Schema{type: :string},
          inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
          updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time}
        },
        required: ["id", "name"]
      }
    },
    required: ["data"]
  }

  # Used in operation :show => the response "ACL details"
  @acl_show_response_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          id: %OpenApiSpex.Schema{type: :string},
          name: %OpenApiSpex.Schema{type: :string},
          description: %OpenApiSpex.Schema{type: :string},
          owner_id: %OpenApiSpex.Schema{type: :string},
          api_key: %OpenApiSpex.Schema{type: :string},
          inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
          updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
          members: %OpenApiSpex.Schema{
            type: :array,
            items: %OpenApiSpex.Schema{
              type: :object,
              properties: %{
                id: %OpenApiSpex.Schema{type: :string},
                name: %OpenApiSpex.Schema{type: :string},
                role: %OpenApiSpex.Schema{type: :string},
                eve_character_id: %OpenApiSpex.Schema{type: :string},
                inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
                updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time}
              },
              required: ["id", "name", "role"]
            }
          }
        },
        required: ["id", "name"]
      }
    },
    required: ["data"]
  }

  # Used in operation :update => the request body "ACL update payload"
  @acl_update_request_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      acl: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          name: %OpenApiSpex.Schema{type: :string},
          description: %OpenApiSpex.Schema{type: :string}
        }
        # If "name" is truly required, add it to required: ["name"] here
      }
    },
    required: ["acl"]
  }

  # Used in operation :update => the response "Updated ACL"
  @acl_update_response_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          id: %OpenApiSpex.Schema{type: :string},
          name: %OpenApiSpex.Schema{type: :string},
          description: %OpenApiSpex.Schema{type: :string},
          owner_id: %OpenApiSpex.Schema{type: :string},
          api_key: %OpenApiSpex.Schema{type: :string},
          inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
          updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
          members: %OpenApiSpex.Schema{
            type: :array,
            items: %OpenApiSpex.Schema{
              type: :object,
              properties: %{
                id: %OpenApiSpex.Schema{type: :string},
                name: %OpenApiSpex.Schema{type: :string},
                role: %OpenApiSpex.Schema{type: :string},
                eve_character_id: %OpenApiSpex.Schema{type: :string},
                inserted_at: %OpenApiSpex.Schema{type: :string, format: :date_time},
                updated_at: %OpenApiSpex.Schema{type: :string, format: :date_time}
              },
              required: ["id", "name", "role"]
            }
          }
        },
        required: ["id", "name"]
      }
    },
    required: ["data"]
  }

  # ------------------------------------------------------------------------
  # ENDPOINTS
  # ------------------------------------------------------------------------

  @doc """
  GET /api/map/acls?map_id=... or ?slug=...

  Lists the ACLs for a given map.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :index,
    summary: "List ACLs for a Map",
    description: "Lists the ACLs for a given map using query parameters 'map_id' or 'slug'.",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID)",
        type: :string,
        required: false
      ],
      slug: [
        in: :query,
        description: "Map slug",
        type: :string,
        required: false
      ]
    ],
    responses: [
      ok: {
        "List of ACLs",
        "application/json",
        @acl_index_response_schema
      }
    ]
  def index(conn, params) do
    case Util.fetch_map_id(params) do
      {:ok, map_identifier} ->
        with {:ok, map} <- get_map(map_identifier),
             {:ok, loaded_map} <- Ash.load(map, acls: [:owner]) do
          acls = loaded_map.acls || []
          json(conn, %{data: Enum.map(acls, &acl_to_list_json/1)})
        else
          {:error, :map_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Map not found"})

          {:error, error} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: inspect(error)})
        end

      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})
    end
  end

  @doc """
  POST /api/map/acls

  Creates a new ACL for a map.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :create,
    summary: "Create ACL",
    description: "Creates a new ACL for a map. Expects an 'acl' object in the request body.",
    request_body: {
      "ACL parameters",
      "application/json",
      @acl_create_request_schema
    },
    responses: [
      ok: {
        "Created ACL",
        "application/json",
        @acl_create_response_schema
      }
    ]
  def create(conn, params) do
    with {:ok, map_identifier} <- Util.fetch_map_id(params),
         {:ok, map} <- get_map(map_identifier),
         %{"acl" => acl_params} <- params,
         owner_eve_id when not is_nil(owner_eve_id) <- Map.get(acl_params, "owner_eve_id"),
         owner_eve_id_str = to_string(owner_eve_id),
         {:ok, character} <- find_character_by_eve_id(owner_eve_id_str),
         {:ok, new_api_key} <- {:ok, UUID.uuid4()},
         new_params <-
           acl_params
           |> Map.delete("owner_eve_id")
           |> Map.put("owner_id", character.id)
           |> Map.put("api_key", new_api_key),
         {:ok, new_acl} <- AccessList.new(new_params),
         {:ok, _updated_map} <- associate_acl_with_map(map, new_acl) do
      json(conn, %{data: acl_to_json(new_acl)})
    else
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing required field: owner_eve_id"})

      {:error, "owner_eve_id does not match any existing character"} = error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: inspect(error)})

      error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: inspect(error)})
    end
  end

  @doc """
  GET /api/acls/:id

  Shows a specific ACL (with its members).
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :show,
    summary: "Show ACL",
    description: "Retrieves a specific ACL by its ID and loads its members.",
    parameters: [
      id: [
        in: :path,
        description: "ACL ID",
        type: :string,
        required: true
      ]
    ],
    responses: [
      ok: {
        "ACL details",
        "application/json",
        @acl_show_response_schema
      }
    ]
  def show(conn, %{"id" => id}) do
    query =
      AccessList
      |> Ash.Query.new()
      |> filter(id == ^id)

    case WandererApp.Api.read(query) do
      {:ok, [acl]} ->
        case Ash.load(acl, :members) do
          {:ok, loaded_acl} ->
            json(conn, %{data: acl_to_json(loaded_acl)})

          {:error, error} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to load ACL members: #{inspect(error)}"})
        end

      {:ok, []} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "ACL not found"})

      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Error reading ACL: #{inspect(error)}"})
    end
  end

  @doc """
  PUT /api/acls/:id

  Updates an ACL.
  """
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :update,
    summary: "Update ACL",
    description: "Updates an ACL identified by its ID.",
    parameters: [
      id: [
        in: :path,
        description: "ACL ID",
        type: :string,
        required: true
      ]
    ],
    request_body: {
      "ACL update payload",
      "application/json",
      @acl_update_request_schema
    },
    responses: [
      ok: {
        "Updated ACL",
        "application/json",
        @acl_update_response_schema
      }
    ]
  def update(conn, %{"id" => id, "acl" => acl_params}) do
    with {:ok, acl} <- AccessList.by_id(id),
         {:ok, updated_acl} <- AccessList.update(acl, acl_params),
         {:ok, updated_acl} <- Ash.load(updated_acl, :members) do
      json(conn, %{data: acl_to_json(updated_acl)})
    else
      {:error, error} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to update ACL: #{inspect(error)}"})
    end
  end

  # ---------------------------------------------------------------------------
  # Private / Helper Functions
  # ---------------------------------------------------------------------------
  defp get_map(map_identifier) do
    WandererApp.Api.Map.by_id(map_identifier)
  end

  defp acl_to_json(acl) do
    members =
      case acl.members do
        %Ash.NotLoaded{} -> []
        list when is_list(list) -> Enum.map(list, &member_to_json/1)
        _ -> []
      end

    %{
      id: acl.id,
      name: acl.name,
      description: acl.description,
      owner_id: acl.owner_id,
      api_key: acl.api_key,
      inserted_at: acl.inserted_at,
      updated_at: acl.updated_at,
      members: members
    }
  end

  defp acl_to_list_json(acl) do
    owner_eve_id =
      case acl.owner do
        %Character{eve_id: eid} -> eid
        _ -> nil
      end

    %{
      id: acl.id,
      name: acl.name,
      description: acl.description,
      owner_eve_id: owner_eve_id,
      inserted_at: acl.inserted_at,
      updated_at: acl.updated_at
    }
  end

  defp member_to_json(member) do
    %{
      id: member.id,
      name: member.name,
      role: member.role,
      eve_character_id: member.eve_character_id,
      inserted_at: member.inserted_at,
      updated_at: member.updated_at
    }
  end

  defp find_character_by_eve_id(eve_id) do
    query =
      Character
      |> Ash.Query.new()
      |> filter(eve_id == ^eve_id)

    case WandererApp.Api.read(query) do
      {:ok, [character]} ->
        {:ok, character}

      {:ok, []} ->
        {:error, "owner_eve_id does not match any existing character"}

      other ->
        other
    end
  end

  defp associate_acl_with_map(map, new_acl) do
    with {:ok, api_map} <- WandererApp.Api.Map.by_id(map.id),
         {:ok, loaded_map} <- Ash.load(api_map, :acls) do
      new_acl_id = if is_binary(new_acl), do: new_acl, else: new_acl.id
      current_acls = loaded_map.acls || []
      updated_acls = current_acls ++ [new_acl_id]

      case WandererApp.Api.Map.update_acls(loaded_map, %{acls: updated_acls}) do
        {:ok, updated_map} ->
          {:ok, updated_map}

        {:error, error} ->
          Logger.error("Failed to update map #{loaded_map.id} with new ACL: #{inspect(error)}")
          {:error, error}
      end
    else
      error ->
        Logger.error("Error loading map ACLs: #{inspect(error)}")
        {:error, error}
    end
  end
end
