#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/build"
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$project_root/build/module-cache" \
  -framework WebKit "$project_root/native/MarkdownFile.swift" "$project_root/native/DocumentAssets.swift" \
  "$project_root/native/AssetTests.swift" -o "$project_root/build/asset-tests"
"$project_root/build/asset-tests"
