defmodule WandererAppWeb.Schemas.ResponseSchemas do
  @moduledoc """
  Standard response schema definitions for API responses.

  This module provides helper functions to create standardized
  HTTP response schemas for OpenAPI documentation.
  """

  alias WandererAppWeb.Schemas.ApiSchemas

  # Standard response status codes for v1 API (with data wrapper)
  def ok(schema, description \\ "Successful operation", use_legacy_format \\ false) do
    response_schema =
      if use_legacy_format do
        schema
      else
        ApiSchemas.data_wrapper(schema)
      end

    {
      description,
      "application/json",
      response_schema
    }
  end

  def created(schema, description \\ "Resource created", use_legacy_format \\ false) do
    response_schema =
      if use_legacy_format do
        schema
      else
        ApiSchemas.data_wrapper(schema)
      end

    {
      description,
      "application/json",
      response_schema
    }
  end

  def bad_request(description \\ "Bad request", use_legacy_format \\ false) do
    response_schema =
      if use_legacy_format do
        ApiSchemas.legacy_error_response(description)
      else
        ApiSchemas.error_response(description)
      end

    {
      description,
      "application/json",
      response_schema
    }
  end

  def not_found(description \\ "Resource not found", use_legacy_format \\ false) do
    response_schema =
      if use_legacy_format do
        ApiSchemas.legacy_error_response(description)
      else
        ApiSchemas.error_response(description)
      end

    {
      description,
      "application/json",
      response_schema
    }
  end

  def internal_server_error(description \\ "Internal server error", use_legacy_format \\ false) do
    response_schema =
      if use_legacy_format do
        ApiSchemas.legacy_error_response(description)
      else
        ApiSchemas.error_response(description)
      end

    {
      description,
      "application/json",
      response_schema
    }
  end

  def unauthorized(description \\ "Unauthorized", use_legacy_format \\ false) do
    response_schema =
      if use_legacy_format do
        ApiSchemas.legacy_error_response(description)
      else
        ApiSchemas.error_response(description)
      end

    {
      description,
      "application/json",
      response_schema
    }
  end

  def forbidden(description \\ "Forbidden", use_legacy_format \\ false) do
    response_schema =
      if use_legacy_format do
        ApiSchemas.legacy_error_response(description)
      else
        ApiSchemas.error_response(description)
      end

    {
      description,
      "application/json",
      response_schema
    }
  end

  # Helper for common response patterns
  def standard_responses(success_schema, success_description \\ "Successful operation") do
    [
      ok: ok(success_schema, success_description),
      bad_request: bad_request(),
      not_found: not_found(),
      internal_server_error: internal_server_error()
    ]
  end

  # Helper for create operation responses
  def create_responses(created_schema, created_description \\ "Resource created") do
    [
      created: created(created_schema, created_description),
      bad_request: bad_request(),
      internal_server_error: internal_server_error()
    ]
  end

  # Helper for update operation responses
  def update_responses(updated_schema, updated_description \\ "Resource updated") do
    [
      ok: ok(updated_schema, updated_description),
      bad_request: bad_request(),
      not_found: not_found(),
      internal_server_error: internal_server_error()
    ]
  end

  # Helper for delete operation responses
  def delete_responses(deleted_schema \\ nil, deleted_description \\ "Resource deleted") do
    if deleted_schema do
      [
        ok: ok(deleted_schema, deleted_description),
        not_found: not_found(),
        internal_server_error: internal_server_error()
      ]
    else
      [
        no_content: {deleted_description <> " (no content)", nil, nil},
        not_found: not_found(),
        internal_server_error: internal_server_error()
      ]
    end
  end
end
