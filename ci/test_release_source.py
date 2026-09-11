import hashlib
import tempfile
from unittest.mock import patch
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

    def test_only_exact_public_fixture_bytes_are_allowed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            tree = root / 'source'
            fixture = tree / 'vendor/openssl/test/identity.p12'
            fixture.parent.mkdir(parents=True)
            fixture.write_bytes(b'public test fixture')
            pins = {str(fixture.relative_to(tree)): hashlib.sha256(fixture.read_bytes()).hexdigest()}
            with patch.object(source, 'PUBLIC_TEST_FIXTURES', pins):
                source.source_tree(tree, root / 'source.tar.gz')
                fixture.write_bytes(b'different signing data')
                with self.assertRaises(ValueError):
                    source.source_tree(tree, root / 'source.tar.gz')
