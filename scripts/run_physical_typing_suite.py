#!/usr/bin/env python3
"""Physical-key CLI checks. No windows, keyboard injection or desktop settings."""

from __future__ import annotations

import hashlib
import json
import copy
from pathlib import Path
import subprocess
import sys
import tempfile

from corpus_run_artifacts import atomic_copy


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    parent = root / ".build" / "physical-runs"
    parent.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="closed-loop-", dir=parent))
    summary_path = directory / "suite.json"
    alias = root / ".build" / "physical-typing-suite-last.json"
    summary = {"status": "invalidRun", "runId": directory.name, "checks": []}

    def publish():
        summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
        atomic_copy(summary_path, alias)

    publish()
    try:
        with (directory / "build.log").open("w") as log:
            subprocess.run(["swift", "build", "-c", "release", "--product", "RuSwitcherTypingSimulator",
                            "-Xswiftc", "-warnings-as-errors"], cwd=root, stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=600)
        binary_directory = subprocess.check_output(
            ["swift", "build", "-c", "release", "--show-bin-path"], cwd=root, text=True
        ).strip()
        binary = Path(binary_directory) / "RuSwitcherTypingSimulator"
        summary["binarySHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        fixture_path = root / "Tests/Fixtures/Simulator/physical-closed-loop.json"

        def run(name, fixture, expected_exit, expected_status, fault=None):
            output = directory / (name + ".json")
            command = [str(binary), "--physical-input", str(fixture), "--output", str(output)]
            if fault:
                command += ["--fault", fault]
            process = subprocess.run(command, cwd=root, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.PIPE, text=True, timeout=60)
            report = json.loads(output.read_text())
            if name == "positive" and process.returncode == 77:
                summary["status"] = "blockedEnvironment"
                summary["error"] = report.get("error", "required layout unavailable")
                raise RuntimeError(summary["error"])
            if (process.returncode != expected_exit or report["status"] != expected_status
                    or report["passed"] != (expected_status == "passed")):
                raise ValueError(f"{name}: exit={process.returncode}, status={report['status']}; see {output}")
            summary["checks"].append({"name": name, "status": "passed", "observedStatus": report["status"],
                                      "report": str(output), "runID": report["runID"]})
            return report

        positive = run("positive", fixture_path, 0, "passed")
        for fault in ["auto-off", "no-layout-switch", "drop-insertion", "duplicate-insertion",
                      "drop-backspace", "reject-post", "preflight-unavailable"]:
            report = run(fault, fixture_path, 1, "failed", fault)
            if fault in ("drop-backspace", "duplicate-insertion"):
                if ("text-mismatch" not in report["assessment"]["failures"]
                        or report["execution"]["verifiedCompletions"] != 0):
                    raise ValueError("damaged text was not detected or acquired anchored confirmation")
            if fault == "no-layout-switch":
                if "checkpoint-layout-mismatch-16" not in report["assessment"]["failures"]:
                    raise ValueError("layout-switch control did not detect divergence at the next physical key")
                if report["execution"]["observations"][15]["textAfter"] != "сегодня ":
                    raise ValueError("control must successfully correct the first word before losing the layout switch")

        duplicate_ack = run("duplicate-acknowledgement", fixture_path, 0, "passed", "duplicate-acknowledgement")
        if duplicate_ack["execution"] != positive["execution"]:
            raise ValueError("a duplicate acknowledgement changed the execution")
        unavailable = run("verification-unavailable", fixture_path, 0, "passed", "verification-unavailable")
        if unavailable["execution"]["verifiedCompletions"] != 0:
            raise ValueError("unavailable verification was counted as confirmed")

        # Same continuous physical phrase, independent clocks. No per-word
        # sleep, language reset, or waiting for a conversion before typing on.
        profiles = [
            ("scheduled-normal", 1, {"deliveryDelayMicroseconds": 1_000,
                                     "syntheticEventIntervalMicroseconds": 50,
                                     "verificationReadDelayMicroseconds": 4_000,
                                     "acknowledgementDelayMicroseconds": 16_000}, 0),
            ("scheduled-fast-late-ack", 70, {"verificationReadDelayMicroseconds": 0,
                                           "acknowledgementDelayMicroseconds": 50_000}, 0),
            ("scheduled-read-timeout", 1, {"verificationReadDelayMicroseconds": 250_000}, 0),
            ("overlapping-delivery-control", 70, {"deliveryDelayMicroseconds": 16_000,
                                                  "syntheticEventIntervalMicroseconds": 100}, 1),
            ("late-layout-control", 70, {"layoutDelayMicroseconds": 16_000}, 1),
        ]
        base_fixture = json.loads(fixture_path.read_text())
        for name, speed, timing, expected_exit in profiles:
            fixture = copy.deepcopy(base_fixture)
            fixture["stimulus"]["timing"] = timing
            for action in fixture["stimulus"]["actions"]:
                action["atMicroseconds"] //= speed
            path = directory / (name + "-input.json")
            path.write_text(json.dumps(fixture))
            report = run(name, path, expected_exit, "passed" if expected_exit == 0 else "failed")
            if name in ("scheduled-fast-late-ack", "scheduled-read-timeout"):
                if report["execution"]["verifiedCompletions"] != 0:
                    raise ValueError(f"{name}: a stale or timed-out result acquired confirmation")
            if name == "scheduled-read-timeout":
                if not any(row["event"] == "readback-timeout" for row in report["execution"]["trace"]):
                    raise ValueError("the late reader did not actually hit its deadline")
            if name == "overlapping-delivery-control" and "text-mismatch" not in report["assessment"]["failures"]:
                raise ValueError("overlapping-delivery control must detect actual text damage")

        # These are observed limitations, not release passes. A green harness
        # means the independent oracle detected each intentionally broken run.
        summary["modeledRuntimeLimitations"] = [
            {"issue": "delivery-can-overlap-next-user-word", "evidence": str(directory / "overlapping-delivery-control.json")},
        ]
        summary["detectedUnrepairedDamage"] = [
            {"issue": "dropped-deletion-rejected-by-anchor", "evidence": str(directory / "drop-backspace.json")},
            {"issue": "duplicate-insertion-rejected-by-anchor", "evidence": str(directory / "duplicate-insertion.json")},
        ]

        fixture = json.loads(fixture_path.read_text())
        fixture["oracle"]["text"] = "intentionally wrong expected text"
        wrong = directory / "wrong-oracle-input.json"
        wrong.write_text(json.dumps(fixture))
        report = run("wrong-oracle", wrong, 1, "failed")
        if report["execution"] != positive["execution"]:
            raise ValueError("oracle changed the actual input execution")

        missing = directory / "absent-input.json"
        stale_report = directory / "missing-input.json"
        stale_report.write_text(json.dumps(positive))
        invalid = run("missing-input", missing, 70, "invalidRun")
        if invalid["runID"] == positive["runID"]:
            raise ValueError("missing input reused the old successful report")

        fixture = json.loads(fixture_path.read_text())
        fixture["stimulus"]["layoutIDs"][0] = "com.ruswitcher.nonexistent-test-layout"
        absent = directory / "missing-layout-input.json"
        absent.write_text(json.dumps(fixture))
        run("missing-layout", absent, 77, "blockedEnvironment")

        # Oracle mutation must not change even legacy text-mode input metadata.
        legacy = {"id": "legacy-oracle-isolation", "initialLanguage": "en", "steps": [
            {"typed": "ctujlyz", "separator": " ", "expected": "switch", "expectedResolved": "сегодня"},
            {"typed": "vs", "separator": " ", "expected": "switch", "expectedResolved": "мы"},
        ], "expectedText": "сегодня мы "}
        actual = []
        for name, verdict in [("legacy-a", "switch"), ("legacy-b", "keep")]:
            legacy["steps"][0]["expected"] = verdict
            path = directory / (name + ".jsonl")
            path.write_text(json.dumps(legacy) + "\n")
            result_path = directory / (name + "-results.jsonl")
            process = subprocess.run([str(binary), "--phrase-input", str(path), "--results", str(result_path)],
                                     stdout=subprocess.DEVNULL, check=False, timeout=60)
            if process.returncode not in (0, 1):
                raise ValueError("legacy oracle-isolation run failed to execute")
            row = json.loads(result_path.read_text())
            actual.append((row["actualText"], row["traces"], row["transactionCount"]))
        if actual[0] != actual[1]:
            raise ValueError("legacy oracle verdict changed input language or decisions")
        summary["checks"].append({"name": "legacy-oracle-isolation", "status": "passed"})
        summary["status"] = "passed"
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        summary["error"] = str(error)
    publish()
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["status"] == "passed" else 77 if summary["status"] == "blockedEnvironment" else 1


if __name__ == "__main__":
    sys.exit(main())
