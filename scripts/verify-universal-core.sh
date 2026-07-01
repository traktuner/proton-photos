#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/ProtonPhotosKit"
DERIVED_DATA_BASE="${DERIVED_DATA_BASE:-/tmp/protonphotos-universal-core-gate}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

CORE_TARGETS=(
  PhotosCore
  MediaByteCache
  MediaDecodingCore
  MediaFeedCore
  MediaLocationCore
  GridCore
)

RENDERING_CORE_TARGETS=(
  MetalRenderingCore
)

PLATFORMS=(
  "iOS:generic/platform=iOS"
  "macOS:generic/platform=macOS"
)

echo "[core-gate] package: $PACKAGE"
echo "[core-gate] developer dir: $DEVELOPER_DIR"

echo "[core-gate] running CoreArchitectureGateTests"
xcrun swift test --package-path "$PACKAGE" --filter CoreArchitectureGateTests

for target in "${CORE_TARGETS[@]}"; do
  for platform in "${PLATFORMS[@]}"; do
    name="${platform%%:*}"
    destination="${platform#*:}"
    derived_data="$DERIVED_DATA_BASE/$target-$name"

    echo "[core-gate] building $target for $name"
    xcrun xcodebuild \
      -scheme "$target" \
      -destination "$destination" \
      -derivedDataPath "$derived_data" \
      -skipPackagePluginValidation \
      -quiet \
      build
  done
done

for target in "${RENDERING_CORE_TARGETS[@]}"; do
  for platform in "${PLATFORMS[@]}"; do
    name="${platform%%:*}"
    destination="${platform#*:}"
    derived_data="$DERIVED_DATA_BASE/$target-$name"

    echo "[core-gate] building $target for $name"
    xcrun xcodebuild \
      -scheme "$target" \
      -destination "$destination" \
      -derivedDataPath "$derived_data" \
      -skipPackagePluginValidation \
      -quiet \
      build
  done
done

echo "[core-gate] universal Core + rendering Core gate passed"
