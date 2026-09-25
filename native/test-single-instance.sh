#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
run_root="$(mktemp -d /private/tmp/margin-single-instance-tests.XXXXXX)"
mkdir -p "$project_root/build"
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "${MARGIN_TEST_MODULE_CACHE:-$project_root/build/module-cache}" \
  -framework AppKit "$project_root/native/SingleInstance.swift" "$project_root/native/SingleInstanceTests.swift" \
  -o "$run_root/Test"
"$run_root/Test" --unit
python3 "$project_root/native/test-single-instance.py" "$run_root" "${1:-$project_root/build/single-instance-tests.json}"
