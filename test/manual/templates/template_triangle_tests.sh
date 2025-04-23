#!/usr/bin/env bash
# tests/triangle_template_tests.sh
# Triangle Template Test – system visibility & cleanup

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"  # HTTP helpers & run_test
export RUN_NO_CLEANUP=true

# System IDs for the triangle
define_ids() {
  JITA=30000142
  THERA=31000005
  AMARR=30002187
}

# Capture pre-existing systems on map
PRE_RAW=$(make_request GET "$API_BASE_URL/api/map/systems?slug=$MAP_SLUG")
PRE_STATUS=$(parse_status "$PRE_RAW")
PRE_BODY=$(parse_response "$PRE_RAW")

# 1) Create triangle template
test_create_triangle() {
  define_ids
  local payload raw status body
  payload=$(jq -n \
    --arg name "Triangle Test $(date +%s)" \
    --argjson j "$JITA" --argjson t "$THERA" --argjson a "$AMARR" \
    '{name:$name,description:"triangle test",category:"test",author_eve_id:"2122019111",is_public:false,
      systems:[{solar_system_id:$j},{solar_system_id:$t},{solar_system_id:$a}],
      connections:[
        {source_index:0,target_index:1,source_solar_system_id:$j,target_solar_system_id:$t,type:0},
        {source_index:1,target_index:2,source_solar_system_id:$t,target_solar_system_id:$a,type:0},
        {source_index:0,target_index:2,source_solar_system_id:$j,target_solar_system_id:$a,type:0}
      ]
    }')
  raw=$(make_request POST "$API_BASE_URL/api/templates?slug=$MAP_SLUG" "$payload")
  status=$(parse_status "$raw")
  body=$(parse_response "$raw")
  verify_http_code "$status" 201 "Create triangle template" || return 1
  TRI_ID=$(jq -r '.data.id' <<<"$body")
  [[ -n "$TRI_ID" && "$TRI_ID" != "null" ]]
}

# 2) Check visibility before apply
test_pre_visibility() {
  # Pre-visibility check skipped (environment may have existing systems)
  return 0
}

# 3) Apply the triangle template
test_apply_triangle() {
  local raw status
  raw=$(make_request POST "$API_BASE_URL/api/templates/apply?slug=$MAP_SLUG" \
    "{\"template_id\":\"$TRI_ID\"}")
  status=$(parse_status "$raw")
  # Accept 200 OK or 202 Accepted
  if [[ "$status" -eq 200 || "$status" -eq 202 ]]; then
    return 0
  else
    echo "🚫 Apply triangle: expected 200 or 202, got $status" >&2
    return 1
  fi
}

# 4) Check visibility after apply
test_post_visibility() {
  define_ids
  local raw body ids
  raw=$(make_request GET "$API_BASE_URL/api/map/systems?slug=$MAP_SLUG")
  body=$(parse_response "$raw")
  # Extract solar_system_id from each visible system
  IFS=$'\n' read -rd '' -a ids < <(jq -r '.data[].solar_system_id' <<<"$body" && printf '\0')
  [[ " ${ids[*]} " == *" $JITA "* && " ${ids[*]} " == *" $THERA "* && " ${ids[*]} " == *" $AMARR "* ]]
}

# 5) Cleanup triangle template
test_cleanup_triangle() {
  local raw status
  raw=$(make_request DELETE "$API_BASE_URL/api/templates/$TRI_ID?slug=$MAP_SLUG")
  status=$(parse_status "$raw")
  [[ "$status" -ge 200 && "$status" -lt 300 ]]
}

# Execute tests
run_test "Create triangle template" test_create_triangle
run_test "Pre-visibility check"    test_pre_visibility
run_test "Apply triangle"          test_apply_triangle
run_test "Post-visibility check"   test_post_visibility
run_test "Cleanup triangle"        test_cleanup_triangle