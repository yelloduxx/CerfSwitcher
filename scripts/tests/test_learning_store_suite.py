import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("learning_suite", Path(__file__).parents[1] / "run_learning_store_suite.py")
SUITE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUITE)


class LearningStoreResultTests(unittest.TestCase):
    def testCompleteTypedResultBelongsToTheActualChild(self):
        row = dict(runID="current", action="inspect", pid=12, ruleCount=1,
                   confirmed=True, applicationException=False, globalConfirmed=True, outcome="none")
        request = dict(runID="current", action="inspect")
        SUITE.validate_result(row, request, 12)
        for replacement in [dict(pid=13), dict(runID="old"), dict(action="record")]:
            with self.assertRaises(ValueError):
                SUITE.validate_result(dict(row, **replacement), request, 12)

    def testBooleansAndCountsCannotImpersonateEachOther(self):
        row = dict(runID="current", action="inspect", pid=12, ruleCount=1,
                   confirmed=True, applicationException=False, globalConfirmed=True, outcome="none")
        for replacement in [dict(ruleCount=True), dict(confirmed=1), dict(applicationException=0), dict(ruleCount=-1)]:
            with self.assertRaises(ValueError):
                SUITE.validate_result(dict(row, **replacement), dict(runID="current", action="inspect"), 12)


if __name__ == "__main__":
    unittest.main()
