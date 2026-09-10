import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import ROOT, load

inputs = load("runtime_inputs", "fetch-runtime-inputs.py")


class RuntimeInputTests(unittest.TestCase):
    def test_locked_inputs_and_preparation_order(self):
        entries = json.loads((ROOT / "ci/runtime-inputs.json").read_text())
        self.assertEqual(len({entry['destination'] for entry in entries}), len(entries))
        for entry in entries:
            inputs.destination(ROOT, entry)
        bad = dict(entries[0], destination="../outside")
        with self.assertRaises(ValueError):
            inputs.destination(ROOT, bad)
        workflow = (ROOT / '.github/workflows/build-unsigned-ipa.yml').read_text()
        self.assertLess(workflow.index('ci/prepare-native-runtime.sh'), workflow.index('ci/check-ipa-prerequisites.py'))
        self.assertNotIn('/tmp/iridium-media-sdk', (ROOT / 'iridium/apps/ios/madeira.yml').read_text())

    def test_digest_failure_and_unsafe_archive_leave_no_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            entry = {'name': 'fixture', 'sha256': '0' * 64, 'url': 'https://example.invalid/source', 'destination': 'source'}
            with patch.object(inputs.urllib.request, 'urlopen', return_value=io.BytesIO(b'wrong')):
                with self.assertRaises(ValueError):
                    inputs.fetch(root, entry)
            self.assertFalse((root / 'source').exists())
            self.assertEqual(list((root / '.build/runtime-downloads').iterdir()), [])
            archive = root / 'test.tar'
            with tarfile.open(archive, 'w') as tar:
                member = tarfile.TarInfo('top/escape')
                member.type = tarfile.SYMTYPE
                member.linkname = '../../outside'
                tar.addfile(member)
            with self.assertRaises(tarfile.FilterError):
                inputs.unpack(archive, root / 'source', 'top')
            self.assertFalse((root / 'source').exists())
            with tarfile.open(archive, 'w') as tar:
                member = tarfile.TarInfo('top/README')
                member.size = 2
                tar.addfile(member, io.BytesIO(b'ok'))
            inputs.unpack(archive, root / 'source', 'top')
            self.assertEqual((root / 'source/README').read_text(), 'ok')
            with self.assertRaises(ValueError):
                inputs.unpack(archive, root / 'source', 'top')


if __name__ == '__main__':
    unittest.main()
