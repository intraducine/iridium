# SPDX-License-Identifier: AGPL-3.0-only
"""Check bundled cues and run the shipping player with silent audio endpoints."""
from pathlib import Path
import hashlib
import json
import os
import sys
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
    enum Cue { case focus, invoke, show, hide, back, next, previous }
    static var moves = 0
    static func play(_ cue: Cue) { if cue == .focus { moves += 1 } }
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

    def test_assets_are_pinned_short_quiet_pcm_with_license_notices(self):
        manifest = json.loads((SOUNDS / 'source.json').read_text())
        pins = [x for x in json.loads((ROOT / 'UPSTREAM-SOURCES.json').read_text())['assets']
                if x['id'] == 'atkey-ui-sounds']
        self.assertEqual(len(pins), 1)
        pin = pins[0]
        for field in ('archiveSHA256', 'upstream', 'version', 'license'):
            self.assertEqual(pin[field], manifest[field])
        self.assertEqual(manifest['license'], 'LicenseRef-Atkey-UI-Sounds-1')
        self.assertIn('Sounds by AtkeySounds (Atkey).', (SOUNDS / 'License.txt').read_text())
        license_file = SOUNDS / manifest['licenseFile']
        self.assertEqual(hashlib.sha256(license_file.read_bytes()).hexdigest(), manifest['licenseSHA256'])
        self.assertIn('Distribute finished projects that include these sounds.', license_file.read_text())
        self.assertIn('Resell or redistribute the sounds as standalone audio files.', license_file.read_text())
        expected = {'focus1', 'focus2', 'focus3', 'focus4', 'invoke', 'show', 'hide', 'back', 'next', 'previous'}
        self.assertEqual(set(manifest['files']), {x + '.wav' for x in expected})
        self.assertEqual(set(manifest['files']), {p.name for p in SOUNDS.glob('*.wav')})
        for name, record in manifest['files'].items():
            self.assertEqual(hashlib.sha256((SOUNDS / name).read_bytes()).hexdigest(), record['sha256'], name)
            self.assertRegex(record['sourceSHA256'], r'^[a-f0-9]{64}$')
            self.assertRegex(record['source'], r'^Atkey Ui Sounds #1/Wav/UI Sound WAV_\d{2}\.wav$')
            with wave.open(str(SOUNDS / name)) as cue:
                self.assertEqual((cue.getnchannels(), cue.getsampwidth(), cue.getframerate()), (1, 2, 44100))
                self.assertGreater(cue.getnframes(), 0)
                self.assertLess(cue.getnframes() / cue.getframerate(), 0.28 if name.startswith('focus') else 1.0)
                samples = struct.unpack('<' + 'h' * cue.getnframes(), cue.readframes(cue.getnframes()))
                self.assertLessEqual(max(abs(x) for x in samples), 0.101 * 32768)
                self.assertLessEqual(abs(samples[0]), 2)
                self.assertLessEqual(abs(samples[-1]), 2)
        self.assertEqual(len({manifest['files']['focus' + str(i) + '.wav']['sha256'] for i in range(1,5)}), 4)

    def test_rapid_scroll_mix_has_headroom(self):
        cues = []
        for i in range(1,5):
            with wave.open(str(SOUNDS / ('focus' + str(i) + '.wav'))) as sound:
                cues.append(struct.unpack('<' + 'h' * sound.getnframes(), sound.readframes(sound.getnframes())))
        mix = [0] * (44100 * 3)
        for event in range(120):
            start = round(event * 0.012 * 44100)
            for i, value in enumerate(cues[event % 4]):
                mix[start + i] += value
        self.assertLess(max(abs(x) for x in mix), 0.95 * 32768, 'Rapid focus cues must not clip')

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_player_overlaps_every_event_reuses_only_idle_voices_and_stops_cleanly(self):
        source = SOURCE.read_text().replace('import AVFoundation', '').replace('import UIKit', '')
        fixture = PLAYER_ENDPOINTS + source + PLAYER_CHECK
        self.run_player(fixture, ['normal', 'failure', 'activation_failure'])

    def run_player(self, fixture, scenarios):
        with tempfile.TemporaryDirectory(prefix='iridium-menu-audio-') as directory:
            folder = Path(directory)
            shutil.copytree(SOUNDS, folder / 'MenuAudio')
            unit = folder / 'Check.swift'; unit.write_text(fixture)
            binary = folder / 'check'
            result = subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                '-module-cache-path', module_cache('macosx'), str(unit), '-o', str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for scenario in scenarios:
                result = subprocess.run([str(binary), scenario], capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(sys.platform == 'darwin' and os.environ.get('IRIDIUM_TEST_MUTED_AUDIO') == '1',
                         'Opt in to a muted local audio-device check')
    def test_real_player_overlaps_and_cancels_scheduled_audio_at_zero_volume(self):
        source = SOURCE.read_text().replace('import UIKit', '')
        endpoints = PLAYER_ENDPOINTS
        start = endpoints.index('@MainActor final class AVAudioPlayer {')
        end = endpoints.index('@MainActor final class AVAudioSession {', start)
        native = r'''@MainActor final class AVAudioPlayer {
    let native: AVFoundation.AVAudioPlayer
    var isPlaying: Bool { native.isPlaying }
    var duration: Double { native.duration }
    var deviceCurrentTime: Double { native.deviceCurrentTime }
    var currentTime: Double {
        get { native.currentTime }
        set { if native.isPlaying { Output.resetsWhilePlaying += 1 }; native.currentTime = newValue }
    }
    init(data: Data) throws {
        native = try AVFoundation.AVAudioPlayer(data: data)
        native.volume = 0
        Output.created.append(self)
    }
    @discardableResult func prepareToPlay() -> Bool { native.prepareToPlay() }
    func play(atTime time: Double) -> Bool {
        precondition(native.volume == 0)
        Output.played.append("played")
        let result = native.play(atTime: time)
        precondition(result, "The real player must accept every scheduled cue")
        return result
    }
    func stop() { native.stop(); Output.stops += 1 }
}
'''
        endpoints = endpoints[:start] + native + endpoints[end:]
        start = endpoints.index('@MainActor final class ProcessInfo {')
        end = endpoints.index('@MainActor final class LibraryModel {', start)
        endpoints = endpoints[:start] + endpoints[end:]
        fixture = endpoints + source + r'''
@main @MainActor struct Check {
    static func main() {
        IridiumMenuSounds.prepare()
        IridiumMenuSounds.play(.focus, count: 12)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        precondition(Output.played.count == 12 && Output.created.filter(\.isPlaying).count >= 3)
        precondition(Output.resetsWhilePlaying == 0 && Output.stops == 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(!Output.created.contains(where: \.isPlaying), "All tails must finish")
        IridiumMenuSounds.play(.focus, count: 40)
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        precondition(Output.played.count == 52 && !Output.created.contains(where: \.isPlaying))
        precondition(Output.resetsWhilePlaying == 0 && Output.stops == 0)
        IridiumMenuSounds.play(.focus, count: 40)
        IridiumMenuSounds.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        precondition(!Output.created.contains(where: \.isPlaying), "Stop must cancel future starts")
        print("PASS real muted AVAudioPlayer overlap, completed tails, no restart of busy voices and cancellation")
    }
}
'''
        self.run_player(fixture, ['native'])

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

PLAYER_ENDPOINTS = r'''import Foundation
@MainActor enum Output {
    static var created: [AVAudioPlayer] = []
    static var played: [String] = []
    static var attempts = 0, stops = 0, resetsWhilePlaying = 0, categories = 0, activations = 0
    static var fail = false, failActivation = false
}
@MainActor final class AVAudioPlayer {
    let name: String
    var isPlaying = false
    let duration = 0.25
    var deviceCurrentTime: Double { ProcessInfo.processInfo.systemUptime }
    var scheduledTime = 0.0
    var currentTime = 0.0 { willSet { if isPlaying { Output.resetsWhilePlaying += 1 } } }
    init(data: Data) throws {
        Output.attempts += 1
        if Output.fail { throw CocoaError(.fileReadCorruptFile) }
        name = ["focus1", "focus2", "focus3", "focus4", "invoke", "show", "hide", "back", "next", "previous"].first {
            let url = Bundle.main.url(forResource: $0, withExtension: "wav", subdirectory: "MenuAudio")!
            return (try? Data(contentsOf: url)) == data
        }!
        Output.created.append(self)
    }
    @discardableResult func prepareToPlay() -> Bool { true }
    func play(atTime time: Double) -> Bool {
        scheduledTime = time; isPlaying = true; Output.played.append(name); return true
    }
    func stop() { isPlaying = false; Output.stops += 1 }
}
@MainActor final class AVAudioSession {
    enum Category { case ambient }
    enum Mode { case `default` }
    static let shared = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { shared }
    func setCategory(_ category: Category, mode: Mode) throws { Output.categories += 1 }
    func setActive(_ active: Bool) throws {
        precondition(active, "The menu must not deactivate a runtime's session")
        if Output.failActivation { throw CocoaError(.fileReadUnknown) }
        Output.activations += 1
    }
}
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication(); var applicationState = State.active
}
@MainActor final class UserDefaults {
    static let standard = UserDefaults(); var enabled: Bool?
    func object(forKey key: String) -> Any? { precondition(key == "iridium.menuSounds"); return enabled }
}
@MainActor final class ProcessInfo {
    static let processInfo = ProcessInfo(); var systemUptime = 100.0
}
@MainActor final class LibraryModel {
    static let shared = LibraryModel(); var current: UUID?, launching = false
}
@MainActor final class IridiumConsoleSession {
    static let shared = IridiumConsoleSession(); var isActive = false
}
'''

PLAYER_CHECK = r'''
@main @MainActor struct Check {
    static func main() {
        if CommandLine.arguments.last == "failure" {
            Output.fail = true
            IridiumMenuSounds.play(.invoke); IridiumMenuSounds.play(.invoke)
            precondition(Output.attempts == 1 && Output.played.isEmpty)
            Output.fail = false; IridiumMenuSounds.play(.back)
            precondition(Output.played == ["back"])
            return
        }
        if CommandLine.arguments.last == "activation_failure" {
            Output.failActivation = true; IridiumMenuSounds.play(.focus)
            precondition(Output.played.isEmpty && Output.created.isEmpty)
            Output.failActivation = false; IridiumMenuSounds.play(.focus)
            precondition(Output.played == ["focus1"])
            return
        }
        IridiumMenuSounds.prepare()
        precondition(Output.created.count == 10 && Output.played.isEmpty)
        IridiumMenuSounds.play(.focus, count: 0); IridiumMenuSounds.play(.focus, count: -1)
        for _ in 0..<40 { IridiumMenuSounds.play(.focus) }
        IridiumMenuSounds.play(.focus, count: 8)
        precondition(Output.played == (0..<48).map { "focus\($0 % 4 + 1)" }, "Every rapid event must play")
        precondition(Output.created.filter(\.isPlaying).count == 48, "Busy voices must overlap")
        for cue in [IridiumMenuSounds.Cue.invoke, .show, .hide, .back, .next, .previous] { IridiumMenuSounds.play(cue) }
        precondition(Output.played.count == 54 && Output.stops == 0 && Output.resetsWhilePlaying == 0)
        precondition(Output.activations == 1, "Do not activate the session on every focus change")
        let starts = Output.created.filter { $0.name.hasPrefix("focus") }.map(\.scheduledTime).sorted()
        for pair in zip(starts, starts.dropFirst()) { precondition(pair.1 - pair.0 > 0.011, "Coalesced cues need distinct onsets") }
        for player in Output.created { player.isPlaying = false }
        let reserved = Output.created.count
        IridiumMenuSounds.play(.focus, count: 4)
        precondition(Output.created.count == reserved + 4, "A scheduled voice is busy before it starts")
        ProcessInfo.processInfo.systemUptime += 2
        let created = Output.created.count
        IridiumMenuSounds.play(.focus, count: 4)
        precondition(Output.created.count == created, "Reuse finished voices")
        let played = Output.played.count, categories = Output.categories
        UserDefaults.standard.enabled = false; IridiumMenuSounds.prepare(); IridiumMenuSounds.play(.invoke)
        UserDefaults.standard.enabled = true
        for state in [UIApplication.State.inactive, .background] {
            UIApplication.shared.applicationState = state; IridiumMenuSounds.prepare(); IridiumMenuSounds.play(.focus)
        }
        UIApplication.shared.applicationState = .active
        LibraryModel.shared.launching = true; IridiumMenuSounds.play(.show)
        LibraryModel.shared.launching = false; LibraryModel.shared.current = UUID(); IridiumMenuSounds.play(.back)
        LibraryModel.shared.current = nil; IridiumConsoleSession.shared.isActive = true
        IridiumMenuSounds.prepare(); IridiumMenuSounds.play(.invoke)
        precondition(Output.played.count == played && Output.categories == categories)
        IridiumMenuSounds.stop()
        precondition(!Output.created.contains(where: \.isPlaying))
        IridiumConsoleSession.shared.isActive = false
        IridiumMenuSounds.play(.focus)
        precondition(Output.played.count == played + 1 && Output.activations == 2)
        precondition(Output.resetsWhilePlaying == 0)
        precondition(Output.created.last!.scheduledTime == ProcessInfo.processInfo.systemUptime, "Stop clears pending timing")
        print("PASS overlapping voices, every rapid/coalesced event, focus variation, idle reuse, mute, runtime ownership, stop and resume")
    }
}
'''
