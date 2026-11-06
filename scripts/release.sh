#!/bin/zsh
# Builds build/release/Unearth.dmg: a Developer ID signed, notarized and stapled app in a disk image that is all three
# too. The app needs a ticket of its own: once it's out of the image, a Mac that can't reach Apple has nothing else to go on.
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
# By its full name, here and in the project: an older Developer ID certificate can still be on this Mac.
IDENTITY='Developer ID Application: "UniCode" d.o.o. Brcko distrikt BiH (VXX54355D8)'
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

rm -rf "$OUT/Unearth.xcarchive" "$OUT/Unearth.dmg"
mkdir -p "$OUT"

echo "Building and signing the app..."
xcodebuild -project Unearth.xcodeproj -scheme Unearth -configuration Release -derivedDataPath "$OUT/DerivedData" \
  -archivePath "$OUT/Unearth.xcarchive" OTHER_CODE_SIGN_FLAGS="--timestamp" archive -quiet

APP="$OUT/Unearth.xcarchive/Products/Applications/Unearth.app"
codesign --verify --deep --strict "$APP"
[[ "$(codesign -dvv "$APP" 2>&1)" == *"Authority=$IDENTITY"* ]] || { echo "The app isn't signed with $IDENTITY."; exit 1; }
codesign --display --entitlements - "$APP" 2>/dev/null | grep -q 'get-task-allow' && { echo "The app is still debuggable: not a release build."; exit 1; }

if (( NOTARIZE )); then
  echo "Sending the app to Apple for notarization. This usually takes a few minutes..."
  ditto -c -k --keepParent "$APP" "$OUT/Unearth.zip"
  xcrun notarytool submit "$OUT/Unearth.zip" --keychain-profile "$PROFILE" --wait
  rm "$OUT/Unearth.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

echo "Making the disk image..."
python3 -m venv "$OUT/dmgbuild"
"$OUT/dmgbuild/bin/pip" install --quiet --disable-pip-version-check dmgbuild==1.6.5
"$OUT/dmgbuild/bin/dmgbuild" -s scripts/dmg/settings.py -D app="$APP" Unearth "$OUT/Unearth.dmg"
codesign --force --sign "$IDENTITY" --timestamp "$OUT/Unearth.dmg"

if (( NOTARIZE )); then
  echo "Sending the disk image to Apple for notarization..."
  xcrun notarytool submit "$OUT/Unearth.dmg" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$OUT/Unearth.dmg"
  xcrun stapler validate "$OUT/Unearth.dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$OUT/Unearth.dmg"
  # Apple's own check of what people will install: it fails the release if the app lost its ticket.
  syspolicy_check distribution "$APP"
fi

ls -lh "$OUT/Unearth.dmg"
shasum -a 256 "$OUT/Unearth.dmg"
