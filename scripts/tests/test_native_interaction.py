from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run_native_interaction_tests as suite


class InteractionTests(unittest.TestCase):
    def testPreparedBinaryCannotValidateNewerSources(self):
        binary = Path("CerfSwitcherTestHost")
        prepared = dict(sourceStateSHA256="source-one", signedBinarySHA256={binary.name: "binary-one"})
        with patch.object(suite.native, "source_digest", return_value="source-two"), \
             patch.object(suite.native, "digest", return_value="binary-one"):
            with self.assertRaisesRegex(RuntimeError, "source changed"):
                suite.validate_prepared(prepared, [binary])
        with patch.object(suite.native, "source_digest", return_value="source-one"), \
             patch.object(suite.native, "digest", return_value="binary-two"):
            with self.assertRaisesRegex(RuntimeError, "binary hash mismatch"):
                suite.validate_prepared(prepared, [binary])
        with patch.object(suite.native, "source_digest", return_value="source-one"), \
             patch.object(suite.native, "digest", return_value="binary-one"):
            suite.validate_prepared(prepared, [binary])

    def testPhysicalEncoderHasIndependentGoldenKeys(self):
        for char, layout, expected in [("t", suite.EN, (17, False)), ("y", suite.EN, (16, False)),
                                       ("е", suite.RU, (17, False)), ("н", suite.RU, (16, False)),
                                       (",", suite.RU, (44, True)), (".", suite.RU, (44, False)),
                                       (",", suite.EN, (43, False)), ("B", suite.EN, (11, True))]:
            self.assertEqual(suite.key(char, layout), expected)
        actions = suite.cases()[0]["stimulus"]["actions"]
        self.assertEqual([a["keyCode"] for a in actions[:14:2]], [2, 17, 7, 17, 4, 38, 9])

    def testFirstContinuationDoesNotWaitForReplacement(self):
        for case in suite.cases()[:2]:
            presses = [a for a in case["stimulus"]["actions"] if a["kind"] == "keyDown"]
            space = next(i for i, a in enumerate(presses) if a["keyCode"] == 49)
            self.assertEqual(presses[space + 1]["atMicroseconds"] - presses[space]["atMicroseconds"], 2000)
        race = suite.cases()[3]["stimulus"]["actions"]
        self.assertEqual(race[4]["kind"], "keyDown")
        self.assertEqual(race[4]["atMicroseconds"] - race[2]["atMicroseconds"], 2000)

    def testOraclesRejectNoOpMixedLayoutAndDeletedNeighbors(self):
        case = suite.cases()[3]
        actions = case["stimulus"]["actions"]
        host = dict(pid=1, status="complete", unexpectedInputCount=0, quartzTapAvailable=True,
                    quartzTapInterrupted=False, clipboardChangeCountDelta=0,
                    text=case["oracle"]["outcomes"][0]["text"], manualCheckpoints=[
                        dict(id="final", focused=True, clipboardChangeCountDelta=0)])
        host["receivedEvents"] = [dict(kind=a["kind"], keyCode=a["keyCode"], marker=i + 1)
                                  for i, a in enumerate(actions) if a["kind"] != "checkpoint"]
        host["quartzEvents"] = list(host["receivedEvents"])
        host["selection"] = [len(host["text"]), 0]
        app = dict(pid=2, status="complete", targetProcessID=1, automaticConversion=False,
                   modelAvailable=True, posted=0, callbackTimingOverflow=False,
                   callbackTimings=[dict(actionIndex=i, eventKind=a["kind"], consumed=False,
                                        keyCode=a["keyCode"], startedNanoseconds=1000, finishedNanoseconds=2000)
                       for i, a in enumerate(actions) if a["kind"] in ("keyDown", "flagsChanged")])
        driver = dict(pid=3, status="complete", restoredLayout=True, maximumLatenessMicroseconds=0,
                      finalLayoutID=suite.EN, records=[dict(actionIndex=i) for i in range(len(actions))])
        self.assertEqual(suite.assess(case, host, app, driver, [1, 2, 3], False, 0), [])
        protected = dict(case, oracle=dict(case["oracle"], learningExcluded=True))
        app["manualCheckpoints"] = [dict(id="final", learnedEntryCount=0, learningUndoAvailable=False)]
        self.assertEqual(suite.assess(protected, host, app, driver, [1, 2, 3], False, 0), [])
        learned = dict(app, manualCheckpoints=[dict(id="final", learnedEntryCount=1, learningUndoAvailable=True)])
        self.assertIn("excluded-pair-learned", suite.assess(protected, host, learned, driver, [1, 2, 3], False, 0))
        no_evidence = dict(app, manualCheckpoints=[])
        self.assertIn("missing-learning-readback", suite.assess(protected, host, no_evidence, driver, [1, 2, 3], False, 0))
        for text in ("dкфае тщеуыб фтв срусл шеуь К! ", "notes, and check item R! "):
            wrong = dict(host, text=text, selection=[len(text), 0])
            self.assertIn("text-or-layout-mismatch", suite.assess(case, wrong, app, driver, [1, 2, 3], False, 0))
        wrong_app = dict(app, callbackTimings=app["callbackTimings"][:-1])
        self.assertIn("missing-or-duplicate-callback", suite.assess(case, host, wrong_app, driver, [1, 2, 3], False, 0))
        wrong_host = dict(host, clipboardChangeCountDelta=2)
        self.assertIn("clipboard-changed", suite.assess(case, wrong_host, app, driver, [1, 2, 3], False, 0))
        auto = suite.cases()[0]
        no_op = dict(host, text=suite.cases()[2]["oracle"]["outcomes"][0]["text"])
        self.assertIn("text-or-layout-mismatch", suite.assess(auto, no_op, app, driver, [1, 2, 3], True, 0))


if __name__ == "__main__":
    unittest.main()
