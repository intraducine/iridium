"""Execute the shared app input model; no emulator or app build is required."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'


class RuntimeInputTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for input model execution')
    def test_polled_input_model(self):
        with tempfile.TemporaryDirectory() as folder:
            executable = Path(folder) / 'input-model-test'
            subprocess.run([
                'swiftc', str(IOS / 'RuntimeSupport/IridiumPolledInput.swift'),
                str(IOS / 'RuntimeTests/Input/main.swift'), '-o', str(executable),
            ], check=True, timeout=60)
            subprocess.run([str(executable)], check=True, timeout=30)

    def test_session_only_acknowledges_actual_core_polls(self):
        session = (IOS / 'MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        self.assertIn('private var digitalInput = IridiumPolledInput()', session)
        self.assertEqual(session.count('acknowledge(controls, polled: frame.input_polled)'), 2)
        self.assertIn('guard polled else { return }', session)
        self.assertIn('digitalInput.cancel()', session)
        self.assertIn('func resetInput() { releaseButtons() }', session)
        self.assertIn('func setButtons(_ buttons: UInt16, source: String)', session)
        self.assertIn('digitalInput.setButtons(buttons, source: source)', session)
        self.assertNotIn('touchButtons', session)
        self.assertNotIn('keyboardButtons', session)
        # Existing lifecycle cancellation and queue/lease ownership remain.
        for text in ['phase = .paused; releaseButtons()', 'phase = .stopping; releaseButtons()',
                     'guard queueOwner == owner', 'guard self.lease == owner']:
            self.assertIn(text, session)


if __name__ == '__main__':
    unittest.main()
