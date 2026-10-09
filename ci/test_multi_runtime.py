"""Production registry/store checks; core execution is an explicit build check."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


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
