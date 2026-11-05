#!/bin/zsh
# Builds build/release/Unearth.dmg: a Developer ID signed app in a signed, notarized and stapled disk image.
#
# Once per Mac, store your notarization login in the keychain. This asks for an app-specific password:
#   xcrun notarytool store-credentials unearth-notary --apple-id <your Apple ID> --team-id VXX54355D8
#
# Then: scripts/release.sh
# Add --no-notarize to stop before Apple's check, which needs no login.
set -euo pipefail

cd "${0:A:h}/.."
OUT=build/release
PROFILE=${NOTARY_PROFILE:-unearth-notary}
IDENTITY="Developer ID Application"
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

rm -rf "$OUT/Unearth.xcarchive" "$OUT/Unearth.dmg"
mkdir -p "$OUT"

echo "Building and signing the app..."
xcodebuild -project Unearth.xcodeproj -scheme Unearth -configuration Release -derivedDataPath "$OUT/DerivedData" \
  -archivePath "$OUT/Unearth.xcarchive" OTHER_CODE_SIGN_FLAGS="--timestamp" archive -quiet

APP="$OUT/Unearth.xcarchive/Products/Applications/Unearth.app"
codesign --verify --deep --strict "$APP"
codesign --display --entitlements - "$APP" 2>/dev/null | grep -q 'get-task-allow' && { echo "The app is still debuggable: not a release build."; exit 1; }

echo "Making the disk image..."
python3 -m venv "$OUT/dmgbuild"
"$OUT/dmgbuild/bin/pip" install --quiet --disable-pip-version-check dmgbuild==1.6.5
"$OUT/dmgbuild/bin/dmgbuild" -s scripts/dmg/settings.py -D app="$APP" Unearth "$OUT/Unearth.dmg"
codesign --force --sign "$IDENTITY" --timestamp "$OUT/Unearth.dmg"

if (( NOTARIZE )); then
  echo "Sending it to Apple for notarization. This usually takes a few minutes..."
  xcrun notarytool submit "$OUT/Unearth.dmg" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$OUT/Unearth.dmg"
  xcrun stapler validate "$OUT/Unearth.dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$OUT/Unearth.dmg"
fi

ls -lh "$OUT/Unearth.dmg"
shasum -a 256 "$OUT/Unearth.dmg"
