# SPDX-License-Identifier: AGPL-3.0-only
"""Exercise the package-size changes at their binary and resource boundaries."""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import madeira_components
import phase3_app


class PackageSizeTests(unittest.TestCase):
    def test_pe_strips_only_unsigned_symbols_with_no_overlay(self):
        pe, fields, symbols = 64, 76, 512
        data = bytearray(560)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 60, pe)
        data[pe:pe + 4] = b'PE\0\0'
        struct.pack_into('<H', data, pe + 6, 1)
        struct.pack_into('<II', data, fields, symbols, 1)
        struct.pack_into('<HH', data, pe + 20, 240, 2)
        struct.pack_into('<H', data, pe + 24, 0x20b)
        section = pe + 24 + 240
        data[section:section + 5] = b'.text'
        struct.pack_into('<II', data, section + 16, 1, symbols - 1)
        data[symbols - 1] = 1
        struct.pack_into('<I', data, symbols + 18, 4)
        original = bytes(data)
        clean = original[:fields] + bytes(8) + original[fields + 8:symbols]

        with patch.object(madeira_components.subprocess, 'run') as run:
            run.return_value = subprocess.CompletedProcess([], 0, stdout=clean)
            self.assertEqual(madeira_components.strip_pe_symbols(original, 'objcopy'), clean)
            run.assert_called_once_with(['objcopy', '--strip-all', '-', '-'], input=original, capture_output=True)
            for candidate in (clean[:-1] + b'\0', clean[:-1], clean[:fields] + original[fields:fields + 8] + clean[fields + 8:]):
                run.return_value.stdout = candidate
                self.assertIs(madeira_components.strip_pe_symbols(original, 'objcopy'), original)

            run.reset_mock()
            data[pe + 24 + 112 + 4 * 8] = 1
            long_name = original[:section] + b'/' + original[section + 1:]
            for unsupported in (bytes(data), original + b'overlay', long_name):
                self.assertIs(madeira_components.strip_pe_symbols(unsupported, 'objcopy'), unsupported)
            run.assert_not_called()

    def test_dolphin_resources_are_staged_and_audited_once_at_bundle_root(self):
        engines = {
            'host': 'libIridiumRetroPlayer.dylib',
            'dolphin': 'libIridiumDolphin.dylib',
            'azahar': 'azahar_libretro.dylib',
            'play': 'play_libretro_ios.dylib',
            'flycast': 'flycast_libretro.dylib',
        }
        pins = {engine: ('fixture', 'rev') for engine in engines if engine != 'host'}

        def digest(path):
            return hashlib.sha256(path.read_bytes()).hexdigest()

        builder = SimpleNamespace(PINS=pins, digest=digest, verify_inputs=lambda _: None,
                                  audit=lambda binary, sdk, native: {'sha256': digest(binary)})
        spec = SimpleNamespace(loader=SimpleNamespace(exec_module=lambda _: None))
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / 'Iridium.app'
            (app / 'Frameworks').mkdir(parents=True)
            for engine, binary in engines.items():
                directory = root / '.build/phase3' / engine / 'iphoneos'
                (directory / 'assets').mkdir(parents=True)
                (directory / 'licenses').mkdir()
                (directory / binary).write_text(engine)
                shutil.copy2(directory / binary, app / 'Frameworks' / binary)
                files = {}
                if engine == 'dolphin':
                    files['assets/Sys/GC/font.bin'] = 'gamecube font'
                elif engine == 'play':
                    files['assets/GameConfig.xml'] = '<config/>'
                if engine != 'host':
                    files['licenses/COPYING'] = 'license'
                for name, value in files.items():
                    resource = directory / name
                    resource.parent.mkdir(parents=True, exist_ok=True)
                    resource.write_text(value)
                record = dict(sha256=digest(directory / binary), revision='rev',
                              files={name: digest(directory / name) for name in files})
                (directory / 'component.json').write_text(json.dumps(record))

            with (patch.object(phase3_app, 'ROOT', root),
                  patch.object(phase3_app.importlib.util, 'spec_from_file_location', return_value=spec),
                  patch.object(phase3_app.importlib.util, 'module_from_spec', return_value=builder)):
                phase3_app.stage_phase3(app, shutil.copytree)
                self.assertTrue((app / 'licenses/Phase3/dolphin/COPYING').is_file())
                self.assertTrue((app / 'Phase3/play/GameConfig.xml').is_file())
                self.assertEqual(list(app.rglob('font.bin')), [app / 'Sys/GC/font.bin'])
                revisions = dict.fromkeys(pins, 'rev')
                phase3_app.check_phase3_bundle(app, revisions)
                (app / 'Phase3/dolphin/Sys').mkdir(parents=True)
                with self.assertRaisesRegex(ValueError, 'Duplicate Dolphin'):
                    phase3_app.check_phase3_bundle(app, revisions)
                (app / 'Phase3/dolphin/Sys').rmdir()
                (app / 'Sys/GC/font.bin').write_text('changed')
                with self.assertRaisesRegex(ValueError, 'packaged resource differs'):
                    phase3_app.check_phase3_bundle(app, revisions)
