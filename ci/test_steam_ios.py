import subprocess
import unittest
from unittest.mock import patch

from test_manual_build import load

steam_ios = load('steam_ios_tests', 'check-steam-ios.py')


class SteamIOSSimulatorTests(unittest.TestCase):
    def test_spawn_readiness_retries_until_core_simulator_accepts_processes(self):
        responses = [
            subprocess.CompletedProcess([], 1),
            subprocess.CompletedProcess([], 0),
        ]
        with patch.object(steam_ios.subprocess, 'run', side_effect=responses) as run, \
             patch.object(steam_ios.time, 'sleep') as sleep:
            steam_ios.wait_for_spawn('device', timeout=30, interval=1)
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(1)
        self.assertEqual(run.call_args_list[0].args[0],
                         ['xcrun', 'simctl', 'spawn', 'device', '/usr/bin/true'])

    def test_spawn_readiness_rejects_a_simulator_that_never_becomes_usable(self):
        failed = subprocess.CompletedProcess([], 1)
        with patch.object(steam_ios.subprocess, 'run', return_value=failed), \
             patch.object(steam_ios.time, 'monotonic', side_effect=[10, 10]), \
             patch.object(steam_ios.time, 'sleep') as sleep:
            with self.assertRaisesRegex(RuntimeError, 'did not become spawn-ready'):
                steam_ios.wait_for_spawn('device', timeout=0, interval=1)
        sleep.assert_not_called()

    def test_spawn_probe_treats_command_timeout_as_not_ready(self):
        with patch.object(steam_ios.subprocess, 'run',
                          side_effect=subprocess.TimeoutExpired(['simctl'], 15)):
            self.assertFalse(steam_ios.simulator_can_spawn('device'))


if __name__ == '__main__':
    unittest.main()
