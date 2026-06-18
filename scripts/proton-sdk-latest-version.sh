#!/bin/bash
# Report the latest Proton Drive SDK tag available upstream (and the ProtonCore version it requires),
# without modifying the working tree. Read-only.
set -e
cd "$(dirname "$0")/.."
REPO="https://github.com/ProtonDriveApps/sdk-swift.git"

LATEST=$(git ls-remote --tags "$REPO" 2>/dev/null \
  | grep -o 'refs/tags/[0-9][0-9.]*$' | sed 's@refs/tags/@@' | sort -V | tail -1)
echo "latest upstream tag:  $LATEST"

# Peek at that tag's Package.swift to learn its ProtonCore pin (needs a local clone to read a blob).
if [ -d "Vendor/sdk-swift/.git" ]; then
  git -C Vendor/sdk-swift fetch --tags --quiet "$REPO" 2>/dev/null || true
  CORE=$(git -C Vendor/sdk-swift show "refs/tags/$LATEST:Package.swift" 2>/dev/null \
    | grep -o 'protoncore_ios.git", exact: "[^"]*"' | grep -o '[0-9][0-9.]*')
  [ -n "$CORE" ] && echo "it requires ProtonCore: $CORE"
fi
echo "(current: run scripts/proton-sdk-current-version.sh)"
