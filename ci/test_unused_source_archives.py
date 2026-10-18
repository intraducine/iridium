"""Unused upstream binaries cannot excuse changed inputs or private material."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import load

ROOT = Path(__file__).resolve().parents[1]
COLLECT = load('unused_archive_source_collect', 'collect-madeira-source.py')
NAME = 'vendor/PPSSPP/ffmpeg/Windows/libavcodec.a'


class UnusedSourceArchiveTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'ci').mkdir()
        (self.root / 'ci/public-signing-fixtures.json').write_text('{}')
        shutil.copy2(ROOT / 'check-public-source.py', self.root)

    def record(self, data):
        record = {'sha256': hashlib.sha256(data).hexdigest(), 'source': 'public upstream', 'reason': 'unused binary'}
        (self.root / 'ci/public-unused-archives.json').write_text(json.dumps({NAME: record}))
        return record

    def write(self, base, data):
        path = base / NAME; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
        return path

    def test_collector_removes_exact_bytes_and_retains_codec_source(self):
        data = b'reviewed public archive'; record = self.record(data)
        original = self.write(self.root, data); stage = self.root / 'stage'
        staged = self.write(stage, data)
        codec = staged.parents[1] / 'libavcodec/h264.c'; codec.parent.mkdir(); codec.write_text('codec source')
        with patch.object(COLLECT, 'ROOT', self.root):
            self.assertEqual(COLLECT.exclude_unused_archives(stage), [{'path': NAME, **record}])
        self.assertFalse(staged.exists()); self.assertEqual(original.read_bytes(), data)
        self.assertEqual(codec.read_text(), 'codec source')
        staged = self.write(stage, b'changed archive')
        with patch.object(COLLECT, 'ROOT', self.root), self.assertRaises(ValueError):
            COLLECT.exclude_unused_archives(stage)
        self.assertTrue(staged.exists())

    def test_large_archive_requires_exact_hash_and_still_gets_private_scan(self):
        data = b'public archive\n' + bytes(50 * 1024 * 1024)
        self.record(data); path = self.write(self.root, data)
        def scan():
            return subprocess.run([sys.executable, '-B', str(self.root / 'check-public-source.py')], capture_output=True, text=True)
        self.assertEqual(scan().returncode, 0)
        with path.open('ab') as stream: stream.write(b'changed')
        result = scan(); self.assertEqual(result.returncode, 1); self.assertIn('large file', result.stdout)
        data = b'-----BEGIN ' + b'PRIVATE KEY-----\n' + bytes(50 * 1024 * 1024)
        self.record(data); self.write(self.root, data)
        result = scan(); self.assertEqual(result.returncode, 1); self.assertIn('private key', result.stdout)


if __name__ == '__main__': unittest.main()
