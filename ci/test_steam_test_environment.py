import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_manual_build import load

framework = load('steam_framework_tests', 'build-steam-framework.py')


class SteamTestEnvironmentTests(unittest.TestCase):
    def test_host_managed_and_native_tests_use_the_canonical_os_temp_anchor(self):
        class TestsFinished(Exception):
            pass

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve(strict=True)
            anchor = base / 'os-temp'
            anchor.mkdir()
            alias = base / 'os-temp-alias'
            alias.symlink_to(anchor, target_is_directory=True)
            outside = base / 'outside'
            outside.mkdir()
            internal_link = anchor / 'untrusted-save-link'
            internal_link.symlink_to(outside, target_is_directory=True)
            calls = []

            def run(*args, **kwargs):
                calls.append((args, kwargs))
                if args[0] == framework.OUTPUT / 'tests/Iridium.Steam.Tests':
                    raise TestsFinished

            inherited = dict(os.environ, TMPDIR=str(alias), IRIDIUM_TEST_MARKER='retained')
            with patch.dict(framework.os.environ, inherited, clear=True), \
                 patch.object(framework.tempfile, 'gettempdir', return_value=str(alias)), \
                 patch.object(framework.platform, 'system', return_value='Darwin'), \
                 patch.object(framework.platform, 'machine', return_value='arm64'), \
                 patch.object(framework.sys, 'argv', ['build-steam-framework.py']), \
                 patch.object(framework.subprocess, 'check_output', return_value='10.0.401\n'), \
                 patch.object(framework, 'run', side_effect=run):
                with self.assertRaises(TestsFinished):
                    framework.main()
                self.assertEqual(framework.os.environ['TMPDIR'], str(alias))

            tests = [(args, kwargs['env']) for args, kwargs in calls if 'env' in kwargs]
            self.assertEqual(len(tests), 2)
            self.assertEqual(tests[0][0][:2], ('dotnet', 'run'))
            self.assertEqual(tests[1][0], (framework.OUTPUT / 'tests/Iridium.Steam.Tests',))
            for _, env in tests:
                self.assertEqual(env['TMPDIR'], str(anchor))
                self.assertEqual(env['IRIDIUM_TEST_MARKER'], 'retained')
            self.assertTrue(internal_link.is_symlink())
            self.assertEqual(os.readlink(internal_link), str(outside))

    def test_command_wrapper_passes_the_test_environment_to_the_child(self):
        env = dict(os.environ, TMPDIR=str(Path(tempfile.gettempdir()).resolve(strict=True)))
        with patch.object(framework.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as child:
            framework.run('fixture', env=env)
        child.assert_called_once_with(['fixture'], cwd=framework.SOURCE, check=True, env=env)


if __name__ == '__main__':
    unittest.main()
