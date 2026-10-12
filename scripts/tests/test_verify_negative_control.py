from __future__ import annotations

from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "verify_simulator_negative_control.sh"
CONTROL_ID = "intentional-negative-control"
REPORT_NAME = "ruswitcher-negative-control.json"
STUB = """#!/bin/sh
if [ -n "${STUB_MARKER:-}" ]; then
    : > "$STUB_MARKER"
fi
output=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--output" ]; then
        output="$2"
    fi
    shift
done
if [ -n "${STUB_REPORT:-}" ] && [ -n "$output" ]; then
    cp "$STUB_REPORT" "$output"
fi
if [ -n "${STUB_RIVAL_REPORT:-}" ]; then
    cp "$STUB_RIVAL_REPORT" "$STUB_RIVAL_PATH"
fi
exit "${STUB_STATUS:-1}"
"""
REQUIRED_TOOLS = ("jq",)
BASH = shutil.which("bash")


def phrase_failure(identifier: str) -> dict:
    return {"id": identifier, "passed": False, "expectedText": "a", "actualText": "b", "steps": []}


def word_failure(identifier: str) -> dict:
    return {"id": identifier, "passed": False}


def report(failures: list[dict], phrase_failures: list[dict]) -> dict:
    return {
        "engine": "v3",
        "total": 26,
        "passed": 26 - len(failures) - len(phrase_failures),
        "failed": len(failures) + len(phrase_failures),
        "failures": failures,
        "phraseFailures": phrase_failures,
    }


class VerifyNegativeControlTests(unittest.TestCase):
    def setUp(self):
        missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
        self.assertEqual(missing, [], f"required tools not found on PATH: {missing}")
        self.directory = Path(tempfile.mkdtemp(prefix="negative-control-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        (self.directory / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.directory / "scripts" / SCRIPT.name)
        stubs = self.directory / "stubs"
        stubs.mkdir()
        (stubs / "swift").write_text(STUB)
        (stubs / "swift").chmod(0o755)
        self.temporary = self.directory / "tmp"
        self.temporary.mkdir()
        self.environment = dict(
            os.environ,
            PATH=f"{stubs}{os.pathsep}{os.environ['PATH']}",
            TMPDIR=str(self.temporary),
        )
        self.environment.pop("STUB_REPORT", None)

    def run_script(self, stub_report: dict | str | None, status: int,
                   rival_report: dict | None = None,
                   environment: dict | None = None) -> subprocess.CompletedProcess:
        environment = dict(environment or self.environment, STUB_STATUS=str(status))
        if stub_report is not None:
            path = self.directory / "stub-report.json"
            path.write_text(stub_report if isinstance(stub_report, str) else json.dumps(stub_report))
            environment["STUB_REPORT"] = str(path)
        if rival_report is not None:
            rival = self.directory / "rival-report.json"
            rival.write_text(json.dumps(rival_report))
            environment["STUB_RIVAL_REPORT"] = str(rival)
            environment["STUB_RIVAL_PATH"] = str(self.temporary / REPORT_NAME)
        return subprocess.run([BASH, str(self.directory / "scripts" / SCRIPT.name)],
                              cwd=self.directory, env=environment,
                              capture_output=True, text=True, timeout=60)

    def testExactlyTheControlFailurePasses(self):
        result = self.run_script(report([], [phrase_failure(CONTROL_ID)]), 1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: simulator rejected the intentionally wrong phrase", result.stdout)

    def testExtraWordFailureNextToTheControlFails(self):
        result = self.run_script(report([word_failure("unrelated-word-case")], [phrase_failure(CONTROL_ID)]), 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL", result.stdout)
        self.assertIn("other failing ids: unrelated-word-case", result.stdout)

    def testExtraPhraseFailureNextToTheControlFails(self):
        result = self.run_script(
            report([], [phrase_failure(CONTROL_ID), phrase_failure("unrelated-phrase-case")]), 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL", result.stdout)
        self.assertIn("other failing ids: unrelated-phrase-case", result.stdout)

    def testUnrelatedFailureWithoutTheControlFails(self):
        result = self.run_script(report([], [phrase_failure("unrelated-phrase-case")]), 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("other failing ids: unrelated-phrase-case", result.stdout)

    def testStaleReportCannotSatisfyAFailedRun(self):
        (self.temporary / REPORT_NAME).write_text(json.dumps(report([], [phrase_failure(CONTROL_ID)])))
        result = self.run_script(None, 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL", result.stdout)
        self.assertNotIn("PASS", result.stdout)

    def testSimulatorAcceptingTheWrongExpectationFails(self):
        result = self.run_script(report([], []), 0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("simulator accepted an intentionally wrong expectation", result.stdout)

    def testMalformedReportFails(self):
        result = self.run_script("not json", 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PASS", result.stdout)

    def testSimulatorCrashAfterWritingTheControlReportFails(self):
        for status in (134, 139, 2, 74):
            with self.subTest(status=status):
                result = self.run_script(report([], [phrase_failure(CONTROL_ID)]), status)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"exited with status {status}", result.stdout)
                self.assertNotIn("PASS", result.stdout)

    def testRivalWriterAtTheOldFixedPathCannotSatisfyACrash(self):
        rival = report([], [phrase_failure(CONTROL_ID)])
        for status in (1, 134):
            with self.subTest(status=status):
                result = self.run_script(None, status, rival_report=rival)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("PASS", result.stdout)

    def testNoReportIsLeftBehind(self):
        self.run_script(report([], [phrase_failure(CONTROL_ID)]), 1)
        self.run_script(report([word_failure("unrelated-word-case")], [phrase_failure(CONTROL_ID)]), 1)
        self.assertEqual(sorted(path.name for path in self.temporary.iterdir()), [])

    def testMissingJqFailsBeforeTheSimulatorRuns(self):
        tools = self.directory / "tools"
        tools.mkdir()
        for tool in ("dirname", "rm", "mktemp", "cp"):
            (tools / tool).symlink_to(shutil.which(tool))
        marker = self.directory / "simulator-ran"
        environment = dict(self.environment,
                           PATH=f"{self.directory / 'stubs'}{os.pathsep}{tools}",
                           STUB_MARKER=str(marker))
        result = self.run_script(report([], [phrase_failure(CONTROL_ID)]), 1, environment=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("jq is required", result.stdout)
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
