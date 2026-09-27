#!/usr/bin/env python3
"""Package only a complete, unsigned app. Never access a signing keychain."""
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import stat
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


def refresh_runtime_manifest_artifacts(app):
    """Refresh artifact hashes after unsigned packaging mutates bundled Mach-O files."""
    bundled_runtime_root = app / "BundledRuntime"
    if not bundled_runtime_root.is_dir():
        return

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
            if not artifact_path.is_file():
                # The iOS bundle intentionally omits the compressed Wine archive when
                # the extracted app-staged userland is present. Preserve its canonical
                # archive identity in the manifest for upgrade comparisons.
                continue
            data = artifact_path.read_bytes()
            checksum = hashlib.sha256(data).hexdigest()
            size_bytes = len(data)
            if artifact.get("checksum") != checksum or artifact.get("sizeBytes") != size_bytes:
                artifact["checksum"] = checksum
                artifact["sizeBytes"] = size_bytes
                changed = True

        if changed:
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )


def package(app, output):
    if output.resolve().is_relative_to(app.resolve()):
        raise ValueError("Output directory must be outside the app bundle")
    check_payload(app)
    check_asset_catalog(app)
    output.mkdir(parents=True, exist_ok=True)
    ipa = output / "Iridium-unsigned.ipa"
    report_path = output / "ipa-size-report.json"
    checksum_path = output / "SHA256SUMS"
    if ipa.exists() or ipa.is_symlink():
        raise ValueError("Output IPA already exists; use a new output directory")
    if any(path.exists() or path.is_symlink() for path in (report_path, checksum_path)):
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
        # codesign --remove-signature changes Mach-O bytes. Refresh the bundled
        # runtime inventory only after every signature has been removed so the
        # manifest describes the exact bytes that are written into the IPA.
        refresh_runtime_manifest_artifacts(staged)
        links = deduplicate_windows_runtime(staged)
        check_payload(staged)
        temporary_ipa = Path(tmp) / "Iridium-unsigned.ipa"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", str(payload), str(temporary_ipa)], check=True)
        report = check_windows_runtime_archive(temporary_ipa, links)
        temporary_report = Path(tmp) / report_path.name
        temporary_report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary_checksum = Path(tmp) / checksum_path.name
        temporary_checksum.write_text(file_sha256(temporary_ipa) + "  " + ipa.name + "\n", encoding="utf-8")
        # Stage all outputs first; publish the verified IPA last. Report/write
        # failures must not leave a final IPA that appears ready to distribute.
        published = []
        try:
            for temporary, destination in ((temporary_report, report_path),
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
    print("Created unsigned IPA. Users must sign the app and its extensions before installation.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: package-unsigned-ipa.py Iridium.app output-directory")
    try:
        package(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Unsigned packaging failed: {error}")
