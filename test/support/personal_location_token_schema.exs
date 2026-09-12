# Generate/check only the affected tables; leave unrelated Zoo snapshot drift alone.
defmodule WandererApp.PersonalLocationTokenSchema do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource WandererApp.Api.MapIntegrationToken
    resource WandererApp.Api.Map
  end
end

AshPostgres.MigrationGenerator.generate(WandererApp.PersonalLocationTokenSchema,
  name: "personal_location_api_tokens",
  check: "--check" in System.argv()
)
