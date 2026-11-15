import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
PRODUCT = "CerfSwitcherTestHost"
IDENTITY = "RuSwitcher Local Code Signing"


class TestHostScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "project with spaces"
        (self.root / "scripts/data").mkdir(parents=True)
        for name in ("build_test_host.sh", "ruswitch_test_app.sh", "render_settings_snapshots.sh",
                     "run_ax_resolver_probe.sh", "run_hid_batch_tests.sh",
                     "run_manual_learning_test.sh", "run_manual_toggle_cycle_test.sh"):
            shutil.copy2(SCRIPTS / name, self.root / "scripts" / name)
        self.original_plist = plistlib.dumps(dict(CFBundleIdentifier="com.cerfswitcher.app",
                                                 CFBundleExecutable="CerfSwitcher"))
        (self.root / "Info.plist").write_bytes(self.original_plist)
        (self.root / "version.json").write_text('{"version":"4.0.0","build":162,"dev":"test"}')
        for name in ("RuSwitcher.icns", "THIRD_PARTY_NOTICES.md", "RuSwitcher.entitlements",
                     "scripts/data/SCOWL_COPYRIGHT.txt", "scripts/data/RUSSIAN_HUNSPELL_COPYRIGHT.txt"):
            (self.root / name).write_text(name)
        self.products = self.root / "stub products"
        model = self.products / "RuSwitcher_RuSwitcherCore.bundle/Contents/Resources/language-model-v1.bin"
        model.parent.mkdir(parents=True)
        model.write_bytes(b"compiled model")
        self.write_executable(self.products / PRODUCT, """
import json, os, sys
with open(os.environ['LAUNCH_LOG'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
""")
        self.bin = self.root / "stub-bin"
        self.bin.mkdir()
        self.write_executable(self.bin / "swift", """
import json, os, sys
with open(os.environ['SWIFT_LOG'], 'a') as stream:
    stream.write(json.dumps({'args': sys.argv[1:], 'testHost': os.environ.get('RUSWITCH_TEST_HOST')}) + '\\n')
if '--show-bin-path' in sys.argv:
    print(os.environ['PRODUCTS'])
""")
        self.write_executable(self.bin / "codesign", """
import json, os, sys
with open(os.environ['SIGN_LOG'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
if '-dv' in sys.argv:
    print('Authority=' + os.environ.get('STUB_AUTHORITY', 'RuSwitcher Local Code Signing'))
""")
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('RUSWITCH_') and key != 'SIGN_ID'}
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ['PATH'], PRODUCTS=str(self.products),
                        SWIFT_LOG=str(self.root / "swift.jsonl"), SIGN_LOG=str(self.root / "sign.jsonl"),
                        LAUNCH_LOG=str(self.root / "launch.jsonl"))
        self.app = self.root / ".build/test-host/apps" / (PRODUCT + ".app")

    def write_executable(self, path, body):
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o755)

    def run_script(self, name, *args, **env):
        return subprocess.run(["bash", str(self.root / "scripts" / name), *map(str, args)],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def records(self, name):
        path = self.root / (name + ".jsonl")
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def build(self):
        result = self.run_script("build_test_host.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def validate(self, **env):
        return subprocess.run(["bash", "-c", 'source "$1/scripts/ruswitch_test_app.sh"; '
                               'ruswitch_validate_test_app "$1"', "gate", str(self.root)],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def change_info(self, app=None, **values):
        path = (app or self.app) / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update(values)
        path.write_bytes(plistlib.dumps(info))

    def testBuilderUsesExplicitProductAndIsolatedScratch(self):
        self.build()
        calls = self.records("swift")
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertEqual(call['testHost'], '1')
            args = call['args']
            self.assertEqual(args[args.index('--product') + 1], PRODUCT)
            self.assertEqual(args[args.index('--scratch-path') + 1], str(self.root / '.build/test-host'))
            self.assertEqual(args[args.index('-c') + 1], 'release')
            self.assertIn('-warnings-as-errors', args)
        self.assertIn('--show-bin-path', calls[1]['args'])
        self.assertEqual((self.root / 'Info.plist').read_bytes(), self.original_plist)
        info = plistlib.loads((self.app / 'Contents/Info.plist').read_bytes())
        self.assertIs(info['RSTestHost'], True)
        self.assertEqual(info['CFBundleIdentifier'], 'com.cerfswitcher.testhost')
        self.assertEqual(info['CFBundleExecutable'], PRODUCT)
        self.assertEqual((info['CFBundleShortVersionString'], info['CFBundleVersion']), ('4.0.0', '162'))
        resources = self.app / 'Contents/Resources'
        self.assertEqual((resources / 'language-model-v1.bin').read_bytes(), b'compiled model')
        self.assertEqual({p.name for p in resources.iterdir()}, {
            'language-model-v1.bin', 'RuSwitcher.icns', 'THIRD_PARTY_NOTICES.md',
            'SCOWL_COPYRIGHT.txt', 'RUSSIAN_HUNSPELL_COPYRIGHT.txt'})
        signing = self.records('sign')
        self.assertEqual(signing[0][signing[0].index('--sign') + 1], IDENTITY)
        self.assertIn('--entitlements', signing[0])
        self.assertIn('--verify', signing[1])
        self.assertEqual(self.records('launch'), [])

    def testOutputOverrideDoesNotChangeScratchOrProduction(self):
        out = self.root / 'live bundles'
        result = self.run_script('build_test_host.sh', out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((out / (PRODUCT + '.app')).is_dir())
        self.assertFalse(self.app.exists())
        self.assertEqual((self.root / 'Info.plist').read_bytes(), self.original_plist)

    def testUnsafeSigningFailsBeforeBuild(self):
        for env in ({'SIGN_ID': '-'}, {'RUSWITCH_UNSIGNED_BUNDLE': '1'}):
            with self.subTest(env=env):
                result = self.run_script('build_test_host.sh', **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.records('swift'), [])

    def testFailedSigningPreservesPreviousBundle(self):
        self.build()
        marker = self.app / 'previous-bundle'
        marker.write_text('preserve')
        result = self.run_script('build_test_host.sh', STUB_AUTHORITY='wrong authority')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), 'preserve')
        self.assertEqual(list(self.app.parent.glob('.test-host.*')), [])

    def testMissingModelNeverPublishesBundle(self):
        shutil.rmtree(self.products / 'RuSwitcher_RuSwitcherCore.bundle')
        result = self.run_script('build_test_host.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.app.exists())
        self.assertEqual(self.records('sign'), [])

    def testDefaultGateAcceptsSourceBuiltTestBundle(self):
        self.build()
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('com.cerfswitcher.testhost 4.0.0+162', result.stderr)

    def testProductionOrFalseMarkerCannotUseEscapeHatches(self):
        self.build()
        for info in ({'RSTestHost': False}, {'RSTestHost': 'true'},
                     {'CFBundleIdentifier': 'com.cerfswitcher.app'}, {'CFBundleExecutable': 'CerfSwitcher'}):
            with self.subTest(info=info):
                self.change_info(RSTestHost=True, CFBundleIdentifier='com.cerfswitcher.testhost',
                                 CFBundleExecutable=PRODUCT)
                self.change_info(**info)
                result = self.validate(RUSWITCH_ALLOW_HASH_MISMATCH='1', RUSWITCH_ALLOW_VERSION_MISMATCH='1',
                                       RUSWITCH_EXPECTED_BUNDLE_ID=info.get('CFBundleIdentifier', 'com.cerfswitcher.testhost'))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('not a test-only application', result.stderr)

    def testVersionAndHashReferenceGatesRemainExact(self):
        self.build()
        copy = self.root / 'copy.app'
        shutil.copytree(self.app, copy)
        self.change_info(copy, CFBundleVersion='161')
        self.assertNotEqual(self.validate(RUSWITCH_APP=str(copy)).returncode, 0)
        self.assertNotEqual(self.validate(RUSWITCH_APP=str(copy), RUSWITCH_ALLOW_VERSION_MISMATCH='1').returncode, 0)
        self.change_info(copy, CFBundleVersion='162')
        (copy / 'Contents/MacOS' / PRODUCT).write_text('changed')
        self.assertNotEqual(self.validate(RUSWITCH_APP=str(copy)).returncode, 0)
        self.assertEqual(self.validate(RUSWITCH_APP=str(copy), RUSWITCH_ALLOW_HASH_MISMATCH='1').returncode, 0)
        self.change_info(RSTestHost=False)
        self.assertNotEqual(self.validate(RUSWITCH_APP=str(copy)).returncode, 0)

    def testWrappersPassOnlyTheirRecognizedMode(self):
        out = self.root / 'snapshots output'
        result = self.run_script('render_settings_snapshots.sh', 'prefix', out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.records('launch'), [
            ['--render-settings-snapshots', str(out), 'prefix-' + lang,
             '-com.ruswitcher.interfaceLanguage', lang] for lang in ('ru', 'en')])
        result = self.run_script('run_ax_resolver_probe.sh', '1234')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.records('launch')[-1], ['--ax-resolver-probe', '1234'])

    def testWrapperRejectsConfiguredProductionBundleBeforeLaunch(self):
        production = self.root / 'production.app'
        (production / 'Contents').mkdir(parents=True)
        (production / 'Contents/Info.plist').write_bytes(self.original_plist)
        for name, args in [('render_settings_snapshots.sh', []), ('run_ax_resolver_probe.sh', ['1234'])]:
            result = self.run_script(name, *args, RUSWITCH_APP=str(production), RUSWITCH_ALLOW_HASH_MISMATCH='1')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('not a test-only application', result.stderr)
        self.assertEqual(self.records('launch'), [])

    def testMissingAXArgumentDoesNotBuildOrLaunch(self):
        result = self.run_script('run_ax_resolver_probe.sh')
        self.assertEqual(result.returncode, 64)
        self.assertEqual(self.records('swift'), [])
        self.assertEqual(self.records('launch'), [])

    def testLegacyInputStopsBeforeTouchingDesktopWhenAnotherSwitcherRuns(self):
        self.build()
        self.write_executable(self.bin / "ps", """
print('/Applications/CerfSwitcher.app/Contents/MacOS/CerfSwitcher')
""")
        for name in ('open', 'pkill', 'kill', 'defaults'):
            self.write_executable(self.bin / name, """
import os
from pathlib import Path
Path(os.environ['LAUNCH_LOG']).write_text('unexpected desktop action')
raise SystemExit(99)
""")
        for name in ('run_hid_batch_tests.sh', 'run_manual_learning_test.sh', 'run_manual_toggle_cycle_test.sh'):
            result = self.run_script(name)
            self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
            self.assertIn('BLOCKED:', result.stderr)
        self.assertFalse((self.root / 'launch.jsonl').exists())

    def testIdleGateAcceptsUnrelatedApplications(self):
        self.write_executable(self.bin / "ps", "print('/Applications/Notes.app/Contents/MacOS/Notes')\n")
        result = subprocess.run(["bash", "-c", 'source "$1/scripts/ruswitch_test_app.sh"; '
                                 'ruswitch_require_idle_desktop', "gate", str(self.root)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
