#!/bin/bash

# Simple Template Creation and Application Script
set -euo pipefail
trap 'echo -e "\n❌ Script failed on line $LINENO" >&2' ERR

# Configuration
API_BASE_URL="http://localhost:4444"
API_TOKEN="8f8912c2-ce9c-4f4d-9901-f1260c29b4f2"
MAP_SLUG="flygd"

# Validate required parameters
if [ -z "$API_TOKEN" ]; then
  echo "❌ Error: API_TOKEN is not set"
  exit 1
fi

if [ -z "$MAP_SLUG" ]; then
  echo "❌ Error: MAP_SLUG is not set"
  exit 1
fi

echo -e "\n🔧 ======== Simple Template Creation and Application ========"

echo -e "\n🧱 1. Creating a template with explicit systems and connections..."
TEMPLATE_NAME="API Test Template $(date +%s)"

REQUEST='{
  "name": "'$TEMPLATE_NAME'",
  "description": "A test template created via API",
  "category": "test",
  "author_eve_id": "2122019111",
  "is_public": false,
  "systems": [
    { "solar_system_id": 30000142, "name": "Jita" },
    { "solar_system_id": 30002053, "name": "Hek" }
  ],
  "connections": [
    { "source_index": 0, "target_index": 1, "type": 0 }
  ]
}'

RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/templates?slug=${MAP_SLUG}" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$REQUEST")

echo "📬 Create response:"
echo "$RESPONSE" | jq '.'

TEMPLATE_ID=$(echo "$RESPONSE" | jq -r '.data.id')

if [ -n "$TEMPLATE_ID" ] && [ "$TEMPLATE_ID" != "null" ]; then
  echo -e "\n✅ Successfully created template with ID: $TEMPLATE_ID"

  echo -e "\n📤 2. Applying the template to the map..."
  APPLY_PAYLOAD='{
    "template_id": "'$TEMPLATE_ID'"
  }'

  APPLY_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/templates/apply?slug=${MAP_SLUG}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$APPLY_PAYLOAD")

  echo "📬 Apply response:"
  echo "$APPLY_RESPONSE" | jq '.'

  SYSTEMS_ADDED=$(echo "$APPLY_RESPONSE" | jq -r '.data.systems_added // 0')
  if [ "$SYSTEMS_ADDED" -gt 0 ]; then
    echo -e "✅ SUCCESS: Template application added $SYSTEMS_ADDED systems"
  else
    echo -e "🟡 Note: No systems were added — they may already exist"
  fi

  echo -e "\n🎉 Template creation and application completed!"
else
  echo "❌ Failed to create template. Cannot continue."
  exit 1
fi
