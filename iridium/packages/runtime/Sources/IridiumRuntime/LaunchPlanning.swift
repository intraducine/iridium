import Foundation
import IridiumCore

public enum LaunchReadiness: String, Codable, CaseIterable, Sendable {
    case ready
    case blockedByJIT
    case blockedByPolicy
    case needsRuntimeValidation
    case missingExecutable

    public var displayName: String {
        switch self {
        case .ready:
            "Ready"
        case .blockedByJIT:
            "Blocked By JIT"
        case .blockedByPolicy:
            "Blocked By Policy"
        case .needsRuntimeValidation:
            "Needs Runtime Validation"
        case .missingExecutable:
            "Missing Executable"
        }
    }
}

public enum LaunchIssueSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case blocking
}

public struct LaunchIssue: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var severity: LaunchIssueSeverity
    public var message: String

    public init(id: UUID = UUID(), severity: LaunchIssueSeverity, message: String) {
        self.id = id
        self.severity = severity
        self.message = message
    }
}

public struct DiscoveredExecutable: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    public var filename: String
    public var score: Int

    public init(id: UUID = UUID(), path: String, filename: String, score: Int) {
        self.id = id
        self.path = path
        self.filename = filename
        self.score = score
    }
}

public struct ImportScanResult: Codable, Hashable, Sendable {
    public var installPath: String
    public var executables: [DiscoveredExecutable]
    public var recommendedExecutable: DiscoveredExecutable?
    public var warnings: [String]

    public init(
        installPath: String,
        executables: [DiscoveredExecutable],
        recommendedExecutable: DiscoveredExecutable?,
        warnings: [String]
    ) {
        self.installPath = installPath
        self.executables = executables
        self.recommendedExecutable = recommendedExecutable
        self.warnings = warnings
    }
}

public struct SteamInstallPlan: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var appID: String
    public var targetPath: String
    public var primaryExecutable: String
    public var contentSets: [String]
    public var estimatedInstallSizeGB: Double
    public var requiredDiskHeadroomGB: Double
    public var verificationSteps: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        appID: String,
        targetPath: String,
        primaryExecutable: String,
        contentSets: [String],
        estimatedInstallSizeGB: Double,
        requiredDiskHeadroomGB: Double,
        verificationSteps: [String]
    ) {
        self.id = id
        self.title = title
        self.appID = appID
        self.targetPath = targetPath
        self.primaryExecutable = primaryExecutable
        self.contentSets = contentSets
        self.estimatedInstallSizeGB = estimatedInstallSizeGB
        self.requiredDiskHeadroomGB = requiredDiskHeadroomGB
        self.verificationSteps = verificationSteps
    }
}

public struct SteamDepotManifest: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var depotID: String
    public var manifestID: String
    public var label: String
    public var compressedSizeGB: Double
    public var mountedPath: String

    public init(
        id: UUID = UUID(),
        depotID: String,
        manifestID: String,
        label: String,
        compressedSizeGB: Double,
        mountedPath: String
    ) {
        self.id = id
        self.depotID = depotID
        self.manifestID = manifestID
        self.label = label
        self.compressedSizeGB = compressedSizeGB
        self.mountedPath = mountedPath
    }
}

public struct SteamManifestResolution: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var appID: String
    public var buildID: String
    public var branchName: String
    public var depots: [SteamDepotManifest]
    public var verificationStages: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        appID: String,
        buildID: String,
        branchName: String,
        depots: [SteamDepotManifest],
        verificationStages: [String]
    ) {
        self.id = id
        self.title = title
        self.appID = appID
        self.buildID = buildID
        self.branchName = branchName
        self.depots = depots
        self.verificationStages = verificationStages
    }
}

public enum InstallPhaseState: String, Codable, CaseIterable, Sendable {
    case pending
    case inFlight
    case completed

    public var displayName: String {
        switch self {
        case .pending:
            "Pending"
        case .inFlight:
            "In Flight"
        case .completed:
            "Completed"
        }
    }
}

public struct InstallPhase: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var detail: String
    public var state: InstallPhaseState

    public init(id: UUID = UUID(), title: String, detail: String, state: InstallPhaseState) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
    }
}

public struct InstallPipeline: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var manifest: SteamManifestResolution
    public var phases: [InstallPhase]

    public init(
        id: UUID = UUID(),
        title: String,
        manifest: SteamManifestResolution,
        phases: [InstallPhase]
    ) {
        self.id = id
        self.title = title
        self.manifest = manifest
        self.phases = phases
    }
}

public enum VerificationGateStatus: String, Codable, CaseIterable, Sendable {
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

public struct VerificationCheck: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var detail: String
    public var status: VerificationGateStatus

    public init(id: UUID = UUID(), title: String, detail: String, status: VerificationGateStatus) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
    }
}

public struct TitleReadinessReport: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var overallStatus: VerificationGateStatus
    public var checks: [VerificationCheck]

    public init(
        id: UUID = UUID(),
        title: String,
        overallStatus: VerificationGateStatus,
        checks: [VerificationCheck]
    ) {
        self.id = id
        self.title = title
        self.overallStatus = overallStatus
        self.checks = checks
    }

    public var summary: String {
        switch overallStatus {
        case .ready:
            return "All launch gates passed for the current runtime and storage state."
        case .warning:
            if let warning = checks.first(where: { $0.status == .warning }) {
                return "\(warning.title): \(warning.detail)"
            }
            return "One or more launch gates require review before recording a launch."
        case .blocked:
            if let blocked = checks.first(where: { $0.status == .blocked }) {
                return "\(blocked.title): \(blocked.detail)"
            }
            return "A blocking launch gate must be resolved before launch preparation can continue."
        }
    }
}

private let informationalRuntimeHealthNotes: [String] = [
    "Host is configured for native runtime execution.",
    "Runtime ready.",
    "Thermal pressure is nominal.",
]

public func primaryRuntimeHealthDetail(
    for runtimeHealth: RuntimeHealthReport,
    hostSnapshot: HostCapabilitySnapshot? = nil
) -> String {
    if hostSnapshot?.launchReady == false {
        return hostSnapshot?.launchStatusSummary
            ?? runtimeHealth.notes.first
            ?? "Embedded runtime launch support is unavailable in this build."
    }

    if runtimeHealth.status != .healthy,
        let actionableNote = runtimeHealth.notes.first(where: { note in
            !note.hasPrefix("Runtime bundle ") && !informationalRuntimeHealthNotes.contains(note)
        })
    {
        return actionableNote
    }

    return runtimeHealth.notes.first
        ?? hostSnapshot?.constraints.first
        ?? "No runtime health notes are available."
}

public struct ManagedFilePresence: Codable, Hashable, Sendable {
    public var installRootExists: Bool
    public var executableExists: Bool

    public init(installRootExists: Bool, executableExists: Bool) {
        self.installRootExists = installRootExists
        self.executableExists = executableExists
    }
}

public struct LaunchSession: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var gameID: UUID
    public var title: String
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]
    public var readiness: LaunchReadiness
    public var issues: [LaunchIssue]

    public init(
        id: UUID = UUID(),
        gameID: UUID,
        title: String,
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        readiness: LaunchReadiness,
        issues: [LaunchIssue]
    ) {
        self.id = id
        self.gameID = gameID
        self.title = title
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.readiness = readiness
        self.issues = issues
    }
}

public struct ImportScanner {
    public init() {}

    public func scan(installPath: String, title: String) -> ImportScanResult {
        let installURL = URL(fileURLWithPath: installPath, isDirectory: true)
        print("[IridiumRuntime] ImportScanner: Scanning \(installPath) for title '\(title)'")

        var folderDebug: [String] = []
        folderDebug.append("exists=\(FileManager.default.fileExists(atPath: installPath))")

        if let contents = try? FileManager.default.contentsOfDirectory(atPath: installPath) {
            folderDebug.append("directCount=\(contents.count)")
            for item in contents.prefix(5) {
                folderDebug.append("  \(item)")
            }
        } else {
            folderDebug.append("contentsOfDirectoryFailed")
        }
        print("[IridiumRuntime] ImportScanner: Folder: \(folderDebug.joined(separator: " | "))")

        guard
            FileManager.default.enumerator(
                at: installURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) != nil
        else {
            print("[IridiumRuntime] ImportScanner: Failed to create enumerator")
            return ImportScanResult(
                installPath: installPath,
                executables: [],
                recommendedExecutable: nil,
                warnings: ["Install path is not readable."]
            )
        }

        var visitedEntryCount = 0
        var sampledEntries: [String] = []
        var executableURLs: [URL] = []

        if let enumerator = FileManager.default.enumerator(
            at: installURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                visitedEntryCount += 1
                if sampledEntries.count < 12 {
                    let isDirectory =
                        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    sampledEntries.append("\(url.lastPathComponent)\(isDirectory ? "/" : "")")
                }
                if url.pathExtension.lowercased() == "exe" {
                    executableURLs.append(url)
                }
            }
        }

        print(
            "[IridiumRuntime] ImportScanner: Visited \(visitedEntryCount) entries; found \(executableURLs.count) executable candidate(s)"
        )
        if !sampledEntries.isEmpty {
            print(
                "[IridiumRuntime] ImportScanner: Sampled entries: \(sampledEntries.joined(separator: ", "))"
            )
        }
        for url in executableURLs.prefix(10) {
            print("[IridiumRuntime] ImportScanner: Found exe: \(url.path)")
        }

        let executables = executableURLs.map { url in
            return DiscoveredExecutable(
                path: url.path,
                filename: url.lastPathComponent,
                score: scoreExecutable(named: url.lastPathComponent, title: title)
            )
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename)
                    == .orderedAscending
            }
            return lhs.score > rhs.score
        }

        var warnings: [String] = []
        if executables.isEmpty {
            warnings.append("No Windows executable was found in the selected folder.")
        } else if let top = executables.first, top.score < 40 {
            warnings.append(
                "Only low-confidence executable candidates were found. Manual selection may be required."
            )
        }

        return ImportScanResult(
            installPath: installPath,
            executables: executables,
            recommendedExecutable: executables.first,
            warnings: warnings
        )
    }

    private func scoreExecutable(named filename: String, title: String) -> Int {
        let baseName = filename.replacingOccurrences(
            of: ".exe", with: "", options: .caseInsensitive)
        let normalizedFile = normalized(baseName)
        let normalizedTitle = normalized(title)

        var score = 50

        if normalizedTitle.contains(normalizedFile) || normalizedFile.contains(normalizedTitle) {
            score += 45
        }

        let penaltyTokens = [
            "unins", "setup", "crash", "redis", "launcherpatcher", "vc_redist", "eac", "battleye",
        ]
        if penaltyTokens.contains(where: { normalizedFile.contains($0) }) {
            score -= 40
        }

        let softPenaltyTokens = ["launcher", "config", "support", "benchmark"]
        if softPenaltyTokens.contains(where: { normalizedFile.contains($0) }) {
            score -= 12
        }

        if normalizedFile == normalizedTitle {
            score += 20
        }

        if normalizedFile.contains("shipping") || normalizedFile.contains("game") {
            score += 8
        }

        return score
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

public struct SteamInstallPlanner: Sendable {
    private let manifestClient: any SteamDepotManifestClient

    public init(manifestClient: any SteamDepotManifestClient = HostedSteamDepotManifestClient()) {
        self.manifestClient = manifestClient
    }

    public func plan(for entry: SteamLibraryEntry, targetPath: String) -> SteamInstallPlan {
        manifestClient.installPlan(for: entry, targetPath: targetPath)
    }
}

public struct SteamManifestResolver: Sendable {
    private let manifestClient: any SteamDepotManifestClient

    public init(manifestClient: any SteamDepotManifestClient = HostedSteamDepotManifestClient()) {
        self.manifestClient = manifestClient
    }

    public func resolve(for entry: SteamLibraryEntry) -> SteamManifestResolution {
        manifestClient.manifest(for: entry)
    }
}

public struct InstallPipelineBuilder: Sendable {
    public init() {}

    public func build(
        for entry: SteamLibraryEntry,
        plan: SteamInstallPlan,
        manifest: SteamManifestResolution,
        task: DownloadTask?,
        execution: InstallExecutionRecord?
    ) -> InstallPipeline {
        let resolveState = phaseState(
            for: .resolving,
            execution: execution,
            entryInstalled: entry.installed,
            task: task
        )
        let downloadState = phaseState(
            for: .downloading,
            execution: execution,
            entryInstalled: entry.installed,
            task: task
        )
        let verifyState = phaseState(
            for: .verifying,
            execution: execution,
            entryInstalled: entry.installed,
            task: task
        )
        let mountState = phaseState(
            for: .mounting,
            execution: execution,
            entryInstalled: entry.installed,
            task: task
        )

        let downloadedDepotSummary: String
        if let execution {
            downloadedDepotSummary =
                "\(execution.completedDepotIDs.count) / \(execution.depotIDs.count) depots staged."
        } else {
            downloadedDepotSummary = "\(manifest.depots.count) depot(s) pending."
        }

        let phases = [
            InstallPhase(
                title: "Resolve depots",
                detail:
                    "\(manifest.depots.count) depot(s) on branch \(manifest.branchName) with build \(manifest.buildID).",
                state: resolveState
            ),
            InstallPhase(
                title: "Download payloads",
                detail:
                    "Target \(plan.requiredDiskHeadroomGB.formatted(.number.precision(.fractionLength(0)))) GB headroom across \(manifest.depots.count) depot(s). \(downloadedDepotSummary)",
                state: downloadState
            ),
            InstallPhase(
                title: "Verify content",
                detail: manifest.verificationStages.joined(separator: " • "),
                state: verifyState
            ),
            InstallPhase(
                title: "Mount runtime target",
                detail:
                    "Bind payload into \(plan.targetPath) and prepare \(plan.primaryExecutable).",
                state: mountState
            ),
        ]

        return InstallPipeline(title: entry.title, manifest: manifest, phases: phases)
    }

    private func phaseState(
        for phase: InstallExecutionStage,
        execution: InstallExecutionRecord?,
        entryInstalled: Bool,
        task: DownloadTask?
    ) -> InstallPhaseState {
        if entryInstalled || task?.state == .installed || execution?.stage == .completed {
            return .completed
        }

        guard let execution else {
            if phase == .resolving {
                return .completed
            }
            if phase == .downloading, task != nil {
                return .inFlight
            }
            if phase == .verifying, task?.state == .verifying {
                return .inFlight
            }
            if phase == .mounting, task?.state == .mounting {
                return .inFlight
            }
            return .pending
        }

        if stageOrder(execution.stage) > stageOrder(phase) {
            return .completed
        }
        if execution.stage == phase {
            return .inFlight
        }
        return .pending
    }

    private func stageOrder(_ stage: InstallExecutionStage) -> Int {
        switch stage {
        case .queued:
            0
        case .resolving:
            1
        case .downloading:
            2
        case .verifying:
            3
        case .mounting:
            4
        case .completed:
            5
        }
    }
}

public struct LaunchEligibilityAuditor: Sendable {
    public init() {}

    public func audit(
        game: GameRecord,
        session: LaunchSession,
        runtimeHealth: RuntimeHealthReport,
        storage: ManagedStorageStatus,
        pipeline: InstallPipeline?,
        filePresence: ManagedFilePresence? = nil,
        hostSnapshot: HostCapabilitySnapshot? = nil
    ) -> TitleReadinessReport {
        let installCheck: VerificationCheck
        if let pipeline {
            let installReady = pipeline.phases.allSatisfy { $0.state == .completed }
            installCheck = VerificationCheck(
                title: "Install pipeline",
                detail: installReady
                    ? "All install phases completed for build \(pipeline.manifest.buildID)."
                    : "Install is still waiting on \(pendingPhaseSummary(from: pipeline)).",
                status: installReady ? .ready : .blocked
            )
        } else {
            installCheck = VerificationCheck(
                title: "Install pipeline",
                detail: game.source == .steam
                    ? "Steam library entry is not resolved yet."
                    : "Manual import does not require depot orchestration.",
                status: game.source == .steam ? .warning : .ready
            )
        }

        let launchPathCheck = VerificationCheck(
            title: "Launch target",
            detail: session.executablePath.isEmpty
                ? "Executable path is missing."
                : session.executablePath,
            status: session.executablePath.isEmpty ? .blocked : .ready
        )

        let managedFilesCheck: VerificationCheck? = filePresence.map { presence in
            let status: VerificationGateStatus =
                (presence.installRootExists && presence.executableExists) ? .ready : .blocked
            let detail: String
            switch (presence.installRootExists, presence.executableExists) {
            case (true, true):
                detail = "Managed install root and launch target are present on disk."
            case (false, false):
                detail = "Managed install root and launch target are missing on disk."
            case (false, true):
                detail = "Managed install root is missing on disk."
            case (true, false):
                detail = "Launch target is missing on disk."
            }

            return VerificationCheck(
                title: "Managed files",
                detail: detail,
                status: status
            )
        }

        let runtimeCheck = VerificationCheck(
            title: "Runtime health",
            detail: primaryRuntimeHealthDetail(for: runtimeHealth, hostSnapshot: hostSnapshot),
            status: {
                switch runtimeHealth.status {
                case .healthy:
                    .ready
                case .degraded:
                    .warning
                case .actionRequired:
                    .blocked
                }
            }()
        )

        let launchReadinessCheck = VerificationCheck(
            title: "Launch readiness",
            detail: session.issues.first(where: { $0.severity == .blocking })?.message
                ?? session.issues.first?.message
                ?? session.readiness.displayName,
            status: {
                switch session.readiness {
                case .ready:
                    .ready
                case .blockedByJIT, .blockedByPolicy, .missingExecutable:
                    .blocked
                case .needsRuntimeValidation:
                    session.issues.contains(where: { $0.severity == .blocking })
                        ? .blocked : .warning
                }
            }()
        )

        let prefixCheck = VerificationCheck(
            title: "Prefix state",
            detail: "Prefix is \(game.prefixState.displayName.lowercased()).",
            status: {
                switch game.prefixState {
                case .clean, .customized:
                    .ready
                case .verificationFailed:
                    .blocked
                case .rebuilding:
                    .warning
                }
            }()
        )

        let storageCheck = VerificationCheck(
            title: "Launch headroom",
            detail:
                "\(storage.availableInstallHeadroomGB.formatted(.number.precision(.fractionLength(0)))) GB managed headroom remains.",
            status: {
                switch storage.pressure {
                case .healthy:
                    .ready
                case .warning:
                    .warning
                case .critical:
                    .blocked
                }
            }()
        )

        let checks = [
            installCheck, launchPathCheck, managedFilesCheck, runtimeCheck, launchReadinessCheck,
            prefixCheck, storageCheck,
        ].compactMap { $0 }
        let overallStatus: VerificationGateStatus
        if checks.contains(where: { $0.status == VerificationGateStatus.blocked }) {
            overallStatus = .blocked
        } else if checks.contains(where: { $0.status == VerificationGateStatus.warning }) {
            overallStatus = .warning
        } else {
            overallStatus = .ready
        }

        return TitleReadinessReport(title: game.title, overallStatus: overallStatus, checks: checks)
    }

    private func pendingPhaseSummary(from pipeline: InstallPipeline) -> String {
        pipeline.phases
            .filter { $0.state != .completed }
            .map(\.title)
            .joined(separator: ", ")
    }
}

public struct LaunchCoordinator: Sendable {
    public let runtime: RuntimeDescriptor
    public let jitStatus: JITStatus
    public let hostSnapshot: HostCapabilitySnapshot?
    public let runtimePolicy: RuntimePolicy
    public let whitelistPolicy: any WhitelistPolicy

    public init(
        runtime: RuntimeDescriptor,
        jitStatus: JITStatus,
        hostSnapshot: HostCapabilitySnapshot? = nil,
        whitelistPolicy: any WhitelistPolicy = DefaultWhitelistPolicy(),
        runtimePolicy: RuntimePolicy = RuntimePolicy(
            memoryBudgetClass: .balanced,
            resolutionScale: 1.0,
            shaderStrategy: .onDemand
        )
    ) {
        self.runtime = runtime
        self.jitStatus = jitStatus
        self.hostSnapshot = hostSnapshot
        self.whitelistPolicy = whitelistPolicy
        self.runtimePolicy = runtimePolicy
    }

    public func prepareLaunch(
        for game: GameRecord,
        runtimeHealth: RuntimeHealthReport,
        scanResult: ImportScanResult? = nil,
        filePresence: ManagedFilePresence? = nil
    ) -> LaunchSession {
        let resolvedExecutable = resolveExecutable(for: game, scanResult: scanResult)
        var issues: [LaunchIssue] = []
        let readiness: LaunchReadiness

        if resolvedExecutable.isEmpty {
            readiness = .missingExecutable
            issues.append(
                LaunchIssue(
                    severity: .blocking, message: "No executable path is available for this title.")
            )
        } else if isDesktopShellEntrypoint(resolvedExecutable) {
            readiness = .missingExecutable
            issues.append(
                LaunchIssue(
                    severity: .blocking,
                    message:
                        "Desktop shell entrypoints are blocked. Select the game executable directly."
                ))
        } else if let filePresence, !filePresence.installRootExists {
            readiness = .missingExecutable
            issues.append(
                LaunchIssue(
                    severity: .blocking, message: "Managed install root is missing from disk."))
        } else if let filePresence, !filePresence.executableExists {
            readiness = .missingExecutable
            issues.append(
                LaunchIssue(severity: .blocking, message: "Launch target is missing from disk."))
        } else if jitStatus != .ready {
            readiness = .blockedByJIT
            let blockingMessage: String
            if jitStatus == .unavailable {
                blockingMessage =
                    hostSnapshot?.launchStatusSummary
                    ?? "Embedded runtime launch support is unavailable because the JIT probe failed on this host."
            } else {
                blockingMessage =
                    hostSnapshot?.launchStatusSummary
                    ?? "No external debugger/JIT session detected."
            }
            issues.append(LaunchIssue(severity: .blocking, message: blockingMessage))
        } else if let hostSnapshot, hostSnapshot.usesLightweightDebuggerCheck {
            readiness = .blockedByPolicy
            issues.append(
                LaunchIssue(
                    severity: .blocking,
                    message: hostSnapshot.lightweightDebuggerCheckSummary
                )
            )
        } else if let hostSnapshot, hostSnapshot.launchReady == false {
            readiness = .blockedByPolicy
            issues.append(
                LaunchIssue(
                    severity: .blocking,
                    message: hostSnapshot.launchStatusSummary
                        ?? "Embedded runtime launch support is unavailable in this build."
                )
            )
        } else if runtimeHealth.status == .actionRequired {
            readiness = .needsRuntimeValidation
            issues.append(
                LaunchIssue(
                    severity: .blocking,
                    message: primaryRuntimeHealthDetail(
                        for: runtimeHealth, hostSnapshot: hostSnapshot)
                )
            )
        } else if let hostSnapshot, hostSnapshot.selectedRuntimeBundle == nil {
            readiness = .needsRuntimeValidation
            issues.append(
                LaunchIssue(
                    severity: .blocking,
                    message: "No validated runtime bundle is available for this host."))
        } else if hostSnapshot?.thermalState == .critical {
            readiness = .blockedByPolicy
            issues.append(
                LaunchIssue(
                    severity: .blocking, message: "Thermal state is critical and launch is blocked."
                ))
        } else if hostSnapshot?.lowPowerModeEnabled == true
            && runtimePolicy.requiresExplicitWhitelist
        {
            readiness = .blockedByPolicy
            issues.append(
                LaunchIssue(
                    severity: .blocking,
                    message: "Heavy-title policy blocks launch while low power mode is enabled."))
        } else if let hostSnapshot, let runtimeBundle = hostSnapshot.selectedRuntimeBundle {
            switch whitelistPolicy.evaluate(
                game: game,
                runtimeBundle: runtimeBundle,
                hostSnapshot: hostSnapshot,
                runtimePolicy: runtimePolicy
            ) {
            case .success:
                if runtimeHealth.status == .degraded {
                    readiness = .needsRuntimeValidation
                    issues.append(
                        LaunchIssue(
                            severity: .warning,
                            message: primaryRuntimeHealthDetail(
                                for: runtimeHealth, hostSnapshot: hostSnapshot)
                        )
                    )
                } else {
                    readiness = .ready
                    issues.append(
                        LaunchIssue(
                            severity: .info,
                            message: "Launch path prepared without exposing a desktop shell."))
                }
            case .failure(let failure):
                readiness = .blockedByPolicy
                issues.append(LaunchIssue(severity: .blocking, message: failure.reason))
            }
        } else {
            readiness = .ready
            issues.append(
                LaunchIssue(
                    severity: .info,
                    message: "Launch path prepared without exposing a desktop shell."))
        }

        if runtime.exposesDesktopShell {
            issues.append(
                LaunchIssue(
                    severity: .blocking,
                    message: "Runtime configuration must not expose a desktop shell."))
        }

        return LaunchSession(
            gameID: game.id,
            title: game.title,
            executablePath: resolvedExecutable,
            arguments: game.launchProfile.arguments,
            workingDirectory: game.installPath,
            environment: baseEnvironment(for: game),
            readiness: readiness,
            issues: issues
        )
    }

    private func baseEnvironment(for game: GameRecord) -> [String: String] {
        var environment: [String: String] = [
            RuntimeEnvironmentKey.noDesktop: runtime.exposesDesktopShell ? "0" : "1",
            "IRIDIUM_RENDERER": (runtimePolicy.rendererOverride ?? game.rendererPreset).rawValue,
            "IRIDIUM_DEVICE_TIER": game.deviceTier.rawValue,
            "IRIDIUM_PREFIX_ID": game.launchProfile.prefixID.uuidString,
            RuntimeEnvironmentKey.memoryBudget: runtimePolicy.memoryBudgetClass.rawValue,
            RuntimeEnvironmentKey.shaderStrategy: runtimePolicy.shaderStrategy.rawValue,
            RuntimeEnvironmentKey.resolutionScale: String(format: "%.2f", runtimePolicy.resolutionScale),
        ]

        if let cap = runtimePolicy.framePacingCap {
            environment[RuntimeEnvironmentKey.frameCap] = String(cap)
        }

        if let runtimeBundle = hostSnapshot?.selectedRuntimeBundle {
            environment[RuntimeEnvironmentKey.runtimeBundleID] = runtimeBundle.id
            environment[RuntimeEnvironmentKey.runtimeBundleVersion] = runtimeBundle.version
        }

        environment.merge(runtimePolicy.environmentOverrides) { _, new in new }
        return environment
    }

    private func resolveExecutable(for game: GameRecord, scanResult: ImportScanResult?) -> String {
        let launchPath = game.launchProfile.executablePath
        if launchPath.isEmpty {
            return scanResult?.recommendedExecutable?.path ?? ""
        }

        if launchPath.hasPrefix("/") {
            return launchPath
        }

        return URL(fileURLWithPath: game.installPath, isDirectory: true)
            .appending(path: launchPath)
            .path
    }

    private func isDesktopShellEntrypoint(_ path: String) -> Bool {
        let blocked = [
            "explorer.exe",
            "cmd.exe",
            "powershell.exe",
            "start.exe",
            "wscript.exe",
            "cscript.exe",
        ]
        return blocked.contains(URL(fileURLWithPath: path).lastPathComponent.lowercased())
    }

    private func tierRank(_ tier: DeviceTier) -> Int {
        switch tier {
        case .tier1:
            return 1
        case .tier2:
            return 2
        case .tier3:
            return 3
        }
    }
}
