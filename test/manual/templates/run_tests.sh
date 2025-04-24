#!/usr/bin/env bash
# tests/run_tests.sh
set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

echo -e "\n🧪 Running all test suites…"
for suite in "$SCRIPT_DIR"/*_tests.sh; do
  [[ "$(basename "$suite")" == "run_tests.sh" ]] && continue
  echo -e "\n📄 $(basename "$suite")"
  source "$suite"
done

echo -e "\n📊 SUMMARY: $PASSED_TESTS/$TOTAL_TESTS passed."
if [ "$FAILED_TESTS" -gt 0 ]; then
  echo "⚠️ Failures:"
  for lbl in "${FAILED_LIST[@]}"; do echo "  - $lbl"; done
  exit 1
else
  echo "🎉 All tests passed!"
  exit 0
fi
