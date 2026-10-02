import subprocess
import unittest
from unittest.mock import patch

from test_manual_build import load

steam_ios = load('steam_ios_tests', 'check-steam-ios.py')


class SteamIOSSimulatorTests(unittest.TestCase):
    def test_main_allows_cold_runner_time_but_still_rejects_failed_or_stalled_tests(self):
        command = ['simctl', 'spawn']
        for error in (None, subprocess.CalledProcessError(1, command, output='PASS: 110 checks'),
                      subprocess.TimeoutExpired(command, 300, output='PASS: 110 checks')):
            with self.subTest(error=error), \
                 patch.object(steam_ios.subprocess, 'check_output', return_value='{}'), \
                 patch.object(steam_ios, 'select_device', return_value=('device', False, False)), \
                 patch.object(steam_ios, 'wait_for_spawn'), \
                 patch.object(steam_ios.subprocess, 'run', side_effect=[
                     subprocess.CompletedProcess([], 0), error or subprocess.CompletedProcess([], 0)]) as run:
                if error:
                    with self.assertRaises(type(error)):
                        steam_ios.main()
                else:
                    steam_ios.main()
                invocation = run.call_args
                self.assertEqual(invocation.args[0][:4], ['xcrun', 'simctl', 'spawn', 'device'])
                self.assertEqual(invocation.args[0][-1], '--network')
                self.assertTrue(invocation.kwargs['check'])
                self.assertEqual(invocation.kwargs['timeout'], 300)

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
                         ['xcrun', 'simctl', 'spawn', 'device', 'launchctl', 'list'])

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
            self.assertFalse(steam_ios.simulator_can_spawn('device')[0])

    def test_stalled_owned_boot_gets_one_restart_before_running_checks(self):
        failed = RuntimeError('did not become spawn-ready')
        for final_error in (None, failed):
            with self.subTest(final_error=final_error), \
                 patch.object(steam_ios, 'wait_for_spawn', side_effect=[failed, final_error]) as wait, \
                 patch.object(steam_ios.subprocess, 'run', return_value=
                              subprocess.CompletedProcess([], 0, stdout='Boot status', stderr='')) as run:
                if final_error:
                    with self.assertRaisesRegex(RuntimeError, 'did not become spawn-ready'):
                        steam_ios.prepare_simulator('device', True)
                else:
                    steam_ios.prepare_simulator('device', True)
                self.assertEqual(wait.call_count, 2)
                self.assertEqual([call.args[0][2] for call in run.call_args_list],
                                 ['boot', 'bootstatus', 'shutdown', 'boot'])
                self.assertTrue(all(call.kwargs.get('timeout') for call in run.call_args_list))

    def test_stalled_existing_booted_simulator_is_not_restarted(self):
        with patch.object(steam_ios, 'wait_for_spawn', side_effect=RuntimeError('not ready')), \
             patch.object(steam_ios.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'not ready'):
                steam_ios.prepare_simulator('device', False)
            run.assert_not_called()

    def test_boot_diagnostic_timeout_does_not_prevent_bounded_recovery(self):
        with patch.object(steam_ios, 'wait_for_spawn', side_effect=[RuntimeError('not ready'), None]), \
             patch.object(steam_ios.subprocess, 'run', side_effect=[
                 subprocess.CompletedProcess([], 0),
                 subprocess.TimeoutExpired(['bootstatus'], 15, output=b'Waiting on device'),
                 subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0)]) as run:
            steam_ios.prepare_simulator('device', True)
            self.assertEqual(run.call_count, 4)

    def test_prefers_an_existing_simulator_and_creates_only_a_compatible_device(self):
        runtime = {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                   'version': '27.0', 'isAvailable': True,
                   'supportedDeviceTypes': [{'identifier': 'compatible-iphone', 'productFamily': 'iPhone'}]}
        inventory = {'runtimes': [runtime], 'devices': {runtime['identifier']: [
            {'name': 'iPhone 18 Pro', 'state': 'Shutdown', 'isAvailable': True, 'udid': 'existing'}]}}
        with patch.object(steam_ios.subprocess, 'check_output') as create:
            self.assertEqual(steam_ios.select_device(inventory), ('existing', True, False))
            create.assert_not_called()
            inventory['devices'].clear()
            create.return_value = 'new-device\n'
            self.assertEqual(steam_ios.select_device(inventory), ('new-device', True, True))
            self.assertEqual(create.call_args.args[0][4], 'compatible-iphone')


if __name__ == '__main__':
    unittest.main()
