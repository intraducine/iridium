"""Exercise launch diagnostics without requiring a signed app or device."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'


class LaunchEntitlementsTests(unittest.TestCase):
    def test_diagnostics_run_before_jit_without_gating_launch(self):
        source = (IOS / 'MadeiraSupport/MadeiraRuntimeAdapter.swift').read_text()
        start = source.index('static func start(')
        diagnostics = source.index('MadeiraLaunchEntitlements.logLines(', start)
        jit = source.index('jit_install_trap_handler()', start)
        self.assertLess(diagnostics, jit)
        block = source[diagnostics:source.index('#endif', diagnostics)]
        self.assertIn('isHosted: LiveContainerIntegration.isHosted()', block)
        self.assertIn('RuntimeLogCapture.writeLine(line)', block)
        self.assertNotIn('fail(', block)
        self.assertNotIn('return', block)
        self.assertNotIn('guard ', block)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler is not installed')
    def test_boolean_decoding_and_both_host_contexts(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'launch-entitlements'
            subprocess.run([
                shutil.which('swiftc'),
                str(IOS / 'MadeiraSupport/MadeiraLaunchEntitlements.swift'),
                str(IOS / 'MadeiraSupportTests/LaunchEntitlementsCheck.swift'),
                '-o', str(binary),
            ], check=True, capture_output=True, text=True, timeout=120)
            result = subprocess.run(
                [str(binary)], check=True, capture_output=True, text=True, timeout=30)
            self.assertIn('Launch entitlement checks passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
