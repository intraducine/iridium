from pathlib import Path
import tempfile
import tarfile
import unittest
from test_manual_build import load

space = load('reclaim_build_space', 'reclaim-build-space.py')


class BuildSpaceTests(unittest.TestCase):
    def test_source_archive_preserves_layout_without_duplicate_disk_copy(self):
        collector = load('source_archive_space_test', 'collect-release-source.py')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, debian = root / 'source', root / 'debian'
            source.mkdir()
            debian.mkdir()
            (source / 'iridium.tar.gz').write_bytes(b'app source')
            (debian / 'wine.source').write_bytes(b'linux source')
            output = root / 'release.tar.gz'
            collector.package_sources(source, debian, output)
            with tarfile.open(output) as archive:
                self.assertEqual(archive.extractfile('corresponding-source/iridium.tar.gz').read(), b'app source')
                self.assertEqual(archive.extractfile('corresponding-source/linux/wine.source').read(), b'linux source')
            self.assertFalse((source / 'linux').exists())
            self.assertEqual((debian / 'wine.source').read_bytes(), b'linux source')
            (source / 'linux').mkdir()
            with self.assertRaises(ValueError):
                collector.package_sources(source, debian, output)

    def test_linked_transfer_parent_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            outside = root / 'outside'
            outside.mkdir()
            (outside / 'compiled.tar.gz').write_bytes(b'keep')
            (root / '.build').mkdir()
            link = (root / space.TRANSFERS[0]).parent
            try:
                link.symlink_to(outside, target_is_directory=True)
            except OSError:
                self.skipTest('Creating symlinks is not supported on this host')
            with self.assertRaises(ValueError):
                space.reclaim(root, 'prepare-source')
            self.assertEqual((outside / 'compiled.tar.gz').read_bytes(), b'keep')

    def test_only_consumed_copies_are_removed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            kept = ('.build/corresponding-source/source.tar.gz',
                    '.build/linux-transfer/sources/source.tar.gz',
                    'iridium/apps/ios/Frameworks/IridiumSteam.xcframework/binary',
                    '.build/ipa-output/SOURCE-SHA256SUMS')
            for name in (*space.TRANSFERS, space.SOURCE_OUTPUT, *kept):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'fixture')
            space.reclaim(root, 'prepare-source')
            self.assertTrue(all(not (root / name).exists() for name in space.TRANSFERS))
            self.assertTrue((root / space.SOURCE_OUTPUT).is_file())
            self.assertTrue(all((root / name).is_file() for name in kept))
            space.reclaim(root, 'source-uploaded')
            self.assertFalse((root / space.SOURCE_OUTPUT).exists())
            self.assertTrue(all((root / name).is_file() for name in kept))

    def test_wrong_output_type_fails_before_any_deletion(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            first, last = (root / name for name in (space.TRANSFERS[0], space.TRANSFERS[-1]))
            first.parent.mkdir(parents=True)
            first.write_bytes(b'keep')
            last.mkdir(parents=True)
            with self.assertRaises(ValueError):
                space.reclaim(root, 'prepare-source')
            self.assertEqual(first.read_bytes(), b'keep')

    def test_workflow_reclaims_only_after_consumption_and_upload(self):
        text = (space.ROOT / '.github/workflows/build-unsigned-ipa.yml').read_text()
        self.assertLess(text.index('run: bash ci/prepare-legacy-bundle.sh'),
                        text.index('reclaim-build-space.py prepare-source'))
        self.assertLess(text.index('name: Retain source archive for release audit'),
                        text.index('reclaim-build-space.py source-uploaded'))
        self.assertLess(text.index('reclaim-build-space.py source-uploaded'),
                        text.index('name: Build without signing'))
