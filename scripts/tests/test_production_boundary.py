import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("boundary", ROOT / "scripts/verify_production_boundary.py")
boundary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(boundary)


def package(test_host):
    env = dict(os.environ, RUSWITCH_TEST_HOST=str(int(test_host)))
    return json.loads(subprocess.check_output(
        ["swift", "package", "describe", "--type", "json"], cwd=ROOT, env=env, text=True))


class ProductionBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.production = package(False)
        cls.host = package(True)

    def testEveryKnownTestMarkerIsRejected(self):
        for marker in boundary.TEST_MARKERS:
            with self.subTest(marker=marker):
                self.assertEqual(boundary.test_markers(b"binary\0" + marker + b"\0"),
                                 [item.decode("ascii") for item in boundary.TEST_MARKERS if item in marker])
        self.assertEqual(boundary.test_markers(b"LayoutDecoder\0InputSession\0TextConverter"), [])

    def testOnlyTestConfigurationCompilesProbeFilesAndSupport(self):
        prod = next(t for t in self.production["targets"] if t["name"] == "RuSwitcher")
        host = next(t for t in self.host["targets"] if t["name"] == "RuSwitcher")
        self.assertEqual(set(prod["target_dependencies"]), {"RuSwitcherCore", "RuSwitcherAppSupport"})
        self.assertIn("RuSwitcherTestSupport", host["target_dependencies"])
        self.assertIn("RuSwitcherProduction/main.swift", prod["sources"])
        self.assertFalse(any("RuSwitcherTestHost/" in p for p in prod["sources"]))
        self.assertIn("RuSwitcherTestHost/main.swift", host["sources"])
        self.assertFalse(any("RuSwitcherProduction/" in p for p in host["sources"]))
        for name in ("HIDIntegrationProbe", "ExternalNativeProbe", "AXResolverProbe", "SettingsSnapshotRenderer"):
            self.assertIn("RuSwitcherTestHost/" + name + ".swift", host["sources"])

    def testBothConfigurationsUseExactlyTheSameRuntimeFiles(self):
        def runtime(description):
            target = next(t for t in description["targets"] if t["name"] == "RuSwitcher")
            return {p for p in target["sources"] if p.startswith("RuSwitcher/")}
        self.assertEqual(runtime(self.production), runtime(self.host))
        self.assertIn("RuSwitcher/AppDelegate.swift", runtime(self.host))
        self.assertIn("RuSwitcher/TextConverter.swift", runtime(self.host))

    def testProductsCannotBeConfused(self):
        prod = {p["name"] for p in self.production["products"]}
        host = {p["name"] for p in self.host["products"]}
        self.assertIn("RuSwitcher", prod)
        self.assertNotIn("CerfSwitcherTestHost", prod)
        self.assertIn("CerfSwitcherTestHost", host)
        self.assertNotIn("RuSwitcher", host)

    def testAppSupportDoesNotContainTestConfiguration(self):
        target = next(t for t in self.production["targets"] if t["name"] == "RuSwitcherAppSupport")
        self.assertNotIn("RuntimePreferencesDomain.swift", target["sources"])
        self.assertNotIn("ExternalNativeProbeConfiguration.swift", target["sources"])


if __name__ == "__main__":
    unittest.main()
