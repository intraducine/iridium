"""Exercise real extraction/staging and cache transitions, without an Apple SDK.

Native compilation is mocked only in the cache-policy tests. ELF fixtures test
resource contracts, not executable Wine or physical-device compatibility.
"""
import contextlib
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]


def load(filename):
    spec = importlib.util.spec_from_file_location(filename.replace('-', '_'), ROOT / 'ci' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


staging = load('local_runtime_staging.py')
refresh = load('prepare-local-runtime.py')
locking = load('local_build_lock.py')


def elf(interpreter=None):
    data = bytearray(256)
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<H', data, 18, 62)
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, 1)
    struct.pack_into('<I', data, 64, 3 if interpreter else 1)
    if interpreter:
        encoded = interpreter.encode() + b'\0'
        struct.pack_into('<Q', data, 72, 128)
        struct.pack_into('<Q', data, 96, len(encoded))
        data[128:128 + len(encoded)] = encoded
    return bytes(data)


@unittest.skipUnless(shutil.which('zstd'), 'zstd is a local build prerequisite')
class LocalStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        # Check both spaces and shell glob characters in the real shell path loop.
        self.root = Path(self.temporary.name) / 'checkout with [spaces]'
        (self.root / 'ci').mkdir(parents=True)
        shutil.copy2(ROOT / 'ci/stage-linux-userland.py', self.root / 'ci/stage-linux-userland.py')
        self.script = self.root / 'iridium/apps/ios/Scripts/stage_runtime_userland.sh'
        self.script.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'iridium/apps/ios/Scripts/stage_runtime_userland.sh', self.script)
        # Validation uses only stdlib. Avoid unrelated sitecustomize hooks in
        # the developer's Python environment when launching its small probes.
        probes = self.root / 'probe-tools'
        probes.mkdir()
        python = probes / 'python3'
        import shlex
        python.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' -S "$@"\n')
        python.chmod(0o755)
        self.env = patch.dict(os.environ, {
            'IRIDIUM_AMETHYST_ROOT': str(self.root / 'Amethyst-iOS'),
            'PATH': str(probes) + os.pathsep + os.environ['PATH']})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.bundle = self.root / staging.BUNDLE
        self.bundle.mkdir(parents=True)
        for name in ('Runtime/runtime-host.bin', 'Translator/x64-jit.bin',
                     'Graphics/vkd3d-stack.json', 'Graphics/ios-presentation-backend.json', 'Metadata/direct-launch.json'):
            target = self.bundle / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b'fixture')
        for name in ('libEGL', 'libGLESv2'):
            binary = self.root / f'Amethyst-iOS/Natives/resources/Frameworks/{name}.framework/{name}'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'framework fixture')
        self.files = {'bin/wineserver': b'server fixture', 'bin/wine': elf(),
                      'share/wine/nls/l_intl.nls': b'nls fixture',
                      'lib/wine/x86_64-unix/wineios.so': b'driver fixture',
                      'lib/wine/x86_64-unix/opengl32.so': b'opengl fixture',
                      'lib/wine/x86_64-unix/win32u.so': b'libEGL fixture',
                      'lib/wine/x86_64-windows/example.dll': b'noncritical fixture'}
        self.archive = self.bundle / 'Userland/wine-userland.tar.zst'
        self.archive.parent.mkdir()
        self.write_archive()
        self.target = self.root / staging.STAGED

    def write_archive(self, extra=None):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w') as tar:
            for name, data in self.files.items():
                entry = tarfile.TarInfo(name)
                entry.mode = 0o755
                entry.size = len(data)
                tar.addfile(entry, io.BytesIO(data))
            if extra:
                tar.addfile(extra)
        result = subprocess.run(['zstd', '-q', '-c'], input=buffer.getvalue(), capture_output=True, check=True)
        self.archive.write_bytes(result.stdout)
        self.manifest()

    def manifest(self):
        (self.bundle / 'manifest.json').write_text(json.dumps({'version': 'local-' + 'a' * 12, 'artifacts': [{
            'identifier': 'wine-userland', 'relativePath': 'Userland/wine-userland.tar.zst',
            'checksum': staging.digest(self.archive), 'sizeBytes': self.archive.stat().st_size}]}))

    def test_archive_only_restore_and_no_duplicate_canonical_tree(self):
        self.assertEqual(staging.ensure_userland(self.root), self.target)
        self.assertTrue((self.target / 'bin/wineserver').is_file())
        self.assertFalse((self.bundle / 'Userland/extracted').exists())
        self.assertFalse((self.root / '.build/local-staging-check').exists())

    def test_repeated_run_reuses_tree_without_extraction(self):
        staging.ensure_userland(self.root)
        before = (self.target / 'bin/wine').stat().st_mtime_ns
        with patch.object(staging, 'load', side_effect=AssertionError('must not extract again')):
            staging.ensure_userland(self.root)
        self.assertEqual((self.target / 'bin/wine').stat().st_mtime_ns, before)

    def test_deleted_tree_is_recreated_on_cache_hit(self):
        staging.ensure_userland(self.root)
        shutil.rmtree(self.target)
        staging.ensure_userland(self.root)
        self.assertTrue((self.target / 'bin/wine').is_file())

    def test_missing_noncritical_dll_is_repaired(self):
        staging.ensure_userland(self.root)
        dll = self.target / 'lib/wine/x86_64-windows/example.dll'
        dll.unlink()
        staging.ensure_userland(self.root)
        self.assertEqual(dll.read_bytes(), self.files['lib/wine/x86_64-windows/example.dll'])

    def test_modified_file_is_repaired(self):
        staging.ensure_userland(self.root)
        dll = self.target / 'lib/wine/x86_64-windows/example.dll'
        dll.write_bytes(b'damaged')
        staging.ensure_userland(self.root)
        self.assertEqual(dll.read_bytes(), self.files['lib/wine/x86_64-windows/example.dll'])

    def test_changed_archive_replaces_stale_files(self):
        staging.ensure_userland(self.root)
        del self.files['lib/wine/x86_64-windows/example.dll']
        self.files['new.dll'] = b'new generation'
        self.write_archive()
        staging.ensure_userland(self.root)
        self.assertFalse((self.target / 'lib/wine/x86_64-windows/example.dll').exists())
        self.assertEqual((self.target / 'new.dll').read_bytes(), b'new generation')

    def test_corrupt_archive_does_not_destroy_previous_tree(self):
        staging.ensure_userland(self.root)
        self.archive.write_bytes(b'not a zstd file')
        self.manifest()
        with self.assertRaises(subprocess.CalledProcessError):
            staging.ensure_userland(self.root)
        self.assertEqual((self.target / 'bin/wine').read_bytes(), elf())

    def test_checksum_mismatch_fails_before_extraction(self):
        self.archive.write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'checksum/size'):
            staging.ensure_userland(self.root)
        self.assertFalse(self.target.exists())

    def test_invalid_replacement_keeps_working_staging(self):
        staging.ensure_userland(self.root)
        self.files['bin/wine'] = b'\xcf\xfa\xed\xfe' + b'not an ELF loader'
        self.write_archive()
        with self.assertRaisesRegex(ValueError, 'Mach-O'):
            staging.ensure_userland(self.root)
        self.assertEqual((self.target / 'bin/wine').read_bytes(), elf())

    def test_validation_rejects_missing_driver_nls_and_egl(self):
        for name in ('share/wine/nls/l_intl.nls', 'lib/wine/x86_64-unix/wineios.so',
                     'lib/wine/x86_64-unix/win32u.so'):
            with self.subTest(name=name):
                data = self.files.pop(name)
                self.write_archive()
                with self.assertRaises(ValueError):
                    staging.ensure_userland(self.root)
                self.files[name] = data
                self.assertFalse(self.target.exists())

    def test_preloader_requires_companion_and_interpreter(self):
        del self.files['bin/wine']
        self.files['lib/wine/x86_64-unix/wine-preloader'] = elf()
        self.files['lib/wine/x86_64-unix/wine'] = elf('/lib64/ld-linux-x86-64.so.2')
        self.write_archive()
        with self.assertRaisesRegex(ValueError, 'companion|sibling'):
            staging.ensure_userland(self.root)
        self.files['lib64/ld-linux-x86-64.so.2'] = elf()
        self.write_archive()
        staging.ensure_userland(self.root)

    def test_direct_pt_interp_loader_is_not_accepted(self):
        self.files['bin/wine'] = elf('/lib64/ld-linux-x86-64.so.2')
        self.write_archive()
        with self.assertRaisesRegex(ValueError, 'PT_INTERP'):
            staging.ensure_userland(self.root)

    def test_invalid_explicit_root_does_not_fall_back(self):
        staging.ensure_userland(self.root)
        with self.assertRaisesRegex(ValueError, 'Missing embedded-FEX-compatible'):
            staging.validate_sources(self.root, self.root / 'not-there')

    def test_cache_marker_damage_self_repairs(self):
        staging.ensure_userland(self.root)
        for content in ('{bad json', '[]', '{}'):
            (self.target / staging.MARKER).write_text(content)
            staging.ensure_userland(self.root)
            self.assertIn('sha256', json.loads((self.target / staging.MARKER).read_text()))

    def test_native_bundle_replacement_does_not_remove_staging(self):
        staging.ensure_userland(self.root)
        previous = self.bundle.with_name(self.bundle.name + '.old')
        shutil.copytree(self.bundle, previous)
        shutil.rmtree(self.bundle)
        previous.rename(self.bundle)
        with patch.object(staging, 'load', side_effect=AssertionError('must reuse extraction')):
            staging.ensure_userland(self.root)

    def test_unsafe_archive_paths_and_links_are_rejected(self):
        for name, link in (('../escaped', None), ('escape-link', '/tmp/host-file')):
            with self.subTest(name=name):
                entry = tarfile.TarInfo(name)
                if link:
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = link
                self.write_archive(entry)
                with self.assertRaises(tarfile.FilterError):
                    staging.ensure_userland(self.root)
                self.assertFalse(self.target.exists())
        self.assertFalse((self.target.parent / 'escaped').exists())

    def test_symlink_destination_is_never_followed(self):
        outside = self.root.parent / 'outside'
        outside.mkdir()
        self.target.parent.mkdir(parents=True)
        self.target.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Refusing'):
            staging.ensure_userland(self.root)
        self.assertEqual(list(outside.iterdir()), [])

    def test_read_only_check_does_not_touch_app(self):
        staging.ensure_userland(self.root)
        app = self.root / '.build/local-staging-check/Iridium.app'
        app.mkdir(parents=True)
        (app / 'keep').write_text('unchanged')
        staging.validate_sources(self.root, self.target)
        self.assertEqual([p.name for p in app.iterdir()], ['keep'])

    def test_missing_framework_rejected_before_publication(self):
        (self.root / 'Amethyst-iOS/Natives/resources/Frameworks/libEGL.framework/libEGL').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing framework binary'):
            staging.ensure_userland(self.root)
        self.assertFalse(self.target.exists())

    def test_fex_disabled_marker_rejected_before_publication(self):
        (self.bundle / 'Translator/x64-jit.bin').write_bytes(b'Embedded FEX runtime was compiled without FEXCore support')
        with self.assertRaisesRegex(ValueError, 'without FEXCore support'):
            staging.ensure_userland(self.root)
        self.assertFalse(self.target.exists())

    def test_full_stage_produces_extracted_only_userland(self):
        staging.ensure_userland(self.root)
        tools = self.root / 'fake-tools'
        tools.mkdir()
        # Only Apple's copy utility is simulated; execute the real stage script.
        ditto = tools / 'ditto'
        ditto.write_text('#!' + sys.executable + ' -S\nimport shutil,sys\nshutil.copytree(sys.argv[1], sys.argv[2], dirs_exist_ok=True, symlinks=True)\n')
        ditto.chmod(0o755)
        product = self.root / 'products'
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                   SRCROOT=str(self.root / 'iridium/apps/ios'), TARGET_BUILD_DIR=str(product),
                   UNLOCALIZED_RESOURCES_FOLDER_PATH='Iridium.app', FRAMEWORKS_FOLDER_PATH='Iridium.app/Frameworks',
                   IRIDIUM_RUNTIME_BUNDLE_ROOT=str(self.bundle), IRIDIUM_WINE_STAGED_ROOT=str(self.target),
                   CODE_SIGNING_ALLOWED='NO')
        subprocess.run(['sh', str(self.script)], env=env, check=True, capture_output=True)
        app = product / 'Iridium.app'
        self.assertTrue((app / 'IridiumWineUserland/bin/wine').is_file())
        self.assertFalse((app / 'BundledRuntime/iridium-runtime-base/Userland/wine-userland.tar.zst').exists())
        metadata = json.loads((app / 'BundledRuntime/iridium-runtime-base/manifest.json').read_text())
        self.assertEqual(metadata['supportMetadata']['userlandDelivery'], 'app-staged-extracted')
        self.assertTrue(self.archive.is_file())


class CacheTransitionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / '.build/local-native-runtime-state.json'
        self.pending = self.state.with_suffix('.incomplete')
        self.state.parent.mkdir()
        self.inventory = {'libRuntime.a': [123, 456]}
        self.staging = SimpleNamespace(recover_bundle=Mock(), check_retained_inputs=Mock(),
                                       native_output_inventory=Mock(side_effect=lambda root: dict(self.inventory)))
        self.provenance = SimpleNamespace(load_reuse=Mock(return_value=object()), verify_native_contract=Mock())
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        for key, value in (('ROOT', self.root), ('STATE', self.state), ('INCOMPLETE', self.pending)):
            self.stack.enter_context(patch.object(refresh, key, value))
        self.stack.enter_context(patch.object(refresh, 'load', side_effect=lambda name, path:
            self.staging if path.name == 'local_runtime_staging.py' else self.provenance))
        self.stack.enter_context(patch.object(refresh, 'native_fingerprint', return_value='fingerprint'))
        self.dirty = self.stack.enter_context(patch.object(refresh, 'native_worktree_dirty', return_value=False))
        self.stack.enter_context(patch.object(refresh, 'existing_producer', return_value='a' * 40))
        self.stack.enter_context(patch.object(refresh, 'output', return_value='a' * 40))
        self.stack.enter_context(patch.object(refresh, 'head_short', return_value='a' * 12))
        self.verify = self.stack.enter_context(patch.object(refresh, 'verify_retained_inputs'))
        self.rebuild = self.stack.enter_context(patch.object(refresh, 'rebuild_native_runtime'))
        self.stack.enter_context(patch.dict(os.environ, {'IRIDIUM_FORCE_NATIVE_REBUILD': '0'}))

    def seed(self):
        refresh.write_state('fingerprint', 'b' * 40)

    def test_complete_cache_hit_does_not_recompile(self):
        self.seed()
        refresh.main()
        self.rebuild.assert_not_called()
        self.verify.assert_called_once_with(self.provenance.load_reuse.return_value, 'b' * 40)

    def test_output_change_invalidates_cache(self):
        self.seed()
        self.inventory['libRuntime.a'] = [124, 457]
        refresh.main()
        self.rebuild.assert_called_once()
        self.assertEqual(json.loads(self.state.read_text())['outputs'], self.inventory)

    def test_missing_output_forces_rebuild_before_publish(self):
        self.seed()
        self.staging.native_output_inventory.side_effect = [ValueError('missing library'), self.inventory]
        refresh.main()
        self.rebuild.assert_called_once()
        self.assertFalse(self.pending.exists())

    def test_failed_force_rebuild_cannot_reuse_old_success_record(self):
        self.seed()
        def fail(_):
            self.assertTrue(self.pending.is_file())
            self.assertFalse(self.state.exists())
            raise RuntimeError('compile failed')
        self.rebuild.side_effect = fail
        with patch.dict(os.environ, {'IRIDIUM_FORCE_NATIVE_REBUILD': '1'}):
            with self.assertRaisesRegex(RuntimeError, 'compile failed'):
                refresh.main()
        self.rebuild.side_effect = None
        refresh.main()  # The retry is not explicitly forced; the marker forces it.
        self.assertEqual(self.rebuild.call_count, 2)
        self.assertFalse(self.pending.exists())
        self.assertTrue(self.state.is_file())
        self.assertEqual(json.loads(self.state.read_text())['retainedRevision'], 'b' * 40)

    def test_provenance_failure_never_writes_success_stamp(self):
        self.provenance.verify_native_contract.side_effect = [ValueError('stale'), ValueError('invalid rebuild')]
        with self.assertRaisesRegex(ValueError, 'invalid rebuild'):
            refresh.main()
        self.assertFalse(self.state.exists())
        self.assertTrue(self.pending.exists())

    def test_output_validation_failure_never_writes_success_stamp(self):
        self.staging.native_output_inventory.side_effect = ValueError('missing output')
        with self.assertRaisesRegex(ValueError, 'missing output'):
            refresh.main()
        self.assertFalse(self.state.exists())
        self.assertTrue(self.pending.exists())

    def test_initial_seed_requires_complete_outputs(self):
        refresh.main()
        self.rebuild.assert_not_called()
        self.assertTrue(self.state.exists())

    def test_initial_seed_with_local_edits_must_recompile(self):
        self.dirty.return_value = True
        refresh.main()
        self.rebuild.assert_called_once()
        self.assertTrue(self.state.exists())

    def test_incompatible_retained_inputs_stop_before_compilation(self):
        self.verify.side_effect = RuntimeError('retained Linux mismatch')
        with self.assertRaisesRegex(RuntimeError, 'retained Linux mismatch'):
            refresh.main()
        self.rebuild.assert_not_called()
        self.assertFalse(self.pending.exists())

    def test_corrupt_interruption_marker_forces_recovery(self):
        self.pending.write_text('[]')
        refresh.main()
        self.rebuild.assert_called_once()
        self.assertFalse(self.pending.exists())


class LocalBuildSafetyTests(unittest.TestCase):
    def test_recover_interrupted_bundle_rename(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bundle = root / staging.BUNDLE
            previous = bundle.with_name(bundle.name + '.previous')
            previous.mkdir(parents=True)
            (previous / 'keep').write_text('old complete generation')
            staging.recover_bundle(root)
            self.assertEqual((bundle / 'keep').read_text(), 'old complete generation')
            self.assertFalse(previous.exists())

    def test_lock_rejects_second_build_and_releases_after_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / '.build').mkdir()
            with (root / '.build/local-ipa.lock').open('a+') as stream:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaisesRegex(RuntimeError, 'Another local IPA build'):
                    locking.run_locked(root, [sys.executable, '-S', '-c', 'raise SystemExit(0)'])
            self.assertEqual(locking.run_locked(root, [sys.executable, '-S', '-c', 'raise SystemExit(19)']), 19)
            self.assertEqual(locking.run_locked(root, [sys.executable, '-S', '-c', 'raise SystemExit(0)']), 0)

    def test_missing_retained_inputs_report_all_paths_together(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch.object(staging, 'retained_inputs', return_value=['a', 'b']):
                with self.assertRaisesRegex(ValueError, r'a\n  b'):
                    staging.check_retained_inputs(root)

    def test_local_entry_point_stages_after_refresh_and_before_xcode(self):
        script = (ROOT / 'ci/build-local-ipa.sh').read_text()
        self.assertLess(script.index('local_build_lock.py'), script.index('mkdir -p .build/local-build-logs'))
        self.assertLess(script.index('python3 ci/prepare-local-runtime.py'), script.index('python3 ci/local_runtime_staging.py'))
        self.assertLess(script.index('python3 ci/local_runtime_staging.py'), script.index('xcodebuild -project'))
        self.assertIn('IRIDIUM_WINE_STAGED_ROOT="$IRIDIUM_WINE_STAGED_ROOT"', script)
        self.assertIn('manifest.json "$runtime_resources/iridium-runtime-base/manifest.json"', script)
        self.assertNotIn('ditto iridium-runtime-sdk/build/iridium-runtime-base', script)
        self.assertNotIn('xcodebuild clean', script)
        self.assertIn('python3 ci/check-ipa-prerequisites.py --package', script)



class RealInputFingerprintTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'repo'
        self.root.mkdir()
        self.git('init', '-q')
        (self.root / 'native').mkdir()
        (self.root / 'native/source.c').write_text('one')
        workflow = self.root / refresh.WORKFLOW
        workflow.parent.mkdir(parents=True)
        workflow.write_text('workflow fixture')
        self.commit()
        self.reuse = SimpleNamespace(
            git=lambda root, *args: subprocess.check_output(['git', '-C', str(root), *args], text=True).strip(),
            producer_job=lambda text, stage: text,
            MEDIA_INPUTS=('native',), PREFIX_INPUTS=('prefix',),
            linux=SimpleNamespace(INPUTS=('linux',)),
            COMPONENT_INPUTS={'graphics': ('graphics',), 'jit': ('jit',)})
        self.provenance = SimpleNamespace(load_reuse=lambda: self.reuse, native_contract_inputs=lambda reuse: ('native',))
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(refresh, 'ROOT', self.root))
        for name in ('MEDIA', 'PREFIX', 'USERLAND'):
            self.stack.enter_context(patch.object(refresh, name, self.root / name))
        self.stack.enter_context(patch.object(refresh, 'output', return_value='stable toolchain'))

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def commit(self):
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')

    def test_uncommitted_and_untracked_sources_change_fingerprint(self):
        before = refresh.native_fingerprint(self.provenance)
        (self.root / 'native/source.c').write_text('two')
        edited = refresh.native_fingerprint(self.provenance)
        self.assertNotEqual(before, edited)
        (self.root / 'native/new.c').write_text('new untracked source')
        self.assertNotEqual(edited, refresh.native_fingerprint(self.provenance))

    def test_ignored_build_outputs_do_not_invalidate_source(self):
        (self.root / '.gitignore').write_text('native/build/\n')
        self.commit()
        before = refresh.native_fingerprint(self.provenance)
        (self.root / 'native/build').mkdir()
        (self.root / 'native/build/cache.o').write_text('generated')
        self.assertEqual(before, refresh.native_fingerprint(self.provenance))

    def test_retained_producer_rejects_committed_and_dirty_changes(self):
        revision = self.git('rev-parse', 'HEAD')
        refresh.verify_retained_inputs(self.reuse, revision)
        (self.root / 'native/source.c').write_text('changed')
        with self.assertRaisesRegex(RuntimeError, 'media'):
            refresh.verify_retained_inputs(self.reuse, revision)
        self.commit()
        with self.assertRaisesRegex(RuntimeError, 'media'):
            refresh.verify_retained_inputs(self.reuse, revision)

    def test_repeated_dirty_submodule_edits_change_fingerprint(self):
        dependency = self.root.parent / 'dependency'
        dependency.mkdir()
        subprocess.run(['git', 'init', '-q', str(dependency)], check=True)
        (dependency / 'allocator.c').write_text('initial')
        subprocess.run(['git', '-C', str(dependency), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(dependency), '-c', 'user.name=Fixture', '-c',
                        'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
        self.git('-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', str(dependency), 'native/dep')
        self.commit()
        source = self.root / 'native/dep/allocator.c'
        source.write_text('first local patch')
        first = refresh.native_fingerprint(self.provenance)
        source.write_text('second local patch')
        self.assertNotEqual(first, refresh.native_fingerprint(self.provenance))


class NativeOutputInventoryTests(unittest.TestCase):
    def test_companion_archive_deletion_and_new_dll_are_detected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'ci').mkdir()
            shutil.copy2(ROOT / 'ci/check-ipa-prerequisites.py', root / 'ci/check-ipa-prerequisites.py')
            try:
                staging.native_output_inventory(root)
            except ValueError as error:
                missing = str(error).split('\n  ')[1:]
            self.assertIn('iridium-fex-ios/build-iridium-ios-iphoneos/FEXCore/Source/libJemallocLibs.a', missing)
            for name in missing:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'fixture output')
            before = staging.native_output_inventory(root)
            dll = root / 'iridium/apps/ios/MediaRuntime/extra.dll'
            dll.write_bytes(b'new staged module')
            self.assertNotEqual(before, staging.native_output_inventory(root))
            (root / 'iridium-fex-ios/build-iridium-ios-iphoneos/External/fmt/libfmt.a').unlink()
            with self.assertRaisesRegex(ValueError, 'libfmt.a'):
                staging.native_output_inventory(root)


if __name__ == '__main__':
    unittest.main()
