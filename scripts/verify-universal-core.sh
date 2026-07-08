#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/ProtonPhotosKit"
DERIVED_DATA_BASE="${DERIVED_DATA_BASE:-/tmp/protonphotos-package-core-gate}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
MODE="${CORE_GATE_MODE:-${1:-full}}"

case "$MODE" in
  fast|full) ;;
  *)
    echo "usage: $(basename "$0") [fast|full]" >&2
    echo "  fast: CoreArchitectureGateTests only" >&2
    echo "  full: architecture tests + iOS/macOS package build proof" >&2
    exit 64
    ;;
esac

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
  MLSearchCore
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
  PhotoLibraryBackupAdapter
  MLSearchAppleAdapter
)

MACOS_PLATFORM_ADAPTER_TARGETS=(
  MetalGridTextureAppKitAdapter
  PhotoLibraryBackupAdapter
  MLSearchAppleAdapter
)

PLATFORMS=(
  "iOS:generic/platform=iOS"
  "macOS:generic/platform=macOS"
)

echo "[core-gate] package: $PACKAGE"
echo "[core-gate] developer dir: $DEVELOPER_DIR"
echo "[core-gate] mode: $MODE"
echo "[core-gate] derived data base: $DERIVED_DATA_BASE"

echo "[core-gate] running CoreArchitectureGateTests"
xcrun swift test --package-path "$PACKAGE" --filter CoreArchitectureGateTests

if [[ "$MODE" == "fast" ]]; then
  echo "[core-gate] fast architecture gate passed"
  exit 0
fi

build_scheme() {
  local scheme="$1"
  local platform_name="$2"
  local destination="$3"
  local label="$4"
  local derived_data="$DERIVED_DATA_BASE/$platform_name"

  echo "[core-gate] building $label$scheme for $platform_name"
  xcrun xcodebuild \
    -scheme "$scheme" \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -skipPackagePluginValidation \
    -quiet \
    build
}

pushd "$PACKAGE" >/dev/null

for target in "${CORE_TARGETS[@]}"; do
  for platform in "${PLATFORMS[@]}"; do
    name="${platform%%:*}"
    destination="${platform#*:}"
    build_scheme "$target" "$name" "$destination" ""
  done
done

for target in "${SHARED_UI_TARGETS[@]}"; do
  for platform in "${PLATFORMS[@]}"; do
    name="${platform%%:*}"
    destination="${platform#*:}"
    build_scheme "$target" "$name" "$destination" "shared UI "
  done
done

for target in "${RENDERING_CORE_TARGETS[@]}"; do
  for platform in "${PLATFORMS[@]}"; do
    name="${platform%%:*}"
    destination="${platform#*:}"
    build_scheme "$target" "$name" "$destination" ""
  done
done

for target in "${MACOS_PLATFORM_ADAPTER_TARGETS[@]}"; do
  build_scheme "$target" "macOS" "generic/platform=macOS" ""
done

for target in "${IOS_PLATFORM_ADAPTER_TARGETS[@]}"; do
  build_scheme "$target" "iOS" "generic/platform=iOS" ""
done

popd >/dev/null

echo "[core-gate] universal Core + shared UI + Metal Core + platform texture adapter proof gate passed"
