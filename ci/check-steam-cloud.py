#!/usr/bin/env python3
"""Run production Cloud preparation and Foundation JSON contract fixtures."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='iridium-cloud-checks-') as directory:
        executable = Path(directory) / 'cloud-checks'
        subprocess.run([
            'swiftc', '-swift-version', '6', '-parse-as-library',
            '-module-cache-path', str(Path(directory) / 'module-cache'),
            str(ROOT / 'iridium/apps/ios/MadeiraSupport/MadeiraGamePreparation.swift'),
            str(ROOT / 'iridium/apps/ios/Iridium/SteamCloudPreparation.swift'),
            str(ROOT / 'iridium/apps/ios/Iridium/SteamCloudModels.swift'),
            str(ROOT / 'iridium/apps/ios/SteamCloudTests/CloudChecks.swift'),
            '-o', str(executable),
        ], check=True, timeout=180)
        subprocess.run([str(executable)], check=True, timeout=60)
        # Tiny host-only modules permit the production MainActor coordinator to
        # run on Linux. No Steam/runtime implementation is substituted into the app.
        directory = Path(directory)
        modules = {
            'Combine': """public protocol ObservableObject: AnyObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
""",
            'IridiumCore': """import Foundation
public struct FixtureLaunchProfile: Sendable {
    public var executablePath: String
    public var titleFlags: [String]
    public init(executablePath: String, titleFlags: [String]) {
        self.executablePath = executablePath; self.titleFlags = titleFlags
    }
}
public struct GameRecord: Sendable {
    public var id: UUID
    public var title: String
    public var installPath: String
    public var launchProfile: FixtureLaunchProfile
    public init(id: UUID, title: String, installPath: String, launchProfile: FixtureLaunchProfile) {
        self.id = id; self.title = title; self.installPath = installPath; self.launchProfile = launchProfile
    }
}
""",
        }
        for name, source in modules.items():
            stub = directory / (name + '.swift')
            stub.write_text(source)
            subprocess.run(['swiftc', '-swift-version', '6', '-module-cache-path',
                            str(directory / 'module-cache'), '-emit-library', '-static',
                            '-emit-module', '-module-name', name, str(stub),
                            '-emit-module-path', str(directory / (name + '.swiftmodule')),
                            '-o', str(directory / ('lib' + name + '.a'))], check=True, timeout=120)
        coordinator = directory / 'coordinator-checks'
        subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                        '-module-cache-path', str(directory / 'module-cache'),
                        '-I', str(directory), '-L', str(directory), '-lCombine', '-lIridiumCore',
                        str(ROOT / 'iridium/apps/ios/Iridium/SteamCloudModels.swift'),
                        str(ROOT / 'iridium/apps/ios/Iridium/SteamCloudFileAccess.swift'),
                        str(ROOT / 'iridium/apps/ios/Iridium/SteamCloudCoordinator.swift'),
                        str(ROOT / 'iridium/apps/ios/SteamCloudTests/CoordinatorChecks.swift'),
                        '-o', str(coordinator)], check=True, timeout=180)
        subprocess.run([str(coordinator)], check=True, timeout=60)
        # Compile the real entry-point bodies, rather than replicas of their
        # guards. Mock filesystem/store effects let the fixture suspend work.
        app_source = (ROOT / 'iridium/apps/ios/Iridium/AppViewModel.swift').read_text()
        methods = ['beginGameFileMutation', 'requireGameFileMutation',
                   'refreshMadeiraGameCopy', 'prepareInstaller', 'deleteImportedGameFiles',
                   'deleteSteamDownload', 'relocateScannedImport', 'removeLibraryEntry',
                   'repairPrefix', 'rebuildPrefix', 'clonePrefix']
        bodies = []
        for name in methods:
            marker = '    private func ' if name.startswith(('beginGame', 'requireGame')) else '    func '
            start = app_source.index(marker + name + '(')
            end = app_source.index('\n    }\n', start) + len('\n    }\n')
            bodies.append(app_source[start:end])
        entry_points = directory / 'MutationEntryPoints.swift'
        entry_points.write_text('import Foundation\nimport IridiumCore\nextension AppViewModel {\n' +
                                '\n'.join(bodies) + '\n}\n')
        mutation = directory / 'mutation-checks'
        subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-D', 'MADEIRA_RUNTIME',
                        '-module-cache-path', str(directory / 'module-cache'),
                        '-I', str(directory), '-L', str(directory), '-lCombine', '-lIridiumCore',
                        str(ROOT / 'iridium/apps/ios/Iridium/SteamCloudModels.swift'),
                        str(ROOT / 'iridium/apps/ios/Iridium/SteamCloudFileAccess.swift'),
                        str(ROOT / 'iridium/apps/ios/Iridium/SteamCloudCoordinator.swift'),
                        str(ROOT / 'iridium/apps/ios/SteamCloudTests/MutationChecks.swift'),
                        str(entry_points), '-o', str(mutation)], check=True, timeout=180)
        subprocess.run([str(mutation)], check=True, timeout=60)


if __name__ == '__main__':
    main()
