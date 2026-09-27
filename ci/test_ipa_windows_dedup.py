"""Packaging-only deduplication: preserve names, bytes, and legacy provisioning."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

spec = importlib.util.spec_from_file_location(
    'windows_dedup_packager', Path(__file__).with_name('package-unsigned-ipa.py'))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def fixture_zip(app, destination, dereference=False, override=None):
    """Emulate a symlink-preserving ZIP writer, not Apple's signing tools."""
    with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob('*')):
            if path.is_dir():
                continue
            name = 'Payload/Iridium.app/' + path.relative_to(app).as_posix()
            link = path.is_symlink() and not dereference
            entry = zipfile.ZipInfo(name)
            entry.create_system = 3
            entry.external_attr = (path.lstat().st_mode if link else path.stat().st_mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            data = os.readlink(path).encode() if link else path.read_bytes()
            if override:
                entry, data = override(entry, data)
            archive.writestr(entry, data)


class WindowsResourceDedupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Iridium.app'
        self.aarch64 = self.app / 'aarch64-windows'
        self.arm64ec = self.app / 'arm64ec-windows'
        self.aarch64.mkdir(parents=True)
        self.arm64ec.mkdir()
        self.data = b'MZ' + bytes(range(256)) * 1024
        self.ipa = self.root / 'test.ipa'

    def pair(self, name='shared.dll', data=None):
        data = self.data if data is None else data
        paths = self.aarch64 / name, self.arm64ec / name
        for path in paths:
            path.write_bytes(data)
            path.chmod(0o755)
        return paths

    def test_identical_resources_keep_both_paths_and_bytes(self):
        alias, canonical = self.pair()
        records = packager.deduplicate_windows_resources(self.app)
        self.assertEqual(len(records), 1)
        self.assertTrue(alias.is_symlink())
        self.assertFalse(canonical.is_symlink())
        self.assertEqual(os.readlink(alias), '../arm64ec-windows/shared.dll')
        self.assertEqual(alias.read_bytes(), self.data)
        self.assertEqual(canonical.read_bytes(), self.data)
        self.assertEqual(records[0]['sha256'], hashlib.sha256(self.data).hexdigest())
        self.assertEqual(records[0]['sizeBytes'], len(self.data))

    def test_same_size_different_bytes_are_not_deduplicated(self):
        alias, _ = self.pair()
        alias.write_bytes(self.data[:-1] + b'!')
        self.assertEqual(packager.deduplicate_windows_resources(self.app), [])
        self.assertFalse(alias.is_symlink())

    def test_different_sizes_and_permissions_are_preserved(self):
        alias, _ = self.pair('size.dll')
        alias.write_bytes(b'MZdifferent')
        alias, _ = self.pair('mode.dll')
        alias.chmod(0o644)
        self.assertEqual(packager.deduplicate_windows_resources(self.app), [])

    def test_native_disguised_as_dll_and_non_resources_stay_regular(self):
        self.pair(data=bytes.fromhex('cffaedfe') + b'native executable')
        self.pair('Info.plist')
        self.pair('library.a')
        self.pair('empty.dll', b'')
        self.assertEqual(packager.deduplicate_windows_resources(self.app), [])

    def test_typelibs_are_included_without_changing_contents(self):
        alias, _ = self.pair('shared.tlb', b'type library data')
        self.assertEqual(len(packager.deduplicate_windows_resources(self.app)), 1)
        self.assertEqual(alias.read_bytes(), b'type library data')

    def test_architecture_specific_names_and_overrides_stay_regular(self):
        (self.arm64ec / 'xtajit64.dll').write_bytes(self.data)
        alias, canonical = self.pair('xinput1_4.dll')
        canonical.write_bytes(b'MZcontroller bridge')
        self.assertEqual(packager.deduplicate_windows_resources(self.app), [])
        self.assertFalse(alias.is_symlink())
        self.assertEqual(canonical.read_bytes(), b'MZcontroller bridge')

    def test_existing_links_are_not_retargeted_or_used_as_canonical(self):
        alias, canonical = self.pair()
        canonical.unlink()
        canonical.symlink_to('../aarch64-windows/shared.dll')
        self.assertEqual(packager.deduplicate_windows_resources(self.app), [])
        self.assertFalse(alias.is_symlink())
        self.assertEqual(canonical.read_bytes(), self.data)

    def test_symlinked_resource_directory_is_rejected(self):
        self.aarch64.rmdir()
        outside = self.root / 'outside'
        outside.mkdir()
        self.aarch64.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'directory must not be a symlink'):
            packager.deduplicate_windows_resources(self.app)

    def test_missing_resource_directory_is_a_noop(self):
        self.aarch64.rmdir()
        self.assertEqual(packager.deduplicate_windows_resources(self.app), [])

    def test_second_pass_is_idempotent(self):
        alias, _ = self.pair()
        packager.deduplicate_windows_resources(self.app)
        link = os.readlink(alias)
        self.assertEqual(packager.deduplicate_windows_resources(self.app), [])
        self.assertEqual(os.readlink(alias), link)

    def test_failed_atomic_replace_keeps_original_and_cleans_temporary(self):
        alias, _ = self.pair()
        with mock.patch.object(packager.os, 'replace', side_effect=OSError('fixture failure')):
            with self.assertRaises(OSError):
                packager.deduplicate_windows_resources(self.app)
        self.assertFalse(alias.is_symlink())
        self.assertEqual(alias.read_bytes(), self.data)
        self.assertFalse(list(self.aarch64.glob('.iridium-dedup-*')))

    def test_archive_round_trip_and_prefix_farms(self):
        self.pair()
        records = packager.deduplicate_windows_resources(self.app)
        fixture_zip(self.app, self.ipa)
        report = packager.verify_windows_resource_archive(self.ipa, records)
        self.assertEqual(report['deduplicatedWindowsFiles'], 1)
        self.assertEqual(report['duplicateUncompressedBytesRemoved'], len(self.data))
        # Relocate the application (as installation does), then create the same
        # absolute prefix links as WineProcessBridge's system32/sysaa64/sysx64 farms.
        installed = self.root / 'relocated.app'
        self.app.rename(installed)
        prefix = self.root / 'prefix/drive_c/windows'
        for farm, arch in [('system32', 'arm64ec-windows'),
                           ('sysaa64', 'aarch64-windows'), ('sysx64', 'arm64ec-windows')]:
            directory = prefix / farm
            directory.mkdir(parents=True)
            for source in (installed / arch).iterdir():
                (directory / source.name).symlink_to(source)
            self.assertEqual((directory / 'shared.dll').read_bytes(), self.data)

    def test_archive_rejects_dereferenced_links(self):
        self.pair()
        records = packager.deduplicate_windows_resources(self.app)
        fixture_zip(self.app, self.ipa, dereference=True)
        with self.assertRaisesRegex(ValueError, 'did not preserve'):
            packager.verify_windows_resource_archive(self.ipa, records)

    def test_archive_rejects_changed_symlink_target(self):
        self.pair()
        records = packager.deduplicate_windows_resources(self.app)
        def override(entry, data):
            return entry, b'../../outside.dll' if stat.S_ISLNK(entry.external_attr >> 16) else data
        fixture_zip(self.app, self.ipa, override=override)
        with self.assertRaisesRegex(ValueError, 'symlink target'):
            packager.verify_windows_resource_archive(self.ipa, records)

    def test_archive_rejects_changed_canonical_bytes(self):
        self.pair()
        records = packager.deduplicate_windows_resources(self.app)
        def override(entry, data):
            return entry, data[:-1] + b'!' if '/arm64ec-windows/' in entry.filename else data
        fixture_zip(self.app, self.ipa, override=override)
        with self.assertRaisesRegex(ValueError, 'checksum'):
            packager.verify_windows_resource_archive(self.ipa, records)

    def test_archive_rejects_duplicate_zip_names(self):
        self.pair()
        records = packager.deduplicate_windows_resources(self.app)
        fixture_zip(self.app, self.ipa)
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(self.ipa, 'a') as archive:
                archive.writestr('Payload/Iridium.app/aarch64-windows/shared.dll', b'bad')
        with self.assertRaisesRegex(ValueError, 'duplicate ZIP entry'):
            packager.verify_windows_resource_archive(self.ipa, records)

    def prepare_app(self):
        self.pair()
        info = {'CFBundleIdentifier': 'software.iridium', 'CFBundleExecutable': 'Iridium'}
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(info))
        (self.app / 'Iridium').write_bytes(bytes.fromhex('cffaedfe') + b'app')
        helper = self.app / 'PlugIns/Helper.appex'
        helper.mkdir(parents=True)
        (helper / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Helper'}))
        (helper / 'Helper').write_bytes(bytes.fromhex('cffaedfe') + b'helper')
        legacy = self.app / 'IridiumWineUserland/bin/wine'
        legacy.parent.mkdir(parents=True)
        legacy.write_bytes(b'legacy userland fixture')

    def run_package(self, dereference=False):
        self.prepare_app()
        output = self.root / 'output'
        def run(command, **kwargs):
            self.assertEqual(command[0], '/usr/bin/ditto')
            fixture_zip(Path(command[-2]) / 'Iridium.app', Path(command[-1]), dereference=dereference)
        # This exercises real orchestration and ZIP checks, with macOS-only
        # signing/asset tooling mocked. It does not claim an Xcode/device test.
        with mock.patch.object(packager, 'check_payload'), \
             mock.patch.object(packager, 'check_asset_catalog'), \
             mock.patch.object(packager, 'unsigned_status', return_value=True), \
             mock.patch.object(packager.subprocess, 'run', side_effect=run), \
             mock.patch('sys.stdout', new_callable=io.StringIO):
            packager.package(self.app, output)
        return output

    def test_packaging_changes_only_copy_and_retains_legacy_runtime(self):
        output = self.run_package()
        self.assertFalse((self.aarch64 / 'shared.dll').is_symlink())
        self.assertEqual((self.aarch64 / 'shared.dll').read_bytes(), self.data)
        with zipfile.ZipFile(output / 'Iridium-unsigned.ipa') as archive:
            self.assertEqual(archive.read('Payload/Iridium.app/IridiumWineUserland/bin/wine'),
                             b'legacy userland fixture')
        report = json.loads((output / 'ipa-size-report.json').read_text())
        self.assertEqual(report['deduplicatedWindowsFiles'], 1)
        self.assertTrue((output / 'SHA256SUMS').is_file())

    def test_packaging_does_not_publish_failed_archive(self):
        with self.assertRaisesRegex(ValueError, 'did not preserve'):
            self.run_package(dereference=True)
        self.assertFalse((self.root / 'output/Iridium-unsigned.ipa').exists())
        self.assertFalse((self.root / 'output/SHA256SUMS').exists())
        self.assertFalse((self.aarch64 / 'shared.dll').is_symlink())


if __name__ == '__main__':
    unittest.main()
