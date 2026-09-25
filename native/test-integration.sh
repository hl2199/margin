#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
web_source="${1:-$project_root/dist}"
run_root="${2:-$project_root/build/integration}"
mkdir -p "$run_root"
if [[ -e "$run_root/web" ]]; then
  echo "Run directory already contains a web snapshot; choose a fresh output directory." >&2
  exit 2
fi
cp -R "$web_source" "$run_root/web"
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$project_root/build/module-cache" \
  -framework AppKit -framework WebKit "$project_root/native/MarkdownFile.swift" \
  "$project_root/native/DocumentAssets.swift" "$project_root/native/IntegrationTests.swift" \
  -parse-as-library -o "$run_root/integration-tests"
"$run_root/integration-tests" "$run_root/web" "$run_root/results.json" 2>&1 | tee "$run_root/output.txt"
