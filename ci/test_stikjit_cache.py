"""Hosted JIT reuse verifies the complete framework and preserves cold builds."""
import importlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch

import stikjit_frontend as jit

components = importlib.import_module('compiled-components')


class JITCacheTests(unittest.TestCase):
    def test_compiler_flags_and_tools_change_the_artifact_identity(self):
        with patch.object(jit, 'inputs', return_value=[]), patch.object(jit, 'digest', return_value='checked'), \
                patch.object(jit.subprocess, 'check_output', return_value='version one') as tools, \
                patch.dict(os.environ, {'RUSTFLAGS': ''}):
            original = jit.identity()
            tools.return_value = 'version two'
            self.assertNotEqual(original, jit.identity())
            tools.return_value = 'version one'
            with patch.dict(os.environ, {'RUSTFLAGS': '-C opt-level=1'}):
                self.assertNotEqual(original, jit.identity())

    def framework(self, root):
        output = root / '.build/stikjit-frontend'
        framework = output / 'StikJIT.framework'
        for name in ('StikJIT', 'universal.js', 'legacy.js', 'LICENSES-idevice.txt',
                     'Modules/StikJIT.swiftmodule/arm64-apple-ios.swiftmodule',
                     'Modules/StikJIT.swiftmodule/arm64-apple-ios.swiftinterface'):
            path = framework / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('checked ' + name)
        (framework / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': jit.MINIMUM_IOS}))
        record = {'inputs': {'recipe': 'checked'}, 'files': jit.framework_files(framework)}
        for path in (output / 'component.json', framework / 'IridiumJITTransport.json'):
            path.write_text(json.dumps(record))
        return output, framework

    def test_module_changes_missing_notices_and_added_files_reject_cached_framework(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output, framework = self.framework(root)
            with patch.object(jit, 'OUTPUT', output), patch.object(jit, 'verify_source'), \
                    patch.object(jit, 'identity', return_value={'recipe': 'checked'}):
                jit.verify(framework)
                module = framework / 'Modules/StikJIT.swiftmodule/arm64-apple-ios.swiftmodule'
                original = module.read_bytes()
                module.write_bytes(b'corrupt module')
                with self.assertRaises(ValueError): jit.verify(framework)
                module.write_bytes(original)
                notice = framework / 'LICENSES-idevice.txt'
                notice.unlink()
                with self.assertRaises(ValueError): jit.verify(framework)
                notice.write_text('checked LICENSES-idevice.txt')
                extra = framework / 'unrecorded.swiftmodule'
                extra.write_text('unexpected')
                with self.assertRaises(ValueError): jit.verify(framework)
                extra.unlink()
                extra.symlink_to(module)
                with self.assertRaises(ValueError): jit.verify(framework)

    def test_hosted_round_trip_and_corrupt_archive_fallback(self):
        verify_framework = jit.verify
        for corrupt in (False, True):
            with self.subTest(corrupt=corrupt), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                output, framework = self.framework(root)
                runner = root / 'ScriptRunner.swift'
                runner.write_text('checked')
                transfer = root / '.build/stikjit-frontend-compiled-transfer'
                env = {'GITHUB_REF_NAME': 'codex/test', 'REUSE_ASSETS': 'true',
                       'GITHUB_OUTPUT': str(root / 'outputs')}
                with patch.dict(os.environ, env), patch.object(jit, 'ROOT', root), \
                        patch.object(jit, 'OUTPUT', output), patch.object(jit, 'RUNNER', runner), \
                        patch.object(jit, 'identity', return_value={'recipe': 'checked'}), \
                        patch.object(jit, 'prepare_sources'), patch.object(jit, 'verify_source'), \
                        patch.object(jit, 'inputs', return_value=[]), \
                        patch.object(jit, 'verify', side_effect=lambda: verify_framework(framework)), \
                        patch.object(components.reuse, 'git', return_value='a' * 40), \
                        patch.object(components.reuse, 'select', return_value=''), \
                        patch.object(jit, 'build') as build:
                    jit.ensure()
                    build.assert_called_once()
                    saved = root / 'saved-artifact'
                    transfer.rename(saved)
                    shutil.rmtree(output)
                    if corrupt:
                        (saved / 'compiled.tar.gz').write_bytes(b'corrupt archive')
                    def download(command, **kwargs):
                        self.assertEqual(command[:4], ['gh', 'run', 'download', '42'])
                        shutil.copytree(saved, transfer)
                    with patch.object(components.reuse, 'select', return_value='42'), \
                            patch.object(components.reuse, 'verify_producer', return_value='a' * 40), \
                            patch.object(jit.subprocess, 'run', side_effect=download), \
                            patch.object(jit, 'build', side_effect=lambda: self.framework(root)) as fallback:
                        jit.ensure()
                        self.assertEqual(fallback.call_count, int(corrupt))
                        verify_framework(framework)
                    self.assertIn('rebuilt=' + str(corrupt).lower(), (root / 'outputs').read_text())


if __name__ == '__main__':
    unittest.main()
