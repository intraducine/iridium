import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "entitlement_carrier_tests", Path(__file__).with_name("package-unsigned-ipa.py"))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def blob(magic, data):
    return struct.pack(">II", magic, len(data) + 8) + data


def carrier_fixture(info=b"info", resources=b"resources", replacements=None, cd_changes=None):
    slots = {
        2: blob(0xfade0c01, bytes(4)),
        5: blob(0xfade7171, packager.CARRIER_XML),
        7: blob(0xfade7172, packager.CARRIER_DER),
        0x10000: blob(0xfade0b01, b""),
    }
    slots.update(replacements or {})
    hash_offset = 88 + len(packager.CARRIER_IDENTIFIER) + 224
    cd = bytearray(hash_offset + 32)
    struct.pack_into(">9I4BIIIIQ3Q", cd, 0, 0xfade0c02, len(cd), 0x20400, 2,
                     hash_offset, 88, 7, 1, 4096, 32, 2, 0, 12, 0, 0, 0, 0, 0, 0, 4096, 1)
    cd[88:88 + len(packager.CARRIER_IDENTIFIER)] = packager.CARRIER_IDENTIFIER
    values = {1: info, 2: slots[2], 3: resources, 5: slots[5], 7: slots[7]}
    for slot, data in values.items():
        cd[hash_offset - slot * 32:hash_offset - (slot - 1) * 32] = hashlib.sha256(data).digest()
    for offset, value in (cd_changes or {}).items():
        struct.pack_into(">I", cd, offset, value)
    slots[0] = bytes(cd)
    entries = sorted(slots.items())
    size = 12 + 8 * len(entries) + sum(len(data) for _, data in entries)
    image = bytearray(4096)
    struct.pack_into("<8I", image, 0, 0xfeedfacf, 0x100000c, 0, 2, 1, 16, 0, 0)
    struct.pack_into("<4I", image, 32, 0x1d, 16, 4096, size)
    cd[hash_offset:] = hashlib.sha256(image).digest()
    # Replace only the normal code hash; policy intentionally delegates code
    # page verification to codesign, exercised by the Darwin tests below.
    entries = [(slot, bytes(cd) if slot == 0 else data) for slot, data in entries]
    signature = struct.pack(">III", 0xfade0cc0, size, len(entries))
    cursor = 12 + 8 * len(entries)
    for slot, data in entries:
        signature += struct.pack(">II", slot, cursor)
        cursor += len(data)
    return bytes(image) + signature + b"".join(data for _, data in entries)


class CarrierPolicyTests(unittest.TestCase):
    def test_exact_anonymous_carrier_is_accepted(self):
        packager.carrier_signature(carrier_fixture(), b"info", b"resources")

    def test_cms_certificates_and_requirements_are_rejected(self):
        for slot, data in ((0x10000, blob(0xfade0b01, b"CMS certificate bytes")),
                           (2, blob(0xfade0c01, struct.pack(">I", 1))),
                           (0x10002, blob(0xfade0b01, b"timestamp"))):
            with self.subTest(slot=slot), self.assertRaises(ValueError):
                packager.carrier_signature(carrier_fixture(replacements={slot: data}), b"info", b"resources")

    def test_unexpected_xml_and_der_entitlements_are_rejected(self):
        cases = ({}, {next(iter(packager.CARRIER_ENTITLEMENTS)): False},
                 {next(iter(packager.CARRIER_ENTITLEMENTS)): 1},
                 {**packager.CARRIER_ENTITLEMENTS, "get-task-allow": True},
                 {**packager.CARRIER_ENTITLEMENTS, "com.apple.developer.team-identifier": "TEAM"})
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                packager.carrier_signature(carrier_fixture(replacements={
                    5: blob(0xfade7171, plistlib.dumps(value))}), b"info", b"resources")
        with self.assertRaises(ValueError):
            packager.carrier_signature(carrier_fixture(replacements={
                7: blob(0xfade7172, packager.CARRIER_DER[:-1] + b"\x00")}), b"info", b"resources")

    def test_team_identifier_flags_and_extra_directories_are_rejected(self):
        for offset, value in ((48, 88), (12, 0), (12, 0x10002), (8, 0x20500), (80, 1)):
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                packager.carrier_signature(carrier_fixture(cd_changes={offset: value}), b"info", b"resources")
        with self.assertRaises(ValueError):
            packager.carrier_signature(carrier_fixture(replacements={0x1000: blob(0xfade0c02, bytes(88))}), b"info", b"resources")

    def test_metadata_hashes_and_anonymous_identifier_are_exact(self):
        data = carrier_fixture()
        for info, resource in ((b"changed", b"resources"), (b"info", b"changed")):
            with self.assertRaises(ValueError):
                packager.carrier_signature(data, info, resource)
        changed = data.replace(packager.CARRIER_IDENTIFIER, b"personal.iridium\0")
        with self.assertRaises(ValueError):
            packager.carrier_signature(bytes(changed), b"info", b"resources")

    def test_truncation_duplicate_and_overlapping_slots_are_rejected(self):
        data = carrier_fixture()
        for changed in (data[:4], data[:-1], data + b"extra"):
            with self.assertRaises(ValueError):
                packager.carrier_signature(bytes(changed), b"info", b"resources")
        for offset, value in ((4096 + 12 + 8, 0), (4096 + 16 + 8, 52)):
            changed = bytearray(data)
            struct.pack_into(">I", changed, offset, value)
            with self.assertRaises(ValueError):
                packager.carrier_signature(bytes(changed), b"info", b"resources")

    def test_all_universal_slices_are_checked(self):
        data = carrier_fixture()
        header = struct.pack(">II", 0xcafebabe, 2)
        header += struct.pack(">5I", 0x100000c, 0, 48, len(data), 0)
        header += struct.pack(">5I", 0x100000c, 1, 48 + len(data), len(data), 0)
        packager.carrier_signature(header + data + data, b"info", b"resources")
        invalid = carrier_fixture(cd_changes={48: 88})
        with self.assertRaises(ValueError):
            packager.carrier_signature(header + data + invalid, b"info", b"resources")
        with self.assertRaises(ValueError):
            packager.macho_slices(header[:28] + struct.pack(">5I", 0x100000c, 1, 48, len(data), 0) + data + data)

    def test_round_trip_rejects_changed_modes_and_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staged, delivered = root / "staged", root / "delivered"
            staged.mkdir(); delivered.mkdir()
            for directory in (staged, delivered):
                (directory / "file").write_bytes(b"fixture")
                (directory / "link").symlink_to("file")
            packager.check_archive_modes(staged, delivered)
            (delivered / "file").chmod(0o700)
            with self.assertRaises(ValueError):
                packager.check_archive_modes(staged, delivered)
            (delivered / "file").chmod(0o644)
            (delivered / "link").unlink(); (delivered / "link").symlink_to("missing")
            with self.assertRaises(ValueError):
                packager.check_archive_modes(staged, delivered)


@unittest.skipUnless(sys.platform == "darwin" and Path("/usr/bin/codesign").is_file()
                     and Path("/usr/bin/xcrun").is_file(), "Requires Apple's compiler and codesign")
class DarwinCarrierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Iridium.app"
        self.app.mkdir()
        self.write("Info.plist", plistlib.dumps({"CFBundleIdentifier": "software.iridium",
            "CFBundleExecutable": "Iridium", "CFBundlePackageType": "APPL"}))
        self.write("fonts/tahoma.ttf", b"font fixture")
        self.write("PlugIns/Helper.appex/Info.plist", plistlib.dumps({"CFBundleExecutable": "Helper"}))
        source = self.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        subprocess.run(["/usr/bin/xcrun", "clang", str(source), "-o", str(self.app / "Iridium")], check=True, capture_output=True)
        shutil.copy2(self.app / "Iridium", self.app / "PlugIns/Helper.appex/Helper")
        for path in (self.app / "Iridium", self.app / "PlugIns/Helper.appex/Helper"):
            if not packager.unsigned_status(path):
                subprocess.run(["/usr/bin/codesign", "--remove-signature", str(path)], check=True, capture_output=True)
        (self.app / "font-link").symlink_to("fonts/tahoma.ttf")

    def write(self, name, data):
        path = self.app / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_bundle_seal_exact_entitlement_and_unsigned_helper(self):
        packager.sign_entitlement_carrier(self.app)
        audit = packager.audit_package_signatures(self.app)
        self.assertEqual(audit["entitlementCarrier"]["entitlements"], packager.CARRIER_ENTITLEMENTS)
        self.assertEqual(audit["entitlementCarrier"]["cmsPayloadBytes"], 0)
        self.assertIsNone(audit["entitlementCarrier"]["teamIdentifier"])
        self.assertEqual(audit["unsignedNativeExecutableCount"], 1)

    def test_tampered_executable_and_resource_are_rejected_cryptographically(self):
        packager.sign_entitlement_carrier(self.app)
        self.write("fonts/tahoma.ttf", b"tampered resource")
        with self.assertRaises(subprocess.CalledProcessError):
            packager.audit_package_signatures(self.app)
        self.write("fonts/tahoma.ttf", b"font fixture")
        binary = self.app / "Iridium"
        changed = bytearray(binary.read_bytes()); changed[4096] ^= 1
        binary.write_bytes(changed)
        with self.assertRaises(subprocess.CalledProcessError):
            packager.audit_package_signatures(self.app)

    def test_unexpected_signed_helper_is_rejected_even_when_resources_are_resealed(self):
        standalone = self.root / "standalone-helper"
        shutil.copy2(self.app / "PlugIns/Helper.appex/Helper", standalone)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                        str(standalone)], check=True, capture_output=True)
        shutil.copy2(standalone, self.app / "PlugIns/Helper.appex/Helper")
        packager.sign_entitlement_carrier(self.app)
        with self.assertRaisesRegex(ValueError, "Only the main"):
            packager.audit_package_signatures(self.app)

    def test_package_round_trip_keeps_input_and_refreshes_then_seals_manifests(self):
        host = self.write("BundledRuntime/base/Runtime/runtime-host.bin", (self.app / "Iridium").read_bytes())
        manifest = self.write("BundledRuntime/base/manifest.json", json.dumps({"artifacts": [{
            "relativePath": "Runtime/runtime-host.bin", "checksum": "stale", "sizeBytes": 0}]}).encode())
        before = {p.relative_to(self.app): p.read_bytes() for p in self.app.rglob("*") if p.is_file()}
        with patch.object(packager, "check_asset_catalog"):
            packager.package(self.app, self.root / "output")
        self.assertEqual(before, {p.relative_to(self.app): p.read_bytes() for p in self.app.rglob("*") if p.is_file()})
        extracted = self.root / "delivered"
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(self.root / "output/Iridium-unsigned.ipa"), str(extracted)], check=True)
        delivered = extracted / "Payload/Iridium.app"
        audit = packager.audit_package_signatures(delivered)
        self.assertEqual(audit, json.loads((self.root / "output/ipa-signature-audit.json").read_text()))
        record = json.loads((delivered / manifest.relative_to(self.app)).read_text())["artifacts"][0]
        self.assertEqual(record["checksum"], packager.file_sha256(delivered / host.relative_to(self.app)))
        self.assertEqual(stat.S_IMODE((delivered / "Iridium").stat().st_mode), 0o755)
        self.assertTrue((delivered / "font-link").is_symlink())
        (delivered / host.relative_to(self.app)).write_bytes(b"changed")
        with self.assertRaises(ValueError):
            packager.refresh_runtime_manifest_artifacts(delivered, verify_only=True)


if __name__ == "__main__":
    unittest.main()
