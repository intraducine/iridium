"""Execute production installation detection and scoped correction persistence."""
from host_tests import module_cache
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class JITInstallationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_current_host_detection_and_explicit_correction(self):
        source = (ROOT / 'iridium/apps/ios/App/JIT/JITSetup.swift').read_text()
        policy = source[source.index('enum JITInstallation:'):source.index('/// Shared setup controls.')]
        properties = '\n'.join(line.strip().replace('private ', '').replace(') var ', ', store: fixtureDefaults) var ')
                               for line in source.splitlines()
                               if '@AppStorage("iridium.setup.installationOverride' in line)
        state = source[source.index('    private var installation: JITInstallation'):source.index('    private var pairingLabel:')]
        state = state.replace('private ', '')
        fixture = '''import Foundation
import SwiftUI
let fixtureName = "Iridium-JIT-Installation-" + UUID().uuidString
let fixtureDefaults = UserDefaults(suiteName: fixtureName)!
@MainActor final class InstallationFixture {
PROPERTIES
    var detectedInstallation: JITInstallation
    init(_ detected: JITInstallation) { detectedInstallation = detected }
STATE
}
'''.replace('PROPERTIES', properties).replace('STATE', state)
        checks = r'''
@main struct Checks {
    @MainActor static func main() {
        defer { fixtureDefaults.removePersistentDomain(forName: fixtureName) }
        let regular = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/fixture/Iridium.app")
        let documents = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/fixture/Documents")
        let hosted = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/host/Documents/Applications/Iridium.app")
        let shared = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/host/LiveContainer/Data/Application/guest/Documents")
        let vectors: [(String?, URL, URL?, JITInstallation)] = [
            (nil, regular, documents, .standalone),
            ("", regular, documents, .standalone),
            ("/host/home", regular, documents, .liveContainer),
            (nil, hosted, documents, .liveContainer),
            ("", hosted, nil, .liveContainer),
            (nil, regular, shared, .liveContainer),
            (nil, regular, nil, .standalone),
            (nil, URL(fileURLWithPath: "/tmp/LiveContainer.app"), documents, .standalone),
            (nil, URL(fileURLWithPath: "/tmp/Documents/Applications/../../Iridium.app"), nil, .standalone)
        ]
        for (home, bundle, docs, expected) in vectors {
            precondition(JITInstallation.detected(liveContainerHomePath: home, bundleURL: bundle, documentDirectoryURL: docs) == expected)
        }
        var combinations = 0
        for detected in [JITInstallation.standalone, .liveContainer] {
            for host in ["", "standalone", "liveContainer", "invalid"] {
                for saved in ["automatic", "standalone", "liveContainer", "", "invalid"] {
                    let accepted = host == detected.rawValue ? JITInstallation(rawValue: saved) : nil
                    precondition(JITInstallation.overrideSelection(saved, host: host, detected: detected) == (accepted?.rawValue ?? "automatic"))
                    precondition(JITInstallation.resolved(saved, host: host, detected: detected) == (accepted ?? detected))
                    combinations += 1
                }
            }
        }

        // These are the actual AppStorage declarations, Binding and refresh
        // action, redirected only to an isolated defaults suite.
        fixtureDefaults.set("liveContainer", forKey: "iridium.setup.installation")
        fixtureDefaults.set("livecontainer3", forKey: "iridium.setup.container")
        fixtureDefaults.set("livecontainer2", forKey: "iridium.jit.stikDebugRoute")
        let first = InstallationFixture(.standalone)
        precondition(first.installation == .standalone && first.installationSelection.wrappedValue == "automatic")
        first.refreshInstallationOverride()
        first.installationSelection.wrappedValue = "liveContainer"
        precondition(first.installation == .liveContainer && first.installationOverrideHost == "standalone")
        let reopened = InstallationFixture(.standalone)
        precondition(reopened.installation == .liveContainer && reopened.installationSelection.wrappedValue == "liveContainer")
        reopened.installationSelection.wrappedValue = "automatic"
        precondition(reopened.installation == .standalone)
        reopened.installationSelection.wrappedValue = "standalone"
        reopened.detectedInstallation = .liveContainer
        precondition(reopened.installation == .liveContainer && reopened.installationSelection.wrappedValue == "automatic")
        reopened.refreshInstallationOverride()
        precondition(reopened.installationOverride == "automatic" && reopened.installationOverrideHost == "liveContainer")
        reopened.detectedInstallation = .standalone
        precondition(reopened.installation == .standalone && reopened.installationSelection.wrappedValue == "automatic")
        reopened.refreshInstallationOverride()
        reopened.installationSelection.wrappedValue = "invalid"
        precondition(reopened.installation == .standalone && reopened.installationSelection.wrappedValue == "automatic")
        reopened.refreshInstallationOverride()
        precondition(reopened.installationOverride == "automatic")
        precondition(fixtureDefaults.string(forKey: "iridium.jit.stikDebugRoute") == "livecontainer2")
        precondition(fixtureDefaults.string(forKey: "iridium.setup.installation") == "liveContainer")
        print("PASS installation: \(vectors.count) current-host vectors, \(combinations) override combinations, legacy defaults ignored, explicit correction persists only in its host context, Automatic/reset/move recovery, StikDebug route preserved")
    }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            swift = root / 'main.swift'
            binary = root / 'installation-check'
            swift.write_text(fixture + policy + checks)
            subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', module_cache('macosx'),
                            str(swift), '-o', str(binary)], check=True, timeout=90)
            subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == '__main__':
    unittest.main()
