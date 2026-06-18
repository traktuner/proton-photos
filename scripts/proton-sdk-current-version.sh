#!/bin/bash
# Print the Proton Drive SDK version currently vendored in Vendor/sdk-swift, plus the ProtonCore
# version its Package.swift requires (which project.yml must match exactly).
set -e
cd "$(dirname "$0")/.."
SDK_DIR="Vendor/sdk-swift"

if [ ! -d "$SDK_DIR/.git" ]; then
  echo "Vendor/sdk-swift not present. Clone it (see .gitignore for the command)." >&2
  exit 1
fi

TAG=$(git -C "$SDK_DIR" describe --tags --exact-match 2>/dev/null || echo "(no exact tag)")
SHA=$(git -C "$SDK_DIR" rev-parse HEAD)
CORE=$(grep -o 'protoncore_ios.git", exact: "[^"]*"' "$SDK_DIR/Package.swift" | grep -o '[0-9][0-9.]*')
APPCORE=$(grep -o 'exactVersion: *[0-9][0-9.]*' project.yml | grep -o '[0-9][0-9.]*' | head -1)

echo "sdk-swift tag:        $TAG"
echo "sdk-swift commit:     $SHA"
echo "SDK wants ProtonCore: $CORE"
echo "project.yml pins:     $APPCORE"
if [ "$CORE" != "$APPCORE" ]; then
  echo "WARNING: project.yml ($APPCORE) != SDK-required ProtonCore ($CORE). SwiftPM resolution will fail." >&2
fi
