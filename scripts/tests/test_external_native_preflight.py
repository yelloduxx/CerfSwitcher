import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("external_preflight_suite", Path(__file__).parents[1] / "run_external_native_suite.py")
SUITE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUITE)


class NativePreflightTests(unittest.TestCase):
    def testHelpersDoNotAdvertiseThemselvesAsCompetingSwitcherApps(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "input-binary"
            binary.write_bytes(b"not executed")
            bundle, executable = SUITE.bundle(binary, root, "RuSwitcherNativeDriver", "com.ruswitcher.native-driver",
                                               display_name="Keyboard Test Driver")
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            self.assertEqual(executable.name, "RuSwitcherNativeDriver")
            self.assertEqual(info["CFBundleIdentifier"], "com.ruswitcher.native-driver")
            self.assertEqual(info["CFBundleDisplayName"], "Keyboard Test Driver")
            self.assertNotIn("RuSwitcher", info["CFBundleName"])

    def testSamplingIsForbiddenInReadOnlyModes(self):
        for mode in ("--prepare-only", "--preflight-only"):
            with patch("sys.stderr", new_callable=io.StringIO), \
                 patch.object(SUITE.subprocess, "Popen", side_effect=AssertionError("launched a process")), \
                 self.assertRaises(SystemExit) as caught:
                SUITE.main([mode, "--sample-process"])
            self.assertEqual(caught.exception.code, 2)

    def run_preflight(self, permission_exit):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binaries = root / "bin"
            binaries.mkdir()
            for name in ("RuSwitcher", "RuSwitcherNativeDriver", "RuSwitcherNativeEditorHost"):
                (binaries / name).write_bytes(b"test binary; never executed")
            resources = root / "Sources/RuSwitcherCore/Resources"
            resources.mkdir(parents=True)
            (resources / "language-model-v1.bin").write_bytes(b"test model")
            (root / "RuSwitcher.icns").write_bytes(b"test icon")
            (root / "RuSwitcher.entitlements").write_bytes(plistlib.dumps({}))
            (root / "Info.plist").write_bytes(plistlib.dumps({}))
            (root / "version.json").write_text('{"version":"4.0.0","build":130}')
            fixture = root / "fixture.json"
            fixture.write_text(json.dumps({"stimulus": {"layoutIDs": ["en", "ru"]}}))
            run_dir = root / "run"
            run_dir.mkdir()
            commands = []

            def run(command, **kwargs):
                commands.append(command)
                self.assertTrue(command[0] in ("swift", "codesign")
                                or "--self-check" in command or "--preflight" in command)
                code = permission_exit if "--preflight" in command else 0
                return subprocess.CompletedProcess(command, code, stdout="read-only access result\n", stderr="")

            with patch.dict(os.environ, {}, clear=True), \
                 patch("sys.stdout", new_callable=io.StringIO), \
                 patch.object(SUITE, "source_digest", return_value="source-sha"), \
                 patch.object(SUITE.tempfile, "mkdtemp", return_value=str(run_dir)), \
                 patch.object(SUITE.subprocess, "run", side_effect=run), \
                 patch.object(SUITE.subprocess, "check_output", side_effect=[str(binaries), "commit-sha"]), \
                 patch.object(SUITE, "running_switchers", side_effect=AssertionError("preflight enumerated apps")), \
                 patch.object(SUITE, "run_case", side_effect=AssertionError("preflight opened a host")), \
                 patch.object(SUITE, "restore_installed", side_effect=AssertionError("preflight restarted an app")), \
                 patch.object(SUITE.os, "kill", side_effect=AssertionError("preflight stopped an app")):
                result = SUITE.main(["--preflight-only", "--restart-installed-pro", "--fixture", str(fixture)], root=root)
            summary = json.loads((run_dir / "summary.json").read_text())
            return result, summary, commands

    def testDeniedPreflightReadsBothProcessesWithoutDesktopAccess(self):
        code, summary, commands = self.run_preflight(77)
        self.assertEqual(code, 77)
        self.assertEqual(summary["status"], "blockedEnvironment")
        self.assertEqual(summary["cases"], [])
        self.assertEqual(len(summary["preflights"]), 2)
        self.assertEqual(sum("--preflight" in command for command in commands), 2)
        app_sign = next(command for command in commands if command[0] == "codesign" and "--sign" in command
                        and command[-1].endswith("/RuSwitcherPro.app"))
        self.assertIn("runtime", app_sign)
        self.assertIn("--entitlements", app_sign)

    def testGrantedPreflightIsNotANativePassAndNeverStopsInstalledApp(self):
        code, summary, _ = self.run_preflight(0)
        self.assertEqual(code, 0)
        self.assertEqual(summary["status"], "permissionsReadyNotRun")
        self.assertEqual(summary["cases"], [])
        self.assertNotIn("restoredInstalledApp", summary)

    def testReportsSurviveRuntimeCleanupWithoutArchivingApplications(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "runtime"
            (runtime / "positive").mkdir(parents=True)
            (runtime / "Test.app/Contents").mkdir(parents=True)
            (runtime / "Test.app/Contents/binary").write_bytes(b"not evidence")
            SUITE.write_json(runtime / "positive/host-result.json", {"text": "test phrase, complete!"})
            summary = dict(runID="run-one", status="blockedEnvironment", cases=[dict(directory=str(runtime / "positive"))])
            archived = SUITE.archive_run(root, runtime, summary)
            shutil.rmtree(runtime)
            archive = Path(archived["artifactDirectory"])
            self.assertFalse((archive / "Test.app").exists())
            self.assertEqual(json.loads((archive / "summary.json").read_text()), archived)
            self.assertEqual(json.loads((Path(archived["cases"][0]["artifactDirectory"]) / "host-result.json").read_text()),
                             {"text": "test phrase, complete!"})

    def testArchiveCannotOverwriteEarlierRunEvidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "runtime"
            runtime.mkdir()
            summary = dict(runID="run-one", status="preparedNotRun", cases=[])
            archived = SUITE.archive_run(root, runtime, summary)
            evidence = Path(archived["artifactDirectory"]) / "summary.json"
            original = evidence.read_bytes()
            with self.assertRaises(FileExistsError):
                SUITE.archive_run(root, runtime, dict(summary, status="passed"))
            self.assertEqual(evidence.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
