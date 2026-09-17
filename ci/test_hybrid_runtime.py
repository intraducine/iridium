"""Checks for the diagnostic old-native/current-app integration, not game compatibility."""
import importlib.util
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'ci' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stage = load('hybrid_windows_stage', 'stage-windows-runtime.py')
hybrid = load('hybrid_preflight', 'check-hybrid-runtime.py')


class HybridProfileTests(unittest.TestCase):
    def test_both_profile_modes_reject_the_opposite_translator(self):
        for compact in (False, True):
            data = b'FEX fixture' + (stage.COMPACT_PROFILE_MARKER if compact else b'')
            stage.check_translator_profile(data, compact)
            with self.assertRaises(ValueError):
                stage.check_translator_profile(data, not compact)
        self.assertFalse(stage.REQUIRE_COMPACT_PROFILE)

    def test_historical_staging_accepts_old_translator_but_rejects_modern_and_placeholder(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp)
            translator = app / 'arm64ec-windows/xtajit64.dll'
            translator.parent.mkdir()
            (app / 'nls').mkdir()
            for relative in ('prefix-template.tar.gz', 'nls/l_intl.nls'):
                (app / relative).write_bytes(b'fixture')
            with patch.object(stage, 'check_pe'):
                translator.write_bytes(b'historical FEX fixture')
                stage.check(app)
                with self.assertRaisesRegex(ValueError, 'compact'):
                    stage.check(app, require_compact=True)
                translator.write_bytes(stage.COMPACT_PROFILE_MARKER)
                with self.assertRaisesRegex(ValueError, 'pre-compact'):
                    stage.check(app)
                translator.write_bytes(b'x64 emulation not implemented')
                with self.assertRaisesRegex(ValueError, 'placeholder'):
                    stage.check(app)
                translator.write_bytes(b'historical FEX fixture')
                (app / 'prefix-template.tar.gz').unlink()
                with self.assertRaisesRegex(ValueError, 'Missing runtime resource'):
                    stage.check(app)

    def test_pe_validation_remains_enabled(self):
        with tempfile.TemporaryDirectory() as temp:
            dll = Path(temp) / 'module.dll'
            dll.write_bytes(b'not a PE')
            with self.assertRaisesRegex(ValueError, 'Not a PE'):
                stage.check_pe(dll, 'arm64ec')


class HybridPreflightUnitTests(unittest.TestCase):
    def test_exact_identity_and_clean_tree_are_required(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(['git', '-C', temp, *args], text=True).strip()
            git('init', '-q')
            git('config', 'user.name', 'Iridium Tests')
            git('config', 'user.email', 'tests@example.invalid')
            target = root / 'native.c'
            target.write_text('int historical;\n')
            git('add', 'native.c')
            git('commit', '-qm', 'fixture')
            identity = git('rev-parse', 'HEAD:native.c')
            hybrid.check(root, {'native.c': identity})
            with self.assertRaisesRegex(ValueError, 'source mismatch'):
                hybrid.check(root, {'native.c': '0' * 40})
            target.write_text('int modern;\n')
            with self.assertRaisesRegex(ValueError, 'local changes'):
                hybrid.check(root, {'native.c': identity})
            git('add', 'native.c')
            with self.assertRaisesRegex(ValueError, 'local changes'):
                hybrid.check(root, {'native.c': identity})


class HybridReservationTests(unittest.TestCase):
    def body(self):
        source = (ROOT / 'iridium/apps/ios/MadeiraSupport/NativePool.c').read_text()
        start = source.index('#if defined(__APPLE__) && TARGET_OS_IPHONE',
                             source.index('int iridium_reserve_fex_memory(void)'))
        return source[source.index('\n', start) + 1:source.index('#endif', start)]

    @unittest.skipUnless(shutil.which('cc'), 'C compiler required')
    def test_missing_hook_and_both_existing_hook_results(self):
        # Exercise the production device branch. ELF uses weak instead of the
        # Mach-O weak_import spelling; the Mach-O object is checked separately.
        for result in (None, 0, 1):
            with self.subTest(result=result), tempfile.TemporaryDirectory() as temp:
                path = Path(temp)
                definition = '' if result is None else (
                    'int winios_reserve_fex_memory(void) { return ' + str(result) + '; }\n')
                code = ('#include <stdio.h>\n#include <stdlib.h>\n#include <assert.h>\n'
                        'extern int winios_reserve_fex_memory(void) __attribute__((weak));\n'
                        + definition + 'int invoke(void) {\n' + self.body() + '}\n'
                        'int main(void) {\n'
                        'setenv("WINE_IOS_FEX_ARENA_BASE", "stale", 1);\n'
                        'setenv("WINE_IOS_FEX_ARENA_SIZE", "stale", 1);\n'
                        'assert(invoke() == ' + str(1 if result is None else result) + ');\n')
                if result is None:
                    code += ('assert(getenv("WINE_IOS_FEX_ARENA_BASE") == NULL);\n'
                             'assert(getenv("WINE_IOS_FEX_ARENA_SIZE") == NULL);\n')
                else:
                    code += 'assert(getenv("WINE_IOS_FEX_ARENA_BASE") != NULL);\n'
                code += 'return 0; }\n'
                (path / 'test.c').write_text(code)
                subprocess.run(['cc', str(path / 'test.c'), '-o', str(path / 'test')],
                               check=True, capture_output=True)
                subprocess.run([str(path / 'test')], check=True, capture_output=True)

    @unittest.skipUnless(shutil.which('clang'), 'Clang cross-target compiler required')
    def test_darwin_object_marks_reservation_hook_as_weak_import(self):
        source = (ROOT / 'iridium/apps/ios/MadeiraSupport/NativePool.c').read_text()
        declaration = next(line for line in source.splitlines()
                           if line.startswith('extern int winios_reserve_fex_memory'))
        code = ('extern void *stderr;\nint fprintf(void *, const char *, ...);\n'
                'int unsetenv(const char *);\n' + declaration + '\n'
                'int invoke(void) {\n' + self.body() + '}\n')
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            (path / 'test.c').write_text(code)
            subprocess.run(['clang', '-target', 'arm64-apple-ios18.0', '-ffreestanding',
                            '-Werror', '-c', str(path / 'test.c'), '-o', str(path / 'test.o')],
                           check=True, capture_output=True)
            data = (path / 'test.o').read_bytes()
        self.assertEqual(struct.unpack_from('<I', data)[0], 0xfeedfacf)
        commands = struct.unpack_from('<I', data, 16)[0]
        offset = 32
        for _ in range(commands):
            command, size = struct.unpack_from('<II', data, offset)
            if command == 2:  # LC_SYMTAB
                symbols, count, strings, _ = struct.unpack_from('<IIII', data, offset + 8)
                for index in range(count):
                    name, kind, section, flags, value = struct.unpack_from(
                        '<IBBHQ', data, symbols + 16 * index)
                    end = data.index(b'\0', strings + name)
                    if data[strings + name:end] == b'_winios_reserve_fex_memory':
                        self.assertTrue(flags & 0x40)  # N_WEAK_REF
                        return
            offset += size
        self.fail('Missing reservation-hook symbol')


class HybridCheckedOutSnapshotTests(unittest.TestCase):
    def test_native_and_app_bridge_objects_match_the_selected_revisions(self):
        hybrid.check()


if __name__ == '__main__':
    unittest.main()
