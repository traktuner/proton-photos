#!/bin/bash
# Build the app and install it as the single canonical /Applications/Proton Photos.app, then launch.
#
# RULE (do not break): there must always, after every build without exception, be exactly ONE openable
# Proton Photos.app, and it must live in /Applications - so Spotlight search only ever finds that one.
# To guarantee it, the build output lives under a `*.noindex` derived-data folder: Spotlight skips any
# directory whose name ends in `.noindex` (the same reason Xcode's own `Intermediates.noindex` never
# shows up while `Products` would). So the build product is never indexed, and /Applications is the only
# bundle Spotlight knows about. Any ad-hoc `xcodebuild` must use this same `-derivedDataPath`.
#
# RULE (do not break): the repo lives on a network share (TrueNAS). NOTHING may be built into the
# repo tree - all build output goes to the local Mac under $PROTONPHOTOS_BUILD_ROOT
# (default: ~/Developer/xcode/ProtonPhotos). Building into the repo pushes every object file
# over SMB and must never happen again.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

BUILD_ROOT="${PROTONPHOTOS_BUILD_ROOT:-$HOME/Developer/xcode/ProtonPhotos}"
DD="$BUILD_ROOT/DD.noindex"
SPM_SCRATCH="$BUILD_ROOT/SPM.noindex"
mkdir -p "$BUILD_ROOT"
# Remove legacy in-repo build dirs (pre-NAS layout) so no stale product lingers on the share.
rm -rf build Packages/ProtonPhotosKit/.build
find "$HOME/Library/Developer/Xcode/DerivedData" \
  \( -path "*/Build/Products/*/ProtonPhotos.app" -o -path "*/Build/Products/*/Proton Photos.app" \) \
  -prune -exec rm -rf {} + 2>/dev/null || true
PROJECT="ProtonPhotos.xcodeproj"
SCHEME="ProtonPhotos"

echo "Preflight: generating Xcode project"
xcodegen generate >/dev/null

echo "Preflight: building ProtonPhotosMobile shell for generic iOS"
SKIP_XCODEGEN=1 ./scripts/verify-ios-app-shell.sh

SIGNING_IDENTITY_HASH="${PROTONPHOTOS_CODE_SIGN_IDENTITY:-}"
SIGNING_IDENTITY_NAME=""
if [[ -z "$SIGNING_IDENTITY_HASH" ]]; then
  SIGNING_LINE="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/ { print; exit }')"
  SIGNING_IDENTITY_HASH="$(awk '{ print $2 }' <<<"$SIGNING_LINE")"
  SIGNING_IDENTITY_NAME="$(awk -F'"' '{ print $2 }' <<<"$SIGNING_LINE")"
fi

SIGN_ARGS=(CODE_SIGNING_ALLOWED=YES)
if [[ -n "$SIGNING_IDENTITY_HASH" ]]; then
  SIGN_ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNING_IDENTITY_HASH")
  if [[ "$SIGNING_IDENTITY_NAME" =~ \(([A-Z0-9]+)\)$ ]]; then
    SIGN_ARGS+=(DEVELOPMENT_TEAM="${BASH_REMATCH[1]}")
  fi
  echo "Signing with: ${SIGNING_IDENTITY_NAME:-$SIGNING_IDENTITY_HASH}"
else
  echo "Signing with: Xcode default (no Apple Development identity found)"
fi

echo "Preflight: validating grid profile configuration"
plutil -lint Packages/ProtonPhotosKit/Sources/TimelineCore/Resources/GridProfiles.plist >/dev/null
xcrun swift test --package-path Packages/ProtonPhotosKit --scratch-path "$SPM_SCRATCH" --filter TimelineGridProfileConfigurationTests

echo "Preflight: building $SCHEME scheme for generic macOS"
xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
  -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation "${SIGN_ARGS[@]}"

echo "Install build: building $SCHEME for local arm64 launch"
xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
  -skipPackagePluginValidation -skipMacroValidation "${SIGN_ARGS[@]}"

APP="$DD/Build/Products/Debug/Proton Photos.app"
DST="/Applications/Proton Photos.app"
LEGACY_DST="/Applications/ProtonPhotos.app"

pkill -9 -f "Proton Photos.app/Contents/MacOS" 2>/dev/null || true
pkill -9 -f "ProtonPhotos.app/Contents/MacOS" 2>/dev/null || true
sleep 1
rm -rf "$DST"
rm -rf "$LEGACY_DST"
cp -R "$APP" "$DST"
xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST"
open "$DST"
echo "Installed + launched: $DST"
echo "Spotlight bundles (must be exactly one - /Applications):"
{
  mdfind -name "Proton Photos.app" 2>/dev/null
  mdfind -name "ProtonPhotos.app" 2>/dev/null
} | grep -Ei "Proton ?Photos.app$" || true
