#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_image="$project_root/assets/icon/source.png"
iconset="$project_root/build/Margin.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$source_image" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  /usr/bin/sips -z "$retina_size" "$retina_size" "$source_image" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$project_root/build/Margin.icns"
echo "Built $project_root/build/Margin.icns"
