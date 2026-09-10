import Foundation

struct RuntimeLaunchPhaseTimer {
    let operation: String
    let gameTitle: String
    private let startedAt: TimeInterval
    private var lastMarkAt: TimeInterval

    init(operation: String, gameTitle: String) {
        self.operation = operation
        self.gameTitle = gameTitle
        let now = ProcessInfo.processInfo.systemUptime
        startedAt = now
        lastMarkAt = now
        print("[IridiumRuntime] \(operation): timingStart game=\(gameTitle)")
    }

    mutating func mark(_ phase: String, detail: String? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let totalMS = Int((now - startedAt) * 1_000)
        let deltaMS = Int((now - lastMarkAt) * 1_000)
        lastMarkAt = now
        let detailSuffix = detail.map { " \($0)" } ?? ""
        print(
            "[IridiumRuntime] \(operation): timing phase=\(phase) totalMS=\(totalMS) deltaMS=\(deltaMS) game=\(gameTitle)\(detailSuffix)"
        )
    }
}
