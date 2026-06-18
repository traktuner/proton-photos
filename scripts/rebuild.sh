#!/bin/bash
# Build the app and install it as the single canonical /Applications/ProtonPhotos.app, then launch.
#
# RULE (do not break): there must always, after every build without exception, be exactly ONE openable
# ProtonPhotos.app, and it must live in /Applications — so Spotlight search only ever finds that one.
# To guarantee it, the build output lives under a `*.noindex` derived-data folder: Spotlight skips any
# directory whose name ends in `.noindex` (the same reason Xcode's own `Intermediates.noindex` never
# shows up while `Products` would). So the build product is never indexed, and /Applications is the only
# bundle Spotlight knows about. Any ad-hoc `xcodebuild` must use this same `-derivedDataPath`.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

DD="build/DD.noindex"
rm -rf build/DD   # remove any legacy INDEXED build dir so its product stops appearing in Spotlight

xcodebuild build -project ProtonPhotos.xcodeproj -scheme ProtonPhotos \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=YES

APP="$DD/Build/Products/Debug/ProtonPhotos.app"
DST="/Applications/ProtonPhotos.app"

pkill -9 -f "ProtonPhotos.app/Contents/MacOS" 2>/dev/null || true
sleep 1
rm -rf "$DST"
cp -R "$APP" "$DST"
xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST"
open "$DST"
echo "Installed + launched: $DST"
echo "Spotlight bundles (must be exactly one — /Applications):"
mdfind -name "ProtonPhotos.app" 2>/dev/null | grep -i "ProtonPhotos.app$" || true
