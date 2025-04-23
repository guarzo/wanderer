# tests/map_tests.sh
#!/usr/bin/env bash
# ─── Map endpoint tests ───────────────────────────────────────────────────────
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

test_upsert_systems() {
  local payload raw status ids
  payload=$(jq -n \
    --argjson s1 30001660 --argjson s2 30002718 \
    '{systems:[
       {solar_system_id:$s1,position_x:111,position_y:222},
       {solar_system_id:$s2,position_x:333,position_y:444}
    ]}')
  raw=$(make_request PATCH "$API_BASE_URL/api/map/systems?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw")
  if [[ "$status" =~ ^2[0-9]{2}$ ]]; then
    ids=$(parse_response "$raw" | jq -r '.data.created[]?.id, .data.updated[]?.id')
    while read -r id; do CREATED_SYSTEM_IDS+=("$id"); done <<<"$ids"
    return 0
  else
    return 1
  fi
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

test_update_system() {
  if [ ${#CREATED_SYSTEM_IDS[@]} -eq 0 ]; then return 1; fi
  local id="${CREATED_SYSTEM_IDS[0]}" payload raw status solar x y
  payload=$(jq -n --arg id "$id" '{systems:[{id:$id,position_x:123,position_y:456}]}')
  raw=$(make_request PATCH "$API_BASE_URL/api/map/systems?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw"); [[ "$status" =~ ^2[0-9]{2}$ ]] || return 1
  solar=$(parse_response "$raw" | jq -r '.data.updated[0].solar_system_id')
  raw=$(make_request GET "$API_BASE_URL/api/map/system?id=$solar&slug=$MAP_SLUG")
  status=$(parse_status "$raw"); [[ "$status" =~ ^2[0-9]{2}$ ]] || return 1
  x=$(parse_response "$raw" | jq -r '.data.position_x')
  y=$(parse_response "$raw" | jq -r '.data.position_y')
  [[ "$x" == "123" && "$y" == "456" ]]
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

test_delete_connection() {
  if [ ${#CREATED_CONNECTION_IDS[@]} -eq 0 ]; then return 1; fi
  local id="${CREATED_CONNECTION_IDS[0]}" payload raw status
  payload=$(jq -n --arg id "$id" '{connection_ids:[$id]}')
  raw=$(make_request DELETE "$API_BASE_URL/api/map/connections?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw")
  [[ "$status" =~ ^2[0-9]{2}$ ]]
}

test_delete_systems() {
  if [ ${#CREATED_SYSTEM_IDS[@]} -eq 0 ]; then return 0; fi
  local payload raw status
  payload=$(printf '%s\n' "${CREATED_SYSTEM_IDS[@]}" | jq -R . | jq -s '{system_ids: .}')
  raw=$(make_request DELETE "$API_BASE_URL/api/map/systems?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw")
  [[ "$status" =~ ^2[0-9]{2}$ ]]
}

# ─── Execute Tests ────────────────────────────────────────────────────────────
run_test "Direct API access"        test_direct_api_access
run_test "Missing params (4xx)"     test_missing_params
run_test "Invalid auth (401/403)"   test_invalid_auth
run_test "Invalid slug on GET"      test_invalid_slug
run_test "Upsert systems"           test_upsert_systems
run_test "Show systems"             test_show_systems
run_test "Nonexistent system (404)" test_nonexistent_system
run_test "Update system properties" test_update_system
run_test "Upsert connections"       test_upsert_connections
run_test "Verify connections"       test_verify_connections
run_test "Delete connection"        test_delete_connection
run_test "Delete systems"           test_delete_systems
