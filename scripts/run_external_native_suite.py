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
                                      "scripts/run_external_native_suite.py")]
    for directory in ("Sources", "Tests/Support", "Tests/NativeDriver", "Tests/NativeEditorHost"):
        paths += [p for p in (root / directory).rglob("*") if p.is_file()]
    value = hashlib.sha256()
    for path in sorted(paths):
        value.update(str(path.relative_to(root)).encode())
        value.update(bytes.fromhex(digest(path)))
    return value.hexdigest()


INSTALLED_APP = Path("/Applications/RuSwitcherPro.app")
INSTALLED_BINARY = INSTALLED_APP / "Contents/MacOS/RuSwitcherPro"


def running_switchers():
    output = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    rows = []
    for line in output.splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) == 2 and "RuSwitcher" in Path(parts[1]).name:
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
    raise RuntimeError("installed RuSwitcher Pro did not restart")


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


def assess(fixture, host, app, driver, pids, automatic, input_marker):
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
    if app.get("posted") != oracle["transactions"] or app.get("verified") != oracle["transactions"]:
        failures.append("transaction-count-mismatch")
    actions = fixture["stimulus"]["actions"]
    records = driver.get("records", [])
    if [x.get("actionIndex") for x in records] != list(range(len(actions))):
        failures.append("incomplete-input-trace")
    if any(x.get("postedNanoseconds", 0) < x.get("plannedNanoseconds", 0) for x in records):
        failures.append("invalid-driver-timestamps")
    if driver.get("maximumLatenessMicroseconds", 10001) > 10000:
        failures.append("input-schedule-too-late")
    for checkpoint in oracle.get("checkpoints", []):
        index = checkpoint["actionIndex"]
        if index >= len(records) or records[index].get("layoutID") != checkpoint["layoutIDBefore"]:
            failures.append("layout-checkpoint-mismatch")
    failures += callback_timing_failures(actions, app, host, input_marker)
    failures += input_delivery_failures(actions, host["receivedEvents"], app["posted"], input_marker)
    failures += ["quartz-" + failure for failure in
                 input_delivery_failures(actions, host["quartzEvents"], app["posted"], input_marker)]
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
                releaseActionsNotHandled=sorted(appkit - responder))


def case_accepted(result, automatic):
    if automatic:
        return result.get("passed") is True and result.get("failures") == []
    # A negative control must fail the normal oracle AND exactly match the
    # independent auto-off oracle. Missing input is not evidence of detection.
    return (result.get("passed") is False and "text-mismatch" in result.get("failures", [])
            and result.get("controlFailures") == [])


def bundle(binary, root, name, identifier, app_info=None):
    app = root / (name + ".app")
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    executable = contents / "MacOS" / name
    shutil.copy2(binary, executable)
    info = dict(app_info or {})
    info.update(CFBundleIdentifier=identifier, CFBundleExecutable=name, CFBundleName=name,
                CFBundlePackageType="APPL", CFBundleVersion=str(info.get("CFBundleVersion", "1")),
                CFBundleShortVersionString=info.get("CFBundleShortVersionString", "1.0"),
                NSPrincipalClass="NSApplication", LSMinimumSystemVersion="13.0")
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


def run_case(root, fixture, executables, automatic):
    root.mkdir()
    run_id = str(uuid.uuid4())
    input_marker = 0x5253544500000000 | (uuid.uuid4().int & 0xFFFFFFFF)
    config = dict(runID=run_id, layoutIDs=fixture["stimulus"]["layoutIDs"], automaticConversion=automatic,
                  inputMarker=input_marker, replacementMarker=0x52555300, timeoutSeconds=45)
    write_json(root / "session.json", config)
    write_json(root / "stimulus.json", fixture["stimulus"])
    processes, logs = [], []
    env = dict(os.environ, RUSWITCH_ALLOW_FOCUS_STEALING="1")

    def launch(binary, arguments, name):
        log = (root / (name + ".log")).open("w")
        logs.append(log)
        process = subprocess.Popen([str(binary), *arguments], env=env, stdout=log, stderr=subprocess.STDOUT)
        processes.append(process)
        return process

    try:
        host = launch(executables[1], ["--session", str(root / "session.json")], "host")
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
        app = launch(executables[0], ["--external-native-probe", run_id, str(root / "session.json"),
                                      "--host-pid", str(host.pid)], "app")
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
        driver = launch(executables[2], ["--session", str(root / "session.json"), "--stimulus", str(root / "stimulus.json"),
                                         "--host-pid", str(host.pid)], "driver")
        deadline = time.monotonic() + config["timeoutSeconds"]
        while driver.poll() is None and time.monotonic() < deadline:
            state = read_state(root / "host-state.json", run_id, schema_version=2)
            if (state and state.get("status") == "interrupted") or app.poll() is not None or host.poll() is not None:
                raise RuntimeError("native run interrupted")
            time.sleep(0.02)
        if driver.poll() is None:
            raise RuntimeError("driver deadline exceeded")
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
        failures = assess(fixture, host_result, app_result, driver_result,
                          [host.pid, app.pid, driver.pid], automatic, input_marker)
        control_failures = None
        if not automatic:
            control_fixture = dict(fixture, oracle=fixture["oracle"]["automaticOff"])
            control_failures = assess(control_fixture, host_result, app_result, driver_result,
                                      [host.pid, app.pid, driver.pid], False, input_marker)
        result = dict(runID=run_id, automaticConversion=automatic, failures=failures,
                      controlFailures=control_failures, passed=not failures, directory=str(root),
                      deliveryDiagnostics=delivery_diagnostics(fixture, host_result, input_marker),
                      callbackTiming=callback_timing_diagnostics(app_result))
        write_json(root / "assessment.json", result)
        return result
    finally:
        (root / "stop").touch()
        terminate_owned(processes)
        for log in logs:
            log.close()
        subprocess.run(["defaults", "delete", "com.ruswitcher.nativeprobe." + run_id],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def run_cases(directory, fixture, executables, summary):
    accepted = True
    quality_failures = {"text-mismatch", "selection-mismatch", "layout-mismatch", "layout-checkpoint-mismatch",
                        "transaction-count-mismatch", "delivered-keydown-count-mismatch",
                        "delivered-keyup-count-mismatch", "input-delivery-sequence-mismatch",
                        "quartz-delivered-keydown-count-mismatch", "quartz-delivered-keyup-count-mismatch",
                        "quartz-input-delivery-sequence-mismatch", "callback-input-sequence-mismatch",
                        "callback-consumption-mismatch"}
    for name, enabled in [("positive", True), ("auto-off-control", False)]:
        result = run_case(directory / name, fixture, executables, enabled)
        summary["cases"].append(result)
        if set(result["failures"]) - quality_failures:
            raise RuntimeError("native run interrupted or evidence invalid; no further window opened")
        if not case_accepted(result, enabled):
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
                        help="Explicitly permit quitting and restoring only /Applications/RuSwitcherPro.app")
    parser.add_argument("--fixture", type=Path)
    args = parser.parse_args(argv)
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
            summary.update(status="blockedEnvironment", error="another RuSwitcher process is running")
            write_json(root / ".build/external-native-last.json", summary)
            print("BLOCKED: another RuSwitcher process is running; use an isolated macOS session", file=sys.stderr)
            return 77
    fixture_path = args.fixture or root / "Tests/Fixtures/Simulator/physical-closed-loop.json"
    fixture = json.loads(fixture_path.read_text())
    directory = Path(tempfile.mkdtemp(prefix="ruswitch-external-", dir="/private/tmp"))
    summary.update(directory=str(directory), fixtureSHA256=digest(fixture_path))
    restore_hash = None
    try:
        if live and (not isinstance(fixture.get("oracle", {}).get("automaticOff"), dict)
                     or fixture["oracle"]["automaticOff"].get("transactions") != 0
                     or fixture["oracle"]["automaticOff"].get("text") == fixture["oracle"].get("text")):
            raise ValueError("live fixture needs an independent, different auto-off oracle with zero transactions")
        summary["sourceStateSHA256"] = source_digest(root)
        with (directory / "build.log").open("w") as log:
            subprocess.run(["swift", "build", "-c", "release", "-Xswiftc", "-warnings-as-errors"],
                           cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
        if source_digest(root) != summary["sourceStateSHA256"]:
            raise RuntimeError("source changed while building; this run cannot prove its binary identity")
        binaries = Path(subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root, text=True).strip())
        config = dict(runID=str(uuid.uuid4()), layoutIDs=fixture["stimulus"]["layoutIDs"], automaticConversion=True,
                      inputMarker=0x52535445, replacementMarker=0x52555300, timeoutSeconds=45)
        write_json(directory / "session.json", config)
        write_json(directory / "stimulus.json", fixture["stimulus"])
        subprocess.run([str(binaries / "RuSwitcherNativeDriver"), "--session", str(directory / "session.json"),
                        "--stimulus", str(directory / "stimulus.json"), "--self-check"], check=True, timeout=10)
        subprocess.run([str(binaries / "RuSwitcherNativeEditorHost"), "--session", str(directory / "session.json"),
                        "--self-check"], check=True, timeout=10)
        summary["binarySHA256"] = {name: digest(binaries / name) for name in
                                  ("RuSwitcher", "RuSwitcherNativeDriver", "RuSwitcherNativeEditorHost")}
        summary["sourceCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        if args.prepare_only:
            summary["status"] = "preparedNotRun"
        else:
            version = json.loads((root / "version.json").read_text())
            info = plistlib.loads((root / "Info.plist").read_bytes())
            info.update(CFBundleShortVersionString=version["version"], CFBundleVersion=str(version["build"]))
            products = [bundle(binaries / "RuSwitcher", directory, "RuSwitcherPro", "com.ruswitcher.pro", info),
                        bundle(binaries / "RuSwitcherNativeEditorHost", directory, "RuSwitcherNativeEditorHost", "com.ruswitcher.native-editor-host"),
                        bundle(binaries / "RuSwitcherNativeDriver", directory, "RuSwitcherNativeDriver", "com.ruswitcher.native-driver")]
            resources = products[0][0] / "Contents/Resources"
            shutil.copy2(root / "Sources/RuSwitcherCore/Resources/language-model-v1.bin", resources)
            shutil.copy2(root / "RuSwitcher.icns", resources)
            identity = os.environ.get("SIGN_ID", "RuSwitcher Local Code Signing")
            for app, _ in products:
                signing = ["codesign", "--force", "--sign", identity]
                if app == products[0][0]:
                    signing += ["--options", "runtime", "--entitlements", str(root / "RuSwitcher.entitlements")]
                subprocess.run([*signing, str(app)], check=True, timeout=30)
                subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=30)
            summary["signedBinarySHA256"] = {path.name: digest(path) for _, path in products}
            preflights = [
                [str(products[0][1]), "--external-native-probe", config["runID"], str(directory / "session.json"),
                 "--host-pid", str(os.getpid()), "--preflight"],
                [str(products[2][1]), "--session", str(directory / "session.json"), "--stimulus", str(directory / "stimulus.json"), "--preflight"],
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
                    if installed_info.get("CFBundleIdentifier") != "com.ruswitcher.pro":
                        raise RuntimeError("installed bundle identity does not match RuSwitcher Pro")
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
                accepted = run_cases(directory, fixture, [x[1] for x in products], summary)
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
