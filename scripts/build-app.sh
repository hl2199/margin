#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$project_root/build/Margin.app"
if [[ ! -f "$project_root/dist/index.html" ]]; then
  echo 'Missing dist/index.html. Run npm run build first.' >&2
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/web"
bash "$project_root/scripts/build-icon.sh"
icon_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$project_root/native/Info.plist")
cp "$project_root/build/Margin.icns" "$app/Contents/Resources/$icon_name"
# A universal binary runs on Apple Silicon and Intel Macs.
for arch in arm64 x86_64; do
  /usr/bin/xcrun swiftc -swift-version 5 -O -target "$arch-apple-macosx13.0" \
    -module-cache-path "$project_root/build/module-cache" \
    -framework AppKit -framework WebKit \
    "$project_root/native/MarkdownFile.swift" "$project_root/native/DocumentAssets.swift" "$project_root/native/DocumentZoom.swift" \
    "$project_root/native/SingleInstance.swift" "$project_root/native/Application.swift" "$project_root/native/main.swift" \
    -o "$project_root/build/Margin-$arch"
done
/usr/bin/lipo -create "$project_root/build/Margin-arm64" "$project_root/build/Margin-x86_64" -output "$app/Contents/MacOS/Margin"
cp "$project_root/native/Info.plist" "$app/Contents/Info.plist"
# Replace only this generated app's web directory so stale hashed assets vanish.
rm -rf "$app/Contents/Resources/web"
cp -R "$project_root/dist" "$app/Contents/Resources/web"
/usr/bin/codesign --force --sign - "$app"
echo "Built $app"
