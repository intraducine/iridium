import Foundation
import IridiumCore

public enum RuntimeFailureCode: String, Codable, CaseIterable, Sendable {
    case missingRuntimeBundle
    case invalidRuntimeBundle
    case missingExecutable
    case managedArtifactMismatch
    case executableFingerprintMismatch
    case desktopShellEntrypointBlocked
    case missingPrefix
    case prefixBootstrapFailed
    case jitNotReady
    case thermalBlocked
    case lowPowerBlocked
    case unsupportedDeviceTier
    case whitelistBlocked
    case runtimeBootFailed
    case rendererInitializationFailed
    case gameProcessExited
}

public struct RuntimeFailure: Error, Codable, Hashable, Sendable {
    public var code: RuntimeFailureCode
    public var reason: String
    public var recoverySuggestion: String?
    public var hostSessionIdentifier: String?
    public var terminalStatus: String?
    public var runtimeBundleID: String?
    public var runtimeBundleVersion: String?
    public var stateHistory: [String]
    public var launchedAt: Date?

    public init(
        code: RuntimeFailureCode,
        reason: String,
        recoverySuggestion: String? = nil,
        hostSessionIdentifier: String? = nil,
        terminalStatus: String? = nil,
        runtimeBundleID: String? = nil,
        runtimeBundleVersion: String? = nil,
        stateHistory: [String] = [],
        launchedAt: Date? = nil
    ) {
        self.code = code
        self.reason = reason
        self.recoverySuggestion = recoverySuggestion
        self.hostSessionIdentifier = hostSessionIdentifier
        self.terminalStatus = terminalStatus
        self.runtimeBundleID = runtimeBundleID
        self.runtimeBundleVersion = runtimeBundleVersion
        self.stateHistory = stateHistory
        self.launchedAt = launchedAt
    }
}

public struct RuntimeSessionRequest: Sendable {
    public var game: GameRecord
    public var prefix: PrefixRecord?
    public var session: LaunchSession
    public var hostSnapshot: HostCapabilitySnapshot
    public var runtimeBundle: RuntimeBundleManifest?
    public var policy: RuntimePolicy
    public var preferredSessionIdentifier: String?

    public init(
        game: GameRecord,
        prefix: PrefixRecord?,
        session: LaunchSession,
        hostSnapshot: HostCapabilitySnapshot,
        runtimeBundle: RuntimeBundleManifest?,
        policy: RuntimePolicy,
        preferredSessionIdentifier: String? = nil
    ) {
        self.game = game
        self.prefix = prefix
        self.session = session
        self.hostSnapshot = hostSnapshot
        self.runtimeBundle = runtimeBundle
        self.policy = policy
        self.preferredSessionIdentifier = preferredSessionIdentifier
    }
}

public struct RuntimeSessionResult: Codable, Hashable, Sendable {
    public var sessionIdentifier: String
    public var launchedAt: Date
    public var terminalStatus: String
    public var launchTicketPath: String
    public var sessionLogPath: String
    public var telemetryPath: String
    public var prefixManifestPath: String
    public var runtimeBundleID: String
    public var runtimeBundleVersion: String
    public var resolvedExecutablePath: String
    public var stateHistory: [String]
    public var environment: [String: String]
    public var telemetrySnapshot: PerformanceTelemetrySnapshot?
    public var mitigationAction: ThermalMitigationAction

    public init(
        sessionIdentifier: String,
        launchedAt: Date = Date(),
        terminalStatus: String,
        launchTicketPath: String,
        sessionLogPath: String,
        telemetryPath: String,
        prefixManifestPath: String,
        runtimeBundleID: String,
        runtimeBundleVersion: String,
        resolvedExecutablePath: String,
        stateHistory: [String],
        environment: [String: String],
        telemetrySnapshot: PerformanceTelemetrySnapshot?,
        mitigationAction: ThermalMitigationAction
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.launchedAt = launchedAt
        self.terminalStatus = terminalStatus
        self.launchTicketPath = launchTicketPath
        self.sessionLogPath = sessionLogPath
        self.telemetryPath = telemetryPath
        self.prefixManifestPath = prefixManifestPath
        self.runtimeBundleID = runtimeBundleID
        self.runtimeBundleVersion = runtimeBundleVersion
        self.resolvedExecutablePath = resolvedExecutablePath
        self.stateHistory = stateHistory
        self.environment = environment
        self.telemetrySnapshot = telemetrySnapshot
        self.mitigationAction = mitigationAction
    }
}

public protocol RuntimeSessionExecutor: Sendable {
    func execute(_ request: RuntimeSessionRequest) async -> Result<RuntimeSessionResult, RuntimeFailure>
}

public struct FileSystemRuntimeSessionExecutor: RuntimeSessionExecutor {
    private let artifactInventory: any GameArtifactInventory
    private let prefixBootstrapService: any PrefixBootstrapService
    private let hostController: any RuntimeHostController
    private let executionMonitor: any RuntimeExecutionMonitor
    private let telemetryCollector: any RuntimeTelemetryCollector
    private let mitigationCoordinator: RuntimeMitigationCoordinator
    private let whitelistPolicy: any WhitelistPolicy

    public init(
        artifactInventory: any GameArtifactInventory = FileSystemGameArtifactInventory(),
        prefixBootstrapService: any PrefixBootstrapService = FileSystemPrefixBootstrapService(),
        hostController: any RuntimeHostController = FileSystemRuntimeHostController(),
        executionMonitor: any RuntimeExecutionMonitor = FileSystemRuntimeExecutionMonitor(),
        telemetryCollector: any RuntimeTelemetryCollector = FileSystemRuntimeTelemetryCollector(),
        mitigationCoordinator: RuntimeMitigationCoordinator = RuntimeMitigationCoordinator(),
        whitelistPolicy: any WhitelistPolicy = DefaultWhitelistPolicy()
    ) {
        self.artifactInventory = artifactInventory
        self.prefixBootstrapService = prefixBootstrapService
        self.hostController = hostController
        self.executionMonitor = executionMonitor
        self.telemetryCollector = telemetryCollector
        self.mitigationCoordinator = mitigationCoordinator
        self.whitelistPolicy = whitelistPolicy
    }

    public func execute(_ request: RuntimeSessionRequest) async -> Result<RuntimeSessionResult, RuntimeFailure> {
        print(
            "[IridiumRuntime] runtimeSessionExecutor: begin game=\(request.game.title) executable=\(request.session.executablePath) preferredSession=\(request.preferredSessionIdentifier ?? "none")"
        )
        guard let runtimeBundle = request.runtimeBundle else {
            print("[IridiumRuntime] runtimeSessionExecutor: blocked stage=runtimeBundle reason=missing")
            return .failure(
                RuntimeFailure(
                    code: .missingRuntimeBundle,
                    reason: "No runtime bundle is registered for direct launch.",
                    recoverySuggestion: "Validate or provision the runtime bundle before launching."
                )
            )
        }

        guard runtimeBundle.supportsDirectGameLaunch, !runtimeBundle.descriptor.exposesDesktopShell else {
            print(
                "[IridiumRuntime] runtimeSessionExecutor: blocked stage=runtimeBundle reason=notDirectLaunchCapable bundle=\(runtimeBundle.id)"
            )
            return .failure(
                RuntimeFailure(
                    code: .invalidRuntimeBundle,
                    reason: "The selected runtime bundle cannot be used for shell-free direct launch.",
                    recoverySuggestion: "Select a direct-launch capable runtime bundle."
                )
            )
        }

        let bundleValidation = validateRuntimeBundleInventory(runtimeBundle, hostSnapshot: request.hostSnapshot)
        guard bundleValidation.failures.isEmpty else {
            print(
                "[IridiumRuntime] runtimeSessionExecutor: blocked stage=bundleValidation failures=\(bundleValidation.failures.joined(separator: " | "))"
            )
            return .failure(
                RuntimeFailure(
                    code: .invalidRuntimeBundle,
                    reason: bundleValidation.failures.joined(separator: " "),
                    recoverySuggestion: "Repair the managed runtime bundle inventory before launching."
                )
            )
        }

        guard FileManager.default.fileExists(atPath: request.session.executablePath) else {
            print("[IridiumRuntime] runtimeSessionExecutor: blocked stage=executable reason=missing path=\(request.session.executablePath)")
            return .failure(
                RuntimeFailure(
                    code: .missingExecutable,
                    reason: "The selected game executable is missing from managed storage.",
                    recoverySuggestion: "Re-import or reinstall the title."
                )
            )
        }

        guard !isDesktopShellEntrypoint(request.session.executablePath) else {
            print("[IridiumRuntime] runtimeSessionExecutor: blocked stage=executable reason=desktopShellEntrypoint path=\(request.session.executablePath)")
            return .failure(
                RuntimeFailure(
                    code: .desktopShellEntrypointBlocked,
                    reason: "Desktop shell entrypoints are blocked; Iridium may only launch a resolved game executable.",
                    recoverySuggestion: "Select the game binary instead of explorer, cmd, or a launcher shell stub."
                )
            )
        }

        switch validateManagedExecutable(for: request) {
        case .success:
            print("[IridiumRuntime] runtimeSessionExecutor: executableValidated")
            break
        case let .failure(failure):
            print(
                "[IridiumRuntime] runtimeSessionExecutor: blocked stage=executableValidation code=\(failure.code.rawValue) reason=\(failure.reason)"
            )
            return .failure(failure)
        }

        guard let prefix = request.prefix, request.game.launchProfile.prefixID == prefix.id else {
            print("[IridiumRuntime] runtimeSessionExecutor: blocked stage=prefix reason=missingOrMismatched")
            return .failure(
                RuntimeFailure(
                    code: .missingPrefix,
                    reason: "No isolated prefix is bound to this title.",
                    recoverySuggestion: "Re-register the title so a prefix can be created."
                )
            )
        }

        switch request.hostSnapshot.jitStatus {
        case .ready:
            print("[IridiumRuntime] runtimeSessionExecutor: jitReady")
            break
        case .required, .unavailable:
            print("[IridiumRuntime] runtimeSessionExecutor: blocked stage=jit status=\(request.hostSnapshot.jitStatus.rawValue)")
            return .failure(
                RuntimeFailure(
                    code: .jitNotReady,
                    reason: "Host JIT capability is not ready.",
                    recoverySuggestion: "Complete host JIT setup before launching Windows code."
                )
            )
        }

        if request.hostSnapshot.launchReady == false {
            print(
                "[IridiumRuntime] runtimeSessionExecutor: blocked stage=launchReadiness summary=\(request.hostSnapshot.launchStatusSummary ?? "none")"
            )
            return .failure(
                RuntimeFailure(
                    code: .jitNotReady,
                    reason: request.hostSnapshot.launchStatusSummary
                        ?? "Embedded runtime launch support is unavailable on this host.",
                    recoverySuggestion:
                        "Complete embedded runtime validation before launching Windows code."
                )
            )
        }

        if request.hostSnapshot.usesLightweightDebuggerCheck {
            print(
                "[IridiumRuntime] runtimeSessionExecutor: blocked stage=debuggerCheck summary=\(request.hostSnapshot.lightweightDebuggerCheckSummary)"
            )
            return .failure(
                RuntimeFailure(
                    code: .jitNotReady,
                    reason: request.hostSnapshot.lightweightDebuggerCheckSummary,
                    recoverySuggestion:
                        "Validate the embedded runtime backend outside the lightweight Xcode check path before launching Windows code."
                )
            )
        }

        var effectivePolicy = request.policy
        effectivePolicy.environmentOverrides = effectivePolicy.environmentOverrides.merging(
            ["IRIDIUM_HOST_JIT_STATUS": request.hostSnapshot.jitStatus.rawValue]
        ) { _, new in new }

        if request.hostSnapshot.lowPowerModeEnabled && request.policy.requiresExplicitWhitelist {
            print("[IridiumRuntime] runtimeSessionExecutor: blocked stage=power reason=lowPowerMode")
            return .failure(
                RuntimeFailure(
                    code: .lowPowerBlocked,
                    reason: "Heavy-title policy blocks launch while low power mode is enabled.",
                    recoverySuggestion: "Disable low power mode or choose a lower-tier title."
                )
            )
        }

        switch whitelistPolicy.evaluate(
            game: request.game,
            runtimeBundle: runtimeBundle,
            hostSnapshot: request.hostSnapshot,
            runtimePolicy: request.policy
        ) {
        case .success:
            print("[IridiumRuntime] runtimeSessionExecutor: whitelistAccepted")
            break
        case let .failure(failure):
            print(
                "[IridiumRuntime] runtimeSessionExecutor: blocked stage=whitelist code=\(failure.code.rawValue) reason=\(failure.reason)"
            )
            return .failure(failure)
        }

        if request.hostSnapshot.thermalState == .critical {
            print("[IridiumRuntime] runtimeSessionExecutor: blocked stage=thermal reason=critical")
            return .failure(
                RuntimeFailure(
                    code: .thermalBlocked,
                    reason: "Thermal state is critical and launch is blocked.",
                    recoverySuggestion: "Allow the device to cool before retrying."
                )
            )
        }

        if tierRank(request.game.deviceTier) > tierRank(request.hostSnapshot.deviceTier) {
            print(
                "[IridiumRuntime] runtimeSessionExecutor: blocked stage=deviceTier game=\(request.game.deviceTier.rawValue) host=\(request.hostSnapshot.deviceTier.rawValue)"
            )
            return .failure(
                RuntimeFailure(
                    code: .unsupportedDeviceTier,
                    reason: "The selected title requires a higher capability tier than the current host snapshot provides.",
                    recoverySuggestion: "Use a compatible title profile or higher-tier device."
                )
            )
        }

        print("[IridiumRuntime] runtimeSessionExecutor: prefixBootstrapStarting prefix=\(prefix.id.uuidString)")
        let bootstrap = await prefixBootstrapService.bootstrap(
            game: request.game,
            prefix: prefix,
            runtimeBundle: runtimeBundle,
            policy: effectivePolicy
        )

        let bootstrapResult: PrefixBootstrapResult
        switch bootstrap {
        case let .success(result):
            bootstrapResult = result
            print("[IridiumRuntime] runtimeSessionExecutor: prefixBootstrapSucceeded manifest=\(result.manifestPath)")
        case let .failure(failure):
            print(
                "[IridiumRuntime] runtimeSessionExecutor: prefixBootstrapFailed code=\(failure.code.rawValue) reason=\(failure.reason)"
            )
            return .failure(failure)
        }

        let resolvedSessionIdentifier = request.preferredSessionIdentifier ?? UUID().uuidString

        let environment = request.session.environment
            .merging(effectivePolicy.environmentOverrides) { _, new in new }
            .merging(
                [
                    "IRIDIUM_RUNTIME_SESSION_ID": resolvedSessionIdentifier,
                    RuntimeEnvironmentKey.runtimeBundleID: runtimeBundle.id,
                    RuntimeEnvironmentKey.runtimeBundleVersion: runtimeBundle.version,
                    RuntimeEnvironmentKey.runtimeGraphicsStack: runtimeBundle.descriptor.graphicsStack.rawValue,
                    RuntimeEnvironmentKey.wineIOSGraphicsDriver: "wineios.drv",
                    RuntimeEnvironmentKey.wineIOSAudioDriver: "winecoreaudio.drv",
                    RuntimeEnvironmentKey.rendererPreset: (effectivePolicy.rendererOverride ?? request.game.rendererPreset).rawValue,
                    RuntimeEnvironmentKey.shaderStrategy: effectivePolicy.shaderStrategy.rawValue,
                    RuntimeEnvironmentKey.memoryBudget: effectivePolicy.memoryBudgetClass.rawValue,
                    RuntimeEnvironmentKey.frameCap: String(effectivePolicy.framePacingCap ?? 60),
                    RuntimeEnvironmentKey.resolutionScale: String(format: "%.2f", effectivePolicy.resolutionScale),
                    RuntimeEnvironmentKey.prefixManifest: bootstrapResult.manifestPath
                ],
                uniquingKeysWith: { _, new in new }
            )

        let ticket = RuntimeLaunchTicket(
            id: resolvedSessionIdentifier,
            gameID: request.game.id,
            gameTitle: request.game.title,
            executablePath: request.session.executablePath,
            workingDirectory: request.session.workingDirectory,
            launchArguments: request.session.arguments,
            environment: environment,
            runtimeBundleID: runtimeBundle.id,
            runtimeBundleVersion: runtimeBundle.version,
            prefixID: prefix.id,
            prefixManifestPath: bootstrapResult.manifestPath
        )

        print(
            "[IridiumRuntime] runtimeSessionExecutor: hostSubmitStarting session=\(ticket.id) bundle=\(runtimeBundle.id)"
        )
        let hostSubmission = await hostController.submit(ticket: ticket)
        let submittedSession: RuntimeHostSession
        switch hostSubmission {
        case let .success(session):
            submittedSession = session
            print(
                "[IridiumRuntime] runtimeSessionExecutor: hostSubmitSucceeded session=\(session.id) state=\(session.state.rawValue)"
            )
        case let .failure(failure):
            print(
                "[IridiumRuntime] runtimeSessionExecutor: hostSubmitFailed code=\(failure.code.rawValue) reason=\(failure.reason)"
            )
            return .failure(failure)
        }

        if request.preferredSessionIdentifier != nil {
            let handoffSession: RuntimeHostSession
            switch submittedSession.state {
            case .failed:
                return .failure(
                    RuntimeFailure(
                        code: submittedSession.failureCode ?? .runtimeBootFailed,
                        reason: submittedSession.failureReason ?? submittedSession.statusSummary,
                        recoverySuggestion: "Inspect the runtime host session log and retry.",
                        hostSessionIdentifier: submittedSession.id,
                        terminalStatus: submittedSession.state.rawValue,
                        runtimeBundleID: submittedSession.runtimeBundleID,
                        runtimeBundleVersion: submittedSession.runtimeBundleVersion,
                        stateHistory: submittedSession.stateHistory.map(\.rawValue),
                        launchedAt: submittedSession.startedAt
                    )
                )
            case .running:
                handoffSession = submittedSession
            case .queued, .bootstrappingPrefix, .bootingRuntime:
                print(
                    "[IridiumRuntime] runtimeSessionExecutor: fullscreenHandoffWaiting session=\(submittedSession.id) state=\(submittedSession.state.rawValue)"
                )
                handoffSession = await waitForPreferredFullscreenHandoff(startingAt: submittedSession)
            case .completed:
                handoffSession = submittedSession
            }

            switch handoffSession.state {
            case .running:
                let payload = RuntimeSessionResult(
                    sessionIdentifier: handoffSession.id,
                    launchedAt: handoffSession.startedAt,
                    terminalStatus: RuntimeHostSessionState.running.rawValue,
                    launchTicketPath: handoffSession.launchTicketPath,
                    sessionLogPath: handoffSession.sessionLogPath,
                    telemetryPath: handoffSession.telemetryPath,
                    prefixManifestPath: bootstrapResult.manifestPath,
                    runtimeBundleID: runtimeBundle.id,
                    runtimeBundleVersion: runtimeBundle.version,
                    resolvedExecutablePath: request.session.executablePath,
                    stateHistory: handoffSession.stateHistory.map(\.rawValue),
                    environment: environment,
                    telemetrySnapshot: nil,
                    mitigationAction: .none
                )
                print(
                    "[IridiumRuntime] runtimeSessionExecutor: fullscreenHandoff session=\(payload.sessionIdentifier) terminalStatus=\(payload.terminalStatus)"
                )
                return .success(payload)
            case .completed:
                let payload = RuntimeSessionResult(
                    sessionIdentifier: handoffSession.id,
                    launchedAt: handoffSession.startedAt,
                    terminalStatus: RuntimeHostSessionState.completed.rawValue,
                    launchTicketPath: handoffSession.launchTicketPath,
                    sessionLogPath: handoffSession.sessionLogPath,
                    telemetryPath: handoffSession.telemetryPath,
                    prefixManifestPath: bootstrapResult.manifestPath,
                    runtimeBundleID: runtimeBundle.id,
                    runtimeBundleVersion: runtimeBundle.version,
                    resolvedExecutablePath: request.session.executablePath,
                    stateHistory: handoffSession.stateHistory.map(\.rawValue),
                    environment: environment,
                    telemetrySnapshot: nil,
                    mitigationAction: .none
                )
                print(
                    "[IridiumRuntime] runtimeSessionExecutor: fullscreenHandoffSkipped session=\(payload.sessionIdentifier) terminalStatus=\(payload.terminalStatus)"
                )
                return .success(payload)
            case .failed:
                return .failure(
                    RuntimeFailure(
                        code: handoffSession.failureCode ?? .runtimeBootFailed,
                        reason: handoffSession.failureReason ?? handoffSession.statusSummary,
                        recoverySuggestion: "Inspect the runtime host session log and retry.",
                        hostSessionIdentifier: handoffSession.id,
                        terminalStatus: handoffSession.state.rawValue,
                        runtimeBundleID: handoffSession.runtimeBundleID,
                        runtimeBundleVersion: handoffSession.runtimeBundleVersion,
                        stateHistory: handoffSession.stateHistory.map(\.rawValue),
                        launchedAt: handoffSession.startedAt
                    )
                )
            case .queued, .bootstrappingPrefix, .bootingRuntime:
                return .failure(
                    RuntimeFailure(
                        code: .runtimeBootFailed,
                        reason:
                            "Runtime backend did not reach shell-free execution before fullscreen handoff.",
                        recoverySuggestion: "Inspect the runtime host session log and retry.",
                        hostSessionIdentifier: handoffSession.id,
                        terminalStatus: handoffSession.state.rawValue,
                        runtimeBundleID: handoffSession.runtimeBundleID,
                        runtimeBundleVersion: handoffSession.runtimeBundleVersion,
                        stateHistory: handoffSession.stateHistory.map(\.rawValue),
                        launchedAt: handoffSession.startedAt
                    )
                )
            }
        }

        print("[IridiumRuntime] runtimeSessionExecutor: terminalStateResolving session=\(submittedSession.id)")
        let terminalSession = await executionMonitor.resolveTerminalState(for: submittedSession)
        print(
            "[IridiumRuntime] runtimeSessionExecutor: terminalStateResolved session=\(terminalSession.id) state=\(terminalSession.state.rawValue) history=\(terminalSession.stateHistory.map(\.rawValue).joined(separator: " -> "))"
        )
        guard terminalSession.state != .failed else {
            return .failure(
                RuntimeFailure(
                    code: terminalSession.failureCode ?? .gameProcessExited,
                    reason: terminalSession.failureReason ?? terminalSession.statusSummary,
                    recoverySuggestion: "Inspect the runtime host session log and retry.",
                    hostSessionIdentifier: terminalSession.id,
                    terminalStatus: terminalSession.state.rawValue,
                    runtimeBundleID: terminalSession.runtimeBundleID,
                    runtimeBundleVersion: terminalSession.runtimeBundleVersion,
                    stateHistory: terminalSession.stateHistory.map(\.rawValue),
                    launchedAt: terminalSession.startedAt
                )
            )
        }

        print("[IridiumRuntime] runtimeSessionExecutor: telemetryCollecting session=\(terminalSession.id)")
        let telemetry = await telemetryCollector.collect(for: terminalSession, policy: request.policy)
        print(
            "[IridiumRuntime] runtimeSessionExecutor: telemetryCollected session=\(terminalSession.id) present=\(telemetry != nil)"
        )
        let mitigation = telemetry.map { mitigationCoordinator.apply(telemetry: $0, to: request.policy) }
            ?? RuntimeMitigationResult(action: .none, adjustedPolicy: request.policy)

        if mitigation.action == .blockLaunch {
            print("[IridiumRuntime] runtimeSessionExecutor: blocked stage=mitigation action=\(mitigation.action.rawValue)")
            return .failure(
                RuntimeFailure(
                    code: .thermalBlocked,
                    reason: "Runtime mitigation blocked relaunch after telemetry collection.",
                    recoverySuggestion: "Reduce thermal or memory pressure and retry."
                )
            )
        }

        let payload = RuntimeSessionResult(
            sessionIdentifier: terminalSession.id,
            terminalStatus: terminalSession.state.rawValue,
            launchTicketPath: terminalSession.launchTicketPath,
            sessionLogPath: terminalSession.sessionLogPath,
            telemetryPath: terminalSession.telemetryPath,
            prefixManifestPath: bootstrapResult.manifestPath,
            runtimeBundleID: runtimeBundle.id,
            runtimeBundleVersion: runtimeBundle.version,
            resolvedExecutablePath: request.session.executablePath,
            stateHistory: terminalSession.stateHistory.map(\.rawValue),
            environment: mitigation.adjustedPolicy.environmentOverrides.isEmpty
                ? environment
                : environment.merging(mitigation.adjustedPolicy.environmentOverrides) { _, new in new },
            telemetrySnapshot: telemetry,
            mitigationAction: mitigation.action
        )

        print(
            "[IridiumRuntime] runtimeSessionExecutor: success session=\(payload.sessionIdentifier) terminalStatus=\(payload.terminalStatus)"
        )
        return .success(payload)
    }

    private func waitForPreferredFullscreenHandoff(
        startingAt session: RuntimeHostSession
    ) async -> RuntimeHostSession {
        var latest = session
        for _ in 0..<60 {
            if latest.state == .running || latest.state == .completed || latest.state == .failed {
                return latest
            }
            latest = await executionMonitor.resolveTerminalState(for: latest)
            if latest.state == .running || latest.state == .completed || latest.state == .failed {
                return latest
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return latest
    }

    private func tierRank(_ tier: DeviceTier) -> Int {
        switch tier {
        case .tier1:
            1
        case .tier2:
            2
        case .tier3:
            3
        }
    }

    private func isDesktopShellEntrypoint(_ path: String) -> Bool {
        let blocked = [
            "explorer.exe",
            "cmd.exe",
            "powershell.exe",
            "start.exe",
            "wscript.exe",
            "cscript.exe"
        ]
        return blocked.contains(URL(fileURLWithPath: path).lastPathComponent.lowercased())
    }

    private func validateManagedExecutable(
        for request: RuntimeSessionRequest
    ) -> Result<Void, RuntimeFailure> {
        do {
            let artifact = try artifactInventory.makeManagedArtifact(
                title: request.game.title,
                executablePath: request.session.executablePath,
                installPath: request.game.installPath
            )

            if let expectedIdentifier = request.game.managedArtifactIdentifier,
               artifact.identifier != expectedIdentifier {
                return .failure(
                    RuntimeFailure(
                        code: .managedArtifactMismatch,
                        reason: "Resolved executable is no longer bound to managed artifact \(expectedIdentifier).",
                        recoverySuggestion: "Re-import the title or refresh its managed artifact inventory."
                    )
                )
            }

            if let expectedFingerprint = request.game.executableFingerprint,
               artifact.checksum.caseInsensitiveCompare(expectedFingerprint) != .orderedSame {
                return .failure(
                    RuntimeFailure(
                        code: .executableFingerprintMismatch,
                        reason: "Resolved executable fingerprint no longer matches the recorded managed artifact.",
                        recoverySuggestion: "Re-scan the executable and refresh the import registration before launching."
                    )
                )
            }

            return .success(())
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .managedArtifactMismatch,
                    reason: "Failed to revalidate the managed executable: \(error.localizedDescription)",
                    recoverySuggestion: "Re-import the title or verify managed storage contents."
                )
            )
        }
    }
}
