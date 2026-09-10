#!/bin/sh
set -eu

runtime_bundle_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/BundledRuntime/iridium-runtime-base"
support_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/IridiumWineUserland"
frameworks_root="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH:-Frameworks}"
sdk_root="${SRCROOT}/../../../iridium-runtime-sdk"
source_bundle_root="${IRIDIUM_RUNTIME_BUNDLE_ROOT:-${sdk_root}/build/iridium-runtime-base}"
amethyst_root="${IRIDIUM_AMETHYST_ROOT:-${SRCROOT}/../../../Amethyst-iOS}"

required_bundle_files="
manifest.json
Translator/x64-jit.bin
Userland/wine-userland.tar.zst
Graphics/vkd3d-stack.json
Graphics/ios-presentation-backend.json
Metadata/direct-launch.json
"

fexcore_disabled_marker="Embedded FEX runtime was compiled without FEXCore support"

candidate_roots="
${IRIDIUM_WINE_STAGED_ROOT:-}
${SRCROOT}/../../../iridium-runtime-sdk/build/wine-userland-linux-x86_64/staged-root
${source_bundle_root}/Userland/extracted
${SRCROOT}/../../../iridium-runtime-sdk/build/wine-userland/staged-root
${SRCROOT}/../../../iridium-runtime-sdk/build/wine-userland-device/staged-root
${SRCROOT}/../../../iridium-runtime-sdk/build/wine-userland-simulator/staged-root
${SRCROOT}/../../../iridium-runtime-sdk/build/wine-userland-host/staged-root
${SRCROOT}/../../../iridium-wine-ios/build-iridium-ios/staged-root
"

for required_command in python3 ditto grep; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "error: ${required_command} is required to stage the bundled runtime userland." >&2
    exit 69
  fi
done

copy_bundle_file() {
  relative_path="$1"
  source_path="${source_bundle_root}/${relative_path}"
  destination_path="${runtime_bundle_root}/${relative_path}"
  mkdir -p "$(dirname "${destination_path}")"
  cp -f "${source_path}" "${destination_path}"
}

inspect_embedded_guest_wine_loader() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
candidates = [
  "lib/wine/x86_64-unix/wine-preloader",
  "lib64/wine/x86_64-unix/wine-preloader",
  "lib/wine/x86_64-unix/wine",
  "lib64/wine/x86_64-unix/wine",
  "bin/wine64",
  "bin/wine",
  "wine64",
  "wine",
]
preloader_companion_names = ("wine", "wine64")


def inspect_embedded_guest_wine_loader(payload):
  is_x86_64_elf = (
    len(payload) >= 20
    and payload[:4] == b"\x7fELF"
    and payload[4] == 2
    and payload[5] == 1
    and payload[18] == 0x3E
    and payload[19] == 0x00
  )
  if not is_x86_64_elf:
    return False, False, None

  has_program_interpreter = False
  program_interpreter_path = None
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
          p_offset = int.from_bytes(payload[offset + 8:offset + 16], "little")
          p_filesz = int.from_bytes(payload[offset + 32:offset + 40], "little")
          if p_type == 3 and p_filesz > 0:
            has_program_interpreter = True
            if p_offset < len(payload):
              raw = payload[p_offset:p_offset + p_filesz].split(b"\0", 1)[0]
              if raw:
                program_interpreter_path = raw.decode("utf-8", errors="replace")
            break

  return True, has_program_interpreter, program_interpreter_path


def describe(data: bytes) -> str:
  is_x86_64_elf, has_program_interpreter, _ = inspect_embedded_guest_wine_loader(data)
  if is_x86_64_elf:
    return "x86_64 ELF (PT_INTERP)" if has_program_interpreter else "x86_64 ELF"
  if len(data) >= 4 and data[:4] == b"\x7fELF":
    return "non-x86_64 ELF"
  if data[:4] in (
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
  ):
    return "Mach-O"
  if data[:2] == b"#!":
    return "script"
  if not data:
    return "unreadable"
  return "unknown format"

def data_looks_unix_wine_loader_companion(data: bytes) -> bool:
  return inspect_embedded_guest_wine_loader(data)[0]

def preloader_has_companion_wine_loader(relative: str) -> bool:
  parent = Path(relative).parent
  for companion_name in preloader_companion_names:
    companion = root / parent / companion_name
    if not companion.is_file():
      continue
    is_x86_64_elf, has_program_interpreter, interpreter_path = inspect_embedded_guest_wine_loader(companion.read_bytes())
    if not is_x86_64_elf:
      continue
    if has_program_interpreter:
      if not interpreter_path:
        continue
      interpreter = root / interpreter_path.lstrip("/")
      if not interpreter.is_file():
        continue
    return True
  return False


incompatible = []
for relative in candidates:
  candidate = root / relative
  if not candidate.is_file():
    continue
  data = candidate.read_bytes()
  is_x86_64_elf, has_program_interpreter, _ = inspect_embedded_guest_wine_loader(data)
  if is_x86_64_elf and not has_program_interpreter:
    if relative.endswith("wine-preloader") or relative.endswith("wine64-preloader"):
      if not preloader_has_companion_wine_loader(relative):
        print("ERR:Staged Wine userland wine-preloader requires a sibling Unix Wine loader and its PT_INTERP ELF interpreter.")
        raise SystemExit(0)
    print(f"OK:{relative}")
    raise SystemExit(0)
  incompatible.append(f"{relative} ({describe(data)})")

if incompatible:
  print(
    "ERR:Staged Wine userland does not expose an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP. Found only "
    + ", ".join(incompatible)
    + "."
  )
else:
  print(
    "ERR:Staged Wine userland is missing an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP "
    "(expected lib/wine/x86_64-unix/wine-preloader, lib64/wine/x86_64-unix/wine-preloader, lib/wine/x86_64-unix/wine, lib64/wine/x86_64-unix/wine, bin/wine64, bin/wine, wine64, or wine)."
  )
PY
}

inspect_wineios_driver() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
candidates = [
  "lib/wine/x86_64-unix/wineios.so",
  "lib64/wine/x86_64-unix/wineios.so",
  "lib/wine/aarch64-unix/wineios.so",
  "lib64/wine/aarch64-unix/wineios.so",
]

for relative in candidates:
  if (root / relative).is_file():
    print(f"OK:{relative}")
    raise SystemExit(0)

print(
  "ERR:Staged Wine userland is missing wineios.drv Unix driver "
  "(expected lib/wine/*-unix/wineios.so or lib64/wine/*-unix/wineios.so)."
)
PY
}

inspect_ios_opengl_backend() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
candidates = [
  "lib/wine/x86_64-unix/opengl32.so",
  "lib64/wine/x86_64-unix/opengl32.so",
  "lib/wine/aarch64-unix/opengl32.so",
  "lib64/wine/aarch64-unix/opengl32.so",
]

for relative in candidates:
  candidate = root / relative
  if not candidate.is_file():
    continue
  egl_loader = candidate.parent / "win32u.so"
  if egl_loader.is_file() and b"libEGL" in egl_loader.read_bytes():
    print(f"OK:{relative}")
    raise SystemExit(0)
  print(f"ERR:Staged Wine userland OpenGL backend {relative} is missing sibling EGL-capable {egl_loader.relative_to(root)}.")
  raise SystemExit(0)

print(
  "ERR:Staged Wine userland is missing an EGL-capable Wine OpenGL backend "
  "(expected lib/wine/*-unix/opengl32.so or lib64/wine/*-unix/opengl32.so with sibling win32u.so containing libEGL linkage)."
)
PY
}

inspect_staged_userland_freshness() {
  python3 - "$1" <<'PY'
from pathlib import Path
import struct
import sys

staged_root = Path(sys.argv[1])
marker = staged_root / ".iridium-userland-stage"
if not marker.is_file():
  print("OK:untracked")
  raise SystemExit(0)

metadata = {}
for line in marker.read_text(encoding="utf-8", errors="replace").splitlines():
  key, separator, value = line.partition("=")
  if separator:
    metadata[key] = value

source_value = metadata.get("source_root", "")
if not source_value:
  print("ERR:Staged Wine userland provenance marker is missing source_root.")
  raise SystemExit(0)

source_root = Path(source_value)
if not source_root.is_dir():
  # A packaged or transferred staging tree may legitimately outlive its build
  # root. Other runtime-contract validation still applies in that case.
  print("OK:source-unavailable")
  raise SystemExit(0)

candidates = (
  "lib/wine/x86_64-unix/ntdll.so",
  "lib64/wine/x86_64-unix/ntdll.so",
)
relative = next(
  (path for path in candidates if (staged_root / path).is_file()),
  None,
)
if relative is None:
  print("ERR:Staged Wine userland is missing its x86_64 Unix ntdll.so.")
  raise SystemExit(0)

staged_ntdll = staged_root / relative
source_ntdll = source_root / relative
if not source_ntdll.is_file():
  print(f"ERR:Wine build root is missing the staged ntdll source at {source_ntdll}.")
  raise SystemExit(0)

def gnu_build_id(path: Path):
  data = path.read_bytes()
  if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
    return None
  section_offset = struct.unpack_from("<Q", data, 40)[0]
  section_size = struct.unpack_from("<H", data, 58)[0]
  section_count = struct.unpack_from("<H", data, 60)[0]
  if section_size < 64 or section_offset + section_size * section_count > len(data):
    return None
  for index in range(section_count):
    section = section_offset + index * section_size
    section_type = struct.unpack_from("<I", data, section + 4)[0]
    if section_type != 7:  # SHT_NOTE
      continue
    note_offset = struct.unpack_from("<Q", data, section + 24)[0]
    note_size = struct.unpack_from("<Q", data, section + 32)[0]
    note_end = min(len(data), note_offset + note_size)
    cursor = note_offset
    while cursor + 12 <= note_end:
      name_size, description_size, note_type = struct.unpack_from("<III", data, cursor)
      cursor += 12
      name_end = cursor + name_size
      description_start = (name_end + 3) & ~3
      description_end = description_start + description_size
      if description_end > note_end:
        break
      name = data[cursor:name_end].rstrip(b"\0")
      if name == b"GNU" and note_type == 3:
        return data[description_start:description_end].hex()
      cursor = (description_end + 3) & ~3
  return None

staged_build_id = gnu_build_id(staged_ntdll)
source_build_id = gnu_build_id(source_ntdll)
if not staged_build_id or not source_build_id:
  print(
    "ERR:Cannot verify staged Wine freshness because x86_64 Unix ntdll.so "
    "is missing a GNU build ID."
  )
  raise SystemExit(0)
if staged_build_id != source_build_id:
  print(
    "ERR:Staged Wine userland is stale: "
    f"{relative} has build ID {staged_build_id}, but its declared build source "
    f"has build ID {source_build_id}. "
    "Re-run stage_userland.sh and package_userland.sh before building the IPA."
  )
  raise SystemExit(0)

print(f"OK:{relative}:{staged_build_id}")
PY
}

if [ ! -d "${source_bundle_root}" ]; then
  echo "error: Missing canonical runtime bundle root at ${source_bundle_root}" >&2
  echo "error: Rebuild the runtime bundle through iridium-runtime-sdk before building the app." >&2
  exit 1
fi

for relative_path in ${required_bundle_files}; do
  if [ ! -f "${source_bundle_root}/${relative_path}" ]; then
    echo "error: Missing canonical runtime artifact ${source_bundle_root}/${relative_path}" >&2
    exit 1
  fi
done

runtime_host_source="${source_bundle_root}/Runtime/runtime-host.bin"

if [ ! -f "${runtime_host_source}" ]; then
  echo "error: Missing canonical runtime-host.bin at ${runtime_host_source}" >&2
  exit 1
fi

if LC_ALL=C grep -a -q "${fexcore_disabled_marker}" "${runtime_host_source}"; then
  echo "error: Selected runtime-host.bin appears to be built without FEXCore support: ${runtime_host_source}" >&2
  exit 1
fi

if LC_ALL=C grep -a -q "${fexcore_disabled_marker}" "${source_bundle_root}/Translator/x64-jit.bin"; then
  echo "error: Canonical translator artifact appears to be built without FEXCore support: ${source_bundle_root}/Translator/x64-jit.bin" >&2
  exit 1
fi

source_root=""
embedded_guest_wine_loader=""
source_root_validation_error=""
for candidate in ${candidate_roots}; do
  if [ ! -d "${candidate}" ] || [ ! -f "${candidate}/bin/wineserver" ]; then
    continue
  fi
  if [ ! -s "${candidate}/share/wine/nls/l_intl.nls" ]; then
    if [ -z "${source_root_validation_error}" ]; then
      source_root_validation_error="Staged Wine userland is missing share/wine/nls/l_intl.nls required by the native embedded server."
    fi
    continue
  fi

  freshness_validation="$(inspect_staged_userland_freshness "${candidate}")"
  case "${freshness_validation}" in
    OK:*) ;;
    ERR:*)
      if [ -z "${source_root_validation_error}" ]; then
        source_root_validation_error="${freshness_validation#ERR:}"
      fi
      continue
      ;;
  esac

  validation_result="$(inspect_embedded_guest_wine_loader "${candidate}")"
  case "${validation_result}" in
    OK:*)
      wineios_driver_validation="$(inspect_wineios_driver "${candidate}")"
      case "${wineios_driver_validation}" in
        OK:*) ;;
        ERR:*)
          if [ -z "${source_root_validation_error}" ]; then
            source_root_validation_error="${wineios_driver_validation#ERR:}"
          fi
          continue
          ;;
      esac
      opengl_backend_validation="$(inspect_ios_opengl_backend "${candidate}")"
      case "${opengl_backend_validation}" in
        OK:*) ;;
        ERR:*)
          if [ -z "${source_root_validation_error}" ]; then
            source_root_validation_error="${opengl_backend_validation#ERR:}"
          fi
          continue
          ;;
      esac
      source_root="${candidate}"
      embedded_guest_wine_loader="${validation_result#OK:}"
      break
      ;;
    ERR:*)
      if [ -z "${source_root_validation_error}" ]; then
        source_root_validation_error="${validation_result#ERR:}"
      fi
      ;;
  esac
done

if [ -z "${source_root}" ]; then
  echo "error: Missing embedded-FEX-compatible staged Wine userland root for iOS runtime bundling." >&2
  echo "error: Expected one of the following directories to exist with bin/wineserver and an x86_64 ELF Wine loader without PT_INTERP:" >&2
  for candidate in ${candidate_roots}; do
    echo "error:   ${candidate}" >&2
  done
  if [ -n "${source_root_validation_error}" ]; then
    echo "error: ${source_root_validation_error}" >&2
  fi
  exit 1
fi

mkdir -p "${runtime_bundle_root}"

for relative_path in ${required_bundle_files}; do
  copy_bundle_file "${relative_path}"
done

mkdir -p "${runtime_bundle_root}/Runtime"
cp -f "${runtime_host_source}" "${runtime_bundle_root}/Runtime/runtime-host.bin"
chmod 755 "${runtime_bundle_root}/Runtime/runtime-host.bin"

python3 - "${runtime_bundle_root}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

bundle_root = Path(sys.argv[1])
manifest_path = bundle_root / "manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

required = [
    ("runtime-host-binary", "Runtime/runtime-host.bin", "runtimeBinary"),
    ("x64-jit-translator", "Translator/x64-jit.bin", "translationLayer"),
    ("wine-userland", "Userland/wine-userland.tar.zst", "userlandPayload"),
    ("vkd3d-stack", "Graphics/vkd3d-stack.json", "graphicsStack"),
    ("ios-presentation-backend", "Graphics/ios-presentation-backend.json", "graphicsStack"),
    ("direct-launch-profile", "Metadata/direct-launch.json", "metadata"),
]

artifacts = []
for identifier, relative_path, kind in required:
    artifact_path = bundle_root / relative_path
    data = artifact_path.read_bytes()
    artifacts.append({
        "identifier": identifier,
        "relativePath": relative_path,
        "sizeBytes": len(data),
        "checksum": hashlib.sha256(data).hexdigest(),
        "kind": kind,
    })

manifest["artifacts"] = artifacts
manifest["bundleRootPath"] = None
manifest.setdefault("supportMetadata", {})["userlandDelivery"] = "app-staged-extracted"
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

# The extracted app-staged tree is the runtime source on iOS. Keeping its
# compressed archive in the same app would duplicate hundreds of megabytes,
# and provisioning would copy that duplicate into managed storage again. The
# manifest retains the canonical archive identity for upgrade comparisons.
rm -f "${runtime_bundle_root}/Userland/wine-userland.tar.zst"

case "${support_root}" in
  "${TARGET_BUILD_DIR}"/*/IridiumWineUserland)
    rm -rf "${support_root}"
    ;;
  *)
    echo "error: Refusing to replace unexpected staged userland path ${support_root}" >&2
    exit 1
    ;;
esac
mkdir -p "$(dirname "${support_root}")"
ditto "${source_root}" "${support_root}"

support_root_validation="$(inspect_embedded_guest_wine_loader "${support_root}")"
case "${support_root_validation}" in
  OK:*)
    embedded_guest_wine_loader="${support_root_validation#OK:}"
    ;;
  ERR:*)
    echo "error: ${support_root_validation#ERR:}" >&2
    exit 1
    ;;
esac

support_driver_validation="$(inspect_wineios_driver "${support_root}")"
case "${support_driver_validation}" in
  OK:*) ;;
  ERR:*)
    echo "error: ${support_driver_validation#ERR:}" >&2
    exit 1
    ;;
esac

support_opengl_validation="$(inspect_ios_opengl_backend "${support_root}")"
case "${support_opengl_validation}" in
  OK:*) ;;
  ERR:*)
    echo "error: ${support_opengl_validation#ERR:}" >&2
    exit 1
    ;;
esac

for framework_name in libEGL.framework libGLESv2.framework; do
  framework_source="${amethyst_root}/Natives/resources/Frameworks/${framework_name}"
  framework_destination="${frameworks_root}/${framework_name}"
  if [ ! -d "${framework_source}" ]; then
    echo "error: Missing ${framework_name} at ${framework_source}; set IRIDIUM_AMETHYST_ROOT to the Amethyst-iOS checkout used for iOS OpenGL support." >&2
    exit 1
  fi
  mkdir -p "${frameworks_root}"
  ditto "${framework_source}" "${framework_destination}"
done

if [ ! -f "${support_root}/bin/wineserver" ]; then
  echo "error: Staged app-bundled Wine userland root is incomplete after copy to ${support_root}" >&2
  exit 1
fi
if [ ! -s "${support_root}/share/wine/nls/l_intl.nls" ]; then
  echo "error: Staged app-bundled Wine userland is missing share/wine/nls/l_intl.nls" >&2
  exit 1
fi

# SwiftPM also copies the package's canonical runtime resource bundle into the
# app. Iridium uses the explicit Bundle.main override above, so keep only its
# tiny manifest fallback and remove the duplicate payload from this derived
# build product.
package_resource_bundle="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Iridium_IridiumRuntime.bundle"
package_runtime_root="${package_resource_bundle}/BundledRuntime"
case "${package_runtime_root}" in
  "${TARGET_BUILD_DIR}"/*/Iridium_IridiumRuntime.bundle/BundledRuntime)
    if [ -d "${package_resource_bundle}" ]; then
      rm -rf "${package_runtime_root}"
      mkdir -p "${package_runtime_root}/iridium-runtime-base"
      # The root manifest is finalized above with the app-staged userland
      # delivery contract. Keep SwiftPM's manifest-only fallback identical so
      # version and delivery diagnostics cannot disagree about this IPA.
      cp -f "${runtime_bundle_root}/manifest.json" \
        "${package_runtime_root}/iridium-runtime-base/manifest.json"
    fi
    ;;
  *)
    echo "error: Refusing to prune unexpected SwiftPM runtime resource path ${package_runtime_root}" >&2
    exit 1
    ;;
esac

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  mach_o_candidates="$(mktemp)"
  find "${support_root}" "${frameworks_root}/libEGL.framework" "${frameworks_root}/libGLESv2.framework" -type f > "${mach_o_candidates}"
  signed_any_binary=0
  while IFS= read -r candidate; do
    if file "${candidate}" | grep -q "Mach-O"; then
      codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "${candidate}"
      signed_any_binary=1
    fi
  done < "${mach_o_candidates}"
  rm -f "${mach_o_candidates}"
fi

echo "Staged runtime bundle artifacts from ${source_bundle_root}"
echo "Staged Wine userland from ${source_root}"
echo "Staged runtime-host.bin from ${runtime_host_source}"
echo "Staged app-bundled Wine support root at ${support_root}"
echo "Validated embedded guest Wine loader at ${embedded_guest_wine_loader}"
