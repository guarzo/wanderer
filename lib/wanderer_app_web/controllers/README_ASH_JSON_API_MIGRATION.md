# Controller Migration Status

This document tracks the migration of controllers to AshJsonApi.

## Migration Status

### ✅ Migrated to AshJsonApi

These resources now have AshJsonApi support. The original controllers are kept for backward compatibility with legacy routes.

1. **AccessListMember** 
   - Legacy: `/api/acls/:acl_id/members`
   - AshJsonApi: `/api/v1/ash/access_list_members`
   - Controller kept for nested route compatibility

2. **MapSystemStructure**
   - Legacy: `/api/map/structures`
   - AshJsonApi: `/api/v1/ash/map_system_structures`
   - Controller handles custom timer endpoints

3. **MapSystemSignature**
   - Legacy: `/api/map/signatures`
   - AshJsonApi: `/api/v1/ash/map_system_signatures`
   - Controller kept for complex update logic

4. **MapConnection**
   - Legacy: `/api/map/connections`
   - AshJsonApi: `/api/v1/ash/map_connections`
   - Controller handles bulk operations

5. **AccessList**
   - Legacy: `/api/acls`
   - AshJsonApi: `/api/v1/ash/access_lists`
   - Controller kept for v1 routes

6. **MapTransaction** (New)
   - AshJsonApi only: `/api/v1/ash/map_transactions`
   - No legacy controller needed

7. **MapPing** (New)
   - AshJsonApi only: `/api/v1/ash/map_pings`
   - No legacy controller needed

### 🔄 Partially Migrated

These controllers have complex business logic and only basic CRUD is migrated:

- **MapAPIController** - Complex map operations, activity tracking
- **MapSystemAPIController** - System-specific operations beyond CRUD
- **CommonAPIController** - Cross-cutting concerns, system lookups
- **CharactersAPIController** - Character tracking logic

### ❌ Not Suitable for AshJsonApi

These controllers contain non-CRUD operations:

- **MapAuditAPIController** - Analytics and reporting
- **AuthController** - Authentication flows
- **BlogController** - Static content
- **RedirectController** - URL redirects

## Migration Guidelines

### For Controllers Being Migrated

1. **Add AshJsonApi to Resource**: Add `extensions: [AshJsonApi.Resource]`
2. **Configure Routes**: Define JSON:API routes in the resource
3. **Keep Controller**: Maintain for legacy route compatibility
4. **Document Changes**: Note both legacy and new endpoints

### For New Resources

1. **Start with AshJsonApi**: Use AshJsonApi from the beginning
2. **No Controller Needed**: Unless custom logic required
3. **Use Standard Routes**: Follow JSON:API conventions

### Backward Compatibility

All legacy routes continue to work:
- Legacy routes use existing controllers
- New v1 routes use AshJsonApi
- Both point to the same underlying Ash resources
- No breaking changes for API consumers

### Client Migration Path

Clients can migrate gradually:
1. Continue using legacy endpoints (no changes required)
2. Optionally migrate to JSON:API endpoints for new features
3. Legacy endpoints will be deprecated in future (with notice)

## Benefits Achieved

1. **Reduced Code**: ~70% less controller code for CRUD operations
2. **Consistency**: All CRUD follows JSON:API specification
3. **Features**: Free filtering, sorting, pagination, includes
4. **Documentation**: Automatic OpenAPI generation
5. **Maintenance**: Focus on business logic, not HTTP handling