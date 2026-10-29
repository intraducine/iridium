"""Execute orchestration against stale outputs and deliberately failing tools."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import load
from test_madeira_native_reuse import fixture_inputs

build = load('checked_madeira_builds', 'madeira-frontend.py')
ROOT = Path(__file__).resolve().parents[1]


def executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/bin/sh\n' + body + '\n')
    path.chmod(0o755)


class CheckedBuildTests(unittest.TestCase):
    def test_repeated_win32u_builds_merge_only_one_copy_of_freetype(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with patch.object(build, 'OUTPUT', root / 'generated'), patch.object(build.subprocess, 'run') as run:
                build.run_checked_recipe('win32u-unix')
            recipe = run.call_args.kwargs['input']
            archive = recipe[recipe.index('echo "=== Building libwin32u_unix.a ==="'):]
            obj = root / 'obj'; obj.mkdir()
            fonts = root / 'fonts/build'; fonts.mkdir(parents=True)
            for name, output in [('unit', obj), ('fixture_font', root)]:
                source = root / (name + '.c'); source.write_text('int ' + name + '(void){return 1;}\n')
                subprocess.run(['cc', '-c', str(source), '-o', str(output / (name + '.o'))], check=True)
            subprocess.run(['ar', 'rcs', str(fonts / 'libfreetype.a'), str(root / 'fixture_font.o')], check=True)
            env = dict(os.environ, OBJ_DIR=str(obj), FREETYPE_DIR=str(fonts.parent), APP_LIB=str(root / 'app.a'))
            for _ in range(2):
                subprocess.run(['bash', '-e'], input=archive, text=True, env=env, check=True, capture_output=True)
                members = subprocess.check_output(['ar', 't', str(root / 'app.a')], text=True).splitlines()
                self.assertEqual(members.count('fixture_font.o'), 1)
                self.assertEqual(members.count('unit.o'), 1)

    def test_ntdll_failed_compilation_cannot_archive_stale_objects(self):
        text = (ROOT / 'vendor/Madeira/build/ntdll-unix/build.sh').read_text()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            recipe = root / 'build/ntdll-unix/build.sh'
            recipe.parent.mkdir(parents=True)
            recipe.write_text(text)
            (recipe.parent / 'audio_null_ios.c').write_text(
                'static OSStatus ios_audio_render_cb(void) {\n'
                '    atomic_fetch_add_explicit(&g_dev.cb_epoch, 1, memory_order_release);\n}')
            for name in ('process_ios.c', 'thread_ios.c', 'server_ios.c', 'loader_ios.c', 'virtual_ios.c', 'signal_arm64_ios.c'):
                (recipe.parent / name).write_text((ROOT / 'vendor/Madeira/build/ntdll-unix' / name).read_text())
            obj = recipe.parent / 'obj'; obj.mkdir()
            for name in re.findall(r'\$OBJ_DIR/([^"/]+\.o)', text[text.index('ar rcs '):]):
                (obj / name).write_bytes(b'stale object')
            unix = root / 'wine/dlls/ntdll/unix'; unix.mkdir(parents=True)
            (unix / 'file.c').write_text('broken source')
            for name in ('sync.c', 'unix/sync.c'):
                (root / 'wine/dlls/ntdll' / name).write_text((ROOT / 'vendor/Madeira/wine/dlls/ntdll' / name).read_text())
            app = root / 'app/Madeira'; app.mkdir(parents=True)
            output = app / 'libntdll_unix.a'; output.write_bytes(b'previous app archive')
            executable(root / 'build/crypto-unix/gen_gnutls_symtab.sh', 'exit 0')
            executable(root / 'bin/xcrun', 'case "$*" in *--show-sdk-path*) echo /fake/sdk; exit 0;; *) exit 1;; esac')
            env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'])
            with patch.object(build, 'UPSTREAM', root), patch.object(build, 'OUTPUT', root / 'output'):
                with self.assertRaises(subprocess.CalledProcessError):
                    build.run_checked_recipe('ntdll-unix', env=env)
            self.assertEqual(output.read_bytes(), b'previous app archive')
            self.assertFalse((obj / 'libntdll_unix.a').exists())

    def test_i386_failed_bulk_build_retries_existing_targets_and_refuses_stale_install(self):
        text = (ROOT / 'vendor/Madeira/build/wine-i386/build.sh').read_text()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            recipe = root / 'build/wine-i386/build.sh'; recipe.parent.mkdir(parents=True)
            recipe.write_text(text)
            wine = root / 'wine/build-i386'; wine.mkdir(parents=True)
            (wine / 'config.status').touch()
            target = wine / 'dlls/ntdll/i386-windows/ntdll.dll'; target.parent.mkdir(parents=True)
            target.write_bytes(b'stale DLL')
            (wine / 'Makefile').write_text('dlls/ntdll/i386-windows/ntdll.dll: missing-input\n')
            tc = root / 'toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin'
            executable(tc / 'make', 'echo intentional make failure >&2; exit 1')
            executable(tc / 'i686-w64-mingw32-strip', 'exit 0')
            executable(tc / 'llvm-objdump', 'exit 0')
            installed = root / 'app/Madeira/i386-windows/ntdll.dll'
            installed.parent.mkdir(parents=True); installed.write_bytes(b'previous installed DLL')
            env = dict(os.environ, SKIP_DXMT='1', JOBS='1')
            stamp = root / '.build/iridium-i386.json'; stamp.parent.mkdir(); stamp.write_text('{}')
            with patch.object(build, 'UPSTREAM', root), patch.dict(os.environ, env), \
                 patch.object(build, 'verify_pin'), patch.object(build, 'compiler_identity', return_value='fixture compiler'), \
                 patch.object(build.subprocess, 'check_output', side_effect=lambda args, **kwargs:
                    '/tool/Metal.xctoolchain/usr/bin/metal\n' if kwargs.get('text') else b'fixture compiler'):
                with self.assertRaises(subprocess.CalledProcessError):
                    build.windows()
                self.assertEqual(installed.read_bytes(), b'previous installed DLL')
                self.assertEqual(stamp.read_text(), '{}')
                self.assertEqual((wine / 'madeira-i386-build.log').read_text().count('intentional make failure'), 2)
                # Bulk failure may recover only after a successful per-target make.
                executable(tc / 'make', 'case "$1" in -k) exit 1;; esac\nprintf fresh > "$2"')
                build.windows()
                self.assertEqual(installed.read_bytes(), b'fresh')
                completed = stamp.read_bytes()
                executable(tc / 'make', 'exit 1')
                build.windows()
                self.assertEqual(stamp.read_bytes(), completed)

    def test_native_stamps_the_rebuilt_linked_crypto_and_verifies_both_copies(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / 'app/Madeira'; app.mkdir(parents=True)
            prefix = root / 'toolchains/gnutls-ios/lib'
            for name in build.CRYPTO_LIBRARIES:
                (app / f'lib{name}.a').write_bytes(b'tracked prebuilt')
            for name in ('arm64ec-windows/dockhost.exe', 'arm64ec-windows/dock-notices.txt',
                         'legal/LICENSES-rppairing-crates.txt'):
                path = app / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'fixture')
            def bootstrap():
                prefix.mkdir(parents=True)
                for name in build.CRYPTO_LIBRARIES:
                    (prefix / f'lib{name}.a').write_bytes(b'rebuilt ' + name.encode())
            def compile_outputs():
                for name in build.native_required_outputs():
                    p = root / name; p.parent.mkdir(parents=True, exist_ok=True)
                    if not p.exists(): p.write_bytes(b'fresh output')
            with patch.object(build, 'UPSTREAM', root), patch.object(build, 'verify_pin'), \
                 patch.object(build, 'native_inputs', return_value=fixture_inputs()), \
                 patch.object(build.inspect, 'getsource', return_value='fixed fixture compiler recipe'), \
                 patch.object(build, 'bootstrap', side_effect=bootstrap), patch.object(build, 'build_native', side_effect=compile_outputs) as compile:
                build.native(); build.native()
                self.assertEqual(compile.call_count, 1)
                record = json.loads((root / '.build/iridium-native.json').read_text())
                self.assertIn('app/Madeira/arm64ec-windows/xtajit64.dll', record['outputs'])
                for name in build.CRYPTO_LIBRARIES:
                    self.assertEqual((app / f'lib{name}.a').read_bytes(), (prefix / f'lib{name}.a').read_bytes())
                    self.assertIn(f'toolchains/gnutls-ios/lib/lib{name}.a', record['outputs'])
                (prefix / 'libgmp.a').write_bytes(b'changed input')
                with self.assertRaisesRegex(ValueError, 'Unverified native substages'): build.native()
                self.assertEqual(compile.call_count, 1)
                completed = (root / '.build/iridium-native.json').read_bytes()
                (prefix / 'libnettle.a').unlink()
                with self.assertRaisesRegex(ValueError, 'Unverified native substages'):
                    build.native()
                self.assertEqual((app / 'libnettle.a').read_bytes(), b'rebuilt nettle')
                self.assertEqual((root / '.build/iridium-native.json').read_bytes(), completed)
