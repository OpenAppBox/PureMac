#!/bin/bash
# Archives the Mac App Store edition (configuration "AppStore": App Sandbox, user-selected
# folder access, security-scoped bookmarks) and exports a signed installer package.
#
# Requires an Apple Developer Program membership, signed in to Xcode (Settings → Accounts), and
# the app record com.openappbox.PureMac in App Store Connect. Nothing secret is stored in the repo.
#
#   TEAM_ID=ABCDE12345 Scripts/build_appstore.sh            # → dist/AppStore/PureMac.pkg
#   TEAM_ID=ABCDE12345 UPLOAD=1 Scripts/build_appstore.sh   # also uploads to App Store Connect
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
DERIVED="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/PureMac-appstore}"
ARCHIVE="dist/PureMac-AppStore.xcarchive"
EXPORT="dist/AppStore"
VERSION=$(grep -m1 'MARKETING_VERSION = ' PureMac.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/')

echo "==> Archive $VERSION (App Store edition)"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project PureMac.xcodeproj -scheme "PureMac App Store" -configuration AppStore \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates archive

APP="$ARCHIVE/Products/Applications/PureMac.app"
echo "==> Entitlements"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -E 'app-sandbox|user-selected|bookmarks'
echo "==> Architectures: $(lipo -archs "$APP/Contents/MacOS/PureMac")"

# The options file lives in its own temporary folder (xcodebuild wants a .plist name), removed on exit.
OPTIONS_DIR=$(mktemp -d)
trap 'rm -rf "$OPTIONS_DIR"' EXIT
OPTIONS="$OPTIONS_DIR/ExportOptions.plist"
sed "s/TEAM_ID_PLACEHOLDER/$TEAM_ID/" Config/ExportOptions-AppStore.plist > "$OPTIONS"
if [[ "${UPLOAD:-0}" == "1" ]]; then plutil -replace destination -string upload "$OPTIONS"; fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "$EXPORT" -allowProvisioningUpdates
echo "==> Done: $EXPORT"
