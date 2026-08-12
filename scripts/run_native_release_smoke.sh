#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=ruswitch_test_app.sh
source "$ROOT/scripts/ruswitch_test_app.sh"
ruswitch_validate_test_app "$ROOT"

if [ "${RUSWITCH_ALLOW_FOCUS_STEALING:-0}" != "1" ]; then
    echo "BLOCKED: native smoke needs an isolated macOS session or explicit RUSWITCH_ALLOW_FOCUS_STEALING=1" >&2
    exit 77
fi

bash "$ROOT/scripts/run_headless_native_parity_test.sh" \
    "$ROOT/Tests/Fixtures/HID/headless-native-parity-trap.json"

bash "$ROOT/scripts/run_manual_toggle_cycle_test.sh" \
    manual-caret-word-toggle-cycle \
    manual-selection-toggle-cycle

echo "PASS: short native release smoke"
