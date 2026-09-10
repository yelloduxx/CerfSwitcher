"""Corpus artifact regression tests; no Swift process or native input is used."""

from __future__ import annotations

import contextlib
import csv
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run_mixed_layout_event_stream_suite as event_suite
import run_mixed_layout_tsv_suite as tsv_suite


class CorpusRunArtifactTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.build = self.root / ".build"
        self.build.mkdir()
        self.tsv = self.root / "corpus.tsv"
        with self.tsv.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle, delimiter="\t")
            writer.writerow(["wrong_input", "expected_output", "token_pattern"])
            writer.writerow(["hello", "hello", "en_correct"])
            writer.writerow(["ghbdtn", "\u043f\u0440\u0438\u0432\u0435\u0442", "ru_wrong"])
        self.commands = []

    def paths(self, module):
        if module is event_suite:
            return {
                "input": self.build / "mixed-layout-5000-event-stream-input.jsonl",
                "report": self.build / "mixed-layout-5000-event-stream-report.json",
                "results": self.build / "mixed-layout-5000-event-stream-results.jsonl",
                "audit": self.build / "mixed-layout-5000-event-stream-audit.json",
            }
        return {
            "input": self.build / "mixed-layout-5000-phrases.jsonl",
            "report": self.build / "mixed-layout-5000-report.json",
            "results": self.build / "mixed-layout-5000-traces.jsonl",
            "audit": self.build / "mixed-layout-5000-audit.json",
        }

    def payloads(self, module, generated, safe_miss=False):
        fixtures = [json.loads(line) for line in generated.read_text().splitlines()]
        rows = []
        for fixture in fixtures:
            steps = []
            for step in fixture["steps"]:
                missed = safe_miss and step["expected"] == "switch"
                actual = step["typed"] if missed else step["expectedResolved"]
                if module is event_suite:
                    steps.append({
                        "verdict": "switchToConverted"
                        if step["expected"] == "switch" and not missed else "keep",
                        "resolvedText": actual,
                    })
                else:
                    steps.append({
                        "typed": step["typed"],
                        "passed": not missed,
                        "expectedVerdict": step["expected"],
                        "actualResolved": actual,
                    })
            passed = not (safe_miss and any(
                step["expected"] == "switch" for step in fixture["steps"]
            ))
            if module is event_suite:
                rows.append({
                    "fixture": fixture["id"], "passed": passed, "traces": steps,
                    "transactionCount": sum(
                        step["verdict"] == "switchToConverted" for step in steps
                    ),
                    "duplicateTransactionCount": 0,
                })
            else:
                rows.append({"id": fixture["id"], "passed": passed, "steps": steps})
        total = len(rows)
        passed = sum(row["passed"] for row in rows)
        if module is event_suite:
            summary = {
                "passed": passed == total,
                "fixtureTotal": total, "fixturePassed": passed,
                "fixtureFailed": total - passed,
                "tokenTotal": sum(len(row["traces"]) for row in rows),
                "duplicateTransactionCount": 0, "workers": 2,
                "elapsedMilliseconds": 1,
                "actualTransactions": sum(row["transactionCount"] for row in rows),
            }
        else:
            summary = {
                "total": total, "passed": passed, "failed": total - passed,
                "phraseTotal": total, "phrasePassed": passed,
                "phraseFailures": [row for row in rows if not row["passed"]],
            }
        return summary, rows

    def write_outputs(self, paths, summary, rows):
        paths["report"].parent.mkdir(parents=True, exist_ok=True)
        paths["results"].parent.mkdir(parents=True, exist_ok=True)
        paths["report"].write_text(json.dumps(summary), encoding="utf-8")
        paths["results"].write_text(
            "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
        )

    def seed_stale(self, module):
        paths = self.paths(module)
        tsv_suite.convert_corpus(self.tsv, paths["input"])
        self.write_outputs(paths, *self.payloads(module, paths["input"]))
        paths["audit"].write_text(json.dumps({
            "qualityPassed": True, "status": "passed", "runId": "stale",
        }))

    def fake_runner(self, module, mode="complete", returncode=0, safe_miss=False):
        def run(command, **kwargs):
            self.commands.append(command)
            paths = {
                "input": Path(command[command.index("--phrase-input") + 1]),
                "report": Path(command[command.index("--output") + 1]),
                "results": Path(command[command.index(
                    "--results" if module is event_suite else "--phrase-results"
                ) + 1]),
            }
            if mode == "launch_error":
                raise FileNotFoundError("fake runner unavailable")
            if mode != "none":
                summary, rows = self.payloads(module, paths["input"], safe_miss)
                if mode == "short":
                    rows.pop()
                elif mode == "duplicate":
                    rows[1] = rows[0]
                elif mode == "wrong_summary":
                    summary["fixtureTotal" if module is event_suite else "phraseTotal"] -= 1
                elif mode == "short_steps":
                    rows[0]["traces" if module is event_suite else "steps"] = []
                elif mode == "missing_actual":
                    del rows[0]["traces" if module is event_suite else "steps"][0][
                        "resolvedText" if module is event_suite else "actualResolved"
                    ]
                self.write_outputs(paths, summary, rows)
                if mode == "report_only":
                    paths["results"].unlink()
                elif mode == "results_only":
                    paths["report"].unlink()
                elif mode == "malformed_report":
                    paths["report"].write_text('{"passed":')
                elif mode == "malformed_results":
                    with paths["results"].open("a") as handle:
                        handle.write('{"traces":')
            return subprocess.CompletedProcess(command, returncode)
        return run

    def invoke(self, module, extra_args=(), **runner_options):
        runner = self.fake_runner(module, **runner_options)
        with mock.patch.object(module, "__file__", str(self.root / "scripts" / Path(module.__file__).name)), \
                mock.patch.object(sys, "argv", ["suite", str(self.tsv), *extra_args]), \
                mock.patch.object(module.subprocess, "run", side_effect=runner), \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            return module.main()

    def assert_invalid(self, module, **options):
        self.seed_stale(module)
        self.assertNotEqual(self.invoke(module, **options), 0)
        audit = json.loads(self.paths(module)["audit"].read_text())
        self.assertEqual(audit["status"], "invalidRun")
        self.assertFalse(audit["qualityPassed"])
        self.assertNotEqual(audit["runId"], "stale")

    def test_stale_outputs_cannot_pass_after_process_failure(self):
        for module in (event_suite, tsv_suite):
            for returncode in (1, 70, -9):
                with self.subTest(suite=module.__name__, returncode=returncode):
                    self.assert_invalid(module, mode="none", returncode=returncode)

    def test_success_exit_requires_fresh_complete_artifacts(self):
        for module in (event_suite, tsv_suite):
            for mode in ("none", "report_only", "results_only", "short", "duplicate",
                         "short_steps", "wrong_summary", "malformed_report", "malformed_results",
                         "missing_actual"):
                with self.subTest(suite=module.__name__, mode=mode):
                    self.assert_invalid(module, mode=mode)

    def test_complete_artifacts_do_not_hide_abnormal_exit(self):
        for module in (event_suite, tsv_suite):
            for returncode in (1, 70, -9):
                with self.subTest(suite=module.__name__, returncode=returncode):
                    self.assert_invalid(module, returncode=returncode)

    def test_launch_failure_invalidates_previous_audit(self):
        for module in (event_suite, tsv_suite):
            with self.subTest(suite=module.__name__):
                self.assert_invalid(module, mode="launch_error")

    def test_completed_safe_misses_preserve_each_suites_exit_policy(self):
        for module, expected_exit, expected_status in (
            (event_suite, 0, "passed"), (tsv_suite, 1, "failed"),
        ):
            with self.subTest(suite=module.__name__):
                self.assertEqual(self.invoke(module, safe_miss=True, returncode=1), expected_exit)
                audit = json.loads(self.paths(module)["audit"].read_text())
                self.assertEqual(audit["status"], expected_status)
                self.assertEqual(audit["failureKinds"], {"safeMiss": 1})

    def test_safe_miss_limit_still_fails_completed_event_run(self):
        self.assertEqual(self.invoke(
            event_suite, extra_args=["--max-safe-misses", "0"], safe_miss=True, returncode=1,
        ), 1)
        audit = json.loads(self.paths(event_suite)["audit"].read_text())
        self.assertEqual(audit["status"], "failed")
        self.assertFalse(audit["qualityPassed"])

    def test_input_error_invalidates_previous_audit_without_launching(self):
        for module in (event_suite, tsv_suite):
            with self.subTest(suite=module.__name__):
                self.seed_stale(module)
                contents = self.tsv.read_bytes()
                self.tsv.write_text("invalid columns\n")
                self.assertNotEqual(self.invoke(module), 0)
                self.assertEqual(json.loads(self.paths(module)["audit"].read_text())["status"], "invalidRun")
                self.assertEqual(self.commands, [])
                self.tsv.write_bytes(contents)

    def test_empty_corpus_is_not_a_successful_quality_check(self):
        contents = self.tsv.read_bytes()
        for module in (event_suite, tsv_suite):
            with self.subTest(suite=module.__name__):
                self.seed_stale(module)
                try:
                    self.tsv.write_text("wrong_input\texpected_output\ttoken_pattern\n")
                    self.assertNotEqual(self.invoke(module), 0)
                    audit = json.loads(self.paths(module)["audit"].read_text())
                    self.assertEqual(audit["status"], "invalidRun")
                finally:
                    self.tsv.write_bytes(contents)

    def test_custom_relative_outputs_are_resolved_before_runner_changes_directory(self):
        for module in (event_suite, tsv_suite):
            with self.subTest(suite=module.__name__):
                relative_root = Path(__import__("os").path.relpath(self.root))
                report = relative_root / module.__name__ / "report.json"
                audit = relative_root / module.__name__ / "audit.json"
                extra_args = ["--report", str(report), "--audit", str(audit)]
                results = relative_root / module.__name__ / "results.jsonl"
                if module is event_suite:
                    extra_args.extend(["--results", str(results)])
                self.assertEqual(self.invoke(module, extra_args=extra_args), 0)
                self.assertTrue(report.is_file())
                data = json.loads(audit.read_text())
                self.assertEqual(data["status"], "passed")
                self.assertTrue(Path(data["artifacts"]["report"]).is_absolute())
                if module is event_suite:
                    self.assertEqual(results.read_bytes(), Path(data["artifacts"]["results"]).read_bytes())

    def test_convert_corpus_remains_importable_by_file_path_without_script_path(self):
        script = Path(tsv_suite.__file__).resolve()
        spec = importlib.util.spec_from_file_location("standalone_corpus_import", script)
        module = importlib.util.module_from_spec(spec)
        with mock.patch.object(sys, "path", [
            entry for entry in sys.path if Path(entry).resolve() != script.parent
        ]), mock.patch.dict(sys.modules):
            sys.modules.pop("corpus_run_artifacts", None)
            spec.loader.exec_module(module)
        generated = self.root / "imported" / "phrases.jsonl"
        self.assertEqual(module.convert_corpus(self.tsv, generated), (2, ["en_correct", "ru_wrong"]))
        fixtures = [json.loads(line) for line in generated.read_text().splitlines()]
        self.assertEqual(fixtures[1]["steps"][0]["typed"], "ghbdtn")
        self.assertEqual(fixtures[1]["steps"][0]["expectedResolved"], "\u043f\u0440\u0438\u0432\u0435\u0442")

    def test_success_publishes_legacy_paths_and_keeps_run_specific_outputs(self):
        for module in (event_suite, tsv_suite):
            with self.subTest(suite=module.__name__):
                self.seed_stale(module)
                self.assertEqual(self.invoke(module), 0)
                paths = self.paths(module)
                first_audit = json.loads(paths["audit"].read_text())
                self.assertEqual(first_audit["status"], "passed")
                self.assertEqual(first_audit["tokenTotal"], 2)
                archived = {
                    key: (Path(path), Path(path).read_bytes())
                    for key, path in first_audit["artifacts"].items()
                }
                for key, path in paths.items():
                    self.assertEqual(path.read_bytes(), archived[key][1])
                self.assertEqual(self.invoke(module), 0)
                second_audit = json.loads(paths["audit"].read_text())
                self.assertNotEqual(first_audit["runId"], second_audit["runId"])
                for path, contents in archived.values():
                    self.assertEqual(path.read_bytes(), contents)
                for command in self.commands:
                    self.assertNotEqual(Path(command[command.index("--output") + 1]), paths["report"])


if __name__ == "__main__":
    unittest.main()
