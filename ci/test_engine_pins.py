"""Check centralized pins, independent upgrades, and strict component reuse."""
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import engine_pins
from test_manual_build import load

engines = load('central_pin_engines', 'engine-components.py')


class EnginePinsTests(unittest.TestCase):
    def test_gitlink_mismatch_is_rejected_without_initializing_submodules(self):
        data = json.loads((engines.ROOT / engine_pins.MANIFEST).read_text())
        with tempfile.TemporaryDirectory() as folder, patch('builtins.print'):
            root = Path(folder)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '-q')
            for name in ('madeira', *(entry['id'] for entry in data['console_runtimes'])):
                entry = engine_pins.get(name, data)
                git('update-index', '--add', '--cacheinfo', '160000,' + entry['revision'] + ',' + entry['path'])
            (root / engine_pins.MANIFEST).write_text(json.dumps(data))
            engine_pins.verify(root)
            entry = engine_pins.get('azahar', data); entry['revision'] = '1' * 40
            (root / engine_pins.MANIFEST).write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'matching submodule pin'):
                engine_pins.verify(root)
            self.assertFalse((root / 'vendor/Azahar').exists())

    def test_consumers_use_the_selected_pins(self):
        for name in engines.phase3.PINS:
            entry = engine_pins.get(name)
            self.assertEqual(engines.phase3.PINS[name],
                (Path(entry['path']).name, entry['revision'], entry['releaseTag']))
        for file in ('ppsspp_sources.py', 'ppsspp_native_overlay.py', 'ppsspp_atlas_resources.py', 'build-ppsspp-native.py'):
            self.assertEqual(load('pin_' + file, file).REVISION, engine_pins.get('ppsspp')['revision'])
        frontend = load('pin_frontend', 'madeira-frontend.py')
        self.assertEqual(frontend.REVISION, engine_pins.get('madeira')['revision'])
        self.assertEqual(frontend.PSP_REVISION, engine_pins.get('ppsspp')['revision'])
        boots = load('pin_bootroms', 'sameboy_bootroms.py')
        self.assertEqual(boots.REVISION, engine_pins.get('sameboy')['revision'])
        self.assertEqual(boots.RGBDS_REVISION, engine_pins.get('sameboy')['buildDependencies']['rgbds']['revision'])
        self.assertEqual(engines.phase3.AZAHAR_DOWNLOADS, {item['filename']: item['sha256']
            for item in engine_pins.get('azahar')['artifacts'].values()})

    def test_invalid_pins_and_artifact_paths_stop_before_building(self):
        original = json.loads((engines.ROOT / engine_pins.MANIFEST).read_text())
        for field, value in (('revision', 'latest'), ('path', '../outside'),
                             ('upstream', 'https://untrusted.invalid/repo')):
            data = deepcopy(original)
            next(item for item in data['console_runtimes'] if item['id'] == 'azahar')[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                engine_pins.get('azahar', data)
        for field, value in (('filename', '../source.tar.xz'), ('filename', '/source.tar.xz'), ('sha256', 'unchecked')):
            data = deepcopy(original)
            next(item for item in data['console_runtimes'] if item['id'] == 'azahar')['artifacts']['source'][field] = value
            with self.subTest(artifact=field), self.assertRaises(ValueError):
                engine_pins.get('azahar', data)
        data = deepcopy(original); data['console_runtimes'].append(engine_pins.get('azahar', data))
        with self.assertRaises(ValueError): engine_pins.get('azahar', data)

    def test_pin_and_adapter_changes_invalidate_only_their_consumers(self):
        reuse = engines.components.reuse
        original = json.loads((engines.ROOT / engine_pins.MANIFEST).read_text())
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '-q'); git('config', 'user.name', 'Test'); git('config', 'user.email', 'test@example.invalid')
            git('remote', 'add', 'origin', str(root))
            paths = {reuse.WORKFLOW, 'ci/compiled-components.py', 'ci/engine_pins.py', engine_pins.MANIFEST}
            for stage in engine_pins.STAGES:
                paths.update(reuse.COMPONENT_INPUTS[stage])
            for name in paths:
                source = engines.ROOT / name
                target = root / name
                if not source.is_file(): target /= 'source.c'
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read_bytes() if source.is_file() else b'upstream fixture')
            git('add', '.'); git('commit', '-qm', 'compiler inputs')
            revision = git('rev-parse', 'HEAD')
            def check(affected):
                for stage, name in engine_pins.STAGES.items():
                    with self.subTest(changed=affected, consumer=stage):
                        if name == affected and stage != 'host':
                            with self.assertRaisesRegex(ValueError, 'Changed producer'):
                                reuse.compatible(root, revision, stage)
                        else:
                            reuse.compatible(root, revision, stage)
            for name in ('madeira', *(item['id'] for item in original['console_runtimes'])):
                git('reset', '--hard', revision)
                data = deepcopy(original)
                entry = data['frontend_runtime'] if name == 'madeira' else next(item for item in data['console_runtimes'] if item['id'] == name)
                entry['revision'] = '0' * 40
                (root / engine_pins.MANIFEST).write_text(json.dumps(data))
                git('add', '.'); git('commit', '-qm', 'one engine pin')
                for stage, consumer in engine_pins.STAGES.items():
                    with self.subTest(pin=name, consumer=stage):
                        if consumer == name:
                            with self.assertRaisesRegex(ValueError, 'Changed producer engine pin'):
                                reuse.compatible(root, revision, stage)
                        else: reuse.compatible(root, revision, stage)
            for name in engines.phase3.PINS:
                for path in ('ci/phase3_' + name + '.py', 'ci/' + name + '-targets.cmake'):
                    git('reset', '--hard', revision)
                    target = root / path; target.write_text(target.read_text() + '\n# Changed engine adapter\n')
                    git('add', '.'); git('commit', '-qm', 'one engine adapter')
                    check(name)

    def test_receipt_pin_hash_is_scoped_and_rejects_an_old_engine(self):
        baseline = {name: engines.phase3.fixed_inputs(name) for name in ('host', *engines.phase3.PINS)}
        original = engine_pins.selected
        def changed(stage, data=None):
            selected = original(stage, data)
            if stage == 'azahar': selected['revision'] = '0' * 40
            return selected
        with patch.object(engine_pins, 'selected', side_effect=changed):
            for name in baseline:
                if name == 'azahar':
                    self.assertNotEqual(baseline[name], engines.phase3.fixed_inputs(name))
                    with self.assertRaisesRegex(ValueError, 'recipe or ABI changed'):
                        engines.phase3.verify_inputs({'engine': name, 'buildInputs': baseline[name]})
                else: self.assertEqual(baseline[name], engines.phase3.fixed_inputs(name))


if __name__ == '__main__': unittest.main()
