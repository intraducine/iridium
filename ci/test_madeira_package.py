"""Native packaging, profile transitions and retained dependency regressions."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(filename):
    spec = importlib.util.spec_from_file_location(filename.replace('-', '_'), ROOT / 'ci' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


madeira = load('madeira-package.py')
prerequisites = load('check-ipa-prerequisites.py')
source = load('collect-release-source.py')
staging = load('local_runtime_staging.py')
refresh = load('prepare-local-runtime.py')
packager = load('package-unsigned-ipa.py')
prepared = load('prepared-runtime.py')


class MadeiraPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'checkout [with spaces]'
        self.root.mkdir()
        self.app = self.root / 'products/Iridium.app'
        self.app.mkdir(parents=True)
        (self.app / 'Info.plist').write_bytes(plistlib.dumps({'IridiumRuntimeProfile': 'madeira'}))
        for name in madeira.APP_FILES + tuple('Frameworks/' + n + '.framework/' + n
                                             for n in madeira.FRAMEWORKS + ('MadeiraNative',)):
            self.write(self.app / name)

    def write(self, path, data=b'fixture'):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def test_native_inventory_needs_no_linux_but_requires_installer_and_shared_inputs(self):
        madeira.check_app(self.app)
        for name in ('i386-windows/ntdll.dll', 'aarch64-windows/xtajit.dll',
                     'MediaRuntime/mfreadwrite.dll', 'Frameworks/libEGL.framework/libEGL',
                     'Frameworks/MadeiraNative.framework/MadeiraNative', 'nls/l_intl.nls'):
            with self.subTest(name=name):
                path = self.app / name
                path.unlink()
                with self.assertRaisesRegex(ValueError, 'Missing Madeira'):
                    madeira.check_app(self.app)
                self.write(path)

    def test_finalize_removes_incremental_legacy_copies_after_swiftpm_copy(self):
        retained = {name: (self.app / name).read_bytes() for name in madeira.APP_FILES}
        for name in madeira.LEGACY_PATHS:
            self.write(self.app / name / 'stale.bin')
        madeira.finalize(self.app)
        madeira.finalize(self.app)
        self.assertEqual(retained, {name: (self.app / name).read_bytes() for name in retained})
        for name in madeira.LEGACY_PATHS:
            self.assertFalse((self.app / name).exists())

    def test_package_validation_rejects_stale_legacy_payload(self):
        for name in (*madeira.LEGACY_PATHS, 'nested/wine-userland.tar.zst'):
            with self.subTest(name=name):
                path = self.app / name
                self.write(path)
                with self.assertRaisesRegex(ValueError, 'legacy|Linux'):
                    madeira.check_app(self.app)
                path.unlink()
        # Exercise the real packager entry point before any signing operation.
        info = plistlib.loads((self.app / 'Info.plist').read_bytes())
        info['CFBundleIdentifier'] = 'software.iridium'
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(info))
        self.write(self.app / 'IridiumWineUserland/fixture')
        with self.assertRaisesRegex(ValueError, 'legacy runtime'):
            packager.check_payload(self.app)

    def test_cleanup_does_not_follow_parent_symlink_or_erase_saves(self):
        saves = self.root / 'saves'
        self.write(saves / 'keep.sav')
        fallback = self.app / 'Iridium_IridiumRuntime.bundle'
        fallback.symlink_to(saves, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'outside'):
            madeira.finalize(self.app)
        self.assertEqual((saves / 'keep.sav').read_bytes(), b'fixture')
        fallback.unlink()
        (self.app / 'IridiumWineUserland').symlink_to(saves)
        madeira.finalize(self.app)
        self.assertTrue((saves / 'keep.sav').is_file())

    def test_swiftpm_preparation_retains_canonical_developer_bundle(self):
        canonical = self.root / 'iridium-runtime-sdk/build/iridium-runtime-base/Userland/wine-userland.tar.zst'
        self.write(canonical)
        resources = self.root / 'iridium/packages/runtime/Sources/IridiumRuntime/Resources/BundledRuntime'
        self.write(resources / 'iridium-runtime-base/Userland/stale')
        madeira.prepare(self.root)
        self.assertTrue(canonical.is_file())
        self.assertFalse((resources / 'iridium-runtime-base').exists())
        self.assertEqual(json.loads((resources / 'madeira-profile.json').read_text())['runtimeProfile'], 'madeira')

    def test_real_stage_checks_sources_without_linux_and_copies_shared_frameworks(self):
        src = self.root / 'iridium/apps/ios'
        upstream = self.root / 'testrepos/Madeira/app/Madeira'
        for name in madeira.APP_FILES:
            origin = src if name.startswith(('MediaRuntime/', 'ControllerRuntime/')) else upstream
            self.write(origin / name)
        frameworks = self.root / 'Amethyst-iOS/Natives/resources/Frameworks'
        for name in madeira.FRAMEWORKS:
            self.write(frameworks / (name + '.framework') / name, b'shared framework')
        env = dict(os.environ, SRCROOT=str(src), TARGET_BUILD_DIR=str(self.app.parent),
                   UNLOCALIZED_RESOURCES_FOLDER_PATH='Iridium.app', IRIDIUM_RUNTIME_PROFILE='madeira',
                   CODE_SIGNING_ALLOWED='NO')
        script = ROOT / 'iridium/apps/ios/Scripts/stage_runtime_userland.sh'
        # Copy script and its dependency into the fixture's actual relative layout.
        self.write(src / 'Scripts/stage_runtime_userland.sh', script.read_bytes())
        self.write(self.root / 'ci/madeira-package.py', (ROOT / 'ci/madeira-package.py').read_bytes())
        for args in (['--check'], []):
            result = subprocess.run(['sh', str(src / 'Scripts/stage_runtime_userland.sh'), *args],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.app / 'Frameworks/libEGL.framework/libEGL').read_bytes(), b'shared framework')
        madeira.check_app(self.app)

    def test_real_aggregate_finalizer_prunes_late_swiftpm_copy_and_installs_bridges(self):
        src = self.root / 'iridium/apps/ios'
        for name in ('finalize_iridium_app.sh',):
            self.write(src / 'Scripts' / name, (ROOT / 'iridium/apps/ios/Scripts' / name).read_bytes())
        self.write(self.root / 'ci/madeira-package.py', (ROOT / 'ci/madeira-package.py').read_bytes())
        self.write(self.app / 'Iridium_IridiumRuntime.bundle/BundledRuntime/iridium-runtime-base/Userland/stale')
        tools = self.root / 'tools'
        self.write(tools / 'codesign', b'#!/bin/sh\nexit 1\n')
        (tools / 'codesign').chmod(0o755)
        env = dict(os.environ, SRCROOT=str(src), CONFIGURATION_BUILD_DIR=str(self.app.parent),
                   PATH=str(tools) + os.pathsep + os.environ['PATH'])
        result = subprocess.run(['sh', str(src / 'Scripts/finalize_iridium_app.sh')],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        madeira.check_app(self.app)
        self.assertEqual((self.app / 'arm64ec-windows/mfreadwrite.dll').read_bytes(),
                         (self.app / 'MediaRuntime/mfreadwrite.dll').read_bytes())
        for name in ('xinput1_1', 'xinput1_2', 'xinput1_3', 'xinput1_4', 'xinput9_1_0'):
            self.assertEqual((self.app / ('arm64ec-windows/' + name + '.dll')).read_bytes(),
                             (self.app / 'ControllerRuntime/arm64ec/xinput.dll').read_bytes())

    def test_prerequisites_filter_only_linux_payload_and_keep_sdk_link_archives(self):
        required = prerequisites.required_for_profile('madeira')
        self.assertNotIn('legacy runtime host and userland', required)
        self.assertIn('legacy native link libraries', required)
        for paths in required.values():
            for name in paths:
                self.write(self.root / name)
        for name in ('binary-release-blockers.json', 'binary-package-blockers.json'):
            self.write(self.root / 'ci' / name, b'[]')
        self.assertEqual(prerequisites.blockers(self.root, package=True), [])
        self.assertTrue(prerequisites.blockers(self.root, profile='legacy'))
        (self.root / required['legacy native link libraries'][0]).unlink()
        self.assertTrue(prerequisites.blockers(self.root))

    def test_source_package_omits_unshipped_debian_tree_and_retains_linked_source(self):
        staged = self.root / 'source'
        self.write(staged / 'Wine/LICENSE', b'notice')
        output = self.root / 'source.tar.gz'
        source.write_source_package(staged, self.root / 'missing-linux', output, include_linux=False)
        with tarfile.open(output) as archive:
            self.assertEqual(archive.extractfile('corresponding-source/Wine/LICENSE').read(), b'notice')
            self.assertFalse(any('/linux' in name for name in archive.getnames()))
        with self.assertRaisesRegex(ValueError, 'Missing Linux'):
            source.write_source_package(staged, self.root / 'missing-linux', output)

    def test_local_madeira_rebuild_does_not_require_or_rebuild_linux_bundle(self):
        media = self.root / 'media.a'
        translator = self.root / 'translator.a'
        self.write(media)
        self.write(translator)
        with patch.dict(os.environ, IRIDIUM_RUNTIME_PROFILE='madeira'), \
             patch.object(refresh, 'ROOT', self.root), patch.object(refresh, 'MEDIA', media), \
             patch.object(refresh, 'USERLAND', self.root / 'missing-userland'), \
             patch.object(refresh, 'TRANSLATOR', translator), patch.object(refresh, 'ensure_prefix_transfer'), \
             patch.object(refresh, 'run') as run, patch.object(refresh, 'head_short', return_value='a' * 12):
            refresh.rebuild_native_runtime(None)
        self.assertFalse(any('build_runtime_bundle.sh' in str(call) for call in run.call_args_list))
        self.assertEqual(json.loads((self.root / '.build/madeira-native-producer.json').read_text())['version'], 'local-' + 'a' * 12)

    def test_local_retained_inputs_and_outputs_drop_only_linux_requirements(self):
        (self.root / 'ci').mkdir(exist_ok=True)
        shutil.copy2(ROOT / 'ci/check-ipa-prerequisites.py', self.root / 'ci/check-ipa-prerequisites.py')
        with patch.dict(os.environ, IRIDIUM_RUNTIME_PROFILE='madeira'):
            self.assertFalse(any('wine-userland' in name for name in staging.retained_inputs(self.root)))
            with self.assertRaises(ValueError) as failure:
                staging.native_output_inventory(self.root)
            missing = str(failure.exception)
            self.assertNotIn('runtime-host.bin', missing)
            self.assertIn('libiridium-fex-ios-embedded.a', missing)
            self.assertIn('i386-windows/ntdll.dll', missing)

    def test_compiler_fingerprint_requires_media_but_no_linux_artifact(self):
        calls = []
        def digest(path):
            calls.append(str(path))
            if 'linux-transfer' in str(path):
                raise FileNotFoundError('Linux input must not be read')
            return 'media-fixture'
        with patch.dict(os.environ, IRIDIUM_RUNTIME_PROFILE='madeira'), \
             patch.object(prepared.subprocess, 'check_output', return_value='compiler fixture'), \
             patch.object(prepared.inputs, 'digest', side_effect=digest):
            native = prepared.toolchain()
        self.assertTrue(any('media-transfer' in name for name in calls))
        self.assertFalse(any('linux-transfer' in name for name in calls))
        with patch.dict(os.environ, IRIDIUM_RUNTIME_PROFILE='legacy'), \
             patch.object(prepared.subprocess, 'check_output', return_value='compiler fixture'), \
             patch.object(prepared.inputs, 'digest', return_value='media-fixture'):
            self.assertNotEqual(native, prepared.toolchain())

    def test_normal_workflow_and_adapter_cannot_select_unshipped_runtime(self):
        workflow = (ROOT / '.github/workflows/build-unsigned-ipa.yml').read_text()
        self.assertIn('ci/madeira-frontend.py app', workflow)
        for old in ('linux-userland:', 'name: linux-runtime-with-source', 'run: bash ci/prepare-legacy-bundle.sh'):
            self.assertNotIn(old, workflow)
        adapter = (ROOT / 'iridium/apps/ios/MadeiraSupport/MadeiraRuntimeAdapter.swift').read_text()
        enabled = adapter.split('static let enabled: Bool = {', 1)[1].split('}()', 1)[0]
        self.assertIn('return true', enabled)
        self.assertNotIn('IRIDIUM_RUNTIME', enabled)
        spec = (ROOT / 'iridium/apps/ios/madeira.yml').read_text()
        self.assertIn('IRIDIUM_RUNTIME_PROFILE: madeira', spec)
        self.assertIn('i386-windows', spec)


if __name__ == '__main__':
    unittest.main()
