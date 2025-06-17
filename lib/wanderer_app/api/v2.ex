defmodule WandererApp.Api.V2 do
  @moduledoc """
  V2 API Domain - Future API version for breaking changes.

  This domain will contain evolved versions of existing resources with
  improved schemas, new features, and breaking changes that cannot be
  made in V1 for backward compatibility reasons.

  Currently empty but structured for future expansion.
  """

  use Ash.Domain,
    extensions: [AshJsonApi.Domain]

  resources do
    # V2 resources will be added here as they are developed
    # Initially, V2 will be empty and clients should use V1
  end
end
