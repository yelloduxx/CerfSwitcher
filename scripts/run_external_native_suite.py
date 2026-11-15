#!/usr/bin/env python3
"""Separate app/editor/driver processes. Default is blocked; never steal focus implicitly."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_digest(root):
    paths = [root / name for name in ("Package.swift", "Info.plist", "version.json", "RuSwitcher.entitlements",
                                      "scripts/run_external_native_suite.py", "scripts/build_test_host.sh",
                                      "scripts/ruswitch_test_app.sh")]
    for directory in ("Sources", "Tests/Support", "Tests/NativeDriver", "Tests/NativeEditorHost"):
        paths += [p for p in (root / directory).rglob("*") if p.is_file()]
    value = hashlib.sha256()
    for path in sorted(paths):
        value.update(str(path.relative_to(root)).encode())
        value.update(bytes.fromhex(digest(path)))
    return value.hexdigest()


INSTALLED_APP = Path("/Applications/CerfSwitcher.app")
INSTALLED_BINARY = INSTALLED_APP / "Contents/MacOS/CerfSwitcher"
TEST_PRODUCT = "CerfSwitcherTestHost"
TEST_BUNDLE_ID = "com.cerfswitcher.testhost"


def running_switchers():
    output = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    rows = []
    for line in output.splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) == 2 and any(name in Path(parts[1]).name for name in ("RuSwitcher", "CerfSwitcher")):
            rows.append((int(parts[0]), parts[1]))
    return rows


def restore_installed(expected_hash):
    if digest(INSTALLED_BINARY) != expected_hash:
        raise RuntimeError("installed binary changed during the test; cannot verify restoration")
    subprocess.run(["open", str(INSTALLED_APP)], check=True, timeout=10)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        for pid, path in running_switchers():
            if path == str(INSTALLED_BINARY):
                return dict(pid=pid, sha256=expected_hash, verified=True)
        time.sleep(0.1)
    raise RuntimeError("installed Cerf Switcher did not restart")


def write_json(path, data):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".new")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def archive_run(root, runtime, summary):
    destination = root / ".build/native-runs" / summary["runID"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Never merge with previous evidence, even if a run ID is accidentally reused.
    destination.mkdir()
    try:
        shutil.copytree(runtime, destination, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("*.app", "summary.json"))
        archived = dict(summary, artifactDirectory=str(destination))
        archived["cases"] = [dict(case, artifactDirectory=str(destination / Path(case["directory"]).name))
                             for case in summary["cases"]]
        # Publish completion last; an incomplete archive cannot contain a passed summary.
        write_json(destination / "summary.json", archived)
        return archived
    except BaseException:
        shutil.rmtree(destination)
        raise


def read_state(path, run_id, schema_version=1):
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    if (not isinstance(data, dict) or type(data.get("schemaVersion")) is not int
            or data["schemaVersion"] != schema_version or str(data.get("runID", "")).lower() != run_id.lower()):
        raise ValueError(f"foreign/stale state: {Path(path).name}")
    return data


class BlockedEnvironment(RuntimeError):
    pass


def assess(fixture, host, app, driver, pids, automatic, input_marker, *, editor="nstextview", manual=False):
    if not all(isinstance(value, dict) for value in (host, app, driver)):
        return ["malformed-native-evidence"]
    integer_fields = [(host, "pid"), (host, "unexpectedInputCount"), (app, "pid"), (app, "posted"),
                      (app, "verified"), (app, "targetProcessID"), (driver, "pid"), (driver, "maximumLatenessMicroseconds")]
    if (any(type(value.get(key)) is not int for value, key in integer_fields)
            or type(host.get("text")) is not str or type(host.get("selection")) is not list
            or len(host["selection"]) != 2 or any(type(x) is not int for x in host["selection"])
            or type(app.get("automaticConversion")) is not bool or type(app.get("modelAvailable")) is not bool
            or type(app.get("callbackTimingOverflow")) is not bool
            or type(driver.get("restoredLayout")) is not bool
            or type(host.get("eventTrace")) is not list or type(host.get("receivedEvents")) is not list
            or type(host.get("quartzEvents")) is not list
            or type(host.get("quartzTapAvailable")) is not bool or type(host.get("quartzTapInterrupted")) is not bool
            or type(driver.get("records")) is not list
            or not all(isinstance(x, dict) for x in host["eventTrace"] + host["receivedEvents"]
                       + host["quartzEvents"] + driver["records"])):
        return ["malformed-native-evidence"]
    failures = []
    if host.get("editorKind", "nstextview") != editor:
        failures.append("editor-kind-mismatch")
    if editor == "webkit":
        failures += dom_evidence_failures(host, initial=fixture.get("editorSetup") if manual else None, manual=manual)
    if not host["quartzTapAvailable"]:
        failures.append("quartz-observation-unavailable")
    if host["quartzTapInterrupted"]:
        failures.append("quartz-observation-interrupted")
    for data, name, pid in [(host, "host", pids[0]), (app, "app", pids[1]), (driver, "driver", pids[2])]:
        if data.get("pid") != pid or data.get("status") != "complete":
            failures.append(name + "-not-complete")
    if len(set(pids)) != 3:
        failures.append("processes-not-independent")
    if app.get("targetProcessID") != host.get("pid"):
        failures.append("app-target-mismatch")
    if host.get("unexpectedInputCount") != 0:
        failures.append("external-interference")
    oracle = fixture["oracle"]
    if host.get("text") != oracle["text"]:
        failures.append("text-mismatch")
    expected_caret = len(oracle["text"].encode("utf-16-le")) // 2
    if host.get("selection") != oracle.get("selectedRange", [expected_caret, 0]):
        failures.append("selection-mismatch")
    if driver.get("finalLayoutID") != oracle["finalLayoutID"]:
        failures.append("layout-mismatch")
    if not driver.get("restoredLayout"):
        failures.append("layout-not-restored")
    if app.get("automaticConversion") is not automatic or not app.get("modelAvailable"):
        failures.append("app-configuration-mismatch")
    expected_verified = oracle.get("verifiedCompletions")
    if expected_verified is not None and (type(expected_verified) is not int or expected_verified < 0):
        return ["invalid-oracle-verification-count"]
    if (app["posted"] != oracle["transactions"] or not 0 <= app["verified"] <= app["posted"]
            or (expected_verified is not None and app["verified"] != expected_verified)):
        failures.append("transaction-count-mismatch")
    actions = fixture["stimulus"]["actions"]
    records = driver.get("records", [])
    if [x.get("actionIndex") for x in records] != list(range(len(actions))):
        failures.append("incomplete-input-trace")
    if any(x.get("postedNanoseconds", 0) < x.get("plannedNanoseconds", 0) for x in records):
        failures.append("invalid-driver-timestamps")
    maximum_lateness = 25_000 if manual else 10_000
    if not 0 <= driver["maximumLatenessMicroseconds"] <= maximum_lateness:
        failures.append("input-schedule-too-late")
    for checkpoint in oracle.get("checkpoints", []):
        index = checkpoint["actionIndex"]
        # A press may wait behind an active callback. The producer's earlier
        # source snapshot is diagnostic, not the layout used to process that key.
        if index < len(actions) and actions[index]["kind"] == "keyDown":
            timings = app.get("callbackTimings", [])
            observed = next((row.get("sourceLayoutID") for row in timings
                             if isinstance(row, dict) and row.get("actionIndex") == index), None) if isinstance(timings, list) else None
        else:
            observed = records[index].get("layoutID") if index < len(records) else None
        if observed != checkpoint["layoutIDBefore"]:
            failures.append("layout-checkpoint-mismatch")
    if manual:
        failures += manual_delivery_failures(actions, host, app, input_marker)
        failures += manual_checkpoint_failures(fixture, host, app, driver)
    else:
        failures += callback_timing_failures(actions, app, host, input_marker)
        failures += input_delivery_failures(actions, host["receivedEvents"], app["posted"], input_marker)
        failures += ["quartz-" + failure for failure in
                     input_delivery_failures(actions, host["quartzEvents"], app["posted"], input_marker)]
    return failures


def manual_delivery_failures(actions, host, app, input_marker):
    failures = []
    event_indices = [i for i, action in enumerate(actions) if action["kind"] in ("keyDown", "keyUp", "flagsChanged")]
    callbacks = [i for i in event_indices if actions[i]["kind"] != "keyUp"]
    timings = app.get("callbackTimings")
    if (not valid_callback_timings(timings) or app["callbackTimingOverflow"]
            or [row["actionIndex"] for row in timings] != callbacks):
        failures.append("manual-callback-sequence-mismatch")
    elif any(row["consumed"] or row["keyCode"] != actions[i]["keyCode"]
             or row.get("eventKind") != actions[i]["kind"] for i, row in zip(callbacks, timings)):
        failures.append("manual-callback-event-mismatch")
    for layer in ("receivedEvents", "quartzEvents"):
        events = [row for row in host[layer] if type(row.get("marker")) is int
                  and input_marker < row["marker"] <= input_marker + 10_000]
        if [row["marker"] - input_marker - 1 for row in events] != event_indices:
            failures.append("manual-" + layer + "-sequence-mismatch")
            continue
        for index, event in zip(event_indices, events):
            action = actions[index]
            if (event.get("kind") != action["kind"] or event.get("keyCode") != action["keyCode"]
                    or (action["kind"] == "flagsChanged" and event.get("shift") is not action["shift"])):
                failures.append("manual-" + layer + "-event-mismatch")
                break
    return failures


def manual_checkpoint_failures(fixture, host, app, driver):
    failures = []
    expected = fixture["oracle"]["manualCheckpoints"]
    actions = fixture["stimulus"]["actions"]
    indices = [i for i, action in enumerate(actions) if action["kind"] == "checkpoint"]
    records = driver["records"]
    if app.get("manualMode") is not True:
        failures.append("manual-mode-mismatch")
    if type(host.get("clipboardChangeCountDelta")) is not int or host["clipboardChangeCountDelta"] != 0:
        failures.append("manual-clipboard-changed")
    for data, source in ((host, "host"), (app, "app")):
        rows = data.get("manualCheckpoints")
        if (not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows)
                or [row.get("actionIndex") for row in rows] != indices or len(rows) != len(expected)):
            failures.append("manual-" + source + "-checkpoints-incomplete")
            continue
        for row, oracle, index in zip(rows, expected, indices):
            if row.get("id") != oracle["id"] or row.get("runID") != data.get("runID"):
                failures.append("manual-checkpoint-identity-mismatch")
            requested, captured = row.get("requestNanoseconds"), row.get("atNanoseconds")
            if (type(requested) is not int or type(captured) is not int or index >= len(records)
                    or not records[index].get("plannedNanoseconds", 2**64) <= requested <= records[index].get("postedNanoseconds", -1)
                    or not requested <= captured <= requested + 400_000_000
                    or (index + 1 < len(records) and captured >= records[index + 1].get("plannedNanoseconds", 0))):
                failures.append("manual-checkpoint-stale")
            if index >= len(records) or records[index].get("layoutID") != oracle["layoutID"]:
                failures.append("manual-checkpoint-layout-mismatch")
            if source == "host":
                if row.get("text") != oracle["text"]:
                    failures.append("manual-checkpoint-text-mismatch")
                if (row.get("selection") != oracle["selection"] or not isinstance(row.get("selection"), list)
                        or any(type(n) is not int for n in row["selection"])):
                    failures.append("manual-checkpoint-selection-mismatch")
                if row.get("focused") is not True:
                    failures.append("manual-checkpoint-unfocused")
                if host.get("editorKind", "nstextview") == "nstextview":
                    if (type(row.get("forcedAXCollapseCount")) is not int
                            or row["forcedAXCollapseCount"] < oracle.get("minimumAXCollapseCount", 0)):
                        failures.append("manual-ax-collapse-not-observed")
                else:
                    dom_sequence = row.get("domSequence")
                    events = host.get("domEvents", [])
                    if row.get("domReadVerified") is not True:
                        failures.append("manual-dom-read-unverified")
                    if (not isinstance(events, list) or type(dom_sequence) is not int
                            or not 0 <= dom_sequence < len(events) or not isinstance(events[dom_sequence], dict)):
                        failures.append("manual-dom-checkpoint-mismatch")
                    else:
                        state = events[dom_sequence].get("state", {})
                        if (not isinstance(state, dict) or state.get("text") != row.get("text") or state.get("selection") != row.get("selection")
                                or state.get("focused") is not True):
                            failures.append("manual-dom-checkpoint-mismatch")
                if type(row.get("clipboardChangeCountDelta")) is not int or row["clipboardChangeCountDelta"] != 0:
                    failures.append("manual-clipboard-changed")
            else:
                for key in ("attemptCount", "confirmedRuleCount", "applicationExceptionCount", "learnedEntryCount"):
                    if type(row.get(key)) is not int or row[key] != oracle[key]:
                        failures.append("manual-" + key + "-mismatch")
                if row.get("feedback") != oracle["feedback"]:
                    failures.append("manual-feedback-mismatch")
                if row.get("learningUndoAvailable") is not oracle["learningUndoAvailable"]:
                    failures.append("manual-learning-visibility-mismatch")
    return list(dict.fromkeys(failures))


def validate_manual_fixture(fixture):
    cases = fixture.get("manualCases")
    names = ("current-token", "completed-token", "selected-multiword")
    if not isinstance(cases, list) or len(cases) != 3 or [case.get("id") for case in cases] != list(names):
        raise ValueError("manual fixture requires current-token, completed-token and selected-multiword cases")
    for case in cases:
        actions = case["stimulus"]["actions"]
        setup = case["editorSetup"]
        oracle = case["oracle"]
        checkpoints = oracle["manualCheckpoints"]
        flags = [action for action in actions if action["kind"] == "flagsChanged"]
        observations = [action for action in actions if action["kind"] == "checkpoint"]
        selection = setup["selection"]
        if (not 1 <= len(actions) <= 256 or len(flags) != 8 or len(observations) != 3
                or [action["id"] for action in observations] != [row["id"] for row in checkpoints]
                or len(checkpoints) != 3 or [row["attemptCount"] for row in checkpoints] != [0, 1, 2]
                or len(selection) != 2 or any(type(n) is not int or n < 0 for n in selection)
                or sum(selection) > len(setup["text"].encode("utf-16-le")) // 2
                or actions[-1]["atMicroseconds"] > 5_000_000 or oracle["transactions"] != 0):
            raise ValueError("manual case must contain two bounded toggles and three independent checkpoints")
        if checkpoints[0]["text"] == checkpoints[1]["text"] or checkpoints[0]["text"] != checkpoints[2]["text"]:
            raise ValueError("manual oracle must detect a no-op on the first toggle and restore the second")
        if oracle["text"] != checkpoints[-1]["text"] or oracle["selectedRange"] != checkpoints[-1]["selection"]:
            raise ValueError("manual final oracle disagrees with its last checkpoint")
        first = next(i for i, action in enumerate(actions) if action["kind"] == "checkpoint")
        if any(action["kind"] not in ("flagsChanged", "checkpoint") for action in actions[first + 1:]):
            raise ValueError("manual toggles must not reselect, type or force layouts between checkpoints")
        for position, row in enumerate(checkpoints):
            index = next(i for i, action in enumerate(actions) if action.get("id") == row["id"])
            if sum(action["kind"] == "flagsChanged" for action in actions[:index]) != position * 4:
                raise ValueError("each toggle requires its own post-gesture checkpoint")
        control = oracle.get("manualDisabled")
        if (not isinstance(control, dict) or control.get("transactions") != 0
                or len(control.get("manualCheckpoints", [])) != 3
                or any(row["text"] != checkpoints[0]["text"] for row in control["manualCheckpoints"])
                or control["manualCheckpoints"][1]["feedback"] != "refused(disabled)"):
            raise ValueError("manual fixture needs an independent disabled-trigger oracle")
    return cases


def dom_evidence_failures(host, *, initial=None, manual=False):
    failures = [] if host.get("domFinalReadVerified") is True else ["dom-final-read-unverified"]
    events = host.get("domEvents")
    if not isinstance(events, list) or not events:
        return failures + ["dom-input-missing"]
    previous_sequence = -1
    for row in events:
        state = row.get("state") if isinstance(row, dict) else None
        if (not isinstance(state, dict) or type(state.get("sequence")) is not int
                or state["sequence"] != previous_sequence + 1
                or type(state.get("text")) is not str or type(state.get("selection")) is not list
                or len(state["selection"]) != 2 or any(type(n) is not int or n < 0 for n in state["selection"])
                or sum(state["selection"]) > len(state["text"].encode("utf-16-le")) // 2
                or type(state.get("focused")) is not bool
                or row.get("event") not in ("ready", "keydown", "keyup", "input", "selectionchange")):
            return failures + ["dom-evidence-invalid"]
        previous_sequence = state["sequence"]
        if row.get("trusted") is not True:
            failures.append("dom-untrusted-event")
    initial = initial or dict(text="", selection=[0, 0])
    if (events[0]["event"] != "ready" or events[0]["state"]["text"] != initial["text"]
            or events[0]["state"]["selection"] != initial["selection"]):
        failures.append("dom-initial-state-invalid")
    if not any(row["event"] == "input" for row in events):
        failures.append("dom-input-missing")
    for dom_kind, native_kind in (("keydown", "keyDown"), ("keyup", "keyUp")):
        expected = sum(row.get("kind") == native_kind for row in host["receivedEvents"])
        if manual:
            expected += sum(row.get("kind") == "flagsChanged" and row.get("shift") is (dom_kind == "keydown")
                            for row in host["receivedEvents"])
        if sum(row["event"] == dom_kind for row in events) != expected:
            failures.append("dom-" + dom_kind + "-count-mismatch")
    if manual:
        expected_shifts = [("keydown" if row["shift"] else "keyup", "ShiftLeft" if row["keyCode"] == 56 else "ShiftRight")
                           for row in host["receivedEvents"] if row.get("kind") == "flagsChanged"
                           and row.get("keyCode") in (56, 60) and type(row.get("shift")) is bool]
        shifts = [(row["event"], row.get("code")) for row in events if row.get("key") == "Shift"]
        if shifts != expected_shifts:
            failures.append("dom-shift-sequence-mismatch")
    state = events[-1]["state"]
    if state["text"] != host["text"] or state["selection"] != host["selection"] or not state["focused"]:
        failures.append("dom-snapshot-mismatch")
    return failures


def valid_callback_timings(timings):
    return (isinstance(timings, list) and all(
        isinstance(row, dict) and type(row.get("consumed")) is bool
        and all(type(row.get(key)) is int and 0 <= row[key] <= 2**64 - 1
                for key in ("actionIndex", "keyCode", "startedNanoseconds", "finishedNanoseconds"))
        and row["finishedNanoseconds"] >= row["startedNanoseconds"] for row in timings))


def callback_timing_failures(actions, app, host, input_marker):
    timings = app.get("callbackTimings")
    failures = ["callback-timing-overflow"] if app["callbackTimingOverflow"] else []
    if not valid_callback_timings(timings):
        return failures + ["callback-timing-invalid"]
    expected = [i for i, action in enumerate(actions) if action["kind"] == "keyDown"]
    if ([row["actionIndex"] for row in timings] != expected
            or any(row["actionIndex"] >= len(actions)
                   or actions[row["actionIndex"]].get("keyCode") != row["keyCode"] for row in timings)):
        failures.append("callback-input-sequence-mismatch")
    consumed = {row["actionIndex"] for row in timings if row["consumed"]}
    for layer in ("receivedEvents", "quartzEvents"):
        delivered = {e["marker"] - input_marker - 1 for e in host[layer]
                     if e.get("kind") == "keyDown" and type(e.get("marker")) is int
                     and input_marker < e["marker"] <= input_marker + 10_000}
        if consumed != set(expected) - delivered:
            failures.append("callback-consumption-mismatch")
            break
    return failures


def callback_timing_diagnostics(app):
    timings = app.get("callbackTimings")
    if not valid_callback_timings(timings):
        return dict(valid=False)
    durations = [row["finishedNanoseconds"] - row["startedNanoseconds"] for row in timings]
    consumed = [duration for row, duration in zip(timings, durations) if row["consumed"]]
    return dict(valid=True, samples=len(timings), overflow=app.get("callbackTimingOverflow"),
                scope="after-marker-guards-before-observer",
                maximumMicroseconds=max(durations) / 1_000 if durations else None,
                consumedMaximumMicroseconds=max(consumed) / 1_000 if consumed else None)


def input_delivery_failures(actions, events, posted_count, input_marker):
    failures = []
    inputs = [e for e in events if type(e.get("marker")) is int and input_marker < e["marker"] <= input_marker + 10_000]
    downs = sum(e.get("kind") == "keyDown" for e in inputs)
    ups = sum(e.get("kind") == "keyUp" for e in inputs)
    if downs != sum(a["kind"] == "keyDown" for a in actions) - posted_count:
        failures.append("delivered-keydown-count-mismatch")
    if ups != sum(a["kind"] == "keyUp" for a in actions):
        failures.append("delivered-keyup-count-mismatch")
    indices = [e["marker"] - input_marker - 1 for e in inputs]
    valid_sequence = indices == sorted(set(indices))
    for event, index in zip(inputs, indices):
        if (index >= len(actions) or event.get("kind") != actions[index]["kind"]
                or type(event.get("keyCode")) is not int or event["keyCode"] != actions[index].get("keyCode")):
            valid_sequence = False
    delivered = set(indices)
    missing = [a for index, a in enumerate(actions) if a["kind"] in ("keyDown", "keyUp") and index not in delivered]
    # Only a consumed conversion boundary may be absent from the editor stream.
    # Every other event retains its unique action index, including repeated keys.
    if (not valid_sequence or len(missing) != posted_count
            or any(a["kind"] != "keyDown" or a.get("keyCode") not in (36, 48, 49) for a in missing)):
        failures.append("input-delivery-sequence-mismatch")
    return failures


def delivery_diagnostics(fixture, host, input_marker):
    releases = {i for i, action in enumerate(fixture["stimulus"]["actions"]) if action["kind"] == "keyUp"}

    def observed(field):
        events = host.get(field, [])
        if not isinstance(events, list):
            return set()
        return {event["marker"] - input_marker - 1 for event in events
                if isinstance(event, dict) and event.get("kind") == "keyUp" and type(event.get("marker")) is int
                and event["marker"] - input_marker - 1 in releases}

    quartz, appkit, responder = (observed(field) for field in ("quartzEvents", "receivedEvents", "eventTrace"))
    complete = (host.get("quartzTapAvailable") is True and host.get("quartzTapInterrupted") is False
                and host.get("status") == "complete" and isinstance(host.get("quartzEvents"), list)
                and all(isinstance(event, dict) for event in host["quartzEvents"]))
    # Absence is not upstream-loss proof: even a complete observer is only one
    # point in the route. These labels locate observations, not a root cause.
    return dict(observationComplete=complete,
                unobservedReleaseActionsAtQuartz=sorted(releases - quartz),
                releaseActionsMissingAtAppKit=sorted(quartz - appkit),
                releaseActionsNotHandled=sorted(appkit - responder) if host.get("editorKind", "nstextview") == "nstextview" else None,
                responderObservation="webkit-dom" if host.get("editorKind") == "webkit" else "nstextview-dispatch")


def case_accepted(result, automatic):
    if automatic:
        return result.get("passed") is True and result.get("failures") == []
    # A negative control must fail the normal oracle AND exactly match the
    # independent auto-off oracle. Missing input is not evidence of detection.
    return (result.get("passed") is False and "text-mismatch" in result.get("failures", [])
            and result.get("controlFailures") == [])


def bundle(binary, root, name, identifier, app_info=None, *, display_name=None):
    app = root / (name + ".app")
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    executable = contents / "MacOS" / name
    shutil.copy2(binary, executable)
    info = dict(app_info or {})
    info.update(CFBundleIdentifier=identifier, CFBundleExecutable=name, CFBundleName=display_name or name,
                CFBundlePackageType="APPL", CFBundleVersion=str(info.get("CFBundleVersion", "1")),
                CFBundleShortVersionString=info.get("CFBundleShortVersionString", "1.0"),
                NSPrincipalClass="NSApplication", LSMinimumSystemVersion="13.0")
    if display_name is not None:
        info["CFBundleDisplayName"] = display_name
    with (contents / "Info.plist").open("wb") as output:
        plistlib.dump(info, output)
    return app, executable


def terminate_owned(processes):
    for process in reversed(processes):
        if process.poll() is None:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)


def run_case(root, fixture, executables, automatic, *, sample_process=False, editor="nstextview",
             manual=False, manual_enabled=True, interaction_assessor=None):
    root.mkdir()
    run_id = str(uuid.uuid4())
    input_marker = 0x5253544500000000 | (uuid.uuid4().int & 0xFFFFFFFF)
    config = dict(runID=run_id, layoutIDs=fixture["stimulus"]["layoutIDs"], automaticConversion=automatic,
                  inputMarker=input_marker, replacementMarker=0x52555300, timeoutSeconds=45)
    if "neverConvertWords" in fixture:
        config["neverConvertWords"] = fixture["neverConvertWords"]
    write_json(root / "session.json", config)
    write_json(root / "stimulus.json", fixture["stimulus"])
    if manual:
        write_json(root / "editor-setup.json", fixture["editorSetup"])
    processes, logs = [], []
    env = dict(os.environ, RUSWITCH_ALLOW_FOCUS_STEALING="1")

    def launch(binary, arguments, name):
        log = (root / (name + ".log")).open("w")
        logs.append(log)
        process = subprocess.Popen([str(binary), *arguments], env=env, stdout=log, stderr=subprocess.STDOUT)
        processes.append(process)
        return process

    try:
        host_arguments = ["--session", str(root / "session.json"), "--editor", editor]
        if manual:
            host_arguments += ["--editor-setup", str(root / "editor-setup.json")]
        host = launch(executables[1], host_arguments, "host")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = read_state(root / "host-state.json", run_id, schema_version=2)
            if state and state.get("active") and state.get("keyWindow"):
                break
            if host.poll() is not None:
                if host.returncode == 77:
                    raise BlockedEnvironment("host cannot install process-scoped Quartz observation")
                raise RuntimeError("host exited before ready")
            time.sleep(0.02)
        else:
            raise BlockedEnvironment("host did not acquire focus")
        app_arguments = ["--external-native-probe", run_id, str(root / "session.json"), "--host-pid", str(host.pid)]
        if manual:
            app_arguments += ["--manual-toggle"] + ([] if manual_enabled else ["--manual-disabled"])
        app = launch(executables[0], app_arguments, "app")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = read_state(root / "app-state.json", run_id, schema_version=2)
            if state and state.get("tapEnabled") and state.get("modelAvailable"):
                break
            if app.poll() is not None:
                if app.returncode == 77:
                    raise BlockedEnvironment("app lacks Accessibility/Input Monitoring or posting access")
                raise RuntimeError(f"app exited before ready: {app.returncode}")
            time.sleep(0.02)
        else:
            raise BlockedEnvironment("app did not acquire a live event tap")
        (root / "record").touch()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            state = read_state(root / "host-state.json", run_id, schema_version=2)
            if state and state.get("status") == "recording":
                break
            time.sleep(0.02)
        else:
            raise RuntimeError("host did not start recording")
        sampler = None
        if sample_process:
            # This samples only the owned probe, not the installed app or editor.
            # Functional results remain useful; timings under sampling are diagnostic.
            sampler = launch("/usr/bin/sample", [str(app.pid), "6", "1", "-mayDie",
                                                 "-file", str(root / "app-sample.txt")], "sampler")
        driver = launch(executables[2], ["--session", str(root / "session.json"), "--stimulus", str(root / "stimulus.json"),
                                         "--host-pid", str(host.pid)] + (["--interaction"] if interaction_assessor else
                                                                          ["--manual-toggle"] if manual else []), "driver")
        deadline = time.monotonic() + config["timeoutSeconds"]
        while driver.poll() is None and time.monotonic() < deadline:
            state = read_state(root / "host-state.json", run_id, schema_version=2)
            if (state and state.get("status") == "interrupted") or app.poll() is not None or host.poll() is not None:
                raise RuntimeError("native run interrupted")
            time.sleep(0.02)
        if driver.poll() is None:
            raise RuntimeError("driver deadline exceeded")
        if sampler is not None:
            sampler.wait(timeout=10)
            if sampler.returncode != 0 or not (root / "app-sample.txt").is_file():
                raise RuntimeError("native process sampling failed; no timing conclusion")
        (root / "stop").touch()
        app.wait(timeout=3)
        host.wait(timeout=3)
        if any(p.returncode != 0 for p in (app, host, driver)):
            if any(p.returncode == 77 for p in (app, host, driver)):
                raise BlockedEnvironment("native process lacks required access or enabled layout")
            raise RuntimeError(f"native process exits: {[p.returncode for p in (app, host, driver)]}")
        host_result = read_state(root / "host-result.json", run_id, schema_version=2)
        app_result = read_state(root / "app-result.json", run_id, schema_version=2)
        driver_result = read_state(root / "driver-result.json", run_id)
        if not all([host_result, app_result, driver_result]):
            raise RuntimeError("missing final native result")
        assessor = interaction_assessor or assess
        failures = assessor(fixture, host_result, app_result, driver_result,
                          [host.pid, app.pid, driver.pid], automatic, input_marker, editor=editor, manual=manual)
        control_failures = None
        if interaction_assessor is None and ((manual and not manual_enabled) or (not manual and not automatic)):
            control_fixture = dict(fixture, oracle=fixture["oracle"]["manualDisabled" if manual else "automaticOff"])
            control_failures = assess(control_fixture, host_result, app_result, driver_result,
                                     [host.pid, app.pid, driver.pid], False, input_marker, editor=editor, manual=manual)
        result = dict(runID=run_id, automaticConversion=automatic, failures=failures,
                      controlFailures=control_failures, passed=not failures, directory=str(root),
                      deliveryDiagnostics=delivery_diagnostics(fixture, host_result, input_marker),
                      callbackTiming=callback_timing_diagnostics(app_result),
                      sampled=sample_process, editorKind=editor,
                      manualMode=manual, manualEnabled=manual_enabled if manual else None,
                      timingUse="diagnostic-under-sampling" if sample_process else "unprofiled-observations")
        write_json(root / "assessment.json", result)
        return result
    finally:
        (root / "stop").touch()
        terminate_owned(processes)
        for log in logs:
            log.close()
        subprocess.run(["defaults", "delete", "com.ruswitcher.nativeprobe." + run_id],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def run_cases(directory, fixture, executables, summary, *, sample_process=False, editor="nstextview", manual=False):
    accepted = True
    quality_failures = {"text-mismatch", "selection-mismatch", "layout-mismatch", "layout-checkpoint-mismatch",
                        "transaction-count-mismatch", "delivered-keydown-count-mismatch",
                        "delivered-keyup-count-mismatch", "input-delivery-sequence-mismatch",
                        "quartz-delivered-keydown-count-mismatch", "quartz-delivered-keyup-count-mismatch",
                        "quartz-input-delivery-sequence-mismatch", "callback-input-sequence-mismatch",
                        "callback-consumption-mismatch"}
    if manual:
        cases = validate_manual_fixture(fixture)
        matrix = [(case["id"], case, True) for case in cases] + [("manual-disabled-control", cases[0], False)]
        quality_failures |= {
            "manual-checkpoint-text-mismatch", "manual-checkpoint-selection-mismatch", "manual-checkpoint-layout-mismatch",
            "manual-feedback-mismatch", "manual-learning-visibility-mismatch", "manual-attemptCount-mismatch",
            "manual-confirmedRuleCount-mismatch", "manual-applicationExceptionCount-mismatch", "manual-learnedEntryCount-mismatch",
            "manual-callback-sequence-mismatch", "manual-callback-event-mismatch",
            "manual-receivedEvents-sequence-mismatch", "manual-receivedEvents-event-mismatch",
            "manual-quartzEvents-sequence-mismatch", "manual-quartzEvents-event-mismatch", "manual-clipboard-changed",
            "manual-ax-collapse-not-observed",
        }
    else:
        matrix = [("positive", fixture, True), ("auto-off-control", fixture, False)]
    for name, case, enabled in matrix:
        options = dict(sample_process=sample_process and enabled, editor=editor)
        if manual:
            options.update(manual=True, manual_enabled=enabled)
        result = run_case(directory / name, case, executables, enabled and not manual, **options)
        summary["cases"].append(result)
        if set(result["failures"]) - quality_failures:
            raise RuntimeError("native run interrupted or evidence invalid; no further window opened")
        if manual and not enabled:
            valid = (result.get("passed") is False and "manual-checkpoint-text-mismatch" in result.get("failures", [])
                     and result.get("controlFailures") == [])
        else:
            valid = case_accepted(result, enabled)
        if not valid:
            accepted = False
            summary.setdefault("qualityFailures", []).append(name)
    return accepted


def main(argv=None, *, root=None):
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare-only", action="store_true")
    mode.add_argument("--preflight-only", action="store_true",
                      help="Build/sign and read access flags only; never open an editor, stop an app or post events")
    parser.add_argument("--restart-installed-pro", action="store_true",
                        help="Explicitly permit quitting and restoring only /Applications/CerfSwitcher.app")
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--manual-toggle", action="store_true",
                        help="Three bounded manual toggle cases and one disabled-trigger control")
    parser.add_argument("--editor", choices=("nstextview", "webkit"), default="nstextview")
    parser.add_argument("--sample-process", action="store_true",
                        help="Collect a six-second stack sample of the owned positive-case app; not a latency acceptance run")
    args = parser.parse_args(argv)
    if args.sample_process and (args.prepare_only or args.preflight_only):
        parser.error("process sampling requires an explicitly permitted live run")
    if args.manual_toggle and args.sample_process:
        parser.error("manual toggle UX requires an unprofiled run")
    root = Path(root) if root is not None else Path(__file__).resolve().parent.parent
    live = not (args.prepare_only or args.preflight_only)
    (root / ".build").mkdir(exist_ok=True)
    summary = dict(status="invalidRun", runID=str(uuid.uuid4()), cases=[])
    # Invalidate the previous audit even when permission gates stop this run.
    write_json(root / ".build/external-native-last.json", summary)
    if live and os.environ.get("RUSWITCH_ALLOW_FOCUS_STEALING") != "1":
        summary.update(status="blockedEnvironment", error="explicit focus permission or isolated session required")
        write_json(root / ".build/external-native-last.json", summary)
        print("BLOCKED: external native suite needs an isolated session or explicit RUSWITCH_ALLOW_FOCUS_STEALING=1", file=sys.stderr)
        return 77
    if live:
        running = running_switchers()
        if any(not args.restart_installed_pro or path != str(INSTALLED_BINARY) for _, path in running):
            summary.update(status="blockedEnvironment", error="another switcher process is running")
            write_json(root / ".build/external-native-last.json", summary)
            print("BLOCKED: another switcher process is running; use an isolated macOS session", file=sys.stderr)
            return 77
    fixture_path = args.fixture or root / ("Tests/Fixtures/Native/manual-toggle-ux.json" if args.manual_toggle
                                          else "Tests/Fixtures/Simulator/physical-closed-loop.json")
    fixture = json.loads(fixture_path.read_text())
    directory = Path(tempfile.mkdtemp(prefix="ruswitch-external-", dir="/private/tmp"))
    summary.update(directory=str(directory), fixtureSHA256=digest(fixture_path), editorKind=args.editor,
                   mode="manual-toggle-ux" if args.manual_toggle else "automatic-continuous")
    restore_hash = None
    try:
        prepared_cases = validate_manual_fixture(fixture) if args.manual_toggle else [fixture]
        if live and not args.manual_toggle and (not isinstance(fixture.get("oracle", {}).get("automaticOff"), dict)
                     or fixture["oracle"]["automaticOff"].get("transactions") != 0
                     or fixture["oracle"]["automaticOff"].get("text") == fixture["oracle"].get("text")):
            raise ValueError("live fixture needs an independent, different auto-off oracle with zero transactions")
        summary["sourceStateSHA256"] = source_digest(root)
        build_env = dict(os.environ, RUSWITCH_TEST_HOST="1")
        build_flags = ["-c", "release", "--scratch-path", str(root / ".build/test-host"),
                       "-Xswiftc", "-warnings-as-errors"]
        with (directory / "build.log").open("w") as log:
            subprocess.run(["bash", str(root / "scripts/build_test_host.sh"), str(directory)],
                           cwd=root, env=build_env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
            for product in ("RuSwitcherNativeDriver", "RuSwitcherNativeEditorHost"):
                subprocess.run(["swift", "build", *build_flags, "--product", product],
                               cwd=root, env=build_env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
        if source_digest(root) != summary["sourceStateSHA256"]:
            raise RuntimeError("source changed while building; this run cannot prove its binary identity")
        binaries = Path(subprocess.check_output(["swift", "build", *build_flags, "--product", TEST_PRODUCT,
                                                "--show-bin-path"], cwd=root, env=build_env, text=True).strip())
        test_app = directory / (TEST_PRODUCT + ".app")
        test_executable = test_app / "Contents/MacOS" / TEST_PRODUCT
        subprocess.run(["bash", "-c", 'source "$1/scripts/ruswitch_test_app.sh"; ruswitch_validate_test_app "$1"',
                        "validate-test-host", str(root)],
                       env=dict(build_env, RUSWITCH_APP=str(test_app), RUSWITCH_REFERENCE_APP=str(test_app)),
                       check=True, timeout=10)
        summary["testBundleID"] = TEST_BUNDLE_ID
        config = dict(runID=str(uuid.uuid4()), layoutIDs=prepared_cases[0]["stimulus"]["layoutIDs"], automaticConversion=not args.manual_toggle,
                      inputMarker=0x52535445, replacementMarker=0x52555300, timeoutSeconds=45)
        write_json(directory / "session.json", config)
        for case in prepared_cases:
            write_json(directory / "stimulus.json", case["stimulus"])
            host_options = []
            if args.manual_toggle:
                write_json(directory / "editor-setup.json", case["editorSetup"])
                host_options = ["--editor-setup", str(directory / "editor-setup.json")]
            subprocess.run([str(binaries / "RuSwitcherNativeDriver"), "--session", str(directory / "session.json"),
                            "--stimulus", str(directory / "stimulus.json"), "--self-check"]
                           + (["--manual-toggle"] if args.manual_toggle else []), check=True, timeout=10)
            subprocess.run([str(binaries / "RuSwitcherNativeEditorHost"), "--session", str(directory / "session.json"),
                            "--self-check", "--editor", args.editor] + host_options, check=True, timeout=10)
        summary["binarySHA256"] = {name: digest(binaries / name) for name in
                                  (TEST_PRODUCT, "RuSwitcherNativeDriver", "RuSwitcherNativeEditorHost")}
        summary["sourceCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        if args.prepare_only:
            summary["status"] = "preparedNotRun"
        else:
            products = [(test_app, test_executable),
                        bundle(binaries / "RuSwitcherNativeEditorHost", directory, "RuSwitcherNativeEditorHost", "com.ruswitcher.native-editor-host",
                               display_name="Keyboard Test Editor"),
                        bundle(binaries / "RuSwitcherNativeDriver", directory, "RuSwitcherNativeDriver", "com.ruswitcher.native-driver",
                               display_name="Keyboard Test Driver")]
            identity = os.environ.get("SIGN_ID") or "RuSwitcher Local Code Signing"
            for app, _ in products[1:]:
                signing = ["codesign", "--force", "--sign", identity]
                subprocess.run([*signing, str(app)], check=True, timeout=30)
                subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=30)
            summary["signedBinarySHA256"] = {path.name: digest(path) for _, path in products}
            preflights = [
                [str(products[0][1]), "--external-native-probe", config["runID"], str(directory / "session.json"),
                 "--host-pid", str(os.getpid()), "--preflight"] + (["--manual-toggle"] if args.manual_toggle else []),
                [str(products[2][1]), "--session", str(directory / "session.json"), "--stimulus", str(directory / "stimulus.json"), "--preflight"]
                + (["--manual-toggle"] if args.manual_toggle else []),
            ]
            summary["preflights"] = []
            for command in preflights:
                result = subprocess.run(command, check=False, timeout=10, capture_output=True, text=True)
                summary["preflights"].append(dict(executable=Path(command[0]).name, exitCode=result.returncode,
                                                  output=result.stdout.strip()))
                if result.returncode not in (0, 77):
                    raise RuntimeError("native preflight failed")
            if any(result["exitCode"] == 77 for result in summary["preflights"]):
                raise BlockedEnvironment("permissions or enabled layouts unavailable; no editor was opened")
            if args.preflight_only:
                summary["status"] = "permissionsReadyNotRun"
            else:
                running = running_switchers()
                if any(not args.restart_installed_pro or path != str(INSTALLED_BINARY) for _, path in running):
                    raise BlockedEnvironment("another switcher appeared during preparation")
                if running:
                    installed_info = plistlib.loads((INSTALLED_APP / "Contents/Info.plist").read_bytes())
                    if installed_info.get("CFBundleIdentifier") != "com.cerfswitcher.app":
                        raise RuntimeError("installed bundle identity does not match Cerf Switcher")
                    expected_hash = digest(INSTALLED_BINARY)
                    for pid, path in running:
                        if (pid, path) not in running_switchers():
                            raise RuntimeError("installed process changed before stop")
                        os.kill(pid, signal.SIGTERM)
                        restore_hash = expected_hash
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline and running_switchers():
                        time.sleep(0.05)
                    if running_switchers():
                        raise BlockedEnvironment("switcher still running after stop request")
                accepted = run_cases(directory, fixture, [x[1] for x in products], summary,
                                     sample_process=args.sample_process, editor=args.editor, manual=args.manual_toggle)
                if any(digest(path) != summary["signedBinarySHA256"][path.name] for _, path in products):
                    raise RuntimeError("a tested executable changed during the run")
                summary["status"] = "passed" if accepted else "failed"
    except BlockedEnvironment as error:
        summary.update(status="blockedEnvironment", error=str(error))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        summary["error"] = str(error)
    finally:
        if restore_hash:
            try:
                summary["restoredInstalledApp"] = restore_installed(restore_hash)
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                summary.update(status="invalidRun", restorationError=str(error))
    try:
        summary = archive_run(root, directory, summary)
    except OSError as error:
        summary.update(status="invalidRun", archiveError=str(error))
    write_json(directory / "summary.json", summary)
    (root / ".build").mkdir(exist_ok=True)
    write_json(root / ".build/external-native-last.json", summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["status"] in ("passed", "preparedNotRun", "permissionsReadyNotRun") else 77 if summary["status"] == "blockedEnvironment" else 1


if __name__ == "__main__":
    sys.exit(main())
