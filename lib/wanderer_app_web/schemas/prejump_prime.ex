defmodule WandererAppWeb.Schemas.PrejumpPrimeRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PrejumpPrimeRequest",
    type: :object,
    additionalProperties: false,
    required: [:prime],
    properties: %{
      prime: %Schema{
        type: :object,
        additionalProperties: false,
        required: [:event_id, :eve_character_id, :source_solar_system_id, :system_name, :flags],
        properties: %{
          event_id: %Schema{type: :string, format: :uuid, description: "Idempotency key"},
          eve_character_id: %Schema{
            type: :integer,
            minimum: 1,
            description: "Numeric EVE character ID"
          },
          source_solar_system_id: %Schema{
            type: :integer,
            minimum: 1,
            description: "Expected source system at Set Root time"
          },
          system_name: %Schema{
            type: :string,
            maxLength: 255,
            description: "Root J-code for temporary_name"
          },
          flags: %Schema{
            type: :object,
            additionalProperties: false,
            properties: %{
              eol: %Schema{type: :boolean},
              half_mass: %Schema{type: :boolean},
              critical: %Schema{type: :boolean},
              frigate: %Schema{type: :boolean}
            }
          }
        }
      }
    }
  })
end

defmodule WandererAppWeb.Schemas.PrejumpPrimeStaged do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PrejumpPrimeStaged",
    type: :object,
    additionalProperties: false,
    required: [:staged, :event_id],
    properties: %{
      staged: %Schema{type: :boolean, enum: [true], description: "Staged, not consumed"},
      event_id: %Schema{type: :string, format: :uuid}
    }
  })
end

defmodule WandererAppWeb.Schemas.PrejumpPrimeError do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PrejumpPrimeError",
    type: :object,
    additionalProperties: false,
    required: [:error],
    properties: %{
      error: %Schema{type: :string},
      code: %Schema{
        type: :string,
        enum: [
          "invalid_request",
          "invalid_token",
          "scope_forbidden",
          "wrong_map",
          "forbidden",
          "disabled",
          "subscription_required",
          "not_acceptable",
          "rate_limited",
          "service_unavailable"
        ]
      }
    }
  })
end
