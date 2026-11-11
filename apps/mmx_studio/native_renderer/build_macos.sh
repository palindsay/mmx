#!/bin/bash
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
MMX_RENDER_ROOT="$(cd "$(dirname "$0")" && pwd)"
MMX_BUILD_ROOT="${DERIVED_FILE_DIR:?Xcode DERIVED_FILE_DIR is required}/mmx-rust"
MMX_FRAMEWORK_DIR="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
MMX_NOTICE_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/native-licenses"
mkdir -p "$MMX_FRAMEWORK_DIR" "$MMX_NOTICE_DIR"
cd "$MMX_RENDER_ROOT"
MMX_LIBRARIES=()
for MMX_ARCH in ${ARCHS:?Xcode ARCHS is required}; do
  case "$MMX_ARCH" in
    arm64) MMX_TRIPLE=aarch64-apple-darwin ;;
    x86_64) MMX_TRIPLE=x86_64-apple-darwin ;;
    *) echo "Unsupported renderer architecture: $MMX_ARCH" >&2; exit 1 ;;
  esac
  cargo build --release --locked --target "$MMX_TRIPLE" --target-dir "$MMX_BUILD_ROOT"
  MMX_LIBRARIES+=("$MMX_BUILD_ROOT/$MMX_TRIPLE/release/libmmx_gpu.dylib")
  python3 "$MMX_RENDER_ROOT/collect_licenses.py" --target "$MMX_TRIPLE" --output "$MMX_NOTICE_DIR/$MMX_ARCH"
done
lipo -create "${MMX_LIBRARIES[@]}" -output "$MMX_FRAMEWORK_DIR/libmmx_gpu.dylib"
# Embedding a dylib must follow the app's existing Xcode signing identity. A
# local unsigned build uses ad-hoc signing; no distribution credentials are used.
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$MMX_FRAMEWORK_DIR/libmmx_gpu.dylib"
