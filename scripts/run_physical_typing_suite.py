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


def rolling_space_actions(actions, gap_microseconds=5_000):
    """Retain key hold times and ordinary cadence; roll the key after Space."""
    if not actions or type(gap_microseconds) is not int or gap_microseconds <= 0:
        raise ValueError("rolling-space gap must be a positive integer")
    result, held = [], {}
    previous_down = None
    for index, original in enumerate(actions):
        action = dict(original)
        kind, code = action["kind"], action.get("keyCode")
        if (kind not in ("keyDown", "keyUp") or code is None or action.get("autorepeat", False)
                or any(action.get(modifier, False) for modifier in ("command", "option", "control"))):
            raise ValueError("rolling-space profile supports balanced physical presses only")
        if kind == "keyDown":
            if code in held:
                raise ValueError("duplicate keyDown in rolling-space source")
            at = action["atMicroseconds"]
            if previous_down is not None:
                prior, prior_at = previous_down
                gap = at - prior["atMicroseconds"]
                if prior["keyCode"] == 49 and code != 49:
                    gap = min(gap, gap_microseconds)
                at = prior_at + gap
            held[code] = (action["atMicroseconds"], at)
            previous_down = (original, at)
        else:
            if code not in held:
                raise ValueError("unbalanced keyUp in rolling-space source")
            source_at, down_at = held.pop(code)
            at = down_at + action["atMicroseconds"] - source_at
        action["atMicroseconds"] = at
        result.append((index, action))
    if held:
        raise ValueError("unreleased key in rolling-space source")
    result.sort(key=lambda item: (item[1]["atMicroseconds"], item[0]))
    return [action for _, action in result], {old: new for new, (old, _) in enumerate(result)}


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

        rolling = json.loads((root / "Tests/Fixtures/Simulator/physical-auto-code-switch.json").read_text())
        rolling["stimulus"]["id"] += "-rolling-space"
        # Read-back may legitimately become stale when the next key is queued.
        # Still require exact text/layout/delivery and valid confirmation counts;
        # do not demand an acknowledgement while the token is no longer current.
        rolling["oracle"].pop("verifiedCompletions", None)
        rolling["stimulus"]["actions"], new_indices = rolling_space_actions(rolling["stimulus"]["actions"])
        # Reindex observations only. Neither oracle controls the physical cadence.
        for oracle in [rolling["oracle"], rolling["oracle"]["automaticOff"]]:
            for checkpoint in oracle["checkpoints"]:
                checkpoint["actionIndex"] = new_indices[checkpoint["actionIndex"]]
        rolling_path = directory / "rolling-space-input.json"
        rolling_path.write_text(json.dumps(rolling, ensure_ascii=False, indent=2) + "\n")
        run("rolling-space", rolling_path, 0, "passed")
        report = run("rolling-space-auto-off", rolling_path, 1, "failed", "auto-off")
        if (report["execution"]["text"] != rolling["oracle"]["automaticOff"]["text"]
                or report["execution"]["transactions"] != 0):
            raise ValueError("rolling-space auto-off did not match its independent literal oracle")

        # A bounded stress envelope, not a replay of macOS timing: 4 ms before
        # publication, 8 ms of synchronous post/layout work. Input still arrives
        # every scheduled timestamp, and editor delivery runs on another lane.
        busy = copy.deepcopy(rolling)
        busy["stimulus"]["timing"] = {"conversionPrePostMicroseconds": 4_000,
                                        "conversionPostWorkMicroseconds": 8_000,
                                        "deliveryDelayMicroseconds": 1_000,
                                        "syntheticEventIntervalMicroseconds": 50,
                                        "verificationReadDelayMicroseconds": 20_000}
        busy_path = directory / "queued-layout-input.json"
        busy_path.write_text(json.dumps(busy, ensure_ascii=False, indent=2) + "\n")
        fixed = run("queued-layout", busy_path, 0, "passed")
        old = run("queued-layout-old-behavior", busy_path, 1, "failed", "no-queued-layout-sync")
        waited = [row for row in fixed["execution"]["observations"]
                  if row["producedText"] and row["capturedLayoutID"] != row["layoutIDBefore"]]
        if not waited or "text-mismatch" not in old["assessment"]["failures"]:
            raise ValueError("queued-layout control did not expose the old-layout first letter")
        for row in waited:
            stale = old["execution"]["observations"][row["actionIndex"]]
            if (row["processedAtMicroseconds"] <= row["atMicroseconds"]
                    or row["capturedText"] == row["producedText"]
                    or row["deliveredText"] != row["producedText"]
                    or stale["deliveredText"] != row["capturedText"]):
                raise ValueError("queued key interpretation did not match the observed native failure class")
        if [row["atMicroseconds"] for row in fixed["execution"]["observations"]] != [
                action["atMicroseconds"] for action in busy["stimulus"]["actions"]]:
            raise ValueError("the callback lane slowed down the input producer")
        if fixed["execution"]["verifiedCompletions"] != 0:
            raise ValueError("new input acquired a stale confirmation")
        wrong_busy = copy.deepcopy(busy)
        wrong_busy["oracle"]["text"] = "intentionally wrong expected queued text"
        wrong_busy_path = directory / "queued-wrong-oracle-input.json"
        wrong_busy_path.write_text(json.dumps(wrong_busy, ensure_ascii=False, indent=2) + "\n")
        wrong_queued = run("queued-wrong-oracle", wrong_busy_path, 1, "failed")
        if wrong_queued["execution"] != fixed["execution"]:
            raise ValueError("oracle changed queued physical execution")
        unpriced = copy.deepcopy(busy)
        unpriced["stimulus"]["timing"] = {}
        unpriced_path = directory / "zero-work-input.json"
        unpriced_path.write_text(json.dumps(unpriced, ensure_ascii=False, indent=2) + "\n")
        run("zero-work-misses-queue-regression", unpriced_path, 0, "passed", "no-queued-layout-sync")
        literal = run("queued-layout-auto-off", busy_path, 1, "failed", "auto-off")
        if (literal["execution"]["text"] != busy["oracle"]["automaticOff"]["text"]
                or literal["execution"]["transactions"] != 0):
            raise ValueError("busy-lane auto-off changed the literal input")
        damaged = copy.deepcopy(busy)
        damaged["stimulus"]["timing"]["deliveryDelayMicroseconds"] = 30_000
        damaged_path = directory / "queued-late-delivery-input.json"
        damaged_path.write_text(json.dumps(damaged, ensure_ascii=False, indent=2) + "\n")
        late = run("queued-late-delivery-control", damaged_path, 1, "failed")
        if "text-mismatch" not in late["assessment"]["failures"] or late["execution"]["verifiedCompletions"] != 0:
            raise ValueError("the callback lane hid damage from genuinely late delivery")
        rolling["stimulus"]["timing"] = {"deliveryDelayMicroseconds": 4_000,
                                          "syntheticEventIntervalMicroseconds": 100}
        rolling_delayed = directory / "rolling-space-delayed-input.json"
        rolling_delayed.write_text(json.dumps(rolling, ensure_ascii=False, indent=2) + "\n")
        report = run("rolling-space-overlap-control", rolling_delayed, 1, "failed")
        if "text-mismatch" not in report["assessment"]["failures"] or report["execution"]["verifiedCompletions"] != 0:
            raise ValueError("rolling-space overlap was not detected as unverified text damage")

        # These are observed limitations, not release passes. A green harness
        # means the independent oracle detected each intentionally broken run.
        summary["modeledRuntimeLimitations"] = [
            {"issue": "delivery-can-overlap-next-user-word", "evidence": str(directory / "overlapping-delivery-control.json")},
            {"issue": "rolling-space-can-overlap-delivery", "evidence": str(directory / "rolling-space-overlap-control.json")},
            {"issue": "delivery-after-busy-callback-can-still-overlap-input", "evidence": str(directory / "queued-late-delivery-control.json")},
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

        # The decoder must actually propose a change; an ordinary dictionary
        # keep would not exercise the shared deletion safety guard.
        deletion_fixture = root / "Tests/Fixtures/Simulator/ambiguous-unicode-deletion.json"
        deletion_output = directory / "legacy-unicode-deletion-safety.json"
        subprocess.run([str(binary), "--input", str(deletion_fixture), "--output", str(deletion_output)],
                       cwd=root, stdout=subprocess.DEVNULL, check=True, timeout=60)
        report = json.loads(deletion_output.read_text())
        expected = json.loads(deletion_fixture.read_text())["expectedText"]
        last = report["traces"][-1]
        if (not report["passed"] or report["actualText"] != expected
                or report["transactionCount"] != 0
                or last["verdict"] != "switchToConverted"
                or last.get("blockedReason") != "ambiguous-deletion"
                or last["backspaceCount"] != 0
                or last["resolvedText"] != last["typedText"]):
            raise ValueError("ambiguous Unicode deletion was not safely refused after a decoder proposal")
        summary["checks"].append({"name": "legacy-unicode-deletion-safety", "status": "passed",
                                  "report": str(deletion_output)})
        summary["status"] = "passed"
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        summary["error"] = str(error)
    publish()
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["status"] == "passed" else 77 if summary["status"] == "blockedEnvironment" else 1


if __name__ == "__main__":
    sys.exit(main())
