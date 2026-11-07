"""A pinned patch must not edit a developer's checkout or index during validation."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import madeira_managed_patches


class ManagedPatchTests(unittest.TestCase):
    def test_expected_bytes_leave_local_edits_and_index_intact(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch); repo = root / 'FEX'; repo.mkdir()
            def git(*args): return subprocess.check_output(['git', '-C', str(repo), *args])
            git('init', '-q'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid')
            file = repo / 'unit.cpp'; file.write_text('base\n'); git('add', '.'); git('commit', '-qm', 'base')
            patches = root / 'build/fex-patches'; patches.mkdir(parents=True)
            file.write_text('patched\n'); (patches / '001.patch').write_bytes(git('diff'))
            file.write_text('user edit\n'); index = git('write-tree')
            self.assertEqual(madeira_managed_patches.expected(root, 'FEX'), {'unit.cpp': b'patched\n'})
            self.assertEqual(file.read_text(), 'user edit\n')
            self.assertEqual(git('write-tree'), index)
            (patches / '001.patch').write_text('invalid patch')
            with self.assertRaises(subprocess.CalledProcessError): madeira_managed_patches.expected(root, 'FEX')
            self.assertEqual(file.read_text(), 'user edit\n')
