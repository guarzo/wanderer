defmodule WandererAppWeb.AshJsonApiRouter do
  @moduledoc """
  Router configuration for AshJsonApi resources.

  This module defines the JSON:API routes for Ash resources that support
  standard CRUD operations through AshJsonApi.
  """

  use AshJsonApi.Router,
    domains: [WandererApp.Api],
    json_schema: "/json_schema",
    open_api: "/openapi"

  # Configure JSON:API routes
  # These will be mounted under /api/v1/ash in the main router
end
