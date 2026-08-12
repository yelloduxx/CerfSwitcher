#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=ruswitch_test_app.sh
source "$ROOT/scripts/ruswitch_test_app.sh"
ruswitch_validate_test_app "$ROOT"

APP="$RUSWITCH_APP"
BIN="$RUSWITCH_APP_EXEC"
DEFAULT_FIXTURE="$ROOT/Tests/Fixtures/HID/mixed-layout-corpus-batch.json"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ruswitch-hid-batch.XXXXXX")"
WAS_RUNNING=0

if pgrep -f "$BIN" >/dev/null; then WAS_RUNNING=1; fi

cleanup() {
    while read -r pid; do
        test -z "$pid" || kill "$pid" 2>/dev/null || true
    done < <(pgrep -f "$BIN" || true)
    rm -rf "$WORK_DIR"
    if [ "$WAS_RUNNING" -eq 1 ]; then
        open "$APP" >/dev/null
        for _ in {1..30}; do
            pgrep -f "$BIN" >/dev/null && break
            sleep 0.1
        done
    fi
}
trap cleanup EXIT

if [ "$#" -eq 0 ]; then
    set -- "$DEFAULT_FIXTURE"
fi

if [ -n "${HID_RESULT_PATH:-}" ] && [ "$#" -ne 1 ]; then
    echo "HID_RESULT_PATH requires exactly one fixture"
    exit 64
fi

failed=0
index=0
for fixture_argument in "$@"; do
    fixture_source="$(cd "$(dirname "$fixture_argument")" && pwd)/$(basename "$fixture_argument")"
    fixture="$WORK_DIR/fixture-$index.json"
    cp "$fixture_source" "$fixture"

    while read -r pid; do
        test -z "$pid" || kill "$pid" 2>/dev/null || true
    done < <(pgrep -f "$BIN" || true)
    for _ in {1..50}; do
        pgrep -f "$BIN" >/dev/null || break
        sleep 0.1
    done
    sleep "${HID_RESTART_SETTLE_SECONDS:-1}"

    fixture_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["name"])' "$fixture_source")"
    typed_length="$(python3 -c 'import json,sys; print(sum(len(x["text"]) for x in json.load(open(sys.argv[1], encoding="utf-8"))["phases"]))' "$fixture_source")"
    result="$WORK_DIR/result-$index.json"
    result_destination="${HID_RESULT_PATH:-$ROOT/.build/ruswitch-hid-batch-$$-$fixture_name.json}"
    mkdir -p "$(dirname "$result_destination")"

    probe_pattern="$BIN --hid-probe-file $fixture"
    launched=0
    for _ in {1..5}; do
        open "$APP" --args --hid-probe-file "$fixture" --result "$result"
        sleep 1
        if pgrep -f "$probe_pattern" >/dev/null; then
            launched=1
            break
        fi
    done
    if [ "$launched" -ne 1 ]; then
        echo "FAIL $fixture_name: LaunchServices returned no probe PID"
        failed=1
        index=$((index + 1))
        continue
    fi

    timeout_ticks=$((typed_length / 4 + 600))
    for ((tick=0; tick<timeout_ticks; tick++)); do
        test -f "$result" && break
        sleep 0.1
    done

    if ! test -f "$result"; then
        echo "FAIL $fixture_name: no result after $typed_length input characters"
        failed=1
        index=$((index + 1))
        continue
    fi
    cp "$result" "$result_destination"

    if python3 - "$fixture_source" "$result_destination" <<'PY'
import json
import sys

fixture_path, result_path = sys.argv[1:]
with open(fixture_path, encoding="utf-8") as handle:
    fixture = json.load(handle)
with open(result_path, encoding="utf-8") as handle:
    result = json.load(handle)

expected = fixture["expectedText"]
actual = result["text"]
typed_length = sum(len(phase["text"]) for phase in fixture["phases"])
okay = (
    result["postEventAccess"]
    and actual == expected
    and result.get("unexpectedInputEventCount", 0) == 0
    and not result.get("boundaryDeliveryTimeouts", [])
    and (
        fixture.get("expectedTransactions") is None
        or (
            result.get("postedAutomaticReplacementCount") == fixture["expectedTransactions"]
            and result.get("verifiedAutomaticReplacementCount") == fixture["expectedTransactions"]
        )
    )
)
print(
    f"{'PASS' if okay else 'FAIL'} {fixture['name']}: "
    f"{len(fixture['phases'])} phases, {typed_length} input chars, "
    f"sources={','.join(fixture.get('sourceIDs', []))}"
)
if okay:
    if len(actual) <= 1_000:
        print(actual)
    else:
        print(f"exact text matched ({len(actual)} characters)")
        print(f"first 240: {actual[:240]!r}")
        print(f"last 240:  {actual[-240:]!r}")
else:
    mismatch = next(
        (i for i, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]),
        min(len(actual), len(expected)),
    )
    print(f"first mismatch at character {mismatch}")
    print(f"layout mismatch strokes: {result.get('layoutMismatchStrokes', [])}")
    print(f"unexpected input events: {result.get('unexpectedInputEventCount', 0)}")
    print(f"boundary delivery timeouts: {result.get('boundaryDeliveryTimeouts', [])}")
    print(f"expected transactions: {fixture.get('expectedTransactions')}")
    print(f"posted transactions: {result.get('postedAutomaticReplacementCount')}")
    print(f"verified transactions: {result.get('verifiedAutomaticReplacementCount')}")
    print(f"expected: {expected!r}")
    print(f"actual:   {actual!r}")
raise SystemExit(0 if okay else 1)
PY
    then
        if [ "${KEEP_HID_RESULTS:-0}" = "1" ] || [ -n "${HID_RESULT_PATH:-}" ]; then
            echo "diagnostic result retained: $result_destination"
        else
            rm -f "$result_destination"
        fi
    else
        failed=1
        echo "diagnostic result retained: $result_destination"
    fi
    index=$((index + 1))
done

exit "$failed"
