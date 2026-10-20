#!/bin/bash
# Runs every automated test: the engine suite with SwiftPM, then the full Xcode scheme
# (engine tests + hosted app tests). DerivedData is kept outside ~/Documents so the Xcode
# test runner is not blocked by macOS privacy protection when the repo lives there.
#
# A run also fails, even when the test runner exits successfully, if
#   - a test run executed no tests, or reported no test summary at all, or
#   - SQLite logged API misuse ("API call with invalid database connection pointer",
#     "misuse at line …") — in the runner output or in the unified log of the test processes.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/PureMac-cli}"
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/PureMacTestLogs.XXXXXX")"
trap 'rm -rf "$LOGS"' EXIT
MISUSE='API call with (invalid|unopened|NULL) database connection pointer|misuse at line [0-9]+'

fail() { echo "error: $*" >&2; exit 1; }

# Every Swift Testing summary must report at least one test. (The suites use Swift Testing only;
# SwiftPM's "Executed 0 tests" line is its empty XCTest pass and is not checked.)
check_summaries() {
  local log="$1" name="$2"
  local summaries
  summaries="$(grep -Eo 'Test run with [0-9]+ tests?' "$log" || true)"
  [[ -n "$summaries" ]] || fail "$name reported no test summary"
  if grep -Eq 'Test run with 0 tests' "$log"; then fail "$name ran no tests"; fi
  echo "    $(echo "$summaries" | tr '\n' ';' | sed 's/;$//')"
}

check_output_for_misuse() {
  local log="$1" name="$2"
  if grep -Eq "$MISUSE" "$log"; then
    grep -En "$MISUSE" "$log" | head -5 >&2
    fail "SQLite reported API misuse during $name"
  fi
}

# SwiftPM's test helper sends SQLite's log to the unified log only, not to its output.
check_unified_log_for_misuse() {
  local since="$1" name="$2"
  [[ -x /usr/bin/log ]] || { echo "    (unified log not available; skipped the SQLite misuse check)"; return; }
  local hits
  hits="$(/usr/bin/log show --start "$since" --style compact \
    --predicate 'subsystem == "com.apple.libsqlite3" AND (process == "swiftpm-testing-helper" OR process == "xctest" OR process == "PureMac") AND (eventMessage CONTAINS "misuse" OR eventMessage CONTAINS "database connection pointer")' \
    2>/dev/null | grep -E "$MISUSE" || true)"
  if [[ -n "$hits" ]]; then
    echo "$hits" | head -5 >&2
    fail "SQLite reported API misuse during $name (unified log)"
  fi
}

echo "==> swift test (PureMacKit)"
since="$(date '+%Y-%m-%d %H:%M:%S')"
swift test --package-path Packages/PureMacKit 2>&1 | tee "$LOGS/swiftpm.log"
check_summaries "$LOGS/swiftpm.log" "swift test"
check_output_for_misuse "$LOGS/swiftpm.log" "swift test"
check_unified_log_for_misuse "$since" "swift test"

echo "==> xcodebuild test (scheme PureMac)"
since="$(date '+%Y-%m-%d %H:%M:%S')"
xcodebuild -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$LOGS/xcodebuild.log"
grep -q '\*\* TEST SUCCEEDED \*\*' "$LOGS/xcodebuild.log" || fail "xcodebuild did not report TEST SUCCEEDED"
check_summaries "$LOGS/xcodebuild.log" "xcodebuild test"
check_output_for_misuse "$LOGS/xcodebuild.log" "xcodebuild test"
check_unified_log_for_misuse "$since" "xcodebuild test"

echo "==> All tests passed; no SQLite misuse was logged."
