#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h}
STAGE_MARKER=".iridium-userland-stage"
source "$ROOT/userland_validation.sh"

function usage() {
  cat >&2 <<'EOF'
usage:
  stage_userland.sh \
    --source-root <path> \
    --output-root <path> \
    [--seed-output <path>]
EOF
}

typeset SOURCE_ROOT=""
typeset OUTPUT_ROOT=""
typeset SEED_OUTPUT=""

function resolve_runtime_strip_tool() {
  local configured="${IRIDIUM_RUNTIME_STRIP:-auto}"
  if [[ "$configured" == "none" ]]; then
    return 1
  fi
  if [[ "$configured" != "auto" ]]; then
    [[ -x "$configured" ]] || {
      echo "configured IRIDIUM_RUNTIME_STRIP is not executable: $configured" >&2
      return 2
    }
    print -r -- "$configured"
    return 0
  fi

  local candidate
  for candidate in \
    "${commands[llvm-strip]:-}" \
    /opt/homebrew/opt/llvm/bin/llvm-strip \
    /usr/local/opt/llvm/bin/llvm-strip; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

function prune_and_strip_runtime_payload() {
  local root="$1"

  # Import/static libraries and pkg-config metadata are build products. Wine
  # never loads them at runtime, and retaining them wastes tens of megabytes.
  find "$root" -type f \( -name '*.a' -o -name '*.la' -o -name '*.pc' \) -delete

  local strip_tool=""
  if strip_tool=$(resolve_runtime_strip_tool); then
    :
  else
    local status=$?
    if [[ "$status" -eq 2 ]]; then
      return "$status"
    fi
    echo "warning: llvm-strip was not found; staged Wine binaries retain debug data" >&2
    return 0
  fi

  local candidate
  local stripped_count=0
  local skipped_count=0
  while IFS= read -r -d $'\0' candidate; do
    if "$strip_tool" --strip-debug "$candidate" >/dev/null 2>&1; then
      (( stripped_count += 1 ))
    else
      # Some Wine data files intentionally use executable-looking suffixes.
      # Keep them intact; validation below still checks required binaries.
      (( skipped_count += 1 ))
    fi
  done < <(
    find "$root" -type f -size +4k \( \
      -name 'wine' -o -name 'wine64' -o -name 'wine-preloader' -o \
      -name 'wine64-preloader' -o -name 'wineserver' -o \
      -name 'ld-linux*.so*' -o -name '*.so' -o -name '*.so.*' -o \
      -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o \
      -name '*.cpl' -o -name '*.ocx' -o -name '*.drv' -o \
      -name '*.acm' -o -name '*.ax' \) -print0
  )
  echo "Stripped debug data from $stripped_count staged runtime binaries ($skipped_count non-object payloads retained)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root) SOURCE_ROOT="$2"; shift 2 ;;
    --output-root) OUTPUT_ROOT="$2"; shift 2 ;;
    --seed-output) SEED_OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

if [[ -z "$SOURCE_ROOT" || -z "$OUTPUT_ROOT" ]]; then
  usage
  exit 64
fi

if [[ ! -d "$SOURCE_ROOT" ]]; then
  echo "source root does not exist: $SOURCE_ROOT" >&2
  exit 66
fi

SOURCE_ROOT="$(normalized_absolute_path "$SOURCE_ROOT")"
OUTPUT_ROOT="$(normalized_absolute_path "$OUTPUT_ROOT")"
require_disjoint_paths "$SOURCE_ROOT" "source root" "$OUTPUT_ROOT" "output root"

if [[ -z "$SEED_OUTPUT" ]]; then
  SEED_OUTPUT="$OUTPUT_ROOT/prefix-seed"
fi
SEED_OUTPUT="$(normalized_absolute_path "$SEED_OUTPUT")"
require_disjoint_paths "$SOURCE_ROOT" "source root" "$SEED_OUTPUT" "seed output"
if [[ "$SEED_OUTPUT" == "$OUTPUT_ROOT" || ("${OUTPUT_ROOT#$SEED_OUTPUT/}" != "$OUTPUT_ROOT" && "${SEED_OUTPUT#$OUTPUT_ROOT/}" == "$SEED_OUTPUT") ]]; then
  echo "seed output must not contain the staged output root: $SEED_OUTPUT" >&2
  exit 64
fi

reset_managed_output_directory "$OUTPUT_ROOT" "$STAGE_MARKER" "output root" "$ROOT" "$SOURCE_ROOT"
mkdir -p "$OUTPUT_ROOT/bin"

if [[ ! -f "$SOURCE_ROOT/bin/wineserver" ]]; then
  echo "source root must contain bin/wineserver" >&2
  exit 66
fi
cp "$SOURCE_ROOT/bin/wineserver" "$OUTPUT_ROOT/bin/wineserver"

if [[ -f "$SOURCE_ROOT/bin/wine64" ]]; then
  cp "$SOURCE_ROOT/bin/wine64" "$OUTPUT_ROOT/bin/wine64"
elif [[ -f "$SOURCE_ROOT/bin/wine" ]]; then
  cp "$SOURCE_ROOT/bin/wine" "$OUTPUT_ROOT/bin/wine"
else
  echo "source root must contain a launchable Wine binary" >&2
  exit 66
fi

typeset COPIED_LIBS=0
for relative in "lib/wine" "lib64/wine"; do
  if [[ -d "$SOURCE_ROOT/$relative" ]]; then
    mkdir -p "$OUTPUT_ROOT/${relative:h}"
    cp -R "$SOURCE_ROOT/$relative" "$OUTPUT_ROOT/$relative"
    COPIED_LIBS=1
  fi
done
for relative in "lib/x86_64-linux-gnu" "usr/lib/x86_64-linux-gnu" "usr/lib64"; do
  if [[ -d "$SOURCE_ROOT/$relative" ]]; then
    mkdir -p "$OUTPUT_ROOT/${relative:h}"
    cp -R "$SOURCE_ROOT/$relative" "$OUTPUT_ROOT/$relative"
  fi
done
copy_required_program_interpreters "$SOURCE_ROOT" "$OUTPUT_ROOT"

prune_and_strip_runtime_payload "$OUTPUT_ROOT"

if [[ "$COPIED_LIBS" -eq 0 ]]; then
  echo "source root must contain lib/wine or lib64/wine" >&2
  exit 66
fi

if [[ ! -d "$SOURCE_ROOT/share/wine" ]]; then
  echo "source root must contain share/wine" >&2
  exit 66
fi

if require_wineserver_nls "$SOURCE_ROOT" "source root" >/dev/null; then
  :
else
  exit $?
fi

typeset EMBEDDED_GUEST_LOADER=""
if EMBEDDED_GUEST_LOADER=$(require_embedded_guest_wine_loader "$SOURCE_ROOT" "source root"); then
  :
else
  exit $?
fi

typeset WINEIOS_DRIVER=""
if WINEIOS_DRIVER=$(require_wineios_driver "$OUTPUT_ROOT" "staged userland"); then
  :
else
  exit $?
fi

typeset OPENGL_BACKEND=""
if OPENGL_BACKEND=$(require_ios_opengl_backend "$OUTPUT_ROOT" "staged userland"); then
  :
else
  exit $?
fi

mkdir -p "$OUTPUT_ROOT/share"
cp -R "$SOURCE_ROOT/share/wine" "$OUTPUT_ROOT/share/wine"

if require_wineserver_nls "$OUTPUT_ROOT" "staged userland" >/dev/null; then
  :
else
  exit $?
fi

"$ROOT/generate_prefix_seed.sh" --output "$SEED_OUTPUT"

if [[ "$SEED_OUTPUT" != "$OUTPUT_ROOT/prefix-seed" ]]; then
  reset_managed_output_directory "$OUTPUT_ROOT/prefix-seed" ".iridium-prefix-seed" "staged prefix seed" "$ROOT" "$SOURCE_ROOT"
  cp -R "$SEED_OUTPUT"/. "$OUTPUT_ROOT/prefix-seed/"
fi

for seed_file in system.reg user.reg userdef.reg; do
  if [[ ! -f "$OUTPUT_ROOT/prefix-seed/$seed_file" ]]; then
    echo "staged userland is missing $seed_file" >&2
    exit 66
  fi
done

{
  print "source_root=$SOURCE_ROOT"
  print "launcher=$( [[ -f "$OUTPUT_ROOT/bin/wine64" ]] && print bin/wine64 || print bin/wine )"
  print "embedded_guest_loader=$EMBEDDED_GUEST_LOADER"
  print "wineios_driver=$WINEIOS_DRIVER"
  print "opengl_backend=$OPENGL_BACKEND"
  print "seed_root=$SEED_OUTPUT"
} > "$OUTPUT_ROOT/$STAGE_MARKER"

echo "Staged Wine userland at $OUTPUT_ROOT"
