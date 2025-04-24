#!/bin/bash
set -eu

# ─── Dependencies ─────────────────────────────────────────────────────────────
for cmd in curl jq; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "Error: '$cmd' is required" >&2
    exit 1
  fi
done


# ─── Load .env if present ─────────────────────────────────────────────────────
load_env_file() {
  echo "📄 Loading env file: $1"
  set -o allexport
  source "$1"
  set +o allexport
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
  load_env_file "$SCRIPT_DIR/.env"
fi

# ─── HTTP Request Helper ──────────────────────────────────────────────────────
make_request() {
  local method=$1 url=$2 data=${3:-}
  # Note the "\n" before %{http_code}
  local curl_cmd="curl -s -w \"\n%{http_code}\" -H \"Authorization: Bearer $API_TOKEN\""
  
  if [ "$method" != "GET" ]; then
    curl_cmd="$curl_cmd -X $method -H \"Content-Type: application/json\""
  fi
  
  if [ -n "$data" ]; then
    curl_cmd="$curl_cmd -d '$data'"
  fi
  
  # Use eval to execute the constructed command
  eval "$curl_cmd \"$url\""
}

# ─── Response Parsers ─────────────────────────────────────────────────────────
parse_response() {   # strips the final newline+status line
  local raw="$1"
  echo "${raw%$'\n'*}"
}

parse_status() {     # returns only the status code (last line)
  local raw="$1"
  echo "${raw##*$'\n'}"
}

# ─── Assertion Helper ─────────────────────────────────────────────────────────
verify_http_code() {
  local got=$1 want=$2 label=$3
  if [ "$got" -eq "$want" ]; then
    return 0
  else
    echo "🚫 $label: expected HTTP $want, got $got" >&2
    return 1
  fi
}

# ─── Test Runner & Summary ────────────────────────────────────────────────────
# Only initialize counters once to accumulate across multiple suite sources
if [ -z "${TOTAL_TESTS+x}" ]; then
  TOTAL_TESTS=0
  PASSED_TESTS=0
  FAILED_TESTS=0
  FAILED_LIST=""
fi

run_test() {
  local label=$1 fn=$2
  TOTAL_TESTS=$((TOTAL_TESTS+1))
  if "$fn"; then
    echo "✅ $label"
    PASSED_TESTS=$((PASSED_TESTS+1))
  else
    echo "❌ $label"
    FAILED_TESTS=$((FAILED_TESTS+1))
    FAILED_LIST="$FAILED_LIST $label"
  fi
}

# ─── Cleanup on Exit ──────────────────────────────────────────────────────────
CREATED_SYSTEM_IDS=""
CREATED_CONNECTION_IDS=""

cleanup_map_systems() {
  if [ -n "$CREATED_CONNECTION_IDS" ]; then
    local payload
    payload=$(echo "$CREATED_CONNECTION_IDS" | tr ' ' '\n' | jq -R . | jq -s '{connection_ids: .}')
    make_request DELETE "$API_BASE_URL/api/map/connections?slug=$MAP_SLUG" "$payload" > /dev/null
  fi
  if [ -n "$CREATED_SYSTEM_IDS" ]; then
    local payload
    payload=$(echo "$CREATED_SYSTEM_IDS" | tr ' ' '\n' | jq -R . | jq -s '{system_ids: .}')
    make_request DELETE "$API_BASE_URL/api/map/systems?slug=$MAP_SLUG" "$payload" > /dev/null
  fi
}
trap cleanup_map_systems EXIT
