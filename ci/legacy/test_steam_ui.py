"""Check that the early SDK command receives real background-download sources."""
import contextlib
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

from test_manual_build import load

steam_ui = load('steam_ui_checks', 'check-steam-ui.py')


class SteamUICompilationTests(unittest.TestCase):
    def test_sdk_command_includes_production_background_types_and_app_intent(self):
        def inspect_command(argv, **options):
            self.assertTrue(options['check'])
            self.assertEqual(options['timeout'], 180)
            self.assertIn('-typecheck', argv)
            self.assertIn('-parse-as-library', argv)
            self.assertIn(['-D', 'IRIDIUM_APP'], [argv[index:index + 2] for index in range(len(argv) - 1)])
            paths = [Path(item) for item in argv if item.endswith('.swift')]
            host = paths[-1].read_text()
            production = '\n'.join(path.read_text() for path in paths[:-1])
            for symbol in ('SteamChunkBatch', 'SteamChunkWakeHandoff', 'SteamBackgroundSession',
                           'SteamBackgroundAppDelegate', 'SteamDownloadActivity', 'SteamDownloadRuntime',
                           'SteamDownloadActivityAttributes', 'CancelSteamDownloadIntent'):
                definition = rf'\b(?:class|struct|enum)\s+{symbol}\b'
                with self.subTest(symbol=symbol):
                    self.assertRegex(production, definition)
                    self.assertNotRegex(host, definition)
            return subprocess.CompletedProcess(argv, 0)

        with patch.object(steam_ui.subprocess, 'check_output', return_value='/synthetic/iPhoneOS.sdk'), \
             patch.object(steam_ui.subprocess, 'run', side_effect=inspect_command) as compiler, \
             contextlib.redirect_stdout(io.StringIO()):
            steam_ui.main()
        compiler.assert_called_once()


if __name__ == '__main__':
    unittest.main()
