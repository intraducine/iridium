// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Foundation
import UIKit

@MainActor enum IridiumMenuSounds {
    enum Cue: String { case focus, invoke, show, hide, back, next, previous }
    static let settingsKey = "iridium.menuSounds"
    private static var audio: [String: Data] = [:]
    @MainActor private final class Voice {
        let player: AVAudioPlayer
        var endsAt = 0.0
        init(_ player: AVAudioPlayer) { self.player = player }
        var idle: Bool { !player.isPlaying && ProcessInfo.processInfo.systemUptime >= endsAt }
    }
    private static var voices: [String: [Voice]] = [:]
    private static var failed: Set<String> = []
    private static var focusIndex = 0
    private static var lastFocusStart = -Double.infinity
    private static var sessionReady = false
    private static var enabled: Bool {
        (UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? true) &&
        UIApplication.shared.applicationState == .active &&
        LibraryModel.shared.current == nil && !LibraryModel.shared.launching &&
        !IridiumConsoleSession.shared.isActive
    }

    static func prepare() {
        guard enabled else { return }
        do { try activate() }
        catch { NSLog("[menu-audio] Could not activate menu audio: %@", error.localizedDescription); return }
        for name in ["focus1", "focus2", "focus3", "focus4", "invoke", "show", "hide", "back", "next", "previous"] {
            _ = voice(for: name)
        }
    }

    static func play(_ cue: Cue, count: Int = 1) {
        guard enabled, count > 0 else { return }
        do {
            try activate()
            for _ in 0..<count {
                let name: String
                if cue == .focus {
                    name = "focus\(focusIndex + 1)"
                    focusIndex = (focusIndex + 1) % 4
                } else { name = cue.rawValue }
                guard let voice = voice(for: name) else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                let start = cue == .focus ? max(now, lastFocusStart + 0.012) : now
                if cue == .focus { lastFocusStart = start }
                voice.endsAt = start + voice.player.duration
                voice.player.currentTime = 0
                // Separate coalesced crossings without cutting off their tails.
                let played = voice.player.play(atTime: voice.player.deviceCurrentTime + start - now)
                if !played { voice.endsAt = 0; NSLog("[menu-audio] Could not play %@", name) }
            }
        } catch { NSLog("[menu-audio] Could not activate menu audio: %@", error.localizedDescription) }
    }

    static func stop() {
        for group in voices.values { for voice in group { voice.player.stop() } }
        voices.removeAll()
        sessionReady = false
        lastFocusStart = -Double.infinity
        // Runtime adapters own activation/deactivation during gameplay.
    }

    private static func activate() throws {
        guard !sessionReady else { return }
        // Menu audio mixes with other apps and follows the silent switch.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient, mode: .default)
        try session.setActive(true)
        sessionReady = true
    }

    private static func voice(for name: String) -> Voice? {
        let group = voices[name] ?? []
        if let idle = group.first(where: { $0.idle }) {
            voices[name] = group.filter { !$0.idle || $0 === idle }
            return idle
        }
        guard !failed.contains(name) else { return nil }
        do {
            let data: Data
            if let cached = audio[name] { data = cached }
            else {
                guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "MenuAudio") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                data = try Data(contentsOf: url)
                audio[name] = data
            }
            // Busy voices finish naturally; each new focus event gets its own voice.
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            let voice = Voice(player)
            voices[name, default: []].append(voice)
            return voice
        } catch {
            failed.insert(name)
            NSLog("[menu-audio] Could not load %@", name)
            return nil
        }
    }
}
