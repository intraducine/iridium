import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

spec = importlib.util.spec_from_file_location(
    "unsigned_packager_dedup_tests", Path(__file__).with_name("package-unsigned-ipa.py"))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def write_zip(app, destination, preserve_links=True):
    """Portable ZIP fixture; the Darwin test separately exercises real ditto."""
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob("*")):
            if path.is_dir():
                continue
            name = "Payload/Iridium.app/" + path.relative_to(app).as_posix()
            if path.is_symlink() and preserve_links:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(info, os.readlink(path).encode("utf-8"))
            else:
                archive.write(path, name)


class WindowsRuntimeDedupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Iridium.app"
        for arch in ("aarch64", "arm64ec"):
            (self.app / f"{arch}-windows").mkdir(parents=True)
        self.pe = b"MZ" + bytes(range(256)) * 32

    def write(self, relative, data, mode=0o644):
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)
        return path

    def pair(self, name="shared.dll"):
        canonical = self.write("aarch64-windows/" + name, self.pe)
        alias = self.write("arm64ec-windows/" + name, self.pe)
        return canonical, alias

    def minimal_app(self):
        self.write("fonts/tahoma.ttf", b"font fixture")
        self.write("Info.plist", plistlib.dumps({
            "CFBundleIdentifier": "software.iridium", "CFBundleExecutable": "Iridium"}))
        self.write("Iridium", bytes.fromhex("cffaedfe") + b"host")
        self.write("PlugIns/Helper.appex/Info.plist", plistlib.dumps({"CFBundleExecutable": "Helper"}))
        self.write("PlugIns/Helper.appex/Helper", bytes.fromhex("cffaedfe") + b"helper")

    def test_identical_modules_keep_both_paths_and_original_bytes(self):
        canonical, alias = self.pair()
        links = packager.deduplicate_windows_runtime(self.app)
        self.assertEqual(list(links), ["arm64ec-windows/shared.dll"])
        self.assertFalse(canonical.is_symlink())
        self.assertTrue(alias.is_symlink())
        self.assertEqual(os.readlink(alias), "../aarch64-windows/shared.dll")
        self.assertEqual(alias.resolve(), canonical.resolve())
        self.assertEqual(alias.read_bytes(), self.pe)
        self.assertEqual(canonical.read_bytes(), self.pe)
        self.assertEqual(links["arm64ec-windows/shared.dll"]["sha256"], hashlib.sha256(self.pe).hexdigest())

    def test_distinct_architecture_modules_and_unique_modules_are_preserved(self):
        canonical, alias = self.pair("d3d11.dll")
        alias.write_bytes(self.pe[:-1] + b"X")  # same size, different bytes
        unique = self.write("arm64ec-windows/xtajit64.dll", self.pe)
        self.assertEqual(packager.deduplicate_windows_runtime(self.app), {})
        self.assertFalse(alias.is_symlink())
        self.assertEqual(canonical.read_bytes(), self.pe)
        self.assertEqual(alias.read_bytes(), self.pe[:-1] + b"X")
        self.assertEqual(unique.read_bytes(), self.pe)

    def test_only_same_named_pe_resources_with_matching_modes_are_shared(self):
        self.pair("native.dylib")
        for arch in ("aarch64", "arm64ec"):
            self.write(f"{arch}-windows/not-pe.dll", b"not a PE image")
            self.write(f"{arch}-windows/empty.dll", b"")
            self.write(f"{arch}-windows/macho.dll", bytes.fromhex("cffaedfe") + b"native")
        _, executable = self.pair("mode.dll")
        executable.chmod(0o755)
        self.write("aarch64-windows/one.dll", self.pe)
        self.write("arm64ec-windows/two.dll", self.pe)
        self.assertEqual(packager.deduplicate_windows_runtime(self.app), {})
        self.assertFalse(any(p.is_symlink() for p in self.app.rglob("*")))

    def test_large_comparison_checks_the_last_chunk(self):
        data = b"MZ" + b"a" * (2 * 1024 * 1024)
        left = self.write("aarch64-windows/large.dll", data)
        right = self.write("arm64ec-windows/large.dll", data[:-1] + b"b")
        self.assertFalse(packager.identical_files(left, right))
        self.assertEqual(packager.deduplicate_windows_runtime(self.app), {})

    def test_links_are_idempotent_and_survive_bundle_relocation(self):
        self.pair("module with spaces.dll")
        first = packager.deduplicate_windows_runtime(self.app)
        self.assertEqual(packager.deduplicate_windows_runtime(self.app), first)
        moved = self.root / "another path" / "Iridium.app"
        shutil.copytree(self.app, moved, symlinks=True)
        alias = moved / "arm64ec-windows/module with spaces.dll"
        self.assertEqual(alias.read_bytes(), self.pe)
        self.assertTrue(alias.resolve().is_relative_to(moved))

    def test_missing_directory_pair_is_rejected_but_legacy_only_app_is_allowed(self):
        (self.app / "arm64ec-windows").rmdir()
        with self.assertRaises(ValueError):
            packager.deduplicate_windows_runtime(self.app)
        (self.app / "aarch64-windows").rmdir()
        self.assertEqual(packager.deduplicate_windows_runtime(self.app), {})

    def test_symlinked_runtime_directory_is_rejected(self):
        directory = self.app / "aarch64-windows"
        directory.rmdir()
        outside = self.root / "outside"
        outside.mkdir()
        directory.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            packager.deduplicate_windows_runtime(self.app)

    def test_dangling_directory_links_are_not_treated_as_absent(self):
        for path in self.app.iterdir():
            path.rmdir()
        (self.app / "aarch64-windows").symlink_to("missing", target_is_directory=True)
        with self.assertRaises(ValueError):
            packager.deduplicate_windows_runtime(self.app)

    def test_unexpected_and_dangling_module_links_are_rejected_before_mutation(self):
        canonical, alias = self.pair("z.dll")
        _, untouched = self.pair("a.dll")
        alias.unlink()
        alias.symlink_to("../../outside.dll")
        with self.assertRaises(ValueError):
            packager.deduplicate_windows_runtime(self.app)
        self.assertFalse(untouched.is_symlink())
        alias.unlink()
        alias.symlink_to("../aarch64-windows/z.dll")
        canonical.unlink()
        with self.assertRaises(ValueError):
            packager.deduplicate_windows_runtime(self.app)

    def test_canonical_module_link_is_rejected(self):
        canonical, _ = self.pair()
        canonical.unlink()
        canonical.symlink_to("../arm64ec-windows/shared.dll")
        with self.assertRaises(ValueError):
            packager.deduplicate_windows_runtime(self.app)

    def test_archive_preserves_links_and_canonical_bytes(self):
        self.pair()
        links = packager.deduplicate_windows_runtime(self.app)
        ipa = self.root / "test.ipa"
        write_zip(self.app, ipa)
        packager.check_windows_runtime_archive(ipa, links)

    def test_archive_that_expands_links_is_rejected(self):
        self.pair()
        links = packager.deduplicate_windows_runtime(self.app)
        ipa = self.root / "test.ipa"
        write_zip(self.app, ipa, preserve_links=False)
        with self.assertRaisesRegex(ValueError, "did not preserve"):
            packager.check_windows_runtime_archive(ipa, links)

    def test_archive_with_changed_canonical_bytes_is_rejected(self):
        canonical, _ = self.pair()
        links = packager.deduplicate_windows_runtime(self.app)
        canonical.write_bytes(self.pe[:-1] + b"X")
        ipa = self.root / "test.ipa"
        write_zip(self.app, ipa)
        with self.assertRaisesRegex(ValueError, "changed canonical"):
            packager.check_windows_runtime_archive(ipa, links)

    def test_archive_with_wrong_link_is_rejected(self):
        _, alias = self.pair()
        links = packager.deduplicate_windows_runtime(self.app)
        alias.unlink()
        alias.symlink_to("../aarch64-windows/wrong.dll")
        ipa = self.root / "test.ipa"
        write_zip(self.app, ipa)
        with self.assertRaisesRegex(ValueError, "incorrect Windows runtime symlink"):
            packager.check_windows_runtime_archive(ipa, links)

    def test_missing_canonical_archive_entry_is_rejected(self):
        canonical, _ = self.pair()
        links = packager.deduplicate_windows_runtime(self.app)
        canonical.unlink()
        ipa = self.root / "test.ipa"
        write_zip(self.app, ipa)
        with self.assertRaisesRegex(ValueError, "missing a Windows runtime"):
            packager.check_windows_runtime_archive(ipa, links)

    def test_duplicate_archive_entries_are_rejected(self):
        self.pair()
        links = packager.deduplicate_windows_runtime(self.app)
        ipa = self.root / "test.ipa"
        write_zip(self.app, ipa)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(ipa, "a") as archive:
                archive.writestr("Payload/Iridium.app/aarch64-windows/shared.dll", self.pe)
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            packager.check_windows_runtime_archive(ipa, links)

    def package_with_fixture_writer(self, preserve_links=True):
        def run(command, **kwargs):
            self.assertEqual(command[0], "/usr/bin/ditto")
            payload, destination = map(Path, command[-2:])
            write_zip(payload / "Iridium.app", destination, preserve_links)
            return subprocess.CompletedProcess(command, 0)
        with mock.patch.object(packager, "unsigned_status", return_value=True), \
             mock.patch.object(packager, "check_asset_catalog"), \
             mock.patch.object(packager.subprocess, "run", side_effect=run):
            packager.package(self.app, self.root / "output")

    def test_package_changes_only_temporary_copy_and_publishes_after_audit(self):
        self.minimal_app()
        canonical, alias = self.pair()
        self.package_with_fixture_writer()
        self.assertFalse(alias.is_symlink())
        self.assertEqual(alias.read_bytes(), self.pe)
        self.assertEqual(canonical.read_bytes(), self.pe)
        ipa = self.root / "output/Iridium-unsigned.ipa"
        self.assertTrue(ipa.is_file())
        checksum = (self.root / "output/SHA256SUMS").read_text().split()[0]
        self.assertEqual(checksum, hashlib.sha256(ipa.read_bytes()).hexdigest())
        with zipfile.ZipFile(ipa) as archive:
            alias_info = archive.getinfo("Payload/Iridium.app/arm64ec-windows/shared.dll")
            self.assertTrue(stat.S_ISLNK(alias_info.external_attr >> 16))

    def test_failed_archive_audit_leaves_no_publishable_ipa_or_checksum(self):
        self.minimal_app()
        _, alias = self.pair()
        with self.assertRaisesRegex(ValueError, "did not preserve"):
            self.package_with_fixture_writer(preserve_links=False)
        self.assertFalse((self.root / "output/Iridium-unsigned.ipa").exists())
        self.assertFalse((self.root / "output/SHA256SUMS").exists())
        self.assertFalse(alias.is_symlink())
        self.assertEqual(list((self.root / "output").iterdir()), [])

    @unittest.skipUnless(sys.platform == "darwin" and Path("/usr/bin/ditto").is_file(),
                         "Requires Apple's ZIP writer and extractor")
    def test_ditto_round_trip(self):
        self.pair()
        payload = self.root / "Payload"
        payload.mkdir()
        app = payload / "Iridium.app"
        shutil.copytree(self.app, app)
        links = packager.deduplicate_windows_runtime(app)
        ipa = self.root / "ditto.ipa"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc",
                        "--noextattr", "--noqtn", str(payload), str(ipa)], check=True)
        packager.check_windows_runtime_archive(ipa, links)
        extracted = self.root / "extracted"
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(ipa), str(extracted)], check=True)
        alias = extracted / "Payload/Iridium.app/arm64ec-windows/shared.dll"
        self.assertTrue(alias.is_symlink())
        self.assertEqual(alias.read_bytes(), self.pe)


if __name__ == "__main__":
    unittest.main()
