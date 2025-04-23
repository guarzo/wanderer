#!/usr/bin/env bash
# Template Error Tests - Validation and Error Responses

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"    # HTTP helpers & run_test
export RUN_NO_CLEANUP=true

TEMP_ID=""

# 1) Missing required name → HTTP 400
test_missing_name() {
  local raw status
  raw=$(make_request POST "$API_BASE_URL/api/templates?slug=$MAP_SLUG" \
    '{"description":"d","category":"c"}')
  status=$(parse_status "$raw")
  [[ "$status" -eq 400 ]]
}

# 2) Malformed JSON → HTTP 400
test_malformed_json() {
  local raw status
  raw=$(printf '{invalid' | curl -s -w "\n%{http_code}" \
    -X POST "$API_BASE_URL/api/templates?slug=$MAP_SLUG" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" -d @-)
  status=$(echo "$raw" | tail -n1)
  [[ "$status" -eq 400 ]]
}

# 3) Invalid author_eve_id → HTTP 400
test_invalid_author_eve_id() {
  local raw status payload
  payload='{"name":"n","description":"d","category":"c","author_eve_id":"NaN","is_public":false,"systems":[],"connections":[]}'
  raw=$(make_request POST "$API_BASE_URL/api/templates?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw")
  [[ "$status" -eq 400 ]]
}

# 4) Create a valid temporary template → HTTP 201
test_create_temp_template() {
  local payload raw status body
  payload='{
    "name":"Temp Error Test",
    "description":"desc",
    "category":"test",
    "author_eve_id":"2122019111",
    "is_public":false,
    "systems":[{"solar_system_id":30001660,"name":"Adirain"}],
    "connections":[]
  }'
  raw=$(make_request POST "$API_BASE_URL/api/templates?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw"); body=$(parse_response "$raw")
  verify_http_code "$status" 201 "Create temp template" || return 1
  TEMP_ID=$(jq -r '.data.id' <<<"$body")
  [[ -n "$TEMP_ID" && "$TEMP_ID" != "null" ]]
}

# 5) Delete the temp template (1st) → HTTP 2xx
test_delete_temp_first() {
  local raw status
  raw=$(make_request DELETE "$API_BASE_URL/api/templates/$TEMP_ID?slug=$MAP_SLUG")
  status=$(parse_status "$raw")
  [[ "$status" -ge 200 && "$status" -lt 300 ]]
}

# 6) Delete again (2nd) → HTTP 2xx or 404
test_delete_temp_second() {
  local raw status
  raw=$(make_request DELETE "$API_BASE_URL/api/templates/$TEMP_ID?slug=$MAP_SLUG")
  status=$(parse_status "$raw")
  # Accept either success (2xx) or any 4xx error
  if [[ "$status" -ge 200 && "$status" -lt 300 ]] || [[ "$status" -ge 400 && "$status" -lt 500 ]]; then
    return 0
  else
    return 1
  fi
}

# 7) Delete again (3rd) → HTTP 2xx or 404
test_delete_temp_third() {
  test_delete_temp_second
}

# 8) Apply non-existent template → HTTP 400 or 404
test_apply_nonexistent() {
  local id raw status
  id="does_not_exist_$(date +%s)"
  raw=$(make_request POST "$API_BASE_URL/api/templates/apply?slug=$MAP_SLUG" \
    "{\"template_id\":\"$id\"}")
  status=$(parse_status "$raw")
  [[ "$status" -eq 400 || "$status" -eq 404 ]]
}

# Execute tests
run_test "400 missing name"             test_missing_name
run_test "400 malformed JSON"           test_malformed_json
run_test "400 invalid author_eve_id"    test_invalid_author_eve_id
run_test "Create & capture temp"        test_create_temp_template
run_test "Delete temp (1st)"            test_delete_temp_first
run_test "Delete temp (2nd)"            test_delete_temp_second
run_test "Delete temp (3rd)"            test_delete_temp_third
run_test "Error apply nonexistent"      test_apply_nonexistent