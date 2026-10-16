"""Execute actual input bridges with deterministic fake cores, never emulators.

The tiny test-only API declarations allow this regression check to run with
uninitialized submodules and without Swift, Apple SDKs, game files or downloads.
They establish bridge behavior, not upstream ABI or device compatibility.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'ci/input'
BRIDGES = ROOT / 'iridium/apps/ios/RuntimeBridge'
CC = shutil.which('cc')


@unittest.skipUnless(CC and sys.platform in ('linux', 'darwin'),
                     'Host C bridge fixtures require a POSIX C compiler')
class InputPollContractTests(unittest.TestCase):
    def check_bridge(self, name):
        with tempfile.TemporaryDirectory(prefix='iridium-input-poll-') as temporary:
            executable = Path(temporary) / name
            command = [CC, '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                       '-UNDEBUG', '-I', str(FIXTURES), '-I', str(BRIDGES),
                       str(FIXTURES / (name + '.c')), '-lm']
            if sys.platform == 'linux':
                command.append('-ldl')
            command += ['-o', str(executable)]
            for args in (command, [str(executable)]):
                result = subprocess.run(args, capture_output=True, text=True, timeout=45)
                self.assertEqual(result.returncode, 0,
                                 '\n'.join([' '.join(args), result.stdout, result.stderr]))
            self.assertIn('PASS: ' + name, result.stdout)

    def test_psp_acknowledges_only_active_non_stopping_polls(self):
        self.check_bridge('check_psp_input_poll')

    def test_game_boy_acknowledges_only_active_polls(self):
        self.check_bridge('check_core_input_poll')


if __name__ == '__main__':
    unittest.main()
