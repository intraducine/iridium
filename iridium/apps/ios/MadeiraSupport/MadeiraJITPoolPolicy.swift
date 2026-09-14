import Foundation

enum MadeiraJITPoolPolicy {
    static let preferenceKey = "IridiumJITPoolMB"
    static let automaticSafeLimitMB = 256

    static func effectiveLimitMB(requested: Int) -> Int {
        requested == 0 ? automaticSafeLimitMB : requested
    }

    static func withEffectiveLimit<T>(
        defaults: UserDefaults = .standard,
        _ body: () -> T
    ) -> T {
        let requested = defaults.integer(forKey: preferenceKey)
        let effective = effectiveLimitMB(requested: requested)
        guard effective != requested else { return body() }

        let previous = defaults.object(forKey: preferenceKey)
        defaults.set(effective, forKey: preferenceKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: preferenceKey)
            } else {
                defaults.removeObject(forKey: preferenceKey)
            }
        }
        return body()
    }
}
