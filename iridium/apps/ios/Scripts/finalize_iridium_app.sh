#!/bin/sh

set -eu

products_root="${CONFIGURATION_BUILD_DIR:-${BUILT_PRODUCTS_DIR:-}}"
if [ -z "${products_root}" ]; then
  echo "error: CONFIGURATION_BUILD_DIR and BUILT_PRODUCTS_DIR are unavailable" >&2
  exit 1
fi

app_root="${products_root}/Iridium.app"
root_bundle="${app_root}/BundledRuntime/iridium-runtime-base"
root_manifest="${root_bundle}/manifest.json"
package_bundle="${app_root}/Iridium_IridiumRuntime.bundle"
package_runtime_root="${package_bundle}/BundledRuntime"
fallback_manifest="${package_runtime_root}/iridium-runtime-base/manifest.json"
support_root="${app_root}/IridiumWineUserland"

case "${app_root}" in
  "${products_root}"/Iridium.app) ;;
  *)
    echo "error: Refusing to finalize unexpected app path ${app_root}" >&2
    exit 1
    ;;
esac

if [ ! -d "${app_root}" ]; then
  echo "error: Built Iridium app is missing at ${app_root}" >&2
  exit 1
fi
if [ ! -s "${root_manifest}" ]; then
  echo "error: Canonical bundled runtime manifest is missing at ${root_manifest}" >&2
  exit 1
fi
if [ ! -d "${package_bundle}" ]; then
  echo "error: SwiftPM runtime resource bundle is missing at ${package_bundle}" >&2
  exit 1
fi

# Xcode copies SwiftPM product resources after the application target's own
# build phases. Finalize them from a dependent aggregate target so this cleanup
# happens after that hidden copy on clean, incremental, and archive builds.
case "${package_runtime_root}" in
  "${app_root}"/Iridium_IridiumRuntime.bundle/BundledRuntime)
    rm -rf "${package_runtime_root}"
    mkdir -p "${package_runtime_root}/iridium-runtime-base"
    cp -f "${root_manifest}" "${fallback_manifest}"
    ;;
  *)
    echo "error: Refusing to prune unexpected package runtime path ${package_runtime_root}" >&2
    exit 1
    ;;
esac

if ! cmp -s "${root_manifest}" "${fallback_manifest}"; then
  echo "error: Canonical and SwiftPM fallback runtime manifests differ" >&2
  exit 1
fi

unexpected_archive="$(find "${app_root}" -name 'wine-userland.tar.zst' -print -quit)"
if [ -n "${unexpected_archive}" ]; then
  echo "error: Compressed Wine userland was duplicated into the final app at ${unexpected_archive}" >&2
  exit 1
fi

for required_path in \
  "${root_bundle}/Runtime/runtime-host.bin" \
  "${root_bundle}/Translator/x64-jit.bin" \
  "${support_root}/bin/wineserver" \
  "${support_root}/lib/wine/x86_64-unix/wine-preloader" \
  "${support_root}/lib/wine/x86_64-unix/ntdll.so" \
  "${support_root}/lib/wine/x86_64-unix/wineios.so" \
  "${support_root}/lib/wine/x86_64-unix/opengl32.so" \
  "${support_root}/share/wine/nls/l_intl.nls"
do
  if [ ! -s "${required_path}" ]; then
    echo "error: Final Iridium app is missing required runtime file ${required_path}" >&2
    exit 1
  fi
done

python3 - "${root_bundle}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
if manifest.get("supportMetadata", {}).get("userlandDelivery") != "app-staged-extracted":
    raise SystemExit("error: Runtime manifest does not declare app-staged-extracted userland delivery")

for artifact in manifest.get("artifacts", []):
    relative = artifact.get("relativePath", "")
    if relative == "Userland/wine-userland.tar.zst":
        continue
    path = root / relative
    data = path.read_bytes()
    expected_size = artifact.get("sizeBytes")
    expected_hash = artifact.get("checksum")
    if len(data) != expected_size:
        raise SystemExit(f"error: Runtime artifact size mismatch for {relative}")
    if hashlib.sha256(data).hexdigest() != expected_hash:
        raise SystemExit(f"error: Runtime artifact checksum mismatch for {relative}")
PY

echo "Finalized Iridium.app after SwiftPM resource copying; runtime payload is singular and verified"

# System-directory XInput loads must use the same bridge as app-local loads.
# Madeira recreates prefix system32/sysx64 links from this bundle on each launch.
if [ -d "${app_root}/arm64ec-windows" ]; then
  media_reader="${app_root}/MediaRuntime/mfreadwrite.dll"
  [ -s "$media_reader" ] || { echo "error: Missing iOS media reader" >&2; exit 1; }
  cp "$media_reader" "${app_root}/arm64ec-windows/mfreadwrite.dll"
  controller_bridge="${app_root}/ControllerRuntime/arm64ec/xinput.dll"
  [ -s "$controller_bridge" ] || { echo "error: Missing ARM64EC controller bridge" >&2; exit 1; }
  for name in xinput1_1 xinput1_2 xinput1_3 xinput1_4 xinput9_1_0; do
    cp "$controller_bridge" "${app_root}/arm64ec-windows/$name.dll"
  done
fi

# This aggregate target runs after Xcode signs Iridium.app. Refresh the outer
# signature after pruning duplicate resources and installing runtime bridges.
signing_identity="$(codesign -dvv "${app_root}" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
if [ -n "${signing_identity}" ]; then
  codesign --force --sign "${signing_identity}" --timestamp=none \
    --preserve-metadata=identifier,entitlements,requirements,flags "${app_root}"
  codesign --verify --deep --strict "${app_root}"
fi
