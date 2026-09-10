import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPTS = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("physical_suite", SCRIPTS / "run_physical_typing_suite.py")
SUITE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUITE)


class PhysicalCadenceTests(unittest.TestCase):
    def testRollsAfterSpaceWithoutShorteningHeldKeysOrChangingOrdinaryCadence(self):
        source = []
        for index, code in enumerate([0, 49, 9, 3]):
            source.extend([dict(kind="keyDown", keyCode=code, atMicroseconds=index * 70_000),
                           dict(kind="keyUp", keyCode=code, atMicroseconds=index * 70_000 + 23_000)])
        actual, mapping = SUITE.rolling_space_actions(source)
        downs = [a for a in actual if a["kind"] == "keyDown"]
        self.assertEqual([a["atMicroseconds"] for a in downs], [0, 70_000, 75_000, 145_000])
        self.assertLess(mapping[4], mapping[3])  # Next letter is pressed while Space is held.
        for down in range(0, len(source), 2):
            self.assertEqual(actual[mapping[down + 1]]["atMicroseconds"]
                             - actual[mapping[down]]["atMicroseconds"], 23_000)
            self.assertEqual(actual[mapping[down]]["keyCode"], source[down]["keyCode"])
        self.assertEqual(source[4]["atMicroseconds"], 140_000)

    def testConsecutiveSpacesRemainBalanced(self):
        source = [dict(kind=kind, keyCode=49, atMicroseconds=at)
                  for kind, at in [("keyDown", 0), ("keyUp", 23_000), ("keyDown", 70_000), ("keyUp", 93_000)]]
        self.assertEqual(SUITE.rolling_space_actions(source)[0], source)

    def testUnsupportedOrUnbalancedSourceCannotProduceAValidLookingFixture(self):
        for source in [[], [dict(kind="selectLayout", atMicroseconds=0, layoutID="en")],
                       [dict(kind="keyDown", keyCode=49, atMicroseconds=0, command=True)],
                       [dict(kind="keyUp", keyCode=49, atMicroseconds=0)],
                       [dict(kind="keyDown", keyCode=49, atMicroseconds=0)]]:
            with self.assertRaises(ValueError):
                SUITE.rolling_space_actions(source)
        with self.assertRaises(ValueError):
            SUITE.rolling_space_actions([], gap_microseconds=0)


if __name__ == "__main__":
    unittest.main()
