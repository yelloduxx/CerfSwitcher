"""Short, independently authored continuous-input tests in real macOS editors."""

import argparse
import contextlib
import json
import os
from pathlib import Path
import signal
import tempfile
import time

import run_external_native_suite as native

ROOT = Path(__file__).resolve().parent.parent
EN = "com.apple.keylayout.US"
RU = "com.apple.keylayout.RussianWin"
CODES = dict(zip("asdfhgzxcvbqweryt123465=97-80]ou[ip\nlj'k;\\,/nm.",
                 [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
                  18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
                  32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47]))
RU_KEYS = dict(zip("йцукенгшщзхъфывапролджэячсмитьбю", "qwertyuiop[]asdfghjkl;'zxcvbnm,."))


def key(character, language):
    if character == " ":
        return 49, False
    if character == "!":
        return 18, True
    if character == ":":
        return 41, True
    if language == RU and character in ",.":
        return 44, character == ","
    base = RU_KEYS.get(character.lower(), character.lower()) if language == RU else character.lower()
    return CODES[base], character.isupper()


def type_text(actions, text, language, start=0, interval=35_000, fast_boundary=False):
    at = start
    compressed = False
    for char in text:
        code, shift = key(char, language)
        for kind, offset in (("keyDown", 0), ("keyUp", 1_000)):
            actions.append(dict(kind=kind, atMicroseconds=at + offset, keyCode=code,
                                shift=shift, capsLock=False, autorepeat=False))
        gap = 2_000 if fast_boundary and char == " " and not compressed else interval
        if gap == 2_000:
            compressed = True
        at += gap
    return at


def gesture(actions, at):
    for offset, pressed in ((0, True), (12_000, False), (50_000, True), (51_000, False)):
        actions.append(dict(kind="flagsChanged", atMicroseconds=at + offset, keyCode=56, shift=pressed))


def fixture(name, text, source, target, *, automatic=True, setup="", selection=None, actions=None,
            transactions=1, alternatives=None):
    if actions is None:
        actions = []
        type_text(actions, text, target, fast_boundary=True)
    actions.append(dict(kind="checkpoint", atMicroseconds=actions[-1]["atMicroseconds"] + 500_000, id="final"))
    return dict(id=name, automatic=automatic,
                editorSetup=dict(text=setup, selection=selection or [len(setup), 0],
                                 title=("CONTROL: auto-conversion OFF" if name == "auto-disabled-negative-control"
                                        else "CHECK: " + name)),
                stimulus=dict(version=1, id=name, layoutIDs=[EN, RU], initialLayoutID=source,
                              keyboardType=40, actions=actions),
                oracle=dict(outcomes=alternatives or [dict(text=text, layout=target)], transactions=transactions))


def cases():
    russian = fixture("fast-russian-continuation", "вечером мы проверим доклад, а утром обсудим результат! ", EN, RU)
    english = fixture("fast-english-continuation", "please send report Q, then attach appendix D! ", RU, EN)
    off = fixture("auto-disabled-negative-control", "", EN, EN, automatic=False,
                  actions=[dict(row) for row in russian["stimulus"]["actions"] if row["kind"] != "checkpoint"],
                  transactions=0,
                  alternatives=[dict(text="dtxthjv vs ghjdthbv ljrkfl? f enhjv j,celbv htpekmnfn! ", layout=EN)])
    # Two legitimate serializations: the empty-field switch completes before
    # typing, or the changed editor cancels it. A mid-phrase switch is neither.
    actions = []
    gesture(actions, 0)
    type_text(actions, "draft notes, and check item R! ", EN, start=52_000)
    race = fixture("empty-caret-then-immediate-typing", "", EN, EN, automatic=False,
                   actions=actions, transactions=0, alternatives=[
                       dict(text="draft notes, and check item R! ", layout=EN),
                       dict(text="вкфае тщеуыб фтв срусл шеуь К! ", layout=RU)])
    # Selected and unselected new phrases toggle twice, without reselecting.
    toggles = []
    for selected in (False, True):
        original = "anchor: nfrnbxyj"
        actions = []
        gesture(actions, 0)
        actions.append(dict(kind="checkpoint", atMicroseconds=450_000, id="converted"))
        gesture(actions, 1_000_000)
        test = fixture("selected-toggle" if selected else "caret-toggle", original, EN, EN,
                       automatic=False, setup=original, selection=[8, 8] if selected else [16, 0],
                       actions=actions, transactions=0)
        test["oracle"]["intermediate"] = dict(text="anchor: тактично", layout=RU)
        toggles.append(test)
    actions = []
    original = "the final note: nfrnbxyj"
    end = type_text(actions, original, EN)
    gesture(actions, end + 80_000)
    actions.append(dict(kind="checkpoint", atMicroseconds=end + 530_000, id="converted"))
    gesture(actions, end + 1_080_000)
    buffered = fixture("buffered-toggle", original, EN, EN, automatic=False,
                       actions=actions, transactions=0)
    buffered["oracle"]["intermediate"] = dict(text="the final note: тактично", layout=RU)
    manual_only = []
    for excluded in (True, False):
        actions = []
        end = type_text(actions, "please wait here ", EN)
        gesture(actions, end + 80_000)
        actions.append(dict(kind="checkpoint", atMicroseconds=end + 530_000, id="converted"))
        gesture(actions, end + 1_080_000)
        type_text(actions, "and keep this note. ", EN, start=end + 1_600_000)
        test = fixture("manual-only-pair" if excluded else "manual-only-learning-control",
                       "please wait here and keep this note. ", EN, EN,
                       actions=actions, transactions=0)
        test["neverConvertWords"] = ["here"] if excluded else []
        test["oracle"]["intermediate"] = dict(text="please wait руку ", layout=RU)
        test["oracle"]["learningExcluded"] = excluded
        manual_only.append(test)
    return [russian, english, off, race, *toggles, buffered, *manual_only]


def assess(fixture, host, app, driver, pids, automatic, marker, **options):
    failures = []
    for data, pid, label in zip((host, app, driver), pids, ("host", "app", "driver")):
        if data.get("status") != "complete" or data.get("pid") != pid:
            failures.append(label + "-incomplete")
    if len(set(pids)) != 3 or app.get("targetProcessID") != pids[0]:
        failures.append("process-identity")
    if host.get("unexpectedInputCount") != 0 or not host.get("quartzTapAvailable") or host.get("quartzTapInterrupted"):
        failures.append("interference-or-missing-observation")
    if host.get("clipboardChangeCountDelta") != 0:
        failures.append("clipboard-changed")
    if not driver.get("restoredLayout") or driver.get("maximumLatenessMicroseconds", 10001) > 10_000:
        failures.append("invalid-schedule-or-layout-restoration")
    actions = fixture["stimulus"]["actions"]
    if [row.get("actionIndex") for row in driver.get("records", [])] != list(range(len(actions))):
        failures.append("incomplete-stimulus")
    if app.get("automaticConversion") != automatic or not app.get("modelAvailable"):
        failures.append("wrong-runtime-configuration")
    if app.get("posted") != fixture["oracle"]["transactions"]:
        failures.append("transaction-count")
    actual = dict(text=host.get("text"), layout=driver.get("finalLayoutID"))
    if actual not in fixture["oracle"]["outcomes"]:
        failures.append("text-or-layout-mismatch")
    if host.get("selection") != [len(host.get("text", "").encode("utf-16-le")) // 2, 0]:
        failures.append("caret-mismatch")
    expected_callbacks = [(i, a["kind"]) for i, a in enumerate(actions) if a["kind"] in ("keyDown", "flagsChanged")]
    if [(r.get("actionIndex"), r.get("eventKind")) for r in app.get("callbackTimings", [])] != expected_callbacks:
        failures.append("missing-or-duplicate-callback")
    key_app = dict(app, callbackTimings=[r for r in app.get("callbackTimings", []) if r.get("eventKind") == "keyDown"])
    failures += native.callback_timing_failures(actions, key_app, host, marker)
    for layer in ("receivedEvents", "quartzEvents"):
        failures += [layer + ":" + error for error in native.input_delivery_failures(actions, host[layer], app["posted"], marker)]
    points = host.get("manualCheckpoints", [])
    if len(points) != sum(a["kind"] == "checkpoint" for a in actions):
        failures.append("missing-readback")
    for point in points:
        if not point.get("focused") or point.get("clipboardChangeCountDelta") != 0:
            failures.append("checkpoint-focus-or-clipboard")
        if point["id"] == "converted":
            expected = fixture["oracle"]["intermediate"]
            record = driver["records"][point["actionIndex"]]
            if point["text"] != expected["text"] or record.get("checkpointLayoutID") != expected["layout"]:
                failures.append("first-toggle-mismatch")
    if "learningExcluded" in fixture["oracle"]:
        observed = app.get("manualCheckpoints", [])
        if [(p.get("id"), p.get("actionIndex")) for p in observed] != [
                (p.get("id"), p.get("actionIndex")) for p in points]:
            failures.append("missing-learning-readback")
        if fixture["oracle"]["learningExcluded"]:
            if any(p.get("learnedEntryCount") != 0 or p.get("learningUndoAvailable") is not False for p in observed):
                failures.append("excluded-pair-learned")
        elif not any(p.get("id") == "converted" and p.get("confirmedRuleCount", 0) > 0 for p in observed):
            failures.append("learning-control-did-not-learn")
    if options.get("editor") == "webkit":
        if not host.get("domFinalReadVerified") or not host.get("domEvents"):
            failures.append("missing-independent-dom-readback")
    return failures


def challenge_disabled_trace(directory, editor):
    """Reassess actual captured input, not fabricated passing evidence."""
    trace = directory / "auto-disabled-negative-control"
    if not trace.is_dir():
        return None
    host, app, driver, config = [json.loads((trace / filename).read_text()) for filename in
                                ("host-result.json", "app-result.json", "driver-result.json", "session.json")]
    failures = assess(cases()[0], host, app, driver, [host["pid"], app["pid"], driver["pid"]],
                      True, config["inputMarker"], editor=editor)
    return dict(detected="text-or-layout-mismatch" in failures and "transaction-count" in failures,
                failures=failures)


def validate_prepared(prepared, executables):
    if native.source_digest(ROOT) != prepared.get("sourceStateSHA256"):
        raise RuntimeError("source changed after preparation; rebuild the native test applications")
    for binary in executables:
        if native.digest(binary) != prepared["signedBinarySHA256"][binary.name]:
            raise RuntimeError("prepared binary hash mismatch")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepared", type=Path)
    parser.add_argument("--editor", choices=("nstextview", "webkit"), required=True)
    parser.add_argument("--case", action="append")
    args = parser.parse_args()
    if os.environ.get("RUSWITCH_ALLOW_FOCUS_STEALING") != "1":
        return 77
    directory = Path(tempfile.mkdtemp(prefix="cerf-native-interaction-", dir="/private/tmp"))
    if args.prepared:
        prepared = json.loads(args.prepared.read_text())
    else:
        with (directory / "prepare.log").open("w") as log, contextlib.redirect_stdout(log):
            code = native.main(["--preflight-only", "--manual-toggle"], root=ROOT)
        if code:
            print(directory / "prepare.log")
            return code
        prepared = json.loads((ROOT / ".build/external-native-last.json").read_text())
    base = Path(prepared["directory"])
    executables = [base / (name + ".app") / "Contents/MacOS" / name for name in
                   ("CerfSwitcherTestHost", "RuSwitcherNativeEditorHost", "RuSwitcherNativeDriver")]
    summary = dict(editor=args.editor, directory=str(directory), prepared=str(base), cases=[],
                   sourceStateSHA256=prepared["sourceStateSHA256"],
                   signedBinarySHA256=prepared["signedBinarySHA256"],
                   scenarioGeneratorSHA256=native.digest(Path(__file__)))
    restore_hash = None
    try:
        validate_prepared(prepared, executables)
        running = native.running_switchers()
        if any(path != str(native.INSTALLED_BINARY) for _, path in running):
            raise RuntimeError("another switcher is running")
        if running:
            restore_hash = native.digest(native.INSTALLED_BINARY)
            for pid, _ in running:
                os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 3
            while native.running_switchers() and time.monotonic() < deadline:
                time.sleep(0.02)
            if native.running_switchers():
                raise RuntimeError("installed app did not stop")
        for case in cases():
            if args.case and case["id"] not in args.case:
                continue
            native.write_json(directory / (case["id"] + ".json"), case)
            result = native.run_case(directory / case["id"], case, executables, case["automatic"],
                                     editor=args.editor, manual=True, interaction_assessor=assess)
            summary["cases"].append(result)
        summary["status"] = "passed" if summary["cases"] and all(r["passed"] for r in summary["cases"]) else "failed"
        validate_prepared(prepared, executables)
        summary["disabledTraceAgainstEnabledOracle"] = challenge_disabled_trace(directory, args.editor)
        if summary["disabledTraceAgainstEnabledOracle"] and not summary["disabledTraceAgainstEnabledOracle"]["detected"]:
            summary["status"] = "failed"
    except (OSError, RuntimeError) as error:
        summary.update(status="invalidRun", error=str(error))
    finally:
        if restore_hash:
            summary["restoredInstalledApp"] = native.restore_installed(restore_hash)
        native.write_json(directory / "summary.json", summary)
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
