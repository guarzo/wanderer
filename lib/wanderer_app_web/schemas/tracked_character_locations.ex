defmodule WandererAppWeb.Schemas.TrackedCharacterLocation do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TrackedCharacterLocation",
    type: :object,
    additionalProperties: false,
    required: [
      :character_id,
      :character_name,
      :tracked,
      :online,
      :solar_system_id,
      :solar_system_name,
      :display_name,
      :map_system_visible,
      :location_observed_at,
      :map_system_updated_at
    ],
    properties: %{
      character_id: %Schema{
        type: :integer,
        minimum: 1,
        description: "Numeric EVE character ID, not Wanderer UUID"
      },
      character_name: %Schema{type: :string, maxLength: 255},
      tracked: %Schema{type: :boolean, enum: [true]},
      online: %Schema{type: :boolean, nullable: true},
      solar_system_id: %Schema{type: :integer, nullable: true},
      solar_system_name: %Schema{
        type: :string,
        nullable: true,
        maxLength: 255,
        description: "Authoritative raw static name, never a synthetic fallback"
      },
      display_name: %Schema{type: :string, nullable: true, maxLength: 255},
      map_system_visible: %Schema{type: :boolean},
      location_observed_at: %Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "UTC uncached upstream 200 confirmation; unavailable at age >=15 seconds"
      },
      map_system_updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  })
end

defmodule WandererAppWeb.Schemas.TrackedCharacterLocationsResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TrackedCharacterLocationsResponse",
    type: :object,
    additionalProperties: false,
    required: [:data, :observed_at, :revision],
    properties: %{
      data: %Schema{
        type: :array,
        maxItems: 2000,
        items: WandererAppWeb.Schemas.TrackedCharacterLocation
      },
      observed_at: %Schema{
        type: :string,
        format: :"date-time",
        description: "Snapshot assembly time, not location freshness"
      },
      revision: %Schema{
        type: :string,
        description: "Opaque content revision used in the weak ETag"
      }
    }
  })
end

defmodule WandererAppWeb.Schemas.TrackedCharacterLocationsError do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TrackedCharacterLocationsError",
    type: :object,
    additionalProperties: false,
    required: [:error, :code],
    properties: %{error: %Schema{type: :string}, code: %Schema{type: :string}}
  })
end
