"""Host result reuse requires both a trusted successful run and matching tools."""
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import host_tests as host


class HostTestReuseTests(unittest.TestCase):
    revision = 'a' * 40
    artifact = 'source-checks-' + revision + '-' + 'b' * 64
    repo = 'owner/repo'

    def producer(self):
        return dict(id=42, head_sha=self.revision, path=host.WORKFLOW, event='push',
                    status='completed', conclusion='success',
                    head_repository={'full_name': self.repo})

    def check(self, run, artifacts):
        with patch.object(host, 'api', side_effect=[{'workflow_runs': [run]}, {'artifacts': artifacts}]):
            return host.verified_run(self.repo, self.revision, self.artifact)

    def test_matching_successful_manual_or_push_run_reuses(self):
        for event in ('push', 'workflow_dispatch'):
            run = self.producer(); run['event'] = event
            self.assertEqual(self.check(run, [{'name': self.artifact, 'expired': False}]), (42, False))

    def test_foreign_revision_repository_workflow_and_pr_events_cannot_supply_receipt(self):
        for change in ({'head_sha': 'c' * 40}, {'head_repository': {'full_name': 'foreign/repo'}},
                       {'head_repository': None},
                       {'path': '.github/workflows/other.yml'}, {'event': 'pull_request'},
                       {'event': 'pull_request_target'}, {'conclusion': 'failure'}, {'id': '../42'}):
            run = self.producer(); run.update(change)
            with self.subTest(change=change), patch.object(host, 'api', return_value={'workflow_runs': [run]}) as api:
                self.assertEqual(host.verified_run(self.repo, self.revision, self.artifact), (None, False))
                api.assert_called_once()

    def test_missing_expired_duplicate_or_other_toolchain_receipts_require_tests(self):
        for artifacts in ([], [{'name': self.artifact, 'expired': True}],
                          [{'name': self.artifact, 'expired': False}] * 2,
                          [{'name': self.artifact + 'other-tools', 'expired': False}]):
            with self.subTest(artifacts=artifacts):
                self.assertEqual(self.check(self.producer(), artifacts), (None, False))

    def test_running_check_waits_and_failed_check_does_not_pass(self):
        run = self.producer(); run.update(status='in_progress', conclusion=None)
        with patch.object(host, 'api', return_value={'workflow_runs': [run]}):
            self.assertEqual(host.verified_run(self.repo, self.revision, self.artifact), (None, True))

    def test_environment_key_changes_with_tools_sdk_python_and_image(self):
        with patch.object(host.shutil, 'which', return_value=sys.executable), \
                patch.object(host.subprocess, 'check_output', return_value='version one') as tool, \
                patch.object(host.platform, 'platform', return_value='host platform'), \
                patch.dict(os.environ, {'ImageVersion': 'image-one'}):
            original = host.environment_key()
            self.assertEqual(original, host.environment_key())
            tool.return_value = 'version two'
            self.assertNotEqual(original, host.environment_key())
            tool.return_value = 'version one'
            tool.side_effect = lambda command, **kw: 'different SDK' if command[-1] == '--show-sdk-build-version' else 'version one'
            self.assertNotEqual(original, host.environment_key())
            tool.side_effect = None
            with patch.object(host.sys, 'version', 'different Python'):
                self.assertNotEqual(original, host.environment_key())
            with patch.object(host.sys, 'flags', 'optimized assertions'):
                self.assertNotEqual(original, host.environment_key())
            with patch.dict(os.environ, {'ImageVersion': 'image-two'}):
                self.assertNotEqual(original, host.environment_key())

    def test_module_cache_is_shared_within_run_but_keeps_sdks_separate(self):
        first = host.module_cache()
        self.assertEqual(first, host.module_cache('macosx'))
        self.assertNotEqual(first, host.module_cache('iphonesimulator'))
        self.assertFalse(Path(first).is_relative_to(host.ROOT))

    def test_cli_waits_for_matching_check_without_starting_duplicate_suite(self):
        with patch.object(sys, 'argv', ['host_tests.py', '--reuse']), \
                patch.dict(os.environ, {'GITHUB_SHA': self.revision, 'GITHUB_REPOSITORY': self.repo}), \
                patch.object(host, 'environment_key', return_value='b' * 64), \
                patch.object(host.subprocess, 'check_output', return_value=self.revision), \
                patch.object(host, 'verified_run', side_effect=[(None, True), (42, False)]), \
                patch.object(host.time, 'sleep') as sleep, \
                patch.object(host.subprocess, 'run') as suite, patch('sys.stdout', new_callable=io.StringIO):
            host.main()
            sleep.assert_called_once_with(20)
            suite.assert_not_called()

    def test_cli_runs_suite_when_receipt_missing_or_api_fails_and_preserves_failure(self):
        for outcome in ((None, False), OSError('offline')):
            with self.subTest(outcome=outcome), patch.object(sys, 'argv', ['host_tests.py', '--reuse']), \
                    patch.dict(os.environ, {'GITHUB_SHA': self.revision, 'GITHUB_REPOSITORY': self.repo}), \
                    patch.object(host, 'environment_key', return_value='b' * 64), \
                    patch.object(host.subprocess, 'check_output', return_value=self.revision), \
                    patch.object(host, 'verified_run', side_effect=[outcome]), \
                    patch.object(host.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'unittest')) as suite, \
                    patch('sys.stdout', new_callable=io.StringIO):
                with self.assertRaises(subprocess.CalledProcessError): host.main()
                suite.assert_called_once_with([sys.executable, '-B', '-m', 'unittest', 'discover',
                                               '-s', 'ci', '-p', 'test_*.py'], cwd=host.ROOT, check=True)

    def test_stuck_source_check_has_bounded_wait_then_runs_tests(self):
        with patch.object(sys, 'argv', ['host_tests.py', '--reuse']), \
                patch.dict(os.environ, {'GITHUB_SHA': self.revision, 'GITHUB_REPOSITORY': self.repo}), \
                patch.object(host, 'environment_key', return_value='b' * 64), \
                patch.object(host.subprocess, 'check_output', return_value=self.revision), \
                patch.object(host, 'verified_run', return_value=(None, True)), \
                patch.object(host.time, 'monotonic', side_effect=[0, 1200]), \
                patch.object(host.time, 'sleep') as sleep, \
                patch.object(host.subprocess, 'run') as suite:
            host.main()
            sleep.assert_not_called()
            suite.assert_called_once()

    def test_record_requires_exact_checked_out_commit(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(host, 'ROOT', Path(folder)), \
                patch.object(sys, 'argv', ['host_tests.py', '--record']), \
                patch.dict(os.environ, {'GITHUB_SHA': self.revision, 'GITHUB_OUTPUT': str(Path(folder) / 'output')}), \
                patch.object(host, 'environment_key', return_value='b' * 64), \
                patch.object(host.subprocess, 'check_output', return_value=self.revision) as git:
            host.main()
            self.assertIn(self.artifact, (Path(folder) / 'output').read_text())
            git.return_value = 'c' * 40
            with self.assertRaisesRegex(ValueError, 'exact checked-out'): host.main()

    def test_workflows_run_once_for_pr_and_retain_receipt_only_after_success(self):
        source = (host.ROOT / host.WORKFLOW).read_text()
        self.assertIn('  push:\n    branches: [main]\n', source)
        self.assertIn('  pull_request:', source)
        self.assertIn('cancel-in-progress: true', source)
        self.assertLess(source.index('unittest discover'), source.index('- name: Retain passed host test identity'))
        self.assertNotIn('always()', source)
        self.assertNotIn('MadeiraSupportTests/', source)
        self.assertNotIn('testrepos/Madeira/build/host-tests', source)
        build = (host.ROOT / '.github/workflows/build-unsigned-ipa.yml').read_text()
        self.assertIn('python3 ci/host_tests.py --reuse', build)
        self.assertNotIn('unittest discover', build)
        legacy = (host.ROOT / '.github/workflows/legacy-checks.yml').read_text()
        self.assertIn('on:\n  workflow_dispatch:\npermissions:', legacy)
        self.assertEqual(legacy.count('ReviewRegressionCheck.py --group lifecycle'), 1)


if __name__ == '__main__':
    unittest.main()
