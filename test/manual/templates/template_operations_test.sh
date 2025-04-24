#!/usr/bin/env bash
# Template Operations Tests - Filtering & Re-apply

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
export RUN_NO_CLEANUP=true

# Create or load template ID
create_or_load_template() {
  if [[ -f /tmp/basic_template_id.txt ]]; then
    TEMPLATE_ID=$(< /tmp/basic_template_id.txt)
    CREATED_HERE=0
    echo "Using existing template ID: $TEMPLATE_ID"
  else
    echo "Creating new template for operations tests..."
    local raw payload status
    payload=$(jq -n '{
      name: "OpTest",
      description: "Operations Test Template",
      category: "test",
      author_eve_id: "2122019111",
      is_public: false,
      systems: [
        {
          solar_system_id: 30000142,
          name: "Jita",
          position_x: 100,
          position_y: 100
        }
      ],
      connections: []
    }')
    
    raw=$(make_request POST "$API_BASE_URL/api/maps/$MAP_SLUG/templates" "$payload")
    status=$(parse_status "$raw")
    
    if [[ "$status" != "201" ]]; then
      echo "❌ Failed to create template: $status"
      echo "Response: $(parse_response "$raw")"
      return 1
    fi
    
    TEMPLATE_ID=$(jq -r '.data.id' <<<"$(parse_response "$raw")")
    if [[ -z "$TEMPLATE_ID" || "$TEMPLATE_ID" == "null" ]]; then
      echo "❌ Failed to extract template ID"
      return 1
    fi
    
    echo "Created template with ID: $TEMPLATE_ID"
    CREATED_HERE=1
  fi
  return 0
}

# Initialize template before tests
if ! create_or_load_template; then
  echo "❌ Template initialization failed, tests may not work correctly"
fi

test_filter_author() {
  local raw status
  raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_SLUG/templates?author_eve_id=2122019111")
  status=$(parse_status "$raw")
  
  if ! verify_http_code "$status" 200 "Filter by author"; then
    echo "❌ Failed to filter templates by author: $status"
    return 1
  fi
  
  if ! parse_response "$raw" | jq -e ".data[]|select(.id==\"$TEMPLATE_ID\")" >/dev/null; then
    echo "❌ Template not found in author-filtered results"
    return 1
  fi
  
  return 0
}

test_filter_category() {
  local raw status
  raw=$(make_request GET "$API_BASE_URL/api/maps/$MAP_SLUG/templates?category=test")
  status=$(parse_status "$raw")
  
  if ! verify_http_code "$status" 200 "Filter by category"; then
    echo "❌ Failed to filter templates by category: $status"
    return 1
  fi
  
  if ! parse_response "$raw" | jq -e ".data[]|select(.id==\"$TEMPLATE_ID\")" >/dev/null; then
    echo "❌ Template not found in category-filtered results"
    return 1
  fi
  
  return 0
}

test_first_apply() {
  local raw status
  raw=$(make_request POST "$API_BASE_URL/api/maps/$MAP_SLUG/templates/apply" "{\"template_id\":\"$TEMPLATE_ID\"}")
  status=$(parse_status "$raw")
  
  if [[ "$status" != "200" ]]; then
    echo "❌ First apply failed: $status"
    echo "Response: $(parse_response "$raw")"
    return 1
  fi
  
  return 0
}

test_second_apply() {
  local raw status
  raw=$(make_request POST "$API_BASE_URL/api/maps/$MAP_SLUG/templates/apply" "{\"template_id\":\"$TEMPLATE_ID\"}")
  status=$(parse_status "$raw")
  
  if [[ "$status" != "200" ]]; then
    echo "❌ Second apply failed: $status"
    echo "Response: $(parse_response "$raw")"
    return 1
  fi
  
  return 0
}

test_cleanup_operations() {
  if (( CREATED_HERE )); then
    local raw status
    raw=$(make_request DELETE "$API_BASE_URL/api/maps/$MAP_SLUG/templates/$TEMPLATE_ID")
    status=$(parse_status "$raw")
    
    if [[ ! "$status" =~ ^2[0-9]{2}$ ]]; then
      echo "❌ Failed to delete template: $status"
      return 1
    fi
    
    echo "✅ Template successfully deleted"
  else
    echo "✅ Skipping deletion for template we didn't create"
  fi
  
  return 0
}

run_test "Filter by author"    test_filter_author
run_test "Filter by category"  test_filter_category
run_test "First apply"         test_first_apply
run_test "Second apply"        test_second_apply
run_test "Cleanup if created"  test_cleanup_operations