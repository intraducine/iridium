"""Run production argument draft, persistence, guards and compatibility defaults.

The host substitutes platform state only. It compiles all production Core and
Profiles sources and extracts unchanged AppViewModel method bodies. All files
and game records are synthetic and local to a temporary directory.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'iridium/apps/ios/Iridium'


class GameArgumentTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable')
    def test_production_argument_editing(self):
        with tempfile.TemporaryDirectory(prefix='iridium-argument-checks-') as temporary:
            directory = Path(temporary)
            compiler = ['swiftc', '-swift-version', '6', '-module-cache-path',
                        str(directory / 'module-cache')]
            for name, package in [('IridiumCore', 'core'), ('IridiumProfiles', 'profiles')]:
                sources = sorted((ROOT / f'iridium/packages/{package}/Sources/{name}').glob('*.swift'))
                subprocess.run(compiler + ['-emit-library', '-static', '-emit-module',
                               '-module-name', name, '-I', str(directory)] +
                               [str(source) for source in sources] + ['-emit-module-path',
                               str(directory / f'{name}.swiftmodule'), '-o',
                               str(directory / f'lib{name}.a')], check=True, timeout=180)
            app = (APP / 'AppViewModel.swift').read_text()
            methods = ['canEditGameArguments', 'saveGameArguments', 'beginGameFileMutation',
                       'requireGameFileMutation', 'compatibilityProfile',
                       'gameApplyingCompatibilityLaunchDefaults', 'launchArgumentsContainExplicitGraphicsAPI',
                       'metalOpenGLFallbackArguments', 'argumentsFilteringPresentationOnlyDefaults']
            bodies = []
            for name in methods:
                marker = '    private func ' if ('    private func ' + name + '(') in app else '    func '
                start = app.index(marker + name + '(')
                end = app.index('\n    }\n', start) + len('\n    }\n')
                # Access is host-only; the production body is unchanged.
                bodies.append(app[start:end].replace('    private func ', '    func ', 1))
            entry_points = directory / 'ArgumentEntryPoints.swift'
            entry_points.write_text('import Foundation\nimport IridiumCore\nimport IridiumProfiles\n'
                                    'extension AppViewModel {\n' + '\n'.join(bodies) + '\n}\n')
            executable = directory / 'argument-checks'
            subprocess.run(compiler + ['-parse-as-library', '-I', str(directory), '-L', str(directory),
                           '-lIridiumProfiles', '-lIridiumCore', str(APP / 'SteamCloudFileAccess.swift'),
                           str(ROOT / 'iridium/apps/ios/GameArgumentTests/ArgumentChecks.swift'),
                           str(entry_points), '-o', str(executable)], check=True, timeout=180)
            subprocess.run([str(executable)], check=True, timeout=60)


if __name__ == '__main__':
    unittest.main()
