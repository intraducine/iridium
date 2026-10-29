# SPDX-License-Identifier: AGPL-3.0-only
"""Run the shipping inbox, recovery, migration and archive code with synthetic files."""
import ctypes
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile

from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'


@unittest.skipUnless(shutil.which('swiftc') and shutil.which('clang'), 'Apple host compilers required')
class ImportFolderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='iridium-inbox-check-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        bridge = IOS / 'RuntimeBridge/IRArchive.c'
        obj = cls.root / 'archive.o'
        subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', '-c', str(bridge), '-o', str(obj)], check=True, timeout=30)
        cls.binary = cls.root / 'check'
        sources = [IOS / 'RuntimeSupport/IridiumRuntime.swift', IOS / 'RuntimeSupport/IridiumGameStorage.swift']
        sources += [IOS / ('MadeiraFrontend/' + name + '.swift') for name in
                    ['IridiumFilesImport', 'IridiumFilesAccess', 'IridiumImportFiles', 'IridiumImportCoordinator']]
        service = (IOS / 'App/Adapters/Madeira/IridiumWindowsLibraryService.swift').read_text()
        admission = service[service.index('    static let programExtensions:'):service.index('    static func inspect(')]
        fixture = cls.root / 'ImportFolderChecks.swift'
        fixture.write_text((IOS / 'LibrarySupportTests/ImportFolderChecks.swift').read_text().replace('// PRODUCTION_EXECUTABLE', admission))
        sources += [IOS / 'App/Steam/SteamKeyValues.swift', IOS / 'App/Steam/SteamInstall.swift', fixture]
        cls.sources = sources
        build = subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors',
            '-D', 'IRIDIUM_PPSSPP', '-D', 'IRIDIUM_PHASE3',
            '-module-cache-path', module_cache('macosx'), '-import-objc-header', str(IOS / 'RuntimeBridge/IRArchive.h'),
            *map(str, sources), str(obj), '-larchive', '-o', str(cls.binary)], capture_output=True, text=True, timeout=120)
        if build.returncode:
            raise AssertionError(build.stdout + build.stderr)
        cls.library = cls.root / 'archive.dylib'
        subprocess.run(['clang', '-dynamiclib', str(bridge), '-larchive', '-o', str(cls.library)], check=True, timeout=30)
        cls.extract = ctypes.CDLL(str(cls.library)).ir_archive_extract
        cls.callback = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
        cls.extract.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint64, ctypes.c_uint, cls.callback, ctypes.c_void_p]
        cls.extract.restype = ctypes.c_int

    def check(self, scenario):
        with tempfile.TemporaryDirectory(prefix='iridium-inbox-fixture-') as directory:
            docs = Path(directory) / 'Documents'
            if scenario in ('archive', '7z', 'arcade', 'archive-restart'):
                source = Path(directory) / 'source'
                source.mkdir()
                if scenario == 'arcade':
                    (source / 'arcade.bin').write_bytes(b'fixture rom chip')
                else:
                    # Same valid header as the Swift fixture, obtained from its production import input.
                    seed = Path(directory) / 'seed'
                    seed.mkdir()
                    subprocess.run([str(self.binary), 'idle', str(seed)], check=True, capture_output=True, timeout=30)
                    data = next((seed / 'Games').glob('*/*.gb')).read_bytes()
                    (source / 'One.gb').write_bytes(data)
                    (source / 'Two.gb').write_bytes(data)
                    if scenario != 'archive-restart':
                        (source / 'readme.txt').write_text('keep this file')
                inbox = docs / 'Import'
                inbox.mkdir(parents=True)
                if scenario == '7z':
                    subprocess.run(['/usr/bin/tar', '--format=7zip', '-cf', str(inbox / 'games.7z'), '-C', str(source), '.'], check=True, timeout=30)
                else:
                    with zipfile.ZipFile(inbox / 'games.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
                        for file in source.iterdir():
                            archive.write(file, file.name)
            result = subprocess.run([str(self.binary), 'archive' if scenario == '7z' else scenario, str(docs)],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if scenario in ('archive', '7z'):
                self.assertFalse(list((docs / 'Import').glob('*.zip')) + list((docs / 'Import').glob('*.7z')))

    def test_interrupted_console_copy_is_rebuilt_before_publication(self): self.check('console-stage')
    def test_future_and_changed_import_records_are_preserved(self): self.check('records')
    def test_windows_launch_paths_stay_inside_owned_storage(self): self.check('windows-paths')
    def test_loose_windows_executable_moves_without_claiming_drive(self): self.check('loose')
    def test_container_move_keeps_windows_paths(self): self.check('relocation')
    def test_named_folders_keep_saves_and_windows_paths_after_interrupted_rename(self): self.check('named-folders')
    def test_completed_imports_remove_only_empty_owned_folders(self): self.check('empty-folders')
    def test_restart_after_last_archive_payload_does_not_duplicate_games(self): self.check('archive-restart')
    def test_large_batch_background_resume_and_retry_preserve_games_and_saves(self): self.check('batch-resume')
    def test_inbox_selection_and_links_cannot_escape_or_recurse(self): self.check('receive-safety')
    def test_pairing_choice_survives_restart(self): self.check('pairing-restart')
    def test_picker_receives_all_inputs_even_during_scan(self): self.check('picker')
    def test_existing_and_shared_installs_move_and_recover(self): self.check('migration')
    def test_installed_3ds_content_and_shared_saves_survive_named_rom_migration(self): self.check('installed-content')
    def test_migration_conflict_preserves_both_sides(self): self.check('conflict')
    def test_receipts_survive_restart_and_changed_inputs_are_kept(self): self.check('receipt')
    def test_windows_copy_is_reused_after_interrupted_registration(self): self.check('windows-retry')
    def test_mixed_bulk_folder_imports_each_game(self): self.check('bulk')
    def test_zip_extracts_and_consumes_only_registered_games(self): self.check('archive')
    def test_7z_extracts_and_imports_games(self): self.check('7z')
    def test_arcade_zip_remains_intact_and_needs_choice(self): self.check('arcade')
    def test_pairing_choice_does_not_replace_twice(self): self.check('pairing')
    def test_failed_library_save_keeps_input_for_retry(self): self.check('registration')
    def test_gameplay_blocks_migration_and_import(self): self.check('idle')
    def test_cloud_transfers_and_migration_share_file_ownership(self): self.check('cloud')

    def test_import_views_typecheck_for_ios(self):
        with tempfile.TemporaryDirectory() as directory:
            extra = Path(directory) / 'UIEndpoints.swift'
            extra.write_text("""import SwiftUI
import Combine
@MainActor final class LibraryController {
    static let shared = LibraryController()
    let commands = PassthroughSubject<String, Never>()
}
extension View {
    func iridiumRowSurface() -> some View { self }
    func iridiumPageSurface() -> some View { self }
}
""")
            sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
            result = subprocess.run(['swiftc', '-typecheck', '-swift-version', '6', '-warnings-as-errors',
                '-sdk', sdk, '-target', 'arm64-apple-ios17.0', '-D', 'IRIDIUM_PPSSPP', '-D', 'IRIDIUM_PHASE3',
                '-module-cache-path', module_cache('iphoneos'), '-import-objc-header', str(IOS / 'RuntimeBridge/IRArchive.h'),
                *map(str, self.sources), str(extra), str(IOS / 'MadeiraFrontend/IridiumImportFolderView.swift'),
                str(IOS / 'MadeiraFrontend/IridiumAddGameView.swift'),
                str(IOS / 'MadeiraFrontend/IridiumFilesImportView.swift')], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_archive_traversal_links_duplicates_limits_and_cancellation(self):
        cases = [('parent', '../escape', b'bad', 1), ('absolute', '/escape', b'bad', 1),
                 ('backslash', 'a\\escape', b'bad', 0), ('backslash-parent', '..\\escape', b'bad', 1), ('drive', 'C:/escape', b'bad', 1),
                 ('big', 'file', b'x' * 32, 2), ('cancel', 'file', b'ok', 3),
                 ('link', 'file', b'../../escape', 1), ('good', 'nested/file', b'ok', 0)]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for case, name, data, expected in cases:
                source = root / (case + '.zip')
                with zipfile.ZipFile(source, 'w') as archive:
                    info = zipfile.ZipInfo(name)
                    if case == 'link': info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(info, data)
                output = root / case
                output.mkdir()
                cancel = self.callback(lambda _: int(case == 'cancel'))
                result = self.extract(str(source).encode(), str(output).encode(), 16, 10, cancel, None)
                self.assertEqual(result, expected, case)
            self.assertFalse((root / 'escape').exists())
            source = root / 'duplicate.zip'
            with zipfile.ZipFile(source, 'w') as archive:
                archive.writestr('file', b'first')
                with self.assertWarns(UserWarning): archive.writestr('file', b'second')
            output = root / 'duplicate'; output.mkdir()
            never = self.callback(lambda _: 0)
            self.assertEqual(self.extract(str(source).encode(), str(output).encode(), 64, 10, never, None), 1)
            self.assertEqual((output / 'file').read_bytes(), b'first')
            output = root / 'count'; output.mkdir()
            self.assertEqual(self.extract(str(source).encode(), str(output).encode(), 64, 0, never, None), 2)


if __name__ == '__main__': unittest.main()
