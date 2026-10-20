#!/bin/bash
# Packages dist/PureMac.app into a compressed disk image with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/PureMac.app"
[[ -d "$APP" ]] || { echo "error: $APP not found — run Scripts/build_release.sh first" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
SUFFIX="${DMG_SUFFIX:-unsigned}"
DMG="dist/PureMac-$VERSION-$SUFFIX.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/PureMac.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "PureMac $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> Created $DMG"
