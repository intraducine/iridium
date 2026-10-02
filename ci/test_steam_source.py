import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('steam_source', Path(__file__).with_name('collect-steam-source.py'))
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class SteamSourceTests(unittest.TestCase):
    def test_rejects_unpinned_or_escaping_inputs_without_network(self):
        for item in [dict(name='test', repository='owner/repo', revision='main'),
                     dict(name='../escape', repository='owner/repo', revision='a' * 40),
                     dict(name='test', repository='../repo', revision='a' * 40)]:
            with tempfile.TemporaryDirectory() as temp, patch.object(collector, 'ROOT', Path(temp)):
                root = Path(temp)
                (root / 'ci').mkdir()
                (root / 'ci/steam-source-inputs.json').write_text(json.dumps([item]))
                with patch.object(collector.urllib.request, 'urlopen') as network:
                    with self.assertRaises(ValueError):
                        collector.collect()
                    network.assert_not_called()

    def test_reuses_verified_archive_and_rejects_changed_cache(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(collector, 'ROOT', Path(temp)):
            root = Path(temp)
            (root / 'ci').mkdir()
            (root / 'ci/patches').mkdir()
            (root / 'ci/patches/steamkit-ios-process-start.patch').write_text('fixture patch')
            (root / 'ci/prepare-steamkit.py').write_text('# fixture recipe')
            item = dict(name='fixture', repository='owner/repo', revision='a' * 40)
            (root / 'ci/steam-source-inputs.json').write_text(json.dumps([item]))
            package = root / 'iridium/packages/steam'
            (package / 'Iridium.Steam').mkdir(parents=True)
            (package / 'THIRD-PARTY-NOTICES.md').write_text('Fixture')
            (package / 'Iridium.Steam/packages.lock.json').write_text('{}')
            output = root / '.build/corresponding-source/steam'
            output.mkdir(parents=True)
            archive = output / ('fixture-' + 'a' * 40 + '.tar.gz')
            with tarfile.open(archive, 'w:gz') as tar:
                member = tarfile.TarInfo('repo-' + 'a' * 40)
                member.type = tarfile.DIRTYPE
                tar.addfile(member)
            archive.with_suffix('.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest())
            with patch.object(collector.urllib.request, 'urlopen') as network:
                collector.collect()
                self.assertEqual(json.loads((output / 'sources.json').read_text())[0]['revision'], 'a' * 40)
                self.assertEqual((output / 'steamkit-ios-process-start.patch').read_text(), 'fixture patch')
                self.assertTrue((output / 'prepare-steamkit.py').is_file())
                network.assert_not_called()
                archive.write_bytes(b'corrupt')
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    collector.collect()


if __name__ == '__main__':
    unittest.main()
