import json
import unittest
from pathlib import Path
from unittest.mock import patch
from test_manual_build import load

reuse = load('linux_reuse', 'verify-linux-reuse.py')

class LinuxReuseTests(unittest.TestCase):
    def test_only_verified_main_producer_is_accepted(self):
        revision = 'a' * 40
        run = {'event': 'workflow_dispatch', 'head_branch': 'main', 'head_sha': revision,
               'path': '.github/workflows/build-unsigned-ipa.yml',
               'head_repository': {'full_name': reuse.REPO}}
        jobs = [{'name': 'linux-userland', 'conclusion': 'success'}]
        reuse.validate_run(run, jobs, revision)
        for key, value in [('event', 'pull_request'), ('head_branch', 'untrusted'),
                           ('head_sha', 'b' * 40), ('path', 'other.yml'),
                           ('head_repository', {'full_name': 'other/iridium'})]:
            with self.assertRaises(ValueError):
                reuse.validate_run(dict(run, **{key: value}), jobs, revision)
        with self.assertRaises(ValueError):
            reuse.validate_run(run, [{'name': 'linux-userland', 'conclusion': 'failure'}], revision)

    def test_current_branch_manual_producer_is_accepted(self):
        revision = 'a' * 40
        run = {'event': 'workflow_dispatch', 'head_branch': 'feature', 'head_sha': revision,
               'path': '.github/workflows/build-unsigned-ipa.yml',
               'head_repository': {'full_name': reuse.REPO}}
        jobs = [{'name': 'linux-userland', 'conclusion': 'success'}]
        reuse.validate_run(run, jobs, revision, 'feature')
        with self.assertRaises(ValueError):
            reuse.validate_run(run, jobs, revision, 'different-branch')
        reuse.validate_run(run, jobs, revision, 'different-branch', allow_other_branch=True)

    def test_merged_branch_revision_must_be_an_ancestor(self):
        revision = 'a' * 40
        current = 'b' * 40
        comparison = json.dumps({'merge_base_commit': {'sha': revision}})
        with patch.object(reuse.subprocess, 'check_output', side_effect=[current, comparison]):
            self.assertTrue(reuse.producer_revision_is_ancestor(Path('.'), revision))
        comparison = json.dumps({'merge_base_commit': {'sha': 'c' * 40}})
        with patch.object(reuse.subprocess, 'check_output', side_effect=[current, comparison]):
            self.assertFalse(reuse.producer_revision_is_ancestor(Path('.'), revision))


class UserlandStageTests(unittest.TestCase):
    def test_archive_extracts_atomically_and_rejects_escape_or_overwrite(self):
        import io
        import tarfile
        import tempfile
        from unittest.mock import patch
        stage = load('stage_linux_userland', 'stage-linux-userland.py')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / 'test.tar'
            def contents(escape=False):
                with tarfile.open(archive, 'w') as tar:
                    for name in ('bin/wineserver', 'share/wine/nls/l_intl.nls'):
                        member = tarfile.TarInfo(name)
                        member.size = 4
                        tar.addfile(member, io.BytesIO(b'data'))
                    if escape:
                        member = tarfile.TarInfo('escape')
                        member.type = tarfile.SYMTYPE
                        member.linkname = '../../outside'
                        tar.addfile(member)
            def decompress(command, stdout, check):
                stdout.write(archive.read_bytes())
            target = root / 'extracted'
            contents(True)
            with patch.object(stage.subprocess, 'run', side_effect=decompress):
                with self.assertRaises(tarfile.FilterError):
                    stage.extract(archive, target)
                self.assertFalse(target.exists())
                contents()
                stage.extract(archive, target)
                self.assertEqual((target / 'bin/wineserver').read_bytes(), b'data')
                with self.assertRaises(ValueError):
                    stage.extract(archive, target)
