"""Production registry/store checks; core execution is an explicit build check."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import sameboy_bootroms as boots

ROOT = Path(__file__).resolve().parents[1]


class SameBoyBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.core = self.root / 'core'
        (self.core / 'BootROMs').mkdir(parents=True)
        for name in ('Makefile', 'version.mk', 'BootROMs/original.asm'):
            (self.core / name).write_text('fixture source\n')
        self.manifest = self.root / 'boots.json'
        self.record = {'revision': boots.REVISION, 'rgbdsRevision': boots.RGBDS_REVISION,
                       'rgbdsVersion': boots.RGBDS_VERSION, 'sourceSHA256': boots.source_hashes(self.core),
                       'bootROMs': {name: {'hex': [bytes(size).hex()],
                                          'sha256': hashlib.sha256(bytes(size)).hexdigest()}
                                   for name, size in boots.MODELS.items()}}
        self.write_manifest()

    def write_manifest(self):
        self.manifest.write_text(json.dumps(self.record))

    def test_all_boot_data_and_source_hashes_are_verified(self):
        result = boots.read_bootroms(self.core, self.manifest)
        self.assertEqual({name: len(data) for name, data in result.items()}, boots.MODELS)
        (self.core / 'BootROMs/original.asm').write_text('changed source\n')
        with self.assertRaises(ValueError): boots.read_bootroms(self.core, self.manifest)

    def test_corrupt_missing_and_wrong_size_boots_are_rejected(self):
        self.record['bootROMs']['dmg']['hex'] = ['ff' * 256]
        self.write_manifest()
        with self.assertRaises(ValueError): boots.read_bootroms(self.core, self.manifest)
        self.record['bootROMs']['dmg'] = {'hex': ['00'], 'sha256': boots.digest(b'\0')}
        self.write_manifest()
        with self.assertRaises(ValueError): boots.read_bootroms(self.core, self.manifest)
        del self.record['bootROMs']['dmg']
        self.write_manifest()
        with self.assertRaises(ValueError): boots.read_bootroms(self.core, self.manifest)

    def test_source_symlinks_and_invented_provenance_are_rejected(self):
        self.record['revision'] = '0' * 40
        self.write_manifest()
        with self.assertRaises(ValueError): boots.read_bootroms(self.core, self.manifest)
        source = self.core / 'BootROMs/original.asm'
        source.unlink(); source.symlink_to(self.core / 'Makefile')
        with self.assertRaises(ValueError): boots.source_hashes(self.core)

    def test_regeneration_does_not_overwrite_before_running_tools(self):
        with patch.object(boots.subprocess, 'check_output') as command:
            with self.assertRaises(ValueError):
                boots.regenerate(self.core, self.root / 'tools', self.manifest)
        command.assert_not_called()

    def test_adapter_change_is_exact_and_public_api_only(self):
        spec = importlib.util.spec_from_file_location('core_builder', ROOT / 'ci/build-sameboy.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        before = 'GB_set_sample_rate(&gameboy[i], GB_get_clock_rate(&gameboy[i]) / 2);'
        self.assertEqual(builder.audio_adapter(before), 'GB_set_sample_rate(&gameboy[i], 48000);')
        for text in ('', before + before):
            with self.assertRaises(ValueError): builder.audio_adapter(text)


class MultiRuntimeTests(unittest.TestCase):
    def test_live_target_includes_core_sources_and_guards(self):
        spec = importlib.util.spec_from_file_location('runtime_overlay', ROOT / 'ci/madeira-frontend.py')
        overlay = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(overlay)
        upstream = ROOT / 'vendor/Madeira/app/Madeira'
        if not upstream.is_dir():
            self.skipTest('Pinned Madeira source not initialized')
        source = (upstream / 'ContentView.swift').read_text()
        result = overlay.overlay('ContentView.swift', source)
        self.assertEqual(result.count('guard !IridiumConsoleSession.shared.isActive'), 4)
        # A changed entry point must fail the declared overlay rather than
        # silently removing the exclusive-runtime check.
        with self.assertRaises(ValueError):
            overlay.overlay('ContentView.swift', source.replace('private func startLibraryEntry(', 'private func renamedEntry('))

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for runtime model execution')
    def test_runtime_model_and_store(self):
        source = ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumRuntime.swift'
        fixture = ROOT / 'iridium/apps/ios/RuntimeTests/main.swift'
        with tempfile.TemporaryDirectory() as folder:
            executable = Path(folder) / 'runtime-test'
            subprocess.run(['swiftc', str(source), str(fixture), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=30)

    @unittest.skipUnless(os.environ.get('IRIDIUM_TEST_CORE') == '1',
                         'Native core execution is explicit; source CI must not trigger emulator builds')
    def test_actual_core_execution(self):
        subprocess.run(['python3', str(ROOT / 'ci/check-sameboy.py')], check=True, timeout=180)


if __name__ == '__main__':
    unittest.main()
