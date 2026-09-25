"""Exercise standard NSWorkspace delivery using an isolated, unique test app ID."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import uuid

root = Path(sys.argv[1])
identifier = f"local.margin.single-instance-test.{uuid.uuid4()}"
log = root / "events.txt"
processes = []
checks = []

def check(name, condition):
    checks.append({"name": name, "passed": bool(condition)})
    assert condition, name

def wait_for(predicate, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        lines = log.read_text().splitlines() if log.exists() else []
        if predicate(lines):
            return lines
        time.sleep(0.05)
    raise AssertionError(f"Timeout; events: {log.read_text() if log.exists() else '<none>'}")

def launch(binary, *args, legacy=False, previous_identifier=None):
    environment = {**os.environ, "MARGIN_TEST_LOG": str(log), "MARGIN_TEST_LEGACY": "1" if legacy else "0"}
    if previous_identifier:
        environment["MARGIN_TEST_LEGACY_IDENTIFIER"] = previous_identifier
    process = subprocess.Popen([str(binary), *args], env=environment,
                               stdout=subprocess.DEVNULL, stderr=(root / "stderr.txt").open("a"))
    processes.append(process)
    return process

try:
    binaries = []
    for name in ["First", "Copy", "Migrated"]:
        bundle = root / f"{name}.app"
        executable = bundle / "Contents/MacOS/Test"
        executable.parent.mkdir(parents=True)
        shutil.copy2(root / "Test", executable)
        with (bundle / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": identifier + (".migrated" if name == "Migrated" else ""), "CFBundleExecutable": "Test",
                          "CFBundleName": "Margin Instance Test", "CFBundlePackageType": "APPL"}, handle)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(bundle)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        binaries.append(executable)
    primary = launch(binaries[0])
    wait_for(lambda lines: f"{primary.pid} primary" in lines)
    check("primary is a regular foreground app", f"{primary.pid} policy 0" in log.read_text().splitlines())
    document = root / "document with spaces.md"
    document.write_text("# Test\n")
    duplicate = launch(binaries[1], str(document))
    lines = wait_for(lambda lines: f"{primary.pid} open {document}" in lines and f"{duplicate.pid} forwarded" in lines)
    check("copied app forwards file URL through NSWorkspace to original process", f"{primary.pid} open {document}" in lines)
    check("duplicate exits after delivery", duplicate.wait(timeout=10) == 0)
    check("duplicate is accessory while forwarding", f"{duplicate.pid} policy 1" in lines)
    reopened = launch(binaries[1])
    lines = wait_for(lambda lines: f"{primary.pid} reopen" in lines and f"{reopened.pid} forwarded" in lines)
    check("plain launch sends reopen to existing process", f"{primary.pid} reopen" in lines)
    check("plain duplicate exits after delivery", reopened.wait(timeout=10) == 0)
    check("one primary remains alive", primary.poll() is None and sum(line.endswith(" primary") for line in lines) == 1)
    primary.terminate()
    primary.wait(timeout=10)
    old = launch(binaries[0], legacy=True)
    wait_for(lambda lines: f"{old.pid} legacy-primary" in lines)
    new = launch(binaries[1], str(document))
    lines = wait_for(lambda lines: f"{old.pid} open {document}" in lines and f"{new.pid} forwarded" in lines)
    check("existing legacy app without coordination lock receives file", f"{old.pid} open {document}" in lines)
    check("legacy redirect exits only after delivery", new.wait(timeout=10) == 0)
    check("legacy process is preserved", old.poll() is None)
    old.terminate()
    old.wait(timeout=10)
    migration_owner = launch(binaries[0])
    wait_for(lambda lines: f"{migration_owner.pid} primary" in lines)
    migrated = launch(binaries[2], str(document), previous_identifier=identifier)
    lines = wait_for(lambda lines: f"{migration_owner.pid} open {document}" in lines and f"{migrated.pid} forwarded" in lines)
    check("new app identity forwards to a running previous identity", migrated.wait(timeout=10) == 0)
    check("identity migration preserves the old running app", migration_owner.poll() is None)
    migration_owner.terminate()
    migration_owner.wait(timeout=10)
    migrated_owner = launch(binaries[2], previous_identifier=identifier)
    wait_for(lambda lines: f"{migrated_owner.pid} primary" in lines)
    migrated_copy = launch(binaries[2], str(document), previous_identifier=identifier)
    wait_for(lambda lines: f"{migrated_owner.pid} open {document}" in lines and f"{migrated_copy.pid} forwarded" in lines)
    check("migrated identity keeps one primary for subsequent launches", migrated_copy.wait(timeout=10) == 0 and migrated_owner.poll() is None)
    migrated_owner.terminate()
    migrated_owner.wait(timeout=10)
    simultaneous = [launch(binary) for binary in binaries[:2]]
    lines = wait_for(lambda lines: sum(f"{p.pid} primary" in lines for p in simultaneous) == 1 and
                     sum(f"{p.pid} forwarded" in lines for p in simultaneous) == 1)
    owners = [p for p in simultaneous if f"{p.pid} primary" in lines]
    followers = [p for p in simultaneous if f"{p.pid} duplicate" in lines]
    check("near-simultaneous launches elect exactly one primary", len(owners) == 1 and len(followers) == 1)
    check("near-simultaneous duplicate forwards and exits", followers[0].wait(timeout=10) == 0)
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
    result = {"bundleIdentifier": identifier, "runRoot": str(root), "checks": checks,
              "events": log.read_text().splitlines() if log.exists() else [], "userAppsTouched": False}
    Path(sys.argv[2]).write_text(json.dumps(result, indent=2) + "\n")
print(f"PASS {len(checks)} isolated process integration checks; artifacts: {root}")
