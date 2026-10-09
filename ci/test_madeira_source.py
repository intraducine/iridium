"""Corresponding source must remain available after native output reuse."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import load

source = load('madeira_source_tests', 'collect-madeira-source.py')


class MadeiraSourceTests(unittest.TestCase):
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
