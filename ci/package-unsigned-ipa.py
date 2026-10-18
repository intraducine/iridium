#!/usr/bin/env python3
"""Package a sideloading app with one anonymous ad-hoc entitlement carrier."""
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile

MACHO = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
SENSITIVE = {".p12", ".pfx", ".mobileprovision", ".provisionprofile"}
PRIVATE_KEY_MARKER = re.compile(rb"-----BEGIN (?P<label>(?:RSA |EC |OPENSSH )?PRIVATE KEY)-----")
PEM_BASE64_LINE = re.compile(rb"[A-Za-z0-9+/]+={0,2}")
PEM_METADATA_LINE = re.compile(rb"[A-Za-z0-9-]+:[ -~]*")
MAX_PEM_SCAN = 1024 * 1024
WINDOWS_MODULE_SUFFIXES = {".dll", ".exe", ".drv", ".sys", ".acm", ".cpl", ".ax", ".ocx", ".mui", ".rll"}
CARRIER_IDENTIFIER = b"software.iridium\0"
CARRIER_ENTITLEMENTS = {"com.apple.developer.kernel.increased-memory-limit": True}
CARRIER_XML = plistlib.dumps(CARRIER_ENTITLEMENTS)
# Apple's canonical DER encoding of the same one-key boolean dictionary.
CARRIER_DER = (bytes.fromhex("703d020101b03830360c31")
               + next(iter(CARRIER_ENTITLEMENTS)).encode("utf-8") + bytes.fromhex("0101ff"))


def macho_slices(data):
    """Read every architecture, rejecting truncated or overlapping fat slices."""
    magic = data[:4]
    fat = {bytes.fromhex(value): (endian, wide) for value, endian, wide in (
        ("cafebabe", ">", False), ("bebafeca", "<", False),
        ("cafebabf", ">", True), ("bfbafeca", "<", True))}
    if magic not in fat:
        return [data]
    endian, wide = fat[magic]
    if len(data) < 8:
        raise ValueError("Truncated universal executable")
    count, = struct.unpack_from(endian + "I", data, 4)
    entry_size = 32 if wide else 20
    table_end = 8 + count * entry_size
    if not 1 <= count <= 32 or table_end > len(data):
        raise ValueError("Invalid universal architecture table")
    ranges = []
    for index in range(count):
        offset, size = struct.unpack_from(endian + ("QQ" if wide else "II"),
                                         data, 8 + index * entry_size + 8)
        if offset < table_end or not size or offset + size > len(data):
            raise ValueError("Invalid universal architecture range")
        ranges.append((offset, offset + size))
    ordered = sorted(ranges)
    if any(left[1] > right[0] for left, right in zip(ordered, ordered[1:])):
        raise ValueError("Overlapping universal architectures")
    return [data[start:end] for start, end in ranges]


def carrier_signature(data, info_bytes, resource_bytes):
    """Enforce the binary signature policy, independently of codesign's text.

    This deliberately accepts only the SHA-256 v0x20400 signature shape we
    generate. New formats need review, rather than silently widening policy.
    Slot definitions follow Apple's xnu osfmk/kern/cs_blobs.h.
    """
    thin = {bytes.fromhex(value): (endian, header) for value, endian, header in (
        ("feedface", ">", 28), ("cefaedfe", "<", 28),
        ("feedfacf", ">", 32), ("cffaedfe", "<", 32))}
    for image in macho_slices(data):
        if image[:4] not in thin or len(image) < 28:
            raise ValueError("Invalid carrier Mach-O header")
        endian, header = thin[image[:4]]
        filetype, count, command_bytes = struct.unpack_from(endian + "III", image, 12)
        command_end = header + command_bytes
        if filetype != 2 or command_end > len(image) or count > command_bytes // 8:
            raise ValueError("Invalid carrier load commands")
        cursor = header
        signatures = []
        for _ in range(count):
            if cursor + 8 > command_end:
                raise ValueError("Truncated carrier load command")
            command, size = struct.unpack_from(endian + "II", image, cursor)
            if size < 8 or size % 4 or cursor + size > command_end:
                raise ValueError("Invalid carrier load command size")
            if command == 0x1d:  # LC_CODE_SIGNATURE
                if size != 16:
                    raise ValueError("Invalid carrier signature command")
                signatures.append(struct.unpack_from(endian + "II", image, cursor + 8))
            cursor += size
        if cursor != command_end or len(signatures) != 1:
            raise ValueError("Carrier must have exactly one embedded signature per architecture")
        offset, size = signatures[0]
        if offset < command_end or size < 12 or offset + size != len(image):
            raise ValueError("Invalid carrier signature range")
        signature = image[offset:offset + size]
        magic, length, count = struct.unpack_from(">III", signature)
        if magic != 0xfade0cc0 or count != 5 or not 52 <= length <= size:
            raise ValueError("Unexpected carrier signature container")
        if any(signature[length:]):
            raise ValueError("Unexpected carrier signature padding")
        blobs = {}
        ranges = []
        for index in range(count):
            slot, start = struct.unpack_from(">II", signature, 12 + index * 8)
            if slot in blobs or start < 52 or start + 8 > length:
                raise ValueError("Invalid carrier signature slot")
            blob_magic, blob_length = struct.unpack_from(">II", signature, start)
            if blob_length < 8 or start + blob_length > length:
                raise ValueError("Invalid carrier signature blob")
            blobs[slot] = (blob_magic, signature[start:start + blob_length])
            ranges.append((start, start + blob_length))
        ordered = sorted(ranges)
        if ordered[0][0] != 52 or ordered[-1][1] != length or any(
                left[1] != right[0] for left, right in zip(ordered, ordered[1:])):
            raise ValueError("Ambiguous carrier signature layout")
        expected = {
            2: (0xfade0c01, bytes.fromhex("fade0c010000000c00000000")),
            5: (0xfade7171, struct.pack(">II", 0xfade7171, 8 + len(CARRIER_XML)) + CARRIER_XML),
            7: (0xfade7172, struct.pack(">II", 0xfade7172, 8 + len(CARRIER_DER)) + CARRIER_DER),
            0x10000: (0xfade0b01, bytes.fromhex("fade0b0100000008")),
        }
        if set(blobs) != {0, *expected} or any(blobs[slot] != blob for slot, blob in expected.items()):
            raise ValueError("Carrier contains CMS/certificates, requirements, or unexpected entitlements")
        cd_magic, cd = blobs[0]
        if cd_magic != 0xfade0c02 or len(cd) < 88:
            raise ValueError("Invalid carrier CodeDirectory")
        version, flags, hash_offset, ident_offset, special, code_slots, code_limit = struct.unpack_from(
            ">7I", cd, 8)
        hash_size, hash_type, platform, page = struct.unpack_from("4B", cd, 36)
        spare, scatter, team, spare3, limit64 = struct.unpack_from(">IIIIQ", cd, 40)
        exec_flags, = struct.unpack_from(">Q", cd, 80)
        expected_hash_offset = 88 + len(CARRIER_IDENTIFIER) + 7 * 32
        if (version != 0x20400 or flags != 2 or ident_offset != 88 or special != 7
                or hash_size != 32 or hash_type != 2 or platform != 0 or page not in (12, 14)
                or any((spare, scatter, team, spare3, limit64)) or exec_flags != 1
                or cd[88:88 + len(CARRIER_IDENTIFIER)] != CARRIER_IDENTIFIER
                or hash_offset != expected_hash_offset or code_limit != offset
                or code_slots != (code_limit + (1 << page) - 1) >> page
                or len(cd) != hash_offset + code_slots * 32):
            raise ValueError("Carrier identity, team, flags, or CodeDirectory format is unexpected")
        special_data = {1: info_bytes, 2: blobs[2][1], 3: resource_bytes,
                        5: blobs[5][1], 7: blobs[7][1]}
        for slot in range(1, 8):
            expected_hash = hashlib.sha256(special_data[slot]).digest() if slot in special_data else bytes(32)
            if cd[hash_offset - slot * 32:hash_offset - (slot - 1) * 32] != expected_hash:
                raise ValueError("Carrier does not seal the expected bundle metadata and entitlements")


def sign_entitlement_carrier(app):
    """Seal the staged bundle only; never sign nested code or use a keychain."""
    with tempfile.TemporaryDirectory(prefix="carrier-entitlements-", dir=app.parent) as tmp:
        entitlements = Path(tmp) / "carrier.plist"
        entitlements.write_bytes(CARRIER_XML)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-",
                        "--identifier", CARRIER_IDENTIFIER[:-1].decode("ascii"),
                        "--timestamp=none", "--digest-algorithm=sha256",
                        "--entitlements", str(entitlements), "--generate-entitlement-der", str(app)],
                       check=True, capture_output=True)


def audit_package_signatures(app):
    info_bytes = (app / "Info.plist").read_bytes()
    main = executable_path(app, plistlib.loads(info_bytes))
    if main.is_symlink():
        raise ValueError("The entitlement carrier must be a real main executable")
    resource_path = app / "_CodeSignature/CodeResources"
    if resource_path.is_symlink() or not resource_path.is_file():
        raise ValueError("The entitlement carrier is missing its bundle resource seal")
    allowed = {resource_path.parent, resource_path}
    for path in app.rglob("*"):
        if "_CodeSignature" in path.relative_to(app).parts and path not in allowed:
            raise ValueError("Unexpected nested signature resources")
    carrier_signature(main.read_bytes(), info_bytes, resource_path.read_bytes())
    # Validate code-page and resource hashes for all slices, including symlinks.
    # No --deep: helper/non-main executables must remain unsigned.
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(app)],
                   check=True, capture_output=True)
    unsigned_count = 0
    for path in app.rglob("*"):
        if path == main or path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            native = stream.read(4) in MACHO
        if native:
            if not unsigned_status(path):
                raise ValueError("Only the main executable may carry a signature")
            unsigned_count += 1
    refresh_runtime_manifest_artifacts(app, verify_only=True)
    return {"entitlementCarrier": {"path": main.relative_to(app).as_posix(),
                                  "sha256": file_sha256(main), "sizeBytes": main.stat().st_size,
                                  "identifier": CARRIER_IDENTIFIER[:-1].decode("ascii"),
                                  "entitlements": CARRIER_ENTITLEMENTS, "signature": "ad-hoc",
                                  "cmsPayloadBytes": 0, "teamIdentifier": None,
                                  "resourceSealSHA256": file_sha256(resource_path)},
            "unsignedNativeExecutableCount": unsigned_count}


def check_archive_modes(staged, delivered):
    """Check the ZIP round trip preserves all paths, modes, and link targets."""
    expected = {Path("."): staged, **{path.relative_to(staged): path for path in staged.rglob("*")}}
    actual = {Path("."): delivered, **{path.relative_to(delivered): path for path in delivered.rglob("*")}}
    if expected.keys() != actual.keys():
        raise ValueError("IPA changed the bundle path inventory")
    for relative, path in expected.items():
        other = actual[relative]
        mode = path.lstat().st_mode
        delivered_mode = other.lstat().st_mode
        if stat.S_IFMT(mode) != stat.S_IFMT(delivered_mode) or stat.S_IMODE(mode) != stat.S_IMODE(delivered_mode):
            raise ValueError(f"IPA changed a bundle file mode: {relative}")
        if path.is_symlink() and os.readlink(path) != os.readlink(other):
            raise ValueError(f"IPA changed a bundle symlink: {relative}")


def executable_path(bundle, info):
    name = info.get("CFBundleExecutable")
    if not isinstance(name, str) or not name or name in {".", ".."} or Path(name).name != name:
        raise ValueError("Invalid bundle executable name")
    return bundle / name


def _pem_payload_size(body):
    """Return encoded payload size when body is a plausible textual PEM payload."""
    encoded = 0
    payload_started = False
    for raw_line in body.replace(b"\r\n", b"\n").split(b"\n"):
        line = raw_line.strip()
        if not line:
            continue
        if not payload_started and PEM_METADATA_LINE.fullmatch(line):
            continue
        if not PEM_BASE64_LINE.fullmatch(line):
            return 0
        payload_started = True
        encoded += len(line)
    return encoded


def has_private_key_material(data):
    """Return True only when a private-key PEM marker is followed by key payload data."""
    for match in PRIVATE_KEY_MARKER.finditer(data):
        cursor = match.end()
        if data[cursor:cursor + 2] == b"\r\n":
            cursor += 2
        elif data[cursor:cursor + 1] == b"\n":
            cursor += 1
        else:
            # Compiled crypto libraries often contain parser marker strings without key data.
            continue

        limit = min(len(data), cursor + MAX_PEM_SCAN)
        end_marker = b"-----END " + match.group("label") + b"-----"
        end = data.find(end_marker, cursor, limit)
        if end >= 0:
            if _pem_payload_size(data[cursor:end]) >= 32:
                return True
            continue

        # Also catch a truncated PEM that contains a substantial base64 payload but no footer.
        candidate = data[cursor:limit].split(b"\x00", 1)[0]
        if _pem_payload_size(candidate) >= 128:
            return True
    return False


def check_payload(app):
    # Exact reviewed binaries only. Any changed byte requires another review.
    public_fixtures = {entry["sha256"] for entry in json.loads(
        Path(__file__).with_name("public-key-fixture-binaries.json").read_text())}
    for path in app.rglob("*"):
        if path.is_symlink():
            if not path.resolve().is_relative_to(app.resolve()):
                raise ValueError("App contains a symlink outside its bundle")
        if not path.is_file():
            continue
        if path.suffix.lower() in SENSITIVE:
            raise ValueError("App contains signing material; do not upload it")
        data = path.read_bytes()
        if has_private_key_material(data):
            if hashlib.sha256(data).hexdigest() not in public_fixtures:
                raise ValueError(f"App contains unreviewed private key material: {path.relative_to(app)}")
        if re.search(rb"\b00008[0-9A-Fa-f]{3}-[0-9A-Fa-f]{16}\b", data):
            raise ValueError("App contains a physical device identifier")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "software.iridium":
        raise ValueError("Expected the Iridium application bundle")
    if info.get("IridiumMadeiraRevision"):
        import importlib.util
        spec = importlib.util.spec_from_file_location("madeira_frontend", Path(__file__).with_name("madeira-frontend.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.check_bundle(app)
    elif not (app / "fonts/tahoma.ttf").is_file():
        raise ValueError("The bundled Windows fonts are missing")
    if info.get("IridiumRuntimeProfile") == "madeira":
        import importlib.util
        spec = importlib.util.spec_from_file_location("madeira_package", Path(__file__).with_name("madeira-package.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.check_app(app)
    executable = executable_path(app, info)
    if not executable.is_file() or executable.read_bytes()[:4] not in MACHO:
        raise ValueError("App executable is missing or is not Mach-O")
    helpers = list((app / "PlugIns").glob("*.appex"))
    if not helpers:
        raise ValueError("The built-in JIT helper extension is missing")
    for helper in helpers:
        helper_info = plistlib.loads((helper / "Info.plist").read_bytes())
        binary = executable_path(helper, helper_info)
        if not binary.is_file() or binary.read_bytes()[:4] not in MACHO:
            raise ValueError("Helper extension executable is missing")


def check_asset_catalog(app):
    source = Path(__file__).resolve().parents[1] / "iridium/apps/ios/Iridium/Assets.xcassets"
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('IridiumMadeiraRevision'):
        source = Path(__file__).resolve().parents[1] / 'vendor/Madeira/app/Madeira/Assets.xcassets'
    expected = {path.stem for path in source.glob("*.imageset")}
    if not expected:
        return
    catalog = app / "Assets.car"
    if not catalog.is_file():
        raise ValueError("App asset catalog is missing")
    result = subprocess.run(["xcrun", "assetutil", "--info", str(catalog)],
                            capture_output=True, text=True, check=True)
    actual = {item.get("Name") for item in json.loads(result.stdout)}
    missing = expected - actual
    if missing:
        raise ValueError("App asset catalog is missing images: " + ", ".join(sorted(missing)))


def unsigned_status(path):
    result = subprocess.run(["/usr/bin/codesign", "-d", str(path)], capture_output=True, text=True)
    if result.returncode == 0:
        return False
    if "not signed at all" in result.stderr:
        return True
    raise ValueError("Could not determine native executable signing state")


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def identical_files(first, second):
    """Compare bytes, not names, timestamps, or architecture-directory labels."""
    if first.stat().st_size != second.stat().st_size:
        return False
    with first.open("rb") as left, second.open("rb") as right:
        while True:
            chunk = left.read(1024 * 1024)
            if chunk != right.read(1024 * 1024):
                return False
            if not chunk:
                return True


def deduplicate_windows_runtime(app):
    """Replace identical PE resources in the disposable package copy with links.

    Keep both lookup paths: Wine uses both architecture directories. Never
    strip or rewrite a PE image, deduplicate native Mach-O code, or touch the
    Xcode product. Do this after bridge installation and signature removal so
    subsequent build steps cannot write through an alias into its other view.
    """
    canonical = app / "aarch64-windows"
    aliases = app / "arm64ec-windows"
    if not any(path.exists() or path.is_symlink() for path in (canonical, aliases)):
        return {}
    for directory in (canonical, aliases):
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError("Windows runtime directories must be real directories")

    links = {}
    for alias in sorted(aliases.iterdir()):
        if alias.suffix.lower() not in WINDOWS_MODULE_SUFFIXES:
            continue
        target = canonical / alias.name
        if target.is_symlink():
            raise ValueError("Windows runtime canonical module must not be a symlink")
        destination = "../aarch64-windows/" + alias.name
        if alias.is_symlink():
            # Permit a previously compacted app only when it has our exact,
            # one-hop, bundle-relative layout and a readable canonical file.
            if os.readlink(alias) != destination or not target.is_file():
                raise ValueError("Invalid Windows runtime module symlink")
        elif not alias.is_file() or not target.is_file():
            continue
        elif stat.S_IMODE(alias.stat().st_mode) != stat.S_IMODE(target.stat().st_mode):
            continue
        elif not identical_files(alias, target):
            continue
        with target.open("rb") as stream:
            if stream.read(2) != b"MZ":
                continue
        links[alias.relative_to(app).as_posix()] = {
            "target": destination,
            "canonical": target.relative_to(app).as_posix(),
            "size": target.stat().st_size,
            "sha256": file_sha256(target),
        }

    # Plan and validate everything before replacing any resource. A failure
    # discards the temporary package; it never damages the original app.
    for relative, record in links.items():
        alias = app / relative
        if not alias.is_symlink():
            # Create the replacement alongside the duplicate, then rename it
            # atomically. A failed link/rename leaves the original file intact.
            fd, temporary = tempfile.mkstemp(prefix=".iridium-dedup-", dir=aliases)
            os.close(fd)
            temporary = Path(temporary)
            try:
                temporary.unlink()
                temporary.symlink_to(record["target"])
                os.replace(temporary, alias)
            finally:
                temporary.unlink(missing_ok=True)
        if alias.resolve(strict=True) != (app / record["canonical"]).resolve(strict=True):
            raise ValueError("Windows runtime alias does not resolve to its canonical module")
    return links


def check_windows_runtime_archive(ipa, links):
    """Fail if the ZIP writer loses links, follows them, or changes PE bytes."""
    prefix = "Payload/Iridium.app/"
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        inventory = {entry.filename: entry for entry in entries}
        if len(inventory) != len(entries):
            raise ValueError("IPA contains ambiguous duplicate archive entries")
        for relative, record in links.items():
            alias = inventory.get(prefix + relative)
            target = inventory.get(prefix + record["canonical"])
            if alias is None or target is None:
                raise ValueError("IPA is missing a Windows runtime module path")
            if not stat.S_ISLNK(alias.external_attr >> 16):
                raise ValueError("IPA writer did not preserve Windows runtime symlinks")
            expected_link = record["target"].encode("utf-8")
            if alias.file_size != len(expected_link) or archive.read(alias) != expected_link:
                raise ValueError("IPA contains an incorrect Windows runtime symlink")
            if not stat.S_ISREG(target.external_attr >> 16) or target.file_size != record["size"]:
                raise ValueError("IPA contains an invalid canonical Windows module")
            digest = hashlib.sha256()
            with archive.open(target) as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            if digest.hexdigest() != record["sha256"]:
                raise ValueError("IPA changed canonical Windows module bytes")
        compressed_by_component = {}
        for entry in entries:
            if entry.filename.startswith(prefix) and not entry.is_dir():
                component = entry.filename[len(prefix):].split("/", 1)[0]
                compressed_by_component[component] = (
                    compressed_by_component.get(component, 0) + entry.compress_size)
        # These describe the resulting layout, including already-valid aliases
        # on a repeat package. They are not a measured compressed-byte saving.
        return {
            "ipaBytes": ipa.stat().st_size,
            "deduplicatedWindowsFiles": len(links),
            "duplicateUncompressedBytesAvoided": sum(record["size"] for record in links.values()),
            "compressedBytesByComponent": dict(sorted(compressed_by_component.items())),
            "windowsResourceAliases": links,
        }


def refresh_runtime_manifest_artifacts(app, *, verify_only=False):
    """Refresh hashes after signing, or verify final sealed bytes without edits."""
    bundled_runtime_root = app / "BundledRuntime"
    if not bundled_runtime_root.is_dir():
        return False

    any_changed = False
    manifest_paths = sorted(bundled_runtime_root.glob("*/manifest.json"))
    for manifest_path in manifest_paths:
        bundle_root = manifest_path.parent
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        artifacts = manifest.get("artifacts")
        if not isinstance(artifacts, list):
            raise ValueError(f"Runtime manifest has invalid artifacts list: {manifest_path.relative_to(app)}")

        changed = False
        for artifact in artifacts:
            if not isinstance(artifact, dict):
                raise ValueError(f"Runtime manifest has invalid artifact entry: {manifest_path.relative_to(app)}")
            relative_path = artifact.get("relativePath")
            if not isinstance(relative_path, str) or not relative_path:
                raise ValueError(f"Runtime manifest artifact is missing relativePath: {manifest_path.relative_to(app)}")
            artifact_path = bundle_root / relative_path
            if not artifact_path.resolve().is_relative_to(bundle_root.resolve()):
                raise ValueError("Runtime manifest artifact escapes its runtime bundle")
            if not artifact_path.is_file():
                # The iOS bundle intentionally omits the compressed Wine archive when
                # the extracted app-staged userland is present. Preserve its canonical
                # archive identity in the manifest for upgrade comparisons.
                continue
            data = artifact_path.read_bytes()
            checksum = hashlib.sha256(data).hexdigest()
            size_bytes = len(data)
            if artifact.get("checksum") != checksum or artifact.get("sizeBytes") != size_bytes:
                if verify_only:
                    raise ValueError("Runtime manifest does not describe the final packaged bytes")
                artifact["checksum"] = checksum
                artifact["sizeBytes"] = size_bytes
                changed = True

        if changed:
            any_changed = True
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
    return any_changed


def package(app, output):
    if output.resolve().is_relative_to(app.resolve()):
        raise ValueError("Output directory must be outside the app bundle")
    check_payload(app)
    check_asset_catalog(app)
    output.mkdir(parents=True, exist_ok=True)
    ipa = output / "Iridium-unsigned.ipa"
    report_path = output / "ipa-size-report.json"
    audit_path = output / "ipa-signature-audit.json"
    checksum_path = output / "SHA256SUMS"
    if ipa.exists() or ipa.is_symlink():
        raise ValueError("Output IPA already exists; use a new output directory")
    if any(path.exists() or path.is_symlink() for path in (report_path, audit_path, checksum_path)):
        raise ValueError("Output report or checksum already exists; use a new output directory")
    with tempfile.TemporaryDirectory(prefix="unsigned-", dir=output) as tmp:
        payload = Path(tmp) / "Payload"
        staged = payload / "Iridium.app"
        shutil.copytree(app, staged, symlinks=True)
        native = []
        for path in staged.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            with path.open("rb") as stream:
                if stream.read(4) not in MACHO:
                    continue
            native.append(path)
            if not unsigned_status(path):
                subprocess.run(["/usr/bin/codesign", "--remove-signature", str(path)], check=True, capture_output=True)
        for path in sorted(staged.rglob("_CodeSignature"), reverse=True):
            if path.is_dir():
                shutil.rmtree(path)
        for path in native:
            if not unsigned_status(path):
                raise ValueError("Native code still has a signature")
        links = deduplicate_windows_runtime(staged)
        sign_entitlement_carrier(staged)
        # Inventory the final artifact bytes after signature changes. If these
        # manifests changed, reseal the bundle so CodeResources covers them.
        if refresh_runtime_manifest_artifacts(staged):
            sign_entitlement_carrier(staged)
        check_payload(staged)
        audit = audit_package_signatures(staged)
        temporary_ipa = Path(tmp) / "Iridium-unsigned.ipa"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", str(payload), str(temporary_ipa)], check=True)
        report = check_windows_runtime_archive(temporary_ipa, links)
        # Verify the extracted delivery as well as the staging directory. ditto
        # must preserve signed resource bytes and every sealed symlink target.
        extracted = Path(tmp) / "archive-audit"
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(temporary_ipa), str(extracted)], check=True)
        delivered = extracted / "Payload/Iridium.app"
        check_payload(delivered)
        if audit_package_signatures(delivered) != audit:
            raise ValueError("IPA changed the entitlement carrier or native signature policy")
        check_archive_modes(staged, delivered)
        temporary_report = Path(tmp) / report_path.name
        temporary_report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary_checksum = Path(tmp) / checksum_path.name
        temporary_checksum.write_text(file_sha256(temporary_ipa) + "  " + ipa.name + "\n", encoding="utf-8")
        temporary_audit = Path(tmp) / audit_path.name
        temporary_audit.write_text(json.dumps(audit, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        # Stage all outputs first; publish the verified IPA last. Report/write
        # failures must not leave a final IPA that appears ready to distribute.
        published = []
        try:
            for temporary, destination in ((temporary_report, report_path),
                                           (temporary_audit, audit_path),
                                           (temporary_checksum, checksum_path),
                                           (temporary_ipa, ipa)):
                temporary.replace(destination)
                published.append(destination)
        except OSError:
            for destination in reversed(published):
                destination.unlink(missing_ok=True)
            raise
        print(f"Shared {len(links)} identical Windows modules; "
              f"avoided {report['duplicateUncompressedBytesAvoided']} uncompressed duplicate bytes; "
              f"IPA {report['ipaBytes']} bytes.")
        print("IPA compressed component sizes: " + json.dumps(report["compressedBytesByComponent"], sort_keys=True))
    print("Created sideloading IPA with an anonymous ad-hoc increased-memory-limit carrier. "
          "Users must re-sign the app and sign its extensions before installation.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: package-unsigned-ipa.py Iridium.app output-directory")
    try:
        package(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Unsigned packaging failed: {error}")
