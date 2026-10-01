#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
run_root="${1:-$project_root/build/lifecycle-check}"
if [[ -e "$run_root" ]]; then echo 'Choose a fresh run root.' >&2; exit 2; fi
bundle="$run_root/LifecycleTests.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp -R "$project_root/dist" "$bundle/Contents/Resources/web"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.margin.lifecycle-tests</string><key>CFBundleExecutable</key><string>LifecycleTests</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$project_root/build/module-cache" -framework AppKit -framework WebKit -framework PDFKit \
  "$project_root/native/MarkdownFile.swift" "$project_root/native/DocumentAssets.swift" "$project_root/native/DocumentZoom.swift" \
  "$project_root/native/SingleInstance.swift" "$project_root/native/PDFExport.swift" "$project_root/native/DocumentImages.swift" "$project_root/native/Application.swift" "$project_root/native/LifecycleTests.swift" \
  -parse-as-library -o "$bundle/Contents/MacOS/LifecycleTests"
/usr/bin/codesign --force --sign - "$bundle"
"$bundle/Contents/MacOS/LifecycleTests" "$run_root/results.json" 2>&1 | tee "$run_root/output.txt"
