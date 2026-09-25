#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/build"
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$project_root/build/module-cache" \
  -framework AppKit -framework WebKit "$project_root/native/DocumentZoom.swift" "$project_root/native/ZoomTests.swift" \
  -parse-as-library -o "$project_root/build/zoom-tests"
"$project_root/build/zoom-tests" "$project_root/build/zoom-tests.json"
