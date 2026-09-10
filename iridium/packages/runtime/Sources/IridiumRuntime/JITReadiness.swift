import Foundation

public enum JITStatus: String, Codable, CaseIterable, Sendable {
    case required
    case ready
    case unavailable

    public var displayName: String {
        switch self {
        case .required:
            "Required"
        case .ready:
            "Ready"
        case .unavailable:
            "Unavailable"
        }
    }
}

public enum JITSessionKind: String, Codable, CaseIterable, Sendable {
    case none
    case debuggerBacked = "debugger-backed"
    case trollStorePrivate = "trollstore-private"

    public var displayName: String {
        switch self {
        case .none:
            "None"
        case .debuggerBacked:
            "Debugger Backed"
        case .trollStorePrivate:
            "TrollStore / Private"
        }
    }
}

public enum JITToolRecommendation: String, Codable, CaseIterable, Sendable {
    case none
    case stikDebug = "stikdebug"
    case sideStore = "sidestore"
    case trollStore = "trollstore"

    public var displayName: String {
        switch self {
        case .none:
            "None"
        case .stikDebug:
            "StikDebug"
        case .sideStore:
            "SideStore"
        case .trollStore:
            "TrollStore"
        }
    }
}

public struct JITReadinessChecker: Sendable {
    private let provider: any HostCapabilityProvider

    public init(provider: any HostCapabilityProvider = FileSystemHostCapabilityProvider()) {
        self.provider = provider
    }

    public func checkStatus() async -> JITStatus {
        await provider.snapshot().jitStatus
    }
}
