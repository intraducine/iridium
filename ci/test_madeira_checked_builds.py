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

build = load('checked_madeira_builds', 'madeira-frontend.py')
ROOT = Path(__file__).resolve().parents[1]


def executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/bin/sh\n' + body + '\n')
    path.chmod(0o755)


class CheckedBuildTests(unittest.TestCase):
    def test_ntdll_failed_compilation_cannot_archive_stale_objects(self):
        text = (ROOT / 'vendor/Madeira/build/ntdll-unix/build.sh').read_text()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            recipe = root / 'build/ntdll-unix/build.sh'
            recipe.parent.mkdir(parents=True)
            recipe.write_text(text)
            obj = recipe.parent / 'obj'; obj.mkdir()
            for name in re.findall(r'\$OBJ_DIR/([^"/]+\.o)', text[text.index('ar rcs '):]):
                (obj / name).write_bytes(b'stale object')
            unix = root / 'wine/dlls/ntdll/unix'; unix.mkdir(parents=True)
            (unix / 'file.c').write_text('broken source')
            app = root / 'app/Madeira'; app.mkdir(parents=True)
            output = app / 'libntdll_unix.a'; output.write_bytes(b'previous app archive')
            executable(root / 'build/crypto-unix/gen_gnutls_symtab.sh', 'exit 0')
            executable(root / 'bin/xcrun', 'case "$*" in *--show-sdk-path*) echo /fake/sdk; exit 0;; *) exit 1;; esac')
            env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'])
            with patch.object(build, 'UPSTREAM', root):
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
            prefix = root / 'toolchains/gnutls-ios/lib'; prefix.mkdir(parents=True)
            for name in build.CRYPTO_LIBRARIES:
                (app / f'lib{name}.a').write_bytes(b'tracked prebuilt')
                (prefix / f'lib{name}.a').write_bytes(b'rebuilt ' + name.encode())
            for name in ('arm64ec-windows/dockhost.exe', 'arm64ec-windows/dock-notices.txt',
                         'legal/LICENSES-rppairing-crates.txt'):
                path = app / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'fixture')
            with patch.object(build, 'UPSTREAM', root), patch.object(build, 'verify_pin'), \
                 patch.object(build, 'compiler_identity', return_value='fixture compiler'), \
                 patch.object(build.inspect, 'getsource', return_value='fixed fixture compiler recipe'), \
                 patch.object(build, 'bootstrap'), patch.object(build, 'build_native') as compile:
                build.native(); build.native()
                self.assertEqual(compile.call_count, 1)
                record = json.loads((root / '.build/iridium-native.json').read_text())
                for name in build.CRYPTO_LIBRARIES:
                    self.assertEqual((app / f'lib{name}.a').read_bytes(), (prefix / f'lib{name}.a').read_bytes())
                    self.assertIn(f'toolchains/gnutls-ios/lib/lib{name}.a', record['outputs'])
                (prefix / 'libgmp.a').write_bytes(b'changed input')
                build.native()
                self.assertEqual(compile.call_count, 2)
                completed = (root / '.build/iridium-native.json').read_bytes()
                (prefix / 'libnettle.a').unlink()
                with self.assertRaisesRegex(ValueError, 'crypto libraries'):
                    build.native()
                self.assertEqual((app / 'libnettle.a').read_bytes(), b'rebuilt nettle')
                self.assertEqual((root / '.build/iridium-native.json').read_bytes(), completed)
