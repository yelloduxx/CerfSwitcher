#!/usr/bin/env python3
"""List the wrong decisions of one event-stream run, one token per row.

Reads `input.jsonl` and `results.jsonl` from a run directory written by
`run_mixed_layout_event_stream_suite.py` and prints a TSV:

    class  typed  actual  expected  reason  earlier_switch  phrase

`class` is `wrong` (converted, but not into the expected text), `false-positive`
(converted a token that should stay) or `miss` (kept a token that should
convert). `earlier_switch` is `yes` when an earlier token of the same phrase was
converted: in the app the layout then switches, so the following keys arrive in
the other layout and a later miss of that phrase may not happen while typing.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path


def rows(run: Path):
    inputs = {}
    with (run / "input.jsonl").open(encoding="utf-8") as handle:
        for line in handle:
            record = json.loads(line)
            inputs[record["id"]] = record
    with (run / "results.jsonl").open(encoding="utf-8") as handle:
        for line in handle:
            result = json.loads(line)
            if result["passed"]:
                continue
            steps = inputs[result["fixture"]]["steps"]
            switched = False
            for step, trace in zip(steps, result["traces"]):
                converted = trace["verdict"] == "switchToConverted"
                actual = trace["resolvedText"] if converted else step["typed"]
                wanted = step["expectedResolved"]
                if actual != wanted:
                    if step["expected"] != "switch":
                        kind = "false-positive"
                    elif converted:
                        kind = "wrong"
                    else:
                        kind = "miss"
                    yield [kind, step["typed"], actual, wanted, trace["reason"],
                           "yes" if switched else "no", result["expectedText"]]
                switched = switched or converted


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run", type=Path, help="run directory with input.jsonl and results.jsonl")
    args = parser.parse_args()
    order = {"wrong": 0, "false-positive": 1, "miss": 2}
    found = sorted(rows(args.run), key=lambda row: (order[row[0]], row[4], row[3]))
    writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    writer.writerow(["class", "typed", "actual", "expected", "reason", "earlier_switch", "phrase"])
    writer.writerows(found)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
