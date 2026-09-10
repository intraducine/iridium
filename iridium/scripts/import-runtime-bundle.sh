#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <source-runtime-bundle-root> [destination-runtime-bundle-root]" >&2
  exit 64
fi

absolute_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$PWD/${path#./}"
  fi
}

SOURCE_ROOT="$(absolute_path "$1")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_ROOT=${2:-"$REPO_ROOT/packages/runtime/Sources/IridiumRuntime/Resources/BundledRuntime/iridium-runtime-base"}
DEST_ROOT="$(absolute_path "$DEST_ROOT")"

required_paths=(
  "Runtime/runtime-host.bin"
  "Translator/x64-jit.bin"
  "Userland/wine-userland.tar.zst"
  "Graphics/vkd3d-stack.json"
  "Graphics/ios-presentation-backend.json"
  "Metadata/direct-launch.json"
)

if [[ ! -d "$SOURCE_ROOT" ]]; then
  echo "source runtime bundle root is missing: $SOURCE_ROOT" >&2
  exit 66
fi

for relative_path in "${required_paths[@]}"; do
  if [[ ! -f "$SOURCE_ROOT/$relative_path" ]]; then
    echo "missing required runtime artifact: $SOURCE_ROOT/$relative_path" >&2
    exit 66
  fi
done

python3 - "$SOURCE_ROOT" "$DEST_ROOT" "$REPO_ROOT" <<'PY'
import hashlib
import json
import shutil
import struct
import sys
import tempfile
from pathlib import Path

source_root = Path(sys.argv[1]).expanduser().resolve()
dest_root = Path(sys.argv[2]).expanduser().resolve()
repo_root = Path(sys.argv[3]).expanduser().resolve()
default_dest_root = (
    repo_root
    / "packages/runtime/Sources/IridiumRuntime/Resources/BundledRuntime/iridium-runtime-base"
).resolve()
manifest_source = source_root / "manifest.json"


def code_signature_invariant_macho_sha256(path: Path) -> str:
    payload = bytearray(path.read_bytes())
    if len(payload) < 32 or struct.unpack_from("<I", payload, 0)[0] != 0xFEEDFACF:
        raise SystemExit(f"runtime host is not a little-endian 64-bit Mach-O: {path}")
    command_count, command_bytes = struct.unpack_from("<II", payload, 16)
    command_offset = 32
    command_region_end = command_offset + command_bytes
    signature_command_offset = None
    signature_offset = None
    signing_owned_ranges = []
    if command_region_end > len(payload):
        raise SystemExit(f"runtime host has an invalid Mach-O load-command region: {path}")
    for _ in range(command_count):
        if command_offset + 8 > command_region_end:
            raise SystemExit(f"runtime host has a truncated Mach-O load command: {path}")
        command, command_size = struct.unpack_from("<II", payload, command_offset)
        if command_size < 8 or command_offset + command_size > command_region_end:
            raise SystemExit(f"runtime host has an invalid Mach-O load command: {path}")
        if command == 0x19 and command_size >= 72:
            segment_name = bytes(payload[command_offset + 8:command_offset + 24]).split(b"\0", 1)[0]
            if segment_name == b"__LINKEDIT":
                signing_owned_ranges.extend(
                    [
                        range(command_offset + 32, command_offset + 40),
                        range(command_offset + 48, command_offset + 56),
                    ]
                )
        elif command == 0x1D:
            if command_size < 16:
                raise SystemExit(f"runtime host has a truncated LC_CODE_SIGNATURE: {path}")
            signature_offset, _ = struct.unpack_from("<II", payload, command_offset + 8)
            if signature_offset < command_region_end or signature_offset > len(payload):
                raise SystemExit(f"runtime host has an invalid code-signature offset: {path}")
            signature_command_offset = command_offset
        command_offset += command_size
    if signature_command_offset is None or signature_offset is None:
        raise SystemExit(f"runtime host is missing LC_CODE_SIGNATURE: {path}")
    canonical = payload[:signature_offset]
    signing_owned_ranges.append(
        range(signature_command_offset + 8, signature_command_offset + 16)
    )
    for signing_owned_range in signing_owned_ranges:
        for index in signing_owned_range:
            canonical[index] = 0
    return hashlib.sha256(canonical).hexdigest()

unsafe_destinations = {
    Path("/"),
    Path.home().resolve(),
    Path(tempfile.gettempdir()).resolve(),
    repo_root,
}
if dest_root in unsafe_destinations:
    raise SystemExit(f"refusing to replace unsafe runtime bundle destination: {dest_root}")
if (
    source_root == dest_root
    or source_root in dest_root.parents
    or dest_root in source_root.parents
):
    raise SystemExit(
        f"refusing overlapping runtime bundle source and destination: {source_root} -> {dest_root}"
    )

descriptor = {
    "cpuTranslation": "x64ToARM64JIT",
    "exposesDesktopShell": False,
    "graphicsStack": "vkd3dViaMoltenVK",
    "identifier": source_root.name,
    "name": "Iridium Runtime Base",
}
manifest = {
    "id": source_root.name,
    "name": "Iridium Runtime Base",
    "version": "0.0.0-imported",
    "descriptor": descriptor,
    "minimumDeviceTier": "tier1",
    "supportsDirectGameLaunch": True,
    "bundleRootPath": None,
    "supportMetadata": {},
}

if manifest_source.exists():
    with manifest_source.open("r", encoding="utf-8") as handle:
        manifest.update(json.load(handle))

required = [
    ("runtime-host-binary", "Runtime/runtime-host.bin", "runtimeBinary"),
    ("x64-jit-translator", "Translator/x64-jit.bin", "translationLayer"),
    ("wine-userland", "Userland/wine-userland.tar.zst", "userlandPayload"),
    ("vkd3d-stack", "Graphics/vkd3d-stack.json", "graphicsStack"),
    ("ios-presentation-backend", "Graphics/ios-presentation-backend.json", "graphicsStack"),
    ("direct-launch-profile", "Metadata/direct-launch.json", "metadata"),
]

if dest_root.exists():
    if not dest_root.is_dir():
        raise SystemExit(f"runtime bundle destination is not a directory: {dest_root}")
    destination_has_content = any(dest_root.iterdir())
    destination_looks_managed = all(
        (dest_root / relative_path).is_file()
        for _, relative_path, _ in required
    ) and (dest_root / "manifest.json").is_file()
    if (
        destination_has_content
        and dest_root != default_dest_root
        and not destination_looks_managed
    ):
        raise SystemExit(
            f"refusing to replace unmanaged runtime bundle destination: {dest_root}"
        )
    shutil.rmtree(dest_root)
shutil.copytree(
    source_root,
    dest_root,
    ignore=shutil.ignore_patterns(".iridium-runtime-bundle-output"),
)

artifacts = []
for identifier, relative_path, kind in required:
    artifact_path = dest_root / relative_path
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
support_metadata = dict(manifest.get("supportMetadata", {}))
support_metadata.setdefault("bundleSource", "app-bundled")
support_metadata.setdefault("engineFamily", "wine-derived")
support_metadata.setdefault("translatorBackend", "fex-derived")
support_metadata.setdefault("supportedArchitectures", "x64")
support_metadata.setdefault("supportedGraphicsAPIs", "d3d11,opengl")
support_metadata.setdefault("runtimeHostContractVersion", "1")
support_metadata.setdefault("launchMode", "direct-executable-only")
support_metadata["runtimeHostCodeSignatureInvariantSHA256"] = (
    code_signature_invariant_macho_sha256(dest_root / "Runtime/runtime-host.bin")
)
manifest["supportMetadata"] = support_metadata

with (dest_root / "manifest.json").open("w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")

host_binary = dest_root / "Runtime/runtime-host.bin"
host_binary.chmod(0o755)
PY

echo "Imported runtime bundle into $DEST_ROOT"
