"""Native reuse and retained artifacts must never turn a miss into a build."""
import contextlib
import copy
import io
import json
from pathlib import Path
import shutil
import tempfile
import time
import unittest
import subprocess
from unittest.mock import patch
from test_manual_build import load

build = load('native_reuse_tests', 'madeira-frontend.py')


def fixture_inputs():
    return {'revision': build.REVISION, 'recipes': {'build_native': 'recipe digest'},
            'files': {'ci/runtime-inputs.json': 'input digest'}, 'tools': {
                'bison --version': {'executable': '/tools/bison', 'version': 'bison (GNU Bison) 3.8.2'},
                'flex --version': {'executable': '/tools/flex', 'version': 'flex 2.6.4'}}}


def fixture_record(upstream, inputs=None):
    inputs = fixture_inputs() if inputs is None else inputs
    for name in build.native_required_outputs():
        path = upstream / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists(): path.write_bytes(('completed ' + name).encode())
    outputs = set(build.native_required_outputs())
    outputs.update(str(p.relative_to(upstream)) for p in (upstream / 'app/Madeira').glob('*.a'))
    outputs.update(str(p.relative_to(upstream)) for p in (upstream / 'FEX/build-ios').rglob('*.a'))
    record = {'schema': 2, 'state': 'complete', 'key': build.native_key(inputs), 'inputs': inputs,
              'completed': time.time(), 'outputs': {name: build.file_digest(upstream / name) for name in sorted(outputs)}}
    stamp = upstream / '.build/iridium-native.json'
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(record))
    return record


@contextlib.contextmanager
def source_fixture():
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder); upstream = root / 'vendor/Madeira'; upstream.mkdir(parents=True)
        (root / '.git').write_text('fixture source-layout marker')
        def commit(repo, names):
            subprocess.run(['git', '-C', str(repo), 'init', '-q'], check=True)
            for name in names:
                p = repo / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('pinned ' + name + '\n')
            subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                            'commit', '-qm', 'fixture'], check=True)
            return subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        revision = commit(upstream, ['native.c', 'parser.y', 'scanner.l', 'Makefile', 'config.data'])
        freetype = upstream / 'research/freetype'; freetype.mkdir(parents=True)
        freetype_revision = commit(freetype, ['freetype.c'])
        (root / 'ci').mkdir()
        for name in ('runtime-inputs.json', 'local_build_tools.py', 'fetch-runtime-inputs.py', 'engine_pins.py'):
            (root / 'ci' / name).write_bytes((build.ROOT / 'ci' / name).read_bytes())
        for name in ('ci/madeira_audio_volume.py', 'ci/madeira_threads.py',
                     'iridium/apps/ios/RuntimeBridge/IRAudioVolume.c', 'iridium/apps/ios/RuntimeBridge/IRAudioVolume.h',
                     'iridium/apps/ios/RuntimeBridge/IRWindowsThreads.c', 'iridium/apps/ios/RuntimeBridge/IRWindowsThreads.h', 'iridium/apps/ios/RuntimeBridge/IRWindowsMetal.h', 'iridium/apps/ios/RuntimeBridge/IRWindowsJITPool.h', 'iridium/apps/ios/RuntimeBridge/IRWindowsMetalEvents.h'):
            destination = root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((build.ROOT / name).read_bytes())
        pins = json.loads((build.ROOT / 'UPSTREAM-SOURCES.json').read_text())
        pins['frontend_runtime'].update(revision=revision, dependencies={})
        pins['frontend_runtime']['buildDependencies']['freetype']['revision'] = freetype_revision
        (root / 'UPSTREAM-SOURCES.json').write_text(json.dumps(pins))
        (root / 'SOURCE-REVISIONS.json').write_text(json.dumps({
            'vendor/Madeira': revision, 'vendor/Madeira/research/freetype': freetype_revision}))
        with patch.object(build, 'ROOT', root), patch.object(build, 'UPSTREAM', upstream), \
             patch.object(build, 'REVISION', revision), patch.object(build, 'FREETYPE_REVISION', freetype_revision), \
             patch.object(build, 'compiler_tools', return_value=fixture_inputs()['tools']):
            yield root, upstream


class NativeReuseTests(unittest.TestCase):
    def test_console_pin_edits_keep_local_native_checkpoint_and_own_inputs_invalidate_it(self):
        with source_fixture() as (root, upstream):
            manifest = root / 'UPSTREAM-SOURCES.json'
            original = manifest.read_text()
            before = build.native_inputs()
            for entry in json.loads(original)['console_runtimes']:
                data = json.loads(original)
                next(item for item in data['console_runtimes'] if item['id'] == entry['id'])['revision'] = '1' * 40
                manifest.write_text(json.dumps(data))
                self.assertEqual(before, build.native_inputs(), entry['id'])
            data = json.loads(original)
            data['frontend_runtime']['buildDependencies']['freetype']['revision'] = '1' * 40
            manifest.write_text(json.dumps(data))
            self.assertNotEqual(before, build.native_inputs())
            manifest.write_text(original)
            helper = root / 'ci/engine_pins.py'; original_helper = helper.read_bytes()
            helper.write_bytes(original_helper + b'\n# Changed reader\n')
            self.assertNotEqual(before, build.native_inputs())
            helper.write_bytes(original_helper)
            self.assertEqual(before, build.native_inputs())
            for name in ('ci/madeira_threads.py', 'iridium/apps/ios/RuntimeBridge/IRWindowsThreads.c',
                         'iridium/apps/ios/RuntimeBridge/IRWindowsThreads.h', 'iridium/apps/ios/RuntimeBridge/IRWindowsMetal.h', 'iridium/apps/ios/RuntimeBridge/IRWindowsJITPool.h', 'iridium/apps/ios/RuntimeBridge/IRWindowsMetalEvents.h'):
                path = root / name; saved = path.read_bytes()
                path.write_bytes(saved + b'\n/* Changed thread adapter */\n')
                self.assertNotEqual(before, build.native_inputs(), name)
                path.write_bytes(saved)

    def check_rejected(self, root, message, inputs=None):
        before = {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file()}
        output = io.StringIO()
        with patch.object(build, 'UPSTREAM', root), patch.object(build, 'verify_pin'), \
             patch.object(build, 'native_inputs', return_value=inputs or fixture_inputs()), \
             patch.object(build, 'bootstrap') as bootstrap, patch.object(build, 'build_native') as compile, \
             contextlib.redirect_stdout(output):
            with self.assertRaisesRegex(ValueError, message): build.native(reuse_only=True)
            bootstrap.assert_not_called(); compile.assert_not_called()
        self.assertEqual(before, {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file()})
        report = json.loads(output.getvalue())
        self.assertFalse(report['reuse'])
        return report

    def test_stale_key_and_every_missing_changed_output_are_reported_read_only(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); record = fixture_record(root)
            record['key'] = 'old recipe key'
            stamp = root / '.build/iridium-native.json'; stamp.write_text(json.dumps(record))
            (root / 'app/Madeira/libavcodec.a').unlink()
            (root / 'app/Madeira/libswresample.a').write_bytes(b'partial relink')
            report = self.check_rejected(root, 'key_mismatch')
            self.assertTrue(any(x.startswith('missing_output:app/Madeira/libavcodec.a') for x in report['issues']))
            self.assertTrue(any(x.startswith('changed_output:app/Madeira/libswresample.a') for x in report['issues']))

    def test_partial_and_legacy_completion_records_are_rejected(self):
        for change in ({'state': 'building'}, {'outputs': {}}, {'schema': 1}, {'completed': float('nan')},
                       {'completed': time.time() - 15 * 86400}):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as folder:
                root = Path(folder); record = fixture_record(root); record.update(change)
                (root / '.build/iridium-native.json').write_text(json.dumps(record))
                self.check_rejected(root, 'rejected')

    def test_unrecorded_required_or_new_archive_is_rejected(self):
        for extra in (False, True):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as folder:
                root = Path(folder); record = fixture_record(root)
                if extra: (root / 'app/Madeira/libnew.a').write_bytes(b'unrecorded')
                else: record['outputs'].pop('app/Madeira/libavcodec.a')
                (root / '.build/iridium-native.json').write_text(json.dumps(record))
                self.check_rejected(root, 'unrecorded_output')

    def test_tool_and_recipe_mismatches_name_the_changed_constituent(self):
        for group, name, value in [('tools', 'bison --version', {'executable': '/usr/bin/bison', 'version': 'bison 2.3'}),
                                   ('recipes', 'build_native', 'different recipe')]:
            with self.subTest(group=group), tempfile.TemporaryDirectory() as folder:
                root = Path(folder); fixture_record(root)
                current = copy.deepcopy(fixture_inputs()); current[group][name] = value
                report = self.check_rejected(root, 'input_mismatch', current)
                self.assertTrue(any(('inputs.' + group + '.' + name) in x for x in report['issues']))

    def test_missing_stamp_does_not_create_directories_or_bootstrap(self):
        with tempfile.TemporaryDirectory() as folder:
            self.check_rejected(Path(folder), 'unreadable_record')

    def test_valid_completion_record_is_portable_without_resealing(self):
        with tempfile.TemporaryDirectory() as folder:
            producer, consumer = Path(folder) / 'producer', Path(folder) / 'consumer'
            fixture_record(producer)
            shutil.copytree(producer, consumer)
            before = (consumer / '.build/iridium-native.json').read_bytes()
            build.validate_native_reuse(upstream=consumer, inputs=fixture_inputs())
            self.assertEqual((consumer / '.build/iridium-native.json').read_bytes(), before)

    def test_failed_native_stage_preserves_old_receipt_and_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); fixture_record(root)
            stamp = root / '.build/iridium-native.json'; previous = stamp.read_bytes()
            (root / 'app/Madeira/libswresample.a').write_bytes(b'changed')
            with patch.object(build, 'UPSTREAM', root), patch.object(build, 'verify_pin'), \
                 patch.object(build, 'native_inputs', return_value=fixture_inputs()), patch.object(build, 'bootstrap') as bootstrap, \
                 patch.object(build, 'build_native') as compile:
                with self.assertRaisesRegex(ValueError, 'Unverified native substages'): build.native()
                bootstrap.assert_not_called(); compile.assert_not_called()
            self.assertEqual(stamp.read_bytes(), previous)
            self.check_rejected(root, 'changed_output')

    def test_unprovenanced_llvm_crypto_and_wineserver_substages_cannot_be_resealed(self):
        for name in ('toolchains/llvm-ios-build/lib/libLLVMPasses.a',
                     'toolchains/gnutls-ios/lib/libgnutls.a', 'build/wineserver/obj/libwineserver.a'):
            with self.subTest(substage=name), tempfile.TemporaryDirectory() as folder:
                root = Path(folder); path = root / name; path.parent.mkdir(parents=True); path.write_bytes(b'old substage')
                before = path.read_bytes()
                with patch.object(build, 'UPSTREAM', root), patch.object(build, 'verify_pin'), \
                     patch.object(build, 'native_inputs', return_value=fixture_inputs()), \
                     patch.object(build, 'bootstrap') as bootstrap, patch.object(build, 'build_native') as compile:
                    with self.assertRaisesRegex(ValueError, 'Unverified native substages'): build.native()
                    bootstrap.assert_not_called(); compile.assert_not_called()
                self.assertEqual(path.read_bytes(), before)
                self.assertFalse((root / '.build/iridium-native.json').exists())

    def test_failure_during_fresh_compilation_never_creates_a_completion_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def failure():
                path = root / 'toolchains/llvm-ios-build/lib/libLLVMPasses.a'
                path.parent.mkdir(parents=True); path.write_bytes(b'partial output')
                raise RuntimeError('Wine configure failed')
            with patch.object(build, 'UPSTREAM', root), patch.object(build, 'verify_pin'), \
                 patch.object(build, 'native_inputs', return_value=fixture_inputs()), patch.object(build, 'bootstrap'), \
                 patch.object(build, 'build_native', side_effect=failure):
                with self.assertRaisesRegex(RuntimeError, 'Wine configure'): build.native()
                self.assertFalse((root / '.build/iridium-native.json').exists())
                with self.assertRaisesRegex(ValueError, 'Unverified native substages'): build.native()

    def test_old_bison_fails_before_bootstrap(self):
        tools = fixture_inputs()['tools']; tools['bison --version']['version'] = 'bison (GNU Bison) 2.3'
        with patch.object(build, 'compiler_tools', return_value=tools), patch.object(build, 'verify_pin'), \
             patch.object(build, 'bootstrap') as bootstrap:
            with self.assertRaisesRegex(ValueError, 'Bison >= 3.0 before bootstrap'): build.native()
            bootstrap.assert_not_called()

    def test_tool_record_resolves_bison_and_flex_and_retains_each_version(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); real = root / 'real-bison'; real.touch()
            (root / 'bison').symlink_to(real)
            (root / 'flex').write_bytes(b'flex fixture')
            def version(command, **kwargs): return 'version for ' + ' '.join(command)
            with patch.object(build.shutil, 'which', side_effect=lambda name: str(root / name)), \
                 patch.object(build.subprocess, 'check_output', side_effect=version):
                record = build.compiler_tools()
            self.assertEqual(record['bison --version']['executable'], str(real.resolve()))
            self.assertEqual(record['flex --version']['executable'], str((root / 'flex').resolve()))
            self.assertEqual(record['flex --version']['version'], 'version for flex --version')
            self.assertEqual(record['bison --version']['sha256'], build.file_digest(real))
            self.assertEqual(record['flex --version']['sha256'], build.file_digest(root / 'flex'))


class NativeSourceIdentityTests(unittest.TestCase):
    def test_only_the_exact_managed_fex_patch_is_accepted_and_hashed_consistently(self):
        module_relative = 'Source/Windows/ARM64EC/Module.cpp'
        module_original = (build.ROOT / 'vendor/Madeira/FEX' / module_relative).read_text()
        with source_fixture() as (root, upstream):
            fex = upstream / 'FEX'; fex.mkdir()
            relative = 'FEXCore/Source/Utils/AllocWatch.cpp'
            source = fex / relative; source.parent.mkdir(parents=True)
            original = '#if defined(FEX_IOS_HOST) && defined(_WIN32) && !defined(ARCHITECTURE_arm64ec)\n#endif\n'
            source.write_text(original)
            module = fex / module_relative; module.parent.mkdir(parents=True)
            module.write_text(module_original)
            def git(repo, *args):
                return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()
            git(fex, 'init', '-q'); git(fex, 'add', '.')
            git(fex, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture')
            revision = git(fex, 'rev-parse', 'HEAD')
            (upstream / '.gitmodules').write_text('[submodule "FEX"]\npath = FEX\nurl = https://example.invalid/FEX\n')
            git(upstream, 'add', '.gitmodules')
            git(upstream, 'update-index', '--add', '--cacheinfo', '160000,' + revision + ',FEX')
            git(upstream, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture FEX')
            git(upstream, 'config', 'submodule.FEX.url', str(fex))
            with patch.object(build, 'REVISION', git(upstream, 'rev-parse', 'HEAD')):
                build.verify_pin(); before = build.native_source_identity()
                source.write_text(build.madeira_threads.apply_fex(original))
                build.verify_pin(); self.assertEqual(before, build.native_source_identity())
                module.write_text(build.madeira_threads.apply_fex_arm64ec(module_original))
                build.verify_pin(); self.assertEqual(before, build.native_source_identity())
                module.write_text(module.read_text() + '// unrelated edit\n')
                with self.assertRaisesRegex(ValueError, 'Pinned source has changes'): build.verify_pin()
                self.assertNotEqual(before, build.native_source_identity())
                module.write_text(module_original)
                source.write_text(source.read_text() + '// unrelated edit\n')
                with self.assertRaisesRegex(ValueError, 'Pinned source has changes'): build.verify_pin()
                self.assertNotEqual(before, build.native_source_identity())

    def test_tracked_grammars_and_build_configuration_are_bound_to_actual_bytes(self):
        with source_fixture() as (root, upstream):
            inventory = build.native_source_inventory()
            for name in ('parser.y', 'scanner.l', 'Makefile', 'config.data'):
                self.assertIn('vendor/Madeira/' + name, inventory['files'])
                original = (upstream / name).read_bytes(); before = build.native_source_identity()
                (upstream / name).write_bytes(original + b'local edit\n')
                self.assertNotEqual(build.native_source_identity(), before)
                (upstream / name).write_bytes(original)
            for name in ('parser.y', 'scanner.l'):
                original = (upstream / name).read_bytes(); (upstream / name).write_bytes(b'changed grammar')
                with self.assertRaisesRegex(ValueError, 'Pinned source has changes'): build.verify_pin()
                (upstream / name).write_bytes(original)

    def test_source_package_inventory_preserves_and_binds_an_applied_patch(self):
        with source_fixture() as (root, upstream):
            inventory = build.native_source_inventory()
            (root / 'MADEIRA-NATIVE-SOURCES.json').write_text(json.dumps(inventory))
            (root / '.git').unlink()
            target = upstream / 'native.c'; target.write_bytes(target.read_bytes() + b'// applied replacement patch\n')
            patched = target.read_bytes(); inputs = build.native_inputs()
            fixture_record(upstream, inputs)
            build.verify_pin(); build.validate_native_reuse(inputs=build.native_inputs())
            self.assertEqual(target.read_bytes(), patched)
            target.write_bytes(patched + b'// another edit\n')
            with self.assertRaisesRegex(ValueError, 'input_mismatch:inputs.upstreamSources'):
                build.validate_native_reuse(inputs=build.native_inputs())
            self.assertEqual(target.read_bytes(), patched + b'// another edit\n')

    def test_source_package_without_file_inventory_fails_closed(self):
        with source_fixture() as (root, upstream):
            (root / '.git').unlink()
            with self.assertRaises(FileNotFoundError): build.native_source_inventory()
