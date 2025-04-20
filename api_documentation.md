# WandererApp API Documentation

This documentation covers the Map System and Map Template API endpoints available in WandererApp.

## Authentication and Authorization

All API endpoints require authentication and use the following pipelines:
- `api` - Basic API acceptor
- `api_map` - Checks for a valid map API key and subscription
- `api_kills` - Specific for kill data endpoints

API keys must be provided in the request headers.

## Map System API

### List Map Systems

**Endpoint:** `GET /api/map/systems`

**Description:** Lists all visible systems for a specified map.

**Parameters:**
- `map_id` (query, optional): Map UUID
- `slug` (query, optional): Map slug

**Note:** Either `map_id` OR `slug` must be provided.

**Example Request:**
```bash
curl -X GET "https://example.com/api/map/systems?slug=map-slug" \
  -H "Authorization: Bearer YOUR_API_KEY"
```

**Response:**
```json
{
  "data": [
    {
      "id": "system-uuid",
      "map_id": "map-uuid",
      "solar_system_id": 30000142,
      "name": "Jita",
      "original_name": "Jita",
      "custom_name": null,
      "temporary_name": null,
      "description": "Trade hub",
      "tag": "HUB",
      "labels": "{\"customLabel\":\"Hub\",\"labels\":[\"highsec\"]}",
      "locked": false,
      "visible": true,
      "status": 0,
      "position_x": 100,
      "position_y": 200,
      "inserted_at": "2025-04-20T10:30:00Z",
      "updated_at": "2025-04-20T10:30:00Z"
    }
  ]
}
```

### Show Map System

**Endpoint:** `GET /api/map/system`

**Description:** Retrieves details for a specific map system.

**Parameters:**
- `id` (query, required): Solar system ID
- `map_id` (query, optional): Map UUID
- `slug` (query, optional): Map slug

**Note:** Either `map_id` OR `slug` must be provided.

**Example Request:**
```bash
curl -X GET "https://example.com/api/map/system?id=30000142&slug=map-slug" \
  -H "Authorization: Bearer YOUR_API_KEY"
```

**Response:**
```json
{
  "data": {
    "id": "system-uuid",
    "map_id": "map-uuid",
    "solar_system_id": 30000142,
    "name": "Jita",
    "original_name": "Jita",
    "custom_name": null,
    "temporary_name": null,
    "description": "Trade hub",
    "tag": "HUB",
    "labels": "{\"customLabel\":\"Hub\",\"labels\":[\"highsec\"]}",
    "locked": false,
    "visible": true,
    "status": 0,
    "position_x": 100,
    "position_y": 200,
    "inserted_at": "2025-04-20T10:30:00Z",
    "updated_at": "2025-04-20T10:30:00Z"
  }
}
```

### Delete Systems

**Endpoint:** `DELETE /api/map/systems`

**Description:** Deletes multiple systems in a batch operation. This will also delete any connections associated with the deleted systems.

**Request Body:**
```json
{
  "slug": "map-slug",
  "system_ids": [
    "system-uuid-1",
    "system-uuid-2"
  ]
}
```

**Example Request:**
```bash
curl -X DELETE "https://example.com/api/map/systems" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"slug":"map-slug","system_ids":["system-uuid-1","system-uuid-2"]}'
```

**Response:**
```json
{
  "data": {
    "deleted_count": 2,
    "deleted_connections_count": 3
  }
}
```

## Map Template API

### List Templates

**Endpoint:** `GET /api/templates`

**Description:** Lists available templates, filtered by category, author, or public status.

**Parameters:**
- `category` (query, optional): Filter by category (e.g., 'wormhole', 'k-space')
- `author_eve_id` (query, optional): Filter by creator's EVE Character ID
- `public` (query, optional): If true, only public templates are returned
- `slug` (query, required): Map slug to identify the map

**Example Request:**
```bash
curl -X GET "https://example.com/api/templates?category=wormhole&slug=map-slug" \
  -H "Authorization: Bearer YOUR_API_KEY"
```

**Response:**
```json
{
  "data": [
    {
      "id": "template-uuid",
      "name": "C5 Wolf Rayet",
      "description": "Standard C5 Wolf Rayet wormhole setup",
      "category": "wormhole",
      "author_eve_id": "2122019111",
      "source_map_id": "source-map-uuid",
      "is_public": true,
      "inserted_at": "2025-04-20T10:30:00Z",
      "updated_at": "2025-04-20T10:30:00Z"
    }
  ]
}
```

### Get Template

**Endpoint:** `GET /api/templates/:id`

**Description:** Gets a template by ID.

**Parameters:**
- `id` (path, required): Template ID

**Example Request:**
```bash
curl -X GET "https://example.com/api/templates/466e922b-e758-485e-9b86-afae06b88363" \
  -H "Authorization: Bearer YOUR_API_KEY"
```

**Response:**
```json
{
  "data": {
    "id": "template-uuid",
    "name": "C5 Wolf Rayet",
    "description": "Standard C5 Wolf Rayet wormhole setup",
    "category": "wormhole",
    "author_eve_id": "2122019111",
    "source_map_id": "source-map-uuid",
    "is_public": true,
    "inserted_at": "2025-04-20T10:30:00Z",
    "updated_at": "2025-04-20T10:30:00Z",
    "systems": [
      {
        "solar_system_id": 31002229,
        "position_x": 100,
        "position_y": 200,
        "labels": "{\"customLabel\":\"Home\",\"labels\":[\"wolf-rayet\"]}"
      }
    ],
    "connections": [
      {
        "solar_system_source": 31002229,
        "solar_system_target": 30003160,
        "type": "K162"
      }
    ],
    "metadata": {
      "version": "1.0",
      "notes": "Template created for demonstration"
    }
  }
}
```

### Create Template

**Endpoint:** `POST /api/templates`

**Description:** Creates a new template.

**Parameters:**
- `slug` (query, required): Map slug to identify the map

**Request Body:**
```json
{
  "name": "My Template",
  "description": "A custom template",
  "category": "custom",
  "author_eve_id": "2122019111",
  "is_public": false,
  "systems": [],
  "connections": []
}
```

**Example Request:**
```bash
curl -X POST "https://example.com/api/templates?slug=map-slug" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"My Template","description":"A custom template","category":"custom","author_eve_id":"2122019111","is_public":false,"systems":[],"connections":[]}'
```

**Response:**
```json
{
  "data": {
    "id": "new-template-uuid",
    "name": "My Template",
    "description": "A custom template",
    "category": "custom",
    "author_eve_id": "2122019111",
    "source_map_id": null,
    "is_public": false,
    "inserted_at": "2025-04-20T10:30:00Z",
    "updated_at": "2025-04-20T10:30:00Z"
  }
}
```

### Create Template from Map

**Endpoint:** `POST /api/templates/from-map`

**Description:** Creates a template from an existing map.

**Parameters:**
- `slug` (query, required): Map slug to identify the map

**Request Body:**
```json
{
  "name": "Map Template",
  "description": "Generated from my map",
  "category": "custom",
  "author_eve_id": "2122019111",
  "is_public": false
}
```

**Example Request:**
```bash
curl -X POST "https://example.com/api/templates/from-map?slug=map-slug" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"Map Template","description":"Generated from my map","category":"custom","author_eve_id":"2122019111","is_public":false}'
```

**Response:**
```json
{
  "data": {
    "id": "new-template-uuid",
    "name": "Map Template",
    "description": "Generated from my map",
    "category": "custom",
    "author_eve_id": "2122019111",
    "source_map_id": "source-map-uuid",
    "is_public": false,
    "inserted_at": "2025-04-20T10:30:00Z",
    "updated_at": "2025-04-20T10:30:00Z"
  }
}
```

### Update Template Metadata

**Endpoint:** `PATCH /api/templates/:id/metadata`

**Description:** Updates a template's metadata.

**Parameters:**
- `id` (path, required): Template ID

**Request Body:**
```json
{
  "name": "Updated Template Name",
  "description": "Updated description",
  "is_public": true
}
```

**Example Request:**
```bash
curl -X PATCH "https://example.com/api/templates/466e922b-e758-485e-9b86-afae06b88363/metadata" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"Updated Template Name","description":"Updated description","is_public":true}'
```

**Response:**
```json
{
  "data": {
    "id": "template-uuid",
    "name": "Updated Template Name",
    "description": "Updated description",
    "category": "custom",
    "author_eve_id": "2122019111",
    "source_map_id": "source-map-uuid",
    "is_public": true,
    "inserted_at": "2025-04-20T10:30:00Z",
    "updated_at": "2025-04-20T10:35:00Z"
  }
}
```

### Update Template Content

**Endpoint:** `PATCH /api/templates/:id/content`

**Description:** Updates a template's content (systems, connections, metadata).

**Parameters:**
- `id` (path, required): Template ID

**Request Body:**
```json
{
  "systems": [
    {
      "solar_system_id": 30000142,
      "position_x": 150,
      "position_y": 250,
      "labels": "{\"customLabel\":\"Updated Hub\",\"labels\":[\"highsec\",\"trade\"]}"
    }
  ],
  "connections": [],
  "metadata": {
    "version": "1.1",
    "notes": "Updated by test script"
  }
}
```

**Example Request:**
```bash
curl -X PATCH "https://example.com/api/templates/466e922b-e758-485e-9b86-afae06b88363/content" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"systems":[{"solar_system_id":30000142,"position_x":150,"position_y":250,"labels":"{\"customLabel\":\"Updated Hub\",\"labels\":[\"highsec\",\"trade\"]}"}],"connections":[],"metadata":{"version":"1.1","notes":"Updated by test script"}}'
```

**Response:**
```json
{
  "data": {
    "id": "template-uuid",
    "name": "My Template",
    "description": "A custom template",
    "category": "custom",
    "author_eve_id": "2122019111",
    "source_map_id": "source-map-uuid",
    "is_public": false,
    "inserted_at": "2025-04-20T10:30:00Z",
    "updated_at": "2025-04-20T10:35:00Z",
    "systems": [
      {
        "solar_system_id": 30000142,
        "position_x": 150,
        "position_y": 250,
        "labels": "{\"customLabel\":\"Updated Hub\",\"labels\":[\"highsec\",\"trade\"]}"
      }
    ],
    "connections": [],
    "metadata": {
      "version": "1.1",
      "notes": "Updated by test script"
    }
  }
}
```

### Delete Template

**Endpoint:** `DELETE /api/templates/:id`

**Description:** Deletes a template.

**Parameters:**
- `id` (path, required): Template ID

**Example Request:**
```bash
curl -X DELETE "https://example.com/api/templates/466e922b-e758-485e-9b86-afae06b88363" \
  -H "Authorization: Bearer YOUR_API_KEY"
```

**Response:** Empty response with status code 204 (No Content)

### Apply Template

**Endpoint:** `POST /api/templates/apply`

**Description:** Applies a template to a map.

**Parameters:**
- `slug` (query, required): Map slug to identify the map

**Request Body:**
```json
{
  "template_id": "template-uuid"
}
```

**Example Request:**
```bash
curl -X POST "https://example.com/api/templates/apply?slug=map-slug" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"template_id":"template-uuid"}'
```

**Response:**
```json
{
  "data": {
    "systems_created": 5,
    "connections_created": 6
  }
}
```

## API Quality Review and Suggestions

### Strengths
1. Well-structured API with clear endpoint purposes
2. Good use of OpenApiSpex for documentation
3. Consistent error handling
4. Support for both direct ID lookups and slugs
5. Proper validation of inputs
6. Clear separation of templates and systems APIs

### Improvement Suggestions

1. **Map Identification Consistency**: The template API requires the map slug as a query parameter, while the system API accepts it in either the query or request body. This inconsistency can be confusing for API users. 
The system api should be updated to only accept it as a query parameter

2. **Required Fields Documentation**: The template creation endpoint requires empty arrays for `systems` and `connections` even if they're not being used. This is confusing, and should be changed.

