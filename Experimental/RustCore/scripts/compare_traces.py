#!/usr/bin/env python3
"""Compare Rust rscore traces with Swift RuSwitcherSimulator phrase results.

Prints counts only. `--show-samples N` prints mismatching tokens and must be
used only with public corpora (FLORES), never with private user text.
"""

from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path


def load(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("swift", type=Path, help="Swift --phrase-results JSONL")
    parser.add_argument("rust", type=Path, help="rscore trace JSONL")
    parser.add_argument("--swift-detail", type=Path, help="SwiftDecoderBench trace JSONL (same schema as rust)")
    parser.add_argument("--show-samples", type=int, default=0)
    args = parser.parse_args()

    swift = load(args.swift)
    rust = load(args.rust)
    detail = load(args.swift_detail) if args.swift_detail else None
    if len(swift) != len(rust):
        raise SystemExit(f"phrase count differs: swift={len(swift)} rust={len(rust)}")

    total = equal = 0
    kinds: collections.Counter[str] = collections.Counter()
    samples = []
    for index, (s_phrase, r_phrase) in enumerate(zip(swift, rust)):
        if len(s_phrase["steps"]) != len(r_phrase["steps"]):
            raise SystemExit(f"step count differs in phrase {index + 1}")
        for step_index, (s, r) in enumerate(zip(s_phrase["steps"], r_phrase["steps"])):
            total += 1
            same_verdict = s["actualVerdict"] == r["verdict"]
            same_text = s["actualResolved"] == r["resolved"]
            if same_verdict and same_text:
                equal += 1
                continue
            key = f"swift={s['actualVerdict']} rust={r['verdict']}" + ("" if same_text else " text-differs")
            kinds[key] += 1
            if len(samples) < args.show_samples:
                sample = {
                    "phrase": index + 1,
                    "step": step_index + 1,
                    "typed": s["typed"],
                    "swift": [s["actualVerdict"], s["actualResolved"]],
                    "rust": [r["verdict"], r["resolved"], r["reason"], r["evidence"]],
                }
                if detail:
                    d = detail[index]["steps"][step_index]
                    sample["swiftDetail"] = [d["reason"], d["evidence"], d["literalScore"], d["convertedScore"], d["threshold"]]
                    sample["rustScores"] = [r["literalScore"], r["convertedScore"], r["threshold"]]
                samples.append(sample)

    score_diffs = 0
    if detail:
        for d_phrase, r_phrase in zip(detail, rust):
            for d, r in zip(d_phrase["steps"], r_phrase["steps"]):
                if any(d[k] != r[k] for k in ("literalScore", "convertedScore", "threshold", "reason", "evidence",
                                         "prefix", "suffix", "kind")):
                    score_diffs += 1

    print(json.dumps({
        "tokens": total,
        "identical": equal,
        "parity": equal / total if total else 1.0,
        "mismatchKinds": dict(kinds.most_common()),
        **({"scoreOrReasonDiffs": score_diffs} if detail else {}),
    }, ensure_ascii=False, indent=2))
    for sample in samples:
        print(json.dumps(sample, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
