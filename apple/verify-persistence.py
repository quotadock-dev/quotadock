#!/usr/bin/env python3
"""Run the real-storage XCTest across distinct simulator host processes.

Build with xcodebuild build-for-testing first. Use a disposable simulator: the
test deliberately replaces synthetic authority and preferences in the app.
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctestrun", type=Path, required=True)
    parser.add_argument("--simulator-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    assert any(device["udid"] == args.simulator_id for runtime, entries in devices["devices"].items()
               if "iOS" in runtime for device in entries), "An available iOS simulator UUID is required"
    source = args.xctestrun.resolve()
    with source.open("rb") as handle:
        run = plistlib.load(handle)
    if "TestConfigurations" in run:
        candidates = [target for config in run["TestConfigurations"] for target in config["TestTargets"]]
    else:
        candidates = [value for value in run.values() if isinstance(value, dict)]
    targets = [target for target in candidates if target.get("BlueprintName") == "QuotaDockTests"]
    assert len(targets) == 1, "Expected exactly one hosted QuotaDockTests target"
    args.output.mkdir(parents=True, exist_ok=False)

    # Keep the derived plist beside its source so __TESTROOT__ paths still refer
    # to the original signed products. Never rewrite the caller's xctestrun.
    with tempfile.NamedTemporaryFile(dir=source.parent, suffix=".xctestrun", delete=False) as handle:
        configured = Path(handle.name)
    try:
        for phase in ["seed", "bridge", "cloud", "renewed", "rejected", "bridge-again",
                      "cloud-again", "switched-bridge", "signed-out", "interrupted"]:
            targets[0].setdefault("EnvironmentVariables", {})["QUOTADOCK_PERSISTENCE_PHASE"] = phase
            with configured.open("wb") as handle:
                plistlib.dump(run, handle)
            command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured),
                       "-destination", f"platform=iOS Simulator,id={args.simulator_id}",
                       "-parallel-testing-enabled", "NO",
                       "-only-testing:QuotaDockTests/NativePersistenceTests/testProductionPersistence",
                       "-resultBundlePath", str(args.output.resolve() / f"{phase}.xcresult")]
            print(f"Running persistence phase: {phase}", flush=True)
            with (args.output / f"{phase}.log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            # XCTest success alone is insufficient if the test filter matched
            # nothing or the environment failed to reach the hosted test.
            log = (args.output / f"{phase}.log").read_text()
            assert f"PERSISTENCE phase={phase} pid=" in log, f"Phase did not execute; inspect {phase}.log"
        print("All ten real Keychain/App Group process-relaunch phases passed.")
    finally:
        configured.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
