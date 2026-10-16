#!/usr/bin/env python3
"""Build a mixed-layout TSV from the FLORES development or calibration split.

Each EN/RU pair yields five realistic phrases: Russian typed fully in the
English layout, English typed fully in the Russian layout, a Russian sentence
that slips into the wrong layout midway, and Russian prose with an English
term after which the user forgot to switch back, and Russian prose with an
English term typed without switching to the English layout. The frozen test split is
read only on request, for a final report after tuning on the other two.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import random
import re
import string
from pathlib import Path

# Quotes are dropped: a Russian quote is Shift+2 (`@` in the English layout),
# which the static projection of the TSV runner cannot express.
QUOTES = str.maketrans({"«": None, "»": None, "„": None, "“": None, "”": None, '"': None, "’": "'", "…": "..."})
CYRILLIC = re.compile(r"[а-яё]", re.IGNORECASE)
LATIN = re.compile(r"[a-z]", re.IGNORECASE)
# Characters that a plain or Shift key press yields in the US or Russian-PC layout.
# A token with anything else (emoji, dashes, accents) cannot come from a wrong layout.
TYPEABLE = set(string.ascii_letters + string.digits + string.punctuation + "№") | set(
    "абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")


def kind(token: str) -> str:
    if any(char.isdigit() or char not in TYPEABLE for char in token):
        return "technical"
    has_ru, has_en = bool(CYRILLIC.search(token)), bool(LATIN.search(token))
    if has_ru == has_en:
        return "technical"
    return "ru" if has_ru else "en"


def label(token: str, wrong: bool) -> str:
    language = kind(token)
    if language == "technical":
        return "technical_unchanged"
    return f"{language}_{'wrong' if wrong else 'correct'}"


def row(tokens: list[str], labels: list[str]) -> list[str]:
    text = " ".join(tokens)
    return [text, text, ",".join(labels)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("corpus", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--split", choices=["development", "calibration", "test"], default="development",
                        help="test is the frozen held-out split: read it only for a final, untuned report")
    parser.add_argument("--scenario", choices=["mixed", "deliberate"], default="mixed",
                        help="deliberate: one correctly typed word of the other language, any length, "
                             "with a layout switch by hand before and after it")
    args = parser.parse_args()
    rng = random.Random(args.seed)
    rows = [["wrong_input", "expected_output", "token_pattern"]]
    with gzip.open(args.corpus, "rt", encoding="utf-8") as source:
        for line in source:
            record = json.loads(line)
            if record["split"] != args.split:
                continue
            ru = record["texts"]["ru"].translate(QUOTES).split()
            en = record["texts"]["en"].translate(QUOTES).split()
            if args.scenario == "deliberate":
                for prose, other in ((ru, en), (en, ru)):
                    words = [t for t in other if kind(t) != "technical"]
                    if words:
                        at = rng.randrange(0, len(prose) + 1)
                        mixed = prose[:at] + [rng.choice(words)] + prose[at:]
                        rows.append(row(mixed, [label(t, False) for t in mixed]))
                continue
            rows.append(row(ru, [label(t, True) for t in ru]))
            rows.append(row(en, [label(t, True) for t in en]))
            cut = rng.randrange(1, max(2, len(ru)))
            rows.append(row(ru, [label(t, i >= cut) for i, t in enumerate(ru)]))
            english_terms = [t.strip(".,:;!?()\"'") for t in en if kind(t) == "en" and len(t) > 3]
            if english_terms:
                term = rng.choice(english_terms).lower()
                at = rng.randrange(0, len(ru))
                mixed = ru[:at] + [term] + ru[at:]
                labels = [label(t, False) for t in ru[:at]] + ["en_correct"] + [label(t, True) for t in ru[at:]]
                rows.append(row(mixed, labels))
                forgotten = [label(t, False) for t in ru[:at]] + ["en_wrong"] + [label(t, False) for t in ru[at:]]
                rows.append(row(mixed, forgotten))
    with args.output.open("w", encoding="utf-8", newline="") as output:
        csv.writer(output, delimiter="\t", lineterminator="\n").writerows(rows)
    print(f"{len(rows) - 1} phrases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
