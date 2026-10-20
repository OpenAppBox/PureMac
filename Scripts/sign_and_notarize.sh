#!/bin/bash
# Developer ID signing + notarization. Requires credentials that are NOT stored in this repo:
#
#   export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
#   xcrun notarytool store-credentials puremac-notary --apple-id you@example.com --team-id TEAMID
#   export NOTARY_PROFILE=puremac-notary
#
# Then: Scripts/build_release.sh && Scripts/sign_and_notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile name}"
APP="dist/PureMac.app"
[[ -d "$APP" ]] || { echo "error: run Scripts/build_release.sh first" >&2; exit 1; }

security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID_APPLICATION" \
  || { echo "error: identity '$DEVELOPER_ID_APPLICATION' not found in the keychain" >&2; exit 1; }

echo "==> Signing with $DEVELOPER_ID_APPLICATION (hardened runtime, secure timestamp)"
codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP="dist/PureMac-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Submitting to Apple notary service"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm -f "$ZIP"

DMG_SUFFIX=notarized Scripts/make_dmg.sh
DMG=$(ls -t dist/PureMac-*-notarized.dmg | head -1)
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
echo "==> Notarized: $APP and $DMG"
