#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTROL_ID="intentional-negative-control"
EXPECTED_FAILURE_STATUS=1

if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq is required to read the simulator report"
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ruswitcher-negative-control.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
REPORT="$WORK/report.json"

cd "$ROOT"
STATUS=0
swift run -c release RuSwitcherSimulator \
    --phrase-input Tests/Fixtures/Simulator/intentional-phrase-failure.jsonl \
    --limit 1 \
    --output "$REPORT" >/dev/null || STATUS=$?

if [ "$STATUS" -eq 0 ]; then
    echo "FAIL: simulator accepted an intentionally wrong expectation"
    exit 1
fi

if [ "$STATUS" -ne "$EXPECTED_FAILURE_STATUS" ]; then
    echo "FAIL: simulator exited with status $STATUS, expected $EXPECTED_FAILURE_STATUS"
    exit 1
fi

if ! jq -e . "$REPORT" >/dev/null 2>&1; then
    echo "FAIL: simulator failed without writing a readable report"
    exit 1
fi

if ! jq -e --arg id "$CONTROL_ID" \
    '.failed == 1 and (.failures | length) == 0 and [.phraseFailures[]?.id] == [$id]' \
    "$REPORT" >/dev/null; then
    OTHER_IDS="$(jq -r --arg id "$CONTROL_ID" \
        '[.failures[]?.id, .phraseFailures[]?.id | select(. != $id)] | join(" ")' "$REPORT")"
    echo "FAIL: expected exactly one failure, $CONTROL_ID; other failing ids: ${OTHER_IDS:-none}"
    exit 1
fi

echo "PASS: simulator rejected the intentionally wrong phrase"
