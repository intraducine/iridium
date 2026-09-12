import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import load

prepared = load('prepared_tests', 'prepared-runtime.py')


class PreparedRuntimeTests(unittest.TestCase):
    def test_producer_must_complete_transfer_even_if_app_later_fails(self):
        run = {'event': 'workflow_dispatch', 'head_branch': 'feature', 'head_sha': 'a' * 40,
               'path': prepared.reuse.WORKFLOW,
               'head_repository': {'full_name': prepared.reuse.REPO}}
        jobs = [{'name': 'build', 'conclusion': 'failure', 'steps': [
            {'name': 'Retain prepared runtime and source', 'conclusion': 'success'}]}]
        self.assertEqual(prepared.reuse.validate(run, jobs, 'native-runtime', 'feature'), 'a' * 40)
        for state in ('failure', 'skipped', None):
            jobs[0]['steps'][0]['conclusion'] = state
            with self.assertRaises(ValueError):
                prepared.reuse.validate(run, jobs, 'native-runtime', 'feature')
        with patch.dict(os.environ, {'NATIVE_TOOLCHAIN': 'b' * 64}):
            self.assertTrue(prepared.reuse.artifact_name('native-runtime').endswith('b' * 64))
        with patch.dict(os.environ, {'NATIVE_TOOLCHAIN': ''}):
            with self.assertRaises(ValueError):
                prepared.reuse.artifact_name('native-runtime')

    def test_archive_roundtrip_and_reject_corruption_or_checkout_overwrite(self):
        # Small files exercise the transfer boundary, not native compilation.
        with tempfile.TemporaryDirectory() as temp:
            producer, consumer = (Path(temp) / name for name in ('producer', 'consumer'))
            for tree in prepared.TREES + prepared.ARCHIVES + prepared.HEADERS:
                (producer / tree).mkdir(parents=True, exist_ok=True)
            required = dict(prepared.prerequisites.REQUIRED)
            names = set(prepared.FILES)
            names.update(prepared.ARCHIVES[1] + '/artifacts/' + name for name in prepared.LINK_ARCHIVES)
            names.update(name for group in required.values() for name in group)
            for name in names:
                path = producer / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'fixture')
            alias = producer / 'iridium-fex-ios/build-iridium-ios-iphoneos'
            alias.rename(alias.with_name('build-iridium-ios-device'))
            alias.symlink_to('build-iridium-ios-device', target_is_directory=True)
            source = producer / prepared.SOURCE
            source.mkdir(parents=True)
            for name in ('iridium.tar.gz', 'repository-revisions.json', 'angle-revisions.json',
                         'StikJIT.tar.gz', 'idevice.tar.gz', 'idevice-dependencies.json',
                         'idevice-ios-dependencies.txt', 'rust-standard-library.tar.gz',
                         'rust-license-texts.tar.gz', 'rust-standard-library-COPYRIGHT.html',
                         'rust-toolchain.txt'):
                (source / name).write_bytes(b'source fixture')
            (source / 'cerbero-1.28.6.tar.xz').write_bytes(b'separate media source')
            ignored = producer / prepared.ARCHIVES[0] / 'CMakeCache.txt'
            ignored.write_text('machine-specific compiler path')
            with patch.dict(os.environ, {'NATIVE_TOOLCHAIN': 'b' * 64, 'GITHUB_REF_NAME': 'feature'}), \
                 patch.object(prepared.reuse, 'git', return_value='a' * 40), \
                 patch.object(prepared.reuse, 'verify_producer', return_value='a' * 40):
                prepared.package(producer)
                prepared.shutil.copytree(producer / '.build/native-transfer', consumer / '.build/native-transfer')
                prepared.restore(consumer, '123')
                self.assertEqual((consumer / prepared.FILES[0]).read_bytes(), b'fixture')
                self.assertFalse((consumer / prepared.ARCHIVES[0] / 'CMakeCache.txt').exists())
                self.assertFalse((consumer / prepared.SOURCE / 'cerbero-1.28.6.tar.xz').exists())
                self.assertTrue((consumer / prepared.SOURCE / 'native-producer-iridium.tar.gz').is_file())
                collector = load('native_source_collector_test', 'collect-release-source.py')
                def snapshot(repo, output):
                    output.write_bytes(b'current app source')
                    return 'c' * 40
                with patch.object(collector, 'ROOT', consumer), \
                     patch.object(collector, 'OUT', consumer / prepared.SOURCE), \
                     patch.object(collector, 'git_snapshot', side_effect=snapshot), \
                     patch.object(collector.subprocess, 'check_output', return_value=b''):
                    collector.collect('checkout')
                self.assertEqual((consumer / prepared.SOURCE / 'iridium.tar.gz').read_bytes(),
                                 b'current app source')
                self.assertEqual((consumer / prepared.SOURCE / 'native-producer-iridium.tar.gz').read_bytes(),
                                 b'source fixture')
                prepared.shutil.rmtree(consumer / 'iridium/packages/runtime/Sources/IridiumRuntime/Resources/BundledRuntime')
                (consumer / prepared.FILES[0]).write_bytes(b'local change')
                with self.assertRaisesRegex(ValueError, 'overwrite'):
                    prepared.restore(consumer, '123')
                archive = consumer / '.build/native-transfer/native-runtime.tar.gz'
                archive.write_bytes(archive.read_bytes() + b'corrupt')
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    prepared.restore(consumer, '123')

    def test_reject_traversal_links_and_unrelated_files_before_restore(self):
        for name in ('../escape', '/escape', '.git/config', 'iridium/UI.swift',
                     prepared.TREES[0] + '/../../escape', prepared.TREES[0] + '/secret.key'):
            self.assertFalse(prepared.allowed(name), name)
        with tempfile.TemporaryDirectory() as temp, \
             patch.dict(os.environ, {'NATIVE_TOOLCHAIN': 'b' * 64, 'GITHUB_REF_NAME': 'feature'}), \
             patch.object(prepared.reuse, 'verify_producer', return_value='a' * 40):
            root = Path(temp)
            transfer = root / '.build/native-transfer'
            transfer.mkdir(parents=True)
            archive = transfer / 'native-runtime.tar.gz'
            for name, kind in [('runtime/../escape', tarfile.REGTYPE),
                               ('runtime/' + prepared.FILES[0], tarfile.SYMTYPE),
                               ('runtime/iridium/UI.swift', tarfile.REGTYPE)]:
                with tarfile.open(archive, 'w:gz') as tar:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    if kind == tarfile.SYMTYPE:
                        member.linkname = '/outside'
                    else:
                        member.size = 1
                    tar.addfile(member, io.BytesIO(b'x'))
                (transfer / 'manifest.json').write_text(json.dumps({
                    'revision': 'a' * 40, 'toolchain': 'b' * 64,
                    'sha256': prepared.inputs.digest(archive)}))
                with self.assertRaisesRegex(ValueError, 'member'):
                    prepared.restore(root, '123')
                self.assertFalse((root / 'iridium').exists())

    def test_native_source_and_toolchain_changes_invalidate_reuse(self):
        with patch.object(prepared.reuse.subprocess, 'run'), \
             patch.object(prepared.reuse, 'git') as git:
            def tree(root, *args):
                if args[0] == 'ls-tree':
                    path = args[-1]
                    return 'old' if args[1] != 'HEAD' and path == 'iridium-fex-ios' else 'same'
                return 'jobs:\n  build:\n    runs-on: xcode-27\n'
            git.side_effect = tree
            with self.assertRaisesRegex(ValueError, 'iridium-fex-ios'):
                prepared.reuse.compatible(Path('.'), 'a' * 40, 'native-runtime')
            git.side_effect = lambda root, *args: ('same' if args[0] == 'ls-tree' else
                'jobs:\n  build:\n    runs-on: xcode-27\n')
            prepared.reuse.compatible(Path('.'), 'a' * 40, 'native-runtime')
        with patch.object(prepared.subprocess, 'check_output', return_value='version 1'), \
             patch.object(prepared.inputs, 'digest', return_value='sdk-1'):
            first = prepared.toolchain()
        with patch.object(prepared.subprocess, 'check_output', return_value='version 2'), \
             patch.object(prepared.inputs, 'digest', return_value='sdk-1'):
            self.assertNotEqual(first, prepared.toolchain())
        with patch.object(prepared.subprocess, 'check_output', return_value='version 1'), \
             patch.object(prepared.inputs, 'digest', return_value='sdk-2'):
            self.assertNotEqual(first, prepared.toolchain())

    def test_reuse_skips_only_dependency_compilation(self):
        workflow = (prepared.ROOT / prepared.reuse.WORKFLOW).read_text()
        for component in ('native', 'wine', 'windows', 'graphics', 'jit'):
            self.assertLess(workflow.index('Retain ' + component + ' compilation'),
                            workflow.index('Check full-runtime build readiness'))
        self.assertNotIn('Retain prepared runtime and source', workflow)
        self.assertIn('python3 ci/collect-release-source.py repository', workflow)
        self.assertIn('run: bash ci/prepare-legacy-bundle.sh', workflow)
