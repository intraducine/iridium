// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum IridiumGameVolume {
    static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    static func load(_ game: UUID, legacyMuted: Bool = false, defaults: UserDefaults = .standard) -> Double {
        let key = "GameVolume.\(game)"
        guard defaults.object(forKey: key) != nil else { return legacyMuted ? 0 : 1 }
        return clamp(defaults.double(forKey: key))
    }
    static func save(_ value: Double, game: UUID, defaults: UserDefaults = .standard) {
        defaults.set(clamp(value), forKey: "GameVolume.\(game)")
    }
}
