#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/build"
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$project_root/build/module-cache" \
  "$project_root/native/MarkdownFile.swift" "$project_root/native/FileTests.swift" \
  -o "$project_root/build/file-tests"
"$project_root/build/file-tests"
