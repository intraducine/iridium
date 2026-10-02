"""Regression coverage for the packaging improvements consolidated into PR #46."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import unittest
from unittest import mock
import warnings
import zipfile

spec = importlib.util.spec_from_file_location(
    "dedup_fixtures", Path(__file__).with_name("test_windows_runtime_dedup.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
packager = fixtures.packager


class ConsolidatedPackagingTests(unittest.TestCase):
    def setUp(self):
        # Reuse the existing filesystem/ZIP fixtures without duplicating their tests.
        self.fixture = fixtures.WindowsRuntimeDedupTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        self.app = self.fixture.app
        self.pe = self.fixture.pe
        self.output = self.root / "output"

    def test_original_survives_until_atomic_rename(self):
        canonical, alias = self.fixture.pair()
        replace = os.replace

        def checked_replace(temporary, destination):
            self.assertEqual(destination, alias)
            self.assertFalse(alias.is_symlink())
            self.assertEqual(alias.read_bytes(), self.pe)
            self.assertEqual(temporary.parent, alias.parent)
            self.assertEqual(os.readlink(temporary), "../aarch64-windows/shared.dll")
            replace(temporary, destination)

        with mock.patch.object(packager.os, "replace", side_effect=checked_replace) as operation:
            packager.deduplicate_windows_runtime(self.app)
        operation.assert_called_once()
        self.assertEqual(alias.read_bytes(), canonical.read_bytes())
        self.assertFalse(list(alias.parent.glob(".iridium-dedup-*")))

    def test_failed_rename_preserves_original_and_cleans_temporary(self):
        canonical, alias = self.fixture.pair()
        with mock.patch.object(packager.os, "replace", side_effect=OSError("fixture failure")):
            with self.assertRaises(OSError):
                packager.deduplicate_windows_runtime(self.app)
        self.assertFalse(alias.is_symlink())
        self.assertEqual(alias.read_bytes(), self.pe)
        self.assertEqual(canonical.read_bytes(), self.pe)
        self.assertFalse(list(alias.parent.glob(".iridium-dedup-*")))

    def test_failed_link_creation_preserves_original_and_cleans_temporary(self):
        canonical, alias = self.fixture.pair()
        with mock.patch.object(Path, "symlink_to", side_effect=OSError("fixture failure")):
            with self.assertRaises(OSError):
                packager.deduplicate_windows_runtime(self.app)
        self.assertFalse(alias.is_symlink())
        self.assertEqual(alias.read_bytes(), self.pe)
        self.assertEqual(canonical.read_bytes(), self.pe)
        self.assertFalse(list(alias.parent.glob(".iridium-dedup-*")))

    def test_report_matches_archive_and_retains_legacy_payload(self):
        self.fixture.pair()
        legacy = self.fixture.write("IridiumWineUserland/lib/fixture.so", b"legacy payload" * 100)
        links = packager.deduplicate_windows_runtime(self.app)
        ipa = self.root / "test.ipa"
        fixtures.write_zip(self.app, ipa)
        report = packager.check_windows_runtime_archive(ipa, links)
        self.assertEqual(report["ipaBytes"], ipa.stat().st_size)
        self.assertEqual(report["deduplicatedWindowsFiles"], 1)
        self.assertEqual(report["duplicateUncompressedBytesAvoided"], len(self.pe))
        self.assertEqual(report["windowsResourceAliases"], links)
        with zipfile.ZipFile(ipa) as archive:
            expected = {}
            for entry in archive.infolist():
                component = entry.filename.removeprefix("Payload/Iridium.app/").split("/", 1)[0]
                expected[component] = expected.get(component, 0) + entry.compress_size
            self.assertEqual(report["compressedBytesByComponent"], expected)
            self.assertEqual(archive.read("Payload/Iridium.app/IridiumWineUserland/lib/fixture.so"),
                             legacy.read_bytes())

    def test_repeat_pass_reports_and_verifies_existing_aliases(self):
        canonical, _ = self.fixture.pair()
        first = packager.deduplicate_windows_runtime(self.app)
        links = packager.deduplicate_windows_runtime(self.app)
        self.assertEqual(links, first)
        ipa = self.root / "test.ipa"
        fixtures.write_zip(self.app, ipa)
        self.assertEqual(packager.check_windows_runtime_archive(ipa, links)["deduplicatedWindowsFiles"], 1)
        canonical.write_bytes(self.pe[:-1] + b"X")
        fixtures.write_zip(self.app, ipa)
        with self.assertRaisesRegex(ValueError, "changed canonical"):
            packager.check_windows_runtime_archive(ipa, links)

    def test_zero_alias_report_still_rejects_duplicate_archive_names(self):
        self.fixture.write("aarch64-windows/unique.dll", self.pe)
        links = packager.deduplicate_windows_runtime(self.app)
        self.assertEqual(links, {})
        ipa = self.root / "test.ipa"
        fixtures.write_zip(self.app, ipa)
        report = packager.check_windows_runtime_archive(ipa, links)
        self.assertEqual(report["deduplicatedWindowsFiles"], 0)
        self.assertEqual(report["duplicateUncompressedBytesAvoided"], 0)
        self.assertGreater(report["compressedBytesByComponent"]["aarch64-windows"], 0)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(ipa, "a") as archive:
                archive.writestr("Payload/Iridium.app/aarch64-windows/unique.dll", self.pe)
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            packager.check_windows_runtime_archive(ipa, links)

    def test_canonical_archive_entry_must_be_regular(self):
        _, alias = self.fixture.pair()
        links = packager.deduplicate_windows_runtime(self.app)
        ipa = self.root / "test.ipa"
        prefix = "Payload/Iridium.app/"
        with zipfile.ZipFile(ipa, "w") as archive:
            link = zipfile.ZipInfo(prefix + "arm64ec-windows/shared.dll")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, os.readlink(alias))
            target = zipfile.ZipInfo(prefix + "aarch64-windows/shared.dll")
            target.create_system = 3
            target.external_attr = (stat.S_IFDIR | 0o755) << 16
            archive.writestr(target, self.pe)
        with self.assertRaisesRegex(ValueError, "invalid canonical"):
            packager.check_windows_runtime_archive(ipa, links)

    def test_package_writes_report_before_final_ipa_and_leaves_source_untouched(self):
        self.fixture.minimal_app()
        _, alias = self.fixture.pair()
        replace = Path.replace
        published = []

        def checked_replace(path, destination):
            destination = Path(destination)
            if destination.parent == self.output:
                if destination.name == "Iridium-unsigned.ipa":
                    self.assertTrue((self.output / "ipa-size-report.json").is_file())
                    self.assertTrue((self.output / "SHA256SUMS").is_file())
                published.append(destination.name)
            return replace(path, destination)

        with mock.patch.object(Path, "replace", checked_replace):
            self.fixture.package_with_fixture_writer()
        self.assertEqual(published, ["ipa-size-report.json", "SHA256SUMS", "Iridium-unsigned.ipa"])
        ipa = self.output / "Iridium-unsigned.ipa"
        report = json.loads((self.output / "ipa-size-report.json").read_text())
        self.assertEqual(report["ipaBytes"], ipa.stat().st_size)
        self.assertEqual(report["deduplicatedWindowsFiles"], 1)
        self.assertEqual((self.output / "SHA256SUMS").read_text().split()[0],
                         hashlib.sha256(ipa.read_bytes()).hexdigest())
        self.assertFalse(alias.is_symlink())
        self.assertEqual(alias.read_bytes(), self.pe)

    def test_failed_writer_leaves_no_final_outputs(self):
        self.fixture.minimal_app()
        self.fixture.pair()

        def failed_writer(command, **kwargs):
            Path(command[-1]).write_bytes(b"partial ZIP")
            raise subprocess.CalledProcessError(1, command)

        with mock.patch.object(packager, "unsigned_status", return_value=True), \
             mock.patch.object(packager, "check_asset_catalog"), \
             mock.patch.object(packager.subprocess, "run", side_effect=failed_writer):
            with self.assertRaises(subprocess.CalledProcessError):
                packager.package(self.app, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_failed_report_write_leaves_no_final_outputs(self):
        self.fixture.minimal_app()
        self.fixture.pair()
        write_text = Path.write_text

        def failed_report(path, *args, **kwargs):
            if path.name == "ipa-size-report.json":
                raise OSError("fixture report failure")
            return write_text(path, *args, **kwargs)

        with mock.patch.object(Path, "write_text", failed_report):
            with self.assertRaises(OSError):
                self.fixture.package_with_fixture_writer()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_failed_output_rename_cleans_already_published_sidecars(self):
        self.fixture.minimal_app()
        self.fixture.pair()
        replace = Path.replace
        for name in ("ipa-size-report.json", "SHA256SUMS", "Iridium-unsigned.ipa"):
            with self.subTest(output=name):
                def failed_replace(path, destination):
                    if Path(destination) == self.output / name:
                        raise OSError("fixture output failure")
                    return replace(path, destination)

                with mock.patch.object(Path, "replace", failed_replace):
                    with self.assertRaises(OSError):
                        self.fixture.package_with_fixture_writer()
                self.assertEqual(list(self.output.iterdir()), [])

    def test_existing_sidecars_and_pe_exclusions_are_preserved(self):
        self.fixture.minimal_app()
        self.fixture.pair("shared.tlb")
        for arch in ("aarch64", "arm64ec"):
            self.fixture.write(f"{arch}-windows/not-pe.dll", b"not PE")
        self.assertEqual(packager.deduplicate_windows_runtime(self.app), {})
        self.output.mkdir()
        for name in ("ipa-size-report.json", "SHA256SUMS"):
            with self.subTest(output=name):
                sidecar = self.output / name
                sidecar.write_text("existing output")
                with self.assertRaisesRegex(ValueError, "already exists"):
                    self.fixture.package_with_fixture_writer()
                self.assertEqual(sidecar.read_text(), "existing output")
                self.assertEqual(list(self.output.iterdir()), [sidecar])
                sidecar.unlink()


if __name__ == "__main__":
    unittest.main()
