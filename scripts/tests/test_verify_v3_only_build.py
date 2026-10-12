from __future__ import annotations

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "verify_v3_only_build.sh"
V4_TARGET = """    targets: [
        .target(
            name: "RuSwitcherExperimentalV4",
            dependencies: ["RuSwitcherCore"],
            path: "Experimental/V4/Sources/RuSwitcherExperimentalV4"
        ),
"""
TOOLS = shutil.which("swift") and shutil.which("jq")


def copy_package(destination: Path, package_swift: str | None = None) -> Path:
    for name in ("Sources", "Tests", "Experimental"):
        shutil.copytree(REPOSITORY / name, destination / name,
                        ignore=shutil.ignore_patterns(".build"))
    (destination / "scripts").mkdir()
    shutil.copy2(SCRIPT, destination / "scripts" / SCRIPT.name)
    manifest = package_swift if package_swift is not None else (REPOSITORY / "Package.swift").read_text()
    (destination / "Package.swift").write_text(manifest)
    return destination / "scripts" / SCRIPT.name


def run_script(script: Path, environment: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(script)], cwd=script.parents[1], env=environment,
                          capture_output=True, text=True, timeout=1800)


@unittest.skipUnless(TOOLS, "swift and jq are required")
class VerifyV3OnlyBuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="verify-v3-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def testRealPackagePasses(self):
        result = run_script(SCRIPT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: production package", result.stdout)

    def testV4TargetInRootGraphFails(self):
        manifest = (REPOSITORY / "Package.swift").read_text()
        self.assertEqual(manifest.count("    targets: [\n"), 1)
        script = copy_package(self.directory, manifest.replace("    targets: [\n", V4_TARGET))
        result = run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("forbidden root target: RuSwitcherExperimentalV4", result.stdout + result.stderr)

    def testTypingSimulatorDependencyDriftFails(self):
        manifest = (REPOSITORY / "Package.swift").read_text()
        old = 'dependencies: ["RuSwitcherCore", "RuSwitcherAppSupport", "RuSwitcherTestSupport"],\n            path: "Sources/RuSwitcherTypingSimulator"'
        self.assertEqual(manifest.count(old), 1)
        new = old.replace('"RuSwitcherTestSupport"', '"RuSwitcherTestSupport", "RuSwitcherInputMethod"')
        script = copy_package(self.directory, manifest.replace(old, new))
        result = run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected typing simulator dependencies", result.stdout + result.stderr)

    def testAlternateDecoderReferenceFailsEvenWhenRipgrepAnswersNo(self):
        script = copy_package(self.directory)
        (self.directory / "Sources" / "RuSwitcher" / "Injected.swift").write_text(
            'let alternate = "ContextualLayoutDecoder"\n')
        stubs = self.directory / "stubs"
        stubs.mkdir()
        (stubs / "rg").write_text("#!/bin/sh\nexit 1\n")
        (stubs / "rg").chmod(0o755)
        environment = dict(os.environ, PATH=f"{stubs}{os.pathsep}{os.environ['PATH']}")
        result = run_script(script, environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("production executable still references an alternate decoder", result.stdout)


if __name__ == "__main__":
    unittest.main()
