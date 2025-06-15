# Migrating Controllers to AshJsonApi

This guide demonstrates how to migrate existing CRUD controllers to use AshJsonApi, which automatically generates JSON:API compliant endpoints from Ash resources.

## Benefits of AshJsonApi

1. **Automatic CRUD Operations**: No need to write controller actions
2. **JSON:API Compliance**: Follows the JSON:API specification out of the box
3. **Consistent Response Format**: Standardized data/errors structure
4. **Built-in Features**: Pagination, filtering, sorting, includes
5. **OpenAPI Support**: Automatic OpenAPI documentation generation
6. **Reduced Boilerplate**: Focus on business logic, not HTTP handling

## Migration Example: AccessListMember

### Step 1: Add AshJsonApi Extension to Resource

**Before:**
```elixir
defmodule WandererApp.Api.AccessListMember do
  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer
    
  # ... rest of resource
end
```

**After:**
```elixir
defmodule WandererApp.Api.AccessListMember do
  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource]  # Add this
    
  # Add JSON:API configuration
  json_api do
    type "access_list_member"
    
    routes do
      base "/access_list_members"
      
      # Define which actions are exposed
      get :read
      index :read
      post :create
      patch :update_role  # Custom action
      delete :destroy
    end
  end
    
  # ... rest of resource
end
```

### Step 2: Remove Controller (or Keep for Custom Logic)

With AshJsonApi, the standard CRUD operations are handled automatically. You can:

1. **Remove the controller entirely** if it only does CRUD
2. **Keep it for custom actions** that don't fit standard CRUD

**Original Controller (can be removed):**
```elixir
defmodule WandererAppWeb.AccessListMemberAPIController do
  use WandererAppWeb, :controller
  
  def index(conn, %{"acl_id" => acl_id}) do
    # ... implementation
  end
  
  def create(conn, params) do
    # ... implementation
  end
  
  def update(conn, params) do
    # ... implementation
  end
  
  def delete(conn, %{"member_id" => member_id}) do
    # ... implementation
  end
end
```

### Step 3: Update Routes

**Before:**
```elixir
resources "/acls", MapAccessListAPIController do
  resources "/members", AccessListMemberAPIController,
    only: [:index, :create, :update, :delete]
end
```

**After:**
```elixir
# Remove the nested resource - it's now handled by AshJsonApi
resources "/acls", MapAccessListAPIController

# AshJsonApi routes are automatically available at:
# GET    /api/v1/ash/access_list_members
# GET    /api/v1/ash/access_list_members/:id
# POST   /api/v1/ash/access_list_members
# PATCH  /api/v1/ash/access_list_members/:id
# DELETE /api/v1/ash/access_list_members/:id
```

### Step 4: Update Client Code

**Before:**
```javascript
// Nested under ACL
GET /api/v1/acls/123/members
POST /api/v1/acls/123/members
```

**After:**
```javascript
// Standard JSON:API endpoints
GET /api/v1/ash/access_list_members?filter[acl_id]=123
POST /api/v1/ash/access_list_members
{
  "data": {
    "type": "access_list_member",
    "attributes": {
      "acl_id": "123",
      "character_id": "456",
      "role": "member"
    }
  }
}
```

## Complete Migration Examples

### 1. MapTransaction (No Existing Controller)

```elixir
defmodule WandererApp.Api.MapTransaction do
  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource]

  json_api do
    type "map_transaction"
    
    routes do
      base "/map_transactions"
      
      get :read
      index :read
      post :create
      patch :update
      delete :destroy
    end
  end
  
  # Existing resource definition...
end
```

### 2. MapPing (With Custom Actions)

```elixir
defmodule WandererApp.Api.MapPing do
  use Ash.Resource,
    domain: WandererApp.Api,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource]

  json_api do
    type "map_ping"
    
    routes do
      base "/map_pings"
      
      get :read
      index :read
      post :new  # Custom create action
      delete :destroy
      
      # Custom routes for filtered queries
      index :by_map, route: "/by_map/:map_id"
      index :by_map_and_system, route: "/by_map/:map_id/system/:system_id"
    end
  end
  
  # Existing resource definition...
end
```

## Authentication with AshJsonApi

AshJsonApi respects the existing authentication pipeline. Add authentication to the AshJsonApi scope:

```elixir
scope "/ash" do
  pipe_through [:api, :api_auth]  # Your auth pipeline
  
  forward "/", WandererAppWeb.AshJsonApiRouter
end
```

## Features You Get for Free

### 1. Filtering
```
GET /api/v1/ash/map_transactions?filter[type]=in&filter[amount][greater_than]=100
```

### 2. Sorting
```
GET /api/v1/ash/map_transactions?sort=-inserted_at,amount
```

### 3. Pagination
```
GET /api/v1/ash/map_transactions?page[size]=20&page[number]=2
```

### 4. Including Relationships
```
GET /api/v1/ash/map_transactions?include=map,user
```

### 5. Sparse Fieldsets
```
GET /api/v1/ash/map_transactions?fields[map_transaction]=type,amount,inserted_at
```

## Gradual Migration Strategy

1. **Start with Simple Resources**: Begin with resources that have no controllers (MapTransaction, MapPing)
2. **Add Authentication**: Ensure auth pipelines work with AshJsonApi routes
3. **Migrate CRUD-only Controllers**: Convert controllers that only do standard CRUD
4. **Keep Complex Controllers**: Maintain controllers with business logic
5. **Update Documentation**: Ensure OpenAPI specs are updated
6. **Test Thoroughly**: Verify all endpoints work as expected

## Maintaining OpenAPI Compatibility

AshJsonApi automatically generates OpenAPI documentation. To ensure compatibility:

1. Access the OpenAPI spec at: `/api/v1/ash/openapi`
2. Compare with existing specs using the breaking change detection
3. Update client SDKs if needed

## Best Practices

1. **Use Custom Actions**: Define custom actions in Ash resources for non-CRUD operations
2. **Leverage Policies**: Move authorization logic to Ash policies
3. **Keep URLs Stable**: Use redirects if changing URL structure
4. **Version Appropriately**: Consider this a minor version bump, not breaking
5. **Monitor Performance**: AshJsonApi is optimized but verify performance

## Rollback Plan

Since AshJsonApi resources are separate from existing controllers:

1. Both can run in parallel during migration
2. Gradually migrate one resource at a time
3. Keep old controllers until clients are updated
4. Remove old code only after validation