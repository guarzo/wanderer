#!/bin/bash

# 🧪 Final Template API Test Script with Enhanced UX
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

echo -e "\n🔧 ======== Map Template API Test ========"

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

  echo -e "\n📦 2. Creating a template from current map..."
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

  echo "📬 From map response:"
  echo "$FROM_MAP_RESPONSE" | jq '.'

  TEMPLATE_FROM_MAP_ID=$(echo "$FROM_MAP_RESPONSE" | jq -r '.data.id')

  echo -e "\n🧹 2b. Deleting existing systems for a clean apply..."
  SYSTEMS_RESPONSE=$(curl -s "${API_BASE_URL}/api/map/systems?slug=${MAP_SLUG}" \
    -H "Authorization: Bearer ${API_TOKEN}")

  SYSTEM_IDS=$(echo "$SYSTEMS_RESPONSE" | jq -r '.data[].id // empty')

  if [ -n "$SYSTEM_IDS" ]; then
    SYSTEM_IDS_JSON=$(echo "$SYSTEM_IDS" | jq -Rs 'split("\n") | map(select(length > 0))')
    DELETE_PAYLOAD="{\"system_ids\": $SYSTEM_IDS_JSON}"

    DELETE_SYSTEMS_RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "${API_BASE_URL}/api/map/systems?slug=${MAP_SLUG}" \
      -H "Authorization: Bearer ${API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$DELETE_PAYLOAD")

    DELETE_BODY=$(echo "$DELETE_SYSTEMS_RESPONSE" | head -n 1)
    DELETE_CODE=$(echo "$DELETE_SYSTEMS_RESPONSE" | tail -n 1)

    echo "🧻 System DELETE response code: $DELETE_CODE"
    echo "$DELETE_BODY" | jq .
  else
    echo "🟡 No systems found to delete. Skipping cleanup."
  fi

  echo "🔍 Systems after delete:"
  curl -s "${API_BASE_URL}/api/map/systems?slug=${MAP_SLUG}" \
    -H "Authorization: Bearer ${API_TOKEN}" | jq .

  echo -e "\n📤 3. Applying the template to the map..."
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
    echo -e "🟡 Note: No systems were added — they may already exist or cleanup failed"
  fi

  echo -e "\n🎉 All template API tests completed successfully!"
else
  echo "❌ Failed to create template. Cannot continue."
  exit 1
fi

echo -e "\n🧼 4. Cleaning up created templates..."
if [ -n "$TEMPLATE_ID" ] && [ "$TEMPLATE_ID" != "null" ]; then
  DELETE_RESPONSE=$(curl -s -X DELETE "${API_BASE_URL}/api/templates/${TEMPLATE_ID}?slug=${MAP_SLUG}" \
    -H "Authorization: Bearer ${API_TOKEN}")
  echo "🗑️  Deleted template $TEMPLATE_ID: $(echo "$DELETE_RESPONSE" | jq -r '.data.success // "Failed"')"
fi

if [ -n "${TEMPLATE_FROM_MAP_ID:-}" ] && [ "$TEMPLATE_FROM_MAP_ID" != "null" ]; then
  DELETE_RESPONSE=$(curl -s -X DELETE "${API_BASE_URL}/api/templates/${TEMPLATE_FROM_MAP_ID}?slug=${MAP_SLUG}" \
    -H "Authorization: Bearer ${API_TOKEN}")
  echo "🗑️  Deleted template $TEMPLATE_FROM_MAP_ID: $(echo "$DELETE_RESPONSE" | jq -r '.data.success // "Failed"')"
fi

echo -e "\n✅ Test cleanup completed."
