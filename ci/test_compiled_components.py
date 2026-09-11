import json
import hashlib
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import load

components = load('components_tests', 'compiled-components.py')
reuse = components.reuse


class CompiledComponentsTests(unittest.TestCase):
    def test_toolchain_ignores_metal_mount_but_checks_version(self):
        def fingerprint(version, mount):
            def output(command, **kwargs):
                if 'metal' in command:
                    return f'Apple metal version {version}\nTarget: air64\nInstalledDir: {mount}\n'
                return 'fixed tool version'
            with patch.object(components.prepared.subprocess, 'check_output', side_effect=output), \
                 patch.object(components.prepared.inputs, 'digest', return_value='fixed input'):
                return components.prepared.toolchain()
        self.assertEqual(fingerprint('32023.921', '/mount/first'),
                         fingerprint('32023.921', '/mount/second'))
        self.assertNotEqual(fingerprint('32023.921', '/mount/first'),
                            fingerprint('32024.0', '/mount/first'))

    def test_legacy_migration_requires_every_other_input_to_match(self):
        old = ['xcode 27', 'sdk 27', 'metal 1\nInstalledDir: /old', 'swift 1', 'media digest']
        expected = hashlib.sha256('\n'.join(old).encode()).hexdigest()
        current = list(old)
        current[2] = 'metal 1\nInstalledDir: /new'
        with patch.object(components.prepared, 'LEGACY_METAL_MOUNTS', {expected: '/old'}):
            self.assertEqual(components.prepared.fingerprint(current), expected)
            for index in range(len(current)):
                changed = list(current)
                changed[index] += '\nchanged'
                self.assertNotEqual(components.prepared.fingerprint(changed), expected)

    def test_round_trip_preserves_executable_and_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / 'testrepos/Madeira/wine/build-macos/tools/wine/wine'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'compiled executable')
            binary.chmod(0o755)
            binary.with_suffix('.o').write_bytes(b'unneeded object')
            env = {'NATIVE_TOOLCHAIN': 'a' * 64, 'GITHUB_REF_NAME': 'main'}
            with patch.dict(os.environ, env), patch.object(reuse, 'git', return_value='b' * 40):
                components.package(root, 'wine')
            archive = root / '.build/wine-compiled-transfer/compiled.tar.gz'
            with tarfile.open(archive) as tar:
                self.assertFalse(any(m.name.endswith('.o') for m in tar))
            binary.unlink()
            with patch.dict(os.environ, env), patch.object(reuse, 'verify_producer', return_value='b' * 40):
                components.restore(root, 'wine', '123')
                self.assertEqual(binary.read_bytes(), b'compiled executable')
                self.assertTrue(binary.stat().st_mode & 0o111)
                archive.write_bytes(b'corrupt')
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    components.restore(root, 'wine', '123')
            for name in ('../secret', '/tmp/file', '.git/config',
                         'testrepos/Madeira/wine/build-macos/cert.p12'):
                self.assertFalse(components.allowed(name, 'wine'))

    def test_failed_later_job_keeps_completed_component_but_expiry_rebuilds(self):
        run = {'id': 123, 'event': 'workflow_dispatch', 'head_branch': 'main',
               'head_sha': 'b' * 40, 'path': reuse.WORKFLOW,
               'head_repository': {'full_name': reuse.REPO}}
        jobs = [{'name': 'build', 'conclusion': 'failure', 'steps': [
            {'name': 'Retain wine compilation', 'conclusion': 'success'}]}]
        self.assertEqual(reuse.validate(run, jobs, 'wine', 'main'), 'b' * 40)
        jobs[0]['steps'][0]['conclusion'] = 'failure'
        with self.assertRaises(ValueError):
            reuse.validate(run, jobs, 'wine', 'main')
        with patch.dict(os.environ, {'NATIVE_TOOLCHAIN': 'a' * 64}), \
             patch.object(reuse, 'api', return_value={'total_count': 1, 'artifacts': [
                 {'expired': True, 'workflow_run': run}]}), \
             patch.object(reuse, 'verify_producer', side_effect=ValueError('absent or expired')):
            self.assertEqual(reuse.select(Path('.'), 'wine', 'main'), '')

    def test_packaging_edit_reuses_wine_but_compiler_edit_invalidates(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '-q'); git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            git('remote', 'add', 'origin', str(root))
            (root / 'ci').mkdir()
            compiler = root / 'ci/compile-wine.sh'
            compiler.write_text('compile')
            workflow = root / reuse.WORKFLOW
            workflow.parent.mkdir(parents=True)
            workflow.write_text('jobs:\n  build:\n    runs-on: xcode-27\n    steps:\n'
                                '      - name: Compile wine\n        run: bash ci/compile-wine.sh\n'
                                '      - name: Stage Windows modules\n        run: stage\n')
            def commit():
                git('add', '.'); git('commit', '-qm', 'fixture')
            commit(); revision = git('rev-parse', 'HEAD')
            (root / 'ci/stage-windows-runtime.py').write_text('packaging fix')
            workflow.write_text(workflow.read_text().replace('run: stage', 'run: new-stage'))
            commit()
            reuse.compatible(root, revision, 'wine')
            compiler.write_text('changed compilation'); commit()
            with self.assertRaisesRegex(ValueError, 'input'):
                reuse.compatible(root, revision, 'wine')

    def test_uploads_precede_staging_and_only_follow_new_compilation(self):
        workflow = (components.ROOT / reuse.WORKFLOW).read_text()
        for component in components.PATHS:
            step = workflow.split('      - name: Retain ' + component + ' compilation\n')[1].split('      - name:')[0]
            self.assertIn(f"if: steps.compiled_{component}.outputs.run_id == ''", step)
            self.assertIn('retention-days: 7', step)
        self.assertLess(workflow.index('Retain wine compilation'), workflow.index('Stage Windows modules'))
        self.assertLess(workflow.index('Retain windows compilation'), workflow.index('Stage Windows modules'))
