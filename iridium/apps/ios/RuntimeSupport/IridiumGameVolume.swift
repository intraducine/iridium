// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum IridiumGameVolume {
    static let defaultKey = "IridiumDefaultGameVolume"
    static func defaultVolume(_ defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: defaultKey) == nil ? 1 : clamp(defaults.double(forKey: defaultKey))
    }
    static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    static func load(_ game: UUID, legacyMuted: Bool = false, defaults: UserDefaults = .standard) -> Double {
        let key = "GameVolume.\(game)"
        guard defaults.object(forKey: key) != nil else { return legacyMuted ? 0 : defaultVolume(defaults) }
        return clamp(defaults.double(forKey: key))
    }
    static func save(_ value: Double, game: UUID, defaults: UserDefaults = .standard) {
        defaults.set(clamp(value), forKey: "GameVolume.\(game)")
    }
}
