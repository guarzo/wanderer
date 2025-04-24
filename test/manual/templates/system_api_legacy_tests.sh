# tests/map_tests_legacy.sh
#!/usr/bin/env bash
# ─── Legacy Map endpoint tests ───────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Track created IDs for cleanup
CREATED_SYSTEM_IDS=()
CREATED_CONNECTION_IDS=()

test_direct_api_access() {
  local raw status
  raw=$(make_request GET "$API_BASE_URL/api/map/systems?slug=$MAP_SLUG")
  status=$(parse_status "$raw")
  [[ "$status" =~ ^2[0-9]{2}$ ]]
}

test_missing_params() {
  local raw status
  raw=$(make_request GET "$API_BASE_URL/api/map/systems")
  status=$(parse_status "$raw")
  [[ "$status" =~ ^4[0-9]{2}$ ]]
}

test_invalid_auth() {
  local old="$API_TOKEN" raw status
  API_TOKEN="invalid-token"
  raw=$(make_request GET "$API_BASE_URL/api/map/systems?slug=$MAP_SLUG")
  status=$(parse_status "$raw")
  API_TOKEN="$old"
  [[ "$status" == "401" || "$status" == "403" ]]
}

test_invalid_slug() {
  local raw status
  raw=$(make_request GET "$API_BASE_URL/api/map/systems?slug=nonexistent")
  status=$(parse_status "$raw")
  [[ "$status" =~ ^4[0-9]{2}$ ]]
}

test_show_systems() {
  for sid in 30001660 30002718; do
    local raw status
    raw=$(make_request GET "$API_BASE_URL/api/map/system?id=$sid&slug=$MAP_SLUG")
    status=$(parse_status "$raw")
    [[ "$status" =~ ^2[0-9]{2}$ ]] || return 1
  done
}

test_nonexistent_system() {
  local raw status
  raw=$(make_request GET "$API_BASE_URL/api/map/system?id=99999999&slug=$MAP_SLUG")
  status=$(parse_status "$raw")
  [[ "$status" == "404" ]]
}

test_upsert_connections() {
  local payload raw status ids
  payload=$(jq -n \
    --argjson s1 30001660 --argjson s2 30002718 \
    '{connections:[
       {solar_system_source:$s1,solar_system_target:$s2,
        type:1,mass_status:0,time_status:0,ship_size_type:0}
    ]}')
  raw=$(make_request PATCH "$API_BASE_URL/api/map/connections?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw")
  if [[ "$status" =~ ^2[0-9]{2}$ ]]; then
    ids=$(parse_response "$raw" | jq -r '.data.created[]?.id, .data.updated[]?.id')
    while read -r id; do CREATED_CONNECTION_IDS+=("$id"); done <<<"$ids"
    return 0
  else
    return 1
  fi
}

test_verify_connections() {
  local raw status
  raw=$(make_request GET "$API_BASE_URL/api/map/connections?slug=$MAP_SLUG")
  status=$(parse_status "$raw")
  [[ "$status" =~ ^2[0-9]{2}$ ]]
}

# ─── Execute Tests ────────────────────────────────────────────────────────────
run_test "Direct API access"        test_direct_api_access
run_test "Missing params (4xx)"     test_missing_params
run_test "Invalid auth (401/403)"   test_invalid_auth
run_test "Invalid slug on GET"      test_invalid_slug
run_test "Show systems"             test_show_systems
run_test "Nonexistent system (404)" test_nonexistent_system
run_test "Verify connections"       test_verify_connections