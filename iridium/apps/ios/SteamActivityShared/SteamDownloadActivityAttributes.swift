import ActivityKit
import AppIntents

struct SteamDownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var verifiedBytes: Int64
        var totalBytes: Int64
        var lastUpdated: Date

        var fractionCompleted: Double {
            totalBytes > 0 ? min(1, max(0, Double(verifiedBytes) / Double(totalBytes))) : 0
        }
        var isTerminal: Bool { ["completed", "cancelled", "failed"].contains(phase) }
        var label: String {
            switch phase {
            case "resolving": "Preparing download"
            case "downloading": "Transferring game files"
            case "verifying": "Verifying game files"
            case "finalizing": "Finishing installation"
            case "waitingForeground": "Open Iridium to verify and continue"
            case "paused": "Download paused"
            case "completed": "Verified and ready"
            case "cancelled": "Download cancelled"
            case "failed": "Download stopped. Open Iridium to retry"
            default: "Preparing download"
            }
        }
    }
    let operationId: String
    let gameName: String
}

struct CancelSteamDownloadIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel Download"
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Download") var operationId: String

    init() { }
    init(operationId: String) { self.operationId = operationId }

    @MainActor func perform() async throws -> some IntentResult {
        #if IRIDIUM_APP
        await SteamLibraryModel.shared.restore()
        if let id = UUID(uuidString: operationId) { SteamLibraryModel.shared.cancel(id) }
        #endif
        return .result()
    }
}
