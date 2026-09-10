"""Run-local corpus evidence with validated, backwards-compatible output aliases."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import sys
import tempfile


def atomic_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as handle:
        temporary = Path(handle.name)
    try:
        shutil.copyfile(source, temporary)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


class CorpusRunArtifacts:
    def __init__(self, parent: Path, name: str, outputs: dict[str, Path]):
        self.outputs = {key: path.resolve() for key, path in outputs.items()}
        if len(set(self.outputs.values())) != len(outputs):
            raise ValueError("corpus output paths must be distinct")
        parent.mkdir(parents=True, exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(prefix=name + "-", dir=parent))
        self.paths = {
            key: self.directory / (key + path.suffix)
            for key, path in self.outputs.items()
        }
        self.returncode = None
        # Invalidate the previous audit before input preparation or process launch.
        # Even an interrupted parent cannot leave the old 'passed' as this run's audit.
        self.write_audit({"qualityPassed": False, "error": "run has not completed"}, "invalidRun")

    def record_process(self, returncode: int) -> None:
        self.returncode = returncode
        if returncode not in (0, 1):
            raise ValueError(f"simulator exited abnormally with code {returncode}")

    def require_exit_matches(self, passed: bool) -> None:
        # Exit 1 is a completed corpus mismatch only when fresh evidence agrees.
        if type(passed) is not bool or self.returncode != (0 if passed else 1):
            raise ValueError("simulator exit code and report outcome disagree")

    def write_audit(self, audit: dict[str, object], status: str) -> dict[str, object]:
        audit = dict(audit, status=status, runId=self.directory.name,
                     subprocessReturnCode=self.returncode,
                     artifacts={key: str(path) for key, path in self.paths.items()})
        self.paths["audit"].write_text(
            json.dumps(audit, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        atomic_copy(self.paths["audit"], self.outputs["audit"])
        return audit

    def publish(self, audit: dict[str, object], passed: bool) -> dict[str, object]:
        # Readers needing a coherent snapshot use the run-local paths in the audit.
        # Legacy aliases are replaced individually; the audit is published last.
        for key, destination in self.outputs.items():
            if key != "audit":
                atomic_copy(self.paths[key], destination)
        return self.write_audit(audit, "passed" if passed else "failed")

    def invalid(self, error: Exception) -> int:
        self.write_audit({"qualityPassed": False, "error": str(error)}, "invalidRun")
        print(f"invalid corpus run {self.directory.name}: {error}", file=sys.stderr)
        return self.returncode if self.returncode not in (None, 0, 1) else 1


def load_phrase_results(
    generated: Path, results: Path, *, identity: str, steps: str
) -> tuple[list[dict], list[dict]]:
    def read_jsonl(path: Path) -> list[dict]:
        with path.open(encoding="utf-8") as handle:
            rows = [json.loads(line) for line in handle if line.strip()]
        if any(not isinstance(row, dict) for row in rows):
            raise ValueError(f"expected JSON objects in {path.name}")
        return rows

    fixtures, rows = read_jsonl(generated), read_jsonl(results)
    if not fixtures or any(not fixture.get("steps") for fixture in fixtures):
        raise ValueError("quality evaluation requires nonempty phrases and tokens")
    if len(rows) != len(fixtures):
        raise ValueError(f"results contain {len(rows)} phrases for {len(fixtures)} fixtures")
    for fixture, row in zip(fixtures, rows):
        if row[identity] != fixture["id"]:
            raise ValueError("result phrase identities or order differ from generated fixtures")
        if (not isinstance(row[steps], list)
                or len(row[steps]) != len(fixture["steps"])
                or any(not isinstance(step, dict) for step in row[steps])):
            raise ValueError(f"incomplete token results for {fixture['id']}")
        if type(row["passed"]) is not bool:
            raise ValueError(f"invalid phrase outcome for {fixture['id']}")
    return fixtures, rows


def require_counts(summary: dict, expected: dict[str, int]) -> None:
    for key, count in expected.items():
        if type(summary[key]) is not int or summary[key] != count:
            raise ValueError(f"report {key} differs from complete results: expected {count}")
