"""Execute settings input routes after removing menu audio."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from host_tests import module_cache
ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'

class SettingsNavigationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_settings_use_existing_keyboard_controller_routes(self):
        source = (IOS / 'App/Library/IridiumWindowsScreens.swift').read_text()
        start = source.index('    private func iridiumNavigate(_ command: String)', source.index('struct LibraryView:'))
        methods = source[start:source.index('    private var iridiumDisplaySettings:', start)]
        fixture = r'''import Foundation
@MainActor final class TouchControlsModel {
    static let shared = TouchControlsModel(); var iridiumSettingsContext: Int?
}
struct IridiumConsoleSystem {
    let title: String; let primaryPlatform = "fixture"
    static let all: [Self] = []
    static func system(titled: String) -> Self? { nil }
}
enum IridiumSystemGameSettings { static func routes(for platform: String) -> [String] { [] } }
@MainActor final class Settings {
    var iridiumPages: [String] = [], iridiumFocus = "JIT & Memory", iridiumGuided = false
    var dismissed = 0
    var settingsSheet: SettingsSheet?
    enum SettingsSheet { case stores, importFolder }
    var onboarding = Onboarding()
    struct Onboarding { func rerun() {} }
    func iridiumDismiss() { dismissed += 1 }
METHODS
    func run() {
        iridiumNavigate("down")
        precondition(iridiumFocus == "Madeira · Windows")
        iridiumNavigate("accept")
        precondition(iridiumPages == ["Madeira · Windows"])
        iridiumNavigate("back"); precondition(iridiumPages.isEmpty && dismissed == 0)
        iridiumNavigate("back"); precondition(dismissed == 1)
        iridiumFocus = "Getting Started"
        iridiumNavigate("up"); precondition(iridiumFocus == "Import Folder")
        iridiumNavigate("accept"); precondition(settingsSheet == .importFolder && iridiumPages.isEmpty)
        iridiumNavigate("up"); iridiumNavigate("accept"); precondition(settingsSheet == .stores && iridiumPages.isEmpty)
        iridiumFocus = "Getting Started"
        TouchControlsModel.shared.iridiumSettingsContext = 1
        iridiumNavigate("down"); precondition(iridiumFocus == "Getting Started")
    }
}
@main @MainActor struct Check { static func main() { Settings().run() } }
'''.replace('METHODS', methods)
        with tempfile.TemporaryDirectory() as directory:
            unit = Path(directory) / 'Check.swift'; unit.write_text(fixture)
            binary = Path(directory) / 'check'
            result = subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                '-module-cache-path', module_cache('macosx'), str(unit), '-o', str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

