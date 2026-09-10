#!/usr/bin/env python3
"""Freeze licensed EN/RU prose before any decoder evaluation or corruption."""

import argparse
from collections import Counter
import csv
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unicodedata
from urllib.parse import urldefrag, urlsplit


ARCHIVE_URL = "https://dl.fbaipublicfiles.com/nllb/flores200_dataset.tar.gz"
ARCHIVE_SHA256 = "b8b0b76783024b85797e5cc75064eb83fc5288b41e9654dabc7be6ae944011f6"
SOURCE_REVISION = "a6c830c6e1051fb4ac1a44b32358f00463f332bd"
LICENSE_SHA256 = "fe38377ee0e52dc6c9c78554055a4e5e78781d73022df4508c9cf284e0f462e9"
SEED = "ruswitch-independent-v1:20260911"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def load_source(path):
    raw = path.read_bytes()
    if sha256(raw) != ARCHIVE_SHA256:
        raise ValueError("FLORES archive checksum mismatch")
    rows, member_hashes = [], {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
        def text_member(name):
            member = archive.getmember("./flores200_dataset/" + name)
            if not member.isfile() or not 0 < member.size < 2_000_000:
                raise ValueError("invalid corpus member")
            data = archive.extractfile(member).read()
            member_hashes[name] = sha256(data)
            return data.decode("utf-8")

        for partition, count in [("dev", 997), ("devtest", 1012)]:
            metadata = list(csv.DictReader(io.StringIO(text_member(f"metadata_{partition}.tsv")), delimiter="\t"))
            en = text_member(f"{partition}/eng_Latn.{partition}").splitlines()
            ru = text_member(f"{partition}/rus_Cyrl.{partition}").splitlines()
            if not (len(metadata) == len(en) == len(ru) == count):
                raise ValueError("FLORES translation/metadata alignment mismatch")
            for index, (meta, english, russian) in enumerate(zip(metadata, en, ru), start=1):
                url = urldefrag(meta["URL"])[0]
                if urlsplit(url).scheme not in ("http", "https") or not urlsplit(url).netloc:
                    raise ValueError("invalid source document URL")
                if not english.strip() or not russian.strip():
                    raise ValueError("empty source sentence")
                rows.append(dict(id=f"flores200:{partition}:{index:04d}", sourceURL=meta["URL"],
                                 documentID=url, domain=meta["domain"], topic=meta["topic"],
                                 texts=dict(en=english, ru=russian)))
    return rows, member_hashes


def partition_documents(rows):
    parents = {row["documentID"]: row["documentID"] for row in rows}

    def root(document):
        while parents[document] != document:
            parents[document] = parents[parents[document]]
            document = parents[document]
        return document

    # Exact normalized sentence duplicates join whole documents, including
    # both translations. Never choose a split independently for each sentence.
    seen = {}
    for row in sorted(rows, key=lambda item: item["id"]):
        for language, text in sorted(row["texts"].items()):
            normalized = " ".join(unicodedata.normalize("NFC", text).casefold().split())
            key = (language, normalized)
            if key in seen:
                a, b = root(row["documentID"]), root(seen[key])
                parents[max(a, b)] = min(a, b)
            else:
                seen[key] = row["documentID"]
    result = []
    for row in sorted(rows, key=lambda item: item["id"]):
        group = root(row["documentID"])
        bucket = int(sha256((SEED + "\0" + group).encode("utf-8")), 16) % 100
        split = "development" if bucket < 60 else "calibration" if bucket < 80 else "test"
        result.append(dict(row, groupID=sha256(group.encode("utf-8")), split=split))
    return result


def encode_rows(rows):
    text = "".join(json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n" for row in rows)
    data = io.BytesIO()
    with gzip.GzipFile(fileobj=data, mode="wb", filename="", mtime=0) as stream:
        stream.write(text.encode("utf-8"))
    return data.getvalue()


def statistics(rows):
    return dict(pairs=len(rows), phrases=2 * len(rows), documents=len({row["documentID"] for row in rows}),
                documentGroups=len({row["groupID"] for row in rows}),
                bySplit={split: dict(pairs=sum(row["split"] == split for row in rows),
                                    documentGroups=len({row["groupID"] for row in rows if row["split"] == split}),
                                    whitespaceTokens={lang: sum(len(row["texts"][lang].split()) for row in rows
                                                              if row["split"] == split) for lang in ("en", "ru")})
                         for split in ("development", "calibration", "test")},
                domains=dict(sorted(Counter(row["domain"] for row in rows).items())))


def prepare(archive, license_path, output):
    if output.exists():
        raise ValueError("refusing to overwrite a frozen corpus; use a new output directory")
    license_data = license_path.read_bytes()
    if sha256(license_data) != LICENSE_SHA256:
        raise ValueError("source license checksum mismatch")
    rows, members = load_source(archive)
    rows = partition_documents(rows)
    data = encode_rows(rows)
    manifest = dict(formatVersion=1, corpusID="flores200-clean-en-ru-v1", status="frozenNotEvaluated",
                    usage="evaluation-only; not model training", sourceURL=ARCHIVE_URL,
                    sourceArchiveSHA256=ARCHIVE_SHA256, sourceRevision=SOURCE_REVISION,
                    license="CC-BY-SA-4.0", licenseSHA256=LICENSE_SHA256, sourceMembers=members,
                    partition=dict(seed=SEED, method="SHA256(document duplicate-component) mod 100; 60/20/20",
                                   duplicates="NFC, casefold and collapsed whitespace; links whole source documents",
                                   textTransform="none; original sentence strings retained"),
                    files={"clean.jsonl.gz": sha256(data)}, counts=statistics(rows),
                    limitations=["Translation benchmark: news, encyclopedia and travel; not chat/work/code coverage",
                                 "Not an OOV-family split and not a physical keyboard fixture",
                                 "Test token volume is below 50000 per language; no false-positive confidence claim",
                                 "No corruption profiles or decoder decisions have been generated yet"])
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="independent-stage-", dir=output.parent) as temporary:
        staged = Path(temporary) / "corpus"
        staged.mkdir()
        (staged / "clean.jsonl.gz").write_bytes(data)
        (staged / "LICENSE_CC-BY-SA.txt").write_bytes(license_data)
        (staged / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        staged.rename(output)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--license", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.archive, args.license, args.output), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
