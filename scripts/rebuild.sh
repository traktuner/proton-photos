#!/bin/bash
# Build and install the current macOS app. When Firestarter is available, also build, install and
# launch the signed iOS app. Build products stay on the local Mac because the repo is on TrueNAS.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

BUILD_ROOT="${PROTONPHOTOS_BUILD_ROOT:-$HOME/Developer/xcode/ProtonPhotos}"
MAC_DD="$BUILD_ROOT/DD.noindex"
IOS_DD="$BUILD_ROOT/DD.device.noindex"
PROJECT="ProtonPhotos.xcodeproj"
MAC_SCHEME="ProtonPhotos"
IOS_SCHEME="ProtonPhotosMobile"
IOS_DEVICE_NAME="${PROTONPHOTOS_IOS_DEVICE_NAME:-Firestarter}"
IOS_DEVELOPMENT_TEAM="${PROTONPHOTOS_IOS_DEVELOPMENT_TEAM:-587T3YR252}"
IOS_BUNDLE_ID="me.protonphotos.ios"

mkdir -p "$BUILD_ROOT"

echo "Generating Xcode project"
xcodegen generate >/dev/null

SIGNING_IDENTITY_HASH="${PROTONPHOTOS_CODE_SIGN_IDENTITY:-}"
SIGNING_IDENTITY_NAME=""
if [[ -z "$SIGNING_IDENTITY_HASH" ]]; then
    SIGNING_LINE="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/ { print; exit }')"
    SIGNING_IDENTITY_HASH="$(awk '{ print $2 }' <<<"$SIGNING_LINE")"
    SIGNING_IDENTITY_NAME="$(awk -F'"' '{ print $2 }' <<<"$SIGNING_LINE")"
fi

MAC_SIGN_ARGS=(CODE_SIGNING_ALLOWED=YES)
if [[ -n "$SIGNING_IDENTITY_HASH" ]]; then
    MAC_SIGN_ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNING_IDENTITY_HASH")
    echo "macOS signing: ${SIGNING_IDENTITY_NAME:-$SIGNING_IDENTITY_HASH}"
else
    echo "macOS signing: Xcode default"
fi

echo "Building macOS app"
xcodebuild build -project "$PROJECT" -scheme "$MAC_SCHEME" \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$MAC_DD" \
    -skipPackagePluginValidation -skipMacroValidation "${MAC_SIGN_ARGS[@]}"

MAC_APP="$MAC_DD/Build/Products/Debug/Proton Photos.app"
MAC_DST="/Applications/Proton Photos.app"
LEGACY_MAC_DST="/Applications/ProtonPhotos.app"

pkill -9 -f "Proton Photos.app/Contents/MacOS" 2>/dev/null || true
pkill -9 -f "ProtonPhotos.app/Contents/MacOS" 2>/dev/null || true
sleep 1
rm -rf "$MAC_DST" "$LEGACY_MAC_DST"
cp -R "$MAC_APP" "$MAC_DST"
xattr -dr com.apple.quarantine "$MAC_DST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$MAC_DST"
open "$MAC_DST"
echo "Installed and launched macOS app: $MAC_DST"

IOS_DEVICE_ID="$(
    xcrun devicectl list devices \
        --filter "Name = '$IOS_DEVICE_NAME' AND State BEGINSWITH 'available'" \
        --columns Identifier --hide-default-columns --hide-headers --timeout 5 2>/dev/null \
        | awk 'NF { print $1; exit }' || true
)"

if [[ -z "$IOS_DEVICE_ID" ]]; then
    echo "iOS skipped: $IOS_DEVICE_NAME is not available"
    exit 0
fi

echo "Building iOS app for $IOS_DEVICE_NAME ($IOS_DEVICE_ID)"
xcodebuild build -project "$PROJECT" -scheme "$IOS_SCHEME" \
    -destination "id=$IOS_DEVICE_ID" -derivedDataPath "$IOS_DD" \
    -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$IOS_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic

IOS_APP="$IOS_DD/Build/Products/Debug-iphoneos/ProtonPhotosMobile.app"
echo "Installing iOS app on $IOS_DEVICE_NAME"
xcrun devicectl device install app --device "$IOS_DEVICE_ID" --timeout 120 "$IOS_APP"
xcrun devicectl device process launch --device "$IOS_DEVICE_ID" --timeout 30 \
    --terminate-existing "$IOS_BUNDLE_ID"
echo "Installed and launched iOS app on $IOS_DEVICE_NAME"
