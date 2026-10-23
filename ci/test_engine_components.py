"""Exercise cold save, trusted restore, and app-only reuse without native compilers."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import load

engines = load('engine_component_tests', 'engine-components.py')


class EngineComponentsTests(unittest.TestCase):
    def test_app_only_edit_restores_every_engine_without_compiling_and_core_edit_rebuilds(self):
        for engine in engines.PATHS:
            with self.subTest(engine=engine), tempfile.TemporaryDirectory() as folder, ExitStack() as stack:
                root = Path(folder) / 'repo'; root.mkdir()
                def git(*args):
                    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
                git('init', '-q'); git('config', 'user.name', 'Test'); git('config', 'user.email', 'test@example.invalid')
                git('remote', 'add', 'origin', str(root))
                (root / '.gitignore').write_text('.build/\n')
                reuse = engines.components.reuse
                for name in (*engines.INPUTS[engine], 'ci/engine-components.py', 'ci/compiled-components.py', reuse.WORKFLOW):
                    path = root / name
                    if name.startswith('vendor/') and Path(name).suffix == '': path /= 'source.c'
                    path.parent.mkdir(parents=True, exist_ok=True)
                    actual = engines.ROOT / name
                    path.write_bytes(actual.read_bytes() if actual.is_file() else b'fixture source')
                git('add', '.'); git('commit', '-qm', 'component fixture')
                revision = git('rev-parse', 'HEAD')
                output = Path(folder) / 'step-output'
                stack.enter_context(patch.dict(os.environ, {'NATIVE_TOOLCHAIN': 'a' * 64,
                    'GITHUB_REF_NAME': 'main', 'GITHUB_OUTPUT': str(output), 'REUSE_ASSETS': 'true'}))
                stack.enter_context(patch.object(engines, 'ROOT', root))
                stack.enter_context(patch.dict(engines.components.PATHS))
                record = {'compiledInputs': {}}
                generated = root / '.build/phase3' / engine / 'iphoneos/build/generated.c'
                if engine in engines.phase3.PINS: record['compiledInputs'][generated.relative_to(root).as_posix()] = 'fixture'
                def compile_component(name):
                    self.assertEqual(name, engine)
                    for base in engines.PATHS[name]:
                        path = root / base
                        if path.suffix:
                            path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'compiled fixture')
                        else:
                            path.mkdir(parents=True, exist_ok=True); (path / 'resource.txt').write_bytes(b'resource')
                    if record['compiledInputs']:
                        generated.parent.mkdir(parents=True, exist_ok=True); generated.write_text('generated source')
                compiler = stack.enter_context(patch.object(engines, 'compile', side_effect=compile_component))
                stack.enter_context(patch.object(engines, 'validate', return_value=record))
                available = False
                artifact = reuse.artifact_name(engine)
                def api(path):
                    if path.startswith('actions/artifacts?'):
                        return {'total_count': int(available), 'artifacts':
                            [{'name': artifact, 'expired': False, 'workflow_run': {'id': 42}}] if available else []}
                    if path == 'actions/runs/42':
                        return {'head_sha': revision, 'event': 'workflow_dispatch', 'head_branch': 'main',
                            'path': reuse.WORKFLOW, 'head_repository': {'full_name': reuse.REPO}}
                    if path.startswith('actions/runs/42/jobs?'):
                        return {'jobs': [{'name': 'build', 'steps': [
                            {'name': 'Retain ' + engine + ' compilation', 'conclusion': 'success'}]}]}
                    if path.startswith('actions/runs/42/artifacts?'):
                        return {'artifacts': [{'name': artifact, 'expired': False}]}
                    self.fail('Unexpected GitHub request: ' + path)
                stack.enter_context(patch.object(reuse, 'api', side_effect=api))
                engines.ensure(engine)
                self.assertIn('rebuilt=true', output.read_text())
                transfer = root / '.build' / (engine + '-compiled-transfer')
                saved = Path(folder) / 'saved'; shutil.copytree(transfer, saved)
                shutil.rmtree(root / '.build')
                available = True
                app = root / 'iridium/apps/ios/App/Library.swift'; app.parent.mkdir(parents=True)
                app.write_text('// app-only fixture')
                git('add', '.'); git('commit', '-qm', 'app-only fixture')
                real_run = subprocess.run
                def run(command, **kwargs):
                    if command[:3] == ['gh', 'run', 'download']:
                        shutil.copytree(saved, Path(command[-1])); return subprocess.CompletedProcess(command, 0)
                    return real_run(command, **kwargs)
                stack.enter_context(patch.object(engines.subprocess, 'run', side_effect=run))
                engines.ensure(engine)
                self.assertEqual(compiler.call_count, 1, 'app edit restarted the compiler')
                self.assertIn('rebuilt=false', output.read_text())
                for name in engines.PATHS[engine]: self.assertTrue((root / name).exists(), name)
                if record['compiledInputs']: self.assertEqual(generated.read_text(), 'generated source')
                source = next(root.glob('vendor/**/source.c'))
                source.write_text('changed compiler source')
                git('add', '.'); git('commit', '-qm', 'core change fixture')
                engines.ensure(engine)
                self.assertEqual(compiler.call_count, 2, 'core edit reused stale compilation')

    def test_disabled_reuse_builds_and_retains_without_querying_github(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {
                'REUSE_ASSETS': 'false', 'GITHUB_REF_NAME': 'main', 'GITHUB_OUTPUT': folder + '/output',
                'NATIVE_TOOLCHAIN': 'a' * 64}), \
                patch.object(engines.components.reuse, 'select') as select, \
                patch.object(engines, 'compile') as compile, patch.object(engines, 'validate', return_value={}), \
                patch.object(engines.components, 'package') as package:
            engines.ensure('psp')
            select.assert_not_called(); compile.assert_called_once_with('psp'); package.assert_called_once()

    def test_corrupt_artifact_does_not_fall_through_to_an_unchecked_app(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {
                'GITHUB_REF_NAME': 'main', 'NATIVE_TOOLCHAIN': 'a' * 64}), \
                patch.object(engines.components.reuse, 'select', return_value='42'), \
                patch.object(engines.subprocess, 'run'), \
                patch.object(engines.components, 'restore', side_effect=ValueError('checksum mismatch')), \
                patch.object(engines, 'compile') as compiler:
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'): engines.ensure('psp')
            compiler.assert_not_called()

    def test_each_engine_tracks_its_actual_bridge_and_its_source(self):
        for engine in ('host', *engines.phase3.PINS):
            self.assertTrue(set(engines.phase3.input_paths(engine)) <= set(engines.INPUTS[engine]))
            self.assertNotIn(engines.BRIDGE + 'IRPPSSPPNative.mm', engines.INPUTS[engine])
        self.assertIn(engines.BRIDGE + 'IRPPSSPPNative.mm', engines.INPUTS['psp'])
        for stage in engines.PATHS:
            self.assertIn('ci/engine-components.py', engines.components.reuse.COMPONENT_INPUTS[stage])

    def test_empty_asset_directories_survive_transfer_and_wrong_platform_stops(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(engines, 'ROOT', Path(folder)), \
                patch.object(engines.phase3, 'verify_inputs'), \
                patch.object(engines.phase3, 'audit', return_value={'sha256': 'checked'}):
            directory = Path(folder) / '.build/phase3/flycast/iphoneos'; directory.mkdir(parents=True)
            receipt = directory / 'component.json'
            record = {'engine': 'flycast', 'sdk': 'iphoneos', 'sha256': 'checked', 'files': {}}
            receipt.write_text(json.dumps(record))
            engines.validate('flycast')
            self.assertTrue((directory / 'assets').is_dir())
            self.assertTrue((directory / 'licenses').is_dir())
            record['sdk'] = 'iphonesimulator'; receipt.write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, 'platform differs'): engines.validate('flycast')

    def test_sameboy_app_step_reuses_only_matching_compiler_platform_and_source(self):
        builder = load('sameboy_reuse_test', 'build-sameboy.py')
        record = {'sdk': None, 'target': None, 'compiler': 'compiler one', 'platformFlags': []}
        with tempfile.TemporaryDirectory() as folder, patch.object(builder, 'verify_source'), \
                patch.object(builder, 'run', return_value='compiler one'), \
                patch.object(builder, 'verify_component', return_value=record), \
                patch.object(builder, 'read_bootroms', side_effect=RuntimeError('compiler requested')) as boots:
            self.assertEqual(builder.build(folder), Path(folder).resolve() / 'libIridiumSameBoy.a')
            boots.assert_not_called()
            for key, value in (('compiler', 'compiler two'), ('sdk', 'iphoneos'), ('target', 'other'),
                               ('platformFlags', ['other sdk'])):
                with self.subTest(key=key), patch.dict(record, {key: value}):
                    with self.assertRaisesRegex(RuntimeError, 'compiler requested'): builder.build(folder)
            with patch.object(builder, 'verify_component', side_effect=ValueError('source changed')):
                with self.assertRaisesRegex(RuntimeError, 'compiler requested'): builder.build(folder)


if __name__ == '__main__': unittest.main()
