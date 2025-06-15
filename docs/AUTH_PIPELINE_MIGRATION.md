# Authentication Pipeline Migration Guide

This guide explains how to migrate from the existing authentication plugs to the new unified AuthPipeline system.

## Overview

The new AuthPipeline consolidates multiple authentication plugs into a single, configurable pipeline with pluggable strategies. This provides:

- **Unified Interface**: Single plug with multiple strategies
- **Flexibility**: Easy to add new authentication methods
- **Composability**: Combine multiple strategies in order
- **Consistency**: All strategies follow the same behavior contract
- **Feature Flags**: Built-in support for disabling features

## Migration Examples

### 1. Migrating CheckMapApiKey

**Before:**
```elixir
pipeline :api_map do
  plug WandererAppWeb.Plugs.ResolveMapIdentifier
  plug WandererAppWeb.Plugs.CheckMapApiKey
  plug WandererAppWeb.Plugs.CheckMapSubscription
  plug WandererAppWeb.Plugs.AssignMapOwner
end
```

**After:**
```elixir
pipeline :api_map do
  plug WandererAppWeb.Plugs.ResolveMapIdentifier
  plug WandererAppWeb.Auth.AuthPipeline,
    strategies: [:map_api_key],
    required: true,
    error_message: "Invalid or missing API key"
  plug WandererAppWeb.Plugs.CheckMapSubscription
  plug WandererAppWeb.Plugs.AssignMapOwner
end
```

### 2. Migrating CheckAclAuth (Multiple Strategies)

**Before:**
```elixir
pipeline :api_acl do
  plug WandererAppWeb.Plugs.CheckAclAuth
end
```

**After:**
```elixir
pipeline :api_acl do
  plug WandererAppWeb.Auth.AuthPipeline,
    strategies: [:acl_key, :character_jwt],
    required: true,
    error_message: "Authentication required"
end
```

### 3. Migrating Feature Flag Checks

**Before:**
```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug WandererAppWeb.Plugs.CheckApiDisabled
end

pipeline :api_character do
  plug WandererAppWeb.Plugs.CheckCharacterApiDisabled
end
```

**After:**
```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug WandererAppWeb.Auth.AuthPipeline,
    strategies: [],
    feature_flag: :public_api_disabled,
    required: false
end

pipeline :api_character do
  plug WandererAppWeb.Auth.AuthPipeline,
    strategies: [],
    feature_flag: :character_api_disabled,
    required: false
end
```

### 4. Complex Authentication Flow

**Before:**
```elixir
# Manual implementation in controller
def index(conn, params) do
  with {:ok, user} <- authenticate_jwt(conn),
       {:ok, character} <- validate_character(user, params["character_id"]),
       :ok <- check_permissions(character, conn.assigns.map) do
    # Handle request
  else
    {:error, reason} -> handle_auth_error(conn, reason)
  end
end
```

**After:**
```elixir
# In router
pipeline :api_character_map do
  plug WandererAppWeb.Plugs.ResolveMapIdentifier
  plug WandererAppWeb.Auth.AuthPipeline,
    strategies: [:character_jwt, :map_api_key],
    required: true,
    assign_as: :auth_context,
    character_jwt: [character_id: :from_params]
end

# In controller - authentication already handled
def index(conn, _params) do
  auth_context = conn.assigns.auth_context
  # Handle request with guaranteed authentication
end
```

## Configuration Options

### AuthPipeline Options

- **`:strategies`** - List of strategies to try in order (e.g., `[:jwt, :map_api_key]`)
- **`:required`** - Whether authentication is required (default: `true`)
- **`:assign_as`** - Key to assign auth data in conn.assigns (e.g., `:current_user`)
- **`:feature_flag`** - Feature flag to check before authentication
- **`:error_status`** - HTTP status for auth failures (default: `401`)
- **`:error_message`** - Error message for auth failures

### Strategy-Specific Options

Pass options to specific strategies:

```elixir
plug WandererAppWeb.Auth.AuthPipeline,
  strategies: [:character_jwt],
  character_jwt: [character_id: :from_params]
```

## Adding Custom Strategies

To add a new authentication strategy:

1. Implement the `AuthStrategy` behaviour:

```elixir
defmodule WandererAppWeb.Auth.Strategies.CustomStrategy do
  @behaviour WandererAppWeb.Auth.AuthStrategy
  
  @impl true
  def name, do: :custom
  
  @impl true
  def validate_opts(_opts), do: :ok
  
  @impl true
  def authenticate(conn, opts) do
    # Return one of:
    # - {:ok, conn, auth_data} - Success
    # - {:error, reason} - Failure
    # - :skip - Not applicable
  end
end
```

2. Register in `AuthPipeline.strategy_module/1`:

```elixir
defp strategy_module(strategy) do
  case strategy do
    # ... existing strategies
    :custom -> WandererAppWeb.Auth.Strategies.CustomStrategy
    _ -> nil
  end
end
```

## Testing with New Pipeline

The new pipeline maintains the same conn.assigns structure, so existing tests should continue to work. For new tests:

```elixir
# Test helper
def auth_conn(conn, strategy \\ :jwt, auth_data \\ %{}) do
  conn
  |> put_req_header("authorization", "Bearer test-token")
  |> assign(:test_auth_data, auth_data)
end

# In test
test "requires authentication", %{conn: conn} do
  conn = get(conn, "/api/v1/protected")
  assert json_response(conn, 401)["error"] == "Authentication required"
end
```

## Benefits of Migration

1. **Reduced Boilerplate**: Single plug replaces multiple auth checks
2. **Flexible Authentication**: Easy to support multiple auth methods
3. **Consistent Error Handling**: Unified error responses
4. **Better Testability**: Strategies can be tested in isolation
5. **Future-Proof**: Easy to add new authentication methods

## Rollback Plan

The existing plugs remain functional during migration. You can:

1. Migrate pipelines incrementally
2. Run both old and new auth in parallel during transition
3. Keep old plugs until all routes are migrated
4. Remove old plugs only after full validation

## Common Patterns

### Optional Authentication
```elixir
plug WandererAppWeb.Auth.AuthPipeline,
  strategies: [:jwt],
  required: false,
  assign_as: :optional_user
```

### API Key with Fallback
```elixir
plug WandererAppWeb.Auth.AuthPipeline,
  strategies: [:map_api_key, :jwt],
  required: true
```

### Feature Flag Protection
```elixir
plug WandererAppWeb.Auth.AuthPipeline,
  strategies: [],
  feature_flag: :experimental_feature,
  error_message: "This feature is not yet available"
```