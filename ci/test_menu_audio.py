# SPDX-License-Identifier: AGPL-3.0-only
"""Check bundled cues and run the shipping player with silent audio endpoints."""
from pathlib import Path
import hashlib
import json
import shutil
import struct
import subprocess
import tempfile
import unittest
import wave

from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'
SOUNDS = IOS / 'App/Resources/MenuAudio'
SOURCE = IOS / 'MadeiraFrontend/IridiumMenuSounds.swift'


class MenuAudioTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_settings_toggle_uses_existing_keyboard_controller_routes(self):
        source = (IOS / 'App/Library/IridiumWindowsScreens.swift').read_text()
        start = source.index('    private func iridiumNavigate(_ command: String)', source.index('struct LibraryView:'))
        methods = source[start:source.index('    private var iridiumDisplaySettings:', start)]
        fixture = r'''import Foundation
@MainActor enum IridiumMenuSounds {
    enum Cue { case move, select, back }
    static var moves = 0
    static func play(_ cue: Cue) { if cue == .move { moves += 1 } }
}
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
    var menuSounds = true, dismissed = 0
    func iridiumDismiss() { dismissed += 1 }
METHODS
    func run() {
        iridiumNavigate("down")
        precondition(iridiumFocus == "Menu sounds" && IridiumMenuSounds.moves == 1)
        iridiumNavigate("accept"); precondition(!menuSounds && iridiumPages.isEmpty)
        iridiumNavigate("accept"); precondition(menuSounds && iridiumPages.isEmpty)
        iridiumNavigate("down"); iridiumNavigate("accept")
        precondition(iridiumPages == ["Madeira · Windows"])
        iridiumNavigate("back"); precondition(iridiumPages.isEmpty && dismissed == 0)
        iridiumNavigate("back"); precondition(dismissed == 1)
        iridiumFocus = "Getting Started"
        let moves = IridiumMenuSounds.moves
        iridiumNavigate("up"); precondition(IridiumMenuSounds.moves == moves)
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

    def test_assets_are_pinned_short_quiet_pcm_with_original_license(self):
        manifest = json.loads((SOUNDS / 'source.json').read_text())
        pin = next(x for x in json.loads((ROOT / 'UPSTREAM-SOURCES.json').read_text())['assets']
                   if x['id'] == 'kenney-ui-audio')
        self.assertEqual(pin['archiveSHA256'], manifest['archiveSHA256'])
        self.assertEqual(pin['license'], 'CC0-1.0')
        self.assertIn('Kenney', (SOUNDS / 'License.txt').read_text())
        self.assertEqual(set(manifest['files']), {'move.wav', 'select.wav', 'back.wav'})
        for name, record in manifest['files'].items():
            data = (SOUNDS / name).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), record['sha256'], name)
            self.assertRegex(record['sourceSHA256'], r'^[a-f0-9]{64}$')
            with wave.open(str(SOUNDS / name)) as cue:
                self.assertEqual((cue.getnchannels(), cue.getsampwidth(), cue.getframerate()), (1, 2, 44100))
                self.assertGreater(cue.getnframes(), 0)
                self.assertLess(cue.getnframes() / cue.getframerate(), 0.12)
                samples = struct.unpack('<' + 'h' * cue.getnframes(), cue.readframes(cue.getnframes()))
                self.assertLessEqual(max(abs(x) for x in samples), 0.221 * 32768)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_player_mute_runtime_guards_rate_limit_cache_and_load_failure(self):
        source = SOURCE.read_text().replace('import AudioToolbox', '').replace('import UIKit', '')
        fixture = r'''import Foundation
import CoreFoundation
typealias SystemSoundID = UInt32
let kAudioServicesNoError: Int32 = 0
@MainActor enum Output {
    static var created: [String] = [], played: [SystemSoundID] = []
    static var fail = false
}
@MainActor func AudioServicesCreateSystemSoundID(_ url: CFURL, _ id: inout SystemSoundID) -> Int32 {
    Output.created.append((url as URL).lastPathComponent)
    if Output.fail { return -1 }
    id = UInt32(Output.created.count); return 0
}
@MainActor func AudioServicesPlaySystemSoundWithCompletion(_ id: SystemSoundID, _ completion: (() -> Void)?) {
    Output.played.append(id)
}
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    var applicationState = State.active
}
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    var enabled: Bool?
    func object(forKey key: String) -> Any? { precondition(key == "iridium.menuSounds"); return enabled }
}
@MainActor final class ProcessInfo {
    static let processInfo = ProcessInfo()
    var systemUptime = 100.0
}
@MainActor final class LibraryModel {
    static let shared = LibraryModel()
    var current: UUID?, launching = false
}
@MainActor final class IridiumConsoleSession {
    static let shared = IridiumConsoleSession()
    var isActive = false
}
PLAYER
@main @MainActor struct Check {
    static func main() {
        if CommandLine.arguments.last == "failure" {
            Output.fail = true
            IridiumMenuSounds.play(.select); IridiumMenuSounds.play(.select)
            precondition(Output.created.count == 1 && Output.played.isEmpty)
            Output.fail = false
            IridiumMenuSounds.play(.back)
            precondition(Output.played.count == 1)
            return
        }
        IridiumMenuSounds.play(.move)
        ProcessInfo.processInfo.systemUptime += 0.01
        IridiumMenuSounds.play(.move)
        precondition(Output.played.count == 1)
        IridiumMenuSounds.play(.select); IridiumMenuSounds.play(.back)
        precondition(Output.played.count == 3, "Confirmation and back must not be throttled by movement")
        ProcessInfo.processInfo.systemUptime += 0.08
        IridiumMenuSounds.play(.move)
        precondition(Output.played.count == 4 && Output.created.count == 3)
        UserDefaults.standard.enabled = false
        IridiumMenuSounds.play(.select)
        UserDefaults.standard.enabled = true
        for state in [UIApplication.State.inactive, .background] {
            UIApplication.shared.applicationState = state; IridiumMenuSounds.play(.select)
        }
        UIApplication.shared.applicationState = .active
        LibraryModel.shared.launching = true; IridiumMenuSounds.play(.select)
        LibraryModel.shared.launching = false; LibraryModel.shared.current = UUID()
        IridiumMenuSounds.play(.select)
        LibraryModel.shared.current = nil; IridiumConsoleSession.shared.isActive = true
        IridiumMenuSounds.play(.select)
        precondition(Output.played.count == 4)
        IridiumConsoleSession.shared.isActive = false
        IridiumMenuSounds.play(.select)
        precondition(Output.played.count == 5 && Output.created.count == 3, "Menu playback resumes after a game")
    }
}
'''.replace('PLAYER', source)
        with tempfile.TemporaryDirectory(prefix='iridium-menu-audio-') as directory:
            folder = Path(directory)
            shutil.copytree(SOUNDS, folder / 'MenuAudio')
            unit = folder / 'Check.swift'; unit.write_text(fixture)
            binary = folder / 'check'
            result = subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                '-module-cache-path', module_cache('macosx'), str(unit), '-o', str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for scenario in ('normal', 'failure'):
                result = subprocess.run([str(binary), scenario], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(shutil.which('xcrun'), 'Apple SDK required')
    def test_player_typechecks_against_the_ios_audio_api(self):
        with tempfile.TemporaryDirectory() as directory:
            unit = Path(directory) / 'Endpoints.swift'
            unit.write_text('''import Foundation
@MainActor final class LibraryModel {
    static let shared = LibraryModel(); var current: UUID?; var launching = false
}
@MainActor final class IridiumConsoleSession {
    static let shared = IridiumConsoleSession(); var isActive = false
}
''')
            sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
            result = subprocess.run(['swiftc', '-typecheck', '-swift-version', '6', '-warnings-as-errors',
                '-sdk', sdk, '-target', 'arm64-apple-ios18.0', '-module-cache-path', module_cache('iphoneos'),
                str(SOURCE), str(unit)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
