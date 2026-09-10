#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path
from typing import Optional


FEXCORE_DISABLED_MARKER = b"Embedded FEX runtime was compiled without FEXCore support"
EMBEDDED_GUEST_WINE_LOADER_MEMBERS = (
    "lib/wine/x86_64-unix/wine-preloader",
    "lib64/wine/x86_64-unix/wine-preloader",
    "lib/wine/x86_64-unix/wine",
    "lib64/wine/x86_64-unix/wine",
    "bin/wine64",
    "bin/wine",
)
PRELOADER_COMPANION_WINE_NAMES = ("wine", "wine64")
WINEIOS_DRIVER_MEMBERS = (
    "lib/wine/x86_64-unix/wineios.so",
    "lib64/wine/x86_64-unix/wineios.so",
    "lib/wine/aarch64-unix/wineios.so",
    "lib64/wine/aarch64-unix/wineios.so",
)
OPENGL_BACKEND_MEMBERS = (
    "lib/wine/x86_64-unix/opengl32.so",
    "lib64/wine/x86_64-unix/opengl32.so",
    "lib/wine/aarch64-unix/opengl32.so",
    "lib64/wine/aarch64-unix/opengl32.so",
)
EGL_LOADER_BASENAME = "win32u.so"
OUTPUT_MARKER = ".iridium-runtime-bundle-output"


def reset_managed_output_directory(output_root: Path, protected_sources: list[Path]) -> Path:
    resolved_root = output_root.expanduser().resolve()
    unsafe_roots = {Path("/"), Path.home().resolve(), Path(tempfile.gettempdir()).resolve()}
    if resolved_root in unsafe_roots:
        raise SystemExit(f"refusing to replace unsafe runtime bundle output: {resolved_root}")

    for source in protected_sources:
        resolved_source = source.expanduser().resolve()
        if resolved_source == resolved_root or resolved_root in resolved_source.parents:
            raise SystemExit(
                f"refusing to replace runtime bundle output because it contains input artifact: {resolved_source}"
            )

    if resolved_root.exists():
        if not resolved_root.is_dir():
            raise SystemExit(f"runtime bundle output exists and is not a directory: {resolved_root}")
        if any(resolved_root.iterdir()) and not (resolved_root / OUTPUT_MARKER).is_file():
            raise SystemExit(
                f"refusing to replace unmanaged runtime bundle output (missing {OUTPUT_MARKER}): {resolved_root}"
            )
        shutil.rmtree(resolved_root)

    resolved_root.mkdir(parents=True)
    (resolved_root / OUTPUT_MARKER).touch()
    return resolved_root


def sha256_for(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def code_signature_invariant_macho_sha256(path: Path) -> str:
    payload = bytearray(path.read_bytes())
    mach_header_64_size = 32
    lc_segment_64 = 0x19
    lc_code_signature = 0x1D

    if len(payload) < mach_header_64_size:
        raise SystemExit(f"runtime host is too small to be a 64-bit Mach-O: {path}")
    magic, = struct.unpack_from("<I", payload, 0)
    if magic != 0xFEEDFACF:
        raise SystemExit(f"runtime host is not a little-endian 64-bit Mach-O: {path}")

    command_count, command_bytes = struct.unpack_from("<II", payload, 16)
    command_offset = mach_header_64_size
    command_region_end = command_offset + command_bytes
    if command_region_end > len(payload):
        raise SystemExit(f"runtime host has an invalid Mach-O load-command region: {path}")

    signature_command_offset = None
    signature_offset = None
    signing_owned_ranges: list[range] = []
    for _ in range(command_count):
        if command_offset + 8 > command_region_end:
            raise SystemExit(f"runtime host has a truncated Mach-O load command: {path}")
        command, command_size = struct.unpack_from("<II", payload, command_offset)
        if command_size < 8 or command_offset + command_size > command_region_end:
            raise SystemExit(f"runtime host has an invalid Mach-O load command: {path}")

        if command == lc_segment_64 and command_size >= 72:
            segment_name = bytes(
                payload[command_offset + 8:command_offset + 24]
            ).split(b"\0", 1)[0]
            if segment_name == b"__LINKEDIT":
                signing_owned_ranges.extend(
                    [
                        range(command_offset + 32, command_offset + 40),
                        range(command_offset + 48, command_offset + 56),
                    ]
                )
        elif command == lc_code_signature:
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


def copy_artifact(source: Path, destination: Path) -> dict:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    if destination.name == "runtime-host.bin":
        destination.chmod(0o755)
    return {
        "checksum": sha256_for(destination),
        "relativePath": destination.relative_to(destination.parents[1]).as_posix(),
        "sizeBytes": destination.stat().st_size,
    }


def load_graphics_stack_identifier(path: Path) -> str:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    return payload.get("graphicsStack", "metalOpenGLFallback")


def require_non_empty_string(value: object, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"invalid bundle metadata: {field_name} must be a non-empty string")
    return value.strip()


def git_revision_for(path: Optional[Path]) -> Optional[str]:
    if path is None:
        return None
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return result.stdout.strip() or None


def tar_command_variants(path: Path, operation: str, member: Optional[str] = None) -> list[list[str]]:
    commands: list[list[str]] = []
    prefers_zstd = path.name.endswith(".tar.zst")

    if prefers_zstd:
        commands.append(["tar", "--zstd", operation, str(path)])
        commands.append(["tar", "-I", "zstd", operation, str(path)])
    commands.append(["tar", operation, str(path)])

    if member is not None:
        commands = [command + [member] for command in commands]

    return commands


def run_tar_command(
    path: Path,
    operation: str,
    member: Optional[str] = None,
    *,
    text: bool,
):
    last_error: Optional[BaseException] = None
    for command in tar_command_variants(path, operation, member):
        try:
            return subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=text,
            )
        except (subprocess.CalledProcessError, FileNotFoundError) as error:
            last_error = error

    if last_error is not None:
        raise last_error
    raise RuntimeError(f"failed to invoke tar for {path}")


def archive_members(path: Path) -> list[str]:
    result = run_tar_command(path, "-tf", text=True)
    return [line.strip().lstrip("./") for line in result.stdout.splitlines() if line.strip()]


def archive_member_prefix(path: Path, member: str, max_bytes: int = 20) -> bytes:
    result = run_tar_command(path, "-xOf", member, text=False)
    return result.stdout[:max_bytes]


def archive_member_contains(path: Path, member: str, marker: bytes) -> bool:
    result = run_tar_command(path, "-xOf", member, text=False)
    return marker in result.stdout


def inspect_embedded_guest_wine_loader(data: bytes) -> tuple[bool, bool, Optional[str]]:
    is_x86_64_elf = (
        len(data) >= 20
        and data[:4] == b"\x7fELF"
        and data[4] == 2
        and data[5] == 1
        and data[18] == 0x3E
        and data[19] == 0x00
    )
    if not is_x86_64_elf:
        return False, False, None

    has_program_interpreter = False
    program_interpreter_path: Optional[str] = None
    if len(data) >= 64:
        e_phoff = int.from_bytes(data[32:40], "little")
        e_phentsize = int.from_bytes(data[54:56], "little")
        e_phnum = int.from_bytes(data[56:58], "little")
        if e_phoff != 0 and e_phentsize >= 40 and e_phnum != 0:
            table_size = e_phentsize * e_phnum
            if e_phoff <= len(data) and table_size <= len(data) - e_phoff:
                for index in range(e_phnum):
                    offset = e_phoff + index * e_phentsize
                    p_type = int.from_bytes(data[offset:offset + 4], "little")
                    p_offset = int.from_bytes(data[offset + 8:offset + 16], "little")
                    p_filesz = int.from_bytes(data[offset + 32:offset + 40], "little")
                    if p_type == 3 and p_filesz > 0:
                        has_program_interpreter = True
                        if p_offset < len(data):
                            raw = data[p_offset:p_offset + p_filesz].split(b"\0", 1)[0]
                            if raw:
                                program_interpreter_path = raw.decode("utf-8", errors="replace")
                        break

    return True, has_program_interpreter, program_interpreter_path


def data_looks_x86_64_elf(data: bytes) -> bool:
    return inspect_embedded_guest_wine_loader(data)[0]


def data_looks_embedded_guest_wine_loader(data: bytes) -> bool:
    is_x86_64_elf, has_program_interpreter, _ = inspect_embedded_guest_wine_loader(data)
    return is_x86_64_elf and not has_program_interpreter


def data_looks_unix_wine_loader_companion(data: bytes) -> bool:
    return inspect_embedded_guest_wine_loader(data)[0]


def preloader_has_companion_wine_loader(path: Path, member: str, members: list[str]) -> bool:
    parent = member.rsplit("/", 1)[0]
    for companion_name in PRELOADER_COMPANION_WINE_NAMES:
        companion = f"{parent}/{companion_name}"
        if companion not in members:
            continue
        prefix = archive_member_prefix(path, companion, max_bytes=4096)
        is_x86_64_elf, has_program_interpreter, interpreter_path = inspect_embedded_guest_wine_loader(prefix)
        if not is_x86_64_elf:
            continue
        if has_program_interpreter:
            if not interpreter_path:
                continue
            interpreter_member = interpreter_path.lstrip("/")
            if interpreter_member not in members:
                continue
        return True
    return False


def describe_binary_container(data: bytes) -> str:
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
    if len(data) >= 2 and data[:2] == b"#!":
        return "script"
    if not data:
        return "unreadable"
    return "unknown format"


def ensure_userland_archive_shape(path: Path) -> None:
    members = archive_members(path)

    def has_prefix(prefix: str) -> bool:
        return any(member == prefix or member.startswith(prefix + "/") for member in members)

    if not ("bin/wine64" in members or "bin/wine" in members):
        raise SystemExit("userland archive is missing bin/wine64 or bin/wine")
    if "bin/wineserver" not in members:
        raise SystemExit("userland archive is missing bin/wineserver")
    if not (has_prefix("lib/wine") or has_prefix("lib64/wine")):
        raise SystemExit("userland archive is missing lib/wine or lib64/wine")
    if not has_prefix("share/wine"):
        raise SystemExit("userland archive is missing share/wine")
    if "share/wine/nls/l_intl.nls" not in members:
        raise SystemExit("userland archive is missing share/wine/nls/l_intl.nls")
    if not has_prefix("prefix-seed"):
        raise SystemExit("userland archive is missing prefix-seed")

    required_seed_files = (
        "prefix-seed/system.reg",
        "prefix-seed/user.reg",
        "prefix-seed/userdef.reg",
    )
    for seed_file in required_seed_files:
        if seed_file not in members:
            raise SystemExit(f"userland archive is missing {seed_file}")

    if not any(member in members for member in WINEIOS_DRIVER_MEMBERS):
        raise SystemExit(
            "userland archive is missing wineios.drv Unix driver "
            "(expected lib/wine/*-unix/wineios.so or lib64/wine/*-unix/wineios.so)"
        )

    opengl_backend = next((member for member in OPENGL_BACKEND_MEMBERS if member in members), None)
    if opengl_backend is None:
        raise SystemExit(
            "userland archive is missing an EGL-capable Wine OpenGL backend "
            "(expected lib/wine/*-unix/opengl32.so or lib64/wine/*-unix/opengl32.so)"
        )
    egl_loader = str(Path(opengl_backend).parent / EGL_LOADER_BASENAME)
    if egl_loader not in members:
        raise SystemExit(
            "userland archive Wine OpenGL backend is not EGL-capable "
            f"({opengl_backend} is missing sibling {egl_loader})"
        )
    if not archive_member_contains(path, egl_loader, b"libEGL"):
        raise SystemExit(
            "userland archive Wine OpenGL backend is not EGL-capable "
            f"({egl_loader} does not contain libEGL linkage)"
        )

    incompatible_candidates: list[str] = []
    for member in EMBEDDED_GUEST_WINE_LOADER_MEMBERS:
        if member not in members:
            continue
        prefix = archive_member_prefix(path, member, max_bytes=4096)
        if data_looks_embedded_guest_wine_loader(prefix):
            if member.endswith("wine-preloader") or member.endswith("wine64-preloader"):
                if not preloader_has_companion_wine_loader(path, member, members):
                    raise SystemExit(
                        "userland archive wine-preloader requires a sibling Unix Wine loader and its PT_INTERP ELF interpreter"
                    )
            return
        incompatible_candidates.append(f"{member} ({describe_binary_container(prefix)})")

    if incompatible_candidates:
        raise SystemExit(
            "userland archive does not expose an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP; "
            f"found only {', '.join(incompatible_candidates)}"
        )

    raise SystemExit(
        "userland archive is missing an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP "
        "(expected lib/wine/x86_64-unix/wine-preloader, lib64/wine/x86_64-unix/wine-preloader, lib/wine/x86_64-unix/wine, lib64/wine/x86_64-unix/wine, bin/wine64, or bin/wine)"
    )


def ensure_translator_supports_fexcore(path: Path) -> None:
    payload = path.read_bytes()
    if FEXCORE_DISABLED_MARKER in payload:
        raise SystemExit(
            "translator artifact appears to be built without FEXCore support; rebuild iridium-fex-ios embedded translator for device"
        )


def ensure_runtime_host_supports_fexcore(path: Path) -> None:
    payload = path.read_bytes()
    if FEXCORE_DISABLED_MARKER in payload:
        raise SystemExit(
            "runtime-host artifact appears to be built without FEXCore support; rebuild iridium-runtime-sdk runtime host with FEXCore-enabled embedded bridge"
        )


def validate_manifest_metadata(manifest_path: Path) -> None:
    with manifest_path.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)

    require_non_empty_string(manifest.get("id"), "manifest.id")
    require_non_empty_string(manifest.get("name"), "manifest.name")
    require_non_empty_string(manifest.get("version"), "manifest.version")

    descriptor = manifest.get("descriptor")
    if not isinstance(descriptor, dict):
        raise SystemExit("invalid bundle metadata: manifest.descriptor must be an object")

    require_non_empty_string(descriptor.get("identifier"), "manifest.descriptor.identifier")
    require_non_empty_string(descriptor.get("name"), "manifest.descriptor.name")
    require_non_empty_string(descriptor.get("cpuTranslation"), "manifest.descriptor.cpuTranslation")
    require_non_empty_string(descriptor.get("graphicsStack"), "manifest.descriptor.graphicsStack")

    support_metadata = manifest.get("supportMetadata")
    if not isinstance(support_metadata, dict):
        raise SystemExit("invalid bundle metadata: manifest.supportMetadata must be an object")

    for field_name in (
        "bundleSource",
        "engineFamily",
        "executionModel",
        "launchMode",
        "runtimeHostContractVersion",
        "supportedArchitectures",
        "supportedGraphicsAPIs",
        "translatorBackend",
        "translatorArtifactType",
        "userlandPackaging",
    ):
        require_non_empty_string(
            support_metadata.get(field_name),
            f"manifest.supportMetadata.{field_name}",
        )

    invariant_checksum = support_metadata.get("runtimeHostCodeSignatureInvariantSHA256")
    if (
        not isinstance(invariant_checksum, str)
        or len(invariant_checksum) != 64
        or any(character not in "0123456789abcdefABCDEF" for character in invariant_checksum)
    ):
        raise SystemExit(
            "invalid bundle metadata: manifest.supportMetadata."
            "runtimeHostCodeSignatureInvariantSHA256 must be a sha256"
        )

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise SystemExit("invalid bundle metadata: manifest.artifacts must be a non-empty array")

    required_artifact_identifiers = {
        "runtime-host-binary",
        "x64-jit-translator",
        "wine-userland",
        "vkd3d-stack",
        "ios-presentation-backend",
        "direct-launch-profile",
    }
    seen_identifiers = set()
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise SystemExit("invalid bundle metadata: each manifest artifact must be an object")

        identifier = require_non_empty_string(artifact.get("identifier"), "manifest.artifacts[].identifier")
        require_non_empty_string(artifact.get("relativePath"), f"manifest.artifacts[{identifier}].relativePath")
        require_non_empty_string(artifact.get("kind"), f"manifest.artifacts[{identifier}].kind")

        checksum = artifact.get("checksum")
        if not isinstance(checksum, str) or len(checksum) != 64:
            raise SystemExit(f"invalid bundle metadata: manifest.artifacts[{identifier}].checksum must be a sha256")

        size_bytes = artifact.get("sizeBytes")
        if not isinstance(size_bytes, int) or size_bytes <= 0:
            raise SystemExit(
                f"invalid bundle metadata: manifest.artifacts[{identifier}].sizeBytes must be a positive integer"
            )

        seen_identifiers.add(identifier)

    missing_identifiers = sorted(required_artifact_identifiers - seen_identifiers)
    if missing_identifiers:
        missing_value = ", ".join(missing_identifiers)
        raise SystemExit(f"invalid bundle metadata: manifest.artifacts is missing {missing_value}")


def smoke_validate_bundle(output_root: Path) -> None:
    manifest_path = output_root / "manifest.json"
    runtime_host = output_root / "Runtime" / "runtime-host.bin"
    translator = output_root / "Translator" / "x64-jit.bin"
    userland = output_root / "Userland" / "wine-userland.tar.zst"
    presentation_backend = output_root / "Graphics" / "ios-presentation-backend.json"
    direct_launch_profile = output_root / "Metadata" / "direct-launch.json"

    if not manifest_path.is_file():
        raise SystemExit("smoke check failed: manifest.json is missing")
    if not runtime_host.is_file():
        raise SystemExit("smoke check failed: runtime-host.bin is missing")
    if not translator.is_file():
        raise SystemExit("smoke check failed: x64-jit.bin is missing")
    if not userland.is_file():
        raise SystemExit("smoke check failed: wine-userland.tar.zst is missing")
    if not presentation_backend.is_file():
        raise SystemExit("smoke check failed: ios-presentation-backend.json is missing")

    ensure_runtime_host_supports_fexcore(runtime_host)
    ensure_translator_supports_fexcore(translator)
    ensure_userland_archive_shape(userland)
    validate_manifest_metadata(manifest_path)

    with presentation_backend.open("r", encoding="utf-8") as handle:
        presentation_payload = json.load(handle)
    if presentation_payload.get("presentable") is not True:
        raise SystemExit("smoke check failed: iOS presentation backend is not marked presentable")

    with direct_launch_profile.open("r", encoding="utf-8") as handle:
        profile = json.load(handle)
    if not profile.get("directLaunchOnly", profile.get("directLaunch", False)):
        raise SystemExit("smoke check failed: direct-launch profile is not direct-launch-only")

    architectures = profile.get("supportedArchitectures") or profile.get("supportsArchitectures") or []
    if "x64" not in architectures:
        raise SystemExit("smoke check failed: direct-launch profile does not advertise x64 support")

    with tempfile.TemporaryDirectory(prefix="iridium-runtime-smoke-") as temp_dir:
        temp_root = Path(temp_dir)
        managed_bundle_root = temp_root / "Managed" / "Runtime" / output_root.name
        managed_bundle_root.parent.mkdir(parents=True)
        # The runtime host extracts Wine beside the managed bundle archive.  Run
        # the smoke launch against an isolated copy so validation cannot mutate
        # the bundle that will be shipped (or accidentally embed both the
        # archive and a full extracted userland in the app).
        shutil.copytree(output_root, managed_bundle_root)
        game_root = temp_root / "Game"
        prefix_root = temp_root / "Prefix"
        outputs_root = temp_root / "Outputs"
        game_root.mkdir(parents=True)
        prefix_root.mkdir(parents=True)
        outputs_root.mkdir(parents=True)

        executable_path = game_root / "SampleGame.exe"
        executable_path.write_bytes(b"sample-game")

        environment_file = temp_root / "environment.env"
        environment_file.write_text(
            "\n".join(
                [
                    f"WINEPREFIX={prefix_root}",
                    "WINEARCH=win64",
                    "IRIDIUM_NO_DESKTOP=1",
                    "IRIDIUM_HOST_JIT_STATUS=ready",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        launch_package = temp_root / "launch-package.json"
        launch_package.write_text(
            json.dumps(
                {
                    "id": "smoke-launch",
                    "gameTitle": "Smoke Game",
                    "executablePath": str(executable_path),
                    "workingDirectory": str(game_root),
                    "runtimeBundleRootPath": str(managed_bundle_root),
                    "environmentFilePath": str(environment_file),
                    "directLaunchOnly": True,
                    "launchArguments": [],
                    "environment": {},
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

        session_update = outputs_root / "session-update.json"
        terminal_result = outputs_root / "terminal-result.json"
        telemetry = outputs_root / "telemetry.json"
        host_log = outputs_root / "host.log"

        environment = dict(os.environ)
        environment.update(
            {
                "IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY": "1",
                "IRIDIUM_FEX_IOS_SMOKE_EXECUTION": "1",
                "IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE": "1",
            }
        )

        result = subprocess.run(
            [
                str(runtime_host),
                "--launch-package",
                str(launch_package),
                "--session-update",
                str(session_update),
                "--terminal-result",
                str(terminal_result),
                "--telemetry",
                str(telemetry),
                "--host-log",
                str(host_log),
            ],
            check=False,
            capture_output=True,
            env=environment,
            text=True,
        )

        if result.returncode not in (0, 1):
            raise SystemExit(
                f"smoke check failed: runtime-host exited with unexpected status {result.returncode}: {result.stderr.strip()}"
            )
        if not session_update.is_file():
            raise SystemExit("smoke check failed: runtime-host did not emit session-update.json")
        if not terminal_result.is_file():
            raise SystemExit("smoke check failed: runtime-host did not emit terminal-result.json")
        if not host_log.is_file():
            raise SystemExit("smoke check failed: runtime-host did not emit host.log")

        host_log_text = host_log.read_text(encoding="utf-8")
        if "launch-package=" not in host_log_text:
            raise SystemExit("smoke check failed: host log did not record the launch package")
        if "userland-root=" not in host_log_text and "userland-unpack=" not in host_log_text:
            raise SystemExit("smoke check failed: host log did not record userland resolution")

    if (output_root / "Userland" / "extracted").exists():
        raise SystemExit("smoke check failed: validation mutated the packaged runtime bundle")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", default="iridium-runtime-base")
    parser.add_argument("--bundle-name", default="Iridium Runtime Base")
    parser.add_argument("--bundle-version", required=True)
    parser.add_argument("--runtime-host", required=True, type=Path)
    parser.add_argument("--translator", required=True, type=Path)
    parser.add_argument("--userland", required=True, type=Path)
    parser.add_argument("--wine-fork-root", type=Path)
    parser.add_argument("--fex-fork-root", type=Path)
    parser.add_argument("--graphics-config", required=True, type=Path)
    parser.add_argument("--presentation-backend-config", type=Path)
    parser.add_argument("--direct-launch-profile", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--minimum-device-tier", default="tier1")
    parser.add_argument("--smoke-check", action="store_true")
    args = parser.parse_args()

    require_non_empty_string(args.bundle_id, "bundle id")
    require_non_empty_string(args.bundle_name, "bundle name")
    require_non_empty_string(args.bundle_version, "bundle version")

    presentation_backend_config = (
        args.presentation_backend_config
        if args.presentation_backend_config is not None
        else args.graphics_config.parent / "ios-presentation-backend.json"
    )

    output_root = reset_managed_output_directory(
        args.output_root,
        [
            args.runtime_host,
            args.translator,
            args.userland,
            args.graphics_config,
            presentation_backend_config,
            args.direct_launch_profile,
        ],
    )

    artifacts = [
        ("runtime-host-binary", "Runtime/runtime-host.bin", "runtimeBinary", args.runtime_host),
        ("x64-jit-translator", "Translator/x64-jit.bin", "translationLayer", args.translator),
        ("wine-userland", "Userland/wine-userland.tar.zst", "userlandPayload", args.userland),
        ("vkd3d-stack", "Graphics/vkd3d-stack.json", "graphicsStack", args.graphics_config),
        (
            "ios-presentation-backend",
            "Graphics/ios-presentation-backend.json",
            "graphicsStack",
            presentation_backend_config,
        ),
        ("direct-launch-profile", "Metadata/direct-launch.json", "metadata", args.direct_launch_profile),
    ]

    ensure_runtime_host_supports_fexcore(args.runtime_host)
    ensure_translator_supports_fexcore(args.translator)

    manifest_artifacts = []
    for identifier, relative_path, kind, source_path in artifacts:
        if not source_path.is_file():
            raise SystemExit(f"missing required artifact: {source_path}")
        artifact_record = copy_artifact(source_path, output_root / relative_path)
        artifact_record["identifier"] = identifier
        artifact_record["kind"] = kind
        manifest_artifacts.append(artifact_record)

    manifest = {
        "artifacts": manifest_artifacts,
        "bundleRootPath": None,
        "descriptor": {
            "cpuTranslation": "x64ToARM64JIT",
            "exposesDesktopShell": False,
            "graphicsStack": load_graphics_stack_identifier(args.graphics_config),
            "identifier": args.bundle_id,
            "name": args.bundle_name,
        },
        "id": args.bundle_id,
        "minimumDeviceTier": args.minimum_device_tier,
        "name": args.bundle_name,
        "supportMetadata": {
            "bundleSource": "app-bundled",
            "engineFamily": "wine-derived",
            "executionModel": "in-process-embedded",
            "launchMode": "direct-executable-only",
            "runtimeHostContractVersion": "1",
            "runtimeHostCodeSignatureInvariantSHA256":
                code_signature_invariant_macho_sha256(args.runtime_host),
            "supportedArchitectures": "x64",
            "supportedGraphicsAPIs": "opengl",
            "translatorBackend": "fex-derived",
            "translatorArtifactType": "static-library",
            "userlandPackaging": "archive-unpack",
        },
        "supportsDirectGameLaunch": True,
        "version": args.bundle_version,
    }

    wine_revision = git_revision_for(args.wine_fork_root)
    if wine_revision:
        manifest["supportMetadata"]["wineForkRevision"] = wine_revision

    fex_revision = git_revision_for(args.fex_fork_root)
    if fex_revision:
        manifest["supportMetadata"]["fexForkRevision"] = fex_revision

    with (output_root / "manifest.json").open("w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")

    validate_manifest_metadata(output_root / "manifest.json")

    if args.smoke_check:
        smoke_validate_bundle(output_root)

    print(f"Packaged runtime bundle at {output_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
