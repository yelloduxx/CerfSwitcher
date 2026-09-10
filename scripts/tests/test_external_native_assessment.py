import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("external_suite", Path(__file__).parents[1] / "run_external_native_suite.py")
SUITE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUITE)


class NativeAssessmentTests(unittest.TestCase):
    def setUp(self):
        self.fixture = {"oracle": {"text": "done ", "finalLayoutID": "en", "transactions": 1, "verifiedCompletions": 1},
                        "stimulus": {"actions": [{"kind": "keyDown", "keyCode": 49}, {"kind": "keyUp", "keyCode": 49}]}}
        self.host = dict(pid=10, status="complete", unexpectedInputCount=0, text="done ", selection=[5, 0],
                         eventTrace=[], receivedEvents=[dict(kind="keyUp", keyCode=49, marker=125)],
                         quartzTapAvailable=True, quartzTapInterrupted=False,
                         quartzEvents=[dict(kind="keyUp", keyCode=49, marker=125,
                                            atNanoseconds=3, eventTimestampNanoseconds=2)])
        self.app = dict(pid=20, status="complete", automaticConversion=True, modelAvailable=True, posted=1, verified=1, targetProcessID=10,
                        callbackTimingOverflow=False, callbackTimings=[dict(actionIndex=0, keyCode=49,
                                                                           startedNanoseconds=1, finishedNanoseconds=2, consumed=True)])
        self.driver = dict(pid=30, status="complete", finalLayoutID="en", restoredLayout=True,
                           maximumLatenessMicroseconds=0,
                           records=[dict(actionIndex=0, plannedNanoseconds=1, postedNanoseconds=1),
                                    dict(actionIndex=1, plannedNanoseconds=2, postedNanoseconds=2)])

    def assess(self):
        return SUITE.assess(self.fixture, self.host, self.app, self.driver, [10, 20, 30], True, 123)

    def testCompleteIndependentEvidencePasses(self):
        self.assertEqual(self.assess(), [])

    def set_webkit_evidence(self):
        self.host.update(editorKind="webkit", domFinalReadVerified=True, domEvents=[
            dict(event="ready", trusted=True, state=dict(sequence=0, text="", selection=[0, 0], focused=True)),
            dict(event="input", trusted=True, state=dict(sequence=1, text="done ", selection=[5, 0], focused=True)),
            dict(event="keyup", trusted=True, state=dict(sequence=2, text="done ", selection=[5, 0], focused=True))])

    def testWebKitCannotReuseTextViewOrUnverifiedDOMEvidence(self):
        def assess_web():
            return SUITE.assess(self.fixture, self.host, self.app, self.driver,
                                [10, 20, 30], True, 123, editor="webkit")
        self.assertIn("editor-kind-mismatch", assess_web())
        self.set_webkit_evidence()
        self.assertEqual(assess_web(), [])
        self.host["domFinalReadVerified"] = False
        self.assertIn("dom-final-read-unverified", assess_web())
        self.host["domFinalReadVerified"] = True
        self.host["domEvents"][-1]["state"]["text"] = "fail "
        self.assertIn("dom-snapshot-mismatch", assess_web())

    def testWebKitMustObserveTrustedInputAndFocusedFinalSelection(self):
        self.host.update(editorKind="webkit", domFinalReadVerified=True, domEvents=[])
        def assess_web():
            return SUITE.assess(self.fixture, self.host, self.app, self.driver,
                                [10, 20, 30], True, 123, editor="webkit")
        self.assertIn("dom-input-missing", assess_web())
        self.set_webkit_evidence()
        self.host["domEvents"][-1]["trusted"] = False
        self.assertIn("dom-untrusted-event", assess_web())
        self.host["domEvents"][-1]["trusted"] = True
        self.host["domEvents"][-1]["state"]["focused"] = False
        self.assertIn("dom-snapshot-mismatch", assess_web())

    def testWebKitExactTextCannotHideMissingDOMKeyboardDelivery(self):
        self.set_webkit_evidence()
        self.host["domEvents"].pop()
        failures = SUITE.assess(self.fixture, self.host, self.app, self.driver,
                                [10, 20, 30], True, 123, editor="webkit")
        self.assertNotIn("text-mismatch", failures)
        self.assertIn("dom-keyup-count-mismatch", failures)

    def testCorrectTextAloneCannotHideMissingOrLateInput(self):
        self.driver["records"].pop()
        self.driver["maximumLatenessMicroseconds"] = 10001
        self.assertIn("incomplete-input-trace", self.assess())
        self.assertIn("input-schedule-too-late", self.assess())

    def testCorrectTextCannotHideSelectionDuplicatesOrUnverifiedReplacement(self):
        self.host["selection"] = [0, 5]
        self.host["receivedEvents"] *= 2
        self.app["verified"] = 0
        failures = self.assess()
        self.assertIn("selection-mismatch", failures)
        self.assertIn("delivered-keyup-count-mismatch", failures)
        self.assertIn("transaction-count-mismatch", failures)

    def testStalePidOrForeignInputCannotPass(self):
        self.host["pid"] = 11
        self.host["unexpectedInputCount"] = 1
        self.assertIn("host-not-complete", self.assess())
        self.assertIn("external-interference", self.assess())

    def testMissingFieldsAndWrongExpectedResultFail(self):
        self.fixture["oracle"]["text"] = "wrong"
        self.host["status"] = "interrupted"
        self.assertIn("text-mismatch", self.assess())
        self.assertIn("host-not-complete", self.assess())

    def testForeignRunCannotReuseAPreviousResult(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "state.json"
            SUITE.write_json(path, dict(schemaVersion=1, runID="old"))
            with self.assertRaisesRegex(ValueError, "foreign/stale"):
                SUITE.read_state(path, "new")
            path.unlink()
            self.assertIsNone(SUITE.read_state(path, "new"))

    def testBooleanCountersCannotMasqueradeAsOneVerifiedTransaction(self):
        self.app["verified"] = True
        self.assertEqual(self.assess(), ["malformed-native-evidence"])

    def testCorrectCountsCannotHideWrongKeyOrDuplicatedAction(self):
        self.host["receivedEvents"][0]["keyCode"] = 0
        self.assertIn("input-delivery-sequence-mismatch", self.assess())
        self.host["receivedEvents"][0]["keyCode"] = 49
        self.fixture["stimulus"]["actions"] += [{"kind": "keyDown", "keyCode": 49}, {"kind": "keyUp", "keyCode": 49}]
        self.driver["records"] += [dict(actionIndex=i, plannedNanoseconds=i, postedNanoseconds=i) for i in (2, 3)]
        self.app["callbackTimings"].append(dict(actionIndex=2, keyCode=49, startedNanoseconds=3,
                                                finishedNanoseconds=4, consumed=False))
        self.host["receivedEvents"] += [dict(kind="keyDown", keyCode=49, marker=126), dict(kind="keyUp", keyCode=49, marker=127)]
        self.host["quartzEvents"] += [dict(kind="keyDown", keyCode=49, marker=126), dict(kind="keyUp", keyCode=49, marker=127)]
        self.assertEqual(self.assess(), [])
        self.host["receivedEvents"][-1]["marker"] = 125
        failures = self.assess()
        self.assertNotIn("delivered-keyup-count-mismatch", failures)
        self.assertIn("input-delivery-sequence-mismatch", failures)

    def testDroppedLetterCannotBeMistakenForConsumedBoundary(self):
        self.fixture["stimulus"]["actions"][0]["keyCode"] = 0
        self.assertIn("input-delivery-sequence-mismatch", self.assess())

    def testAutoOffMustMatchItsOwnOracleNotMerelyFailThePositiveOne(self):
        self.fixture["oracle"]["automaticOff"] = {"text": "wrong ", "finalLayoutID": "en", "transactions": 0}
        self.host.update(text="wrong ", selection=[6, 0], receivedEvents=[dict(kind="keyDown", keyCode=49, marker=124),
                                                                     dict(kind="keyUp", keyCode=49, marker=125)])
        self.app.update(automaticConversion=False, posted=0, verified=0)
        self.app["callbackTimings"][0]["consumed"] = False
        self.host["quartzEvents"] = self.host["receivedEvents"][:]

        def result():
            control = dict(self.fixture, oracle=self.fixture["oracle"]["automaticOff"])
            failures = SUITE.assess(self.fixture, self.host, self.app, self.driver, [10, 20, 30], False, 123)
            return dict(passed=not failures, failures=failures,
                        controlFailures=SUITE.assess(control, self.host, self.app, self.driver, [10, 20, 30], False, 123))

        self.assertTrue(SUITE.case_accepted(result(), False))
        self.host["receivedEvents"].pop(0)
        damaged = result()
        self.assertIn("text-mismatch", damaged["failures"])
        self.assertIn("delivered-keydown-count-mismatch", damaged["controlFailures"])
        self.assertFalse(SUITE.case_accepted(damaged, False))
        self.assertFalse(SUITE.case_accepted(dict(passed=False, failures=["text-mismatch"]), False))

    def testArrivalIsIndependentOfResponderHandling(self):
        self.assertEqual(self.host["eventTrace"], [])
        self.assertEqual(self.assess(), [])
        self.host["eventTrace"] = self.host["receivedEvents"][:]
        self.host["receivedEvents"] = []
        self.assertIn("delivered-keyup-count-mismatch", self.assess())
        del self.host["receivedEvents"]
        self.assertEqual(self.assess(), ["malformed-native-evidence"])

    def testQuartzObservationCannotStandInForAppKitReceipt(self):
        self.host.update(quartzTapAvailable=True, quartzTapInterrupted=False,
                         quartzEvents=[dict(kind="keyUp", keyCode=49, marker=125,
                                            atNanoseconds=3, eventTimestampNanoseconds=2)])
        self.host["receivedEvents"] = []
        self.assertIn("delivered-keyup-count-mismatch", self.assess())
        diagnosis = SUITE.delivery_diagnostics(self.fixture, self.host, 123)
        self.assertEqual(diagnosis["unobservedReleaseActionsAtQuartz"], [])
        self.assertEqual(diagnosis["releaseActionsMissingAtAppKit"], [1])
        self.host["quartzEvents"] = []
        diagnosis = SUITE.delivery_diagnostics(self.fixture, self.host, 123)
        self.assertEqual(diagnosis["unobservedReleaseActionsAtQuartz"], [1])
        self.assertEqual(diagnosis["releaseActionsMissingAtAppKit"], [])

    def testUnavailableOrInterruptedQuartzObserverCannotPass(self):
        self.host.update(quartzTapAvailable=False, quartzTapInterrupted=False, quartzEvents=[])
        self.assertIn("quartz-observation-unavailable", self.assess())
        self.assertFalse(SUITE.delivery_diagnostics(self.fixture, self.host, 123)["observationComplete"])
        self.host.update(quartzTapAvailable=True, quartzTapInterrupted=True)
        self.assertIn("quartz-observation-interrupted", self.assess())
        self.assertFalse(SUITE.delivery_diagnostics(self.fixture, self.host, 123)["observationComplete"])

    def testHostSchemaCannotBeMistakenForLegacyReceiptEvidence(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "host-state.json"
            SUITE.write_json(path, dict(schemaVersion=1, runID="same"))
            with self.assertRaisesRegex(ValueError, "foreign/stale"):
                SUITE.read_state(path, "same", schema_version=2)
            SUITE.write_json(path, dict(schemaVersion=2, runID="same"))
            self.assertIsNotNone(SUITE.read_state(path, "same", schema_version=2))

    def testMissingOrInvalidCallbackTimingsCannotPass(self):
        self.app["callbackTimings"] = []
        self.assertIn("callback-input-sequence-mismatch", self.assess())
        self.app["callbackTimings"] = [dict(actionIndex=0, keyCode=49, startedNanoseconds=20,
                                            finishedNanoseconds=10, consumed=True)]
        self.assertIn("callback-timing-invalid", self.assess())
        self.app["callbackTimings"][0].update(startedNanoseconds=1, finishedNanoseconds=2, keyCode=0)
        self.assertIn("callback-input-sequence-mismatch", self.assess())
        self.app["callbackTimingOverflow"] = True
        self.assertIn("callback-timing-overflow", self.assess())

    def testConsumedFlagMustAgreeWithObservedInput(self):
        self.app["callbackTimings"] = [dict(actionIndex=0, keyCode=49, startedNanoseconds=1,
                                            finishedNanoseconds=2, consumed=False)]
        self.assertIn("callback-consumption-mismatch", self.assess())

    def testCallbackTimingSummaryReportsSamplesNotAClaimedPopulationPercentile(self):
        self.app["callbackTimings"] = [dict(actionIndex=0, keyCode=49, startedNanoseconds=2**63,
                                            finishedNanoseconds=2**63 + 7_000_000, consumed=True)]
        summary = SUITE.callback_timing_diagnostics(self.app)
        self.assertEqual(summary["samples"], 1)
        self.assertEqual(summary["maximumMicroseconds"], 7000)
        self.assertEqual(summary["consumedMaximumMicroseconds"], 7000)
        self.assertNotIn("p99", summary)

    def testLayoutCheckpointUsesProcessingNotEarlierProducerSnapshot(self):
        self.fixture["oracle"]["checkpoints"] = [dict(actionIndex=0, layoutIDBefore="ru")]
        self.driver["records"][0]["layoutID"] = "en"
        self.app["callbackTimings"][0]["sourceLayoutID"] = "ru"
        self.assertEqual(self.assess(), [])
        self.app["callbackTimings"][0]["sourceLayoutID"] = "en"
        self.assertIn("layout-checkpoint-mismatch", self.assess())

    def testOptionalConfirmationCountDoesNotWeakenDeliveryOrTextChecks(self):
        self.fixture["oracle"].pop("verifiedCompletions", None)
        self.app["verified"] = 0
        self.assertEqual(self.assess(), [])
        self.app["verified"] = 2
        self.assertIn("transaction-count-mismatch", self.assess())
        self.app["verified"] = 0
        self.host["text"] = "damaged"
        self.assertIn("text-mismatch", self.assess())
        self.fixture["oracle"]["verifiedCompletions"] = True
        self.assertIn("invalid-oracle-verification-count", self.assess())

    def testCompletedPositiveFailureStillCollectsTheNegativeControl(self):
        summary = dict(cases=[])
        positive = dict(passed=False, failures=["delivered-keyup-count-mismatch"], controlFailures=None)
        negative = dict(passed=False, failures=["text-mismatch"], controlFailures=[])
        with patch.object(SUITE, "run_case", side_effect=[positive, negative]) as run:
            self.assertFalse(SUITE.run_cases(Path("unused"), {}, [], summary))
        self.assertEqual([call.args[-1] for call in run.call_args_list], [True, False])
        self.assertEqual(summary["cases"], [positive, negative])
        self.assertEqual(summary["qualityFailures"], ["positive"])

    def testInterferenceStopsBeforeAnotherWindowIsRequested(self):
        summary = dict(cases=[])
        result = dict(passed=False, failures=["external-interference"], controlFailures=None)
        with patch.object(SUITE, "run_case", return_value=result) as run:
            with self.assertRaisesRegex(RuntimeError, "no further window"):
                SUITE.run_cases(Path("unused"), {}, [], summary)
        self.assertEqual(run.call_count, 1)

    def testSamplingIsExplicitAndOnlyAppliesToPositiveCase(self):
        positive = dict(passed=True, failures=[], controlFailures=None)
        negative = dict(passed=False, failures=["text-mismatch"], controlFailures=[])
        for requested in (False, True):
            with patch.object(SUITE, "run_case", side_effect=[positive, negative]) as run:
                self.assertTrue(SUITE.run_cases(Path("unused"), {}, [], dict(cases=[]), sample_process=requested))
            self.assertEqual([call.kwargs["sample_process"] for call in run.call_args_list], [requested, False])


if __name__ == "__main__":
    unittest.main()
