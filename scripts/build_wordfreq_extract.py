#!/usr/bin/env python3
"""Extract conversational word frequencies from the pinned wordfreq wheel.

wordfreq 3.1.1 (Robyn Speer, data CC BY-SA 4.0) ships each language as a
gzipped msgpack list of frequency buckets: bucket i holds the words whose
Zipf frequency is 9 - i/100. This writes the plain words of one language
(lowercase letters of its alphabet, Zipf >= 3.0, i.e. at least once per
million words) to scripts/data. The extract is what the model builder reads.

Usage: python3 scripts/build_wordfreq_extract.py wordfreq-3.1.1-py3-none-any.whl
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import struct
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_language_model import WORDFREQ_EXTRACTS, WORDFREQ_MIN_ZIPF, is_language_word  # noqa: E402

WHEEL_SHA256 = "4b1c6ecffc6198be3396d5cf871c4423ca71c907c231348d352dd54d62b97473"


def unpack(data: bytes, at: int = 0):
    """The msgpack subset wordfreq uses: maps, arrays, strings, small ints."""
    tag = data[at]
    if tag <= 0x7F:
        return tag, at + 1
    if 0x80 <= tag <= 0x8F or tag == 0xDE:
        count, at = (tag & 0x0F, at + 1) if tag <= 0x8F else (struct.unpack(">H", data[at + 1:at + 3])[0], at + 3)
        result = {}
        for _ in range(count):
            key, at = unpack(data, at)
            result[key], at = unpack(data, at)
        return result, at
    if 0x90 <= tag <= 0x9F or tag in (0xDC, 0xDD):
        if tag <= 0x9F:
            count, at = tag & 0x0F, at + 1
        elif tag == 0xDC:
            count, at = struct.unpack(">H", data[at + 1:at + 3])[0], at + 3
        else:
            count, at = struct.unpack(">I", data[at + 1:at + 5])[0], at + 5
        result = []
        for _ in range(count):
            value, at = unpack(data, at)
            result.append(value)
        return result, at
    if 0xA0 <= tag <= 0xBF:
        length, at = tag & 0x1F, at + 1
    elif tag == 0xD9:
        length, at = data[at + 1], at + 2
    elif tag == 0xDA:
        length, at = struct.unpack(">H", data[at + 1:at + 3])[0], at + 3
    elif tag == 0xDB:
        length, at = struct.unpack(">I", data[at + 1:at + 5])[0], at + 5
    elif tag == 0xCC:
        return data[at + 1], at + 2
    elif tag == 0xCD:
        return struct.unpack(">H", data[at + 1:at + 3])[0], at + 3
    else:
        raise ValueError(f"unsupported msgpack tag {tag:#x}")
    return data[at:at + length].decode("utf-8"), at + length


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("wheel", type=Path)
    args = parser.parse_args()
    if hashlib.sha256(args.wheel.read_bytes()).hexdigest() != WHEEL_SHA256:
        raise SystemExit(f"unexpected wheel {args.wheel}")
    with zipfile.ZipFile(args.wheel) as wheel:
        for language, (path, _) in WORDFREQ_EXTRACTS.items():
            buckets, _ = unpack(gzip.decompress(wheel.read(f"wordfreq/data/large_{language}.msgpack.gz")))
            header, buckets = buckets[0], buckets[1:]
            assert header.get("format") == "cB", header
            rows = [f"{word}\t{9 - index / 100:.2f}\n"
                    for index, words in enumerate(buckets) if 9 - index / 100 >= WORDFREQ_MIN_ZIPF
                    for word in words if is_language_word(word, language)]
            buffer = io.BytesIO()
            with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0) as handle:
                handle.write("".join(rows).encode("utf-8"))
            path.write_bytes(buffer.getvalue())
            print(f"{path}: {len(rows)} words, sha256={hashlib.sha256(buffer.getvalue()).hexdigest()}")


if __name__ == "__main__":
    main()
