# Ash Policy Integration Investigation Report

## Summary
The Ash Policy Integration has completely broken the UI functionality for map visibility. Users cannot see any maps in the UI due to authorization failures.

## Timeline of Investigation

### Initial Issue
- **Problem**: Users reported they cannot see any maps in the UI after the API improvements were implemented
- **Root Cause**: The Ash Policy Integration (item #10 from `api_improvements.md`) moved authorization from controller plugs to resource-level Ash policies

### Key Findings

#### 1. Query Filtering Works, But Authorization Fails
The `FilterMapsByRoles` preparation correctly builds the query:
```
FilterMapsByRoles prepare result: #Ash.Query<resource: WandererApp.Api.Map, 
  filter: #Ash.Filter<(owner_id in ["104aa8c1-f998-4f7e-8873-50298307a876"] or 
    exists(acls.members, eve_character_id in ["2115754172"] or 
      eve_corporation_id in ["98648442"] or 
      eve_alliance_id in ["99010452"])) and deleted == false>, 
  load: [owner: [], acls: #Ash.Query<resource: WandererApp.Api.AccessList, load: [members: []]>]>
```

However, the authorization step fails with:
```
get_available_maps failed with error: %Ash.Error.Invalid{query: "#Query<>", 
  errors: [%Ash.Error.Query.NoSuchField{resource: WandererApp.Api.Map, 
    field: WandererApp.Api.Policies.Checks, splode: Ash.Error, 
    bread_crumbs: [], vars: [], path: [], stacktrace: #Splode.Stacktrace<>, 
    class: :invalid}]}
```

#### 2. Policy Module Reference Issue
- Initially found that policy checks were using `{Checks, :function_name}` syntax
- Ash was interpreting `Checks` as a field name instead of a module reference
- Fixed by using full module path: `{WandererApp.Api.Policies.Checks, :function_name}`
- Applied this fix to all 6 affected resources:
  - Map
  - MapConnection
  - MapSystemSignature
  - MapSystemStructure
  - AccessList
  - AccessListMember

#### 3. Circular Authorization Issue (Attempted Fix)
- The `has_map_access?` policy check was causing circular authorization when loading ACL data
- Modified the function to:
  - Check if ACLs are already loaded to avoid unnecessary loading
  - Use `actor: nil` when loading to bypass authorization
  - Provide graceful fallbacks
- **Result**: This fix did not resolve the issue

#### 4. Current Error
Despite all fixes, the error persists:
```
NoSuchField{resource: WandererApp.Api.Map, field: WandererApp.Api.Policies.Checks}
```

This suggests that Ash is still somehow interpreting the module reference as a field name.

## Current Code State

### Map Resource Policies (`/app/lib/wanderer_app/api/map.ex`)
```elixir
policies do
  # Admin users can do anything
  policy action_type(:*) do
    authorize_if {WandererApp.Api.Policies.Checks, :admin?}
  end

  # Map owners can manage their maps
  policy action_type([...]) do
    authorize_if {WandererApp.Api.Policies.Checks, :owner?}
  end

  # Users with any map access can read maps
  policy action(:read) do
    authorize_if {WandererApp.Api.Policies.Checks, :has_map_access?}
  end

  # Users can see maps they have access to
  policy action(:available) do
    authorize_if actor_present()
    # The prepare step will filter results based on access
  end
end
```

### Filter Preparation (`/app/lib/wanderer_app/api/preparations/filter_maps_by_roles.ex`)
- Successfully filters maps based on ownership and ACL membership
- Loads necessary relationships: `[:owner, acls: [:members]]`

### Policy Checks (`/app/lib/wanderer_app/api/policies/checks.ex`)
- Contains all authorization logic
- Fixed circular loading issues in `has_map_access?` function
- Added helper functions for ACL membership checking

## Flow Analysis

1. **UI Request**: User navigates to maps page
2. **LiveView Mount**: Calls `WandererApp.Maps.get_available_maps(current_user)`
3. **API Call**: Executes `WandererApp.Api.Map.available(%{}, actor: current_user)`
4. **Policy Check**: `:available` action passes (only requires `actor_present()`)
5. **Query Preparation**: `FilterMapsByRoles` correctly builds the filtered query
6. **Execution Failure**: Ash fails with `NoSuchField` error

## Impact

- **Complete UI Breakage**: Users cannot see any maps
- **API Still Works**: The underlying data and query logic work correctly
- **Authorization System Broken**: The Ash policy system is not functioning as expected

## Next Steps

### Option 1: Debug Ash Policy System
- Investigate why Ash is interpreting module references as field names
- Check Ash version compatibility
- Review Ash policy documentation for correct syntax

### Option 2: Revert Ash Policies
- Remove all Ash policies from resources
- Restore controller-level authorization plugs
- Keep the query filtering logic (which works correctly)

### Option 3: Hybrid Approach
- Keep Ash policies for write operations only
- Use simple `actor_present()` for read operations
- Rely on query filtering for actual access control

## Recommendation

Given the severity of the issue and the fact that multiple debugging attempts have failed, I recommend **Option 2: Revert Ash Policies**. The benefits of centralized authorization are not worth a completely broken UI. The original plug-based authorization was working correctly and should be restored.

## Lessons Learned

1. **Test Authorization Changes Thoroughly**: Authorization changes affect the entire application
2. **Incremental Migration**: Should have migrated one resource at a time
3. **Fallback Strategy**: Always maintain a working fallback when making system-wide changes
4. **Documentation**: The Ash policy system syntax and behavior need better understanding