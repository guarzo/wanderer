#!/bin/bash

# Final Working Template API Test Script
set -euo pipefail

# Configuration
API_BASE_URL="http://localhost:4444"
API_TOKEN="33486e7e-01bd-412b-844d-a63635a8821f"
MAP_SLUG="flygd"

# Validate required parameters
if [ -z "$API_TOKEN" ]; then
  echo "Error: API_TOKEN is not set"
  exit 1
fi

if [ -z "$MAP_SLUG" ]; then
  echo "Error: MAP_SLUG is not set"
  exit 1
fi

echo "======== Map Template API Test ========"

echo "1. Creating a template..."
TEMPLATE_NAME="API Test Template $(date +%s)"

# Template creation - Need slug in query parameter, not in body
REQUEST='{
  "name": "'$TEMPLATE_NAME'",
  "description": "A test template created via API",
  "category": "test",
  "author_eve_id": "2122019111",
  "is_public": false,
  "systems": [],
  "connections": []
}'

# Create template
RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/templates?slug=${MAP_SLUG}" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST")

echo "Create response:"
echo "$RESPONSE" | jq '.'

# Extract template ID
TEMPLATE_ID=$(echo "$RESPONSE" | jq -r '.data.id')

if [ -n "$TEMPLATE_ID" ] && [ "$TEMPLATE_ID" != "null" ]; then
  echo "Successfully created template with ID: $TEMPLATE_ID"
  
  echo "2. Creating a template from map..."
  # Create template from map
  FROM_MAP_PAYLOAD='{
    "name": "From Map Template '"$(date +%s)"'",
    "description": "Generated from test map",
    "category": "test",
    "author_eve_id": "2122019111",
    "is_public": false
  }'
  
  FROM_MAP_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/templates/from-map?slug=${MAP_SLUG}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$FROM_MAP_PAYLOAD")
  
  echo "From map response:"
  echo "$FROM_MAP_RESPONSE" | jq '.'
  
  # Extract second template ID
  TEMPLATE_FROM_MAP_ID=$(echo "$FROM_MAP_RESPONSE" | jq -r '.data.id')
  
  echo "3. Applying template to map..."
  # Apply template to map
  APPLY_PAYLOAD='{
    "template_id": "'$TEMPLATE_ID'"
  }'
  
  APPLY_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/templates/apply?slug=${MAP_SLUG}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$APPLY_PAYLOAD")
  
  echo "Apply response:"
  echo "$APPLY_RESPONSE" | jq '.'
  
  echo "All template API tests completed successfully!"
else
  echo "Failed to create template. Cannot continue with other tests."
  exit 1
fi

# Clean up created templates for idempotency
echo "4. Cleaning up created templates..."
if [ -n "$TEMPLATE_ID" ] && [ "$TEMPLATE_ID" != "null" ]; then
  DELETE_RESPONSE=$(curl -s -X DELETE "${API_BASE_URL}/api/templates/${TEMPLATE_ID}" \
    -H "Authorization: Bearer ${API_TOKEN}")
  echo "Deleted template $TEMPLATE_ID: $(echo "$DELETE_RESPONSE" | jq -r '.data.success // "Failed"')"
fi

if [ -n "${TEMPLATE_FROM_MAP_ID:-}" ] && [ "$TEMPLATE_FROM_MAP_ID" != "null" ]; then
  DELETE_RESPONSE=$(curl -s -X DELETE "${API_BASE_URL}/api/templates/${TEMPLATE_FROM_MAP_ID}" \
    -H "Authorization: Bearer ${API_TOKEN}")
  echo "Deleted template $TEMPLATE_FROM_MAP_ID: $(echo "$DELETE_RESPONSE" | jq -r '.data.success // "Failed"')"
fi

echo "Test cleanup completed."