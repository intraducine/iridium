import Foundation
import IridiumCore

private enum GenericTitleClass: String, Sendable {
    case lightweight
    case balanced
    case heavy
}

private func normalizedTitle(_ value: String) -> String {
    value.lowercased().filter { $0.isLetter || $0.isNumber }
}

private func deviceTierRank(_ tier: DeviceTier) -> Int {
    switch tier {
    case .tier1:
        return 1
    case .tier2:
        return 2
    case .tier3:
        return 3
    }
}

public protocol TitleOverrideResolver: Sendable {
    func overridePolicy(for game: GameRecord) -> RuntimePolicy?
    func evidenceSummary(for game: GameRecord) -> String
}

public protocol RuntimePolicyResolver: Sendable {
    func resolve(
        game: GameRecord,
        hostSnapshot: HostCapabilitySnapshot,
        runtimeBundle: RuntimeBundleManifest?,
        basePolicy: RuntimePolicy,
        overrideResolver: any TitleOverrideResolver
    ) -> RuntimePolicy
}

public struct DefaultTitleOverrideResolver: TitleOverrideResolver {
    public init() {}

    public func overridePolicy(for game: GameRecord) -> RuntimePolicy? {
        _ = game
        return nil
    }

    public func evidenceSummary(for game: GameRecord) -> String {
        let source = game.source == .steam ? "steam-manifest" : "manual-import"
        return
            "Resolved generic broad-catalog policy from \(source) evidence for \(game.title) using fingerprint \(game.executableFingerprint ?? "unknown")."
    }
}

public struct DefaultRuntimePolicyResolver: RuntimePolicyResolver {
    public init() {}

    public func resolve(
        game: GameRecord,
        hostSnapshot: HostCapabilitySnapshot,
        runtimeBundle: RuntimeBundleManifest?,
        basePolicy: RuntimePolicy,
        overrideResolver: any TitleOverrideResolver
    ) -> RuntimePolicy {
        _ = overrideResolver
        var policy = genericPolicy(
            for: game, hostSnapshot: hostSnapshot, runtimeBundle: runtimeBundle,
            fallback: basePolicy)

        policy = applyRuntimeBundleConstraints(policy, runtimeBundle: runtimeBundle)
        policy = applyHostSafetyConstraints(
            policy, game: game, hostSnapshot: hostSnapshot, runtimeBundle: runtimeBundle)
        policy = applyInventoryEvidence(policy, game: game)
        return policy
    }

    private func genericPolicy(
        for game: GameRecord,
        hostSnapshot: HostCapabilitySnapshot,
        runtimeBundle: RuntimeBundleManifest?,
        fallback: RuntimePolicy
    ) -> RuntimePolicy {
        let titleClass = classifyGenericTitle(
            for: game, hostSnapshot: hostSnapshot, runtimeBundle: runtimeBundle)

        let policy: RuntimePolicy
        switch titleClass {
        case .lightweight:
            policy = RuntimePolicy(
                memoryBudgetClass: .compact,
                rendererOverride: hostSnapshot.deviceTier == .tier1
                    ? .metalOpenGLFallback : .dxvkBalanced,
                resolutionScale: hostSnapshot.deviceTier == .tier1 ? 0.9 : 1.0,
                framePacingCap: 60,
                shaderStrategy: .onDemand,
                environmentOverrides: [
                    "IRIDIUM_TITLE_OVERRIDE": "broad-catalog-default",
                    "IRIDIUM_POLICY_SOURCE": "generic-broad-catalog",
                    "IRIDIUM_SOURCE_CLASS": game.source.rawValue,
                    "IRIDIUM_TITLE_CLASS": "\(titleClass.rawValue)-unknown",
                ]
            )
        case .balanced:
            policy = RuntimePolicy(
                memoryBudgetClass: .balanced,
                rendererOverride: hostSnapshot.deviceTier == .tier1
                    ? .metalOpenGLFallback : .dxvkBalanced,
                resolutionScale: hostSnapshot.deviceTier == .tier1 ? 0.8 : 0.9,
                framePacingCap: hostSnapshot.deviceTier == .tier3 ? 60 : 45,
                shaderStrategy: .selectivePrewarm,
                environmentOverrides: [
                    "IRIDIUM_TITLE_OVERRIDE": "broad-catalog-default",
                    "IRIDIUM_POLICY_SOURCE": "generic-broad-catalog",
                    "IRIDIUM_SOURCE_CLASS": game.source.rawValue,
                    "IRIDIUM_TITLE_CLASS": "\(titleClass.rawValue)-unknown",
                ]
            )
        case .heavy:
            policy = RuntimePolicy(
                memoryBudgetClass: .expansive,
                rendererOverride: .vkd3dHighCompatibility,
                resolutionScale: hostSnapshot.deviceTier == .tier3 ? 0.8 : 0.7,
                framePacingCap: hostSnapshot.deviceTier == .tier3 ? 60 : 45,
                shaderStrategy: .selectivePrewarm,
                environmentOverrides: [
                    "IRIDIUM_TITLE_OVERRIDE": "broad-catalog-default",
                    "IRIDIUM_POLICY_SOURCE": "generic-broad-catalog",
                    "IRIDIUM_SOURCE_CLASS": game.source.rawValue,
                    "IRIDIUM_TITLE_CLASS": "\(titleClass.rawValue)-unknown",
                ],
                requiresExplicitWhitelist: game.deviceTier == .tier3 && titleClass == .heavy
            )
        }

        var resolvedPolicy = policy
        if fallback.rendererOverride != nil, resolvedPolicy.rendererOverride == nil {
            resolvedPolicy.rendererOverride = fallback.rendererOverride
        }
        if fallback.framePacingCap != nil, resolvedPolicy.framePacingCap == nil {
            resolvedPolicy.framePacingCap = fallback.framePacingCap
        }
        if fallback.environmentOverrides.isEmpty == false {
            resolvedPolicy.environmentOverrides.merge(fallback.environmentOverrides) { current, _ in
                current
            }
        }
        return resolvedPolicy
    }

    private func classifyGenericTitle(
        for game: GameRecord,
        hostSnapshot: HostCapabilitySnapshot,
        runtimeBundle: RuntimeBundleManifest?
    ) -> GenericTitleClass {
        let installSize = game.installedSizeGB ?? 0
        let bundleTier = runtimeBundle?.minimumDeviceTier ?? .tier1
        let graphicsStack = runtimeBundle?.descriptor.graphicsStack

        if installSize >= 50
            || game.deviceTier == .tier3
            || bundleTier == .tier3
            || game.rendererPreset == .vkd3dHighCompatibility
            || (installSize >= 30 && game.source == .steam && hostSnapshot.deviceTier != .tier1)
        {
            return .heavy
        }

        if installSize > 0 && installSize <= 5
            && game.source == .manualImport
            && game.rendererPreset != .vkd3dHighCompatibility
            && graphicsStack != .vkd3dViaMoltenVK
        {
            return .lightweight
        }

        if installSize > 0 && installSize <= 8
            && game.source == .manualImport
            && hostSnapshot.deviceTier != .tier3
        {
            return .lightweight
        }

        return .balanced
    }

    private func applyRuntimeBundleConstraints(
        _ policy: RuntimePolicy,
        runtimeBundle: RuntimeBundleManifest?
    ) -> RuntimePolicy {
        guard let runtimeBundle else {
            return policy
        }

        var constrained = policy
        switch runtimeBundle.descriptor.graphicsStack {
        case .metalOpenGLFallback:
            constrained.rendererOverride = .metalOpenGLFallback
            constrained.shaderStrategy = .onDemand
            constrained.framePacingCap = min(constrained.framePacingCap ?? 60, 60)
        case .dxvkViaMoltenVK:
            if constrained.rendererOverride == .vkd3dHighCompatibility {
                constrained.rendererOverride = .dxvkBalanced
            }
        case .vkd3dViaMoltenVK, .dxmtViaMetal:
            break
        }

        if runtimeBundle.minimumDeviceTier == .tier3 {
            constrained.environmentOverrides["IRIDIUM_HEAVY_PROFILE"] = "1"
        }

        return constrained
    }

    private func applyHostSafetyConstraints(
        _ policy: RuntimePolicy,
        game: GameRecord,
        hostSnapshot: HostCapabilitySnapshot,
        runtimeBundle: RuntimeBundleManifest?
    ) -> RuntimePolicy {
        var constrained = policy

        if hostSnapshot.deviceTier == .tier1 {
            constrained.memoryBudgetClass =
                constrained.memoryBudgetClass == .compact ? .compact : .balanced
            constrained.resolutionScale = min(constrained.resolutionScale, 0.8)
            constrained.framePacingCap = min(constrained.framePacingCap ?? 60, 45)
            constrained.shaderStrategy = .onDemand
            if constrained.rendererOverride == .vkd3dHighCompatibility {
                constrained.rendererOverride =
                    runtimeBundle?.descriptor.graphicsStack == .metalOpenGLFallback
                    ? .metalOpenGLFallback
                    : .dxvkBalanced
            }
        } else if hostSnapshot.deviceTier == .tier2, constrained.memoryBudgetClass == .expansive {
            constrained.resolutionScale = min(constrained.resolutionScale, 0.75)
            constrained.framePacingCap = min(constrained.framePacingCap ?? 60, 60)
        }

        if hostSnapshot.lowPowerModeEnabled {
            constrained.resolutionScale = min(constrained.resolutionScale, 0.85)
            constrained.framePacingCap = min(constrained.framePacingCap ?? 60, 45)
            constrained.shaderStrategy = .onDemand
            constrained.environmentOverrides["IRIDIUM_POWER_CONSTRAINT"] = "low-power"
        }

        if hostSnapshot.thermalState == .serious {
            constrained.framePacingCap = min(constrained.framePacingCap ?? 60, 45)
            constrained.environmentOverrides["IRIDIUM_THERMAL_CONSTRAINT"] = "serious"
        }

        if deviceTierRank(game.deviceTier) > deviceTierRank(hostSnapshot.deviceTier) {
            constrained.environmentOverrides["IRIDIUM_HOST_TIER_GATED"] =
                hostSnapshot.deviceTier.rawValue
        }

        return constrained
    }

    private func applyInventoryEvidence(
        _ policy: RuntimePolicy,
        game: GameRecord
    ) -> RuntimePolicy {
        var enriched = policy
        enriched.environmentOverrides["IRIDIUM_POLICY_PRECEDENCE"] = "generic-broad-catalog"

        if game.managedArtifactIdentifier == nil {
            enriched.environmentOverrides["IRIDIUM_ARTIFACT_CONFIDENCE"] = "degraded"
        }

        return enriched
    }
}

public struct WhitelistEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var titleMatch: String
    public var allowedDeviceTiers: [DeviceTier]
    public var minimumRuntimeBundleVersion: String?

    public init(
        id: String, titleMatch: String, allowedDeviceTiers: [DeviceTier],
        minimumRuntimeBundleVersion: String? = nil
    ) {
        self.id = id
        self.titleMatch = titleMatch
        self.allowedDeviceTiers = allowedDeviceTiers
        self.minimumRuntimeBundleVersion = minimumRuntimeBundleVersion
    }
}

public protocol WhitelistPolicy: Sendable {
    func evaluate(
        game: GameRecord,
        runtimeBundle: RuntimeBundleManifest?,
        hostSnapshot: HostCapabilitySnapshot,
        runtimePolicy: RuntimePolicy
    ) -> Result<WhitelistEntry?, RuntimeFailure>
}

public struct DefaultWhitelistPolicy: WhitelistPolicy {
    public let entries: [WhitelistEntry]

    public init(
        entries: [WhitelistEntry] = [
            WhitelistEntry(
                id: "heavy-whitelist",
                titleMatch: "heavy",
                allowedDeviceTiers: [.tier3],
                minimumRuntimeBundleVersion: FileSystemRuntimeBundleRegistry.defaultManifest.version
            )
        ]
    ) {
        self.entries = entries
    }

    public func evaluate(
        game: GameRecord,
        runtimeBundle: RuntimeBundleManifest?,
        hostSnapshot: HostCapabilitySnapshot,
        runtimePolicy: RuntimePolicy
    ) -> Result<WhitelistEntry?, RuntimeFailure> {
        guard runtimePolicy.requiresExplicitWhitelist else {
            return .success(nil)
        }

        guard let entry = entries.first(where: { entryMatches($0, gameTitle: game.title) }) else {
            return .failure(
                RuntimeFailure(
                    code: .whitelistBlocked,
                    reason: "This title requires an explicit whitelist entry before launch.",
                    recoverySuggestion: "Add the title to the Tier 3 whitelist."
                )
            )
        }

        guard entry.allowedDeviceTiers.contains(hostSnapshot.deviceTier) else {
            return .failure(
                RuntimeFailure(
                    code: .whitelistBlocked,
                    reason: "The current host tier is not in the whitelist for this title.",
                    recoverySuggestion: "Use a Tier 3 device or lower the title profile."
                )
            )
        }

        if let requiredVersion = entry.minimumRuntimeBundleVersion,
            let version = runtimeBundle?.version,
            version.compare(requiredVersion, options: .numeric) == .orderedAscending
        {
            return .failure(
                RuntimeFailure(
                    code: .whitelistBlocked,
                    reason:
                        "The active runtime bundle version is below the required whitelist baseline.",
                    recoverySuggestion: "Update the runtime bundle before launching."
                )
            )
        }

        return .success(entry)
    }

    private func entryMatches(_ entry: WhitelistEntry, gameTitle: String) -> Bool {
        let normalizedEntry = normalizedTitle(entry.titleMatch)
        let normalizedGame = normalizedTitle(gameTitle)
        guard !normalizedEntry.isEmpty else {
            return false
        }
        return normalizedGame.contains(normalizedEntry)
    }
}

public struct ValidationHarnessRequest: Sendable {
    public var title: String
    public var source: GameSource
    public var installPath: String
    public var executablePath: String
    public var runtimeBundle: RuntimeBundleManifest
    public var runtimePolicy: RuntimePolicy

    public init(
        title: String,
        source: GameSource,
        installPath: String,
        executablePath: String,
        runtimeBundle: RuntimeBundleManifest,
        runtimePolicy: RuntimePolicy
    ) {
        self.title = title
        self.source = source
        self.installPath = installPath
        self.executablePath = executablePath
        self.runtimeBundle = runtimeBundle
        self.runtimePolicy = runtimePolicy
    }
}

public struct ValidationHarnessExecutionRequest: Sendable {
    public var runtimeRequest: RuntimeSessionRequest

    public init(runtimeRequest: RuntimeSessionRequest) {
        self.runtimeRequest = runtimeRequest
    }
}

public struct ValidationHarnessReport: Codable, Hashable, Sendable {
    public var title: String
    public var accepted: Bool
    public var runtimeBundleVersion: String
    public var hostSessionID: String?
    public var terminalStatus: String?
    public var failureCode: String?
    public var failureReason: String?
    public var launchTicketPath: String?
    public var sessionLogPath: String?
    public var telemetryPath: String?
    public var prefixManifestPath: String?
    public var stateHistory: [String]
    public var telemetrySummary: String?
    public var mitigationAction: String?
    public var evidence: CompatibilityEvidenceRecord?
    public var evidenceSummary: String
    public var generatedAt: Date

    public init(
        title: String,
        accepted: Bool,
        runtimeBundleVersion: String,
        hostSessionID: String? = nil,
        terminalStatus: String? = nil,
        failureCode: String? = nil,
        failureReason: String? = nil,
        launchTicketPath: String? = nil,
        sessionLogPath: String? = nil,
        telemetryPath: String? = nil,
        prefixManifestPath: String? = nil,
        stateHistory: [String] = [],
        telemetrySummary: String? = nil,
        mitigationAction: String? = nil,
        evidence: CompatibilityEvidenceRecord? = nil,
        evidenceSummary: String,
        generatedAt: Date = Date()
    ) {
        self.title = title
        self.accepted = accepted
        self.runtimeBundleVersion = runtimeBundleVersion
        self.hostSessionID = hostSessionID
        self.terminalStatus = terminalStatus
        self.failureCode = failureCode
        self.failureReason = failureReason
        self.launchTicketPath = launchTicketPath
        self.sessionLogPath = sessionLogPath
        self.telemetryPath = telemetryPath
        self.prefixManifestPath = prefixManifestPath
        self.stateHistory = stateHistory
        self.telemetrySummary = telemetrySummary
        self.mitigationAction = mitigationAction
        self.evidence = evidence
        self.evidenceSummary = evidenceSummary
        self.generatedAt = generatedAt
    }
}

public struct ValidationHarness: Sendable {
    public init() {}

    public func run(_ request: ValidationHarnessRequest) -> ValidationHarnessReport {
        let summary =
            "Validated \(request.title) from \(request.source.displayName) with runtime bundle \(request.runtimeBundle.version) and policy \(request.runtimePolicy.memoryBudgetClass.rawValue)."
        let accepted = FileManager.default.fileExists(atPath: request.executablePath)
        let evidence = CompatibilityEvidenceRecord(
            title: request.title,
            source: request.source,
            managedArtifactIdentifier: nil,
            executableFingerprint: nil,
            runtimeBundleIdentifier: request.runtimeBundle.id,
            runtimeBundleVersion: request.runtimeBundle.version,
            resolvedPolicySummary: [
                request.runtimePolicy.memoryBudgetClass.rawValue,
                request.runtimePolicy.rendererOverride?.rawValue ?? "default-renderer",
                "scale=\(String(format: "%.2f", request.runtimePolicy.resolutionScale))",
            ].joined(separator: ", "),
            accepted: accepted,
            evidenceSummary: summary
        )
        return ValidationHarnessReport(
            title: request.title,
            accepted: accepted,
            runtimeBundleVersion: request.runtimeBundle.version,
            terminalStatus: accepted
                ? RuntimeHostSessionState.completed.rawValue
                : RuntimeHostSessionState.failed.rawValue,
            evidence: evidence,
            evidenceSummary: summary
        )
    }

    public func runExecution(
        _ request: ValidationHarnessExecutionRequest,
        executor: any RuntimeSessionExecutor = FileSystemRuntimeSessionExecutor()
    ) async -> ValidationHarnessReport {
        let game = request.runtimeRequest.game
        let runtimeBundle = request.runtimeRequest.runtimeBundle
        let policySummary = [
            request.runtimeRequest.policy.memoryBudgetClass.rawValue,
            request.runtimeRequest.policy.rendererOverride?.rawValue ?? "default-renderer",
            "scale=\(String(format: "%.2f", request.runtimeRequest.policy.resolutionScale))",
        ].joined(separator: ", ")

        let execution = await executor.execute(request.runtimeRequest)
        switch execution {
        case .success(let result):
            let summary =
                "Executed \(game.title) through the runtime validation harness with host session \(result.sessionIdentifier)."
            let evidence = CompatibilityEvidenceRecord(
                title: game.title,
                source: game.source,
                managedArtifactIdentifier: game.managedArtifactIdentifier,
                executableFingerprint: game.executableFingerprint,
                runtimeBundleIdentifier: result.runtimeBundleID,
                runtimeBundleVersion: result.runtimeBundleVersion,
                resolvedPolicySummary: policySummary,
                accepted: true,
                hostSessionID: result.sessionIdentifier,
                terminalStatus: result.terminalStatus,
                telemetrySummary: result.telemetrySnapshot.map {
                    "fps=\(Int($0.averageFPS.rounded())) p95=\(Int($0.frameTimeP95MS.rounded()))ms"
                } ?? "Telemetry unavailable from runtime backend.",
                mitigationAction: result.mitigationAction.rawValue,
                evidenceSummary: summary
            )
            return ValidationHarnessReport(
                title: game.title,
                accepted: true,
                runtimeBundleVersion: result.runtimeBundleVersion,
                hostSessionID: result.sessionIdentifier,
                terminalStatus: result.terminalStatus,
                launchTicketPath: result.launchTicketPath,
                sessionLogPath: result.sessionLogPath,
                telemetryPath: result.telemetryPath,
                prefixManifestPath: result.prefixManifestPath,
                stateHistory: result.stateHistory,
                telemetrySummary: evidence.telemetrySummary,
                mitigationAction: result.mitigationAction.rawValue,
                evidence: evidence,
                evidenceSummary: summary
            )
        case .failure(let failure):
            let summary = "Execution failed for \(game.title) with \(failure.code.rawValue)."
            let evidence = CompatibilityEvidenceRecord(
                title: game.title,
                source: game.source,
                managedArtifactIdentifier: game.managedArtifactIdentifier,
                executableFingerprint: game.executableFingerprint,
                runtimeBundleIdentifier: failure.runtimeBundleID ?? runtimeBundle?.id,
                runtimeBundleVersion: failure.runtimeBundleVersion ?? runtimeBundle?.version,
                resolvedPolicySummary: policySummary,
                accepted: false,
                hostSessionID: failure.hostSessionIdentifier,
                terminalStatus: failure.terminalStatus ?? RuntimeHostSessionState.failed.rawValue,
                failureCode: failure.code.rawValue,
                failureReason: failure.reason,
                evidenceSummary: summary
            )
            return ValidationHarnessReport(
                title: game.title,
                accepted: false,
                runtimeBundleVersion: failure.runtimeBundleVersion ?? runtimeBundle?.version
                    ?? "unknown",
                hostSessionID: failure.hostSessionIdentifier,
                terminalStatus: failure.terminalStatus ?? RuntimeHostSessionState.failed.rawValue,
                failureCode: failure.code.rawValue,
                failureReason: failure.reason,
                stateHistory: failure.stateHistory,
                evidence: evidence,
                evidenceSummary: summary
            )
        }
    }
}
