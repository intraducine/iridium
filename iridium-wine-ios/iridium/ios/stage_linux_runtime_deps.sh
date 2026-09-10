#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  stage_linux_runtime_deps.sh --install-root <path>

Copies Linux runtime dependencies reported by ldd into the install root,
preserving guest absolute paths such as lib64/ld-linux-x86-64.so.2.

Environment:
  LDD_BIN                         ldd executable to use; defaults to ldd
  LINUX_RUNTIME_DEP_SOURCE_ROOT   optional sysroot prefix for dependency sources
EOF
}

install_root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-root) install_root="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

if [[ -z "$install_root" ]]; then
  usage
  exit 64
fi

if [[ ! -d "$install_root" ]]; then
  echo "install root does not exist: $install_root" >&2
  exit 66
fi

ldd_bin="${LDD_BIN:-ldd}"
if ! command -v "$ldd_bin" >/dev/null 2>&1; then
  echo "ldd is required to stage Linux runtime dependencies" >&2
  exit 69
fi

source_root="${LINUX_RUNTIME_DEP_SOURCE_ROOT:-}"
if [[ -n "$source_root" ]]; then
  source_root="${source_root%/}"
fi

copy_dependency() {
  local guest_path="$1"
  local source_path=""
  local destination_path=""

  [[ "$guest_path" == /* ]] || return 0
  case "$guest_path" in
    /proc/*|/dev/*|/sys/*|/run/*) return 0 ;;
  esac

  if [[ -n "$source_root" ]]; then
    source_path="$source_root$guest_path"
  else
    source_path="$guest_path"
  fi

  if [[ ! -e "$source_path" ]]; then
    echo "missing Linux runtime dependency source: $source_path for $guest_path" >&2
    exit 66
  fi

  destination_path="$install_root/${guest_path#/}"
  mkdir -p "$(dirname "$destination_path")"
  cp -L "$source_path" "$destination_path"
}

parse_ldd_line() {
  local line="$1"
  local path=""

  line="${line#"${line%%[![:space:]]*}"}"
  case "$line" in
    linux-vdso*|statically\ linked*|not\ a\ dynamic\ executable*) return 0 ;;
  esac

  if [[ "$line" =~ "=> "[[:space:]]*(/[^[:space:]]+) ]]; then
    path="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^(/[^[:space:]]+) ]]; then
    path="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$path" ]]; then
    copy_dependency "$path"
  fi
}

roots=()
for relative in bin lib lib64; do
  if [[ -d "$install_root/$relative" ]]; then
    roots+=("$install_root/$relative")
  fi
done

if [[ "${#roots[@]}" -eq 0 ]]; then
  exit 0
fi

while IFS= read -r -d '' candidate; do
  while IFS= read -r line; do
    parse_ldd_line "$line"
  done < <("$ldd_bin" "$candidate" 2>/dev/null || true)
done < <(find "${roots[@]}" -type f -print0)
