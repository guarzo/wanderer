# Ash Policy System Documentation

This document describes the authorization system implemented using Ash policies, which replaces controller-based authorization with resource-level policies.

## Overview

The new policy system moves authorization logic from controller plugs to Ash resource policies, providing:

1. **Resource-Level Authorization**: Policies are defined on the resources themselves
2. **Action-Specific Rules**: Different permissions for different actions
3. **Centralized Logic**: All authorization logic in one place per resource
4. **Consistent Patterns**: Same authorization patterns across all resources
5. **Actor-Based Security**: Policies work with the authenticated user/character as actor

## Policy Architecture

### Core Components

#### 1. **Policy Checks Module** (`WandererApp.Api.Policies.Checks`)
Contains reusable authorization logic:

- **`admin?/3`** - Checks if actor is application admin
- **`owner?/3`** - Checks if actor owns the resource
- **`has_acl_role?/3`** - Checks ACL membership and role level
- **`has_map_permission?/3`** - Checks map-specific permissions
- **`has_map_access?/3`** - Checks if actor has any map access
- **`same_organization?/3`** - Checks EVE character/corp/alliance matching

#### 2. **Resource Policies**
Each resource defines policies using the checks:

```elixir
policies do
  # Admin users can do anything
  policy action_type(:*) do
    authorize_if Checks.admin?()
  end
  
  # Resource owners can manage their resources
  policy action_type([:read, :update, :destroy]) do
    authorize_if Checks.owner?()
  end
  
  # Default deny
  policy action_type(:*) do
    forbid_if always()
  end
end
```

## Resource-Specific Policies

### 1. AccessList Policies

**Access Patterns**:
- **Admins**: Full access to all ACLs
- **Owners**: Can manage their own ACLs
- **Users**: Can create new ACLs, view ACLs they're members of

**Key Policies**:
```elixir
# ACL owners can manage their ACLs
policy action_type([:read, :update, :destroy]) do
  authorize_if Checks.owner?()
end

# Users can create new ACLs (they become the owner)
policy action(:create) do
  authorize_if actor_present()
end
```

### 2. AccessListMember Policies

**Access Patterns**:
- **Admins**: Full access to all ACL members
- **ACL Owners**: Can manage all members in their ACLs
- **ACL Admins**: Can manage members (except owners/admins)
- **ACL Managers**: Can read members and manage basic roles
- **ACL Members**: Can read other members in same ACL
- **Same Organization**: Can read info about themselves

**Role Hierarchy**:
- **Owner** (level 5): Full control
- **Admin** (level 4): Manage most members
- **Manager** (level 3): Basic member management
- **Member** (level 2): Read access
- **Viewer** (level 1): Limited read access

### 3. Map Policies

**Access Patterns**:
- **Admins**: Full access to all maps
- **Map Owners**: Can manage their maps
- **Admin Map Permission**: Can manage maps
- **Manage Map Permission**: Can update maps
- **Any Map Access**: Can read maps

**Permission Integration**:
Uses the existing bitwise permission system:
```elixir
# Users with admin map permissions can manage maps
policy action_type([:read, :update, :update_acls]) do
  authorize_if Checks.has_map_permission?(permission: :admin_map)
end
```

### 4. Map-Related Resource Policies

All map-related resources (connections, signatures, structures) follow similar patterns:

**Connection Policies**:
- **Delete Connection Permission**: Can delete connections
- **Add Connection Permission**: Can create connections  
- **Update Connection Permission**: Can modify connections
- **View Connection Permission**: Can read connections

**System-Related Policies** (Signatures, Structures):
- **Update System Permission**: Can modify signatures/structures
- **View System Permission**: Can read signatures/structures

## Permission System Integration

### Bitwise Permissions

The policy system integrates with the existing bitwise permission system:

```elixir
@view_system 1
@view_character 2
@view_connection 4
@add_system 8
@add_connection 16
@update_system 32
@track_character 64
@delete_connection 128
@delete_system 256
@lock_system 512
@add_acl 1024
@delete_acl 2048
@delete_map 4096
@manage_map 8192
@admin_map 16384
```

### Permission Calculation

The `has_map_permission?/3` check calculates permissions based on:

1. **Map Ownership**: Map owners get all permissions
2. **ACL Memberships**: Role-based permissions through ACLs
3. **Organization Matching**: Character/corporation/alliance membership

## Actor System

### Actor Structure

Policies expect an actor with these fields:
```elixir
%{
  id: uuid,                    # User/Character ID
  eve_character_id: integer,   # EVE Character ID
  eve_corporation_id: integer, # EVE Corporation ID (optional)
  eve_alliance_id: integer     # EVE Alliance ID (optional)
}
```

### Actor Setting

The actor is set in the authentication pipeline and passed to Ash operations:

```elixir
# In controller or API call
WandererApp.Api.read(AccessList, %{}, actor: current_user)
```

## Policy Check Examples

### Admin Check
```elixir
def admin?(actor, _context, _opts) do
  case actor do
    %{eve_character_id: character_id} ->
      admins = Application.get_env(:wanderer_app, :admin_character_ids, [])
      character_id in admins
    _ ->
      false
  end
end
```

### ACL Role Check
```elixir
def has_acl_role?(actor, %{resource: resource}, opts) do
  required_role = Keyword.get(opts, :role, :member)
  acl_field = Keyword.get(opts, :acl_field, :access_list_id)
  
  case {actor, Map.get(resource, acl_field)} do
    {%{eve_character_id: character_id}, acl_id} when not is_nil(acl_id) ->
      check_acl_membership(character_id, acl_id, required_role)
    _ ->
      false
  end
end
```

### Map Permission Check
```elixir
def has_map_permission?(actor, %{resource: resource}, opts) do
  required_permission = Keyword.get(opts, :permission, :view_system)
  map_field = Keyword.get(opts, :map_field, :map_id)
  
  case {actor, Map.get(resource, map_field)} do
    {%{eve_character_id: character_id}, map_id} when not is_nil(map_id) ->
      permissions = calculate_map_permissions(character_id, map_id)
      Permissions.has_permission?(permissions, required_permission)
    _ ->
      false
  end
end
```

## Migration from Controller Authorization

### Before (Controller Plugs)
```elixir
pipeline :api_acl do
  plug WandererAppWeb.Plugs.CheckAclAuth
end

def index(conn, params) do
  # Manual authorization check
  if authorized?(conn.assigns.current_user, :read, :acl_members) do
    # Handle request
  else
    send_resp(conn, 403, "Forbidden")
  end
end
```

### After (Ash Policies)
```elixir
policies do
  policy action(:read) do
    authorize_if Checks.has_acl_role?(role: :member)
  end
end

def index(conn, params) do
  # Authorization handled automatically by Ash
  case WandererApp.Api.read(AccessListMember, params, actor: conn.assigns.current_user) do
    {:ok, members} -> json(conn, %{data: members})
    {:error, :forbidden} -> send_resp(conn, 403, "Forbidden")
  end
end
```

## Benefits

1. **Centralized Authorization**: All auth logic in resource definitions
2. **Consistent Patterns**: Same patterns across all resources
3. **Better Testability**: Policies can be tested independently
4. **Automatic Enforcement**: No risk of forgetting auth checks
5. **Clear Documentation**: Policies serve as authorization documentation
6. **Resource Composition**: Policies work with Ash's resource composition
7. **Performance**: Built-in query optimization for authorization

## Common Patterns

### Resource Ownership
```elixir
policy action_type([:read, :update, :destroy]) do
  authorize_if Checks.owner?()
end
```

### Role-Based Access
```elixir
policy action(:manage_members) do
  authorize_if Checks.has_acl_role?(role: :admin)
end
```

### Permission-Based Access
```elixir
policy action(:create) do
  authorize_if Checks.has_map_permission?(permission: :add_system)
end
```

### Admin Override
```elixir
policy action_type(:*) do
  authorize_if Checks.admin?()
end
```

### Default Deny
```elixir
policy action_type(:*) do
  forbid_if always()
end
```

## Testing Policies

Policies can be tested by calling Ash actions with different actors:

```elixir
test "owner can read their ACL" do
  user = user_fixture()
  acl = acl_fixture(owner_id: user.id)
  
  assert {:ok, _} = WandererApp.Api.read(AccessList, %{id: acl.id}, actor: user)
end

test "non-owner cannot read ACL" do
  user = user_fixture()
  other_user = user_fixture()
  acl = acl_fixture(owner_id: user.id)
  
  assert {:error, :forbidden} = WandererApp.Api.read(AccessList, %{id: acl.id}, actor: other_user)
end
```