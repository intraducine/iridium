"""Audit the active native PSP component; source CI never compiles the emulator."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from test_ppsspp_native import native as psp


class PSPBuildTests(unittest.TestCase):
    def test_both_mobile_targets_require_media_and_native_frontend(self):
        with patch.object(psp, 'output', return_value='/SDK'):
            for sdk, platform in [('iphoneos', 'OS'), ('iphonesimulator', 'SIMULATOR')]:
                command = psp.configure(Path('/source'), Path('/output'), sdk)
                self.assertIn('-DIOS_PLATFORM=' + platform, command)
                for flag in ('-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_SYSROOT=/SDK',
                             '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0', '-DLIBRETRO=OFF', '-DUSE_FFMPEG=ON'):
                    self.assertIn(flag, command)

    def test_export_platform_and_system_dependency_boundary(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / 'component.dylib'; binary.write_bytes(b'fixture')
            records = {
                'lipo': 'arm64', 'nm': '\n'.join(psp.EXPORTS),
                'otool-D': 'component:\n@rpath/libIridiumPPSSPPNative.dylib',
                'otool-L': 'component:\n\t@rpath/libIridiumPPSSPPNative.dylib (version)\n\t/usr/lib/libSystem.B.dylib (version)',
                'vtool': '  platform IOS\n  minos 18.0\n  sdk 27.0',
            }
            def output(*args):
                key = args[1] + (args[2] if args[1] == 'otool' else '')
                return records[key]
            with patch.object(psp, 'output', side_effect=output):
                audit = psp.audit(binary, 'iphoneos')
                self.assertEqual(audit['minimumOS'], '18.0')
                self.assertEqual(set(audit['exports']), {'_ir_native_psp_' + name for name in
                    ('abi', 'check_jit', 'check_jit_diagnostic', 'create', 'pause', 'resume', 'request', 'resolution', 'stop', 'restart', 'frames', 'exec_version', 'exec_prepare', 'exec_prepare_diagnostic', 'exec_detach', 'exec_accept_shutdown', 'exec_restored', 'exec_restored_diagnostic', 'exec_advance', 'exec_cancel', 'exec_end')})
                for key, value in [
                    ('nm', records['nm'] + '\n_cpp_internal'), ('lipo', 'arm64 x86_64'),
                    ('otool-D', 'component:\n/private/build/component.dylib'),
                    ('otool-L', records['otool-L'] + '\n\t@rpath/unreviewed.dylib (version)'),
                    ('vtool', '  platform IOSSIMULATOR\n  minos 18.0'),
                ]:
                    original = records[key]; records[key] = value
                    with self.subTest(key=key), self.assertRaises(ValueError): psp.audit(binary, 'iphoneos')
                    records[key] = original

    def test_compiled_inventory_excludes_unbuilt_targets_and_rejects_outside_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); source = root / 'source'; destination = root / 'output'
            source.mkdir(); (destination / 'build').mkdir(parents=True)
            unit = source / 'core.cpp'; unit.write_text('fixture')
            records = []
            for name, file, built in [('core', unit, True),
                    ('adapter', psp.NATIVE / 'IRPPSSPPNative.mm', True),
                    ('codec', psp.NATIVE / 'IRPPSSPPCodecCheck.c', True),
                    ('probe', psp.NATIVE / 'IRJITExecutionProbe.c', True),
                    ('memory', psp.NATIVE / 'IRPSPExecutableMemory.cpp', True),
                    ('unused', source / 'absent.cpp', False)]:
                obj = destination / 'build' / (name + '.o')
                if built: obj.write_bytes(b'object')
                records.append({'directory': str(destination / 'build'), 'file': str(file),
                                'arguments': ['clang', '-o', str(obj)]})
            manifest = destination / 'build/compile_commands.json'; manifest.write_text(json.dumps(records))
            result = psp.compiled_inputs(source, destination)
            self.assertEqual(set(result), {'PPSSPP/core.cpp', 'Iridium/IRPPSSPPNative.mm', 'Iridium/IRPPSSPPCodecCheck.c', 'Iridium/IRJITExecutionProbe.c', 'Iridium/IRPSPExecutableMemory.cpp'})
            outside = root / 'outside.cpp'; outside.write_text('outside')
            records[0]['file'] = str(outside); manifest.write_text(json.dumps(records))
            with self.assertRaises(ValueError): psp.compiled_inputs(source, destination)
            linked = source / 'linked.cpp'; linked.symlink_to(outside)
            records[0]['file'] = str(linked); manifest.write_text(json.dumps(records))
            with self.assertRaisesRegex(ValueError, 'outside the reviewed'):
                psp.compiled_inputs(source, destination)
            records[0]['file'] = str(unit); (destination / 'build/codec.o').unlink()
            manifest.write_text(json.dumps(records))
            with self.assertRaisesRegex(ValueError, 'not both compiled'):
                psp.compiled_inputs(source, destination)


if __name__ == '__main__': unittest.main()
