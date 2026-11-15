import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("external_manual_suite", ROOT / "scripts/run_external_native_suite.py")
SUITE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUITE)
FIXTURE = ROOT / "Tests/Fixtures/Native/manual-toggle-ux.json"


def evidence(case, *, disabled=False):
    oracle = case["oracle"]["manualDisabled"] if disabled else case["oracle"]
    actions = case["stimulus"]["actions"]
    states = iter(oracle["manualCheckpoints"])
    records, events, timings, host_points, app_points = [], [], [], [], []
    for index, action in enumerate(actions):
        planned = 1_000_000_000 + action["atMicroseconds"] * 1000
        record = dict(actionIndex=index, plannedNanoseconds=planned, postedNanoseconds=planned + 1000,
                      layoutID=case["stimulus"]["initialLayoutID"])
        records.append(record)
        if action["kind"] == "checkpoint":
            state = next(states)
            record["layoutID"] = state["layoutID"]
            common = dict(runID="test-run", actionIndex=index, id=state["id"],
                          requestNanoseconds=planned + 500, atNanoseconds=planned + 50_000_000)
            host_points.append(dict(common, text=state["text"], selection=state["selection"], focused=True,
                                    clipboardChangeCountDelta=0, forcedAXCollapseCount=state.get("minimumAXCollapseCount", 0)))
            app_points.append(dict(common, **{key: state[key] for key in (
                "attemptCount", "feedback", "confirmedRuleCount", "applicationExceptionCount",
                "learnedEntryCount", "learningUndoAvailable")}))
        elif action["kind"] != "selectLayout":
            events.append(dict(kind=action["kind"], keyCode=action["keyCode"], marker=124 + index,
                               shift=action.get("shift", False)))
            if action["kind"] != "keyUp":
                timings.append(dict(actionIndex=index, keyCode=action["keyCode"], eventKind=action["kind"],
                                    startedNanoseconds=planned + 1000, finishedNanoseconds=planned + 2000, consumed=False))
    host = dict(runID="test-run", pid=10, status="complete", unexpectedInputCount=0,
                text=oracle["text"], selection=oracle["selectedRange"], eventTrace=[], receivedEvents=events,
                quartzEvents=copy.deepcopy(events), quartzTapAvailable=True, quartzTapInterrupted=False,
                clipboardChangeCountDelta=0, manualCheckpoints=host_points)
    app = dict(runID="test-run", pid=20, status="complete", automaticConversion=False, modelAvailable=True,
               posted=0, verified=0, targetProcessID=10, callbackTimingOverflow=False, callbackTimings=timings,
               manualMode=True, manualCheckpoints=app_points)
    driver = dict(runID="test-run", pid=30, status="complete", finalLayoutID=oracle["finalLayoutID"],
                  restoredLayout=True, maximumLatenessMicroseconds=0, records=records)
    return host, app, driver


def add_dom_evidence(case, host):
    events = []
    text, selection = case["editorSetup"]["text"], case["editorSetup"]["selection"]

    def emit(kind, *, key=None, code=None):
        events.append(dict(event=kind, trusted=True, key=key, code=code,
                           state=dict(sequence=len(events), text=text, selection=selection, focused=True)))

    emit("ready")
    checkpoints = iter(host["manualCheckpoints"])
    for action in case["stimulus"]["actions"]:
        if action["kind"] == "checkpoint":
            row = next(checkpoints)
            previous = text
            text, selection = row["text"], row["selection"]
            emit("input" if text != previous else "selectionchange")
            row.update(domReadVerified=True, domSequence=len(events) - 1, forcedAXCollapseCount=0)
        elif action["kind"] == "flagsChanged":
            emit("keydown" if action["shift"] else "keyup", key="Shift",
                 code="ShiftLeft" if action["keyCode"] == 56 else "ShiftRight")
        elif action["kind"] in ("keyDown", "keyUp"):
            emit(action["kind"].lower())
    host.update(editorKind="webkit", domFinalReadVerified=True, domEvents=events)


class ManualAssessmentTests(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads(FIXTURE.read_text())
        self.case = self.fixture["manualCases"][0]
        self.host, self.app, self.driver = evidence(self.case)

    def assess(self, case=None):
        return SUITE.assess(case or self.case, self.host, self.app, self.driver,
                            [10, 20, 30], False, 123, manual=True)

    def testThreeBoundedCasesHaveIndependentToggleOracles(self):
        cases = SUITE.validate_manual_fixture(self.fixture)
        self.assertEqual(len(cases), 3)
        self.assertLess(sum(case["stimulus"]["actions"][-1]["atMicroseconds"] for case in cases)
                        + cases[0]["stimulus"]["actions"][-1]["atMicroseconds"], 20_000_000)
        for case in cases:
            self.host, self.app, self.driver = evidence(case)
            self.assertEqual(self.assess(case), [], case["id"])

    def testNoOpCannotPassEvenWhenFinalTextAndLayoutAreCorrect(self):
        self.host["manualCheckpoints"][1]["text"] = self.host["text"]
        failures = self.assess()
        self.assertNotIn("text-mismatch", failures)
        self.assertNotIn("layout-mismatch", failures)
        self.assertIn("manual-checkpoint-text-mismatch", failures)

    def testManualFunctionalScheduleStillRejectsExcessiveLateness(self):
        for lateness in (10_392, 25_000):
            self.driver["maximumLatenessMicroseconds"] = lateness
            self.assertNotIn("input-schedule-too-late", self.assess())
        for lateness in (-1, 25_001):
            self.driver["maximumLatenessMicroseconds"] = lateness
            self.assertIn("input-schedule-too-late", self.assess())

    def testAutomaticScheduleKeepsItsTenMillisecondGate(self):
        self.driver["maximumLatenessMicroseconds"] = 10_001
        failures = SUITE.assess(self.case, self.host, self.app, self.driver,
                               [10, 20, 30], False, 123)
        self.assertIn("input-schedule-too-late", failures)

    def testFirstCaretLayoutAndNeighborsAreIndependentOfFinalState(self):
        self.host["manualCheckpoints"][1]["text"] = "one привет"
        self.host["manualCheckpoints"][1]["selection"] = [0, 0]
        index = self.host["manualCheckpoints"][1]["actionIndex"]
        self.driver["records"][index]["layoutID"] = self.case["stimulus"]["initialLayoutID"]
        failures = self.assess()
        for failure in ("manual-checkpoint-text-mismatch", "manual-checkpoint-selection-mismatch",
                        "manual-checkpoint-layout-mismatch"):
            self.assertIn(failure, failures)

    def testMultiwordSelectionMustCollapseAndToggleWithoutReselection(self):
        case = self.fixture["manualCases"][2]
        self.host, self.app, self.driver = evidence(case)
        self.host["manualCheckpoints"][1]["selection"] = [5, 10]
        self.assertIn("manual-checkpoint-selection-mismatch", self.assess(case))
        self.host["manualCheckpoints"][1]["forcedAXCollapseCount"] = 0
        self.assertIn("manual-ax-collapse-not-observed", self.assess(case))
        actions = case["stimulus"]["actions"]
        actions.insert(-1, dict(kind="keyDown", keyCode=123, shift=True, atMicroseconds=3_300_000))
        with self.assertRaisesRegex(ValueError, "reselect"):
            SUITE.validate_manual_fixture(self.fixture)

    def testClipboardMutationCannotHideBehindRestoredContents(self):
        self.host["manualCheckpoints"][1]["clipboardChangeCountDelta"] = 2
        self.assertIn("manual-clipboard-changed", self.assess())
        self.host["manualCheckpoints"][1]["clipboardChangeCountDelta"] = 0
        self.host["clipboardChangeCountDelta"] = 2
        self.assertIn("manual-clipboard-changed", self.assess())

    def testCorrectTextDoesNotProveFeedbackOrVisibleLearning(self):
        state = self.app["manualCheckpoints"][1]
        state.update(feedback="unverified", confirmedRuleCount=0, learnedEntryCount=0, learningUndoAvailable=False)
        failures = self.assess()
        self.assertIn("manual-feedback-mismatch", failures)
        self.assertIn("manual-confirmedRuleCount-mismatch", failures)
        self.assertIn("manual-learnedEntryCount-mismatch", failures)
        self.assertIn("manual-learning-visibility-mismatch", failures)

    def testReversalMustRemoveLearningWithoutAddingApplicationException(self):
        self.app["manualCheckpoints"][2].update(confirmedRuleCount=1, applicationExceptionCount=1)
        self.assertIn("manual-confirmedRuleCount-mismatch", self.assess())
        self.assertIn("manual-applicationExceptionCount-mismatch", self.assess())

    def testDuplicateCallbackAndBooleanAttemptCounterFail(self):
        self.app["manualCheckpoints"][1]["attemptCount"] = True
        self.app["callbackTimings"].append(self.app["callbackTimings"][-1])
        self.assertIn("manual-attemptCount-mismatch", self.assess())
        self.assertIn("manual-callback-sequence-mismatch", self.assess())

    def testFlagsChangedMustReachBothNativeLayersWithCorrectFlags(self):
        for layer in ("receivedEvents", "quartzEvents"):
            self.host, self.app, self.driver = evidence(self.case)
            event = next(row for row in self.host[layer] if row["kind"] == "flagsChanged")
            event["kind"] = "keyDown"
            self.assertIn("manual-" + layer + "-event-mismatch", self.assess())
            event["kind"] = "flagsChanged"
            event["shift"] = False
            self.assertIn("manual-" + layer + "-event-mismatch", self.assess())

    def testDroppedTriggersCannotPassAsDisabledControl(self):
        self.host, self.app, self.driver = evidence(self.case, disabled=True)
        control = dict(self.case, oracle=self.case["oracle"]["manualDisabled"])
        self.assertEqual(self.assess(control), [])
        self.assertIn("manual-checkpoint-text-mismatch", self.assess())
        self.host["receivedEvents"] = [row for row in self.host["receivedEvents"] if row["kind"] != "flagsChanged"]
        self.assertIn("manual-receivedEvents-sequence-mismatch", self.assess(control))

    def testMissingDuplicateAndForeignCheckpointsFail(self):
        self.host["manualCheckpoints"].pop(1)
        self.app["manualCheckpoints"][1]["runID"] = "previous-run"
        self.assertIn("manual-host-checkpoints-incomplete", self.assess())
        self.assertIn("manual-checkpoint-identity-mismatch", self.assess())
        self.host, self.app, self.driver = evidence(self.case)
        self.host["manualCheckpoints"][1] = self.host["manualCheckpoints"][0]
        self.assertIn("manual-host-checkpoints-incomplete", self.assess())

    def testSnapshotsMustBeFreshAndFocused(self):
        self.host["manualCheckpoints"][1]["atNanoseconds"] = 1
        self.app["manualCheckpoints"][2]["atNanoseconds"] += 500_000_000
        self.host["manualCheckpoints"][2]["focused"] = False
        self.assertIn("manual-checkpoint-stale", self.assess())
        self.assertIn("manual-checkpoint-unfocused", self.assess())

    def testNoOpOracleAndMissingControlAreRejectedBeforeBuild(self):
        self.case["oracle"]["manualCheckpoints"][1]["text"] = self.case["oracle"]["text"]
        with self.assertRaisesRegex(ValueError, "no-op"):
            SUITE.validate_manual_fixture(self.fixture)
        self.setUp()
        del self.case["oracle"]["manualDisabled"]
        with self.assertRaisesRegex(ValueError, "disabled-trigger"):
            SUITE.validate_manual_fixture(self.fixture)

    def testManualMatrixKeepsAutomaticConversionOffAndHasOneControl(self):
        responses = [dict(passed=True, failures=[], controlFailures=None) for _ in range(3)]
        responses.append(dict(passed=False, failures=["manual-checkpoint-text-mismatch"], controlFailures=[]))
        summary = dict(cases=[])
        with patch.object(SUITE, "run_case", side_effect=responses) as run:
            self.assertTrue(SUITE.run_cases(Path("unused"), self.fixture, [], summary, manual=True))
        self.assertEqual(len(summary["cases"]), 4)
        self.assertEqual([call.args[3] for call in run.call_args_list], [False] * 4)
        self.assertEqual([call.kwargs["manual_enabled"] for call in run.call_args_list], [True, True, True, False])

    def testIncompleteControlFailsEvenIfPositiveOracleDetectedIt(self):
        responses = [dict(passed=True, failures=[], controlFailures=None) for _ in range(3)]
        responses.append(dict(passed=False, failures=["manual-checkpoint-text-mismatch"],
                              controlFailures=["manual-attemptCount-mismatch"]))
        with patch.object(SUITE, "run_case", side_effect=responses):
            self.assertFalse(SUITE.run_cases(Path("unused"), self.fixture, [], dict(cases=[]), manual=True))


class ManualWebKitAssessmentTests(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads(FIXTURE.read_text())
        self.case = self.fixture["manualCases"][0]
        self.host, self.app, self.driver = evidence(self.case)
        add_dom_evidence(self.case, self.host)

    def assess(self, case=None):
        return SUITE.assess(case or self.case, self.host, self.app, self.driver,
                            [10, 20, 30], False, 123, manual=True, editor="webkit")

    def testBothEditorsUseTheExplicitEnabledPair(self):
        for case in self.fixture["manualCases"]:
            self.assertEqual(case["stimulus"]["layoutIDs"], ["com.apple.keylayout.US", "com.apple.keylayout.RussianWin"])
            self.host, self.app, self.driver = evidence(case)
            add_dom_evidence(case, self.host)
            self.assertEqual(self.assess(case), [], case["id"])

    def testWebKitDisabledControlStillNeedsActualShiftEvents(self):
        self.host, self.app, self.driver = evidence(self.case, disabled=True)
        add_dom_evidence(self.case, self.host)
        control = dict(self.case, oracle=self.case["oracle"]["manualDisabled"])
        self.assertEqual(self.assess(control), [])
        self.assertIn("manual-checkpoint-text-mismatch", self.assess())
        next(row for row in self.host["domEvents"] if row.get("key") == "Shift")["key"] = "Other"
        self.assertIn("dom-shift-sequence-mismatch", self.assess(control))

    def testSeededTextAndSelectionMustMatchTheInputOnlySetup(self):
        self.host["domEvents"][0]["state"].update(text="", selection=[0, 0])
        self.assertIn("dom-initial-state-invalid", self.assess())
        self.setUp()
        self.host["domEvents"][0]["state"]["selection"] = [0, 0]
        self.assertIn("dom-initial-state-invalid", self.assess())

    def testFinalReadDoesNotStandInForFreshIntermediateDOMReads(self):
        self.host["manualCheckpoints"][1]["domReadVerified"] = False
        self.assertIn("manual-dom-read-unverified", self.assess())
        self.host["manualCheckpoints"][1]["domReadVerified"] = True
        self.host["manualCheckpoints"][1]["domSequence"] = 0
        self.assertIn("manual-dom-checkpoint-mismatch", self.assess())

    def testShiftSideAndPressReleaseOrderMustMatchNativeReceipt(self):
        shifts = [row for row in self.host["domEvents"] if row.get("key") == "Shift"]
        shifts[0]["code"] = "ShiftLeft"
        failures = self.assess()
        self.assertIn("dom-shift-sequence-mismatch", failures)
        self.assertNotIn("dom-keydown-count-mismatch", failures)
        self.setUp()
        shifts = [row for row in self.host["domEvents"] if row.get("key") == "Shift"]
        shifts[0]["event"], shifts[1]["event"] = shifts[1]["event"], shifts[0]["event"]
        self.assertIn("dom-shift-sequence-mismatch", self.assess())

    def testLostShiftCannotHideBehindCorrectTextAndFinalLayout(self):
        shift = next(row for row in self.host["domEvents"] if row.get("key") == "Shift")
        shift.update(event="selectionchange", key=None, code=None)
        failures = self.assess()
        self.assertIn("dom-keydown-count-mismatch", failures)
        self.assertIn("dom-shift-sequence-mismatch", failures)
        self.assertNotIn("text-mismatch", failures)

    def testMalformedDOMCheckpointEvidenceFailsClosed(self):
        self.host["domEvents"] = None
        failures = self.assess()
        self.assertIn("dom-input-missing", failures)
        self.assertIn("manual-dom-checkpoint-mismatch", failures)

    def testWebKitStillRequiresExplicitFocusPermissionBeforeAnyBuild(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True), \
             patch.object(SUITE.subprocess, "run", side_effect=AssertionError("built or launched")), \
             patch.object(SUITE, "running_switchers", side_effect=AssertionError("enumerated apps")):
            self.assertEqual(SUITE.main(["--manual-toggle", "--editor", "webkit"], root=Path(temporary)), 77)


@unittest.skipUnless(os.environ.get("RUSWITCH_NATIVE_DRIVER_CHECK"), "native driver self-check binary not supplied")
class NativeDriverGrammarTests(unittest.TestCase):
    def run_driver(self, case, *, manual=True):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            SUITE.write_json(root / "session.json", dict(
                runID="11111111-1111-1111-1111-111111111111", layoutIDs=case["stimulus"]["layoutIDs"],
                automaticConversion=False, inputMarker=123, replacementMarker=0x52555300, timeoutSeconds=45))
            SUITE.write_json(root / "stimulus.json", case["stimulus"])
            return subprocess.run([os.environ["RUSWITCH_NATIVE_DRIVER_CHECK"], "--session", str(root / "session.json"),
                                   "--stimulus", str(root / "stimulus.json"), "--self-check"]
                                  + (["--manual-toggle"] if manual else []), capture_output=True, text=True, timeout=5)

    def testRealParserAndFlagsConstructionWithoutPosting(self):
        for case in json.loads(FIXTURE.read_text())["manualCases"]:
            result = self.run_driver(case)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("no application, window or events posted", result.stdout)

    def testNativeExtensionsRequireManualMode(self):
        case = json.loads(FIXTURE.read_text())["manualCases"][0]
        self.assertEqual(self.run_driver(case, manual=False).returncode, 64)

    def testModifierKeyDownCannotPretendToBeFlagsChanged(self):
        case = json.loads(FIXTURE.read_text())["manualCases"][0]
        action = next(action for action in case["stimulus"]["actions"] if action["kind"] == "flagsChanged")
        action["kind"] = "keyDown"
        self.assertEqual(self.run_driver(case).returncode, 64)

    def testUnbalancedFlagsUnsupportedModifiersAndShortCheckpointGapFail(self):
        for mutation in ("unbalanced", "command", "gap"):
            case = json.loads(FIXTURE.read_text())["manualCases"][0]
            actions = case["stimulus"]["actions"]
            action = next(action for action in actions if action["kind"] == "flagsChanged")
            if mutation == "unbalanced":
                action["shift"] = False
            elif mutation == "command":
                action["command"] = True
            else:
                action["atMicroseconds"] = 1_100_000
            self.assertEqual(self.run_driver(case).returncode, 64, mutation)


if __name__ == "__main__":
    unittest.main()
