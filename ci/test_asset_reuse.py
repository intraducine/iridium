import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from test_manual_build import load

reuse = load('asset_reuse_tests', 'reuse-build-assets.py')
local = load('local_runtime_media_reuse_tests', 'prepare-local-runtime.py')


class AssetReuseTests(unittest.TestCase):
    def test_spandsp_mirror_only_reuses_retained_media(self):
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
            workflow.write_text('jobs:\n  media:\n    runs-on: xcode-27\n    steps:\n      - run: build\n')
            script = root / 'ci/prepare-media-sdk.sh'
            script.parent.mkdir(parents=True)
            current = (reuse.ROOT / 'ci/prepare-media-sdk.sh').read_text()
            script.write_text(current.replace(reuse.SPANDSP_NEW_LOOP, reuse.SPANDSP_OLD_LOOP))
            git('add', '.')
            git('commit', '-qm', 'old media source')
            previous = git('rev-parse', 'HEAD')
            script.write_text(current)
            mirror = root / reuse.SPANDSP_MIRROR_PATCH
            mirror.parent.mkdir(parents=True)
            shutil.copy2(reuse.ROOT / reuse.SPANDSP_MIRROR_PATCH, mirror)
            git('add', '.')
            git('commit', '-qm', 'mirror only')

            fake = SimpleNamespace(
                MEDIA_INPUTS=('ci/prepare-media-sdk.sh', reuse.SPANDSP_MIRROR_PATCH),
                PREFIX_INPUTS=(), linux=SimpleNamespace(INPUTS=()),
                COMPONENT_INPUTS={'graphics': (), 'jit': ()},
                SPANDSP_MIRROR_PATCH=reuse.SPANDSP_MIRROR_PATCH,
                media_mirror_transport_only=reuse.media_mirror_transport_only,
                git=reuse.git, producer_job=lambda text, stage: text)
            self.assertTrue(reuse.media_mirror_transport_only(root, previous))
            reuse.compatible(root, previous, 'media')
            with patch.object(local, 'ROOT', root), patch.object(local, 'CI', reuse.ROOT / 'ci'):
                local.verify_retained_inputs(fake, previous)
                mirror.write_text(mirror.read_text().replace('cc053ac67', 'bad53ac67'))
                with self.assertRaisesRegex(RuntimeError, 'media'):
                    local.verify_retained_inputs(fake, previous)
                git('add', '.')
                git('commit', '-qm', 'changed source checksum')
                self.assertFalse(reuse.media_mirror_transport_only(root, previous))
                with self.assertRaisesRegex(ValueError, 'producer input'):
                    reuse.compatible(root, previous, 'media')

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
            for name in ('testrepos/Madeira/tools/check-jit-url.py',
                         'testrepos/Madeira/README.md',
                         'testrepos/Madeira/app/Madeira/Library.swift'):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('unrelated change')
            commit()
            reuse.compatible(root, original, 'native')
            for tree in ('build', 'FEX', 'wine', 'research/dxmt', 'research/freetype', 'toolchains'):
                before = git('rev-parse', 'HEAD')
                path = root / 'testrepos/Madeira' / tree / 'compiler-input'
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('changed compiler input')
                commit()
                with self.assertRaisesRegex(ValueError, 'producer input'):
                    reuse.compatible(root, before, 'native')
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

    def test_merged_branch_producer_is_checked_as_current_history(self):
        revision = 'a' * 40
        run = {'id': 123, 'event': 'workflow_dispatch', 'head_branch': 'merged-feature',
               'head_sha': revision, 'path': reuse.WORKFLOW,
               'head_repository': {'full_name': reuse.REPO}}
        jobs = {'jobs': [{'name': 'media', 'conclusion': 'success'}]}
        artifacts = {'artifacts': [{'name': 'media-sdk-with-source', 'expired': False}]}
        with patch.object(reuse, 'api', side_effect=[run, jobs, artifacts]), \
             patch.object(reuse.linux, 'producer_revision_is_ancestor', return_value=True), \
             patch.object(reuse, 'compatible'):
            self.assertEqual(reuse.verify_producer(Path('.'), '123', 'media', 'feature'), revision)
        with patch.object(reuse, 'api', side_effect=[run, jobs]), \
             patch.object(reuse.linux, 'producer_revision_is_ancestor', return_value=False):
            with self.assertRaisesRegex(ValueError, 'ancestor'):
                reuse.verify_producer(Path('.'), '123', 'media', 'feature')
        with patch.object(reuse, 'api', return_value={'workflow_runs': [run]}), \
             patch.object(reuse, 'verify_producer', return_value=revision) as verify:
            self.assertEqual(reuse.select(Path('.'), 'media', 'feature'), '123')
            verify.assert_called_once_with(Path('.'), '123', 'media', 'feature')

    def test_rerun_can_select_same_run_media_from_prior_attempt(self):
        runs = {'workflow_runs': [{'id': 123}]}
        env = {'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2'}
        with patch.dict(os.environ, env, clear=False), \
             patch.object(reuse, 'api', return_value=runs), \
             patch.object(reuse, 'verify_producer', return_value='a' * 40) as verify:
            self.assertEqual(reuse.select(Path('.'), 'media', 'feature'), '123')
            verify.assert_called_once_with(Path('.'), '123', 'media', 'feature')
        env['GITHUB_RUN_ATTEMPT'] = '1'
        with patch.dict(os.environ, env, clear=False), \
             patch.object(reuse, 'api', return_value=runs), \
             patch.object(reuse, 'verify_producer') as verify:
            self.assertEqual(reuse.select(Path('.'), 'media', 'feature'), '')
            verify.assert_not_called()

    def test_rerun_can_select_same_run_compiler_checkpoint(self):
        artifacts = {'artifacts': [{'expired': False, 'workflow_run': {'id': 123}}],
                     'total_count': 1}
        env = {'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2',
               'NATIVE_TOOLCHAIN': 'b' * 64}
        with patch.dict(os.environ, env, clear=False), \
             patch.object(reuse, 'api', return_value=artifacts), \
             patch.object(reuse, 'verify_producer', return_value='a' * 40) as verify:
            self.assertEqual(reuse.select(Path('.'), 'native', 'feature'), '123')
            verify.assert_called_once_with(Path('.'), '123', 'native', 'feature')
        env['GITHUB_RUN_ATTEMPT'] = '1'
        with patch.dict(os.environ, env, clear=False), \
             patch.object(reuse, 'api', return_value=artifacts), \
             patch.object(reuse, 'verify_producer') as verify:
            self.assertEqual(reuse.select(Path('.'), 'native', 'feature'), '')
            verify.assert_not_called()

    def test_producer_validation_reads_all_workflow_attempts(self):
        revision = 'a' * 40
        run = {'event': 'workflow_dispatch', 'head_branch': 'feature',
               'head_sha': revision, 'path': reuse.WORKFLOW,
               'head_repository': {'full_name': reuse.REPO}}
        jobs = {'jobs': [{'name': 'media', 'conclusion': 'success'}]}
        artifacts = {'artifacts': [{'name': 'media-sdk-with-source', 'expired': False}]}
        with patch.object(reuse, 'api', side_effect=[run, jobs, artifacts]) as api, \
             patch.object(reuse, 'compatible'):
            self.assertEqual(reuse.verify_producer(Path('.'), '123', 'media', 'feature'), revision)
            self.assertEqual(api.call_args_list[1].args[0],
                             'actions/runs/123/jobs?filter=all&per_page=100')

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
