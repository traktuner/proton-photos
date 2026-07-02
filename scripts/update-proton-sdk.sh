#!/bin/bash
# Check out a Proton Drive SDK tag in Vendor/sdk-swift and report the ProtonCore version that
# project.yml must be set to. Does NOT edit project.yml or build - review the printed pin, update
# project.yml's ProtonCore exactVersion to match, then run scripts/rebuild.sh.
#
# Usage: scripts/update-proton-sdk.sh [<tag>]   (defaults to latest upstream tag)
set -e
cd "$(dirname "$0")/.."
SDK_DIR="Vendor/sdk-swift"
REPO="https://github.com/ProtonDriveApps/sdk-swift.git"

if [ ! -d "$SDK_DIR/.git" ]; then
  echo "Cloning sdk-swift…"
  git clone "$REPO" "$SDK_DIR"
fi

git -C "$SDK_DIR" fetch --tags --quiet "$REPO"
TAG="${1:-$(git -C "$SDK_DIR" tag -l | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)}"

echo "Checking out sdk-swift $TAG…"
git -C "$SDK_DIR" checkout --quiet "refs/tags/$TAG"

CORE=$(grep -o 'protoncore_ios.git", exact: "[^"]*"' "$SDK_DIR/Package.swift" | grep -o '[0-9][0-9.]*')
echo ""
echo "  sdk-swift now at: $TAG ($(git -C "$SDK_DIR" rev-parse --short HEAD))"
echo "  REQUIRED ProtonCore exactVersion: $CORE"
echo ""
echo "Next:"
echo "  1. Set project.yml -> packages.ProtonCore.exactVersion to $CORE (if different)."
echo "  2. Update the clone hint in .gitignore to $TAG."
echo "  3. xcodegen generate"
echo "  4. rm -rf build/DD.noindex/SourcePackages/artifacts build/DD.noindex/SourcePackages/workspace-state.json"
echo "  5. ./scripts/rebuild.sh"
