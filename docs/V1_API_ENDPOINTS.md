# V1 API Endpoints - JSON:API Compliant

The V1 API (`/api/v1/*`) has been restructured to use AshJsonApi for all standard CRUD operations, making it fully JSON:API compliant while keeping custom endpoints for complex business logic.

## New API Structure

### 🆕 JSON:API CRUD Resources

All standard CRUD operations now follow JSON:API specification:

#### Access Control Lists
```
GET    /api/v1/acls              # List ACLs
GET    /api/v1/acls/:id          # Get specific ACL
POST   /api/v1/acls              # Create ACL
PATCH  /api/v1/acls/:id          # Update ACL
DELETE /api/v1/acls/:id          # Delete ACL
GET    /api/v1/acls/available    # Available ACLs (custom)
```

#### ACL Members
```
GET    /api/v1/acl_members           # List ACL members
GET    /api/v1/acl_members/:id       # Get specific member
POST   /api/v1/acl_members           # Create member
PATCH  /api/v1/acl_members/:id       # Update member
DELETE /api/v1/acl_members/:id       # Delete member
PATCH  /api/v1/acl_members/:id/role  # Update role (custom)
PATCH  /api/v1/acl_members/:id/block # Block member (custom)
PATCH  /api/v1/acl_members/:id/unblock # Unblock member (custom)
```

#### Connections
```
GET    /api/v1/connections                  # List connections
GET    /api/v1/connections/:id             # Get specific connection
POST   /api/v1/connections                 # Create connection
PATCH  /api/v1/connections/:id             # Update connection
DELETE /api/v1/connections/:id             # Delete connection
PATCH  /api/v1/connections/:id/mass_status # Update mass status (custom)
PATCH  /api/v1/connections/:id/time_status # Update time status (custom)
PATCH  /api/v1/connections/:id/ship_size   # Update ship size (custom)
PATCH  /api/v1/connections/:id/locked      # Update locked status (custom)
```

#### Structures
```
GET    /api/v1/structures                               # List structures
GET    /api/v1/structures/:id                          # Get specific structure
POST   /api/v1/structures                              # Create structure
PATCH  /api/v1/structures/:id                          # Update structure
DELETE /api/v1/structures/:id                          # Delete structure
GET    /api/v1/structures/active                       # Active structures (custom)
GET    /api/v1/structures/by_map/:map_id/system/:system_id # Filtered structures (custom)
```

#### Signatures
```
GET    /api/v1/signatures                      # List signatures
GET    /api/v1/signatures/:id                  # Get specific signature
POST   /api/v1/signatures                      # Create signature
PATCH  /api/v1/signatures/:id                  # Update signature
DELETE /api/v1/signatures/:id                  # Delete signature
PATCH  /api/v1/signatures/:id/linked_system    # Update linked system (custom)
PATCH  /api/v1/signatures/:id/type             # Update type (custom)
PATCH  /api/v1/signatures/:id/group            # Update group (custom)
GET    /api/v1/signatures/active               # Active signatures (custom)
```

#### Transactions
```
GET    /api/v1/transactions     # List transactions
GET    /api/v1/transactions/:id # Get specific transaction
POST   /api/v1/transactions     # Create transaction
PATCH  /api/v1/transactions/:id # Update transaction
DELETE /api/v1/transactions/:id # Delete transaction
```

#### Pings
```
GET    /api/v1/pings                                    # List pings
GET    /api/v1/pings/:id                               # Get specific ping
POST   /api/v1/pings                                   # Create ping
DELETE /api/v1/pings/:id                               # Delete ping
GET    /api/v1/pings/by_map/:map_id                    # Pings by map (custom)
GET    /api/v1/pings/by_map/:map_id/system/:system_id  # Pings by map+system (custom)
```

### 🎯 Custom Business Logic Endpoints

Complex operations that don't fit standard CRUD patterns:

#### Map-Specific Operations
```
GET /api/v1/maps/:map_identifier/audit        # Map audit logs
GET /api/v1/maps/:map_identifier/activity     # Character activity
GET /api/v1/maps/:map_identifier/kills        # System kills
GET /api/v1/maps/:map_identifier/characters   # Tracked characters
GET /api/v1/maps/:map_identifier/users/characters # User characters
GET /api/v1/maps/:map_identifier/systems      # Map-specific systems
```

#### Global Operations
```
GET /api/v1/systems/:id    # Global system lookup
GET /api/v1/characters     # Global character operations
GET /api/v1/openapi        # OpenAPI specification
```

## JSON:API Features

All JSON:API endpoints support standard features:

### Filtering
```
GET /api/v1/acls?filter[name]=Test
GET /api/v1/connections?filter[mass_status]=critical
```

### Sorting
```
GET /api/v1/signatures?sort=-inserted_at,name
GET /api/v1/transactions?sort=amount
```

### Pagination
```
GET /api/v1/acl_members?page[size]=20&page[number]=2
```

### Including Relationships
```
GET /api/v1/acl_members?include=access_list
GET /api/v1/connections?include=system_from,system_to
```

### Sparse Fieldsets
```
GET /api/v1/signatures?fields[map_system_signature]=name,type,group
```

## Request/Response Format

### JSON:API Request Format
```json
POST /api/v1/acls
{
  "data": {
    "type": "access_list",
    "attributes": {
      "name": "My ACL",
      "description": "Test access list"
    }
  }
}
```

### JSON:API Response Format
```json
{
  "data": {
    "type": "access_list",
    "id": "123",
    "attributes": {
      "name": "My ACL",
      "description": "Test access list",
      "inserted_at": "2024-01-01T00:00:00Z"
    },
    "relationships": {
      "members": {
        "links": {
          "related": "/api/v1/acl_members?filter[access_list_id]=123"
        }
      }
    }
  }
}
```

## Migration from Legacy API

### For CRUD Operations
- **Legacy**: `/api/acls` → **V1**: `/api/v1/acls`
- **Legacy**: `/api/map/signatures` → **V1**: `/api/v1/signatures`
- **Legacy**: `/api/acls/:id/members` → **V1**: `/api/v1/acl_members?filter[access_list_id]=:id`

### For Custom Operations
- **Legacy**: `/api/character-activity` → **V1**: `/api/v1/maps/:id/activity`
- **Legacy**: `/api/map/systems-kills` → **V1**: `/api/v1/maps/:id/kills`

## Authentication

All V1 endpoints use the same authentication as before:
- Bearer tokens for API keys
- JWT tokens for user authentication
- ACL keys for access list operations

## Benefits

1. **Standards Compliance**: Full JSON:API specification adherence
2. **Rich Features**: Built-in filtering, sorting, pagination, includes
3. **Consistent Format**: All responses follow same structure
4. **Auto Documentation**: OpenAPI specs generated automatically
5. **Client Libraries**: Can use standard JSON:API client libraries
6. **Backward Compatible**: Legacy routes continue to work unchanged