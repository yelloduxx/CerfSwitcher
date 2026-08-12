#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=ruswitch_test_app.sh
source "$ROOT/scripts/ruswitch_test_app.sh"
ruswitch_validate_test_app "$ROOT"
APP="$RUSWITCH_APP"
APP_EXECUTABLE="$RUSWITCH_APP_EXECUTABLE"
APP_EXEC="$RUSWITCH_APP_EXEC"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ruswitch-toggle-cycle.XXXXXX")"
WAS_RUNNING=0

test -x "$APP_EXEC"
if pgrep -x "$APP_EXECUTABLE" >/dev/null; then WAS_RUNNING=1; fi

cleanup() {
    pkill -x "$APP_EXECUTABLE" 2>/dev/null || true
    rm -rf "$WORK_DIR"
    if [ "$WAS_RUNNING" -eq 1 ]; then open "$APP"; fi
}
trap cleanup EXIT

run_scenario() {
    local name="$1"
    local force_fallback="${2:-0}"
    local result="$WORK_DIR/$name.json"
    pkill -x "$APP_EXECUTABLE" 2>/dev/null || true
    for _ in {1..30}; do
        pgrep -x "$APP_EXECUTABLE" >/dev/null || break
        sleep 0.1
    done
    shift 2
    if [ "$force_fallback" -eq 1 ]; then
        open -n "$APP" --args --hid-probe "$name" --result "$result" \
            --force-synthetic-input-fallback
    elif [ "$#" -gt 0 ]; then
        open -n "$APP" --args --hid-probe "$name" --result "$result" "$@"
    else
        open -n "$APP" --args --hid-probe "$name" --result "$result"
    fi
    python3 - "$result" <<'PY'
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 20
while (not os.path.exists(path) or os.path.getsize(path) == 0) and time.monotonic() < deadline:
    time.sleep(0.05)
if not os.path.exists(path) or os.path.getsize(path) == 0:
    raise SystemExit(f"FAIL: no result for {os.path.basename(path)}")
PY
}

if [ "$#" -gt 0 ]; then
    scenarios=("$@")
else
    scenarios=(
        manual-russian-word-toggle-cycle
        manual-caret-word-toggle-cycle
        manual-selection-toggle-cycle
        manual-auto-word-toggle-cycle
        manual-ax-unavailable-toggle-cycle
        manual-ax-unavailable-current-word-toggle-cycle
        manual-ax-unavailable-long-word-toggle-cycle
    )
fi

for scenario in "${scenarios[@]}"; do
    case "$scenario" in
        manual-russian-word-toggle-cycle)
            run_scenario "$scenario" 1
            ;;
        manual-ax-unavailable-toggle-cycle|manual-ax-unavailable-current-word-toggle-cycle|manual-ax-unavailable-long-word-toggle-cycle)
            run_scenario "$scenario" 0 \
                --force-ax-unavailable-fallback --force-global-event-stream
            ;;
        manual-caret-word-toggle-cycle|manual-selection-toggle-cycle|manual-auto-word-toggle-cycle)
            run_scenario "$scenario" 0
            ;;
        *)
            echo "Unknown manual toggle scenario: $scenario" >&2
            exit 64
            ;;
    esac
done

python3 - "$WORK_DIR" "${scenarios[@]}" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
selected = sys.argv[2:]
expected = {
    "manual-russian-word-toggle-cycle": [";jgf", "жопа"],
    "manual-caret-word-toggle-cycle": ["руку  ", "here  "],
    "manual-selection-toggle-cycle": ["руку", "here", "руку", "here"],
    "manual-auto-word-toggle-cycle": ["ckj;yj ", "сложно "],
    "manual-ax-unavailable-toggle-cycle": ["руку ", "here ", "руку ", "here "],
    "manual-ax-unavailable-current-word-toggle-cycle": ["руку", "here", "руку", "here"],
    "manual-ax-unavailable-long-word-toggle-cycle": ["приветствую", "ghbdtncnde."],
}

for name in selected:
    trace = expected[name]
    result = json.loads((root / f"{name}.json").read_text(encoding="utf-8"))
    passed = (
        result.get("postEventAccess") is True
        and result.get("manualTrace") == trace
        and result.get("text") == trace[-1]
        and result.get("pasteboardChangeCountDelta") == 0
        and result.get("unexpectedInputEventCount") == 0
        and not result.get("layoutMismatchStrokes")
        and not result.get("boundaryDeliveryTimeouts")
    )
    if name in {
        "manual-ax-unavailable-toggle-cycle",
        "manual-ax-unavailable-current-word-toggle-cycle",
        "manual-ax-unavailable-long-word-toggle-cycle",
    }:
        # The AX-blind path must select the exact suffix (123 = Left) and type
        # over it. A destructive Backspace is a regression even if final text
        # happens to look correct in NSTextView.
        backspace_events = [e for e in result.get("syntheticKeyTrace", []) if e.startswith("51:")]
        selection_events = [e for e in result.get("syntheticKeyTrace", []) if e.startswith("123:")]
        passed = passed and not backspace_events and len(selection_events) >= 4 * len(trace)
    configured_layouts = set(result.get("configuredLayoutIDs", []))
    observed_layouts = set(result.get("observedLayoutIDs", []))
    passed = passed and len(configured_layouts) == 2 and observed_layouts == configured_layouts
    if name == "manual-auto-word-toggle-cycle":
        passed = passed and result.get("postedAutomaticReplacementCount") == 1
    print(f"{'PASS' if passed else 'FAIL'} {name}: {result.get('manualTrace')!r}")
    if not passed:
        raise SystemExit(1)
PY
