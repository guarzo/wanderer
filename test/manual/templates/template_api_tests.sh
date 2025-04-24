#!/usr/bin/env bash
# ─── Template API Endpoint Tests ─────────────────────────────────────────────────
# Usage:
#   ./template_api_tests.sh         # Run tests without debug output
#   DEBUG=1 ./template_api_tests.sh # Run tests with debug output
#
# Note: This tests specific controller actions directly, bypassing the Phoenix router's resources.

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Set DEBUG to false by default
DEBUG=${DEBUG:-}

# Add a stub route to test if the controller is working
test_controller_exists() {
  echo "Testing if controller routes are accessible..."
  
  # Try a simpler route from the API to verify the controller is working
  local raw status response
  raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_SLUG/systems")
  status=$(parse_status "$raw")
  
  if [[ "$status" != "200" ]]; then
    echo "❌ ERROR: Cannot access API systems endpoint. Check your server and API_TOKEN."
    echo "Status: $status"
    return 1
  fi
  
  echo "✅ API Access test passed"
  return 0
}

# Enhanced response parsing (same as other API test scripts)
parse_response_safe() {
  local raw="$1"
  
  # If empty input, return empty JSON
  if [[ -z "$raw" ]]; then
    echo "{}"
    return
  fi
  
  # Extract the JSON part from a HTTP response (ignore headers)
  # Get all non-HTTP header lines and keep only lines that look like JSON
  local json_part=$(echo "$raw" | grep -v "^HTTP/" | grep -v "^[[:space:]]*$")
  
  # Print the raw response for debugging only if DEBUG is set
  if [[ -n "$DEBUG" ]]; then
    echo "DEBUG Raw response: $raw" >&2
    echo "DEBUG JSON part: $json_part" >&2
  fi
  
  # If it starts with a number (status code), remove that line
  if [[ "$json_part" =~ ^[0-9]{3}$ ]]; then
    [[ -n "$DEBUG" ]] && echo "DEBUG Removing status line" >&2
    json_part=$(echo "$json_part" | grep -v "^[0-9]\{3\}$")
  fi
  
  # Validate JSON format
  if echo "$json_part" | jq . &>/dev/null; then
    echo "$json_part"
  else
    # Try to extract just the JSON part if there's mixed content
    local json_extract=$(echo "$raw" | grep -o '{.*}')
    if [[ -n "$json_extract" ]] && echo "$json_extract" | jq . &>/dev/null; then
      echo "$json_extract"
    else
      # If not valid JSON, return empty object
      echo "{}"
    fi
  fi
}

# Track created entities for cleanup
CREATED_TEMPLATES=()

# Parse response carefully to avoid malformed JSON issues
check_json_response() {
  local response="$1"
  local key="$2"
  
  # First check if it's valid JSON
  if ! echo "$response" | jq . >/dev/null 2>&1; then
    echo "❌ Invalid JSON response"
    echo "Response: $response"
    return 1
  fi
  
  # Then check if it has the expected key (simplified approach)
  if [[ -n "$key" ]]; then
    # Remove the leading dot if present
    key=${key#.}
    if ! echo "$response" | grep -q "\"$key\""; then
      echo "❌ Response missing $key field"
      echo "Response: $response"
      return 1
    fi
  fi
  
  return 0
}

# ─── Template List Tests ─────────────────────────────────────────────────────────

test_template_list_endpoint() {
  echo "Testing template list endpoint..."
  
  # Check if controller exists and is accessible
  if ! test_controller_exists; then
    echo "⚠️ Skipping template tests - controller not accessible"
    return 1
  fi
  
  # Test the standard templates endpoint with map slug
  echo "Testing templates list with map slug..."
  local raw status response
  raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_SLUG/templates")
  status=$(parse_status "$raw")
  
  if [[ "$status" != "200" ]]; then
    echo "❌ Failed to list templates: $status"
    if [[ -n "$DEBUG" ]]; then
      response=$(parse_response_safe "$raw")
      echo "Response: $response"
    fi
    return 1
  fi
  
  # Verify the response format with data wrapper
  response=$(parse_response_safe "$raw")
  if [[ -n "$DEBUG" ]]; then
    echo "DEBUG Full response: $response"
  fi
  
  if ! check_json_response "$response" ".data"; then
    return 1
  fi
  
  # If successful and we have MAP_ID, try with the map ID too
  if [[ -n "$MAP_ID" ]]; then
    echo "Testing templates list with map ID..."
    raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_ID/templates")
    status=$(parse_status "$raw")
    
    if [[ "$status" != "200" ]]; then
      echo "❌ Failed to list templates with map ID: $status"
      return 1
    fi
    
    # Verify the response format with data wrapper
    response=$(parse_response_safe "$raw")
    if ! check_json_response "$response" ".data"; then
      return 1
    fi
  fi
  
  echo "✅ Template list endpoint test passed"
  return 0
}

# ─── Template Create Tests ───────────────────────────────────────────────────────

test_template_create() {
  echo "Testing template create endpoint..."
  
  # Create a test template payload with required fields
  local template_id random_suffix template_name template_payload raw status response
  random_suffix=$(date +%s)
  template_name="API Test Template $random_suffix"
  
  template_payload=$(jq -n \
    --arg name "$template_name" \
    '{
      "name": $name,
      "description": "A test template",
      "category": "test",
      "author_eve_id": "2122019111",
      "is_public": false,
      "systems": [],
      "connections": []
    }')
  
  if [[ -n "$DEBUG" ]]; then
    echo "DEBUG Template payload: $template_payload"
  fi
  
  # Test template creation with map slug
  echo "Creating test template with slug..."
  raw=$(make_request POST "$API_BASE_URL/api/maps/$MAP_SLUG/templates" "$template_payload")
  status=$(parse_status "$raw")
  
  if [[ "$status" != "201" && "$status" != "200" ]]; then
    echo "❌ Failed to create template: $status"
    response=$(parse_response_safe "$raw")
    echo "Response: $response"
    return 1
  fi
  
  response=$(parse_response_safe "$raw")
  if [[ -n "$DEBUG" ]]; then
    echo "DEBUG Full response: $response"
  fi
  
  if ! check_json_response "$response" ".data"; then
    return 1
  fi
  
  template_id=$(echo "$response" | jq -r '.data.id // empty' 2>/dev/null)
  
  if [[ -n "$template_id" ]]; then
    echo "Created template with ID: $template_id"
    CREATED_TEMPLATES+=("$template_id")
  else
    echo "❌ Could not extract template ID from response"
    echo "Response: $response"
    return 1
  fi
  
  # Verify the template was created by fetching it
  echo "Verifying template creation by fetching it..."
  raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$template_id")
  status=$(parse_status "$raw")
  
  if [[ "$status" != "200" ]]; then
    echo "❌ Failed to get created template: $status"
    return 1
  fi
  
  response=$(parse_response_safe "$raw")
  if ! check_json_response "$response" ".data"; then
    return 1
  fi
  
  # Verify template name matches what we sent
  fetched_name=$(echo "$response" | jq -r '.data.name // empty' 2>/dev/null)
  if [[ "$fetched_name" != "$template_name" ]]; then
    echo "❌ Template fetched doesn't match created template"
    echo "Expected: $template_name"
    echo "Got: $fetched_name"
    return 1
  fi
  
  echo "✅ Template creation test passed"
  return 0
}

# ─── Template Delete Tests ───────────────────────────────────────────────────────

test_template_delete() {
  echo "Testing template delete endpoint..."
  
  # First create a template to delete
  local template_id random_suffix template_name template_payload raw status response
  random_suffix=$(date +%s)
  template_name="Delete Test Template $random_suffix"
  
  template_payload=$(jq -n \
    --arg name "$template_name" \
    '{
      "name": $name,
      "description": "A test template for deletion",
      "category": "test",
      "author_eve_id": "2122019111",
      "is_public": false,
      "systems": [],
      "connections": []
    }')
  
  echo "Creating a template for delete testing..."
  raw=$(make_request POST "$API_BASE_URL/api/maps/$MAP_SLUG/templates" "$template_payload")
  status=$(parse_status "$raw")
  
  if [[ "$status" != "201" && "$status" != "200" ]]; then
    echo "❌ Failed to create test template for delete test: $status"
    response=$(parse_response_safe "$raw")
    echo "Response: $response"
    return 1
  fi
  
  response=$(parse_response_safe "$raw")
  template_id=$(echo "$response" | jq -r '.data.id // empty' 2>/dev/null)
  
  if [[ -z "$template_id" ]]; then
    echo "❌ Failed to extract template ID from response"
    echo "Response: $response"
    return 1
  fi
  
  echo "Created template ID: $template_id"
  
  # Delete the template
  echo "Deleting template with ID $template_id..."
  raw=$(make_request DELETE "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$template_id")
  status=$(parse_status "$raw")
  
  if [[ "$status" != "204" && "$status" != "200" ]]; then
    echo "❌ Failed to delete template: $status"
    response=$(parse_response_safe "$raw")
    echo "Response: $response"
    return 1
  fi
  
  # Verify deletion by attempting to get the template
  echo "Verifying deletion..."
  raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$template_id")
  status=$(parse_status "$raw")
  
  if [[ "$status" != "404" ]]; then
    echo "❌ Template was not properly deleted, still accessible: $status"
    CREATED_TEMPLATES+=("$template_id") # Add to cleanup list since it wasn't deleted
    return 1
  fi
  
  echo "✅ Template delete test passed"
  return 0
}

# ─── Template Update Tests ─────────────────────────────────────────────────────
test_template_update() {
  echo "🔍 Testing template update endpoint..."
  
  # First create a template
  local template_id
  template_id=$(create_test_template)
  
  # Exit if template creation failed
  if [[ $? -ne 0 ]]; then
    echo "❌ Failed to create test template for update"
    return 1
  fi
  
  # Prepare updated data
  local updated_name="Updated Template $(date +%s)"
  local updated_description="Updated description for testing"
  local updated_data="{\"name\":\"${updated_name}\",\"description\":\"${updated_description}\"}"
  
  # Send update request
  local response
  response=$(api_put "templates/${template_id}" "$updated_data")
  local http_code=$?
  
  # Check response
  if ! verify_http_code $http_code 200; then
    echo "❌ Update template request failed with code $http_code"
    echo "Response: $response"
    cleanup_test_templates
    return 1
  fi
  
  # Verify the response format
  if ! check_json_response "$response" ".data"; then
    echo "❌ Update template response missing data field"
    cleanup_test_templates
    return 1
  fi
  
  # Get the template to verify update
  response=$(api_get "templates/${template_id}")
  http_code=$?
  
  # Check if get was successful
  if ! verify_http_code $http_code 200; then
    echo "❌ Failed to get updated template"
    echo "Response: $response"
    cleanup_test_templates
    return 1
  fi
  
  # Check if the update was applied
  local retrieved_name
  retrieved_name=$(echo "$response" | jq -r '.data.name')
  local retrieved_description
  retrieved_description=$(echo "$response" | jq -r '.data.description')
  
  if [[ "$retrieved_name" != "$updated_name" ]]; then
    echo "❌ Template name was not updated correctly"
    echo "Expected: $updated_name"
    echo "Got: $retrieved_name"
    cleanup_test_templates
    return 1
  fi
  
  if [[ "$retrieved_description" != "$updated_description" ]]; then
    echo "❌ Template description was not updated correctly"
    echo "Expected: $updated_description"
    echo "Got: $retrieved_description"
    cleanup_test_templates
    return 1
  fi
  
  echo "✅ Template update test passed"
  
  # Add to cleanup list
  TEMPLATES_TO_CLEANUP+=("$template_id")
  
  return 0
}

# ─── Cleanup Function ───────────────────────────────────────────────────────────

cleanup() {
  if [ ${#CREATED_TEMPLATES[@]} -gt 0 ]; then
    echo "Processing ${#CREATED_TEMPLATES[@]} templates for cleanup..."
    for id in "${CREATED_TEMPLATES[@]}"; do
      if [[ -n "$id" ]]; then
        echo "Deleting template: $id"
        # Use the correct path for template deletion
        make_request DELETE "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$id" >/dev/null
      fi
    done
  fi
  
  echo "Cleanup completed"
}

# ─── Execute Tests ────────────────────────────────────────────────────────────

echo "Starting Template API endpoint tests..."

# Override run_test to handle debug properly
run_test() {
  local test_name="$1"
  local test_func="$2"
  local start_time=$(date +%s)
  
  # If DEBUG is set, show more output
  if [[ -n "$DEBUG" ]]; then
    echo -e "\n▶ Running test: $test_name"
    if "$test_func"; then
      local duration=$(($(date +%s) - start_time))
      echo -e "✅ Test passed: $test_name ($duration seconds)\n"
      return 0
    else
      local duration=$(($(date +%s) - start_time))
      echo -e "❌ Test failed: $test_name ($duration seconds)\n"
      return 1
    fi
  else
    # Otherwise, capture output and only show if there's a failure
    local output
    output=$(if "$test_func" 2>&1; then
      echo "PASS"
    else
      echo "FAIL"
    fi)
    
    if [[ "$output" == *"PASS"* ]]; then
      echo "✅ $test_name"
      return 0
    else
      echo "❌ $test_name"
      # Re-run with output for debugging
      echo "--- Detailed output from failed test ---"
      if "$test_func"; then
        echo "(Test mysteriously passed on re-run)"
      fi
      echo "--------------------------------------"
      return 1
    fi
  fi
}

# Run the tests
run_test "API connectivity test"       test_controller_exists
run_test "Template listing test"       test_template_list_endpoint
run_test "Template creation test"      test_template_create
run_test "Template deletion test"      test_template_delete
# run_test "Template update test"        test_template_update  # Disabled for now until properly implemented

# Clean up after tests
trap cleanup EXIT

echo "Template API endpoint tests completed."

# ─── API Request Functions ───────────────────────────────────────────────────────

api_put() {
  local endpoint=$1
  local data=$2
  local additional_headers=$3
  
  echo "$data" | curl -s -X PUT \
    -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    $([[ -n "$additional_headers" ]] && echo $additional_headers) \
    -d @- \
    "${API_BASE_URL}/${endpoint}" \
    -o /tmp/api_response
    
  local http_code=$?
  
  cat /tmp/api_response
  return $http_code
}

# ─── Response Verification Functions ───────────────────────────────────────────

verify_http_code() {
  local actual_code=$1
  local expected_code=$2
  
  if [[ "$actual_code" == "$expected_code" ]]; then
    return 0
  else
    return 1
  fi
} 