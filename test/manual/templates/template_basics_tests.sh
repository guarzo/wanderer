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
    '{name:$name,description:"A test template",category:"test",
      author_eve_id:"2122019111",is_public:false,
      systems:[],connections:[]}')
  raw=$(make_request POST "$API_BASE_URL/api/templates?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  verify_http_code "$status" 201 "Create template" || return 1
- TEMPLATE_ID=$(jq -r '.data.id' <<<"$body")
- [[ -n "$TEMPLATE_ID" && "$TEMPLATE_ID" != "null" ]]
+ TEMPLATE_ID=$(jq -r '.data.id // empty' <<<"$body")
+ if [[ -z "$TEMPLATE_ID" ]]; then
+   echo "🚫 Create template: response did not contain .data.id" >&2
+   return 1
+ fi
}

test_create_from_map() {
  local payload raw status body
  
  # First, add a test system to the map
  local system_payload
  system_payload=$(jq -n \
    '{systems:[{solar_system_id:30001660,position_x:111,position_y:222}]}')
  raw=$(make_request PATCH "$API_BASE_URL/api/map/systems?slug=$MAP_SLUG" "$system_payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  # Verify system addition was successful
  if [[ ! "$status" =~ ^2[0-9]{2}$ ]]; then
    echo "Failed to add test system to map, status: $status"
    echo "Response: $body"
    # Continue anyway, to see if we can create a template without adding a system first
  fi
  
  # Now create template from map that has system(s)
  payload=$(jq -n \
    --arg name "From Map Template $(date +%s)" \
    '{name:$name,description:"From map",category:"test",
      author_eve_id:"2122019111",is_public:false}')
  raw=$(make_request POST "$API_BASE_URL/api/templates/from-map?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  verify_http_code "$status" 201 "Create from-map template" || return 1
  TEMPLATE_FROM_MAP_ID=$(jq -r '.data.id' <<<"$body")
  [[ -n "$TEMPLATE_FROM_MAP_ID" && "$TEMPLATE_FROM_MAP_ID" != "null" ]]
}

test_list_templates() {
  local raw status names
  raw=$(make_request GET "$API_BASE_URL/api/templates?slug=$MAP_SLUG&is_public=false")
  status=$(parse_status "$raw")
  verify_http_code "$status" 200 "List templates" || return 1
  names=$(parse_response "$raw" | jq -r '.data[].name')
  # Match the full name including timestamp
  grep -Fxq "$TEMPLATE_NAME" <<<"$names"
}

test_update_metadata() {
  local payload raw status body
  payload='{"metadata":{"test_key":"test_val"}}'
  raw=$(make_request PATCH "$API_BASE_URL/api/templates/$TEMPLATE_ID/content?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  verify_http_code "$status" 200 "Update metadata" || return 1
  [[ "$(jq -r '.data.metadata.test_key' <<<"$body")" == "test_val" ]]
}

test_confirm_metadata() {
  local raw status body
  raw=$(make_request GET "$API_BASE_URL/api/templates/$TEMPLATE_ID?slug=$MAP_SLUG")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  verify_http_code "$status" 200 "Get template" || return 1
  [[ "$(jq -r '.data.metadata.test_key' <<<"$body")" == "test_val" ]]
}

test_update_content() {
  local payload raw status body
  payload='{"systems":[{"solar_system_id":30002187}],"connections":[]}'
  raw=$(make_request PATCH "$API_BASE_URL/api/templates/$TEMPLATE_ID/content?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  verify_http_code "$status" 200 "Update content" || return 1
  [[ "$(jq -r '.data.systems[0].solar_system_id' <<<"$body")" == "30002187" ]]
}

test_confirm_content() {
  local raw status body
  raw=$(make_request GET "$API_BASE_URL/api/templates/$TEMPLATE_ID?slug=$MAP_SLUG")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  verify_http_code "$status" 200 "Get updated template" || return 1
  [[ "$(jq -r '.data.systems[0].solar_system_id' <<<"$body")" == "30002187" ]]
}

test_apply_template() {
  local raw status body
  
  # First verify that the template has systems
  raw=$(make_request GET "$API_BASE_URL/api/templates/$TEMPLATE_ID?slug=$MAP_SLUG")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  if [[ "$status" != "200" ]]; then
    echo "Failed to get template info, status: $status"
    echo "Response: $body"
    return 1
  fi
  
  # Extract systems count to confirm we have systems to apply
  systems_count=$(jq '.data.systems | length' <<<"$body")
  solar_system_id=$(jq -r '.data.systems[0].solar_system_id' <<<"$body")
  
  if [[ "$systems_count" -le 0 ]]; then
    echo "Template has no systems to apply, count: $systems_count"
    return 1
  fi
  
  # Apply template
  apply_payload="{\"template_id\":\"$TEMPLATE_ID\"}"
  raw=$(make_request POST "$API_BASE_URL/api/templates/apply?slug=$MAP_SLUG" "$apply_payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  
  [[ "$status" =~ ^2[0-9]{2}$ ]]
}

test_cleanup_basic() {
  # delete both templates, ignore errors
  make_request DELETE "$API_BASE_URL/api/templates/$TEMPLATE_ID?slug=$MAP_SLUG" >/dev/null
  make_request DELETE "$API_BASE_URL/api/templates/$TEMPLATE_FROM_MAP_ID?slug=$MAP_SLUG" >/dev/null
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
