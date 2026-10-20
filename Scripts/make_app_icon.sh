#!/bin/bash
# Builds PureMac/Assets.xcassets/AppIcon.appiconset from a single 1024×1024 PNG.
#
#   Scripts/make_app_icon.sh                 # renders the placeholder icon, then installs it
#   Scripts/make_app_icon.sh path/to/icon.png  # installs your official icon (PNG, ≥1024×1024)
#
# SVG sources: export a 1024×1024 PNG first (e.g. from your design tool); asset catalogs need PNG/PDF.
set -euo pipefail
cd "$(dirname "$0")/.."

SET="PureMac/Assets.xcassets/AppIcon.appiconset"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SOURCE="${1:-}"
if [[ -z "$SOURCE" ]]; then
  swift Scripts/render_app_icon.swift "$WORK/source.png"
  SOURCE="$WORK/source.png"
fi

width=$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ {print $2}')
height=$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')
if [[ "$width" -lt 1024 || "$height" -lt 1024 ]]; then
  echo "error: icon must be at least 1024×1024 (got ${width}×${height})" >&2
  exit 1
fi

mkdir -p "$SET"
rm -f "$SET"/*.png
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  pt=${spec%%:*}; scale=${spec##*:}; px=$((pt * scale))
  suffix=""
  if [[ $scale == 2 ]]; then suffix="@2x"; fi
  name="icon_${pt}x${pt}${suffix}.png"
  sips -s format png -z "$px" "$px" "$SOURCE" --out "$SET/$name" >/dev/null
done

cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "Installed app icon into $SET"
