# API Change Management

This document describes the process for managing API changes in the Wanderer application, including versioning, documentation, and breaking change detection.

## Overview

The Wanderer API uses a comprehensive change management system that includes:

1. **OpenAPI Documentation** - All API endpoints are documented using OpenAPI 3.0 specifications
2. **Automated Breaking Change Detection** - CI pipeline checks for breaking changes in PRs
3. **Changelog-Driven Development** - API changes are tracked in the changelog with specific commit types
4. **Version Management** - Semantic versioning with automated releases

## Commit Convention for API Changes

When making API changes, use the following commit types:

### Non-Breaking API Changes
```bash
# New endpoint or feature
git commit -m "api: add character activity endpoint"

# Improvement to existing endpoint
git commit -m "api: add pagination to systems endpoint"

# Documentation update
git commit -m "docs(api): update authentication examples"
```

### Breaking API Changes
```bash
# Use api! type for breaking changes
git commit -m "api!: remove deprecated map_id parameter"

# Include migration details in body
git commit -m "api!: change response format for errors

BREAKING CHANGE: Error responses now use 'errors' array instead of 'error' string.
Migrate by updating error handling to expect [{message: '...'}] format."
```

## OpenAPI Documentation

### Exporting the API Specification
```bash
# Export current OpenAPI spec
mix openapi.export

# Export to custom location
mix openapi.export --output docs/api/v1/spec.json
```

### Adding Documentation to Endpoints

1. Use the `operation` macro in controllers:
```elixir
operation :index,
  summary: "List all maps",
  description: "Returns a paginated list of maps accessible to the authenticated user",
  parameters: [
    limit: [in: :query, type: :integer, description: "Number of results per page"],
    offset: [in: :query, type: :integer, description: "Number of results to skip"]
  ],
  responses: [
    ok: {"Success", "application/json", paginated_response(ApiSchemas.map_basic_schema())}
  ]
```

2. Define schemas in `ApiSchemas` module for reusability
3. Use `ResponseSchemas` helpers for consistent response formats

## Breaking Change Detection

### Local Testing
```bash
# Compare two OpenAPI specs
elixir scripts/check_api_breaking_changes.exs old-spec.json new-spec.json
```

### CI Pipeline

The CI automatically checks for breaking changes on PRs that modify:
- Controllers (`lib/wanderer_app_web/controllers/**`)
- Schemas (`lib/wanderer_app_web/schemas/**`)
- API Specification (`lib/wanderer_app_web/api_spec.ex`)
- API Resources (`lib/wanderer_app/api/**`)

### What Constitutes a Breaking Change?

The following changes are considered breaking:
- Removing an endpoint
- Removing an HTTP method from an endpoint
- Adding a required parameter
- Removing a parameter
- Changing parameter types
- Removing response codes
- Changing response types
- Adding required properties to response schemas
- Removing properties from response schemas
- Removing enum values

## API Versioning Strategy

### Current Version
- **v1** - Current stable API at `/api/v1/*`
- **Legacy** - Deprecated API at `/api/*` (sunset in 6 months)

### Version Lifecycle
1. **Active** - Fully supported, new features added
2. **Deprecated** - Supported but no new features, sunset date announced
3. **Sunset** - No longer available

### Deprecation Process
1. Add deprecation headers (RFC 8594) to legacy endpoints
2. Set sunset date 6 months in future
3. Provide migration guide in changelog
4. Link to successor version in headers

## Changelog Integration

API changes are automatically included in the project changelog under specific sections:
- **API Changes** - Non-breaking improvements and additions
- **Breaking API Changes** - Changes requiring client updates

The changelog is generated automatically by `git_ops` during the release process.

## Best Practices

1. **Document First** - Update OpenAPI specs before implementing changes
2. **Test Schemas** - Use `assert_conforms!` in tests to validate responses
3. **Gradual Migration** - Provide transition period for breaking changes
4. **Clear Communication** - Use descriptive commit messages and changelog entries
5. **Version Appropriately** - Use semantic versioning for API releases

## Tools and Commands

### Development
```bash
# Run tests with OpenAPI validation
mix test

# Generate OpenAPI documentation
mix openapi.export

# Check for breaking changes locally
elixir scripts/check_api_breaking_changes.exs base.json current.json
```

### CI/CD
- Breaking change detection runs automatically on API-related PRs
- OpenAPI spec is exported and stored as artifact on each build
- Changelog is updated with API changes during release

## Migration Examples

### Example 1: Changing Error Response Format
```diff
# Old format (legacy API)
- {"error": "Not found"}

# New format (v1 API)  
+ {"errors": [{"message": "Not found"}]}
```

### Example 2: Parameter Migration
```diff
# Old: Query parameter
- GET /api/map/systems?map_id=123

# New: Path parameter with slug support
+ GET /api/v1/maps/my-map/systems
```

## Resources

- [OpenAPI Specification](https://spec.openapis.org/oas/v3.0.3)
- [RFC 8594 - The Sunset HTTP Header Field](https://www.rfc-editor.org/rfc/rfc8594.html)
- [Semantic Versioning](https://semver.org/)
- [Git Conventional Commits](https://www.conventionalcommits.org/)