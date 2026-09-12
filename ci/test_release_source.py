import hashlib
import io
import json
import tempfile
from unittest.mock import patch
from pathlib import Path
import tarfile
import unittest
from test_manual_build import load

source = load('release_source', 'collect-release-source.py')

class SourceTests(unittest.TestCase):
    def test_media_rust_registry_sources_are_verified(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            data = b'crate source'
            lock = ('[[package]]\nname="object"\nversion="0.37.3"\n'
                    'source="registry+https://github.com/rust-lang/crates.io-index"\n'
                    'checksum="' + hashlib.sha256(data).hexdigest() + '"\n').encode()
            with tarfile.open(root / 'media-rust-src-1.96.0.tar.xz', 'w:xz') as archive:
                member = tarfile.TarInfo('rust-src/lib/rust/library/Cargo.lock')
                member.size = len(lock)
                archive.addfile(member, io.BytesIO(lock))
            directory = root / 'media-rust-dependencies'
            directory.mkdir()
            crate = directory / 'object-0.37.3.crate'
            crate.write_bytes(data)
            with patch.object(source, 'OUT', root):
                source.collect_rust_dependencies('media-rust-src-1.96.0.tar.xz', 'media-rust-dependencies')
                crate.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    source.collect_rust_dependencies('media-rust-src-1.96.0.tar.xz', 'media-rust-dependencies')

    def test_restored_vendor_source_cannot_omit_checksummed_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            checksum = json.dumps({'files': {'src/target/apple.rs': 'missing'}}).encode()
            with tarfile.open(root / 'idevice.tar.gz', 'w:gz') as archive:
                member = tarfile.TarInfo('vendor/cc/.cargo-checksum.json')
                member.size = len(checksum)
                archive.addfile(member, io.BytesIO(checksum))
            with patch.object(source, 'OUT', root):
                with self.assertRaisesRegex(ValueError, 'incomplete'):
                    source.check_restored_sources()

    def test_moltenvk_source_checks_cached_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'ci').mkdir()
            payload = root / 'media-MoltenVK.tar.gz'
            payload.write_bytes(b'verified source')
            (root / 'ci/moltenvk-source-inputs.json').write_text(json.dumps([{
                'name': 'MoltenVK', 'sha256': hashlib.sha256(payload.read_bytes()).hexdigest()}]))
            with patch.object(source, 'ROOT', root), patch.object(source, 'OUT', root):
                source.collect_moltenvk()
                payload.write_bytes(b'corrupt')
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    source.collect_moltenvk()

    def test_media_rust_source_fails_closed_on_changed_pin_or_payload(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'ci').mkdir()
            inputs = root / 'ci/runtime-inputs.json'
            inputs.write_text(json.dumps([{'name': 'cerbero-source', 'sha256': 'changed'}]))
            with patch.object(source, 'ROOT', root), patch.object(source, 'OUT', root):
                with self.assertRaisesRegex(ValueError, 'new Cerbero'):
                    source.collect_media_rust()
                inputs.write_text(json.dumps([{'name': 'cerbero-source', 'sha256':
                    '1874c5ed8b67612ca0370e5a8c7b25420ed98f0176425aa427eb1461293a82d3'}]))
                (root / 'media-rust-src-1.96.0.tar.xz').write_bytes(b'corrupt')
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    source.collect_media_rust()

    def test_nested_target_source_and_verified_vendor_fixture_survive(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            tree = root / 'source'
            crate = tree / 'vendor/cc'
            (crate / 'src/target').mkdir(parents=True)
            (crate / 'src/target/apple.rs').write_text('source')
            (tree / 'target').mkdir()
            (tree / 'target/output').write_text('build output')
            fixture = crate / 'fixture.a'
            fixture.write_bytes(b'upstream fixture')
            (crate / '.cargo-checksum.json').write_text(json.dumps({
                'files': {'fixture.a': hashlib.sha256(fixture.read_bytes()).hexdigest()}}))
            output = root / 'source.tar.gz'
            source.source_tree(tree, output)
            with tarfile.open(output) as archive:
                self.assertIn('vendor/cc/src/target/apple.rs', archive.getnames())
                self.assertIn('vendor/cc/fixture.a', archive.getnames())
                self.assertNotIn('target/output', archive.getnames())
            fixture.write_bytes(b'changed')
            with self.assertRaises(ValueError):
                source.source_tree(tree, output)

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
