"""Corresponding source must remain available after native output reuse."""
from pathlib import Path
import os
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import load

source = load('madeira_source_tests', 'collect-madeira-source.py')


class MadeiraSourceTests(unittest.TestCase):
    def git(self, repo, *args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()

    def init_repo(self, repo):
        repo.mkdir(parents=True)
        self.git(repo, 'init', '-q')
        self.git(repo, 'config', 'user.name', 'Test')
        self.git(repo, 'config', 'user.email', 'test@example.invalid')

    def commit(self, repo, *paths):
        if paths: self.git(repo, 'add', *paths)
        self.git(repo, 'commit', '-qm', 'source fixture')
        return self.git(repo, 'rev-parse', 'HEAD')

    def recursive_repo(self, folder, target, *, include_target=True):
        repo = folder / 'repo'
        self.init_repo(repo)
        (repo / 'README').write_bytes(b'frontend source\n')
        flycast = repo / 'vendor/Flycast'
        self.init_repo(flycast)
        oboe = flycast / 'core/deps/oboe'
        self.init_repo(oboe)
        proto = oboe / 'games-performance-tuner/proto'
        proto.mkdir(parents=True)
        (proto / 'descriptor.proto').symlink_to(target)
        (proto / 'tuner.proto').write_bytes(b'tuner source\n')
        oboe_revision = self.commit(oboe, 'games-performance-tuner')
        if include_target:
            descriptor = flycast / 'core/deps/external/protobuf/src/google/protobuf/descriptor.proto'
            descriptor.parent.mkdir(parents=True)
            descriptor.write_bytes(b'protobuf source\n')
            self.git(flycast, 'add', 'core/deps/external')
        self.git(flycast, 'update-index', '--add', '--cacheinfo',
                 f'160000,{oboe_revision},core/deps/oboe')
        flycast_revision = self.commit(flycast)
        self.git(repo, 'update-index', '--add', '--cacheinfo',
                 f'160000,{flycast_revision},vendor/Flycast')
        revision = self.commit(repo, 'README')
        revisions = {'.': revision, 'vendor/Flycast': flycast_revision,
                     'vendor/Flycast/core/deps/oboe': oboe_revision}
        return repo, (proto / 'descriptor.proto').relative_to(repo), revisions

    def test_recursive_snapshot_preserves_sibling_source_symlink(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            target = '../../../external/protobuf/src/google/protobuf/descriptor.proto'
            repo, name, expected = self.recursive_repo(root, target)
            stage = root / 'stage'
            revisions = {}
            with patch.object(source, 'ROOT', repo):
                source.snapshot(repo, stage, revisions)
            link = stage / name
            self.assertTrue(link.is_symlink())
            self.assertEqual(os.readlink(link), target)
            self.assertEqual(link.read_bytes(), b'protobuf source\n')
            self.assertEqual((link.parent / 'tuner.proto').read_bytes(), b'tuner source\n')
            self.assertEqual((stage / 'README').read_bytes(), b'frontend source\n')
            self.assertEqual(revisions, expected)

    def test_recursive_snapshot_preserves_dangling_symlink_inside_source_root(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            target = '../../../external/protobuf/src/google/protobuf/descriptor.proto'
            repo, name, expected = self.recursive_repo(root, target, include_target=False)
            stage = root / 'stage'
            revisions = {}
            with patch.object(source, 'ROOT', repo):
                source.snapshot(repo, stage, revisions)
            link = stage / name
            self.assertTrue(link.is_symlink())
            self.assertEqual(os.readlink(link), target)
            self.assertFalse(link.exists())
            self.assertEqual((link.parent / 'tuner.proto').read_bytes(), b'tuner source\n')
            self.assertEqual(revisions, expected)

    def test_recursive_snapshot_rejects_symlinks_outside_source_root(self):
        for kind in ('absolute', 'traversal'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                outside = root / 'outside'
                outside.mkdir()
                sentinel = outside / 'sentinel'
                sentinel.write_bytes(b'preserve outside source\n')
                stage = root / 'stage'
                proto = stage / 'vendor/Flycast/core/deps/oboe/games-performance-tuner/proto'
                target = str(sentinel) if kind == 'absolute' else os.path.relpath(sentinel, proto)
                repo, name, _ = self.recursive_repo(root, target)
                with patch.object(source, 'ROOT', repo), self.assertRaises(tarfile.FilterError):
                    source.snapshot(repo, stage, {})
                self.assertFalse((stage / name).is_symlink())
                self.assertEqual(sentinel.read_bytes(), b'preserve outside source\n')

    def test_snapshot_rejects_archive_path_through_symlinked_ancestor(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            repo = root / 'repo'
            self.init_repo(repo)
            (repo / 'sentinel').write_bytes(b'archive replacement\n')
            self.commit(repo, 'sentinel')
            outside = root / 'outside/Flycast'
            outside.mkdir(parents=True)
            sentinel = outside / 'sentinel'
            sentinel.write_bytes(b'preserve outside source\n')
            stage = root / 'stage'
            stage.mkdir()
            (stage / 'vendor').symlink_to(outside.parent, target_is_directory=True)
            with patch.object(source, 'ROOT', repo), self.assertRaises(tarfile.FilterError):
                source.snapshot(repo, stage / 'vendor/Flycast', {}, source_root=stage)
            self.assertEqual(sentinel.read_bytes(), b'preserve outside source\n')

    def test_snapshot_rejects_destination_outside_supplied_source_root(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            repo = root / 'repo'
            self.init_repo(repo)
            (repo / 'sentinel').write_bytes(b'archive replacement\n')
            self.commit(repo, 'sentinel')
            outside = root / 'outside'
            outside.mkdir()
            sentinel = outside / 'sentinel'
            sentinel.write_bytes(b'preserve outside source\n')
            stage = root / 'stage'
            for destination in (outside, stage / '../outside'):
                with self.subTest(destination=destination), patch.object(source, 'ROOT', repo):
                    revisions = {}
                    with self.assertRaises(ValueError):
                        source.snapshot(repo, destination, revisions, source_root=stage)
                    self.assertEqual(revisions, {})
                    self.assertEqual(sentinel.read_bytes(), b'preserve outside source\n')

    def test_supplemental_freetype_uses_supplied_source_root(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            upstream = root / 'vendor/Madeira'
            repo = upstream / 'research/freetype'
            self.init_repo(repo)
            (repo / 'font.c').write_bytes(b'font source\n')
            (repo / 'shared.c').symlink_to('../shared.c')
            revision = self.commit(repo, 'font.c', 'shared.c')
            stage = root / 'stage'
            destination = stage / repo.relative_to(root)
            destination.parent.mkdir(parents=True)
            (destination.parent / 'shared.c').write_bytes(b'shared source\n')
            revisions = {}
            with patch.object(source, 'ROOT', root), patch.object(source.build, 'UPSTREAM', upstream), \
                 patch.object(source, 'FREETYPE_REVISION', revision):
                source.snapshot_freetype(destination, revisions, source_root=stage)
            self.assertEqual((destination / 'font.c').read_bytes(), b'font source\n')
            self.assertEqual(os.readlink(destination / 'shared.c'), '../shared.c')
            self.assertEqual((destination / 'shared.c').read_bytes(), b'shared source\n')
            self.assertEqual(revisions, {repo.relative_to(root).as_posix(): revision})

    def test_fetch_failure_stops_source_collection(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            revisions = {}
            destination = root / 'stage'
            with patch.object(source, 'ROOT', root), \
                 patch.object(source.build, 'UPSTREAM', root / 'vendor/Madeira'), \
                 patch.object(source.subprocess, 'run', side_effect=subprocess.CalledProcessError(128, 'git clone')), \
                 patch.object(source, 'snapshot') as snapshot:
                with self.assertRaises(subprocess.CalledProcessError):
                    source.snapshot_freetype(destination, revisions)
                snapshot.assert_not_called()
            self.assertEqual(revisions, {})
            self.assertFalse(destination.exists())

    def test_cached_native_build_fetches_missing_source_and_preserves_audit_checks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            producer = root / 'producer'
            producer.mkdir()
            def git(repo, *args):
                return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()
            git(producer, 'init', '-q')
            git(producer, 'config', 'user.name', 'Test')
            git(producer, 'config', 'user.email', 'test@example.invalid')
            (producer / 'source.c').write_text('pinned source\n')
            git(producer, 'add', '.'); git(producer, 'commit', '-qm', 'source fixture')
            revision = git(producer, 'rev-parse', 'HEAD')
            upstream = root / 'vendor/Madeira'
            upstream.mkdir(parents=True)
            freetype = upstream / 'research/freetype'
            name = freetype.relative_to(root).as_posix()
            revisions = {}
            run = subprocess.run
            def clone(command, **kwargs):
                if command[:2] != ['git', 'clone']: return run(command, **kwargs)
                self.assertEqual(command, ['git', 'clone', '--depth', '1', '--branch', 'VER-2-13-3',
                    'https://github.com/freetype/freetype.git', str(freetype)])
                return run(['git', 'clone', '--quiet', '--no-hardlinks', str(producer), str(freetype)], **kwargs)
            with patch.object(source, 'ROOT', root), patch.object(source.build, 'UPSTREAM', upstream), \
                 patch.object(source, 'FREETYPE_REVISION', revision):
                with patch.object(source.subprocess, 'run', side_effect=clone) as fetch:
                    # Only cloning is redirected; snapshot uses real Git and tar extraction.
                    source.snapshot_freetype(root / 'stage', revisions)
                    self.assertEqual(sum(call.args[0][:2] == ['git', 'clone'] for call in fetch.call_args_list), 1)
                self.assertEqual(revisions[name], revision)
                self.assertEqual((root / 'stage/source.c').read_text(), 'pinned source\n')
                with patch.object(source.subprocess, 'run', wraps=run) as fetch:
                    source.snapshot_freetype(root / 'again', {})
                    self.assertFalse(any(call.args[0][:2] == ['git', 'clone'] for call in fetch.call_args_list))
                (freetype / 'source.c').write_text('local change\n')
                with self.assertRaisesRegex(ValueError, 'Commit source changes'):
                    source.snapshot_freetype(root / 'dirty', {})
                git(freetype, 'config', 'user.name', 'Test')
                git(freetype, 'config', 'user.email', 'test@example.invalid')
                git(freetype, 'add', '.'); git(freetype, 'commit', '-qm', 'changed source')
                with self.assertRaisesRegex(ValueError, 'Unexpected FreeType revision'):
                    source.snapshot_freetype(root / 'wrong', {})
