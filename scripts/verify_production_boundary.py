#!/usr/bin/env python3
"""Reject test entry points in a release executable without launching it."""

import argparse
from pathlib import Path
import subprocess
import sys


TEST_MARKERS = (
    b"--hid-probe", b"--external-native-probe", b"--ax-resolver-probe",
    b"--render-settings-snapshots", b"--force-keyboard-deletion-fallback",
    b"--force-synthetic-input-fallback", b"--force-ax-unavailable-fallback",
    b"--force-global-event-stream", b"HIDIntegrationProbe",
    b"ExternalNativeProbe", b"AXResolverProbe", b"SettingsSnapshotRenderer",
    b"RuntimePreferencesDomain", b"RuSwitcherTestSupport", b"sampleDictionary",
)


def test_markers(data):
    return [marker.decode("ascii") for marker in TEST_MARKERS if marker in data]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    args = parser.parse_args(argv)
    # Fail on missing/non-Mach-O input as well as contamination.
    subprocess.run(["lipo", "-archs", str(args.executable)],
                   check=True, stdout=subprocess.DEVNULL)
    found = test_markers(args.executable.read_bytes())
    if found:
        print("FAIL: test code in production executable: " + ", ".join(found), file=sys.stderr)
        return 1
    print("PASS: no test entry points, force switches or test support in production executable")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
