from __future__ import annotations

from pathlib import Path
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "build_app.sh"
EXECUTABLE = "RuSwitcherPro"
SPM_PRODUCT = "RuSwitcher"
MODEL = "language-model-v1.bin"
NOTICES = ("THIRD_PARTY_NOTICES.md", "SCOWL_COPYRIGHT.txt", "RUSSIAN_HUNSPELL_COPYRIGHT.txt")
VERSION = {"version": "9.8.7", "build": "654", "dev": "t"}
UNIVERSAL = ("arm64", "x86_64")
SWIFT_STUB = """#!/bin/sh
printf '%s\\n' "$*" >> "$STUB_SWIFT_LOG"
for argument in "$@"; do
    if [ "$argument" = "--show-bin-path" ]; then
        printf '%s\\n' "$STUB_PRODUCTS"
    fi
done
exit 0
"""
SECURITY_STUB = """#!/bin/sh
echo "     0 valid identities found"
exit 0
"""
UNSIGNED_MARKER = "UNSIGNED: bundle is for CI checks only and is not installable"


def compile_universal(destination: Path) -> None:
    source = destination.with_suffix(".c")
    source.write_text("int main(void){return 0;}\n")
    flags = [flag for name in UNIVERSAL for flag in ("-arch", name)]
    subprocess.run(["cc", str(source), "-o", str(destination), *flags],
                   check=True, capture_output=True)


class BuildAppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = Path(tempfile.mkdtemp(prefix="build-app-shared-"))
        cls.addClassCleanup(shutil.rmtree, cls.shared, ignore_errors=True)
        cls.universal_binary = cls.shared / SPM_PRODUCT
        compile_universal(cls.universal_binary)

    def setUp(self):
        self.project = Path(tempfile.mkdtemp(prefix="build-app-project-"))
        self.addCleanup(shutil.rmtree, self.project, ignore_errors=True)
        shutil.copy2(SCRIPT, self.project / "build_app.sh")
        for name in ("Info.plist", "RuSwitcher.icns",
                     "THIRD_PARTY_NOTICES.md"):
            shutil.copy2(REPOSITORY / name, self.project / name)
        (self.project / "scripts" / "data").mkdir(parents=True)
        for name in NOTICES[1:]:
            shutil.copy2(REPOSITORY / "scripts" / "data" / name,
                         self.project / "scripts" / "data" / name)
        (self.project / "version.json").write_text(
            '{"version": "%(version)s", "build": "%(build)s", "dev": "%(dev)s"}' % VERSION)

        self.products = self.project / "stub-products" / "Release"
        self.model_bytes = b"model-bytes-for-test"
        resources = self.products / "RuSwitcher_RuSwitcherCore.bundle" / "Contents" / "Resources"
        resources.mkdir(parents=True)
        (resources / MODEL).write_bytes(self.model_bytes)
        shutil.copy2(self.universal_binary, self.products / SPM_PRODUCT)

        stubs = self.project / "stubs"
        stubs.mkdir()
        for name, body in (("swift", SWIFT_STUB), ("security", SECURITY_STUB)):
            (stubs / name).write_text(body)
            (stubs / name).chmod(0o755)
        self.swift_log = self.project / "swift-calls.log"
        self.environment = {
            key: value for key, value in os.environ.items()
            if key not in ("SIGN_ID", "RUSWITCH_UNSIGNED_BUNDLE")
        }
        self.environment.update(
            PATH=f"{stubs}{os.pathsep}{os.environ['PATH']}",
            STUB_PRODUCTS=str(self.products),
            STUB_SWIFT_LOG=str(self.swift_log),
        )
        self.bundle = self.project / f"{EXECUTABLE}.app"

    def run_script(self, **overrides: str) -> subprocess.CompletedProcess:
        environment = dict(self.environment, **overrides)
        return subprocess.run(["bash", str(self.project / "build_app.sh")],
                              cwd=self.project, env=environment,
                              capture_output=True, text=True, timeout=120)

    def swift_calls(self) -> list[str]:
        return self.swift_log.read_text().splitlines() if self.swift_log.exists() else []

    def testUnsignedOptInBuildsBundleStampedFromVersionJson(self):
        result = self.run_script(RUSWITCH_UNSIGNED_BUNDLE="1")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn(UNSIGNED_MARKER, result.stdout)
        self.assertNotIn("Signed with", result.stdout)
        with open(self.bundle / "Contents" / "Info.plist", "rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["CFBundleShortVersionString"], VERSION["version"])
        self.assertEqual(info["CFBundleVersion"], VERSION["build"])
        self.assertEqual(info["RSDevTag"], VERSION["dev"])
        self.assertEqual(info["CFBundleExecutable"], EXECUTABLE)
        self.assertTrue((self.bundle / "Contents" / "MacOS" / EXECUTABLE).is_file())
        self.assertFalse((self.bundle / "Contents" / "_CodeSignature").exists())

    def testUnsignedOptInBundlesModelAndNotices(self):
        result = self.run_script(RUSWITCH_UNSIGNED_BUNDLE="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        resources = self.bundle / "Contents" / "Resources"
        self.assertEqual((resources / MODEL).read_bytes(), self.model_bytes)
        for name in NOTICES:
            self.assertTrue((resources / name).is_file(), name)

    def testBinPathQueryUsesTheBuildFlags(self):
        result = self.run_script(RUSWITCH_UNSIGNED_BUNDLE="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.swift_calls()
        self.assertEqual(len(calls), 2, calls)
        build = "build -c release --arch arm64 --arch x86_64 --product " + SPM_PRODUCT
        self.assertEqual(calls, [build, build + " --show-bin-path"])

    def testMissingSigningIdentityWithoutOptInFails(self):
        result = self.run_script()
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ERROR: no signing identity found.", output)
        self.assertNotIn("UNSIGNED", output)
        self.assertNotIn("Done", output)

    def testEmptySignIdDoesNotSkipSigning(self):
        result = self.run_script(SIGN_ID="")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ERROR: no signing identity found.", output)
        self.assertNotIn("Done", output)

    def testOptInValueOtherThanOneStillRequiresSigning(self):
        result = self.run_script(RUSWITCH_UNSIGNED_BUNDLE="0")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ERROR: no signing identity found.", output)
        self.assertNotIn("UNSIGNED", output)

    def testOptInTogetherWithSignIdFailsBeforeBuilding(self):
        result = self.run_script(RUSWITCH_UNSIGNED_BUNDLE="1", SIGN_ID="Some Identity")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RUSWITCH_UNSIGNED_BUNDLE", output)
        self.assertIn("SIGN_ID", output)
        self.assertEqual(self.swift_calls(), [])
        self.assertFalse(self.bundle.exists())

    def testMissingProductNamesTheReportedBinPath(self):
        (self.products / SPM_PRODUCT).unlink()
        result = self.run_script(RUSWITCH_UNSIGNED_BUNDLE="1")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"ERROR: built product not found: {self.products / SPM_PRODUCT}", output)

    def testMissingResourceBundleNamesTheReportedBinPath(self):
        shutil.rmtree(self.products / "RuSwitcher_RuSwitcherCore.bundle")
        result = self.run_script(RUSWITCH_UNSIGNED_BUNDLE="1")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(self.products / "RuSwitcher_RuSwitcherCore.bundle"), output)

    def testScriptNeverSignsAdHoc(self):
        text = SCRIPT.read_text()
        self.assertIsNone(re.search(r"--sign\s+['\"]?-['\"]?(\s|$)", text, re.MULTILINE))


if __name__ == "__main__":
    unittest.main()
