#!/usr/bin/env bash
# Build release binaries and packages for mmx (CLI and Studio).
# Usage:
#   ./tool/build_release.sh [options]
#
# Options:
#   --platform=<linux|macos|windows|auto>  Target OS platform (default: auto)
#   --arch=<x64|arm64|auto>                Target CPU architecture (default: auto)
#   --target=<all|cli|studio>              What to build (default: all)
#   --version=<version>                    Release version string (default: from pubspec.yaml)
#   --out-dir=<path>                       Directory to store artifacts (default: dist)
#   --no-archive                           Skip packaging into archives (.tar.gz / .zip)
#   --no-checksums                         Skip writing SHA256SUMS.txt
#   -h, --help                             Show this help message

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Normalize Windows paths if in MSYS/Cygwin/Git Bash
if command -v cygpath >/dev/null 2>&1; then
  ROOT_DIR="$(cygpath -m "$ROOT_DIR")"
fi

# Detect platform
detect_platform() {
  case "$(uname -s)" in
    Linux*)               echo "linux" ;;
    Darwin*)              echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    Windows_NT)           echo "windows" ;;
    *)                    echo "linux" ;;
  esac
}

# Detect architecture
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)         echo "x64" ;;
    arm64|aarch64)        echo "arm64" ;;
    *)                    uname -m ;;
  esac
}

# Detect default version
detect_version() {
  if [[ -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    echo "${GITHUB_REF_NAME#v}"
    return
  fi
  if [[ -f "$ROOT_DIR/packages/mmx_core/pubspec.yaml" ]]; then
    local v
    v="$(grep -m1 '^version:' "$ROOT_DIR/packages/mmx_core/pubspec.yaml" | awk '{print $2}' | tr -d '\r')"
    if [[ -n "$v" ]]; then
      echo "$v"
      return
    fi
  fi
  echo "0.1.0"
}

PLATFORM=""
ARCH=""
TARGET="all"
VERSION=""
OUT_DIR="$ROOT_DIR/dist"
ARCHIVE="true"
CHECKSUMS="true"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform=*)
      PLATFORM="${1#*=}"
      shift
      ;;
    --arch=*)
      ARCH="${1#*=}"
      shift
      ;;
    --target=*)
      TARGET="${1#*=}"
      shift
      ;;
    --version=*)
      VERSION="${1#*=}"
      shift
      ;;
    --out-dir=*)
      OUT_DIR="${1#*=}"
      shift
      ;;
    --no-archive)
      ARCHIVE="false"
      shift
      ;;
    --no-checksums)
      CHECKSUMS="false"
      shift
      ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information." >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PLATFORM" || "$PLATFORM" == "auto" ]]; then
  PLATFORM="$(detect_platform)"
fi

if [[ -z "$ARCH" || "$ARCH" == "auto" ]]; then
  ARCH="$(detect_arch)"
fi

# The script builds natively and does not cross-compile, so a mismatched
# platform or arch would only mislabel the archives.
if [[ "$PLATFORM" != "$(detect_platform)" ]]; then
  echo "Error: --platform=$PLATFORM does not match this host ($(detect_platform)); cross-compiling is not supported." >&2
  exit 1
fi
if [[ "$ARCH" != "$(detect_arch)" ]]; then
  echo "Error: --arch=$ARCH does not match this host ($(detect_arch)); cross-compiling is not supported." >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(detect_version)"
fi

mkdir -p "$OUT_DIR"
if command -v cygpath >/dev/null 2>&1; then
  OUT_DIR="$(cygpath -m "$(cd "$OUT_DIR" && pwd)")"
else
  OUT_DIR="$(cd "$OUT_DIR" && pwd)"
fi

TEMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'mmx-build')"
if command -v cygpath >/dev/null 2>&1; then
  TEMP_DIR="$(cygpath -m "$TEMP_DIR")"
fi
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "=================================================="
echo " mmx Release Build"
echo " Platform : $PLATFORM"
echo " Arch     : $ARCH"
echo " Target   : $TARGET"
echo " Version  : $VERSION"
echo " Output   : $OUT_DIR"
echo " Archive  : $ARCHIVE"
echo "=================================================="

create_tar_gz() {
  local src_dir="$1"
  local dest_archive="$2"
  local parent_dir
  parent_dir="$(dirname "$src_dir")"
  local base_name
  base_name="$(basename "$src_dir")"

  tar -czf "$dest_archive" -C "$parent_dir" "$base_name"
  echo "  Created archive: $dest_archive"
}

create_zip() {
  local src_dir="$1"
  local dest_archive="$2"
  local parent_dir
  parent_dir="$(dirname "$src_dir")"
  local base_name
  base_name="$(basename "$src_dir")"

  if command -v zip >/dev/null 2>&1; then
    (cd "$parent_dir" && zip -r -q -y "$dest_archive" "$base_name")
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import shutil, sys; shutil.make_archive(sys.argv[1][:-4] if sys.argv[1].endswith('.zip') else sys.argv[1], 'zip', sys.argv[2], sys.argv[3])" "$dest_archive" "$parent_dir" "$base_name"
  elif command -v powershell >/dev/null 2>&1; then
    powershell -NoProfile -Command "Compress-Archive -Path '$src_dir\*' -DestinationPath '$dest_archive' -Force"
  else
    echo "Error: Neither zip, python3, nor powershell available to create zip archive." >&2
    exit 1
  fi
  echo "  Created archive: $dest_archive"
}

build_cli() {
  echo ""
  echo "==> Building mmx CLI ($PLATFORM-$ARCH)..."

  if ! command -v dart >/dev/null 2>&1; then
    echo "Error: 'dart' executable not found in PATH." >&2
    exit 1
  fi

  local stage_dir="$TEMP_DIR/mmx-cli-${VERSION}-${PLATFORM}-${ARCH}"
  mkdir -p "$stage_dir"

  cd "$ROOT_DIR/packages/mmx_core"
  echo "Fetching packages/mmx_core dependencies..."
  dart pub get

  local bin_name="mmx"
  if [[ "$PLATFORM" == "windows" ]]; then
    bin_name="mmx.exe"
  fi

  echo "Compiling $bin_name with dart compile exe..."
  dart compile exe bin/mmx.dart -o "$stage_dir/$bin_name"
  chmod +x "$stage_dir/$bin_name" 2>/dev/null || true

  # Include licenses and documentation
  [[ -f "$ROOT_DIR/LICENSE" ]] && cp "$ROOT_DIR/LICENSE" "$stage_dir/"
  [[ -f "$ROOT_DIR/NOTICE" ]] && cp "$ROOT_DIR/NOTICE" "$stage_dir/"
  [[ -f "$ROOT_DIR/packages/mmx_core/README.md" ]] && cp "$ROOT_DIR/packages/mmx_core/README.md" "$stage_dir/"

  if [[ "$ARCHIVE" == "true" ]]; then
    if [[ "$PLATFORM" == "windows" ]]; then
      create_zip "$stage_dir" "$OUT_DIR/mmx-cli-${VERSION}-${PLATFORM}-${ARCH}.zip"
    else
      create_tar_gz "$stage_dir" "$OUT_DIR/mmx-cli-${VERSION}-${PLATFORM}-${ARCH}.tar.gz"
    fi
  else
    mkdir -p "$OUT_DIR/mmx-cli-${VERSION}-${PLATFORM}-${ARCH}"
    cp -R "$stage_dir"/* "$OUT_DIR/mmx-cli-${VERSION}-${PLATFORM}-${ARCH}/"
    echo "  Copied unarchived build to $OUT_DIR/mmx-cli-${VERSION}-${PLATFORM}-${ARCH}/"
  fi
}

build_studio() {
  echo ""
  echo "==> Building mmx_studio ($PLATFORM-$ARCH)..."

  if ! command -v flutter >/dev/null 2>&1; then
    echo "Error: 'flutter' executable not found in PATH." >&2
    exit 1
  fi

  # Flutter builds a universal (x86_64 + arm64) app on macOS, so name it that way.
  local studio_arch="$ARCH"
  if [[ "$PLATFORM" == "macos" ]]; then
    studio_arch="universal"
  fi

  local stage_dir="$TEMP_DIR/mmx-studio-${VERSION}-${PLATFORM}-${studio_arch}"
  mkdir -p "$stage_dir"

  cd "$ROOT_DIR/apps/mmx_studio"
  echo "Fetching apps/mmx_studio dependencies..."
  flutter pub get

  case "$PLATFORM" in
    linux)
      flutter build linux --release
      local bundle_dir="$ROOT_DIR/apps/mmx_studio/build/linux/x64/release/bundle"
      if [[ ! -d "$bundle_dir" ]]; then
        bundle_dir="$(find "$ROOT_DIR/apps/mmx_studio/build/linux" -type d -name "bundle" 2>/dev/null | head -n 1)"
      fi
      if [[ -z "$bundle_dir" || ! -d "$bundle_dir" ]]; then
        echo "Error: Linux release bundle directory not found." >&2
        exit 1
      fi
      cp -R "$bundle_dir"/* "$stage_dir/"
      ;;
    macos)
      flutter build macos --release
      local app_dir="$ROOT_DIR/apps/mmx_studio/build/macos/Build/Products/Release/mmx_studio.app"
      if [[ ! -d "$app_dir" ]]; then
        echo "Error: macOS release app bundle not found at $app_dir" >&2
        exit 1
      fi
      cp -R "$app_dir" "$stage_dir/"
      ;;
    windows)
      flutter build windows --release
      local runner_dir="$ROOT_DIR/apps/mmx_studio/build/windows/x64/runner/Release"
      if [[ ! -d "$runner_dir" ]]; then
        runner_dir="$(find "$ROOT_DIR/apps/mmx_studio/build/windows" -type d -name "Release" 2>/dev/null | head -n 1)"
      fi
      if [[ -z "$runner_dir" || ! -d "$runner_dir" ]]; then
        echo "Error: Windows release runner directory not found." >&2
        exit 1
      fi
      cp -R "$runner_dir"/* "$stage_dir/"
      ;;
    *)
      echo "Error: Unsupported platform '$PLATFORM' for Studio build." >&2
      exit 1
      ;;
  esac

  # Include licenses and documentation
  [[ -f "$ROOT_DIR/LICENSE" ]] && cp "$ROOT_DIR/LICENSE" "$stage_dir/"
  [[ -f "$ROOT_DIR/NOTICE" ]] && cp "$ROOT_DIR/NOTICE" "$stage_dir/"
  [[ -f "$ROOT_DIR/apps/mmx_studio/README.md" ]] && cp "$ROOT_DIR/apps/mmx_studio/README.md" "$stage_dir/"

  if [[ "$ARCHIVE" == "true" ]]; then
    if [[ "$PLATFORM" == "linux" ]]; then
      create_tar_gz "$stage_dir" "$OUT_DIR/mmx-studio-${VERSION}-${PLATFORM}-${studio_arch}.tar.gz"
    else
      create_zip "$stage_dir" "$OUT_DIR/mmx-studio-${VERSION}-${PLATFORM}-${studio_arch}.zip"
    fi
  else
    mkdir -p "$OUT_DIR/mmx-studio-${VERSION}-${PLATFORM}-${studio_arch}"
    cp -R "$stage_dir"/* "$OUT_DIR/mmx-studio-${VERSION}-${PLATFORM}-${studio_arch}/"
    echo "  Copied unarchived build to $OUT_DIR/mmx-studio-${VERSION}-${PLATFORM}-${studio_arch}/"
  fi
}

generate_checksums() {
  if [[ "$ARCHIVE" != "true" || "$CHECKSUMS" != "true" ]]; then
    return
  fi

  echo ""
  echo "==> Generating SHA-256 checksums..."
  cd "$OUT_DIR"
  local checksum_file="SHA256SUMS.txt"
  local matched=0

  for file in *.tar.gz *.zip; do
    if [[ -f "$file" ]]; then
      matched=1
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" >> "$checksum_file.tmp"
      elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" >> "$checksum_file.tmp"
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import hashlib, sys; print(f'{hashlib.sha256(open(sys.argv[1], \"rb\").read()).hexdigest()}  {sys.argv[1]}')" "$file" >> "$checksum_file.tmp"
      fi
    fi
  done

  if [[ $matched -eq 1 && -f "$checksum_file.tmp" ]]; then
    sort -k2 -u "$checksum_file.tmp" > "$checksum_file"
    rm -f "$checksum_file.tmp"
    echo "Checksums written to $OUT_DIR/$checksum_file:"
    cat "$checksum_file"
  fi
}

if [[ "$TARGET" == "all" || "$TARGET" == "cli" ]]; then
  build_cli
fi

if [[ "$TARGET" == "all" || "$TARGET" == "studio" ]]; then
  build_studio
fi

generate_checksums

echo ""
echo "Release build completed successfully. Output files in $OUT_DIR"
