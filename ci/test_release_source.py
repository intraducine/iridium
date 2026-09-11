import tempfile
from pathlib import Path
import tarfile
import unittest
from test_manual_build import load

source = load('release_source', 'collect-release-source.py')

class SourceTests(unittest.TestCase):
    def test_source_archive_excludes_vendor_binary_and_rejects_signing_or_escape(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            tree = root / 'source'
            tree.mkdir()
            (tree / 'LICENSE').write_text('fixture license')
            (tree / 'ffi.a').write_bytes(b'opaque archive')
            out = root / 'source.tar.gz'
            source.source_tree(tree, out)
            with tarfile.open(out) as archive:
                self.assertEqual(archive.getnames(), ['LICENSE'])
            (tree / 'signing.p12').write_bytes(b'fixture')
            with self.assertRaises(ValueError):
                source.source_tree(tree, out)
            (tree / 'signing.p12').unlink()
            (tree / 'escape').symlink_to(root / 'private')
            with self.assertRaises(ValueError):
                source.source_tree(tree, out)
            with self.assertRaises(ValueError):
                source.source_tree(root / 'missing', out)
