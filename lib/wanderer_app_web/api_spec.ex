defmodule WandererAppWeb.ApiSpec do
  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{OpenApi, Info, Paths, Components, SecurityScheme, Server}
  alias WandererAppWeb.{Endpoint, Router}

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Wanderer API",
        version: "1.0.0",
        description: """
        ## API Documentation for Wanderer

        Wanderer provides a comprehensive set of public APIs that allow you to programmatically interact with the platform.

        ### Key API Features

        - **Map Management:** Retrieve map data, systems, and connections
        - **Character Management:** Track character locations and activities
        - **Access Control:** Manage permissions through Access Control Lists (ACLs)
        - **Templates:** Create and apply map templates
        - **Monitoring:** Track kills, structure timers, and other game events

        ### Authentication

        Wanderer uses Bearer token authentication. Pass tokens in the `Authorization` header:

        ```
        Authorization: Bearer <YOUR_TOKEN>
        ```

        Two types of tokens are used:
        1. **Map API Token:** For map-specific endpoints (found in map settings)
        2. **ACL API Token:** For ACL management endpoints (found in ACL settings)

        If a token is missing or invalid, you'll receive a `401 Unauthorized` error.
        """
      },
      servers: [
        # Development server
        %Server{
          url: "http://localhost:4000",
          description: "Development server"
        },
        # Production server (example)
        %Server{
          url: "https://wanderer.example.com",
          description: "Production server"
        },
        # Server from endpoint (based on configuration)
        Server.from_endpoint(Endpoint)
      ],
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT",
            description: "Enter your API token with the 'Bearer ' prefix"
          }
        }
      },
      security: [%{"bearerAuth" => []}],
      externalDocs: %{
        description: "Additional Documentation",
        url: "/news/api-guide"
      },
      tags: [
        %{name: "Maps", description: "Operations related to map management"},
        %{name: "Systems", description: "Operations related to systems within maps"},
        %{name: "Connections", description: "Operations related to connections between systems"},
        %{name: "Characters", description: "Operations related to character management"},
        %{name: "Access Lists", description: "Operations related to access control lists"},
        %{name: "Templates", description: "Operations related to map templates"},
        %{name: "Audit", description: "Operations related to audit logs"},
        %{name: "Common", description: "Common utility operations"},
        %{name: "License", description: "Operations related to license management"},
        %{name: "Blog", description: "Operations related to blog content"}
      ]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
