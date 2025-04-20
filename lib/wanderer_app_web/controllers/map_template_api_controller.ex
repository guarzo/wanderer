defmodule WandererAppWeb.MapTemplateAPIController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererApp.MapTemplateRepo
  alias WandererAppWeb.UtilAPIController, as: Util
  alias Ecto.UUID

  # Reference schemas from MapAPIController
  alias WandererAppWeb.MapAPIController, as: MapAPISchemas

  @doc """
  GET /api/templates

  Lists available templates. Can be filtered by category, author, or public status.

  Example usage:
    GET /api/templates?category=wormhole
    GET /api/templates?author_eve_id=2122019111
    GET /api/templates?public=true
  """
  @spec list_templates(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :list_templates,
    summary: "List Templates",
    description: "Lists available templates, filtered by category, author, or public status.",
    parameters: [
      category: [
        in: :query,
        description: "Filter by category (e.g., 'wormhole', 'k-space')",
        type: :string,
        required: false,
        example: "wormhole"
      ],
      author_eve_id: [
        in: :query,
        description: "Filter by creator's EVE Character ID",
        type: :string,
        required: false,
        example: "2122019111"
      ],
      public: [
        in: :query,
        description: "If true, only public templates are returned",
        type: :boolean,
        required: false,
        example: true
      ]
    ],
    responses: [
      ok: {"List of templates", "application/json", MapAPISchemas.template_list_response_schema()}
    ]
  def list_templates(conn, params) do
    templates = cond do
      Map.has_key?(params, "category") ->
        case WandererApp.MapTemplateRepo.list_by_category(params["category"]) do
          {:ok, templates} -> templates
          _ -> []
        end

      Map.has_key?(params, "author_eve_id") ->
        author_eve_id = parse_integer_param(params["author_eve_id"])
        case WandererApp.MapTemplateRepo.list_by_author(author_eve_id) do
          {:ok, templates} -> templates
          _ -> []
        end

      Map.has_key?(params, "public") && params["public"] == true ->
        case WandererApp.MapTemplateRepo.list_public() do
          {:ok, templates} -> templates
          _ -> []
        end

      true ->
        # Default: return empty list if no filters match expected keys
        # Or potentially list all accessible templates (e.g., public + user's own)
        # For now, keeping it restrictive based on explicit filters.
        []
    end

    json(conn, %{data: Enum.map(templates, &template_to_json/1)})
  end

  @doc """
  GET /api/templates/:id

  Gets a template by ID.

  Example usage:
  ```
  GET /api/templates/466e922b-e758-485e-9b86-afae06b88363
  ```
  """
  @spec get_template(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :get_template,
    summary: "Get Template",
    description: "Gets a template by ID.",
    parameters: [
      id: [
        in: :path,
        description: "Template ID",
        type: :string,
        required: true,
        example: ""
      ]
    ],
    responses: [
      ok: {"Template", "application/json", MapAPISchemas.template_response_schema()},
      not_found: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]
  def get_template(conn, %{"id" => id}) do
    case WandererApp.MapTemplateRepo.get(id) do
      {:ok, template} ->
        json(conn, %{data: template_to_json(template, true)}) # Include content for GET single

      _error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Template not found"})
    end
  end

  @doc """
  POST /api/templates

  Creates a new template.

  Example body:
  ```json
  {
    "name": "My Template",
    "description": "A custom template",
    "category": "custom",
    "author_eve_id": "2122019111",
    "is_public": false,
    "systems": [...],
    "connections": [...]
  }
  ```
  """
  @spec create_template(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :create_template,
    summary: "Create Template",
    description: "Creates a new template.",
    request_body: {"Template", "application/json", MapAPISchemas.template_create_request_schema()},
    responses: [
      created: {"Template", "application/json", MapAPISchemas.template_response_schema()},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]
  def create_template(conn, params) do
    # Normalize parameters to what Ash expects
    normalized_params = normalize_template_params(params)

    # Convert author params
    final_params = convert_author_params(normalized_params)

    case WandererApp.MapTemplateRepo.create(final_params) do
      {:ok, template} ->
        conn
        |> put_status(:created)
        |> json(%{data: template_to_json(template)}) # Don't include content on create response

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Error creating template: #{inspect(reason)}"})
    end
  end

  @doc """
  POST /api/templates/from-map

  Creates a template from an existing map.

  Example body:
  ```json
  {
    "map_id": "466e922b-e758-485e-9b86-afae06b88363",
    "name": "Map Template",
    "description": "Generated from my map",
    "category": "custom",
    "author_eve_id": "2122019111",
    "is_public": false,
    "system_ids": ["system1", "system2"] # Optional: only include specified systems
  }
  ```
  """
  @spec create_template_from_map(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :create_template_from_map,
    summary: "Create Template from Map",
    description: "Creates a template from an existing map.",
    request_body: {"Template from Map", "application/json", MapAPISchemas.template_from_map_request_schema()},
    responses: [
      created: {"Template", "application/json", MapAPISchemas.template_response_schema()},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]
  def create_template_from_map(conn, params) do
    # Normalize parameters to what Ash expects
    normalized_params = normalize_template_params(params)

    # Convert author params
    final_params = convert_author_params(normalized_params)

    with {:ok, map_id} <- Util.fetch_map_id(final_params), # Use final_params here
         {:ok, template} <- WandererApp.MapTemplateRepo.create_from_map(map_id, final_params) do
      conn
      |> put_status(:created)
      |> json(%{data: template_to_json(template)}) # Don't include content on create response
    else
      {:error, msg} when is_binary(msg) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Error creating template from map: #{inspect(reason)}"})
    end
  end

  @doc """
  PATCH /api/templates/:id/metadata

  Updates a template's metadata.

  Example body:
  ```json
  {
    "name": "Updated Template Name",
    "description": "Updated description",
    "is_public": true
  }
  ```
  """
  @spec update_template_metadata(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :update_template_metadata,
    summary: "Update Template Metadata",
    description: "Updates a template's metadata.",
    parameters: [
      id: [
        in: :path,
        description: "Template ID",
        type: :string,
        required: true,
        example: ""
      ]
    ],
    request_body: {"Template Metadata", "application/json", MapAPISchemas.template_update_metadata_request_schema()},
    responses: [
      ok: {"Template", "application/json", MapAPISchemas.template_response_schema()},
      not_found: {"Error", "application/json", OpenApiSpex.Schema.Error},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]
  def update_template_metadata(conn, %{"id" => id} = params) do
    # Normalize parameters to what Ash expects
    normalized_params = normalize_template_params(params)

    # Filter out URL parameters that shouldn't be in the update data
    update_params = Map.drop(normalized_params, ["id", "slug"]) # Also drop slug if present

    with {:ok, template} <- WandererApp.MapTemplateRepo.get(id),
         {:ok, updated_template} <- WandererApp.MapTemplateRepo.update_metadata(template, update_params) do
      json(conn, %{data: template_to_json(updated_template)}) # Don't include content
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Template not found"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Error updating template metadata: #{inspect(reason)}"})
    end
  end

  @doc """
  PATCH /api/templates/:id/content

  Updates a template's content (systems, connections, metadata).

  Example body:
  ```json
  {
    "systems": [...],
    "connections": [...],
    "metadata": {...}
  }
  ```
  """
  @spec update_template_content(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :update_template_content,
    summary: "Update Template Content",
    description: "Updates a template's content (systems, connections, metadata).",
    parameters: [
      id: [
        in: :path,
        description: "Template ID",
        type: :string,
        required: true,
        example: ""
      ]
    ],
    request_body: {"Template Content", "application/json", MapAPISchemas.template_update_content_request_schema()},
    responses: [
      ok: {"Template", "application/json", MapAPISchemas.template_response_schema()},
      not_found: {"Error", "application/json", OpenApiSpex.Schema.Error},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]
  def update_template_content(conn, %{"id" => id} = params) do
    # Filter out URL parameters that shouldn't be in the update data
    update_params = Map.drop(params, ["id", "slug"]) # Also drop slug if present

    with {:ok, template} <- WandererApp.MapTemplateRepo.get(id),
         {:ok, updated_template} <- WandererApp.MapTemplateRepo.update_content(template, update_params) do
      json(conn, %{data: template_to_json(updated_template, true)}) # Include content after update
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Template not found"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Error updating template content: #{inspect(reason)}"})
    end
  end

  @doc """
  DELETE /api/templates/:id

  Deletes a template.

  Example usage:
  ```
  DELETE /api/templates/466e922b-e758-485e-9b86-afae06b88363
  ```
  """
  @spec delete_template(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :delete_template,
    summary: "Delete Template",
    description: "Deletes a template.",
    parameters: [
      id: [
        in: :path,
        description: "Template ID",
        type: :string,
        required: true,
        example: ""
      ]
    ],
    responses: [
      no_content: {"Success", "application/json", %OpenApiSpex.Schema{
          type: :object,
          properties: %{}
        }
      },
      not_found: {"Error", "application/json", OpenApiSpex.Schema.Error},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]
  def delete_template(conn, %{"id" => id}) do
    with {:ok, _} <- validate_template_id(id),
         {:ok, template} <- WandererApp.MapTemplateRepo.get(id),
         destroy_result <- WandererApp.MapTemplateRepo.destroy(template),
         :ok <- handle_destroy_result(destroy_result) do
      conn
      |> put_status(:no_content)
      |> text("")
    else
      {:error, :invalid_template_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid template ID format"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Template not found"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Error deleting template: #{inspect(reason)}"})
    end
  end

  @doc """
  POST /api/templates/apply

  Applies a template to a map.

  Requires either `map_id` or `slug` in the body, plus `template_id`.

  Example body:
  ```json
  {
    "map_id": "466e922b-e758-485e-9b86-afae06b88363",
    "template_id": "template-uuid"
  }
  ```
  """
  @spec apply_template(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :apply_template,
    summary: "Apply Template",
    description: "Applies a template to a map. Requires either 'map_id' or 'slug' in the body to identify the target map.",
    request_body: {"Apply Template", "application/json", MapAPISchemas.template_apply_request_schema()},
    responses: [
      ok: {"Result", "application/json", MapAPISchemas.template_apply_response_schema()},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error},
      not_found: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]
  def apply_template(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         template_id = Map.get(params, "template_id"),
         {:ok, _} <- validate_template_id(template_id),
         options = Map.drop(params, ["map_id", "slug", "template_id"]), # Pass additional options if needed
         {:ok, result} <- WandererApp.MapTemplateRepo.apply_template(map_id, template_id, options) do
      json(conn, %{data: result.summary}) # Assuming result has a :summary field
    else
      {:error, :invalid_template_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid template ID format"})

      {:error, msg} when is_binary(msg) -> # Handle errors from fetch_map_id
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Template or map not found"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Error applying template: #{inspect(reason)}"})
    end
  end

  # ---------------- Private Helpers ----------------

  # Validate that the template_id is a valid UUID
  defp validate_template_id(nil), do: {:error, :invalid_template_id} # Handle nil case
  defp validate_template_id(template_id) when is_binary(template_id) do
    case Ecto.UUID.cast(template_id) do
      {:ok, _uuid} -> {:ok, template_id}
      :error -> {:error, :invalid_template_id}
    end
  end
  defp validate_template_id(_), do: {:error, :invalid_template_id} # Handle other types

  # Helper function to format a template for JSON response
  defp template_to_json(template, include_content \\ false) do
    base = %{
      id: template.id,
      name: template.name,
      description: template.description,
      category: template.category,
      author_eve_id: template.author_eve_id, # Keep author_eve_id
      source_map_id: template.source_map_id,
      is_public: template.is_public,
      inserted_at: template.inserted_at,
      updated_at: template.updated_at
    }

    if include_content do
      Map.merge(base, %{
        systems: template.systems || [], # Default to empty list
        connections: template.connections || [], # Default to empty list
        metadata: template.metadata || %{} # Default to empty map
      })
    else
      base
    end
  end

  # Helper to handle different return values from destroy
  defp handle_destroy_result(:ok), do: :ok
  defp handle_destroy_result({:ok, _}), do: :ok
  # Handle Ash bulk result structs specifically
  defp handle_destroy_result(%Ash.BulkResult{status: :success}), do: :ok
  defp handle_destroy_result(%Ash.BulkResult{status: :error, errors: errors}), do: {:error, errors}
  # Catch-all for other potential error tuples/values
  defp handle_destroy_result(error), do: {:error, error}

  # Helper function to normalize template parameters for Ash
  defp normalize_template_params(params) do
    # Extract selection data if it exists
    params = if Map.has_key?(params, "selection") do
      selection = params["selection"]

      # Extract solar_system_ids from selection
      params = if Map.has_key?(selection, "solar_system_ids") do
        Map.put(params, "solar_system_ids", selection["solar_system_ids"])
      else
        params
      end

      # Extract system_ids from selection if solar_system_ids wasn't present
      params = if !Map.has_key?(params, "solar_system_ids") && Map.has_key?(selection, "system_ids") do
        Map.put(params, "system_ids", selection["system_ids"])
      else
        params
      end

      params
    else
      params
    end

    params
    |> maybe_rename_key("public", "is_public")
    |> maybe_rename_key("template_name", "name")
    |> maybe_rename_key("template_description", "description")
    |> maybe_rename_key("template_category", "category")
  end

  # Helper to rename keys in params map if they exist
  defp maybe_rename_key(params, old_key, new_key) do
    if Map.has_key?(params, old_key) do
      value = params[old_key]
      params
      |> Map.put(new_key, value)
      |> Map.delete(old_key)
    else
      params
    end
  end

  # Helper function to handle author parameters, standardizing on author_eve_id
  defp convert_author_params(params) do
    cond do
      # If author_id is present (legacy), convert it to author_eve_id and remove author_id
      Map.has_key?(params, "author_id") ->
        author_id = params["author_id"]
        params
        |> Map.put("author_eve_id", to_string(author_id)) # Ensure it's string
        |> Map.delete("author_id")

      # If author_eve_id is set, ensure it's properly formatted as a string
      Map.has_key?(params, "author_eve_id") ->
        # Keep author_eve_id as is, ensuring it's a string
        author_eve_id = to_string(params["author_eve_id"])
        Map.put(params, "author_eve_id", author_eve_id)

      # Otherwise leave params unchanged
      true ->
        params
    end
  end

  defp parse_integer_param(param) when is_integer(param), do: param
  defp parse_integer_param(param) when is_binary(param) do
    case Integer.parse(param) do
      {num, ""} -> num
      _ -> nil
    end
  end
  defp parse_integer_param(_), do: nil
end
