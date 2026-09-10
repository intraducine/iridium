#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h}
STAGE_MARKER=".iridium-userland-stage"
source "$ROOT/userland_validation.sh"

function usage() {
  cat >&2 <<'EOF'
usage:
  package_userland.sh \
    --source-root <path> \
    --output <path/to/wine-userland.tar.zst> \
    --prefix-seed <path>
EOF
}

typeset SOURCE_ROOT=""
typeset OUTPUT_PATH=""
typeset PREFIX_SEED=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root) SOURCE_ROOT="$2"; shift 2 ;;
    --output) OUTPUT_PATH="$2"; shift 2 ;;
    --prefix-seed) PREFIX_SEED="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

if [[ -z "$SOURCE_ROOT" || -z "$OUTPUT_PATH" || -z "$PREFIX_SEED" ]]; then
  usage
  exit 64
fi

if [[ ! -f "$SOURCE_ROOT/$STAGE_MARKER" ]]; then
  echo "source root must be produced by iridium/ios/stage_userland.sh" >&2
  exit 66
fi

if [[ ! -d "$PREFIX_SEED" ]]; then
  echo "prefix seed directory is required" >&2
  exit 66
fi

for seed_file in system.reg user.reg userdef.reg; do
  if [[ ! -f "$PREFIX_SEED/$seed_file" ]]; then
    echo "prefix seed is missing $seed_file" >&2
    exit 66
  fi
done

if ! command -v zstd >/dev/null 2>&1; then
  echo "zstd is required to produce wine-userland.tar.zst" >&2
  exit 69
fi

typeset STAGING_ROOT
STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/iridium-wine-userland.XXXXXX")
trap 'rm -rf "$STAGING_ROOT"' EXIT

typeset -a COPY_PATHS
COPY_PATHS=(
  "bin/wine64"
  "bin/wine"
  "bin/wineserver"
  "lib/wine"
  "lib/x86_64-linux-gnu"
  "lib64/wine"
  "usr/lib/x86_64-linux-gnu"
  "usr/lib64"
  "share/wine"
)

for relative in "${COPY_PATHS[@]}"; do
  if [[ -e "$SOURCE_ROOT/$relative" ]]; then
    mkdir -p "$STAGING_ROOT/${relative:h}"
    cp -R "$SOURCE_ROOT/$relative" "$STAGING_ROOT/$relative"
  fi
done
copy_required_program_interpreters "$SOURCE_ROOT" "$STAGING_ROOT"

mkdir -p "$STAGING_ROOT/prefix-seed"
cp -R "$PREFIX_SEED"/. "$STAGING_ROOT/prefix-seed/"

if [[ ! -f "$STAGING_ROOT/bin/wineserver" ]]; then
  echo "source root must contain bin/wineserver" >&2
  exit 66
fi

if [[ ! -f "$STAGING_ROOT/bin/wine64" && ! -f "$STAGING_ROOT/bin/wine" ]]; then
  echo "staged userland must contain a Wine launcher" >&2
  exit 66
fi

if [[ ! -d "$STAGING_ROOT/share/wine" ]]; then
  echo "staged userland must contain share/wine" >&2
  exit 66
fi

if require_wineserver_nls "$STAGING_ROOT" "staged userland" >/dev/null; then
  :
else
  exit $?
fi

if [[ ! -d "$STAGING_ROOT/lib/wine" && ! -d "$STAGING_ROOT/lib64/wine" ]]; then
  echo "staged userland must contain lib/wine or lib64/wine" >&2
  exit 66
fi

typeset EMBEDDED_GUEST_LOADER=""
if EMBEDDED_GUEST_LOADER=$(require_embedded_guest_wine_loader "$STAGING_ROOT" "staged userland"); then
  :
else
  exit $?
fi

if require_wineios_driver "$STAGING_ROOT" "staged userland" >/dev/null; then
  :
else
  exit $?
fi

if require_ios_opengl_backend "$STAGING_ROOT" "staged userland" >/dev/null; then
  :
else
  exit $?
fi

typeset -a PRUNED_EXECUTABLES
PRUNED_EXECUTABLES=(
  "explorer.exe"
  "cmd.exe"
  "powershell.exe"
  "pwsh.exe"
  "steam.exe"
  "steamservice.exe"
  "control.exe"
  "start.exe"
  "winebrowser.exe"
  "winemenubuilder.exe"
  "regedit.exe"
  "wordpad.exe"
  "taskmgr.exe"
)

for executable in "${PRUNED_EXECUTABLES[@]}"; do
  find "$STAGING_ROOT/share/wine" -name "$executable" -delete 2>/dev/null || true
done

for seed_file in system.reg user.reg userdef.reg; do
  if [[ ! -f "$STAGING_ROOT/prefix-seed/$seed_file" ]]; then
    echo "staged userland is missing seeded registry file $seed_file" >&2
    exit 66
  fi
done

mkdir -p "${OUTPUT_PATH:h}"
typeset TAR_PATH="${OUTPUT_PATH%.zst}"
tar -C "$STAGING_ROOT" -cf "$TAR_PATH" .
zstd -f -q "$TAR_PATH" -o "$OUTPUT_PATH"
rm -f "$TAR_PATH"

echo "Packaged Wine userland at $OUTPUT_PATH"
