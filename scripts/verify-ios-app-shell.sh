#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Repo lives on a network share - build output must stay on the local Mac (see rebuild.sh).
BUILD_ROOT="${PROTONPHOTOS_BUILD_ROOT:-$HOME/Developer/xcode/ProtonPhotos}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$BUILD_ROOT/DD.ios.noindex}"
export DEVELOPER_DIR

cd "$ROOT"

if [[ "${SKIP_XCODEGEN:-0}" != "1" ]]; then
  xcodegen generate >/dev/null
fi

xcodebuild build \
  -project ProtonPhotos.xcodeproj \
  -scheme ProtonPhotosMobile \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO
