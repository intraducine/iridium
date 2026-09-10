#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

platform="device"
build_root=""
output=""
jobs=""
build_root_explicit=0

usage() {
    cat >&2 <<'EOF'
usage:
  build_embedded_translator.sh \
    [--platform device|simulator|host] \
    [--build-root <path>] \
    [--output <path>] \
    [--jobs <count>]

Builds the canonical Iridium embedded FEX archive and writes
iridium-ios-embedded-artifact.txt into the build root.
EOF
}

absolute_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s\n' "$PWD/${path#./}"
    fi
}

replace_build_alias() {
    local alias_path="$1"
    local target_name="$2"

    if [[ -L "$alias_path" ]]; then
        rm "$alias_path"
    elif [[ -e "$alias_path" ]]; then
        echo "refusing to replace non-symlink build alias: $alias_path" >&2
        exit 73
    fi
    ln -s "$target_name" "$alias_path"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) platform="$2"; shift 2 ;;
        --build-root) build_root="$(absolute_path "$2")"; build_root_explicit=1; shift 2 ;;
        --output) output="$(absolute_path "$2")"; shift 2 ;;
        --jobs) jobs="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 64 ;;
    esac
done

case "$platform" in
    device|simulator|host) ;;
    *)
        echo "unsupported --platform: $platform" >&2
        usage
        exit 64
        ;;
esac

if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake is required to build the embedded FEX translator." >&2
    exit 69
fi

required_submodule_files=(
    "External/vixl/CMakeLists.txt"
    "Source/Common/cpp-optparse/CMakeLists.txt"
    "External/fmt/CMakeLists.txt"
    "External/xxhash/cmake_unofficial/CMakeLists.txt"
    "External/range-v3/CMakeLists.txt"
    "External/unordered_dense/CMakeLists.txt"
    "External/rpmalloc/CMakeLists.txt"
)
missing_submodules=()
for required_file in "${required_submodule_files[@]}"; do
    if [[ ! -f "$REPO_ROOT/$required_file" ]]; then
        missing_submodules+=("$required_file")
    fi
done
if (( ${#missing_submodules[@]} > 0 )); then
    echo "embedded FEX dependencies are not initialized:" >&2
    printf '  - %s\n' "${missing_submodules[@]}" >&2
    echo "run: git submodule update --init External/vixl Source/Common/cpp-optparse External/fmt External/xxhash External/range-v3 External/unordered_dense External/rpmalloc" >&2
    exit 66
fi

if [[ -z "$build_root" ]]; then
    case "$platform" in
        device) build_root="$REPO_ROOT/build-iridium-ios-device" ;;
        simulator) build_root="$REPO_ROOT/build-iridium-ios-simulator" ;;
        host) build_root="$REPO_ROOT/build-iridium-ios-host" ;;
    esac
fi

archive_path="$build_root/artifacts/libiridium-fex-ios-embedded.a"
manifest_path="$build_root/iridium-ios-embedded-artifact.txt"

cmake_configure_args=(
    -S "$REPO_ROOT"
    -B "$build_root"
    -DIRIDIUM_IOS_EMBEDDED=ON
    -DIRIDIUM_IOS_EMBEDDED_PLATFORM="$platform"
    -DIRIDIUM_IOS_EMBEDDED_TESTING=ON
)

cmake_build_args=(--build "$build_root" --target iridium-fex-ios-embedded)
if [[ -n "$jobs" ]]; then
    cmake_build_args+=(--parallel "$jobs")
fi

cmake "${cmake_configure_args[@]}"
cmake "${cmake_build_args[@]}"

if [[ ! -f "$archive_path" ]]; then
    echo "embedded translator build did not produce $archive_path" >&2
    exit 66
fi

if [[ ! -f "$manifest_path" ]]; then
    echo "embedded translator build did not produce $manifest_path" >&2
    exit 66
fi

if ! grep -qx "PLATFORM=$platform" "$manifest_path"; then
    echo "embedded translator manifest has the wrong platform; expected PLATFORM=$platform in $manifest_path" >&2
    exit 66
fi

if [[ -n "$output" && "$output" != "$archive_path" ]]; then
    mkdir -p "$(dirname "$output")"
    cp -f "$archive_path" "$output"
fi

if [[ "$build_root_explicit" -eq 0 ]]; then
    case "$platform" in
        device)
            replace_build_alias "$REPO_ROOT/build-iridium-ios-iphoneos" "$(basename "$build_root")"
            replace_build_alias "$REPO_ROOT/build-iridium-ios-current" "$(basename "$build_root")"
            ;;
        simulator)
            replace_build_alias "$REPO_ROOT/build-iridium-ios-iphonesimulator" "$(basename "$build_root")"
            replace_build_alias "$REPO_ROOT/build-iridium-ios-current" "$(basename "$build_root")"
            ;;
    esac
fi

echo "Built embedded FEX translator for $platform at $archive_path"
