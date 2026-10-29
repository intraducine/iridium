// SPDX-License-Identifier: AGPL-3.0-only
import AudioToolbox
import Foundation
import UIKit

@MainActor enum IridiumMenuSounds {
    enum Cue: String { case move, select, open, back }
    static let settingsKey = "iridium.menuSounds"
    private static var sounds: [Cue: SystemSoundID] = [:]
    private static var lastMove = -Double.infinity

    static func play(_ cue: Cue) {
        guard UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? true,
              UIApplication.shared.applicationState == .active,
              LibraryModel.shared.current == nil, !LibraryModel.shared.launching,
              !IridiumConsoleSession.shared.isActive else { return }
        if cue == .move {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastMove >= 0.075 else { return }
            lastMove = now
        }
        let sound: SystemSoundID
        if let cached = sounds[cue] { sound = cached }
        else {
            var loaded: SystemSoundID = 0
            if let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav", subdirectory: "MenuAudio"),
               AudioServicesCreateSystemSoundID(url as CFURL, &loaded) == kAudioServicesNoError {
                sound = loaded
            } else {
                NSLog("[menu-audio] Could not load %@", cue.rawValue)
                sound = 0
            }
            sounds[cue] = sound
        }
        guard sound != 0 else { return }
        // System sounds respect silent mode and do not change the runtime's audio session.
        AudioServicesPlaySystemSoundWithCompletion(sound, nil)
    }
}
