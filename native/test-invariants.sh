#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
web_source="${1:-$project_root/dist}"
run_root="${2:?Pass fresh absolute run directory}"
if [[ -e "$run_root" ]]; then echo 'Choose a fresh run root.' >&2; exit 2; fi
mkdir -p "$run_root"
cp -R "$web_source" "$run_root/web"
cp "$project_root/native/invariant-checks.js" "$run_root/invariant-checks.js"
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$project_root/build/module-cache" -framework AppKit -framework WebKit "$project_root/native/InvariantTests.swift" -parse-as-library -o "$run_root/invariant-tests"
"$run_root/invariant-tests" "$run_root/web" "$run_root/results.json" "$run_root/invariant-checks.js" "$project_root/native/invariant-corpus" 2>&1 | tee "$run_root/output.txt"
