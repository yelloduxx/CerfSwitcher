#!/usr/bin/env python3
"""Test production rule persistence across real process exits, without desktop input."""
import hashlib
import json
from pathlib import Path
import subprocess
import uuid


def validate_result(row, request, pid):
    if (not isinstance(row, dict) or row.get("runID") != request["runID"]
            or row.get("action") != request["action"] or type(row.get("pid")) is not int or row["pid"] != pid
            or type(row.get("ruleCount")) is not int or row["ruleCount"] < 0
            or any(type(row.get(key)) is not bool for key in ("confirmed", "applicationException", "globalConfirmed"))
            or row.get("outcome") not in ("none", "ignored", "confirmed", "application-exception")):
        raise ValueError("foreign or malformed persistence result")


def main():
    root = Path(__file__).resolve().parent.parent
    run_id = str(uuid.uuid4()).upper()
    directory = root / ".build/learning-store-runs" / run_id
    directory.mkdir(parents=True)
    summary = dict(status="invalidRun", runID=run_id, checks=[])
    binary = None
    original, converted = "ешдщьукфй", "tilomeraq"

    def call(action, app="editor.first", reverse=False):
        request = dict(runID=run_id, action=action, original=converted if reverse else original,
                       converted=original if reverse else converted, appBundleID=app)
        path = directory / f"{len(summary['checks']):02d}-{action}.json"
        path.write_text(json.dumps(request, ensure_ascii=False))
        command = [str(binary), "--learning-store-probe", str(path)]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            stdout, stderr = process.communicate(timeout=15)
        except BaseException:
            process.kill()
            process.communicate()
            raise
        if process.returncode != 0:
            raise subprocess.CalledProcessError(process.returncode, command, stdout, stderr)
        row = json.loads(stdout)
        validate_result(row, request, process.pid)
        row["appContext"] = app
        row["reverse"] = reverse
        summary["checks"].append(row)
        return row

    try:
        with (directory / "build.log").open("w") as log:
            subprocess.run(["swift", "build", "-c", "release", "--product", "RuSwitcherTypingSimulator",
                            "-Xswiftc", "-warnings-as-errors"], cwd=root, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=600)
        binary = Path(subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"],
                                             cwd=root, text=True).strip()) / "RuSwitcherTypingSimulator"
        summary["binarySHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()

        def expect(row, **values):
            row["expected"] = values
            if any(row.get(key) != value for key, value in values.items()):
                raise ValueError(f"persistence expectation failed: {row['action']}")

        expect(call("inspect"), ruleCount=0, confirmed=False)
        expect(call("record"), outcome="confirmed", confirmed=True, globalConfirmed=True)
        expect(call("inspect", "editor.second"), confirmed=True)
        expect(call("record", "editor.second", reverse=True), outcome="application-exception")
        expect(call("inspect", "editor.second"), confirmed=False, applicationException=True, globalConfirmed=True)
        expect(call("inspect"), confirmed=True, applicationException=False)
        call("export")
        call("clear")
        expect(call("inspect"), ruleCount=0, confirmed=False)
        call("restore")
        expect(call("inspect"), confirmed=True)
        expect(call("inspect", "editor.second"), confirmed=False, applicationException=True)
        expect(call("record", "editor.second"), outcome="confirmed", confirmed=True, applicationException=False)
        expect(call("inspect", "editor.second"), confirmed=True)
        if len({row["pid"] for row in summary["checks"]}) != len(summary["checks"]):
            raise ValueError("persistence checks did not run in distinct processes")
        summary["status"] = "passed"
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        summary["error"] = str(error)
    finally:
        if binary is not None:
            try:
                call("clear")
                summary["cleaned"] = call("inspect")["ruleCount"] == 0
            except (OSError, ValueError, subprocess.SubprocessError):
                summary["cleaned"] = False
            if not summary["cleaned"]:
                summary["status"] = "invalidRun"
        (directory / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
