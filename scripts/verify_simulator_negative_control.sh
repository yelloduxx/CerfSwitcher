#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="${TMPDIR:-/tmp}/ruswitcher-negative-control.json"
CONTROL_ID="intentional-negative-control"

cd "$ROOT"
rm -f "$REPORT"
if swift run -c release RuSwitcherSimulator \
    --phrase-input Tests/Fixtures/Simulator/intentional-phrase-failure.jsonl \
    --limit 1 \
    --output "$REPORT" >/dev/null; then
    echo "FAIL: simulator accepted an intentionally wrong expectation"
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
