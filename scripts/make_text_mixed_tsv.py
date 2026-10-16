#!/usr/bin/env python3
"""Build mixed-layout TSV phrases from plain text, one message per line.

Every message yields the layouts a person could have typed it in:
- `en-layout`: the whole message in the English layout, so its Russian words
  are wrong and its English words correct;
- `ru-layout`: the whole message in the Russian layout;
- `by-hand`: a message mixing both languages, each word in its own layout,
  which the user switched by hand; every conversion is a false positive;
- `slip`: the dominant language's layout until a random word, then the other.

Use it for text the decoder was never tuned on, such as Universal Dependencies
treebanks or newly written chat messages, kept in separate tuning, validation
and test files.
"""
from __future__ import annotations

import argparse
import csv
import random
from pathlib import Path

from make_flores_mixed_tsv import QUOTES, kind, label


def labels(tokens: list[str], layout: str) -> list[str]:
    """Labels for typing every token in `layout` ("ru" or "en")."""
    return [label(token, kind(token) not in ("technical", layout)) for token in tokens]


def phrases(tokens: list[str], rng: random.Random) -> list[tuple[str, list[str]]]:
    kinds = [kind(token) for token in tokens]
    russian, english = kinds.count("ru"), kinds.count("en")
    if russian + english == 0:
        return []
    rows = [("en-layout", labels(tokens, "en")), ("ru-layout", labels(tokens, "ru"))]
    if russian and english:
        rows.append(("by-hand", [label(token, False) for token in tokens]))
    if len(tokens) >= 4:
        dominant = "ru" if russian >= english else "en"
        other = "en" if dominant == "ru" else "ru"
        cut = rng.randrange(1, len(tokens))
        rows.append(("slip", labels(tokens[:cut], dominant) + labels(tokens[cut:], other)))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("inputs", type=Path, nargs="+")
    parser.add_argument("--seed", type=int, default=11)
    parser.add_argument("--scenario", action="append", choices=["en-layout", "ru-layout", "by-hand", "slip"],
                        help="keep only these scenarios (repeatable); default all")
    args = parser.parse_args()
    rng = random.Random(args.seed)
    rows = [["wrong_input", "expected_output", "token_pattern"]]
    for path in args.inputs:
        for line in path.read_text(encoding="utf-8").splitlines():
            tokens = line.translate(QUOTES).split()
            for scenario, pattern in phrases(tokens, rng):
                if args.scenario and scenario not in args.scenario:
                    continue
                text = " ".join(tokens)
                rows.append([text, text, ",".join(pattern)])
    with args.output.open("w", encoding="utf-8", newline="") as output:
        csv.writer(output, delimiter="\t", lineterminator="\n").writerows(rows)
    print(f"{len(rows) - 1} phrases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
