#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h}
TEMPLATE_ROOT="$ROOT/prefix-seed-template"
source "$ROOT/userland_validation.sh"
SEED_MARKER=".iridium-prefix-seed"

function usage() {
  cat >&2 <<'EOF'
usage:
  generate_prefix_seed.sh \
    --output <path/to/prefix-seed> \
    [--template-root <path>]
EOF
}

typeset OUTPUT_PATH=""
typeset TEMPLATE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_PATH="$2"; shift 2 ;;
    --template-root) TEMPLATE_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

if [[ -z "$OUTPUT_PATH" ]]; then
  usage
  exit 64
fi

if [[ -n "$TEMPLATE_OVERRIDE" ]]; then
  TEMPLATE_ROOT="$TEMPLATE_OVERRIDE"
fi

if [[ ! -d "$TEMPLATE_ROOT" ]]; then
  echo "prefix-seed template root does not exist: $TEMPLATE_ROOT" >&2
  exit 66
fi

TEMPLATE_ROOT="$(normalized_absolute_path "$TEMPLATE_ROOT")"
OUTPUT_PATH="$(normalized_absolute_path "$OUTPUT_PATH")"
require_disjoint_paths "$TEMPLATE_ROOT" "prefix-seed template" "$OUTPUT_PATH" "prefix-seed output"

reset_managed_output_directory "$OUTPUT_PATH" "$SEED_MARKER" "prefix-seed output" "$ROOT" "$TEMPLATE_ROOT"

for seed_file in system.reg user.reg userdef.reg; do
  if [[ ! -f "$TEMPLATE_ROOT/$seed_file" ]]; then
    echo "prefix-seed template is missing $seed_file" >&2
    exit 66
  fi
  cp "$TEMPLATE_ROOT/$seed_file" "$OUTPUT_PATH/$seed_file"
done

echo "Generated prefix seed at $OUTPUT_PATH"
