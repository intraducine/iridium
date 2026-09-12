import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import load

repair = load('source_repair', 'repair-release-source.py')


def archive_bytes(files):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w:gz') as archive:
        for name, content in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
    return stream.getvalue()


class RepairTests(unittest.TestCase):
    def test_cerbero_repair_preserves_executable_mode_and_existing_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            for name in ('recipes', 'packages', 'config', 'tools'):
                (source / name).mkdir(parents=True)
            launcher = source / 'cerbero-uninstalled'
            launcher.write_bytes(b'launcher')
            launcher.chmod(0o755)
            target = root / 'cerbero.tar.xz'
            with tarfile.open(target, 'w:xz') as archive:
                member = tarfile.TarInfo('cerbero-1.28.6/original')
                member.size = 4
                archive.addfile(member, io.BytesIO(b'keep'))
            self.assertEqual(repair.repair_cerbero(target, source, []), 1)
            with tarfile.open(target) as archive:
                self.assertEqual(archive.extractfile('cerbero-1.28.6/original').read(), b'keep')
                self.assertEqual(archive.getmember('cerbero-1.28.6/cerbero-uninstalled').mode, 0o755)
            self.assertEqual(repair.repair_cerbero(target, source, []), 0)

    def test_missing_source_repaired_and_bad_download_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'idevice.tar.gz'
            crate = archive_bytes({'cc-1.0/src/target/apple.rs': b'source'})
            original = archive_bytes({
                'vendor/cc/Cargo.toml': b'[package]\nname="cc"\nversion="1.0"',
                'vendor/cc/.cargo-checksum.json': json.dumps({
                    'package': hashlib.sha256(crate).hexdigest(),
                    'files': {'src/target/apple.rs': hashlib.sha256(b'source').hexdigest()}
                }).encode()})
            path.write_bytes(original)
            with patch.object(repair.urllib.request, 'urlopen', return_value=io.BytesIO(b'wrong')):
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    repair.repair_cargo(path)
            self.assertEqual(path.read_bytes(), original)
            with patch.object(repair.urllib.request, 'urlopen', return_value=io.BytesIO(crate)):
                self.assertEqual(repair.repair_cargo(path), 1)
            with tarfile.open(path) as archive:
                self.assertEqual(archive.extractfile('vendor/cc/src/target/apple.rs').read(), b'source')
            self.assertEqual(repair.repair_cargo(path), 0)
