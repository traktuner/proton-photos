#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/ProtonPhotosKit"
DERIVED_DATA_BASE="${DERIVED_DATA_BASE:-/tmp/protonphotos-package-core-gate}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

CORE_TARGETS=(
  PhotosCore
  MediaByteCache
  MediaDecodingCore
  MediaFeedCore
  MediaLocationCore
  MediaCacheCore
  GridCore
  UploadCore
  TimelineCore
  PhotoViewerCore
)

SHARED_UI_TARGETS=(
  DesignSystemCore
)

RENDERING_CORE_TARGETS=(
  MetalRenderingCore
  MetalGridTextureCore
  MetalGridComposeCore
)

IOS_PLATFORM_ADAPTER_TARGETS=(
  MetalGridTextureUIKitAdapter
  TimelineUIKitAdapter
  TimelineUIKitFeature
)

MACOS_PLATFORM_ADAPTER_TARGETS=(
  MetalGridTextureAppKitAdapter
)

PLATFORMS=(
  "iOS:generic/platform=iOS"
  "macOS:generic/platform=macOS"
)

echo "[core-gate] package: $PACKAGE"
echo "[core-gate] developer dir: $DEVELOPER_DIR"

echo "[core-gate] running CoreArchitectureGateTests"
xcrun swift test --package-path "$PACKAGE" --filter CoreArchitectureGateTests

pushd "$PACKAGE" >/dev/null

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

for target in "${SHARED_UI_TARGETS[@]}"; do
  for platform in "${PLATFORMS[@]}"; do
    name="${platform%%:*}"
    destination="${platform#*:}"
    derived_data="$DERIVED_DATA_BASE/$target-$name"

    echo "[core-gate] building shared UI $target for $name"
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

for target in "${MACOS_PLATFORM_ADAPTER_TARGETS[@]}"; do
  derived_data="$DERIVED_DATA_BASE/$target-macOS"

  echo "[core-gate] building $target for macOS"
  xcrun xcodebuild \
    -scheme "$target" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$derived_data" \
    -skipPackagePluginValidation \
    -quiet \
    build
done

for target in "${IOS_PLATFORM_ADAPTER_TARGETS[@]}"; do
  derived_data="$DERIVED_DATA_BASE/$target-iOS"

  echo "[core-gate] building $target for iOS"
  xcrun xcodebuild \
    -scheme "$target" \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$derived_data" \
    -skipPackagePluginValidation \
    -quiet \
    build
done

popd >/dev/null

echo "[core-gate] universal Core + shared UI + Metal Core + platform texture adapter proof gate passed"
