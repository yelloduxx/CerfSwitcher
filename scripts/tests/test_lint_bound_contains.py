from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "lint_bound_contains.sh"

BOUND_REFERENCES = [
    "char.unicodeScalars.allSatisfy(set.contains)",
    "raw.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) { return true }",
    "names.filter(set.contains, limit)",
    "names.filter(set.contains )",
    "let isMember = set.contains",
    "let isMember = set.contains;",
    "names.filter(set.contains(_:))",
    "names.contains(where: other.contains(where:))",
]

CALLS = [
    "x.contains(y)",
    "raw.contains(\"/\")",
    "scalars.contains(where: { scalar in set.contains(scalar) })",
    "rules.contains {",
    "rules.contains { $0.isEmpty }",
    "names.containsWhere(y)",
    "let containsAll = true",
    "// Keep `contains` predicates as closures, never a bound `set.contains` reference.",
]


def lint(lines: list[str]) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "scripts").mkdir()
        shutil.copy2(SCRIPT, root / "scripts" / SCRIPT.name)
        (root / "Sample.swift").write_text("\n".join(lines) + "\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "add", "Sample.swift"], cwd=root, check=True)
        return subprocess.run(["bash", str(root / "scripts" / SCRIPT.name)],
                              capture_output=True, text=True)


class LintBoundContainsTests(unittest.TestCase):
    def test_reports_every_bound_reference_and_no_call(self) -> None:
        result = lint(BOUND_REFERENCES + CALLS)

        self.assertEqual(result.returncode, 1)
        reported = [line.split(":", 2)[1] for line in result.stdout.splitlines()]
        self.assertEqual(reported, ["1", "2", "3", "4", "5", "6", "7", "8"])

    def test_passes_when_only_calls_and_closures_remain(self) -> None:
        result = lint(CALLS)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
