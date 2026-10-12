#!/usr/bin/env python3
"""Fit the decoder's calibrated score for words the rules leave undecided.

Input: `results.jsonl` from `run_mixed_layout_tsv_suite.py` on FLORES
development phrases (`make_flores_mixed_tsv.py --split development`). Each step
the rules left undecided carries `calibrationFeatures` and its candidate; it is
a positive when switching to that candidate yields the expected text. The threshold is the lowest probability
above every negative, so the score adds no false conversion on the fitting
data. Evaluate on the calibration split, never on the frozen test split.

To refit from the rules alone, set `threshold` above 1 in
`scripts/data/undecided-calibration.json`, rebuild the model, run the suite,
then fit from that run and rebuild again.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


def rows(path: Path):
    for line in path.open(encoding="utf-8"):
        for step in json.loads(line)["steps"]:
            features = step.get("calibrationFeatures")
            if not features or step["actualReason"] not in ("undecided", "calibratedScore"):
                continue
            positive = step["expectedVerdict"] == "switch" and step["calibrationCandidate"] == step["expectedResolved"]
            yield features, positive, step


def fit(samples: list[list[float]], labels: list[int], l2: float = 1.0, steps: int = 6000, rate: float = 0.1):
    width = len(samples[0])
    weights, bias = [0.0] * width, 0.0
    for _ in range(steps):
        gradient, bias_gradient = [0.0] * width, 0.0
        for x, y in zip(samples, labels):
            p = 1 / (1 + math.exp(-max(-30, min(30, bias + sum(w * v for w, v in zip(weights, x))))))
            for index, value in enumerate(x):
                gradient[index] += (p - y) * value
            bias_gradient += p - y
        weights = [w - rate * (g / len(labels) + l2 * w / len(labels)) for w, g in zip(weights, gradient)]
        bias -= rate * bias_gradient / len(labels)
    return weights, bias


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("results", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    data = list(rows(args.results))
    names = sorted(data[0][0])
    raw = [[features[name] for name in names] for features, _, _ in data]
    labels = [int(positive) for _, positive, _ in data]
    mean = [sum(column) / len(column) for column in zip(*raw)]
    scale = [math.sqrt(sum((v - m) ** 2 for v in column) / len(column)) or 1.0 for column, m in zip(zip(*raw), mean)]
    scaled = [[(v - m) / s for v, m, s in zip(x, mean, scale)] for x in raw]
    weights, bias = fit(scaled, labels)
    probability = [1 / (1 + math.exp(-(bias + sum(w * v for w, v in zip(weights, x))))) for x in scaled]
    threshold = max((p for p, y in zip(probability, labels) if not y), default=0.5) + 1e-6
    recovered = sum(1 for p, y in zip(probability, labels) if y and p >= threshold)
    calibration = {
        "features": names,
        "mean": [round(v, 6) for v in mean],
        "scale": [round(v, 6) for v in scale],
        "weights": [round(v, 6) for v in weights],
        "bias": round(bias, 6),
        "threshold": round(threshold, 6),
    }
    args.output.write_text(json.dumps(calibration, indent=1) + "\n", encoding="utf-8")
    print(f"{len(labels)} undecided steps, {sum(labels)} positive, {recovered} recovered at {threshold:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
