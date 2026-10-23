#!/usr/bin/env bash
# Run the handwritten adversarial phrases through the app's decision path and
# write every wrong decision to one TSV (default: .build/adversarial-findings.tsv).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$root/.build/adversarial-findings.tsv}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf 'set\tclass\ttyped\tactual\texpected\treason\tearlier_switch\tphrase\n' > "$work/findings.tsv"
for phrases in "$root"/Tests/Fixtures/Adversarial/handwritten-*.txt; do
  name="$(basename "$phrases" .txt)"
  python3 "$root/scripts/make_text_mixed_tsv.py" "$work/$name.tsv" "$phrases" >/dev/null
  python3 "$root/scripts/run_mixed_layout_event_stream_suite.py" "$work/$name.tsv" \
    --jobs 8 --max-safe-misses 1000000 --report "$work/$name-report.json" \
    --results "$work/$name-results.jsonl" --audit "$work/$name-audit.json" >/dev/null || true
  run="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifacts"]["results"].rsplit("/", 1)[0])' "$work/$name-audit.json")"
  python3 "$root/scripts/list_layout_failures.py" "$run" | tail -n +2 | sed "s/^/$name\t/" >> "$work/findings.tsv"
done
mkdir -p "$(dirname "$output")"
cp "$work/findings.tsv" "$output"
cut -f2 "$output" | tail -n +2 | sort | uniq -c
echo "findings: $output"
