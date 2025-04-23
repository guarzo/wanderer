defmodule WandererAppWeb.MapTemplateAPIController do
  use WandererAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererAppWeb.UtilAPIController, as: Util
  alias WandererAppWeb.Schemas.MapApiSchemas
  alias WandererApp.MapTemplateRepo

  require Logger

  @spec list_templates(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :list_templates,
    summary: "List Templates",
    description: "Lists available templates, filtered by category, author, or public status.",
    parameters: [
      map_id: [
        in: :query,
        description: "Map ID to filter templates",
        type: :string,
        required: false,
        example: "466e922b-e758-485e-9b86-afae06b88363"
      ],
      slug: [
        in: :query,
        description: "Map slug to filter templates",
        type: :string,
        required: false,
        example: "my-map"
      ],
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
      ok: {"List of templates", "application/json", MapApiSchemas.template_list_response_schema()}
    ]

  def list_templates(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params) do
      # Always fetch templates scoped to the map first
      all_map_templates = fetch_template(:all_for_map, map_id)

      # Apply additional filters if provided
      templates =
        case params do
          %{"category" => category} ->
            Enum.filter(all_map_templates, &(&1.category == category))

          %{"author_eve_id" => author_id_str} ->
            # No longer parsing to integer here
            Enum.filter(all_map_templates, &(&1.author_eve_id == author_id_str))

          %{"public" => "true"} ->
            # Filter map-specific templates that are also public
            Enum.filter(all_map_templates, &(&1.is_public == true))
            # Note: If the intent was truly *all* public templates regardless of map,
            # the original fetch_template(:public) would be needed, but the slug suggests map scoping.

          _ ->
            # Default case: return all templates for the map
            all_map_templates
        end

      json(conn, %{data: Enum.map(templates, &template_to_json/1)})
    else
      {:error, msg} -> error_response(conn, :bad_request, msg)
    end
  end

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
      ok: {"Template", "application/json", MapApiSchemas.template_response_schema()},
      not_found: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]

  def get_template(conn, %{"id" => id}) do
    case MapTemplateRepo.get(id) do
      {:ok, template} -> json(conn, %{data: template_to_json(template, true)})
      _ -> error_response(conn, :not_found, "Template not found")
    end
  end

  @spec create_template(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :create_template,
    summary: "Create Template",
    description: "Creates a new template.",
    request_body: {"Template", "application/json", MapApiSchemas.template_create_request_schema()},
    responses: [
      created: {"Template", "application/json", MapApiSchemas.template_response_schema()},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]

  def create_template(conn, params) do
    Logger.info("[MapTemplateAPIController.create_template] Received params: #{inspect(params)}")
    with {:ok, map_id} <- Util.fetch_map_id(params) do
      params
      |> normalize_template_params()
      |> convert_author_params()
      |> Map.put(:source_map_id, map_id)
      |> MapTemplateRepo.create()
      |> case do
        {:ok, template} -> created_response(conn, template_to_json(template))
        {:error, reason} -> error_response(conn, :bad_request, "Error creating template: #{Util.format_error(reason)}")
      end
    else
      {:error, msg} -> error_response(conn, :bad_request, msg)
    end
  end

  @spec create_template_from_map(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :create_template_from_map,
    summary: "Create Template from Map",
    description: "Creates a template from an existing map.",
    request_body: {"Template from Map", "application/json", MapApiSchemas.template_from_map_request_schema()},
    responses: [
      created: {"Template", "application/json", MapApiSchemas.template_response_schema()},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]

  def create_template_from_map(conn, params) do
    params
    |> normalize_template_params()
    |> convert_author_params()
    |> then(fn final ->
      with {:ok, map_id} <- Util.fetch_map_id(final),
           {:ok, template} <- MapTemplateRepo.create_from_map(map_id, final) do
        created_response(conn, template_to_json(template))
      else
        {:error, :no_systems_selected} ->
          error_response(conn, :not_found, "No systems found in map to create template")
        {:error, msg} when is_binary(msg) ->
          error_response(conn, :bad_request, msg)
        {:error, reason} ->
          error_response(conn, :bad_request, "Error creating template from map: #{Util.format_error(reason)}")
      end
    end)
  end

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
    request_body: {"Template Metadata", "application/json", MapApiSchemas.template_update_metadata_request_schema()},
    responses: [
      ok: {"Template", "application/json", MapApiSchemas.template_response_schema()},
      not_found: {"Error", "application/json", OpenApiSpex.Schema.Error},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]

  def update_template_metadata(conn, %{"id" => id} = params) do
    update_params = Map.drop(normalize_template_params(params), ["id", "slug"])

    with {:ok, _} <- Util.validate_uuid(id),
         {:ok, template} <- MapTemplateRepo.get(id),
         {:ok, updated} <- MapTemplateRepo.update_metadata(template, update_params) do
      json(conn, %{data: template_to_json(updated)})
    else
      {:error, :not_found} -> error_response(conn, :not_found, "Template not found")
      {:error, reason} -> error_response(conn, :bad_request, "Error updating template metadata: #{Util.format_error(reason)}")
    end
  end

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
    request_body: {"Template Content", "application/json", MapApiSchemas.template_update_content_request_schema()},
    responses: [
      ok: {"Template", "application/json", MapApiSchemas.template_response_schema()},
      not_found: {"Error", "application/json", OpenApiSpex.Schema.Error},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]

  def update_template_content(conn, %{"id" => id} = params) do
    update_params = Map.drop(params, ["id", "slug"])

    with {:ok, _} <- Util.validate_uuid(id),
         {:ok, template} <- MapTemplateRepo.get(id),
         {:ok, updated} <- MapTemplateRepo.update_content(template, update_params) do
      json(conn, %{data: template_to_json(updated, true)})
    else
      {:error, :not_found} -> error_response(conn, :not_found, "Template not found")
      {:error, reason} -> error_response(conn, :bad_request, "Error updating template content: #{Util.format_error(reason)}")
    end
  end

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
      no_content: {"Success", "application/json", %OpenApiSpex.Schema{type: :object, properties: %{}}},
      not_found: {"Error", "application/json", OpenApiSpex.Schema.Error},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]

  def delete_template(conn, %{"id" => id}) do
    with {:ok, _} <- Util.validate_uuid(id),
         {:ok, template} <- MapTemplateRepo.get(id),
         :ok <- Util.handle_destroy_result(MapTemplateRepo.destroy(template)) do
      send_resp(conn, :no_content, "")
    else
      {:error, :invalid_uuid} -> error_response(conn, :bad_request, "Invalid template ID format")
      {:error, :not_found} -> error_response(conn, :not_found, "Template not found")
      {:error, reason} -> error_response(conn, :bad_request, "Error deleting template: #{Util.format_error(reason)}")
    end
  end

  @spec apply_template(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :apply_template,
    summary: "Apply Template",
    description: "Applies a template to a map. Requires either 'map_id' or 'slug' as a query parameter to identify the target map.",
    parameters: [
      map_id: [
        in: :query,
        description: "Map identifier (UUID) - Either map_id or slug must be provided",
        type: :string,
        required: false,
        example: "466e922b-e758-485e-9b86-afae06b88363"
      ],
      slug: [
        in: :query,
        description: "Map slug - Either map_id or slug must be provided",
        type: :string,
        required: false,
        example: "my-map"
      ]
    ],
    request_body: {"Apply Template", "application/json", MapApiSchemas.template_apply_request_schema()},
    responses: [
      ok: {"Result", "application/json", MapApiSchemas.template_apply_response_schema()},
      bad_request: {"Error", "application/json", OpenApiSpex.Schema.Error},
      not_found: {"Error", "application/json", OpenApiSpex.Schema.Error}
    ]

  def apply_template(conn, params) do
    with {:ok, map_id} <- Util.fetch_map_id(params),
         template_id = Map.get(params, "template_id"),
         {:ok, _} <- Util.validate_uuid(template_id),
         {:ok, template} <- MapTemplateRepo.get(template_id) do

      # Debug logging
      Logger.info("Applying template - Template ID: #{template_id}, Map ID: #{map_id}")
      Logger.info("Template connections: #{inspect(template.connections)}")
      Logger.info("Fetched template details for application: #{inspect(template)}")

      # Ensure systems exist in the template
      if Enum.empty?(template.systems || []) do
        error_response(conn, :bad_request, "Cannot apply template with no systems")
      else
        # Extract additional options
        opts = %{
          "cleanup_existing" => Map.get(params, "cleanup_existing", false),
          "position_x" => Map.get(params, "position_x"),
          "position_y" => Map.get(params, "position_y")
        }

        case MapTemplateRepo.apply_template(map_id, template_id, opts) do
          {:ok, result} ->
            # Log the result summary
            Logger.info("Template application result: #{inspect(result.summary)}")

            # Ensure connections_added is included in the response
            # Even if connections failed to be retrieved, the application should continue
            # and return success as long as systems were added
            summary = result.summary
                      |> Map.put_new(:connections_added, 0)
                      |> Map.put_new(:systems_added, 0)
                      |> Map.put_new(:connections_failed, Map.get(result, :failed_connections, 0))

            json(conn, %{data: summary})

          {:error, reason} ->
            Logger.error("Error applying template: #{inspect(reason)}")
            error_response(conn, :bad_request, "Error applying template: #{Util.format_error(reason)}")
        end
      end
    else
      {:error, :invalid_uuid} -> error_response(conn, :bad_request, "Invalid template ID format")
      {:error, msg} -> error_response(conn, :bad_request, msg)
      {:error, :not_found} -> error_response(conn, :not_found, "Template or map not found")
      {:error, reason} ->
        Logger.error("Error in apply_template: #{inspect(reason)}")
        error_response(conn, :bad_request, "Error applying template: #{Util.format_error(reason)}")
    end
  end

  # --------- Private Helpers ---------

  defp fetch_template(:category, val), do: MapTemplateRepo.list_by_category(val) |> unwrap_or_empty()
  defp fetch_template(:author, val), do: MapTemplateRepo.list_by_author(val) |> unwrap_or_empty()
  defp fetch_template(:public), do: MapTemplateRepo.list_public() |> unwrap_or_empty()
  defp fetch_template(:all_for_map, map_id), do: MapTemplateRepo.list_all_for_map(map_id) |> unwrap_or_empty()
  defp unwrap_or_empty({:ok, result}), do: result
  defp unwrap_or_empty(_), do: []

  defp error_response(conn, status, msg), do: conn |> put_status(status) |> json(%{error: msg})
  defp created_response(conn, data), do: conn |> put_status(:created) |> json(%{data: data})

  defp convert_author_params(params) do
    case Map.fetch(params, "author_eve_id") do
      {:ok, val} -> Map.put(params, "author_eve_id", to_string(val))
      :error -> params
    end
  end

  defp template_to_json(template, include_content \\ false) do
    base = %{
      id: template.id,
      name: template.name,
      description: template.description,
      category: template.category,
      author_eve_id: template.author_eve_id,
      source_map_id: template.source_map_id,
      is_public: template.is_public,
      inserted_at: template.inserted_at,
      updated_at: template.updated_at
    }

    if include_content do
      systems =
        Enum.map(template.systems || [], fn s ->
          s
          |> Map.put(:solar_system_id, s[:system_id] || s[:solar_system_id])
          |> Map.delete(:system_id)
        end)

      # Log connections before returning
      Logger.debug("Template connections (json conversion): #{inspect(template.connections)}")

      Map.merge(base, %{
        systems: systems,
        connections: template.connections || [],
        metadata: template.metadata || %{}
      })
    else
      base
    end
  end

  defp normalize_template_params(params) do
    selection = Map.get(params, "selection", %{})

    params
    |> maybe_add_from_selection(selection, "solar_system_ids")
    |> maybe_add_from_selection(selection, "system_ids")
    |> maybe_rename_key("public", "is_public")
    |> maybe_rename_key("template_name", "name")
    |> maybe_rename_key("template_description", "description")
    |> maybe_rename_key("template_category", "category")
  end

  defp maybe_add_from_selection(params, selection, key) do
    if Map.has_key?(selection, key), do: Map.put(params, key, selection[key]), else: params
  end

  defp maybe_rename_key(params, old_key, new_key) do
    if Map.has_key?(params, old_key),
      do: Map.put(params, new_key, params[old_key]) |> Map.delete(old_key),
      else: params
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
