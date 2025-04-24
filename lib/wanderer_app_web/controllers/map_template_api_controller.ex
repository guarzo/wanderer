defmodule WandererAppWeb.MapTemplateAPIController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererAppWeb.UtilAPIController, as: Util
  alias WandererApp.MapTemplateRepo
  alias WandererAppWeb.Schemas.{ApiSchemas, ResponseSchemas}
  alias OpenApiSpex.Schema

  require Logger
  action_fallback WandererAppWeb.FallbackController

  # -----------------------------------------------------------------
  # Schema Definitions
  # -----------------------------------------------------------------

  @template_base_schema %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string, description: "Template unique identifier"},
      name: %Schema{type: :string, description: "Template name"},
      description: %Schema{type: :string, description: "Template description"},
      category: %Schema{type: :string, description: "Template category"},
      author_eve_id: %Schema{type: :string, description: "Creator EVE Character ID"},
      is_public: %Schema{type: :boolean, description: "Public availability"},
      inserted_at: %Schema{type: :string, format: :date_time},
      updated_at: %Schema{type: :string, format: :date_time}
    },
    required: ["id", "name", "category", "author_eve_id", "is_public"]
  }

  @template_detailed_schema %Schema{
    allOf: [
      @template_base_schema,
      %Schema{
        type: :object,
        properties: %{
          systems: %Schema{type: :array, items: %Schema{type: :object}},
          connections: %Schema{type: :array, items: %Schema{type: :object}}
        }
      }
    ]
  }

  @create_template_request_schema %Schema{
    type: :object,
    properties: %{
      name: %Schema{type: :string},
      description: %Schema{type: :string},
      category: %Schema{type: :string},
      author_eve_id: %Schema{type: :string},
      is_public: %Schema{type: :boolean},
      systems: %Schema{type: :array, items: %Schema{type: :object}},
      connections: %Schema{type: :array, items: %Schema{type: :object}}
    },
    required: ["name", "category", "author_eve_id"]
  }

  @create_from_map_request_schema %Schema{
    type: :object,
    properties: %{
      name: %Schema{type: :string},
      description: %Schema{type: :string},
      category: %Schema{type: :string},
      author_eve_id: %Schema{type: :string},
      is_public: %Schema{type: :boolean},
      system_ids: %Schema{type: :array, items: %Schema{type: :string}}
    },
    required: ["name", "category", "author_eve_id"]
  }

  @update_metadata_request_schema %Schema{
    type: :object,
    properties: %{
      name: %Schema{type: :string},
      description: %Schema{type: :string},
      category: %Schema{type: :string},
      is_public: %Schema{type: :boolean}
    }
  }

  @update_content_request_schema %Schema{
    type: :object,
    properties: %{
      systems: %Schema{type: :array, items: %Schema{type: :object}},
      connections: %Schema{type: :array, items: %Schema{type: :object}}
    },
    required: ["systems", "connections"]
  }

  @apply_request_schema %Schema{
    type: :object,
    properties: %{
      template_id: %Schema{type: :string, format: :uuid},
      position_x: %Schema{type: :integer},
      position_y: %Schema{type: :integer},
      scale: %Schema{type: :number},
      should_cleanup_existing: %Schema{type: :boolean}
    },
    required: ["template_id"]
  }

  @list_response_schema ApiSchemas.data_wrapper(%Schema{type: :array, items: @template_base_schema})
  @detail_response_schema ApiSchemas.data_wrapper(@template_detailed_schema)
  @apply_response_schema ApiSchemas.data_wrapper(%Schema{type: :object, properties: %{
    systems_added: %Schema{type: :integer},
    connections_added: %Schema{type: :integer},
    connections_failed: %Schema{type: :integer}
  }})

  # -----------------------------------------------------------------
  # RESTful Actions for /templates
  # -----------------------------------------------------------------

  @doc """
  GET /api/maps/:map_identifier/templates
  Lists templates for a specific map.
  """
  operation :index,
    summary: "List Templates",
    parameters: [
      map_identifier: [in: :path, type: :string, required: true]
    ],
    responses: [ ok: ResponseSchemas.ok(@list_response_schema) ]
  def index(conn, _params) do
    map_id = conn.assigns.map_id
    templates = MapTemplateRepo.list_all_for_map(map_id) |> unwrap_or_empty()
    json(conn, %{data: Enum.map(templates, &template_to_json/1)})
  end

  @doc """
  GET /api/maps/:map_identifier/templates/:id
  Retrieves full details of a single template.
  """
  operation :show,
    summary: "Get Template",
    parameters: [map_identifier: [in: :path, type: :string], id: [in: :path, type: :string, required: true]],
    responses: [ ok: ResponseSchemas.ok(@detail_response_schema), not_found: ResponseSchemas.not_found("Template not found") ]
  def show(conn, %{"id" => id}) do
    case MapTemplateRepo.get(id) do
      {:ok, tpl} -> json(conn, %{data: template_to_json(tpl, true)})
      _ -> error_response(conn, :not_found, "Template not found")
    end
  end

  @doc """
  POST /api/maps/:map_identifier/templates
  Creates a new template.
  """
  operation :create,
    summary: "Create Template",
    parameters: [map_identifier: [in: :path, type: :string, required: true]],
    request_body: {"Template", "application/json", @create_template_request_schema},
    responses: [ created: ResponseSchemas.created(@detail_response_schema), bad_request: ResponseSchemas.bad_request("Error creating template") ]
  def create(conn, params) do
    map_id = conn.assigns.map_id

    params
    |> normalize_params()
    |> Map.put(:source_map_id, map_id)
    |> MapTemplateRepo.create()
    |> case do
      {:ok, tpl} -> conn |> put_status(:created) |> json(%{data: template_to_json(tpl)})
      {:error, reason} -> error_response(conn, :bad_request, Util.format_error(reason))
    end
  end

  @doc """
  DELETE /api/maps/:map_identifier/templates/:id
  Deletes a template.
  """
  operation :delete,
    summary: "Delete Template",
    parameters: [map_identifier: [in: :path, type: :string], id: [in: :path, type: :string, required: true]],
    responses: [ no_content: {"", "application/json", %Schema{type: :object}}, not_found: ResponseSchemas.not_found("Template not found") ]
  def delete(conn, %{"id" => id}) do
    with {:ok, tpl} <- MapTemplateRepo.get(id),
         :ok         <- Util.handle_destroy_result(MapTemplateRepo.destroy(tpl)) do
      send_resp(conn, :no_content, "")
    else
      _ -> error_response(conn, :not_found, "Template not found")
    end
  end

  # -----------------------------------------------------------------
  # Member and Collection Custom Actions
  # -----------------------------------------------------------------

  @doc """
  POST /api/maps/:map_identifier/templates/from-map
  Creates a template from an existing map.
  """
  operation :create_template_from_map,
    summary: "Create from Map",
    parameters: [map_identifier: [in: :path, type: :string]],
    request_body: {"From Map", "application/json", @create_from_map_request_schema},
    responses: [ created: ResponseSchemas.created(@detail_response_schema) ]
  def create_template_from_map(conn, params) do
    map_id = conn.assigns.map_id

    params
    |> normalize_params()
    |> then(fn p -> MapTemplateRepo.create_from_map(map_id, p) end)
    |> case do
      {:ok, tpl} -> conn |> put_status(:created) |> json(%{data: template_to_json(tpl)})
      {:error, :no_systems_selected} -> error_response(conn, :not_found, "No systems selected")
      {:error, reason} -> error_response(conn, :bad_request, Util.format_error(reason))
    end
  end

  @doc """
  PATCH /api/maps/:map_identifier/templates/:id/metadata
  Updates template metadata.
  """
  operation :update_template_metadata,
    summary: "Update Metadata",
    parameters: [map_identifier: [in: :path], id: [in: :path, required: true]],
    request_body: {"Metadata", "application/json", @update_metadata_request_schema},
    responses: [ ok: ResponseSchemas.ok(@detail_response_schema) ]
  def update_template_metadata(conn, %{"id" => id} = params) do
    update = normalize_params(params) |> Map.drop(["id"])

    with {:ok, tpl} <- MapTemplateRepo.get(id),
         {:ok, updated} <- MapTemplateRepo.update_metadata(tpl, update) do
      json(conn, %{data: template_to_json(updated)})
    else
      _ -> error_response(conn, :not_found, "Template not found")
    end
  end

  @doc """
  PATCH /api/maps/:map_identifier/templates/:id/content
  Updates template content.
  """
  operation :update_template_content,
    summary: "Update Content",
    parameters: [map_identifier: [in: :path], id: [in: :path, required: true]],
    request_body: {"Content", "application/json", @update_content_request_schema},
    responses: [ ok: ResponseSchemas.ok(@detail_response_schema) ]
  def update_template_content(conn, %{"id" => id} = params) do
    with {:ok, tpl} <- MapTemplateRepo.get(id),
         {:ok, updated} <- MapTemplateRepo.update_content(tpl, normalize_params(params)) do
      json(conn, %{data: template_to_json(updated, true)})
    else
      _ -> error_response(conn, :not_found, "Template not found")
    end
  end

  @doc """
  POST /api/maps/:map_identifier/templates/apply
  Applies a template to a map.
  """
  operation :apply_template,
    summary: "Apply Template",
    parameters: [map_identifier: [in: :path, type: :string]],
    request_body: {"Apply", "application/json", @apply_request_schema},
    responses: [ ok: ResponseSchemas.ok(@apply_response_schema) ]
  def apply_template(conn, params) do
    map_id = conn.assigns.map_id
    tpl_id = params["template_id"]

    with {:ok, tpl}      <- MapTemplateRepo.get(tpl_id),
         systems when is_list(tpl.systems) and tpl.systems != [] <- tpl.systems,
         {:ok, result}    <- MapTemplateRepo.apply_template(map_id, tpl_id, normalize_params(params)) do
      json(conn, %{data: %{
        systems_added: Map.get(result, :systems_added, 0),
        connections_added: Map.get(result, :connections_added, 0),
        connections_failed: Map.get(result, :failed_connections, 0)
      }})
    else
      []  -> error_response(conn, :bad_request, "Template has no systems")
      _   -> error_response(conn, :not_found, "Template not found or invalid ID")
    end
  end

  # -----------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------

  defp unwrap_or_empty({:ok, r}), do: r
  defp unwrap_or_empty(_), do: []

  defp normalize_params(params) do
    params
    |> Util.atomize_keys()
    |> Map.drop([:map_identifier, :id])
  end

  defp template_to_json(tpl, include \\ false) do
    base = %{
      id: tpl.id,
      name: tpl.name,
      description: tpl.description,
      category: tpl.category,
      author_eve_id: tpl.author_eve_id,
      source_map_id: tpl.source_map_id,
      is_public: tpl.is_public,
      inserted_at: tpl.inserted_at,
      updated_at: tpl.updated_at
    }

    if include do
      Map.merge(base, %{systems: tpl.systems || [], connections: tpl.connections || []})
    else
      base
    end
  end

  defp error_response(conn, status, reason) do
    Util.standardized_error_response(conn, status, reason)
  end

  defp created_response(conn, data) do
    conn |> put_status(:created) |> json(%{data: data})
  end
end
