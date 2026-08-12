#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="${1:-$ROOT/Tests/Fixtures/HID/headless-native-parity-trap.json}"
# shellcheck source=ruswitch_test_app.sh
source "$ROOT/scripts/ruswitch_test_app.sh"
ruswitch_validate_test_app "$ROOT"
APP="$RUSWITCH_APP"
HEADLESS="$ROOT/.build/headless-native-parity-headless.json"
NATIVE="$ROOT/.build/headless-native-parity-native.json"

cd "$ROOT"
swift run -c release RuSwitcherTypingSimulator \
    --input "$FIXTURE" \
    --output "$HEADLESS" >/dev/null

KEEP_HID_RESULTS=1 \
HID_RESULT_PATH="$NATIVE" \
HID_RESTART_SETTLE_SECONDS=1 \
RUSWITCH_APP="$APP" \
    bash "$ROOT/scripts/run_hid_batch_tests.sh" "$FIXTURE"

python3 - "$FIXTURE" "$HEADLESS" "$NATIVE" <<'PY'
import json
import sys

fixture_path, headless_path, native_path = sys.argv[1:]
fixture = json.load(open(fixture_path, encoding="utf-8"))
headless = json.load(open(headless_path, encoding="utf-8"))
native = json.load(open(native_path, encoding="utf-8"))

expected = fixture["expectedText"]
expected_transactions = fixture["expectedTransactions"]
checks = {
    "headlessTextMatches": headless["actualText"] == expected,
    "nativeTextMatches": native["text"] == expected,
    "headlessEqualsNative": headless["actualText"] == native["text"],
    "headlessTransactionsMatch": headless["transactionCount"] == expected_transactions,
    "nativePostedTransactionsMatch": native["postedAutomaticReplacementCount"] == expected_transactions,
    "nativeVerifiedTransactionsMatch": native["verifiedAutomaticReplacementCount"] == expected_transactions,
    "nativeCanPostEvents": native["postEventAccess"],
    "nativeHadNoExternalInput": native.get("unexpectedInputEventCount", 0) == 0,
    "nativeLayoutStayedSynchronized": not native["layoutMismatchStrokes"],
    "nativeBoundariesDelivered": not native["boundaryDeliveryTimeouts"],
}

summary = {
    "fixture": fixture["name"],
    "passed": all(checks.values()),
    "expectedText": expected,
    "headlessActualText": headless["actualText"],
    "nativeActualText": native["text"],
    "expectedTransactions": expected_transactions,
    "headlessTransactions": headless["transactionCount"],
    "nativePostedTransactions": native["postedAutomaticReplacementCount"],
    "nativeVerifiedTransactions": native["verifiedAutomaticReplacementCount"],
    "checks": checks,
}
print(json.dumps(summary, ensure_ascii=False, indent=2))
raise SystemExit(0 if summary["passed"] else 1)
PY
