#!/bin/bash
# Check out a Proton Drive SDK tag in Vendor/sdk-swift, apply this repo's local path-package linker
# patch, and report the ProtonCore version that project.yml must be set to. Does NOT edit project.yml
# or build - review the printed pin, update project.yml's ProtonCore exactVersion to match, then run
# scripts/rebuild.sh.
#
# Usage: scripts/update-proton-sdk.sh [<tag>]   (defaults to latest upstream tag)
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SDK_DIR="Vendor/sdk-swift"
REPO="https://github.com/ProtonDriveApps/sdk-swift.git"

if [ ! -d "$SDK_DIR/.git" ]; then
  echo "Cloning sdk-swift..."
  git clone "$REPO" "$SDK_DIR"
fi

git -C "$SDK_DIR" fetch --tags --quiet "$REPO"
TAG="${1:-$(git -C "$SDK_DIR" tag -l | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)}"

echo "Checking out sdk-swift $TAG..."
git -C "$SDK_DIR" checkout --quiet --force "refs/tags/$TAG"

echo "Applying local SDK path-package patch..."
perl -0pi -e 's~import PackageDescription~import Foundation\nimport PackageDescription\n\nlet packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path\nlet sdkResourceLibrarySearchPath = "-L\\(packageDirectory)/Resources"~' "$SDK_DIR/Package.swift"
perl -0pi -e 's~\n\s*\.unsafeFlags\(\[\n\s*// path used in normal builds\n\s*"-L\$\{BUILD_DIR\}/\.\./\.\./SourcePackages/checkouts/sdk-swift/Resources",\n\s*// path used in archive builds\n\s*"-L\$\{BUILD_DIR\}/\.\./\.\./\.\./\.\./\.\./SourcePackages/checkouts/sdk-swift/Resources",\n\s*\]\),~\n                .unsafeFlags([sdkResourceLibrarySearchPath]),~g' "$SDK_DIR/Package.swift"
perl -0pi -e 's~"-llibbootstrapperdll\.osx-arm64\.o",\n\s*"-llibbootstrapperdll\.osx-x64\.o"~"-llibbootstrapperdll.osx-universal.o"~' "$SDK_DIR/Package.swift"
lipo -create \
  "$SDK_DIR/Resources/libbootstrapperdll.osx-arm64.o" \
  "$SDK_DIR/Resources/libbootstrapperdll.osx-x64.o" \
  -output "$SDK_DIR/Resources/libbootstrapperdll.osx-universal.o"

echo "Clearing local Xcode module caches that may reference the previous SDK..."
BUILD_ROOT="${PROTONPHOTOS_BUILD_ROOT:-$HOME/Developer/xcode/ProtonPhotos}"
rm -rf "$BUILD_ROOT/DD.noindex" "$BUILD_ROOT/DD.ios.noindex" "$BUILD_ROOT/SPM.noindex" \
       "$BUILD_ROOT/core-gate-dd.noindex"
# Legacy in-repo build dirs (pre-NAS layout).
rm -rf "$ROOT/build" "$ROOT/Packages/ProtonPhotosKit/.build"

CORE=$(grep -o 'protoncore_ios.git", exact: "[^"]*"' "$SDK_DIR/Package.swift" | grep -o '[0-9][0-9.]*')
echo ""
echo "  sdk-swift now at: $TAG ($(git -C "$SDK_DIR" rev-parse --short HEAD))"
echo "  REQUIRED ProtonCore exactVersion: $CORE"
echo ""
echo "Next:"
echo "  1. Set project.yml -> packages.ProtonCore.exactVersion to $CORE (if different)."
echo "  2. Update the clone hint in .gitignore to $TAG."
echo "  3. xcodegen generate"
echo "  4. ./scripts/rebuild.sh"
