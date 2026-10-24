"""Public upstream fixtures never exempt other signing files or ship as keys."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import load

ROOT = Path(__file__).resolve().parents[1]
COLLECT = load('fixture_source_collect', 'collect-madeira-source.py')
FIXTURES = json.loads((ROOT / 'ci/public-signing-fixtures.json').read_text())
NAME = 'vendor/PPSSPP/UWP/PPSSPP_UWP_TemporaryKey.pfx'


class PublicSigningFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'ci').mkdir()
        shutil.copy2(ROOT / 'check-public-source.py', self.root)
        # Synthetic bytes exercise the policy without committing a signing key.
        self.data = b'public upstream signing fixture\n'
        self.approve(self.data)

    def approve(self, data):
        self.fixture = {**FIXTURES[NAME], 'sha256': hashlib.sha256(data).hexdigest()}
        (self.root / 'ci/public-signing-fixtures.json').write_text(json.dumps({NAME: self.fixture}))

    def write(self, root, name=NAME, data=None):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.data if data is None else data)
        return path

    def scan(self, *identifiers):
        return subprocess.run([sys.executable, '-B', str(self.root / 'check-public-source.py'),
                               *identifiers], capture_output=True, text=True)

    def exclude(self, stage):
        with patch.object(COLLECT, 'ROOT', self.root):
            return COLLECT.exclude_signing_fixtures(stage)

    def test_scan_requires_exact_path_and_digest(self):
        path = self.write(self.root)
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        path.write_bytes(b'changed fixture')
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn(NAME + ': signing material', result.stdout)
        path.unlink()
        for name in ('maintainer.pfx', 'vendor/PPSSPP/UWP/other.pfx', 'copy.PFX',
                     'profile.mobileprovision', 'profile.provisionprofile', 'certificate.p12'):
            with self.subTest(name=name):
                other = self.write(self.root, name)
                result = self.scan()
                self.assertEqual(result.returncode, 1)
                self.assertIn(name + ': signing material', result.stdout)
                other.unlink()

    def test_scan_keeps_other_patterns_and_targeted_identifiers(self):
        data = b'-----BEGIN ' + b'PRIVATE KEY-----\nfixture\n'
        self.approve(data)
        self.write(self.root, data=data)
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn(NAME + ': private key', result.stdout)
        self.approve(self.data)
        self.write(self.root)
        result = self.scan('public upstream signing fixture')
        self.assertEqual(result.returncode, 1)
        self.assertIn(NAME + ': private identifier 1', result.stdout)

    def test_fast_scan_preserves_case_insensitive_patterns_and_literal_identifiers(self):
        cases = {
            'private key': b'-----begin ' + b'ec private key-----',
            'access token': b'GiThUb_' + b'PaT_' + b'example' * 5,
            'device identifier': b'00008' + b'aBc-' + b'0123aBcD' * 2,
            'configured signing team': b'development_team: ' + b'AbCdEf0123',
        }
        file = self.root / 'candidate.txt'
        for category, data in cases.items():
            with self.subTest(category=category):
                file.write_bytes(b'ordinary source\n' * 1000 + data)
                result = self.scan()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('candidate.txt: ' + category, result.stdout)
        file.write_bytes(b'ordinary source\n' * 1000)
        self.assertEqual(self.scan().returncode, 0)
        file.write_bytes(b'Literal.+[Identifier]')
        self.assertIn('candidate.txt: private identifier 1', self.scan('literal.+[identifier]').stdout)

    def test_public_pem_source_exception_is_exact_and_keeps_other_patterns(self):
        name = 'vendor/Engine/public-example.c'
        data = b'-----BEGIN ' + b'PRIVATE KEY-----\npublic synthetic marker\n'
        manifest = self.root / 'ci/public-key-source-fixtures.json'
        manifest.write_text(json.dumps({name: {'sha256': hashlib.sha256(data).hexdigest()}}))
        path = self.write(self.root, name, data)
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.scan('public synthetic marker')
        self.assertEqual(result.returncode, 1)
        self.assertIn(name + ': private identifier 1', result.stdout)
        path.write_bytes(data + b'changed')
        self.assertEqual(self.scan().returncode, 1)
        path.unlink()
        self.write(self.root, 'vendor/Engine/copied-example.c', data)
        self.assertEqual(self.scan().returncode, 1)

    def test_scan_checks_initialized_dependency_and_untracked_signing_files(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        child = self.root / 'vendor/PPSSPP'
        child.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(child)], check=True)
        self.write(self.root)
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.write(self.root, 'vendor/PPSSPP/UWP/maintainer.pfx')
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn('vendor/PPSSPP/UWP/maintainer.pfx: signing material', result.stdout)

    def test_stage_omits_only_exact_fixture_and_preserves_inputs(self):
        original = self.write(self.root)
        stage = self.root / 'stage'
        staged = self.write(stage)
        source = self.write(stage, 'vendor/PPSSPP/UWP/UWP.vcxproj', b'upstream project')
        ios = self.write(stage, 'vendor/PPSSPP/libretro/libretro.cpp', b'upstream core')
        self.assertEqual(self.exclude(stage), [{'path': NAME, **self.fixture}])
        self.assertFalse(staged.exists())
        self.assertEqual(original.read_bytes(), self.data)
        self.assertEqual(source.read_bytes(), b'upstream project')
        self.assertEqual(ios.read_bytes(), b'upstream core')

    def test_stage_rejects_changed_and_unreviewed_signing_files(self):
        for name, data in ((NAME, b'changed'), ('maintainer.pfx', self.data),
                           ('copy.PFX', self.data), ('certificate.p12', self.data),
                           ('profile.mobileprovision', self.data),
                           ('profile.provisionprofile', self.data)):
            with self.subTest(name=name):
                stage = self.root / 'stage'
                path = self.write(stage, name, data)
                with self.assertRaisesRegex(ValueError, 'Unexpected signing material'):
                    self.exclude(stage)
                self.assertTrue(path.exists())
                shutil.rmtree(stage)

    def test_signing_symlink_is_never_exempt(self):
        target = self.write(self.root, 'public-fixture', self.data)
        path = self.root / NAME
        path.parent.mkdir(parents=True)
        path.symlink_to(target)
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn(NAME + ': signing material', result.stdout)
        with self.assertRaisesRegex(ValueError, 'Unexpected signing material'):
            self.exclude(self.root)

    def test_stage_rejects_signing_symlinks_to_directories_and_missing_targets(self):
        directory = self.root / 'directory'
        directory.mkdir()
        for name in (NAME, 'maintainer.pfx'):
            for target in (directory, self.root / 'missing'):
                with self.subTest(name=name, target=target.name):
                    path = self.root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.symlink_to(target)
                    with self.assertRaisesRegex(ValueError, 'Unexpected signing material'):
                        self.exclude(self.root)
                    path.unlink()

    def test_collection_records_exclusion_and_archives_no_signing_fixture(self):
        (self.root / '.build').mkdir()
        (self.root / 'ci/runtime-inputs.json').write_text('[]')
        app = self.root / 'app'
        for directory in ('licenses', 'legal', 'd3d12'):
            (app / directory).mkdir(parents=True)
        maps = self.root / 'maps'
        maps.mkdir()
        (maps / 'app-LinkMap.txt').touch()
        psp = self.root / 'psp'
        psp.mkdir()
        external_data = b'locked external source fixture'
        external_hash = hashlib.sha256(external_data).hexdigest()
        external = [{'name': 'MoltenVK', 'sha256': external_hash}]
        (self.root / 'ci/moltenvk-source-inputs.json').write_text(json.dumps(external))
        downloads = self.root / '.build/runtime-downloads'
        downloads.mkdir()
        (downloads / (external_hash + '.tar')).write_bytes(external_data)
        (psp / 'component.json').write_text(json.dumps({'moltenVK': {'sourceInputs': external}}))
        output = self.root / 'output'
        native_inventory = {'schema': 1, 'files': {'vendor/Madeira/build/build.sh': '100644'},
                            'revisions': {'vendor/Madeira': 'test revision'}}

        def snapshot(repo, destination, revisions):
            destination.mkdir(parents=True, exist_ok=True)
            revisions[repo.relative_to(self.root).as_posix()] = 'test revision'
            if repo == self.root:
                self.write(destination)
                self.write(destination, 'vendor/PPSSPP/libretro/libretro.cpp', b'upstream core')
                self.write(destination, 'vendor/Madeira/build/build.sh', b'# fixture build recipe\n')

        def command(args, **kwargs):
            if args[0] == 'cargo':
                Path(args[-1]).mkdir(parents=True)
            return 'test tool output'

        def snapshot_freetype(destination, revisions, *, source_root):
            self.assertEqual(destination, source_root / 'vendor/Madeira/research/freetype')
            snapshot(self.root / 'vendor/Madeira/research/freetype', destination, revisions)

        with patch.object(COLLECT, 'ROOT', self.root), \
                patch.object(COLLECT.build, 'UPSTREAM', self.root / 'vendor/Madeira'), \
                patch.object(COLLECT.build, 'PSP_OUTPUT', psp), \
                patch.object(COLLECT.build, 'verify_pin'), \
                patch.object(COLLECT.build, 'native_source_inventory', return_value=native_inventory), \
                patch.object(COLLECT.build, 'check_bundle'), \
                patch.object(COLLECT.audit, 'inventory', return_value=[{'path': 'Iridium'}]), \
                patch.object(COLLECT.audit, 'static_inputs', return_value=[
                    {'archive': 'libntdll_unix.a'}, {'archive': 'libIridiumSameBoy.a'}]), \
                patch.object(COLLECT, 'snapshot', side_effect=snapshot), \
                patch.object(COLLECT, 'snapshot_freetype', side_effect=snapshot_freetype), \
                patch.object(COLLECT.subprocess, 'check_output', side_effect=command):
            COLLECT.collect(app, output, maps)

        manifest = json.loads((output / 'COMPONENT-MANIFEST.json').read_text())
        self.assertEqual(manifest['source_exclusions'], [{'path': NAME, **self.fixture}])
        self.assertEqual(manifest['psp_external_source_inputs'], external)
        with tarfile.open(output / 'Iridium-corresponding-source.tar.gz') as archive:
            self.assertNotIn('iridium/' + NAME, archive.getnames())
            self.assertEqual(archive.extractfile('iridium/.build/runtime-downloads/' + external_hash + '.tar').read(), external_data)
            self.assertEqual(archive.extractfile(
                'iridium/vendor/PPSSPP/libretro/libretro.cpp').read(), b'upstream core')
            self.assertEqual(json.load(archive.extractfile('iridium/COMPONENT-MANIFEST.json')),
                             manifest)
            self.assertEqual(json.load(archive.extractfile('iridium/MADEIRA-NATIVE-SOURCES.json')),
                             native_inventory)


if __name__ == '__main__': unittest.main()
