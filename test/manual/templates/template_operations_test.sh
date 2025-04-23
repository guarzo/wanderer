#!/usr/bin/env bash
# Template Operations Tests - Filtering & Re-apply

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
export RUN_NO_CLEANUP=true

if [[ -f /tmp/basic_template_id.txt ]]; then
  TEMPLATE_ID=$(< /tmp/basic_template_id.txt)
  CREATED_HERE=0
else
  raw='' payload=''
  payload='{"name":"OpTest","description":"d","category":"test","author_eve_id":"2122019111","is_public":false,"systems":[],"connections":[]}'
  raw=$(make_request POST "$API_BASE_URL/api/templates?slug=$MAP_SLUG" "$payload")
  TEMPLATE_ID=$(jq -r '.data.id' <<<"$(parse_response "$raw")")
  CREATED_HERE=1
fi

test_filter_author() {
  local raw status
  raw=$(make_request GET "$API_BASE_URL/api/templates?slug=$MAP_SLUG&author_eve_id=2122019111")
  status=$(parse_status "$raw")
  verify_http_code "$status" 200 "Filter by author" || return 1
  parse_response "$raw" | jq -e ".data[]|select(.id==\"$TEMPLATE_ID\")" >/dev/null
}

test_filter_category() {
  local raw status
  raw=$(make_request GET "$API_BASE_URL/api/templates?slug=$MAP_SLUG&category=test")
  status=$(parse_status "$raw")
  verify_http_code "$status" 200 "Filter by category" || return 1
  parse_response "$raw" | jq -e ".data[]|select(.id==\"$TEMPLATE_ID\")" >/dev/null
}

test_first_apply() {
  local raw status
  raw=$(make_request POST "$API_BASE_URL/api/templates/apply?slug=$MAP_SLUG" \
        "{\"template_id\":\"$TEMPLATE_ID\"}")
  status=$(parse_status "$raw")
  verify_http_code "$status" 200 "Apply template (1st)"
}

test_second_apply() {
  [[ $(make_request POST "$API_BASE_URL/api/templates/apply?slug=$MAP_SLUG" "{\"template_id\":\"$TEMPLATE_ID\"}") == 200 ]]
}

test_cleanup_operations() {
  if (( CREATED_HERE )); then
    [[ $(make_request DELETE "$API_BASE_URL/api/templates/$TEMPLATE_ID?slug=$MAP_SLUG") =~ ^2[0-9]{2}$ ]]
  else
    return 0
  fi
}

run_test "Filter by author"    test_filter_author
run_test "Filter by category"  test_filter_category
run_test "First apply"         test_first_apply
run_test "Second apply"        test_second_apply
run_test "Cleanup if created"  test_cleanup_operations