from __future__ import annotations

from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "verify_v3_only_build.sh"
EXECUTABLE = "RuSwitcherPro"
DESCRIPTION = {
    "targets": [
        {"name": "RuSwitcher", "target_dependencies": ["RuSwitcherCore", "RuSwitcherAppSupport"]},
        {"name": "RuSwitcherSimulator", "target_dependencies": ["RuSwitcherCore"]},
        {"name": "RuSwitcherTypingSimulator",
         "target_dependencies": ["RuSwitcherCore", "RuSwitcherAppSupport", "RuSwitcherTestSupport"]},
    ]
}
STUB = f"""#!/bin/sh
if [ "$1" = "package" ]; then
    cat <<'JSON'
{json.dumps(DESCRIPTION)}
JSON
    exit 0
fi
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--output" ]; then
        printf '{{"engine":"v3","failed":0}}' > "$2"
    fi
    shift
done
exit 0
"""
REQUIRED_TOOLS = ("jq", "cc", "lipo")
UNIVERSAL = ("arm64", "x86_64")


def compile_binary(destination: Path, source: str, *flags: str,
                   architectures: tuple[str, ...] = UNIVERSAL) -> None:
    source_file = destination.with_suffix(".c")
    source_file.write_text(source)
    architecture_flags = [flag for name in architectures for flag in ("-arch", name)]
    subprocess.run(["cc", str(source_file), "-o", str(destination), *architecture_flags, *flags],
                   check=True, capture_output=True)


class VerifyV3BundleChecksTests(unittest.TestCase):
    def setUp(self):
        missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
        self.assertEqual(missing, [], f"required tools not found on PATH: {missing}")
        self.directory = Path(tempfile.mkdtemp(prefix="verify-v3-bundle-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        (self.directory / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.directory / "scripts" / SCRIPT.name)
        (self.directory / "Sources" / "RuSwitcher").mkdir(parents=True)
        stubs = self.directory / "stubs"
        stubs.mkdir()
        (stubs / "swift").write_text(STUB)
        (stubs / "swift").chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{stubs}{os.pathsep}{os.environ['PATH']}")

    def make_bundle(self) -> Path:
        bundle = self.directory / "Fake.app"
        shutil.rmtree(bundle, ignore_errors=True)
        (bundle / "Contents" / "MacOS").mkdir(parents=True)
        (bundle / "Contents" / "Resources").mkdir()
        (bundle / "Contents" / "Resources" / "language-model-v1.bin").write_bytes(b"model")
        with open(bundle / "Contents" / "Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleExecutable": EXECUTABLE}, handle)
        return bundle

    def binary(self, bundle: Path) -> Path:
        return bundle / "Contents" / "MacOS" / EXECUTABLE

    def run_script(self, *arguments: Path) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(self.directory / "scripts" / SCRIPT.name),
                               *map(str, arguments)],
                              cwd=self.directory, env=self.environment,
                              capture_output=True, text=True, timeout=120)

    def testCleanMachOBundlePasses(self):
        bundle = self.make_bundle()
        compile_binary(self.binary(bundle), "int main(void){return 0;}")
        result = self.run_script(bundle)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: production package, simulator and app bundle are V3-only", result.stdout)
        self.assertNotIn("SKIP", result.stdout)

    def testBundleWithoutExecutableFails(self):
        result = self.run_script(self.make_bundle())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(EXECUTABLE, result.stdout + result.stderr)
        self.assertNotIn("PASS", result.stdout)

    def testTextFileInsteadOfMachOFails(self):
        bundle = self.make_bundle()
        self.binary(bundle).write_text("#!/bin/sh\nexit 0\n")
        self.binary(bundle).chmod(0o755)
        result = self.run_script(bundle)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PASS", result.stdout)

    def testCoreMLLinkStillFails(self):
        bundle = self.make_bundle()
        compile_binary(self.binary(bundle), "int main(void){return 0;}", "-framework", "CoreML")
        result = self.run_script(bundle)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("production executable links CoreML", result.stdout)

    def testAlternateDecoderSymbolStillFails(self):
        bundle = self.make_bundle()
        compile_binary(self.binary(bundle),
                       "int SmartAutoConvertEngine(void){return 1;}\nint main(void){return SmartAutoConvertEngine();}")
        result = self.run_script(bundle)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("alternate decoder symbol found in application executable", result.stdout)

    def testMissingLanguageModelFails(self):
        bundle = self.make_bundle()
        compile_binary(self.binary(bundle), "int main(void){return 0;}")
        (bundle / "Contents" / "Resources" / "language-model-v1.bin").unlink()
        result = self.run_script(bundle)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("language-model-v1.bin", result.stdout)
        self.assertNotIn("PASS", result.stdout)

    def testSingleArchitectureExecutableFails(self):
        for architecture in UNIVERSAL:
            with self.subTest(architecture=architecture):
                bundle = self.make_bundle()
                compile_binary(self.binary(bundle), "int main(void){return 0;}",
                               architectures=(architecture,))
                result = self.run_script(bundle)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("not universal", result.stdout)
                self.assertNotIn("PASS", result.stdout)

    def testAbsentDefaultBundleIsReportedAsSkipped(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SKIP: app bundle checks", result.stdout)
        self.assertNotIn("app bundle are V3-only", result.stdout)

    def testExplicitMissingBundleFails(self):
        result = self.run_script(self.directory / "Missing.app")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing.app", result.stdout + result.stderr)
        self.assertNotIn("PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
