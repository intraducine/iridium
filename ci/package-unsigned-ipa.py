#!/usr/bin/env python3
"""Package only a complete, unsigned app. Never access a signing keychain."""
import hashlib
import json
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

MACHO = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
SENSITIVE = {".p12", ".pfx", ".mobileprovision", ".provisionprofile"}
PRIVATE_KEY_MARKER = re.compile(rb"-----BEGIN (?P<label>(?:RSA |EC |OPENSSH )?PRIVATE KEY)-----")
PEM_BASE64_LINE = re.compile(rb"[A-Za-z0-9+/]+={0,2}")
PEM_METADATA_LINE = re.compile(rb"[A-Za-z0-9-]+:[ -~]*")
MAX_PEM_SCAN = 1024 * 1024


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
    if ipa.exists():
        raise ValueError("Output IPA already exists; use a new output directory")
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
        check_payload(staged)
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", str(payload), str(ipa)], check=True)
    (output / "SHA256SUMS").write_text(hashlib.sha256(ipa.read_bytes()).hexdigest() + "  " + ipa.name + "\n")
    print("Created unsigned IPA. Users must sign the app and its extensions before installation.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: package-unsigned-ipa.py Iridium.app output-directory")
    try:
        package(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Unsigned packaging failed: {error}")
