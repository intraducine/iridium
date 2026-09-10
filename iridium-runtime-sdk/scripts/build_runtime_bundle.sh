#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$0"
if [[ -n "${BASH_VERSION:-}" ]]; then
  SCRIPT_PATH="${BASH_SOURCE[0]}"
fi
ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

function build_runtime_host() {
  if command -v cmake >/dev/null 2>&1; then
    if cmake -S "$ROOT" -B "$ROOT/build" >&2 && cmake --build "$ROOT/build" >&2; then
      echo "$ROOT/build/runtime-host.bin"
      return
    fi

    echo "cmake runtime-host build failed; falling back to swift build" >&2
  fi

  if ! command -v swift >/dev/null 2>&1; then
    echo "swift is required to build runtime-host.bin when cmake is unavailable or fails" >&2
    exit 69
  fi

  swift build --package-path "$ROOT" >&2
  echo "$ROOT/.build/debug/runtime-host.bin"
}

function build_fex_embedded_library() {
  local fex_root="$1"
  local fex_platform="${2:-device}"
  local helper_script="$fex_root/iridium/ios/build_embedded_translator.sh"
  local build_root="$ROOT/build/fex-ios-embedded-$fex_platform"
  local output_root="$build_root/artifacts"
  local library_path="$output_root/libiridium-fex-ios-embedded.a"

  if [[ ! -x "$helper_script" ]]; then
    echo "fex fork is missing canonical embedded build entrypoint: $helper_script" >&2
    exit 66
  fi

  mkdir -p "$output_root"
  "$helper_script" \
    --platform "$fex_platform" \
    --build-root "$build_root" \
    --output "$library_path" >&2

  if [[ ! -f "$library_path" ]]; then
    echo "canonical embedded translator build did not produce $library_path" >&2
    exit 66
  fi

  echo "$library_path"
}

function build_wine_userland_archive() {
  local wine_root="$1"
  local prefix_seed_root="${2:-}"
  local wine_platform="${3:-linux-x86_64}"
  local script_root="$wine_root/iridium/ios"
  local build_script="$script_root/build_install_root.sh"
  local stage_script="$script_root/stage_userland.sh"
  local seed_script="$script_root/generate_prefix_seed.sh"
  local package_script="$script_root/package_userland.sh"
  local build_root="$ROOT/build/wine-userland-$wine_platform"
  local install_root="$build_root/install-root"
  local staged_root="$build_root/staged-root"
  local userland_archive="$build_root/wine-userland.tar.zst"

  if [[ ! -x "$build_script" ]]; then
    echo "wine fork is missing canonical build entrypoint: $build_script" >&2
    exit 66
  fi
  if [[ ! -x "$stage_script" ]]; then
    echo "wine fork is missing canonical staging entrypoint: $stage_script" >&2
    exit 66
  fi
  if [[ ! -x "$seed_script" ]]; then
    echo "wine fork is missing canonical prefix-seed entrypoint: $seed_script" >&2
    exit 66
  fi
  if [[ ! -x "$package_script" ]]; then
    echo "wine fork is missing canonical packaging entrypoint: $package_script" >&2
    exit 66
  fi

  mkdir -p "$build_root"
  if [[ -z "$prefix_seed_root" ]]; then
    prefix_seed_root="$build_root/prefix-seed"
  fi

  "$build_script" \
    --platform "$wine_platform" \
    --build-root "$build_root/wine-build" \
    --install-root "$install_root" >&2

  "$seed_script" --output "$prefix_seed_root" >&2
  "$stage_script" \
    --source-root "$install_root" \
    --output-root "$staged_root" \
    --seed-output "$prefix_seed_root" >&2
  "$package_script" \
    --source-root "$staged_root" \
    --output "$userland_archive" \
    --prefix-seed "$prefix_seed_root" >&2

  echo "$userland_archive"
}

function usage() {
  cat >&2 <<'EOF'
usage:
  build_runtime_bundle.sh \
    --bundle-version <version> \
    --output-root <path> \
    [--smoke-check] \
    [--translator <path>] \
    [--userland <path>] \
    [--build-from-forks] \
    [--fex-platform <device|simulator|host>] \
    [--wine-platform <linux-x86_64|device|simulator|host>] \
    [--wine-fork-root <path>] \
    [--fex-fork-root <path>] \
    [--wine-prefix-seed <path>] \
    [--bundle-id <id>] \
    [--bundle-name <name>] \
    [--graphics-config <path>] \
    [--direct-launch-profile <path>]
EOF
}

typeset BUNDLE_ID="iridium-runtime-base"
typeset BUNDLE_NAME="Iridium Runtime Base"
typeset BUNDLE_VERSION=""
typeset TRANSLATOR=""
typeset USERLAND=""
typeset OUTPUT_ROOT=""
typeset WINE_FORK_ROOT=""
typeset FEX_FORK_ROOT=""
typeset FEX_PLATFORM="host"
typeset WINE_PLATFORM="linux-x86_64"
typeset WINE_PREFIX_SEED=""
typeset BUILD_FROM_FORKS=0
typeset SMOKE_CHECK=0
typeset GRAPHICS_CONFIG="$ROOT/samples/runtime-bundle-template/Graphics/vkd3d-stack.json"
typeset DIRECT_LAUNCH_PROFILE="$ROOT/samples/runtime-bundle-template/Metadata/direct-launch.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --bundle-name) BUNDLE_NAME="$2"; shift 2 ;;
    --bundle-version) BUNDLE_VERSION="$2"; shift 2 ;;
    --translator) TRANSLATOR="$2"; shift 2 ;;
    --userland) USERLAND="$2"; shift 2 ;;
    --build-from-forks) BUILD_FROM_FORKS=1; shift 1 ;;
    --fex-platform) FEX_PLATFORM="$2"; shift 2 ;;
    --wine-platform) WINE_PLATFORM="$2"; shift 2 ;;
    --smoke-check) SMOKE_CHECK=1; shift 1 ;;
    --wine-fork-root) WINE_FORK_ROOT="$2"; shift 2 ;;
    --fex-fork-root) FEX_FORK_ROOT="$2"; shift 2 ;;
    --wine-userland-source-root) shift 2 ;;
    --wine-prefix-seed) WINE_PREFIX_SEED="$2"; shift 2 ;;
    --graphics-config) GRAPHICS_CONFIG="$2"; shift 2 ;;
    --direct-launch-profile) DIRECT_LAUNCH_PROFILE="$2"; shift 2 ;;
    --output-root) OUTPUT_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

if [[ -z "$BUNDLE_VERSION" || -z "$OUTPUT_ROOT" ]]; then
  usage
  exit 64
fi

if [[ "$BUILD_FROM_FORKS" -eq 1 ]]; then
  if [[ -z "$FEX_FORK_ROOT" || -z "$WINE_FORK_ROOT" ]]; then
    echo "--build-from-forks requires --fex-fork-root and --wine-fork-root" >&2
    exit 64
  fi

  if [[ ! -d "$FEX_FORK_ROOT" ]]; then
    echo "fex fork root does not exist: $FEX_FORK_ROOT" >&2
    exit 66
  fi

  if [[ ! -d "$WINE_FORK_ROOT" ]]; then
    echo "wine fork root does not exist: $WINE_FORK_ROOT" >&2
    exit 66
  fi

  if ! command -v zsh >/dev/null 2>&1; then
    echo "zsh is required because the Wine fork build/stage/package helpers are zsh scripts" >&2
    exit 69
  fi

  if [[ "$WINE_PLATFORM" == "linux-x86_64" ]] && ! command -v docker >/dev/null 2>&1; then
    echo "docker is required to build the linux-x86_64 Wine userland from forks" >&2
    exit 69
  fi
fi

case "$FEX_PLATFORM" in
  device|simulator|host) ;;
  *)
    echo "unsupported --fex-platform: $FEX_PLATFORM" >&2
    exit 64
    ;;
esac

case "$WINE_PLATFORM" in
  linux-x86_64|device|simulator|host) ;;
  *)
    echo "unsupported --wine-platform: $WINE_PLATFORM" >&2
    exit 64
    ;;
esac

typeset RUNTIME_HOST
RUNTIME_HOST=$(build_runtime_host)

if [[ "$BUILD_FROM_FORKS" -eq 1 ]]; then
  TRANSLATOR=$(build_fex_embedded_library "$FEX_FORK_ROOT" "$FEX_PLATFORM")

  USERLAND=$(build_wine_userland_archive "$WINE_FORK_ROOT" "$WINE_PREFIX_SEED" "$WINE_PLATFORM")
fi

if [[ -z "$TRANSLATOR" || -z "$USERLAND" ]]; then
  echo "translator and userland artifacts are required; provide them directly or use --build-from-forks" >&2
  exit 64
fi

typeset -a PACKAGER_ARGS
PACKAGER_ARGS=(
  --bundle-id "$BUNDLE_ID"
  --bundle-name "$BUNDLE_NAME"
  --bundle-version "$BUNDLE_VERSION"
  --runtime-host "$RUNTIME_HOST"
  --translator "$TRANSLATOR"
  --userland "$USERLAND"
  --graphics-config "$GRAPHICS_CONFIG"
  --direct-launch-profile "$DIRECT_LAUNCH_PROFILE"
  --output-root "$OUTPUT_ROOT"
)

if [[ -n "$WINE_FORK_ROOT" ]]; then
  PACKAGER_ARGS+=(--wine-fork-root "$WINE_FORK_ROOT")
fi

if [[ -n "$FEX_FORK_ROOT" ]]; then
  PACKAGER_ARGS+=(--fex-fork-root "$FEX_FORK_ROOT")
fi

if [[ "$SMOKE_CHECK" -eq 1 ]]; then
  PACKAGER_ARGS+=(--smoke-check)
fi

python3 "$ROOT/scripts/package_runtime_bundle.py" "${PACKAGER_ARGS[@]}"
