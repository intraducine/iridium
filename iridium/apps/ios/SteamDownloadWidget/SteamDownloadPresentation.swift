import Foundation

// Presentation only. Progress remains the number of verified bytes supplied by
// the app; no timer, transfer speed, artwork lookup or download control lives here.
struct SteamDownloadPresentation: Sendable {
    enum Tone: Equatable, Sendable { case neutral, success, attention, failure }
    let phase: String
    let verifiedBytes: Int64
    let totalBytes: Int64
    let isStale: Bool

    init(phase: String, verifiedBytes: Int64, totalBytes: Int64, isStale: Bool) {
        self.phase = phase
        self.verifiedBytes = max(0, verifiedBytes)
        self.totalBytes = max(0, totalBytes)
        self.isStale = isStale && !["completed", "cancelled", "failed"].contains(phase)
    }
    var fractionCompleted: Double? {
        totalBytes > 0 ? min(1, Double(verifiedBytes) / Double(totalBytes)) : nil
    }
    var symbol: String {
        if isStale { return "clock.badge.exclamationmark" }
        switch phase {
        case "paused": return "pause.circle"
        case "waitingForeground": return "exclamationmark.circle"
        case "completed": return "checkmark.circle"
        case "cancelled": return "xmark.circle"
        case "failed": return "exclamationmark.triangle"
        case "verifying": return "checkmark.shield"
        case "finalizing": return "tray.and.arrow.down"
        case "resolving": return "ellipsis.circle"
        default: return "arrow.down.circle"
        }
    }
    var tone: Tone {
        if isStale { return .attention }
        switch phase {
        case "completed": return .success
        case "failed": return .failure
        case "paused", "waitingForeground": return .attention
        default: return .neutral
        }
    }
    var verifiedSummary: String {
        let verified = ByteCountFormatter.string(fromByteCount: verifiedBytes, countStyle: .file)
        guard totalBytes > 0 else { return "Verified \(verified) · total unknown" }
        return "Verified \(verified) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
    }
}
