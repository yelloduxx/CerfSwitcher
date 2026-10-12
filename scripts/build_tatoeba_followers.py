#!/usr/bin/env python3
"""Derive next-word and word-frequency statistics from Tatoeba sentence exports.

Followers: only words whose keys also spell a frequent or attested word in the
other layout are kept (`here`/`руку`, `руки`/`herb`). For such a word W and a
preceding word P the output stores ln(count(P W) / count(P)) when the pair
occurs at least --min-count times. The decoder uses it only to tell which of
two readings continues the previous word.

Attested: counts of words outside the model's frequency list that occur at
least twice, contractions included (`it's`). They tell an attested rare form
(`вероятностью`) from a spelling artifact that conversational text never uses.

Tatoeba sentences are CC BY 2.0 FR.
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
WORD = {"en": re.compile(r"[a-z]+(?:'[a-z]+)*"), "ru": re.compile(r"[а-яё]+")}
EXPORT = {"en": "eng_sentences.tsv.bz2", "ru": "rus_sentences.tsv.bz2"}


def sentences(path: Path, language: str):
    with bz2.open(path, "rt", encoding="utf-8") as source:
        for line in source:
            text = line.rstrip("\n").split("\t", 2)[-1].lower().replace("’", "'")
            yield TOKEN[language].findall(text)


def word_counts(path: Path, language: str) -> collections.Counter[str]:
    words: collections.Counter[str] = collections.Counter()
    for tokens in sentences(path, language):
        words.update(tokens)
    return words


def followers(path: Path, language: str, vocabulary: set[str], min_count: int) -> dict[str, float]:
    previous_counts: collections.Counter[str] = collections.Counter()
    pairs: collections.Counter[tuple[str, str]] = collections.Counter()
    for tokens in sentences(path, language):
        previous_counts.update(tokens[:-1])
        pairs.update(pair for pair in zip(tokens, tokens[1:]) if pair[1] in vocabulary)
    return {
        f"{previous}\u001f{word}": round(math.log(count / previous_counts[previous]), 4)
        for (previous, word), count in sorted(pairs.items())
        if count >= min_count
    }


def attested(words: collections.Counter[str], language: str, frequent: set[str]) -> dict[str, int]:
    return {
        word: count
        for word, count in sorted(words.items())
        if count >= 2 and word not in frequent and WORD[language].fullmatch(word)
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("exports", type=Path, help="directory with Tatoeba per-language exports")
    parser.add_argument("vocabulary", type=Path, help="JSON {language: [frequent words]} from the model")
    parser.add_argument("output", type=Path)
    parser.add_argument("--min-count", type=int, default=3)
    args = parser.parse_args()
    frequent = {language: set(words) for language, words in json.loads(args.vocabulary.read_text()).items()}
    paths = {language: args.exports / name for language, name in EXPORT.items()}
    counts = {language: word_counts(path, language) for language, path in paths.items()}
    known = {
        language: frequent[language] | set(attested(counts[language], language, frequent[language]))
        for language in EXPORT
    }
    mapping = {"en": (EN_TO_RU, "ru"), "ru": (RU_TO_EN, "en")}
    vocabulary = {
        language: {
            word for word in words
            if len(word) >= 2 and "".join(table.get(char, char) for char in word) in known[other]
        }
        for language, words in known.items()
        for table, other in [mapping[language]]
    }
    result = {
        "license": "CC BY 2.0 FR",
        "source": "https://tatoeba.org (per-language sentence exports)",
        "sha256": {},
        "minCount": args.min_count,
        "followers": {},
        "attested": {},
    }
    for language, name in EXPORT.items():
        result["sha256"][name] = hashlib.sha256(paths[language].read_bytes()).hexdigest()
        result["followers"][language] = followers(paths[language], language, vocabulary[language], args.min_count)
        result["attested"][language] = attested(counts[language], language, frequent[language])
        print(language, len(result["followers"][language]), len(result["attested"][language]))
    payload = json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    with gzip.GzipFile(args.output, "wb", mtime=0) as output:
        output.write(payload)
    print(args.output, args.output.stat().st_size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
