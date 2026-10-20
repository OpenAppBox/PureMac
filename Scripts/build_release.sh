#!/bin/bash
# Builds a Release PureMac.app into dist/. Without signing credentials the app is ad-hoc signed
# (runs on this Mac; NOT a distributable Developer ID build). For a distributable build, run
# Scripts/sign_and_notarize.sh afterwards (needs a Developer ID certificate and notary credentials).
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/PureMac-release}"
DIST="dist"
VERSION=$(grep -m1 'MARKETING_VERSION = ' PureMac.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/')
grep -q "^## $VERSION " CHANGELOG.md || echo "warning: CHANGELOG.md has no entry for $VERSION" >&2

echo "==> Release build $VERSION"
xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build

APP="$DERIVED/Build/Products/Release/PureMac.app"
BUILT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$BUILT" == "$VERSION" ]] || { echo "error: built app is $BUILT, project says $VERSION" >&2; exit 1; }
rm -rf "$DIST/PureMac.app"
mkdir -p "$DIST"
ditto "$APP" "$DIST/PureMac.app"

# Ad-hoc signature with the hardened runtime so the bundle is valid and launchable locally.
codesign --force --deep --options runtime --sign - "$DIST/PureMac.app"
codesign --verify --deep --strict "$DIST/PureMac.app"
echo "==> Architectures: $(lipo -archs "$DIST/PureMac.app/Contents/MacOS/PureMac")"
echo "==> Built $DIST/PureMac.app (ad-hoc signed, not notarized)"
