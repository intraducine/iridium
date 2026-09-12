import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from test_manual_build import load

reuse = load('asset_reuse_tests', 'reuse-build-assets.py')


class AssetReuseTests(unittest.TestCase):
    def test_reviewed_action_upgrade_preserves_inputs(self):
        old = 'uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4\nwith:\n  path: source\n'
        new = old.replace('ea165f8d65b6e75b540449e92b4886f43607fa02 # v4',
                          '043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1')
        self.assertEqual(reuse.normalize_source_only_changes(old), reuse.normalize_source_only_changes(new))
        self.assertNotEqual(reuse.normalize_source_only_changes(old), reuse.normalize_source_only_changes(new.replace('path: source', 'path: different')))
        self.assertNotEqual(reuse.normalize_source_only_changes(old), reuse.normalize_source_only_changes(new.replace('043fb46d1a93c77aae656e7c1c64a875d1fc6a0a', 'a' * 40)))
        for stage in ('jit', 'graphics'):
            self.assertNotIn('ci/collect-release-source.py', reuse.COMPONENT_INPUTS[stage])

    def test_native_reuses_app_link_edits_but_rejects_compiler_edits(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '-q')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            git('remote', 'add', 'origin', str(root))
            workflow = root / reuse.WORKFLOW
            workflow.parent.mkdir(parents=True)
            workflow.write_text('jobs:\n  build:\n    runs-on: xcode-27\n    steps:\n      - name: Compile native\n        run: build\n')
            recipe = root / 'ci/prepare-media-sdk.sh'
            recipe.parent.mkdir(parents=True)
            recipe.write_text('compile media')
            app = root / 'iridium/apps/ios/madeira.yml'
            app.parent.mkdir(parents=True)
            app.write_text('app frameworks')
            def commit():
                git('add', '.'); git('commit', '-qm', 'fixture')
            commit()
            original = git('rev-parse', 'HEAD')
            app.write_text('different app frameworks')
            commit()
            reuse.compatible(root, original, 'native')
            recipe.write_text('different compiler flags')
            commit()
            with self.assertRaisesRegex(ValueError, 'producer input'):
                reuse.compatible(root, original, 'native')

    def test_manual_producer_trust_and_success(self):
        run = {'event': 'workflow_dispatch', 'head_branch': 'feature',
               'head_sha': 'a' * 40, 'path': reuse.WORKFLOW,
               'head_repository': {'full_name': reuse.REPO}}
        jobs = [{'name': 'media', 'conclusion': 'success'}]
        self.assertEqual(reuse.validate(run, jobs, 'media', 'feature'), 'a' * 40)
        for field, value in [('event', 'pull_request'), ('head_branch', 'other'),
                             ('head_repository', {'full_name': 'other/repo'}),
                             ('head_sha', 'bad'), ('path', 'other.yml')]:
            with self.assertRaises(ValueError):
                reuse.validate(dict(run, **{field: value}), jobs, 'media', 'feature')
        with self.assertRaises(ValueError):
            reuse.validate(run, [], 'media', 'feature')

    def test_input_and_producer_changes_invalidate_but_ui_does_not(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '-q')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            git('remote', 'add', 'origin', str(root))
            for name in reuse.MEDIA_INPUTS:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('original')
            workflow = root / reuse.WORKFLOW
            workflow.parent.mkdir(parents=True, exist_ok=True)
            workflow.write_text('jobs:\n  media:\n    runs-on: xcode-27\n    steps:\n      - run: build\n  build:\n    runs-on: xcode-27\n')
            def commit():
                git('add', '.'); git('commit', '-qm', 'fixture')
            commit()
            original = git('rev-parse', 'HEAD')
            (root / 'UI.swift').write_text('UI edit')
            workflow.write_text(workflow.read_text().replace('  media:\n', '  media:\n    needs: asset-plan\n    if: condition\n'))
            commit()
            reuse.compatible(root, original, 'media')
            self.assertNotEqual(reuse.producer_job(workflow.read_text(), 'media'),
                                reuse.producer_job('env:\n  CFLAGS: changed\n' + workflow.read_text(), 'media'))
            workflow.write_text(workflow.read_text().replace('xcode-27', 'xcode-28'))
            commit()
            with self.assertRaisesRegex(ValueError, 'workflow'):
                reuse.compatible(root, original, 'media')
            (root / reuse.MEDIA_INPUTS[0]).write_text('different recipe')
            commit()
            with self.assertRaisesRegex(ValueError, 'input'):
                reuse.compatible(root, original, 'media')

    def test_expired_artifact_and_failed_explicit_selection_are_rejected(self):
        run = {'event': 'workflow_dispatch', 'head_branch': 'main',
               'head_sha': 'a' * 40, 'path': reuse.WORKFLOW,
               'head_repository': {'full_name': reuse.REPO}}
        responses = [run, {'jobs': [{'name': 'media', 'conclusion': 'success'}]},
                     {'artifacts': [{'name': 'media-sdk-with-source', 'expired': True}]}]
        with patch.object(reuse, 'api', side_effect=responses):
            with self.assertRaisesRegex(ValueError, 'expired'):
                reuse.verify_producer(Path('.'), '123', 'media', 'main')
        with patch.object(reuse, 'verify_producer', side_effect=ValueError('mismatch')):
            with self.assertRaises(ValueError):
                reuse.select(Path('.'), 'media', 'main', '123')
