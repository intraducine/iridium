"""Retain source and finished components when freeing this Actions phase's scratch."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import load

space = load('native_phase_space', 'free-build-space.py')


class NativePhaseSpaceTests(unittest.TestCase):
    def fixture(self, root):
        (root / 'ci').mkdir()
        archive = b'consumed immutable toolchain input'
        checksum = hashlib.sha256(archive).hexdigest()
        (root / 'ci/runtime-inputs.json').write_text(json.dumps([
            dict(name='llvm', sha256=checksum, destination='testrepos/Madeira/toolchains/llvm-project')]))
        transfer = root / '.build/madeira-native-compiled-transfer'
        transfer.mkdir(parents=True)
        (transfer / 'compiled.tar.gz').write_bytes(b'uploaded checkpoint')
        download = root / '.build/runtime-downloads' / (checksum + '.tar')
        download.parent.mkdir(); download.write_bytes(archive)
        (root / 'vendor/Madeira/toolchains/llvm-project').mkdir(parents=True)
        objects = root / space.NATIVE_OBJECT_TREES[0]; objects.mkdir()
        for name in ['temporary.o', 'libLLVM.a', 'config.h']: (objects / name).write_text(name)
        return transfer, download, objects

    def run_cleanup(self, root, **kwargs):
        with patch.dict(os.environ, GITHUB_ACTIONS='true', GITHUB_WORKSPACE=str(root)), \
             patch.object(space.subprocess, 'run', **kwargs) as validate, \
             patch.object(space.shutil, 'disk_usage', return_value=shutil._ntuple_diskusage(100, 20, 60 * 1024**3)):
            space.cleanup_native(root)
            validate.assert_called_once_with([space.sys.executable, str(root / 'ci/madeira-frontend.py'), 'native', '--reuse-only'], check=True)

    def test_verified_native_checkpoint_retains_libraries_sources_and_unrelated_data(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); transfer, archive, objects = self.fixture(root)
            source = root / 'vendor/Madeira/toolchains/llvm-project/source.o'; source.write_text('source')
            (objects / 'linked.o').symlink_to(source)
            self.run_cleanup(root)
            self.assertFalse(transfer.exists()); self.assertFalse(archive.exists())
            self.assertFalse((objects / 'temporary.o').exists())
            self.assertTrue((objects / 'libLLVM.a').exists()); self.assertTrue((objects / 'config.h').exists())
            self.assertEqual(source.read_text(), 'source'); self.assertTrue((objects / 'linked.o').is_symlink())

    def test_failed_checkpoint_and_archive_validation_do_not_remove_anything(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); transfer, archive, objects = self.fixture(root)
            with self.assertRaises(subprocess.CalledProcessError):
                self.run_cleanup(root, side_effect=subprocess.CalledProcessError(1, 'native'))
            self.assertTrue(transfer.exists()); self.assertTrue((objects / 'temporary.o').exists())
            archive.write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'checksum'): self.run_cleanup(root)
            self.assertTrue(transfer.exists()); self.assertTrue((objects / 'temporary.o').exists())

    def test_only_own_ci_workspace_and_regular_parents_are_allowed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); transfer, archive, objects = self.fixture(root)
            with patch.dict(os.environ, GITHUB_ACTIONS='false'), self.assertRaisesRegex(ValueError, 'Actions workspace'):
                space.cleanup_native(root)
            objects.rename(objects.with_name('retained'))
            objects.symlink_to(objects.with_name('retained'), target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'symlink'): self.run_cleanup(root)
            self.assertTrue(transfer.exists()); self.assertTrue(archive.exists())

    def test_reserve_is_not_lowered_after_cleanup(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); self.fixture(root)
            with patch.dict(os.environ, GITHUB_ACTIONS='true', GITHUB_WORKSPACE=str(root)), \
                 patch.object(space.subprocess, 'run'), \
                 patch.object(space.shutil, 'disk_usage', return_value=shutil._ntuple_diskusage(100, 20, 39 * 1024**3)), \
                 self.assertRaisesRegex(ValueError, 'available=39.00 GiB'):
                space.cleanup_native(root)


class HostedImageSpaceTests(unittest.TestCase):
    def test_local_and_self_hosted_machines_are_rejected_before_tools_run(self):
        for hosted, actions in [('self-hosted', 'true'), ('github-hosted', 'false')]:
            with patch.dict(os.environ, RUNNER_ENVIRONMENT=hosted, GITHUB_ACTIONS=actions), \
                 patch.object(space.subprocess, 'check_output') as commands, \
                 self.assertRaisesRegex(ValueError, 'hosted device-build workspace'):
                space.cleanup_ci_runtimes(Path.cwd())
            commands.assert_not_called()

    def test_only_identified_idle_images_are_removed_and_sdks_are_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            sdks = {name: root / name for name in ('iphoneos', 'iphonesimulator')}
            for path in sdks.values(): path.mkdir()
            identifier = '12345678-1234-1234-1234-1234567890ab'
            second = '12345678-1234-1234-1234-1234567890ac'
            def output(command, **kwargs):
                if command[1] == '--sdk': return str(sdks[command[2]])
                if 'devices' in command: return json.dumps({'devices': {}})
                return json.dumps({key: {'identifier': key, 'runtimeIdentifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'deletable': True}
                                   for key in (identifier, second)})
            free = [shutil._ntuple_diskusage(100, 80, n * 1024**3) for n in (96, 102, 112, 112)]
            with patch.dict(os.environ, RUNNER_ENVIRONMENT='github-hosted', GITHUB_ACTIONS='true', GITHUB_WORKSPACE=str(root), IRIDIUM_CHROME_SIMULATOR=''), \
                 patch.object(space.subprocess, 'check_output', side_effect=output), \
                 patch.object(space.subprocess, 'run') as remove, \
                 patch.object(space.shutil, 'disk_usage', side_effect=free):
                remove.return_value = subprocess.CompletedProcess([], 0)
                space.cleanup_ci_runtimes(root)
            self.assertEqual([call.args[0] for call in remove.call_args_list],
                             [['xcrun', 'simctl', 'runtime', 'delete', key] for key in (identifier, second)])
            self.assertTrue(all(path.is_dir() for path in sdks.values()))

    def test_bundled_unknown_and_failed_deletions_never_bypass_space_admission(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            sdks = {name: root / name for name in ('iphoneos', 'iphonesimulator')}
            for path in sdks.values(): path.mkdir()
            keys = [f'12345678-1234-1234-1234-1234567890a{n}' for n in range(4)]
            images = {key: {'identifier': key, 'runtimeIdentifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'} for key in keys}
            images[keys[0]]['deletable'] = False
            images[keys[2]]['deletable'] = images[keys[3]]['deletable'] = True
            def output(command, **kwargs):
                if command[1] == '--sdk': return str(sdks[command[2]])
                if 'devices' in command: return json.dumps({'devices': {}})
                return json.dumps(images)
            for available in [39, 60]:
                with patch.dict(os.environ, RUNNER_ENVIRONMENT='github-hosted', GITHUB_ACTIONS='true', GITHUB_WORKSPACE=str(root), IRIDIUM_CHROME_SIMULATOR=''), \
                     patch.object(space.subprocess, 'check_output', side_effect=output), \
                     patch.object(space.subprocess, 'run', side_effect=[subprocess.CompletedProcess([], 2), subprocess.CompletedProcess([], 0)]) as remove, \
                     patch.object(space.shutil, 'disk_usage', return_value=shutil._ntuple_diskusage(200, 100, available * 1024**3)):
                    if available < 40:
                        with self.assertRaisesRegex(ValueError, 'reserve'): space.cleanup_ci_runtimes(root)
                    else:
                        space.cleanup_ci_runtimes(root)
                self.assertEqual([call.args[0][-1] for call in remove.call_args_list], keys[2:])
                self.assertTrue(all(path.is_dir() for path in sdks.values()))

    def test_idle_images_are_best_effort_and_the_stage_reserve_is_required(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            sdks={name:root/name for name in ('iphoneos','iphonesimulator')}
            for path in sdks.values():path.mkdir()
            def output(command, **kwargs):
                if command[1]=='--sdk':return str(sdks[command[2]])
                if 'devices' in command:return json.dumps({'devices':{}})
                return '{}'
            for available in [39, 60]:
                with patch.dict(os.environ,RUNNER_ENVIRONMENT='github-hosted',GITHUB_ACTIONS='true',GITHUB_WORKSPACE=str(root),IRIDIUM_CHROME_SIMULATOR=''), \
                     patch.object(space.shutil,'disk_usage',return_value=shutil._ntuple_diskusage(200,100,available*1024**3)), \
                     patch.object(space.subprocess,'check_output',side_effect=output), \
                     patch.object(space.subprocess,'run') as remove:
                    if available < 40:
                        with self.assertRaisesRegex(ValueError,'reserve'):space.cleanup_ci_runtimes(root)
                    else:space.cleanup_ci_runtimes(root)
                remove.assert_not_called()

    def test_booted_simulator_blocks_removal(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with patch.dict(os.environ, RUNNER_ENVIRONMENT='github-hosted', GITHUB_ACTIONS='true', GITHUB_WORKSPACE=str(root), IRIDIUM_CHROME_SIMULATOR=''), \
                 patch.object(space.shutil, 'disk_usage', return_value=shutil._ntuple_diskusage(100, 80, 22 * 1024**3)), \
                 patch.object(space.subprocess, 'check_output', return_value=json.dumps({'devices': {'runtime': [{'state': 'Booted'}]}})), \
                 patch.object(space.subprocess, 'run') as remove, self.assertRaisesRegex(ValueError, 'simulator is active'):
                space.cleanup_ci_runtimes(root)
            remove.assert_not_called()
