"""Component packaging policy tests; never trigger emulator compilation in source CI."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('psp_builder', Path(__file__).with_name('build-ppsspp.py'))
psp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(psp)


class PSPBuildTests(unittest.TestCase):
    def test_both_mobile_targets_keep_the_reviewed_upstream_recipe(self):
        with patch.object(psp, 'output', return_value='/SDK'):
            for sdk, platform in [('iphoneos', 'OS'), ('iphonesimulator', 'SIMULATOR')]:
                command = psp.configure(Path('/source'), Path('/output'), sdk)
                self.assertIn('-DIOS_PLATFORM=' + platform, command)
                self.assertIn('-DCMAKE_OSX_ARCHITECTURES=arm64', command)
                self.assertIn('-DCMAKE_OSX_SYSROOT=/SDK', command)
                for flag in ('-DLIBRETRO=ON', '-DHEADLESS=OFF', '-DUSE_FFMPEG=OFF', '-DUSE_DISCORD=OFF'):
                    self.assertIn(flag, command)
            with self.assertRaises(ValueError):
                psp.configure(Path('/source'), Path('/output'), 'macosx')

    def test_exact_export_platform_and_system_dependency_boundary(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / 'component.dylib'
            binary.write_bytes(b'fixture')
            records = {
                'lipo': 'arm64', 'nm': '\n'.join(psp.EXPORTS),
                'otool-D': 'component:\n@rpath/ppsspp_libretro.dylib',
                'otool-L': 'component:\n\t@rpath/ppsspp_libretro.dylib (version)\n\t/usr/lib/libSystem.B.dylib (version)',
                'vtool': '  platform IOS\n  minos 12.0\n  sdk 27.0',
            }
            def output(*args):
                key = args[1] + (args[2] if args[1] == 'otool' else '')
                return records[key]
            with patch.object(psp, 'output', side_effect=output):
                audit = psp.audit(binary, 'iphoneos')
                self.assertEqual(audit['minimumOS'], '12.0')
                self.assertEqual(len(audit['exports']), 26)
                for key, value in [
                    ('nm', records['nm'] + '\n_cpp_internal'),
                    ('lipo', 'arm64 x86_64'),
                    ('otool-D', 'component:\n/private/build/component.dylib'),
                    ('otool-L', records['otool-L'] + '\n\t@rpath/unreviewed.dylib (version)'),
                    ('vtool', '  platform IOSSIMULATOR\n  minos 14.0'),
                ]:
                    original = records[key]; records[key] = value
                    with self.subTest(key=key), self.assertRaises(ValueError): psp.audit(binary, 'iphoneos')
                    records[key] = original

    def test_minimal_assets_are_exact_hashed_and_originals_untouched(self):
        with tempfile.TemporaryDirectory() as folder:
            source, delivered = Path(folder) / 'source', Path(folder) / 'delivered'
            for name in psp.ASSETS:
                path = source / 'assets' / name
                path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(name.encode())
            self.assertEqual(len(psp.ASSETS), 34)
            before = {name: psp.digest(source / 'assets' / name) for name in psp.ASSETS}
            self.assertEqual(psp.assets(source, delivered), before)
            self.assertEqual({p.relative_to(delivered).as_posix() for p in delivered.rglob('*') if p.is_file()}, set(psp.ASSETS))
            self.assertEqual({name: psp.digest(source / 'assets' / name) for name in psp.ASSETS}, before)
            (delivered / 'unexpected').write_text('retain me')
            with self.assertRaises(ValueError): psp.assets(source, delivered)
            self.assertEqual((delivered / 'unexpected').read_text(), 'retain me')

    def test_compiled_inventory_excludes_unbuilt_targets_and_rejects_outside_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'source'; destination = root / 'output'
            source.mkdir(); (destination / 'build').mkdir(parents=True)
            unit = source / 'core.cpp'; unit.write_text('fixture')
            companion = psp.ROOT / 'iridium/apps/ios/RuntimeBridge/IridiumPPSSPPAdapter.cpp'
            records = []
            for name, file, built in [('core', unit, True), ('adapter', companion, True), ('unused', source / 'absent.cpp', False)]:
                obj = destination / 'build' / (name + '.o')
                if built: obj.write_bytes(b'object')
                records.append({'directory': str(destination / 'build'), 'file': str(file), 'arguments': ['clang', '-o', str(obj)]})
            manifest = destination / 'build/compile_commands.json'
            manifest.write_text(json.dumps(records))
            result = psp.compiled_inputs(source, destination)
            self.assertEqual(set(result), {'PPSSPP/core.cpp', 'Iridium/IridiumPPSSPPAdapter.cpp'})
            outside = root / 'outside.cpp'; outside.write_text('outside')
            records[0]['file'] = str(outside); manifest.write_text(json.dumps(records))
            with self.assertRaises(ValueError): psp.compiled_inputs(source, destination)


if __name__ == '__main__':
    unittest.main()
