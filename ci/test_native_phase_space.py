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
