#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h:h}

function usage() {
  cat >&2 <<'EOF'
usage: build_embedded_wineserver.sh --build-root <configured Wine build> --output <archive>

Builds Wine's native server objects and archives them without program_main.o,
making the result safe to link into an iOS application executable.
EOF
}

typeset BUILD_ROOT=""
typeset OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-root) BUILD_ROOT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

if [[ -z "$BUILD_ROOT" || -z "$OUTPUT" ]]; then
  usage
  exit 64
fi

BUILD_ROOT=${BUILD_ROOT:a}
OUTPUT=${OUTPUT:a}

if [[ ! -f "$BUILD_ROOT/Makefile" ]]; then
  echo "configured Wine build is missing Makefile: $BUILD_ROOT" >&2
  exit 66
fi

make -C "$BUILD_ROOT" server/wineserver

typeset -a OBJECTS
OBJECTS=("$BUILD_ROOT"/server/*.o)
OBJECTS=("${(@)OBJECTS:#*/program_main.o}")
if (( ${#OBJECTS[@]} == 0 )); then
  echo "Wine server build did not produce object files" >&2
  exit 66
fi

mkdir -p "${OUTPUT:h}"
rm -f "$OUTPUT"
if [[ "$(uname -s)" == "Darwin" ]]; then
  xcrun libtool -static -o "$OUTPUT" "${OBJECTS[@]}"
else
  ar rcs "$OUTPUT" "${OBJECTS[@]}"
fi

echo "Built embedded Wine server archive at $OUTPUT"
