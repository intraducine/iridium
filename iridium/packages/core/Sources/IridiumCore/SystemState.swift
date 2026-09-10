import Foundation

public enum SteamAuthState: String, Codable, CaseIterable, Sendable {
    case signedOut
    case authenticating
    case signedIn

    public var displayName: String {
        switch self {
        case .signedOut:
            "Signed Out"
        case .authenticating:
            "Authenticating"
        case .signedIn:
            "Signed In"
        }
    }
}

public struct SteamAccount: Codable, Hashable, Sendable {
    public var accountName: String
    public var state: SteamAuthState
    public var sessionReference: String?

    public init(accountName: String, state: SteamAuthState, sessionReference: String? = nil) {
        self.accountName = accountName
        self.state = state
        self.sessionReference = sessionReference
    }
}

public struct SteamLibraryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var appID: String
    public var installed: Bool
    public var cloudSavesEnabled: Bool
    public var lastSyncedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        appID: String,
        installed: Bool,
        cloudSavesEnabled: Bool,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.appID = appID
        self.installed = installed
        self.cloudSavesEnabled = cloudSavesEnabled
        self.lastSyncedAt = lastSyncedAt
    }
}

public enum RuntimeHealthStatus: String, Codable, CaseIterable, Sendable {
    case healthy
    case degraded
    case actionRequired

    public var displayName: String {
        switch self {
        case .healthy:
            "Healthy"
        case .degraded:
            "Degraded"
        case .actionRequired:
            "Action Required"
        }
    }
}

public struct RuntimeHealthReport: Codable, Hashable, Sendable {
    public var status: RuntimeHealthStatus
    public var runtimeName: String
    public var runtimeBundleIdentifier: String?
    public var runtimeBundleVersion: String?
    public var validationEvidence: [String]
    public var activeConstraints: [String]
    public var notes: [String]
    public var lastValidatedAt: Date?

    public init(
        status: RuntimeHealthStatus,
        runtimeName: String,
        runtimeBundleIdentifier: String? = nil,
        runtimeBundleVersion: String? = nil,
        validationEvidence: [String] = [],
        activeConstraints: [String] = [],
        notes: [String],
        lastValidatedAt: Date? = nil
    ) {
        self.status = status
        self.runtimeName = runtimeName
        self.runtimeBundleIdentifier = runtimeBundleIdentifier
        self.runtimeBundleVersion = runtimeBundleVersion
        self.validationEvidence = validationEvidence
        self.activeConstraints = activeConstraints
        self.notes = notes
        self.lastValidatedAt = lastValidatedAt
    }
}

public struct CompatibilityEvidenceRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var source: GameSource
    public var managedArtifactIdentifier: String?
    public var executableFingerprint: String?
    public var runtimeBundleIdentifier: String?
    public var runtimeBundleVersion: String?
    public var resolvedPolicySummary: String
    public var accepted: Bool
    public var hostSessionID: String?
    public var terminalStatus: String?
    public var failureCode: String?
    public var failureReason: String?
    public var telemetrySummary: String?
    public var mitigationAction: String?
    public var evidenceSummary: String
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        source: GameSource,
        managedArtifactIdentifier: String?,
        executableFingerprint: String?,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?,
        resolvedPolicySummary: String,
        accepted: Bool,
        hostSessionID: String? = nil,
        terminalStatus: String? = nil,
        failureCode: String? = nil,
        failureReason: String? = nil,
        telemetrySummary: String? = nil,
        mitigationAction: String? = nil,
        evidenceSummary: String,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.managedArtifactIdentifier = managedArtifactIdentifier
        self.executableFingerprint = executableFingerprint
        self.runtimeBundleIdentifier = runtimeBundleIdentifier
        self.runtimeBundleVersion = runtimeBundleVersion
        self.resolvedPolicySummary = resolvedPolicySummary
        self.accepted = accepted
        self.hostSessionID = hostSessionID
        self.terminalStatus = terminalStatus
        self.failureCode = failureCode
        self.failureReason = failureReason
        self.telemetrySummary = telemetrySummary
        self.mitigationAction = mitigationAction
        self.evidenceSummary = evidenceSummary
        self.recordedAt = recordedAt
    }
}

public enum OnboardingCheckState: String, Codable, CaseIterable, Sendable {
    case ready
    case warning
    case actionRequired

    public var displayName: String {
        switch self {
        case .ready:
            "Ready"
        case .warning:
            "Warning"
        case .actionRequired:
            "Action Required"
        }
    }
}

public struct OnboardingCheck: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var detail: String
    public var state: OnboardingCheckState

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        state: OnboardingCheckState
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
    }
}

public struct LaunchHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var gameTitle: String
    public var resolvedExecutablePath: String
    public var readiness: String
    public var issueSummary: [String]
    public var hostSessionID: String?
    public var stateHistory: [String]?
    public var terminalStatus: String?
    public var failureCode: String?
    public var failureReason: String?
    public var runtimeBundleVersion: String?
    public var telemetrySummary: String?
    public var launchedAt: Date

    public init(
        id: UUID = UUID(),
        gameTitle: String,
        resolvedExecutablePath: String,
        readiness: String,
        issueSummary: [String],
        hostSessionID: String? = nil,
        stateHistory: [String]? = nil,
        terminalStatus: String? = nil,
        failureCode: String? = nil,
        failureReason: String? = nil,
        runtimeBundleVersion: String? = nil,
        telemetrySummary: String? = nil,
        launchedAt: Date
    ) {
        self.id = id
        self.gameTitle = gameTitle
        self.resolvedExecutablePath = resolvedExecutablePath
        self.readiness = readiness
        self.issueSummary = issueSummary
        self.hostSessionID = hostSessionID
        self.stateHistory = stateHistory
        self.terminalStatus = terminalStatus
        self.failureCode = failureCode
        self.failureReason = failureReason
        self.runtimeBundleVersion = runtimeBundleVersion
        self.telemetrySummary = telemetrySummary
        self.launchedAt = launchedAt
    }
}

public enum PendingLaunchStatus: String, Codable, CaseIterable, Sendable {
    case waitingForJIT
    case resumingAfterJIT
    case resumeValidationFailed

    public var displayName: String {
        switch self {
        case .waitingForJIT:
            "Waiting For JIT"
        case .resumingAfterJIT:
            "Resuming After JIT"
        case .resumeValidationFailed:
            "Resume Validation Failed"
        }
    }
}

public struct PendingLaunchRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var launchEntryID: UUID
    public var gameID: UUID
    public var gameTitle: String
    public var prefixID: UUID
    public var resolvedExecutablePath: String
    public var workingDirectory: String
    public var launchArguments: [String]
    public var environment: [String: String]
    public var runtimeBundleIdentifier: String?
    public var runtimeBundleVersion: String?
    public var resolvedPolicySummary: String
    public var status: PendingLaunchStatus
    public var detail: String
    public var requestedAt: Date
    public var lastUpdatedAt: Date

    public init(
        id: UUID = UUID(),
        launchEntryID: UUID,
        gameID: UUID,
        gameTitle: String,
        prefixID: UUID,
        resolvedExecutablePath: String,
        workingDirectory: String,
        launchArguments: [String],
        environment: [String: String],
        runtimeBundleIdentifier: String? = nil,
        runtimeBundleVersion: String? = nil,
        resolvedPolicySummary: String,
        status: PendingLaunchStatus,
        detail: String,
        requestedAt: Date = Date(),
        lastUpdatedAt: Date = Date()
    ) {
        self.id = id
        self.launchEntryID = launchEntryID
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.prefixID = prefixID
        self.resolvedExecutablePath = resolvedExecutablePath
        self.workingDirectory = workingDirectory
        self.launchArguments = launchArguments
        self.environment = environment
        self.runtimeBundleIdentifier = runtimeBundleIdentifier
        self.runtimeBundleVersion = runtimeBundleVersion
        self.resolvedPolicySummary = resolvedPolicySummary
        self.status = status
        self.detail = detail
        self.requestedAt = requestedAt
        self.lastUpdatedAt = lastUpdatedAt
    }
}

public struct InstallHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var appID: String
    public var buildID: String
    public var branchName: String
    public var targetPath: String
    public var primaryExecutable: String
    public var installedAt: Date
    public var detail: String

    public init(
        id: UUID = UUID(),
        title: String,
        appID: String,
        buildID: String,
        branchName: String,
        targetPath: String,
        primaryExecutable: String,
        installedAt: Date,
        detail: String
    ) {
        self.id = id
        self.title = title
        self.appID = appID
        self.buildID = buildID
        self.branchName = branchName
        self.targetPath = targetPath
        self.primaryExecutable = primaryExecutable
        self.installedAt = installedAt
        self.detail = detail
    }
}

public enum ActivityLogKind: String, Codable, CaseIterable, Sendable {
    case imported
    case steamRegistered
    case stagedReset
    case uninstalled
    case prefixRepairScheduled
    case prefixRebuilt
    case runtimeValidated
    case launchQueuedForJIT
    case launchResumed
    case launchResumeFailed

    public var displayName: String {
        switch self {
        case .imported:
            "Imported"
        case .steamRegistered:
            "Steam Registered"
        case .stagedReset:
            "Staged Reset"
        case .uninstalled:
            "Uninstalled"
        case .prefixRepairScheduled:
            "Repair Scheduled"
        case .prefixRebuilt:
            "Prefix Rebuilt"
        case .runtimeValidated:
            "Runtime Validated"
        case .launchQueuedForJIT:
            "Launch Queued"
        case .launchResumed:
            "Launch Resumed"
        case .launchResumeFailed:
            "Resume Failed"
        }
    }
}

public struct ActivityLogEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var kind: ActivityLogKind
    public var title: String
    public var detail: String
    public var relatedTitle: String?
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        kind: ActivityLogKind,
        title: String,
        detail: String,
        relatedTitle: String? = nil,
        recordedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.relatedTitle = relatedTitle
        self.recordedAt = recordedAt
    }
}

public enum VerificationAuditStatus: String, Codable, CaseIterable, Sendable {
    case ready
    case warning
    case blocked

    public var displayName: String {
        switch self {
        case .ready:
            "Ready"
        case .warning:
            "Warning"
        case .blocked:
            "Blocked"
        }
    }
}

public struct VerificationAuditGate: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var detail: String
    public var status: VerificationAuditStatus

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        status: VerificationAuditStatus
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
    }
}

public struct VerificationAuditEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var gameID: UUID
    public var gameTitle: String
    public var overallStatus: VerificationAuditStatus
    public var summary: String
    public var gates: [VerificationAuditGate]
    public var verifiedAt: Date

    public init(
        id: UUID = UUID(),
        gameID: UUID,
        gameTitle: String,
        overallStatus: VerificationAuditStatus,
        summary: String,
        gates: [VerificationAuditGate],
        verifiedAt: Date
    ) {
        self.id = id
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.overallStatus = overallStatus
        self.summary = summary
        self.gates = gates
        self.verifiedAt = verifiedAt
    }
}

public enum StoragePressure: String, Codable, CaseIterable, Sendable {
    case healthy
    case warning
    case critical

    public var displayName: String {
        switch self {
        case .healthy:
            "Healthy"
        case .warning:
            "Warning"
        case .critical:
            "Critical"
        }
    }
}

public struct ManagedStorageStatus: Codable, Hashable, Sendable {
    public var totalCapacityGB: Double
    public var reservedForSystemGB: Double
    public var usedByGamesGB: Double
    public var usedByPrefixesGB: Double
    public var reservedForQueuedDownloadsGB: Double
    public var pressure: StoragePressure
    public var notes: [String]
    public var lastMeasuredAt: Date?

    public init(
        totalCapacityGB: Double,
        reservedForSystemGB: Double,
        usedByGamesGB: Double,
        usedByPrefixesGB: Double,
        reservedForQueuedDownloadsGB: Double,
        pressure: StoragePressure,
        notes: [String],
        lastMeasuredAt: Date? = nil
    ) {
        self.totalCapacityGB = totalCapacityGB
        self.reservedForSystemGB = reservedForSystemGB
        self.usedByGamesGB = usedByGamesGB
        self.usedByPrefixesGB = usedByPrefixesGB
        self.reservedForQueuedDownloadsGB = reservedForQueuedDownloadsGB
        self.pressure = pressure
        self.notes = notes
        self.lastMeasuredAt = lastMeasuredAt
    }

    public var availableInstallHeadroomGB: Double {
        max(totalCapacityGB - reservedForSystemGB - usedByGamesGB - usedByPrefixesGB - reservedForQueuedDownloadsGB, 0)
    }
}

public struct IridiumSnapshot: Codable, Sendable {
    public static let currentSnapshotVersion = 1

    public var snapshotVersion: Int
    public var games: [GameRecord]
    public var downloads: [DownloadTask]
    public var installExecutions: [InstallExecutionRecord]
    public var installHistory: [InstallHistoryEntry]
    public var prefixes: [PrefixRecord]
    public var steamAccount: SteamAccount?
    public var steamLibrary: [SteamLibraryEntry]
    public var runtimeHealth: RuntimeHealthReport
    public var lastLibrarySync: Date?
    public var launchHistory: [LaunchHistoryEntry]
    public var pendingLaunches: [PendingLaunchRecord]
    public var compatibilityEvidence: [CompatibilityEvidenceRecord]
    public var verificationAudits: [VerificationAuditEntry]
    public var activityFeed: [ActivityLogEntry]

    public init(
        snapshotVersion: Int = Self.currentSnapshotVersion,
        games: [GameRecord],
        downloads: [DownloadTask],
        installExecutions: [InstallExecutionRecord],
        installHistory: [InstallHistoryEntry],
        prefixes: [PrefixRecord],
        steamAccount: SteamAccount?,
        steamLibrary: [SteamLibraryEntry],
        runtimeHealth: RuntimeHealthReport,
        lastLibrarySync: Date? = nil,
        launchHistory: [LaunchHistoryEntry] = [],
        pendingLaunches: [PendingLaunchRecord] = [],
        compatibilityEvidence: [CompatibilityEvidenceRecord] = [],
        verificationAudits: [VerificationAuditEntry] = [],
        activityFeed: [ActivityLogEntry] = []
    ) {
        self.snapshotVersion = snapshotVersion
        self.games = games
        self.downloads = downloads
        self.installExecutions = installExecutions
        self.installHistory = installHistory
        self.prefixes = prefixes
        self.steamAccount = steamAccount
        self.steamLibrary = steamLibrary
        self.runtimeHealth = runtimeHealth
        self.lastLibrarySync = lastLibrarySync
        self.launchHistory = launchHistory
        self.pendingLaunches = pendingLaunches
        self.compatibilityEvidence = compatibilityEvidence
        self.verificationAudits = verificationAudits
        self.activityFeed = activityFeed
    }
}

extension IridiumSnapshot {
    private enum CodingKeys: String, CodingKey {
        case snapshotVersion
        case games
        case downloads
        case installExecutions
        case installHistory
        case prefixes
        case steamAccount
        case steamLibrary
        case runtimeHealth
        case lastLibrarySync
        case launchHistory
        case pendingLaunches
        case compatibilityEvidence
        case verificationAudits
        case activityFeed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.snapshotVersion = try container.decodeIfPresent(Int.self, forKey: .snapshotVersion) ?? 0
        self.games = try container.decodeIfPresent([GameRecord].self, forKey: .games) ?? []
        self.downloads = try container.decodeIfPresent([DownloadTask].self, forKey: .downloads) ?? []
        self.installExecutions = try container.decodeIfPresent([InstallExecutionRecord].self, forKey: .installExecutions) ?? []
        self.installHistory = try container.decodeIfPresent([InstallHistoryEntry].self, forKey: .installHistory) ?? []
        self.prefixes = try container.decodeIfPresent([PrefixRecord].self, forKey: .prefixes) ?? []
        self.steamAccount = try container.decodeIfPresent(SteamAccount.self, forKey: .steamAccount)
        self.steamLibrary = try container.decodeIfPresent([SteamLibraryEntry].self, forKey: .steamLibrary) ?? []
        self.runtimeHealth = try container.decodeIfPresent(RuntimeHealthReport.self, forKey: .runtimeHealth) ?? RuntimeHealthReport(
            status: .actionRequired,
            runtimeName: "Iridium Runtime Base",
            notes: ["Runtime validation has not run yet."]
        )
        self.lastLibrarySync = try container.decodeIfPresent(Date.self, forKey: .lastLibrarySync)
        self.launchHistory = try container.decodeIfPresent([LaunchHistoryEntry].self, forKey: .launchHistory) ?? []
        self.pendingLaunches = try container.decodeIfPresent([PendingLaunchRecord].self, forKey: .pendingLaunches) ?? []
        self.compatibilityEvidence = try container.decodeIfPresent([CompatibilityEvidenceRecord].self, forKey: .compatibilityEvidence) ?? []
        self.verificationAudits = try container.decodeIfPresent([VerificationAuditEntry].self, forKey: .verificationAudits) ?? []
        self.activityFeed = try container.decodeIfPresent([ActivityLogEntry].self, forKey: .activityFeed) ?? []
    }
}

public extension IridiumSnapshot {
    static let empty: IridiumSnapshot = IridiumSnapshot(
        games: [],
        downloads: [],
        installExecutions: [],
        installHistory: [],
        prefixes: [],
        steamAccount: nil,
        steamLibrary: [],
        runtimeHealth: RuntimeHealthReport(
            status: .actionRequired,
            runtimeName: "Iridium Runtime Base",
            notes: ["Runtime validation has not run yet."]
        ),
        lastLibrarySync: nil,
        launchHistory: [],
        pendingLaunches: [],
        compatibilityEvidence: [],
        verificationAudits: [],
        activityFeed: []
    )

    static let preview: IridiumSnapshot = .empty
}
