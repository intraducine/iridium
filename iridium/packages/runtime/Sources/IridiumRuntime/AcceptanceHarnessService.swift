import Foundation
import IridiumCore

public struct AcceptanceHarnessConfiguration: Sendable {
    public var title: String
    public var source: GameSource
    public var installPath: String
    public var steamAppID: String?
    public var executableOverridePath: String?
    public var outputPath: String?

    public init(
        title: String,
        source: GameSource,
        installPath: String,
        steamAppID: String? = nil,
        executableOverridePath: String? = nil,
        outputPath: String? = nil
    ) {
        self.title = title
        self.source = source
        self.installPath = installPath
        self.steamAppID = steamAppID
        self.executableOverridePath = executableOverridePath
        self.outputPath = outputPath
    }
}

public struct AcceptanceInstallSummary: Codable, Hashable, Sendable {
    public var title: String
    public var appID: String
    public var buildID: String
    public var branchName: String
    public var targetPath: String
    public var primaryExecutable: String
    public var stage: String
    public var completedDepotIDs: [String]
    public var depotProgressBytes: [String: Int64]
    public var depotVerifiedIDs: [String]
    public var resumeCheckpoint: String?

    public init(
        title: String,
        appID: String,
        buildID: String,
        branchName: String,
        targetPath: String,
        primaryExecutable: String,
        stage: String,
        completedDepotIDs: [String],
        depotProgressBytes: [String: Int64],
        depotVerifiedIDs: [String],
        resumeCheckpoint: String?
    ) {
        self.title = title
        self.appID = appID
        self.buildID = buildID
        self.branchName = branchName
        self.targetPath = targetPath
        self.primaryExecutable = primaryExecutable
        self.stage = stage
        self.completedDepotIDs = completedDepotIDs
        self.depotProgressBytes = depotProgressBytes
        self.depotVerifiedIDs = depotVerifiedIDs
        self.resumeCheckpoint = resumeCheckpoint
    }
}

public struct AcceptanceHarnessReportArtifact: Codable, Hashable, Sendable {
    public var title: String
    public var source: GameSource
    public var installPath: String
    public var selectedExecutablePath: String?
    public var recommendedExecutablePath: String?
    public var discoveredExecutables: [String]
    public var warnings: [String]
    public var executableFingerprint: String?
    public var managedArtifactIdentifier: String?
    public var runtimeBundleIdentifier: String?
    public var runtimeBundleVersion: String?
    public var policySummary: String
    public var launchReadiness: String
    public var launchIssues: [String]
    public var readinessSummary: String
    public var readinessChecks: [VerificationCheck]
    public var hostCapabilitySnapshot: HostCapabilitySnapshot?
    public var hostConstraints: [String]
    public var installSummary: AcceptanceInstallSummary?
    public var validationReport: ValidationHarnessReport
    public var generatedAt: Date

    public init(
        title: String,
        source: GameSource,
        installPath: String,
        selectedExecutablePath: String?,
        recommendedExecutablePath: String?,
        discoveredExecutables: [String],
        warnings: [String],
        executableFingerprint: String?,
        managedArtifactIdentifier: String?,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?,
        policySummary: String,
        launchReadiness: String,
        launchIssues: [String],
        readinessSummary: String,
        readinessChecks: [VerificationCheck],
        hostCapabilitySnapshot: HostCapabilitySnapshot?,
        hostConstraints: [String],
        installSummary: AcceptanceInstallSummary?,
        validationReport: ValidationHarnessReport,
        generatedAt: Date = Date()
    ) {
        self.title = title
        self.source = source
        self.installPath = installPath
        self.selectedExecutablePath = selectedExecutablePath
        self.recommendedExecutablePath = recommendedExecutablePath
        self.discoveredExecutables = discoveredExecutables
        self.warnings = warnings
        self.executableFingerprint = executableFingerprint
        self.managedArtifactIdentifier = managedArtifactIdentifier
        self.runtimeBundleIdentifier = runtimeBundleIdentifier
        self.runtimeBundleVersion = runtimeBundleVersion
        self.policySummary = policySummary
        self.launchReadiness = launchReadiness
        self.launchIssues = launchIssues
        self.readinessSummary = readinessSummary
        self.readinessChecks = readinessChecks
        self.hostCapabilitySnapshot = hostCapabilitySnapshot
        self.hostConstraints = hostConstraints
        self.installSummary = installSummary
        self.validationReport = validationReport
        self.generatedAt = generatedAt
    }
}

public struct AcceptanceHarnessService: Sendable {
    private let artifactInventory: any GameArtifactInventory
    private let runtimeBundleRegistry: any RuntimeBundleRegistry
    private let capabilityProvider: any HostCapabilityProvider
    private let validationService: any RuntimeValidationService
    private let policyResolver: any RuntimePolicyResolver
    private let titleOverrideResolver: any TitleOverrideResolver
    private let executor: any RuntimeSessionExecutor
    private let steamManifestClient: any SteamDepotManifestClient
    private let depotTransferEngine: any DepotTransferEngine
    private let steamInstallCoordinator: any SteamInstallCoordinator

    public init(
        artifactInventory: any GameArtifactInventory = FileSystemGameArtifactInventory(),
        runtimeBundleRegistry: any RuntimeBundleRegistry = FileSystemRuntimeBundleRegistry(),
        capabilityProvider: (any HostCapabilityProvider)? = nil,
        validationService: any RuntimeValidationService = DefaultRuntimeValidationService(),
        policyResolver: any RuntimePolicyResolver = DefaultRuntimePolicyResolver(),
        titleOverrideResolver: any TitleOverrideResolver = DefaultTitleOverrideResolver(),
        steamManifestClient: (any SteamDepotManifestClient)? = nil,
        depotTransferEngine: any DepotTransferEngine = DefaultDepotTransferEngine(),
        steamInstallCoordinator: (any SteamInstallCoordinator)? = nil,
        executor: (any RuntimeSessionExecutor)? = nil
    ) {
        self.artifactInventory = artifactInventory
        self.runtimeBundleRegistry = runtimeBundleRegistry
        self.capabilityProvider = capabilityProvider ?? FileSystemHostCapabilityProvider(
            runtimeBundleRegistry: runtimeBundleRegistry,
            managedRootURL: URL(fileURLWithPath: configurationManagedRootPath(), isDirectory: true)
        )
        self.validationService = validationService
        self.policyResolver = policyResolver
        self.titleOverrideResolver = titleOverrideResolver
        self.depotTransferEngine = depotTransferEngine
#if os(macOS) || targetEnvironment(simulator)
        let runtimeBridgeFallbackMode: RuntimeBridgeFallbackMode = .never
        let runtimeBridgeProcessor: (any RuntimeBridgeRequestProcessor)? = NativeRuntimeBridgeRequestProcessor(
            runtimeBackendClient: DevelopmentRuntimeBackendClient()
        )
        let steamBridgeFallbackMode: SteamBridgeFallbackMode = .never
        let steamBridgeProcessor: (any SteamBridgeRequestProcessor)? = NativeSteamBridgeRequestProcessor()
#else
        let runtimeBridgeFallbackMode: RuntimeBridgeFallbackMode = .never
        let runtimeBridgeProcessor: (any RuntimeBridgeRequestProcessor)? = nil
        let steamBridgeFallbackMode: SteamBridgeFallbackMode = .never
        let steamBridgeProcessor: (any SteamBridgeRequestProcessor)? = nil
#endif
        self.steamManifestClient = steamManifestClient ?? BridgedSteamDepotManifestClient(
            processor: steamBridgeProcessor,
            fallbackMode: steamBridgeFallbackMode
        )
        self.steamInstallCoordinator = steamInstallCoordinator ?? NativeSteamInstallCoordinator(
            contentClient: BridgedSteamContentServerClient(
                processor: steamBridgeProcessor,
                fallbackMode: steamBridgeFallbackMode
            ),
            verificationService: BridgedDepotVerificationService(
                processor: steamBridgeProcessor,
                fallbackMode: steamBridgeFallbackMode
            )
        )
        self.executor = executor ?? FileSystemRuntimeSessionExecutor(
            hostController: BridgedRuntimeHostController(
                processor: runtimeBridgeProcessor,
                fallbackMode: runtimeBridgeFallbackMode
            ),
            executionMonitor: BridgedRuntimeExecutionMonitor(
                processor: runtimeBridgeProcessor,
                fallbackMode: runtimeBridgeFallbackMode
            ),
            telemetryCollector: BridgedRuntimeTelemetryCollector(
                processor: runtimeBridgeProcessor,
                fallbackMode: runtimeBridgeFallbackMode
            )
        )
    }

    public func run(_ configuration: AcceptanceHarnessConfiguration) async throws -> AcceptanceHarnessReportArtifact {
        let runtimeBundle = try provisionRuntimeBundle()
        let hostSnapshot = await capabilityProvider.snapshot()
        let runtimeHealth = await validationService.validate(snapshot: hostSnapshot)
        let scan = artifactInventory.scanImport(installPath: configuration.installPath, title: configuration.title)
        let selectedExecutablePath = configuration.executableOverridePath ?? scan.recommendedExecutable?.path
        let filePresence = ManagedFilePresence(
            installRootExists: FileManager.default.fileExists(atPath: URL(fileURLWithPath: configuration.installPath).path),
            executableExists: selectedExecutablePath.map { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).path) } ?? false
        )

        let validationReport: ValidationHarnessReport
        let launchSession: LaunchSession
        let policySummary: String
        let readinessReport: TitleReadinessReport
        let installSummary: AcceptanceInstallSummary?
        let fingerprint: ExecutableFingerprint?
        let artifact: RuntimeArtifact?

        if let executablePath = selectedExecutablePath {
            let materialized = try makeGameMaterialization(
                configuration: configuration,
                executablePath: executablePath,
                runtimeBundle: runtimeBundle,
                hostSnapshot: hostSnapshot
            )
            let game = materialized.game
            fingerprint = materialized.fingerprint
            artifact = materialized.artifact
            let policy = policyResolver.resolve(
                game: game,
                hostSnapshot: hostSnapshot,
                runtimeBundle: runtimeBundle,
                basePolicy: RuntimePolicy(
                    memoryBudgetClass: .balanced,
                    resolutionScale: 1.0,
                    framePacingCap: 60,
                    shaderStrategy: .onDemand
                ),
                overrideResolver: titleOverrideResolver
            )
            policySummary = summarize(policy: policy)
            launchSession = LaunchCoordinator(
                runtime: runtimeBundle.descriptor,
                jitStatus: hostSnapshot.jitStatus,
                hostSnapshot: hostSnapshot,
                runtimePolicy: policy
            ).prepareLaunch(
                for: game,
                runtimeHealth: runtimeHealth,
                scanResult: scan,
                filePresence: filePresence
            )
            let steamPipeline: (pipeline: InstallPipeline, summary: AcceptanceInstallSummary)? = if configuration.source == .steam {
                await buildSteamInstallState(for: configuration, runtimeBundle: runtimeBundle)
            } else {
                nil
            }
            installSummary = steamPipeline?.summary
            readinessReport = LaunchEligibilityAuditor().audit(
                game: game,
                session: launchSession,
                runtimeHealth: runtimeHealth,
                storage: managedStorageStatus(from: hostSnapshot),
                pipeline: steamPipeline?.pipeline,
                filePresence: filePresence
            )
            let prefix = PrefixRecord(
                id: game.launchProfile.prefixID,
                name: "\(configuration.title) Prefix",
                runtimeName: runtimeBundle.name,
                state: .clean,
                storageFootprint: "0.5 GB",
                storageFootprintGB: 0.5
            )
            validationReport = await ValidationHarness().runExecution(
                ValidationHarnessExecutionRequest(
                    runtimeRequest: RuntimeSessionRequest(
                        game: game,
                        prefix: prefix,
                        session: launchSession,
                        hostSnapshot: hostSnapshot,
                        runtimeBundle: runtimeBundle,
                        policy: policy
                    )
                ),
                executor: executor
            )
        } else {
            launchSession = LaunchSession(
                gameID: UUID(),
                title: configuration.title,
                executablePath: "",
                arguments: [],
                workingDirectory: configuration.installPath,
                environment: [:],
                readiness: .missingExecutable,
                issues: [LaunchIssue(severity: .blocking, message: "No candidate executable was found for the supplied payload path.")]
            )
            policySummary = "unresolved"
            readinessReport = TitleReadinessReport(
                title: configuration.title,
                overallStatus: .blocked,
                checks: [
                    VerificationCheck(
                        title: "Launch target",
                        detail: "No candidate executable was found for the supplied payload path.",
                        status: .blocked
                    )
                ]
            )
            installSummary = configuration.source == .steam
                ? await buildSteamInstallState(for: configuration, runtimeBundle: runtimeBundle)?.summary
                : nil
            fingerprint = nil
            artifact = nil
            validationReport = ValidationHarnessReport(
                title: configuration.title,
                accepted: false,
                runtimeBundleVersion: runtimeBundle.version,
                terminalStatus: RuntimeHostSessionState.failed.rawValue,
                failureCode: RuntimeFailureCode.missingExecutable.rawValue,
                failureReason: "No candidate executable was found for the supplied payload path.",
                evidenceSummary: "Acceptance harness could not resolve a launch target."
            )
        }

        let report = AcceptanceHarnessReportArtifact(
            title: configuration.title,
            source: configuration.source,
            installPath: configuration.installPath,
            selectedExecutablePath: selectedExecutablePath,
            recommendedExecutablePath: scan.recommendedExecutable?.path,
            discoveredExecutables: scan.executables.map(\.path),
            warnings: scan.warnings,
            executableFingerprint: fingerprint?.value,
            managedArtifactIdentifier: artifact?.identifier,
            runtimeBundleIdentifier: runtimeBundle.id,
            runtimeBundleVersion: runtimeBundle.version,
            policySummary: policySummary,
            launchReadiness: launchSession.readiness.rawValue,
            launchIssues: launchSession.issues.map(\.message),
            readinessSummary: readinessReport.summary,
            readinessChecks: readinessReport.checks,
            hostCapabilitySnapshot: hostSnapshot,
            hostConstraints: hostSnapshot.constraints,
            installSummary: installSummary,
            validationReport: validationReport
        )

        if let outputPath = configuration.outputPath {
            try write(report, to: outputPath)
        }

        return report
    }

    private func provisionRuntimeBundle() throws -> RuntimeBundleManifest {
        if let bundle = try runtimeBundleRegistry.defaultBundle() {
            return bundle
        }
        throw RuntimeBundleRegistryError.missingExternalBundle("No runtime bundle is registered in managed storage.")
    }

    private func makeGameMaterialization(
        configuration: AcceptanceHarnessConfiguration,
        executablePath: String,
        runtimeBundle: RuntimeBundleManifest,
        hostSnapshot: HostCapabilitySnapshot
    ) throws -> (game: GameRecord, fingerprint: ExecutableFingerprint, artifact: RuntimeArtifact) {
        let fingerprint = try artifactInventory.fingerprintExecutable(at: executablePath)
        let artifact = try artifactInventory.makeManagedArtifact(
            title: configuration.title,
            executablePath: executablePath,
            installPath: configuration.installPath
        )
        let prefixID = UUID()
        let guessedRenderer = titleOverrideResolver.overridePolicy(
            for: GameRecord(
                title: configuration.title,
                source: configuration.source,
                installPath: configuration.installPath,
                savePathMapping: "Documents/Saves/\(configuration.title)",
                compatibilityProfileName: "validation-default",
                inputProfileName: "Generic",
                touchOverlayName: "Standard Touch",
                controllerPresetName: "Standard Gamepad",
                keyboardMouseEnabled: true,
                prefixState: .clean,
                deviceTier: hostSnapshot.deviceTier,
                rendererPreset: runtimeBundle.descriptor.graphicsStack == .metalOpenGLFallback ? .metalOpenGLFallback : .dxvkBalanced,
                launchProfile: GameLaunchProfile(
                    executablePath: executablePath,
                    arguments: [],
                    prefixID: prefixID,
                    rendererPreset: runtimeBundle.descriptor.graphicsStack == .metalOpenGLFallback ? .metalOpenGLFallback : .dxvkBalanced,
                    deviceTier: hostSnapshot.deviceTier,
                    titleFlags: [configuration.source.rawValue]
                ),
                summary: "Probe"
            )
        )?.rendererOverride ?? (runtimeBundle.descriptor.graphicsStack == .metalOpenGLFallback ? .metalOpenGLFallback : .dxvkBalanced)

        let game = GameRecord(
            title: configuration.title,
            source: configuration.source,
            installPath: configuration.installPath,
            savePathMapping: "Documents/Saves/\(configuration.title)",
            compatibilityProfileName: "validation-default",
            inputProfileName: "Generic",
            touchOverlayName: "Standard Touch",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: hostSnapshot.deviceTier,
            rendererPreset: guessedRenderer,
            launchProfile: GameLaunchProfile(
                executablePath: executablePath,
                arguments: [],
                prefixID: prefixID,
                rendererPreset: guessedRenderer,
                deviceTier: hostSnapshot.deviceTier,
                titleFlags: [configuration.source.rawValue]
            ),
            installedSizeGB: directorySizeGB(at: configuration.installPath),
            managedArtifactIdentifier: artifact.identifier,
            executableFingerprint: fingerprint.value,
            summary: "Acceptance harness candidate for \(configuration.title)"
        )
        return (game, fingerprint, artifact)
    }

    private func summarize(policy: RuntimePolicy) -> String {
        [
            policy.memoryBudgetClass.rawValue,
            policy.rendererOverride?.rawValue ?? "default-renderer",
            "scale=\(String(format: "%.2f", policy.resolutionScale))",
            "cap=\(policy.framePacingCap.map(String.init) ?? "uncapped")",
            policy.shaderStrategy.rawValue
        ].joined(separator: ", ")
    }

    private func directorySizeGB(at path: String) -> Double {
        let enumerator = FileManager.default.enumerator(atPath: path)
        var total: Int64 = 0
        while let next = enumerator?.nextObject() as? String {
            let url = URL(fileURLWithPath: path).appending(path: next)
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) {
                total += size
            }
        }
        return Double(total) / 1_000_000_000
    }

    private func write(_ report: AcceptanceHarnessReportArtifact, to outputPath: String) throws {
        let url = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private func managedStorageStatus(from hostSnapshot: HostCapabilitySnapshot) -> ManagedStorageStatus {
        ManagedStorageStatus(
            totalCapacityGB: max(hostSnapshot.availableManagedStorageGB + 24, 32),
            reservedForSystemGB: 24,
            usedByGamesGB: 0,
            usedByPrefixesGB: 0,
            reservedForQueuedDownloadsGB: 0,
            pressure: hostSnapshot.availableManagedStorageGB < 8 ? .critical : (hostSnapshot.availableManagedStorageGB < 16 ? .warning : .healthy),
            notes: hostSnapshot.constraints,
            lastMeasuredAt: hostSnapshot.measuredAt
        )
    }

    private func buildSteamInstallState(
        for configuration: AcceptanceHarnessConfiguration,
        runtimeBundle: RuntimeBundleManifest
    ) async -> (pipeline: InstallPipeline, summary: AcceptanceInstallSummary)? {
        let entry = SteamLibraryEntry(
            title: configuration.title,
            appID: configuration.steamAppID ?? derivedSteamAppID(from: configuration.title),
            installed: false,
            cloudSavesEnabled: true,
            lastSyncedAt: Date()
        )
        let plan = SteamInstallPlanner(manifestClient: steamManifestClient).plan(
            for: entry,
            targetPath: configuration.installPath
        )
        let manifest = SteamManifestResolver(manifestClient: steamManifestClient).resolve(for: entry)
        let seededExecution = depotTransferEngine.makeExecution(for: entry, plan: plan, manifest: manifest)
        var execution = InstallExecutionRecord(
            id: seededExecution.id,
            title: seededExecution.title,
            appID: seededExecution.appID,
            buildID: seededExecution.buildID,
            branchName: seededExecution.branchName,
            targetPath: seededExecution.targetPath,
            primaryExecutable: seededExecution.primaryExecutable,
            depotIDs: seededExecution.depotIDs,
            depotMountPaths: seededExecution.depotMountPaths,
            completedDepotIDs: seededExecution.completedDepotIDs,
            stage: seededExecution.stage,
            detail: seededExecution.detail,
            reservedDiskGB: seededExecution.reservedDiskGB,
            accountSessionReference: seededExecution.accountSessionReference,
            depotProgressBytes: seededExecution.depotProgressBytes,
            depotVerifiedIDs: seededExecution.depotVerifiedIDs,
            resumeCheckpoint: seededExecution.resumeCheckpoint,
            managedArtifactIdentifier: seededExecution.managedArtifactIdentifier,
            executableFingerprint: seededExecution.executableFingerprint,
            runtimeBundleIdentifier: runtimeBundle.id,
            runtimeBundleVersion: runtimeBundle.version,
            lastUpdatedAt: seededExecution.lastUpdatedAt
        )

        while execution.stage != .completed {
            execution = await steamInstallCoordinator.advance(execution: execution, manifest: manifest)
        }

        let pipeline = InstallPipelineBuilder().build(
            for: entry,
            plan: plan,
            manifest: manifest,
            task: nil,
            execution: execution
        )
        let summary = AcceptanceInstallSummary(
            title: execution.title,
            appID: execution.appID,
            buildID: execution.buildID,
            branchName: execution.branchName,
            targetPath: execution.targetPath,
            primaryExecutable: execution.primaryExecutable,
            stage: execution.stage.rawValue,
            completedDepotIDs: execution.completedDepotIDs,
            depotProgressBytes: execution.depotProgressBytes,
            depotVerifiedIDs: execution.depotVerifiedIDs,
            resumeCheckpoint: execution.resumeCheckpoint
        )
        return (pipeline, summary)
    }

    private func derivedSteamAppID(from title: String) -> String {
        let digits = abs(title.hashValue % 1_000_000)
        return String(format: "9%06d", digits)
    }
}

private func configurationManagedRootPath() -> String {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appending(path: "Library/Application Support/Iridium", directoryHint: .isDirectory)
        .path
}
