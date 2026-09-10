function normalized_absolute_path() {
  print -r -- "${1:A}"
}

function path_is_same_or_descendant() {
  local candidate="$(normalized_absolute_path "$1")"
  local parent="$(normalized_absolute_path "$2")"
  [[ "$candidate" == "$parent" || "${candidate#$parent/}" != "$candidate" ]]
}

function require_disjoint_paths() {
  local first="$(normalized_absolute_path "$1")"
  local first_label="$2"
  local second="$(normalized_absolute_path "$3")"
  local second_label="$4"

  if path_is_same_or_descendant "$first" "$second" || path_is_same_or_descendant "$second" "$first"; then
    echo "$first_label and $second_label must not overlap: $first and $second" >&2
    return 64
  fi
}

function reset_managed_output_directory() {
  local target="$(normalized_absolute_path "$1")"
  local marker="$2"
  local label="$3"
  shift 3

  local temp_root="${${TMPDIR:-/tmp}:A}"
  if [[ "$target" == "/" || "$target" == "${HOME:A}" || "$target" == "$temp_root" ]]; then
    echo "refusing to replace unsafe $label: $target" >&2
    return 64
  fi

  local protected=""
  for protected in "$@"; do
    protected="$(normalized_absolute_path "$protected")"
    if path_is_same_or_descendant "$protected" "$target"; then
      echo "refusing to replace $label because it contains protected path $protected: $target" >&2
      return 64
    fi
  done

  if [[ -e "$target" && ! -d "$target" ]]; then
    echo "$label exists and is not a directory: $target" >&2
    return 73
  fi

  if [[ -d "$target" && ! -f "$target/$marker" ]]; then
    local first_entry="$(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
    if [[ -n "$first_entry" ]]; then
      echo "refusing to replace unmanaged $label (missing $marker): $target" >&2
      return 73
    fi
  fi

  rm -rf "$target"
  mkdir -p "$target"
  : > "$target/$marker"
}

function require_python3_for_binary_inspection() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  echo "python3 is required to inspect Wine loader binaries" >&2
  return 69
}

function describe_binary_container() {
  python3 - "$1" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    data = path.read_bytes()
except OSError:
    print("unreadable")
    raise SystemExit(0)

def inspect_embedded_guest_wine_loader(payload):
    is_x86_64_elf = (
        len(payload) >= 20
        and payload[:4] == b"\x7fELF"
        and payload[4] == 2
        and payload[5] == 1
        and int.from_bytes(payload[18:20], "little") == 62
    )
    if not is_x86_64_elf:
        return False, False

    has_program_interpreter = False
    if len(payload) >= 64:
        e_phoff = int.from_bytes(payload[32:40], "little")
        e_phentsize = int.from_bytes(payload[54:56], "little")
        e_phnum = int.from_bytes(payload[56:58], "little")
        if e_phoff != 0 and e_phentsize >= 40 and e_phnum != 0:
            table_size = e_phentsize * e_phnum
            if e_phoff <= len(payload) and table_size <= len(payload) - e_phoff:
                for index in range(e_phnum):
                    offset = e_phoff + index * e_phentsize
                    p_type = int.from_bytes(payload[offset:offset + 4], "little")
                    p_filesz = int.from_bytes(payload[offset + 32:offset + 40], "little")
                    if p_type == 3 and p_filesz > 0:
                        has_program_interpreter = True
                        break

    return True, has_program_interpreter


is_x86_64_elf, has_program_interpreter = inspect_embedded_guest_wine_loader(data)
if is_x86_64_elf:
    if has_program_interpreter:
        print("x86_64 ELF (PT_INTERP)")
    else:
        print("x86_64 ELF")
elif len(data) >= 4 and data[:4] == b"\x7fELF":
    print("non-x86_64 ELF")
elif data[:4] in (
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
):
    print("Mach-O")
elif len(data) >= 2 and data[:2] == b"#!":
    print("script")
elif not data:
    print("unreadable")
else:
    print("unknown format")
PY
}

function require_embedded_guest_wine_loader() {
  local root="$1"
  local label="${2:-Wine userland root}"
  local candidate=""
  local candidate_description=""
  typeset -a candidate_paths incompatible_candidates

  if ! require_python3_for_binary_inspection; then
    return $?
  fi

  candidate_paths=(
    "lib/wine/x86_64-unix/wine-preloader"
    "lib64/wine/x86_64-unix/wine-preloader"
    "lib/wine/x86_64-unix/wine"
    "lib64/wine/x86_64-unix/wine"
    "bin/wine64"
    "bin/wine"
    "wine64"
    "wine"
  )
  incompatible_candidates=()

  for candidate in "${candidate_paths[@]}"; do
    if [[ ! -f "$root/$candidate" ]]; then
      continue
    fi

    candidate_description=$(describe_binary_container "$root/$candidate")
    if [[ "$candidate_description" == "x86_64 ELF" ]]; then
      if [[ "$candidate" == *"wine-preloader" || "$candidate" == *"wine64-preloader" ]]; then
        if ! preloader_has_companion_wine_loader "$root" "$candidate"; then
          echo "$label wine-preloader requires a sibling Unix Wine loader and its PT_INTERP ELF interpreter." >&2
          return 66
        fi
      fi
      print "$candidate"
      return 0
    fi

    incompatible_candidates+=("$candidate ($candidate_description)")
  done

  if [[ "${#incompatible_candidates[@]}" -gt 0 ]]; then
    echo "$label does not expose an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP. Found only ${(j:, :)incompatible_candidates}." >&2
  else
    echo "$label is missing an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP (expected lib/wine/x86_64-unix/wine-preloader, lib64/wine/x86_64-unix/wine-preloader, lib/wine/x86_64-unix/wine, lib64/wine/x86_64-unix/wine, bin/wine64, bin/wine, wine64, or wine)." >&2
  fi
  return 66
}

function require_wineios_driver() {
  local root="$1"
  local label="${2:-Wine userland root}"
  local candidate=""
  typeset -a candidate_paths

  candidate_paths=(
    "lib/wine/x86_64-unix/wineios.so"
    "lib64/wine/x86_64-unix/wineios.so"
    "lib/wine/aarch64-unix/wineios.so"
    "lib64/wine/aarch64-unix/wineios.so"
  )

  for candidate in "${candidate_paths[@]}"; do
    if [[ -f "$root/$candidate" ]]; then
      print "$candidate"
      return 0
    fi
  done

  echo "$label is missing wineios.drv Unix driver (expected lib/wine/*-unix/wineios.so or lib64/wine/*-unix/wineios.so)." >&2
  return 66
}

function require_wineserver_nls() {
  local root="$1"
  local label="${2:-Wine userland root}"
  local relative_path="share/wine/nls/l_intl.nls"

  if [[ -s "$root/$relative_path" ]]; then
    print "$relative_path"
    return 0
  fi

  echo "$label is missing the native Wine server locale table at $relative_path." >&2
  return 66
}

function require_ios_opengl_backend() {
  local root="$1"
  local label="${2:-Wine userland root}"
  local candidate=""
  typeset -a candidate_paths

  candidate_paths=(
    "lib/wine/x86_64-unix/opengl32.so"
    "lib64/wine/x86_64-unix/opengl32.so"
    "lib/wine/aarch64-unix/opengl32.so"
    "lib64/wine/aarch64-unix/opengl32.so"
  )

  for candidate in "${candidate_paths[@]}"; do
    if [[ ! -f "$root/$candidate" ]]; then
      continue
    fi
    local egl_loader="${candidate:h}/win32u.so"
    if [[ -f "$root/$egl_loader" ]] && LC_ALL=C grep -a -F -q "libEGL" "$root/$egl_loader"; then
      print "$candidate"
      return 0
    fi

    echo "$label OpenGL backend $candidate is missing sibling EGL-capable win32u.so." >&2
    return 66
  done

  echo "$label is missing an EGL-capable Wine OpenGL backend (expected lib/wine/*-unix/opengl32.so or lib64/wine/*-unix/opengl32.so with sibling win32u.so containing libEGL linkage)." >&2
  return 66
}

function program_interpreter_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

try:
    data = Path(sys.argv[1]).read_bytes()
except OSError:
    raise SystemExit(0)

is_x86_64_elf = (
    len(data) >= 20
    and data[:4] == b"\x7fELF"
    and data[4] == 2
    and data[5] == 1
    and int.from_bytes(data[18:20], "little") == 62
)
if not is_x86_64_elf or len(data) < 64:
    raise SystemExit(0)

e_phoff = int.from_bytes(data[32:40], "little")
e_phentsize = int.from_bytes(data[54:56], "little")
e_phnum = int.from_bytes(data[56:58], "little")
if e_phoff == 0 or e_phentsize < 40 or e_phnum == 0:
    raise SystemExit(0)

table_size = e_phentsize * e_phnum
if e_phoff > len(data) or table_size > len(data) - e_phoff:
    raise SystemExit(0)

for index in range(e_phnum):
    offset = e_phoff + index * e_phentsize
    p_type = int.from_bytes(data[offset:offset + 4], "little")
    p_offset = int.from_bytes(data[offset + 8:offset + 16], "little")
    p_filesz = int.from_bytes(data[offset + 32:offset + 40], "little")
    if p_type == 3 and p_filesz > 0 and p_offset < len(data):
        raw = data[p_offset:p_offset + p_filesz].split(b"\0", 1)[0]
        if raw:
            print(raw.decode("utf-8", errors="replace"))
        break
PY
}

function preloader_has_companion_wine_loader() {
  local root="$1"
  local preloader_relative="$2"
  local parent="${preloader_relative:h}"
  local companion_name=""
  local companion=""
  local companion_description=""
  local interpreter_path=""

  for companion_name in wine wine64; do
    companion="$root/$parent/$companion_name"
    if [[ ! -f "$companion" ]]; then
      continue
    fi

    companion_description=$(describe_binary_container "$companion")
    if [[ "$companion_description" != "x86_64 ELF" && "$companion_description" != "x86_64 ELF (PT_INTERP)" ]]; then
      continue
    fi

    interpreter_path=$(program_interpreter_path "$companion")
    if [[ -n "$interpreter_path" && ! -f "$root/${interpreter_path#/}" ]]; then
      continue
    fi

    return 0
  done

  return 1
}

function copy_required_program_interpreters() {
  local source_root="$1"
  local output_root="$2"
  local relative=""
  local interpreter_path=""
  local source_path=""
  local destination_path=""
  typeset -a companion_paths

  companion_paths=(
    "lib/wine/x86_64-unix/wine"
    "lib64/wine/x86_64-unix/wine"
    "bin/wine64"
    "bin/wine"
    "wine64"
    "wine"
  )

  for relative in "${companion_paths[@]}"; do
    if [[ ! -f "$source_root/$relative" ]]; then
      continue
    fi

    interpreter_path=$(program_interpreter_path "$source_root/$relative")
    if [[ -z "$interpreter_path" ]]; then
      continue
    fi

    source_path="$source_root/${interpreter_path#/}"
    if [[ ! -f "$source_path" ]]; then
      continue
    fi

    destination_path="$output_root/${interpreter_path#/}"
    mkdir -p "${destination_path:h}"
    cp "$source_path" "$destination_path"
  done
}
