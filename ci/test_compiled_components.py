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
from test_madeira_native_reuse import build as native_build, fixture_inputs, fixture_record, source_fixture

components = load('components_tests', 'compiled-components.py')
space = load('build_space_tests', 'free-build-space.py')
reuse = components.reuse


class CompiledComponentsTests(unittest.TestCase):
    def test_frontend_app_bodies_do_not_change_compiler_source(self):
        source = (components.ROOT / 'ci/madeira-frontend.py').read_text()
        original = reuse.frontend_compiler_source(source)
        self.assertNotEqual(original, source)
        for name in reuse.FRONTEND_APP_FUNCTIONS:
            with self.subTest(function=name):
                header = next(line for line in source.splitlines() if line.startswith('def ' + name + '('))
                changed = source.replace(header + '\n', header + '\n    print("app-only edit")\n')
                self.assertEqual(original, reuse.frontend_compiler_source(changed))
        # App source staging belongs to preparation, never native compilation.
        before = source.replace('names = app_sources.stage(app)',
                                'names = fixture_stage(app)')
        self.assertNotEqual(before, source)
        self.assertEqual(original, reuse.frontend_compiler_source(before))
        before = source.replace('Wii, 3DS, and PSP controls use device motion while you play.',
                                'PSP tilt controls use device motion while you play.')
        self.assertNotEqual(before, source)
        self.assertEqual(original, reuse.frontend_compiler_source(before))

    def test_frontend_compiler_helpers_and_global_inputs_remain_exact(self):
        source = (components.ROOT / 'ci/madeira-frontend.py').read_text()
        original = reuse.frontend_compiler_source(source)
        for name in ('native', 'windows', 'build_native', 'bootstrap', 'toolchains',
                     'stage_crypto_libraries', 'run_checked_recipe', 'verify_pin', 'compiler_identity'):
            with self.subTest(function=name):
                header = next(line for line in source.splitlines() if line.startswith('def ' + name + '('))
                changed = source.replace(header + '\n', header + '\n    # Changed compiler recipe.\n')
                self.assertNotEqual(original, reuse.frontend_compiler_source(changed))
        revision = next(line for line in source.splitlines() if line.startswith('REVISION = '))
        for old, new in (("CRYPTO_LIBRARIES = ('gnutls',", "CRYPTO_LIBRARIES = ('different',"),
                         (revision, "REVISION = '0000000000000000000000000000000000000000'"),
                         ('import subprocess', 'import subprocess as another_process'),
                         ('import madeira_threads', 'import madeira_threads as another_module'),
                         ("'native': lambda: native(reuse_only=args.reuse_only)", "'native': windows"),
                         ('def prepare():', 'def prepare(*args):')):
            with self.subTest(input=old):
                changed = source.replace(old, new)
                self.assertNotEqual(source, changed)
                self.assertNotEqual(original, reuse.frontend_compiler_source(changed))
        self.assertNotEqual(original, reuse.frontend_compiler_source(source + '\ndef new_helper():\n    return 1\n'))

    def test_frontend_unknown_or_shared_app_dependencies_fail_closed(self):
        source = (components.ROOT / 'ci/madeira-frontend.py').read_text()
        def helper(body, arguments=''):
            return source.replace("\nif __name__ == '__main__':",
                                  '\ndef new_helper(' + arguments + '):\n' + body + "\nif __name__ == '__main__':")
        variants = [
            source + '\ndef prepare():\n    return 1\n',
            source + '\nprepare = native\n',
            source + '\nif True:\n    native = prepare\n',
            helper('    prepare()\n'),
            helper('    return PSP_PRIVACY_DESCRIPTIONS\n'),
            helper('    return module.PSP_PRIVACY_DESCRIPTIONS\n'),
            helper('    return globals()["PSP_PRIVACY_DESCRIPTIONS"]\n'),
            helper('    callback()\n', 'callback=prepare'),
            helper('    def nested():\n        prepare()\n    nested()\n'),
            helper('    return globals()["prepare"]\n'),
            helper('    return sys.modules[__name__]\n'),
            helper('    importlib.import_module(__name__).prepare()\n'),
            helper('    from builtins import globals as namespace\n    namespace()["prepare"]()\n'),
            helper('    return Path(__file__).read_text()\n'),
            helper('    subprocess.run([sys.executable, str(ROOT / "ci/madeira-frontend.py"), "prepare"], check=True)\n'),
            helper('    subprocess.run([driver, "prepare"], check=True)\n'),
            helper('    module.prepare()\n'),
            source.replace('import json', 'from builtins import globals as namespace\nimport json'),
            source.replace('import json', 'import inspect as inspection\nimport json'),
            source.replace('def native(reuse_only=False):\n', 'def native(reuse_only=False):\n    inspect.stack()\n'),
            source.replace('def native(reuse_only=False):\n', 'def native(reuse_only=False):\n    __builtins__["globals"]()["prepare"]()\n'),
            source.replace('def prepare():', '@decorator\ndef prepare():'),
            source.replace('def prepare():', 'def prepare(value=bootstrap()):'),
            source.replace('def prepare():', 'def prepare() -> bootstrap():'),
            source.replace('def prepare():', 'async def prepare():'),
            source.replace('PSP_PRIVACY_DESCRIPTIONS = {',
                           'PSP_PRIVACY_DESCRIPTIONS = build_metadata()\nUNREVIEWED_METADATA = {'),
            source.replace("'NSMotionUsageDescription':", '42:'),
            source.replace('PSP_PRIVACY_DESCRIPTIONS = {',
                           'OTHER_INPUT = 1; PSP_PRIVACY_DESCRIPTIONS = {'),
            source.replace('}\ndef overlay', '}; OTHER_INPUT = 1\ndef overlay'),
            source.replace('PSP_PRIVACY_DESCRIPTIONS = {',
                           'PSP_PRIVACY_DESCRIPTIONS = {"note": "' + 'é' * 40 +
                           '"}; OTHER_INPUT = 1\nUNREVIEWED_METADATA = {'),
            source.replace("if __name__ == '__main__':", "if __name__ == '__main__':\n    prepare()"),
            source.replace('args = parser.parse_args()', 'args = parser.parse_args()\n    args.action = "prepare"'),
            source.replace("'native': lambda: native(reuse_only=args.reuse_only)", "'native': prepare"),
            source.replace("engine_pins.get('madeira')['revision']", "engine_pins.get(prepare())['revision']"),
            source + '\ninvalid python !\n',
        ]
        for index, changed in enumerate(variants):
            with self.subTest(variant=index):
                self.assertEqual(reuse.frontend_compiler_source(changed), changed)

    def test_frontend_app_only_edit_reuses_existing_producer_both_components(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '-q'); git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            git('remote', 'add', 'origin', str(root))
            script = root / 'ci/madeira-frontend.py'
            script.parent.mkdir()
            source = (components.ROOT / 'ci/madeira-frontend.py').read_text()
            script.write_text(source.replace('Wii, 3DS, and PSP controls use device motion while you play.',
                                             'PSP tilt controls use device motion while you play.'))
            workflow = root / reuse.WORKFLOW
            workflow.parent.mkdir(parents=True)
            workflow.write_text((components.ROOT / reuse.WORKFLOW).read_text())
            contract = root / 'ci/compiled-components.py'
            contract.write_text((components.ROOT / 'ci/compiled-components.py').read_text())
            for name in ('ci/engine_pins.py', 'UPSTREAM-SOURCES.json'):
                (root / name).write_bytes((components.ROOT / name).read_bytes())
            tracker_inputs = ('ci/madeira_threads.py', 'iridium/apps/ios/RuntimeBridge/IRWindowsThreads.c',
                              'iridium/apps/ios/RuntimeBridge/IRWindowsThreads.h')
            for name in tracker_inputs:
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes((components.ROOT / name).read_bytes())
            def commit():
                git('add', '.'); git('commit', '-qm', 'fixture')
            commit(); revision = git('rev-parse', 'HEAD')
            script.write_text(source.replace('def prepare():\n', 'def prepare():\n    print("new app staging")\n'))
            commit()
            for stage in ('madeira-native', 'madeira-windows'):
                reuse.compatible(root, revision, stage)
            app_only = script.read_text()
            for name in tracker_inputs:
                path = root / name; saved = path.read_bytes()
                path.write_bytes(saved + b'\n/* Changed thread adapter */\n'); commit()
                with self.assertRaisesRegex(ValueError, 'Changed producer input: ' + name):
                    reuse.compatible(root, revision, 'madeira-native')
                reuse.compatible(root, revision, 'madeira-windows')
                path.write_bytes(saved); commit()
            for name in ('build_native', 'windows', 'verify_pin', 'run_checked_recipe', 'stage_crypto_libraries'):
                header = next(line for line in source.splitlines() if line.startswith('def ' + name + '('))
                script.write_text(app_only.replace(header + '\n', header + '\n    print("changed recipe")\n'))
                commit()
                for stage in ('madeira-native', 'madeira-windows'):
                    with self.subTest(stage=stage, helper=name), self.assertRaisesRegex(ValueError, 'Changed producer input: ci/madeira-frontend.py'):
                        reuse.compatible(root, revision, stage)
            script.write_text(app_only)
            contract.write_text(contract.read_text() + '\n# Changed artifact contract.\n')
            commit()
            for stage in ('madeira-native', 'madeira-windows'):
                with self.assertRaisesRegex(ValueError, 'Changed producer input: ci/compiled-components.py'):
                    reuse.compatible(root, revision, stage)

    def test_uploaded_transfers_are_removed_without_touching_runtime(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            build = root / '.build'
            for name in space.TRANSFERS:
                path = build / (name + '-transfer')
                path.mkdir(parents=True)
                (path / 'archive').write_bytes(b'uploaded')
            runtime = build / 'corresponding-source/source.tar.gz'
            runtime.parent.mkdir()
            runtime.write_bytes(b'needed')
            objects = root / space.OBJECT_TREES[0]
            objects.mkdir(parents=True)
            (objects / 'compiled.o').write_bytes(b'temporary object')
            (objects / 'compiled.obj').write_bytes(b'temporary object')
            (objects / 'libFinal.a').write_bytes(b'needed archive')
            source = root / 'source.o'
            source.write_bytes(b'not a compiler output')
            (objects / 'linked.o').symlink_to(source)
            space.cleanup(root)
            self.assertFalse((objects / 'compiled.o').exists())
            self.assertFalse((objects / 'compiled.obj').exists())
            self.assertEqual((objects / 'libFinal.a').read_bytes(), b'needed archive')
            self.assertTrue((objects / 'linked.o').is_symlink())
            self.assertEqual(source.read_bytes(), b'not a compiler output')
            self.assertEqual(runtime.read_bytes(), b'needed')
            self.assertTrue(all(not (build / (name + '-transfer')).exists() for name in space.TRANSFERS))
            outside = root / 'outside'
            outside.mkdir()
            for name in space.TRANSFERS[1:]:
                (build / (name + '-transfer')).mkdir()
            (build / 'media-transfer').symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'regular build transfer'):
                space.cleanup(root)
            self.assertTrue(outside.is_dir())
            self.assertTrue((build / 'native-compiled-transfer').is_dir())

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

    def test_frontend_checkpoint_restores_libraries_and_completion_records(self):
        for component in ('madeira-native', 'madeira-windows'):
            with self.subTest(component=component), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                for name in components.PATHS[component]:
                    base = root / name
                    if base.suffix in {'.json', '.exe', '.txt'}:
                        base.parent.mkdir(parents=True, exist_ok=True)
                        base.write_bytes(b'completion record')
                    else:
                        base.mkdir(parents=True, exist_ok=True)
                        (base / 'output.a').write_bytes(b'archive')
                library = root / components.FRONTEND / 'app/Madeira/libntdll_unix.a'
                library.parent.mkdir(parents=True, exist_ok=True)
                library.write_bytes(b'native library')
                library.with_suffix('.o').write_bytes(b'temporary object')
                env = {'NATIVE_TOOLCHAIN': 'a' * 64, 'GITHUB_REF_NAME': 'main'}
                if component == 'madeira-native': fixture_record(root / components.FRONTEND)
                with patch.dict(os.environ, env), patch.object(reuse, 'git', return_value='b' * 40), \
                     patch.object(components, 'frontend_module', return_value=native_build), \
                     patch.object(native_build, 'ROOT', root), patch.object(native_build, 'UPSTREAM', root / components.FRONTEND), \
                     patch.object(native_build, 'native_inputs', return_value=fixture_inputs()), patch.object(native_build, 'verify_pin'):
                    components.package(root, component)
                archive = root / '.build' / (component + '-compiled-transfer/compiled.tar.gz')
                with tarfile.open(archive) as tar:
                    names = [m.name for m in tar]
                    self.assertFalse(any(name.endswith('.o') for name in names))
                    for name in names: (root / name.removeprefix('compiled/')).unlink()
                with patch.dict(os.environ, env), patch.object(reuse, 'verify_producer', return_value='b' * 40), \
                     patch.object(components, 'frontend_module', return_value=native_build), \
                     patch.object(native_build, 'ROOT', root), patch.object(native_build, 'UPSTREAM', root / components.FRONTEND), \
                     patch.object(native_build, 'native_inputs', return_value=fixture_inputs()), patch.object(native_build, 'verify_pin'):
                    components.restore(root, component, '123')
                self.assertTrue(all((root / name.removeprefix('compiled/')).is_file() for name in names))
                if component == 'madeira-native': self.assertEqual(library.read_bytes(), b'native library')

    def test_round_trip_preserves_executable_and_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / 'testrepos/Madeira/wine/build-macos/tools/wine/wine'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'compiled executable')
            binary.chmod(0o755)
            guest = root / 'testrepos/Madeira/wine/build-i386/dlls/ntdll/i386-windows/ntdll.dll'
            guest.parent.mkdir(parents=True)
            guest.write_bytes(b'compiled guest module')
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
                self.assertEqual(guest.read_bytes(), b'compiled guest module')
                self.assertTrue(binary.stat().st_mode & 0o111)
                archive.write_bytes(b'corrupt')
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    components.restore(root, 'wine', '123')
            for name in ('../secret', '/tmp/file', '.git/config',
                         'testrepos/Madeira/wine/build-macos/cert.p12'):
                self.assertFalse(components.allowed(name, 'wine'))

    def test_partial_native_generation_cannot_be_packaged_as_a_producer(self):
        for change in ('partial', 'changed', 'missing', 'tool'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); upstream = root / components.FRONTEND
                record = fixture_record(upstream)
                current = fixture_inputs()
                if change == 'partial': record['state'] = 'building'
                elif change == 'changed': (upstream / 'app/Madeira/libswresample.a').write_bytes(b'partial relink')
                elif change == 'missing': (upstream / 'app/Madeira/libavcodec.a').unlink()
                else: current['tools']['bison --version']['executable'] = '/different/bison'
                (upstream / '.build/iridium-native.json').write_text(json.dumps(record))
                with patch.object(components, 'frontend_module', return_value=native_build), \
                     patch.object(native_build, 'ROOT', root), patch.object(native_build, 'UPSTREAM', upstream), \
                     patch.object(native_build, 'native_inputs', return_value=current), patch.object(native_build, 'verify_pin'):
                    with self.assertRaisesRegex(ValueError, 'native reuse rejected'):
                        components.package(root, 'madeira-native')
                self.assertFalse((root / '.build/madeira-native-compiled-transfer').exists())

    def test_invalid_restored_native_stamp_is_rejected_before_staging_any_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); upstream = root / components.FRONTEND
            record = fixture_record(upstream)
            transfer = root / '.build/madeira-native-compiled-transfer'; transfer.mkdir(parents=True)
            archive = transfer / 'compiled.tar.gz'
            record['state'] = 'building'
            stamp = upstream / '.build/iridium-native.json'; stamp.write_text(json.dumps(record))
            names = [p for p in upstream.rglob('*') if p.is_file()]
            with tarfile.open(archive, 'w:gz') as tar:
                for p in names: tar.add(p, arcname='compiled/' + str(p.relative_to(root)))
            manifest = {'revision': 'b' * 40, 'component': 'madeira-native', 'toolchain': 'a' * 64,
                        'workspace': str(root.resolve()), 'sha256': components.inputs.digest(archive)}
            (transfer / 'manifest.json').write_text(json.dumps(manifest))
            library = upstream / 'app/Madeira/libswresample.a'; library.write_bytes(b'preserve previous output')
            stamp.write_bytes(b'preserve previous receipt')
            before = {p: p.read_bytes() for p in names}
            env = {'NATIVE_TOOLCHAIN': 'a' * 64, 'GITHUB_REF_NAME': 'main'}
            with patch.dict(os.environ, env), patch.object(reuse, 'verify_producer', return_value='b' * 40), \
                 patch.object(components, 'frontend_module', return_value=native_build), \
                 patch.object(native_build, 'ROOT', root), patch.object(native_build, 'UPSTREAM', upstream), \
                 patch.object(native_build, 'native_inputs', return_value=fixture_inputs()), patch.object(native_build, 'verify_pin'):
                with self.assertRaisesRegex(ValueError, 'incomplete_record'):
                    components.restore(root, 'madeira-native', '123')
            self.assertEqual(before, {p: p.read_bytes() for p in names})

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

    def test_restore_rejects_in_checkout_leaf_and_ancestor_symlinks_before_any_copy(self):
        for kind in ('leaf', 'ancestor', 'dangling'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                binary = root / 'testrepos/Madeira/wine/build-macos/tools/wine/wine'
                binary.parent.mkdir(parents=True); binary.write_bytes(b'new artifact binary')
                guest = root / 'testrepos/Madeira/wine/build-i386/ntdll.dll'
                guest.parent.mkdir(parents=True); guest.write_bytes(b'guest artifact')
                env = {'NATIVE_TOOLCHAIN': 'a' * 64, 'GITHUB_REF_NAME': 'main'}
                with patch.dict(os.environ, env), patch.object(reuse, 'git', return_value='b' * 40):
                    components.package(root, 'wine')
                retained = root / 'retained'
                if kind == 'ancestor':
                    binary.parent.rename(retained); binary.parent.symlink_to(retained, target_is_directory=True)
                    sentinel = retained / 'wine'; sentinel.write_bytes(b'preserve target')
                else:
                    binary.unlink()
                    if kind == 'leaf': retained.write_bytes(b'preserve target')
                    binary.symlink_to(retained); sentinel = retained
                copy = components.shutil.copy2
                with patch.dict(os.environ, env), patch.object(reuse, 'verify_producer', return_value='b' * 40), \
                     patch.object(components.shutil, 'copy2', wraps=copy) as copied:
                    with self.assertRaisesRegex(ValueError, 'symbolic link'): components.restore(root, 'wine', '123')
                    copied.assert_not_called()
                self.assertTrue(binary.is_symlink() if kind != 'ancestor' else binary.parent.is_symlink())
                if kind == 'dangling': self.assertFalse(sentinel.exists())
                else: self.assertEqual(sentinel.read_bytes(), b'preserve target')

    def test_native_package_and_restore_validate_actual_upstream_sources(self):
        with source_fixture() as (root, upstream):
            fixture_record(upstream, native_build.native_inputs())
            for name in components.PATHS['madeira-native']:
                p = root / name
                if not p.suffix: p.mkdir(parents=True, exist_ok=True)
            env = {'NATIVE_TOOLCHAIN': 'a' * 64, 'GITHUB_REF_NAME': 'main'}
            source = upstream / 'Makefile'; original = source.read_bytes()
            with patch.object(components, 'frontend_module', return_value=native_build), patch.dict(os.environ, env), \
                 patch.object(reuse, 'git', return_value='b' * 40), patch.object(reuse, 'verify_producer', return_value='b' * 40):
                source.write_bytes(original + b'changed build input\n')
                with self.assertRaisesRegex(ValueError, 'upstreamSources'): components.package(root, 'madeira-native')
                self.assertFalse((root / '.build/madeira-native-compiled-transfer').exists())
                source.write_bytes(original); components.package(root, 'madeira-native')
                source.write_bytes(original + b'changed build input\n')
                library = upstream / 'app/Madeira/libswresample.a'; library.write_bytes(b'preserve destination')
                with self.assertRaisesRegex(ValueError, 'upstreamSources'): components.restore(root, 'madeira-native', '123')
                self.assertEqual(library.read_bytes(), b'preserve destination')
                self.assertEqual(source.read_bytes(), original + b'changed build input\n')

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
        for component in ('madeira-native', 'madeira-windows'):
            step = workflow.split('      - name: Retain ' + component + ' compilation\n')[1].split('      - name:')[0]
            self.assertIn(f"if: steps.compiled_{component.replace('-', '_')}.outputs.run_id == ''", step)
            self.assertIn('retention-days: 14', step)
            self.assertLess(workflow.index('Retain ' + component + ' compilation'), workflow.index('name: Build without signing'))

    def test_helper_edits_reuse_libraries_but_media_and_fex_edits_rebuild(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '-q'); git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            git('remote', 'add', 'origin', str(root))
            scripts = 'iridium/apps/ios/Scripts/'
            support = 'iridium/apps/ios/MadeiraSupport/'
            helpers = (scripts + 'build_controller_runtime.sh',
                       support + 'xinput.c', support + 'xinput.def', support + 'prerequisites.c')
            libraries = (scripts + 'build_media_runtime.sh', 'testrepos/Madeira/FEX/source.cc',
                         'ci/prepare-media-sdk.sh')
            for name in helpers + libraries:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('original input')
            workflow = root / reuse.WORKFLOW
            workflow.parent.mkdir(parents=True)
            workflow.write_text('jobs:\n  build:\n    runs-on: xcode-27\n    steps:\n'
                                '      - name: Compile native\n        run: bash ci/prepare-native-runtime.sh\n')
            def commit():
                git('add', '.'); git('commit', '-qm', 'fixture')
            commit(); revision = git('rev-parse', 'HEAD')
            for name in helpers:
                (root / name).write_text('changed helper')
                commit()
                reuse.compatible(root, revision, 'native')
            for name in libraries:
                with self.subTest(library=name):
                    (root / name).write_text('changed library')
                    commit()
                    with self.assertRaisesRegex(ValueError, 'Changed producer input'):
                        reuse.compatible(root, revision, 'native')
                    (root / name).write_text('original input')
                    commit()

    def test_helpers_are_always_rebuilt_after_library_cache_and_before_staging(self):
        workflow = (components.ROOT / reuse.WORKFLOW).read_text()
        for component, action in (('madeira-native', 'native'), ('madeira-windows', 'windows')):
            step = workflow.split('      - name: Compile ' + component + '\n')[1].split('      - name:')[0]
            self.assertNotIn('if:', step)
            self.assertIn('ci/madeira-frontend.py ' + action, step)
            self.assertLess(workflow.index('Compile ' + component), workflow.index('Check build prerequisites'))
        self.assertNotIn('build_controller_runtime.sh', workflow)
