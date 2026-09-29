import io
import json
import os
import subprocess
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import ROOT, load

inputs = load("runtime_inputs", "fetch-runtime-inputs.py")


class RuntimeInputTests(unittest.TestCase):
    def test_supplied_archive_never_downloads_or_overwrites_changed_input(self):
        import hashlib
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            supplied = root / 'gmp.source-archive'
            supplied.write_bytes(b'supplied source')
            entry = {'name': 'fixture', 'sha256': hashlib.sha256(supplied.read_bytes()).hexdigest(),
                     'url': 'https://example.invalid/source', 'destination': 'inputs/source.tar'}
            with patch.object(inputs.urllib.request, 'urlopen', side_effect=AssertionError('Network used')):
                inputs.fetch(root, entry, supplied)
                target = root / entry['destination']
                self.assertEqual(target.read_bytes(), supplied.read_bytes())
                target.write_bytes(b'local edits')
                with self.assertRaises(ValueError):
                    inputs.fetch(root, entry, supplied)
                supplied.write_bytes(b'corrupt source')
                with self.assertRaises(ValueError):
                    inputs.fetch(root, entry, supplied)
                supplied.unlink()
                with self.assertRaises(FileNotFoundError):
                    inputs.fetch(root, entry, supplied)
                self.assertEqual(target.read_bytes(), b'local edits')
                self.assertFalse((root / '.build/runtime-downloads').exists())

    def test_locked_inputs_and_preparation_order(self):
        entries = json.loads((ROOT / "ci/runtime-inputs.json").read_text())
        self.assertEqual(len({entry['destination'] for entry in entries}), len(entries))
        for entry in entries:
            inputs.destination(ROOT, entry)
        bad = dict(entries[0], destination="../outside")
        with self.assertRaises(ValueError):
            inputs.destination(ROOT, bad)
        workflow = (ROOT / '.github/workflows/build-unsigned-ipa.yml').read_text()
        stages = ['prepare-runtime-inputs.sh', 'prepare-native-runtime.sh', 'compile-wine.sh', 'compile-windows-modules.sh', 'prepare-windows-runtime.sh', 'prepare-graphics.sh', 'prepare-stikjit.sh', 'prepare-legacy-bundle.sh', 'check-ipa-prerequisites.py']
        positions = [workflow.index('ci/' + stage + '\n') for stage in stages]
        self.assertLess(workflow.index('ci/prepare-graphics.sh --preflight'), positions[0])
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn('/tmp/iridium-media-sdk', (ROOT / 'iridium/apps/ios/madeira.yml').read_text())

    def test_vendor_workspace_exclusion_with_real_cargo(self):
        import shutil
        import sys
        cargo = shutil.which('cargo')
        if not cargo:
            self.skipTest('Cargo is not installed')
        script = (ROOT / 'ci/prepare-stikjit.sh').read_text()
        code = script.split("<<'WORKSPACE'\n", 1)[1].split('\nWORKSPACE', 1)[0]
        self.assertIn('--sync vendor/plist_ffi/Cargo.toml vendor', script)
        self.assertNotIn('--no-deps', script)
        self.assertLess(script.index('--sync vendor/plist_ffi/Cargo.toml'), script.index('metadata --offline --locked --all-features'))

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = root / 'Cargo.toml'
            manifest.write_text('[workspace]\nresolver="2"\nmembers=[]\n')
            for name in ('plist_ffi', 'another_crate'):
                crate = root / 'vendor' / name
                (crate / 'src').mkdir(parents=True)
                (crate / 'src/lib.rs').write_text('')
                (crate / 'Cargo.toml').write_text(f'[package]\nname="{name}"\nversion="0.1.0"\nedition="2021"\n')
            command = [cargo, 'metadata', '--offline', '--no-deps', '--format-version=1', '--manifest-path']
            before = subprocess.run(command + [str(root / 'vendor/plist_ffi/Cargo.toml')], capture_output=True, text=True)
            self.assertNotEqual(before.returncode, 0)
            self.assertIn("believes it's in a workspace", before.stderr)
            subprocess.run([sys.executable, '-c', code, str(manifest)], check=True)
            for name in ('plist_ffi', 'another_crate'):
                result = subprocess.run(command + [str(root / 'vendor' / name / 'Cargo.toml')], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_windows_compile_enables_ios_for_all_languages(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'ci').mkdir()
            script = root / 'ci/compile-windows-modules.sh'
            script.write_text((ROOT / 'ci/compile-windows-modules.sh').read_text())
            tools = root / 'bin'
            tools.mkdir()
            for name, body in {
                'brew': 'echo "$MOCK_PREFIX"',
                'cmake': 'printf "%s\\n" "$@" >> "$CAPTURE"; exit 17',
            }.items():
                tool = tools / name
                tool.write_text('#!/bin/sh\n' + body + '\n')
                tool.chmod(0o755)
            wine = root / 'testrepos/Madeira/wine/build-macos'
            for entry in ('libs/winecrt0', 'dlls/ntdll', 'dlls/dbghelp'):
                archive = wine / entry / 'aarch64-windows' / ('lib' + Path(entry).name + '.a')
                archive.parent.mkdir(parents=True)
                archive.write_bytes(b'archive fixture')
            capture = root / 'args'
            env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'], CAPTURE=str(capture), MOCK_PREFIX=str(root))
            result = subprocess.run(['bash', str(script)], env=env, capture_output=True)
            self.assertEqual(result.returncode, 17, result.stderr.decode())
            args = capture.read_text().splitlines()
            for language in ('C', 'CXX', 'ASM'):
                self.assertIn(f'-DCMAKE_{language}_FLAGS=-DFEX_IOS_HOST', args)
            self.assertIn('-DFEX_IOS_HOST_BUILD=ON', args)
            for entry in ('libs/winecrt0', 'dlls/ntdll', 'dlls/dbghelp'):
                archive = wine / entry / 'arm64ec-windows' / ('lib' + Path(entry).name + '.a')
                self.assertEqual(archive.read_bytes(), b'archive fixture')
                self.assertTrue(archive.is_symlink())
            # Let configuration/build finish and exercise the real DLL handoff.
            (tools / 'cmake').write_text('#!/bin/sh\nexit 0\n')
            fex = root / 'testrepos/Madeira/FEX/build-arm64ec'
            (fex / 'Bin').mkdir(parents=True)
            (fex / 'Source/Windows/ARM64EC').mkdir(parents=True)
            dll = fex / 'Bin/libarm64ecfex.dll'
            dll.write_bytes(b'compiled DLL')
            dxmt = root / 'testrepos/Madeira/research/dxmt'
            dxmt.mkdir(parents=True)
            (dxmt / 'build-arm64ec-win.txt').write_text('fixture')
            (tools / 'meson').write_text('#!/bin/sh\nexit 17\n')
            (tools / 'meson').chmod(0o755)
            result = subprocess.run(['bash', str(script)], env=env, capture_output=True)
            self.assertEqual(result.returncode, 17, result.stderr.decode())
            self.assertEqual((fex / 'Source/Windows/ARM64EC/libarm64ecfex.dll').read_bytes(), b'compiled DLL')
            dll.unlink()
            result = subprocess.run(['bash', str(script)], env=env, capture_output=True)
            self.assertEqual(result.returncode, 1)
            (wine / 'libs/winecrt0/aarch64-windows/libwinecrt0.a').unlink()
            result = subprocess.run(['bash', str(script)], env=env, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn(b'Missing Wine link input', result.stderr)

    def test_wine_compile_selects_windows_modules_and_resources_only(self):
        stage = load('wine_stage_compile_test', 'stage-windows-runtime.py')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'ci').mkdir()
            script = root / 'ci/compile-wine.sh'
            script.write_text((ROOT / 'ci/compile-wine.sh').read_text())
            tools = root / 'bin'
            tools.mkdir()
            for name, body in {
                'brew': 'echo "$MOCK_PREFIX"',
                'make': 'printf "%s\\n" "$@" > "$CAPTURE"; exit 17',
            }.items():
                tool = tools / name
                tool.write_text('#!/bin/sh\n' + body + '\n')
                tool.chmod(0o755)
            build = root / 'testrepos/Madeira/wine/build-macos'
            build.mkdir(parents=True)
            targets = [f'{group}/fixture/{arch}-windows/fixture{suffix}'
                       for group in ('dlls', 'programs')
                       for arch in ('aarch64', 'arm64ec') for suffix in stage.SUFFIXES]
            excluded = ['dlls/winegstreamer/winegstreamer.so',
                        'dlls/fixture/i386-windows/fixture.dll',
                        'dlls/fixture/aarch64-windows/fixture.o']
            makefile = build / 'Makefile'
            makefile.write_text('\n'.join(f'{target}: dependency' for target in targets + excluded))
            capture = root / 'args'
            env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'],
                       CAPTURE=str(capture), MOCK_PREFIX=str(root))
            result = subprocess.run(['bash', str(script)], env=env, capture_output=True)
            self.assertEqual(result.returncode, 17, result.stderr.decode())
            self.assertEqual(capture.read_text().splitlines(),
                             ['-C', str(build), '-j2', 'nls/all', 'fonts/all'] + sorted(targets))
            capture.unlink()
            makefile.write_text('\n'.join(f'{target}:' for target in excluded))
            result = subprocess.run(['bash', str(script)], env=env, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(capture.exists())


    def test_wineboot_wrapper_preserves_executable_path_and_arguments(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            launcher = root / 'wine launcher'
            launcher.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            launcher.chmod(0o755)
            env = dict(os.environ, WINE=str(launcher), WINEBOOT_PE=str(root / 'wine boot.exe'))
            result = subprocess.run(['sh', str(ROOT / 'ci/wineboot-from-build.sh'), '--init'],
                                    env=env, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), [env['WINEBOOT_PE'], '--init'])

    def test_digest_failure_and_unsafe_archive_leave_no_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            entry = {'name': 'fixture', 'sha256': '0' * 64, 'url': 'https://example.invalid/source', 'destination': 'source'}
            with patch.object(inputs.urllib.request, 'urlopen', return_value=io.BytesIO(b'wrong')):
                with self.assertRaises(ValueError):
                    inputs.fetch(root, entry)
            self.assertFalse((root / 'source').exists())
            self.assertEqual(list((root / '.build/runtime-downloads').iterdir()), [])
            archive = root / 'test.tar'
            with tarfile.open(archive, 'w') as tar:
                member = tarfile.TarInfo('top/escape')
                member.type = tarfile.SYMTYPE
                member.linkname = '../../outside'
                tar.addfile(member)
            with self.assertRaises(tarfile.FilterError):
                inputs.unpack(archive, root / 'source', 'top')
            self.assertFalse((root / 'source').exists())
            with tarfile.open(archive, 'w') as tar:
                member = tarfile.TarInfo('top/README')
                member.size = 2
                tar.addfile(member, io.BytesIO(b'ok'))
            inputs.unpack(archive, root / 'source', 'top')
            self.assertEqual((root / 'source/README').read_text(), 'ok')
            with self.assertRaises(ValueError):
                inputs.unpack(archive, root / 'source', 'top')


if __name__ == '__main__':
    unittest.main()
