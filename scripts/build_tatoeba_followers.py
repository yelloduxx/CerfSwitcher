#!/usr/bin/env python3
"""Derive next-word statistics from Tatoeba sentence exports.

Only words whose keys also spell a frequent word in the other layout are kept
(`here`/`руку`). For such a word W and a preceding word P the output stores
ln(count(P W) / count(P)) when the pair occurs at least --min-count times. The
decoder uses it only to tell which of two frequent readings continues the
previous word. Tatoeba sentences are CC BY 2.0 FR.
"""

from __future__ import annotations

import argparse
import bz2
import collections
import gzip
import hashlib
import json
import math
import re
from pathlib import Path

from run_mixed_layout_tsv_suite import EN_TO_RU, RU_TO_EN

TOKEN = {
    "en": re.compile(r"[a-z]+(?:'[a-z]+)*"),
    "ru": re.compile(r"[а-яё]+(?:-[а-яё]+)*"),
}
EXPORT = {"en": "eng_sentences.tsv.bz2", "ru": "rus_sentences.tsv.bz2"}


def followers(path: Path, language: str, vocabulary: set[str], min_count: int) -> dict[str, float]:
    unigrams: collections.Counter[str] = collections.Counter()
    pairs: collections.Counter[tuple[str, str]] = collections.Counter()
    with bz2.open(path, "rt", encoding="utf-8") as source:
        for line in source:
            text = line.rstrip("\n").split("\t", 2)[-1].lower().replace("’", "'")
            tokens = TOKEN[language].findall(text)
            unigrams.update(tokens[:-1])
            pairs.update(pair for pair in zip(tokens, tokens[1:]) if pair[1] in vocabulary)
    return {
        f"{previous}\u001f{word}": round(math.log(count / unigrams[previous]), 4)
        for (previous, word), count in sorted(pairs.items())
        if count >= min_count
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("exports", type=Path, help="directory with Tatoeba per-language exports")
    parser.add_argument("vocabulary", type=Path, help="JSON {language: [frequent words]} from the model")
    parser.add_argument("output", type=Path)
    parser.add_argument("--min-count", type=int, default=5)
    args = parser.parse_args()
    frequent = {language: set(words) for language, words in json.loads(args.vocabulary.read_text()).items()}
    mapping = {"en": (EN_TO_RU, "ru"), "ru": (RU_TO_EN, "en")}
    vocabulary = {
        language: {
            word for word in words
            if len(word) >= 2 and "".join(table.get(char, char) for char in word) in frequent[other]
        }
        for language, words in frequent.items()
        for table, other in [mapping[language]]
    }
    result = {
        "license": "CC BY 2.0 FR",
        "source": "https://tatoeba.org (per-language sentence exports)",
        "sha256": {},
        "minCount": args.min_count,
        "followers": {},
    }
    for language, name in EXPORT.items():
        path = args.exports / name
        result["sha256"][name] = hashlib.sha256(path.read_bytes()).hexdigest()
        result["followers"][language] = followers(path, language, vocabulary[language], args.min_count)
        print(language, len(result["followers"][language]))
    payload = json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    with gzip.GzipFile(args.output, "wb", mtime=0) as output:
        output.write(payload)
    print(args.output, args.output.stat().st_size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
