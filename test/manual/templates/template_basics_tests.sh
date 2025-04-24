#!/usr/bin/env bash
# tests/template_basics_tests.sh
# Basic Template API Tests - Creation, Metadata, and Content Operations

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"      # shared helpers
export RUN_NO_CLEANUP=true

TEMPLATE_ID=""
TEMPLATE_FROM_MAP_ID=""
TEMPLATE_NAME=""

test_create_template() {
  local payload raw status body
  TEMPLATE_NAME="API Test Template $(date +%s)"
  payload=$(jq -n \
    --arg name "$TEMPLATE_NAME" \
    '{
      name: $name,
      description: "A test template",
      category: "test",
      author_eve_id: "2122019111",
      is_public: false,
      systems: [],
      connections: []
    }')
  raw=$(make_request POST "$API_BASE_URL/api/maps/$MAP_SLUG/templates" "$payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  if ! verify_http_code "$status" 201 "Create template"; then
    echo "❌ Failed to create template: $status"
    echo "Response: $body"
    return 1
  fi
  
  TEMPLATE_ID=$(jq -r '.data.id' <<<"$body")
  if [[ -z "$TEMPLATE_ID" || "$TEMPLATE_ID" == "null" ]]; then
    echo "❌ Failed to extract template ID from response"
    echo "Response: $body"
    return 1
  fi
  
  echo "✅ Created template with ID: $TEMPLATE_ID"
  return 0
}

test_create_from_map() {
  local payload raw status body
  
  # First, add a test system to the map
  local system_payload
  system_payload=$(jq -n \
    '{systems:[{
      solar_system_id: 30001660,
      position_x: 0,
      position_y: 0,
      size: 1,
      security_class: null,
      security_status: 0,
      region_id: 10000001,
      constellation_id: 20000001
    }]}')
  raw=$(make_request PATCH "$API_BASE_URL/api/maps/$MAP_SLUG/systems-and-connections" "$system_payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  # Verify system addition was successful
  if [[ ! "$status" =~ ^2[0-9]{2}$ ]]; then
    echo "Failed to add test system to map, status: $status"
    echo "Response: $body"
    # Continue anyway, to see if we can create a template without adding a system first
  fi
  
  # Get system ID from the map
  raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_SLUG/systems")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  local system_ids=()
  if [[ "$status" == "200" ]]; then
    # Try to extract system IDs
    IFS=$'\n' read -rd '' -a system_ids < <(jq -r '.data[].id' <<<"$body" 2>/dev/null && printf '\0')
  fi
  
  # Now create template from map that has system(s)
  payload=$(jq -n \
    --arg name "From Map Template $(date +%s)" \
    '{
      name: $name,
      description: "From map",
      category: "test",
      author_eve_id: "2122019111",
      is_public: false,
      system_ids: ["30001660"]
    }')
  
  echo "Creating template from map with payload: $payload"
  
  raw=$(make_request POST "$API_BASE_URL/api/maps/$MAP_SLUG/templates/from_map" "$payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  if ! verify_http_code "$status" 201 "Create from-map template"; then
    echo "❌ Failed to create template from map: $status"
    echo "Response: $body"
    return 1
  fi
  
  TEMPLATE_FROM_MAP_ID=$(jq -r '.data.id' <<<"$body")
  if [[ -z "$TEMPLATE_FROM_MAP_ID" || "$TEMPLATE_FROM_MAP_ID" == "null" ]]; then
    echo "❌ Failed to extract template ID from response"
    echo "Response: $body"
    return 1
  fi
  
  echo "✅ Created from-map template with ID: $TEMPLATE_FROM_MAP_ID"
  return 0
}

test_list_templates() {
  local raw status names
  raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_SLUG/templates?is_public=false")
  status=$(parse_status "$raw")
  verify_http_code "$status" 200 "List templates" || return 1
  names=$(parse_response "$raw" | jq -r '.data[].name')
  # Match the full name including timestamp
  grep -Fxq "$TEMPLATE_NAME" <<<"$names"
}

test_update_metadata() {
  local payload raw status body
  
  # Use PATCH method for metadata updates
  payload=$(jq -n '{
    name: "Updated Name",
    description: "Updated description",
    category: "updated",
    is_public: true
  }')
  
  echo "Updating template metadata with ID: $TEMPLATE_ID"
  raw=$(make_request PATCH "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$TEMPLATE_ID" "$payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  if ! verify_http_code "$status" 200 "Update metadata"; then
    echo "❌ Failed to update template metadata: $status"
    echo "Response: $body"
    return 1
  fi
  
  # Verify the updated name
  local updated_name
  updated_name=$(jq -r '.data.name' <<<"$body")
  if [[ "$updated_name" != "Updated Name" ]]; then
    echo "❌ Template name not updated correctly"
    echo "Expected: Updated Name"
    echo "Got: $updated_name"
    return 1
  fi
  
  echo "✅ Template metadata updated successfully"
  return 0
}

test_confirm_metadata() {
  local raw status body
  raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$TEMPLATE_ID")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  verify_http_code "$status" 200 "Get template" || return 1
  [[ "$(jq -r '.data.name' <<<"$body")" == "Updated Name" ]]
}

test_update_content() {
  local payload raw status body
  
  payload=$(jq -n '{
    systems: [
      {
        solar_system_id: 30002187,
        position_x: 0,
        position_y: 0,
        size: 1,
        security_class: null,
        security_status: 0,
        region_id: 10000002,
        constellation_id: 20000002
      }
    ],
    connections: []
  }')
  
  echo "Updating template content with ID: $TEMPLATE_ID"
  raw=$(make_request PUT "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$TEMPLATE_ID/content" "$payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  if ! verify_http_code "$status" 200 "Update content"; then
    echo "❌ Failed to update template content: $status"
    echo "Response: $body"
    return 1
  fi
  
  # Verify the system was added
  if ! jq -e '.data.systems[0].solar_system_id == 30002187' <<<"$body" >/dev/null; then
    echo "❌ System not added correctly to template"
    echo "Response: $body"
    return 1
  fi
  
  echo "✅ Template content updated successfully"
  return 0
}

test_confirm_content() {
  local raw status body
  raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$TEMPLATE_ID")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  verify_http_code "$status" 200 "Get updated template" || return 1
  [[ "$(jq -r '.data.systems[0].solar_system_id' <<<"$body")" == "30002187" ]]
}

test_apply_template() {
  local raw status body
  
  # First verify that the template has systems
  raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$TEMPLATE_ID")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  if [[ "$status" != "200" ]]; then
    echo "Failed to get template info, status: $status"
    echo "Response: $body"
    return 1
  fi
  
  # Extract systems count to confirm we have systems to apply
  systems_count=$(jq '.data.systems | length' <<<"$body")
  
  if [[ "$systems_count" -le 0 ]]; then
    echo "Template has no systems to apply, count: $systems_count"
    return 1
  fi
  
  solar_system_id=$(jq -r '.data.systems[0].solar_system_id' <<<"$body")
  echo "Applying template with system ID: $solar_system_id"
  
  # Apply template
  apply_payload="{\"template_id\":\"$TEMPLATE_ID\"}"
  raw=$(make_request POST "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$TEMPLATE_ID/apply" "$apply_payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  if ! [[ "$status" =~ ^2[0-9]{2}$ ]]; then
    echo "❌ Failed to apply template: $status"
    echo "Response: $body"
    return 1
  fi
  
  echo "✅ Template applied successfully"
  return 0
}

test_cleanup_basic() {
  # delete both templates, ignore errors
  make_request DELETE "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$TEMPLATE_ID" >/dev/null
  make_request DELETE "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$TEMPLATE_FROM_MAP_ID" >/dev/null
  return 0
}

run_test "Create template"                 test_create_template
run_test "Create from-map template"        test_create_from_map
run_test "List templates includes ours"    test_list_templates
run_test "Update metadata"                 test_update_metadata
run_test "Confirm metadata persisted"      test_confirm_metadata
run_test "Update content"                  test_update_content
run_test "Confirm content persisted"       test_confirm_content
run_test "Apply template to map"           test_apply_template
run_test "Cleanup basic templates"         test_cleanup_basic
