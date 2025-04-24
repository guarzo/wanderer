%{
  title: "Comprehensive Guide: Wanderer API Documentation",
  author: "Wanderer Team",
  cover_image_uri: "/images/news/03-05-api/swagger-ui.png",
  tags: ~w(api map acl characters documentation swagger),
  description: "Complete documentation for Wanderer's public APIs, including map data, character information, and access control management. Includes interactive API documentation with Swagger UI."
}

---

---
title: Wanderer API Developer Guide
author: Wanderer Team
cover: /images/blog/api-guide-cover.jpg
tags: [api, development, documentation]
description: A comprehensive guide for developers looking to integrate with the Wanderer API.
---

# Wanderer API Developer Guide

Welcome to the Wanderer API Developer Guide. This documentation is intended for developers who want to build integrations, tools, or custom applications that interact with Wanderer's functionality.

## Introduction

Wanderer provides a RESTful API that allows you to programmatically access and manipulate maps, characters, access control lists, and more. Whether you're building a tool for your corporation or creating a custom dashboard, this guide will help you get started.

For interactive API documentation, please visit the [Swagger UI](/api/swagger).

## Authentication

### Authentication Types

Wanderer supports two types of authentication tokens:

1. **Map API Token**: For map-specific operations
2. **ACL API Token**: For access control list operations

### How to Authenticate

All API requests must include an `Authorization` header with a Bearer token:

```
Authorization: Bearer YOUR_TOKEN_HERE
```

#### Where to Find Your Tokens

- **Map API Token**: Available in the map settings page under "API Access"
- **ACL API Token**: Available in the ACL settings page under "API Access"

### Authentication Errors

If authentication fails, you'll receive a `401 Unauthorized` response with an error message. Common authentication errors include:

- Missing token
- Invalid token format
- Expired token
- Insufficient permissions

## Error Handling

### Error Response Format

All API errors follow a consistent format:

```json
{
  "error": "Descriptive error message"
}
```

### HTTP Status Codes

The API uses standard HTTP status codes:

- `200 OK`: Request succeeded
- `201 Created`: Resource was successfully created
- `400 Bad Request`: Invalid input parameters
- `401 Unauthorized`: Authentication failed
- `403 Forbidden`: Insufficient permissions
- `404 Not Found`: Resource not found
- `500 Internal Server Error`: Server-side error

## Common Request Patterns

### Map Identification

Most API endpoints that operate on maps accept two alternative parameters for map identification:

- `map_id`: The UUID of the map
- `slug`: The human-readable slug of the map

Example:
```
/api/map/systems?map_id=466e922b-e758-485e-9b86-afae06b88363
```

OR

```
/api/map/systems?slug=my-wormhole-map
```

### Pagination

Endpoints that return collections support pagination via the following query parameters:

- `page`: Page number (starts at 1)
- `limit`: Number of items per page (default: 20, max: 100)

Example:
```
/api/map/audit?map_id=466e922b-e758-485e-9b86-afae06b88363&page=2&limit=50
```

### Filtering

Many collection endpoints support filtering via query parameters. Specific filters are documented with each endpoint.

## Response Format

Successful API calls return data in a consistent format:

```json
{
  "data": { ... }
}
```

For collections, the data field contains an array:

```json
{
  "data": [
    { ... },
    { ... }
  ]
}
```

## Rate Limiting

To ensure service stability, the API implements rate limiting:

- 60 requests per minute per token
- 5,000 requests per day per token

Rate limit headers are included in all responses:

- `X-RateLimit-Limit`: Total requests allowed in the current time window
- `X-RateLimit-Remaining`: Requests remaining in the current time window
- `X-RateLimit-Reset`: Time in seconds until the rate limit resets

## Best Practices

### Caching

To improve performance and reduce API calls, consider caching responses. Many resources include `updated_at` timestamps that you can use to determine if your cached data needs refreshing.

### Conditional Requests

The API supports conditional requests using ETags. Use the `If-None-Match` header with the ETag value from a previous response to avoid retrieving unchanged resources.

### Handling Errors

Implement robust error handling in your application. Always check for error responses and handle them gracefully.

### Rate Limit Handling

Implement retry logic with exponential backoff for rate limit errors. Monitor the rate limit headers to avoid hitting limits.

### Batch Operations

Where available, use batch operations (e.g., creating multiple systems at once) to reduce the number of API calls.

## API Endpoints Reference

This section provides an overview of the available API endpoints organized by category. For detailed parameter specifications and response formats, refer to the [Swagger UI](/api/swagger).

### Map API

#### Maps

- `GET /api/map` - List available maps
- `POST /api/map` - Create a new map
- `GET /api/map/:id` - Get map details
- `PATCH /api/map/:id` - Update map properties
- `DELETE /api/map/:id` - Delete a map

#### Systems

- `GET /api/map/systems` - List systems in a map
- `POST /api/map/systems` - Create a new system
- `GET /api/map/systems/:id` - Get system details
- `PATCH /api/map/systems/:id` - Update system properties
- `DELETE /api/map/systems/:id` - Delete a system

#### Connections

- `GET /api/map/connections` - List connections between systems
- `POST /api/map/connections` - Create a new connection
- `GET /api/map/connections/:id` - Get connection details
- `PATCH /api/map/connections/:id` - Update connection properties
- `DELETE /api/map/connections/:id` - Delete a connection

#### Audit

- `GET /api/map/audit` - List audit events for a map

### Character API

- `GET /api/characters` - List characters
- `GET /api/characters/:id` - Get character details
- `POST /api/characters/locate` - Set character location
- `GET /api/map/characters` - Get characters in a specific map

### Access Control API

#### Access Lists

- `GET /api/access_lists` - List access control lists
- `POST /api/access_lists` - Create a new access list
- `GET /api/access_lists/:id` - Get access list details
- `PATCH /api/access_lists/:id` - Update access list properties
- `DELETE /api/access_lists/:id` - Delete an access list

#### Access List Members

- `GET /api/access_lists/:id/members` - List members of an access list
- `POST /api/access_lists/:id/members` - Add a member to an access list
- `DELETE /api/access_lists/:id/members/:member_id` - Remove a member from an access list
- `PATCH /api/access_lists/:id/members/:member_id` - Update a member's role

#### Map Access Lists

- `GET /api/map/access_lists` - Get access lists associated with a map
- `POST /api/map/access_lists` - Associate an access list with a map
- `DELETE /api/map/access_lists/:id` - Remove an access list from a map

### Template API

- `GET /api/map/templates` - List available templates
- `POST /api/map/templates` - Create a new template
- `GET /api/map/templates/:id` - Get template details
- `PATCH /api/map/templates/:id/metadata` - Update template metadata
- `PATCH /api/map/templates/:id/content` - Update template content
- `DELETE /api/map/templates/:id` - Delete a template
- `POST /api/map/templates/apply` - Apply a template to a map
- `POST /api/map/templates/from_map` - Create a template from an existing map

### License API

- `GET /api/licenses` - List license information
- `GET /api/licenses/validate` - Validate license status

### Utility API

- `GET /api/util/ping` - Check API connectivity
- `GET /api/util/status` - Get server status
- `GET /api/util/version` - Get API version information

## Common Use Cases

### Tracking Character Locations

```javascript
// Example: Tracking character locations
async function trackCharacterLocations(mapId) {
  const response = await fetch(`/api/map/characters?map_id=${mapId}`, {
    headers: {
      'Authorization': `Bearer ${apiToken}`,
      'Content-Type': 'application/json'
    }
  });
  
  if (!response.ok) {
    throw new Error(`API error: ${response.status}`);
  }
  
  const data = await response.json();
  return data.data; // Array of characters with location info
}
```

### Monitoring System Activity

```javascript
// Example: Monitoring system activity
async function getSystemActivity(mapId, systemId, period = "1D") {
  const response = await fetch(`/api/map/audit?map_id=${mapId}&system_id=${systemId}&period=${period}`, {
    headers: {
      'Authorization': `Bearer ${apiToken}`,
      'Content-Type': 'application/json'
    }
  });
  
  if (!response.ok) {
    throw new Error(`API error: ${response.status}`);
  }
  
  const data = await response.json();
  return data.data; // Array of audit events
}
```

### Applying Templates

```javascript
// Example: Applying a template to a map
async function applyTemplate(mapId, templateId, position = { x: 0, y: 0 }) {
  const response = await fetch(`/api/map/templates/apply?map_id=${mapId}`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiToken}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      template_id: templateId,
      position_x: position.x,
      position_y: position.y,
      cleanup_existing: false
    })
  });
  
  if (!response.ok) {
    throw new Error(`API error: ${response.status}`);
  }
  
  const data = await response.json();
  return data.data; // Result of template application
}
```

## Troubleshooting

### Common Issues

1. **Authentication Errors**
   - Verify that you're using the correct token type for the endpoint
   - Check that the token is still valid
   - Ensure the token has the necessary permissions

2. **Resource Not Found**
   - Confirm that the resource ID or slug is correct
   - Verify that the resource exists and is accessible to your token

3. **Rate Limiting**
   - Implement backoff and retry logic
   - Consider batching requests where possible

### Diagnostic Steps

1. Check the HTTP status code and error message
2. Verify that your request format matches the API documentation
3. Try the same operation in the Swagger UI to isolate client-side issues

## Support

If you encounter issues or have questions about the API:

1. Consult the [API Reference Documentation](/api/swagger)
2. Join our [Discord community](https://discord.gg/wanderer)
3. Submit a support ticket through the Wanderer application
4. Email us at api-support@wanderer.example.com

---

This guide will be continuously updated as new features are added to the API. Last updated: April 15, 2025. 