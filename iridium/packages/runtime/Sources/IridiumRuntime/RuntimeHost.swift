import Foundation
import IridiumCore
import IridiumRuntimeHostSDK

#if canImport(Darwin)
    import Darwin
#endif

public enum RuntimeHostSessionState: String, Codable, CaseIterable, Sendable {
    case queued
    case bootstrappingPrefix
    case bootingRuntime
    case running
    case completed
    case failed

    public var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

public struct RuntimeLaunchTicket: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var gameID: UUID
    public var gameTitle: String
    public var executablePath: String
    public var workingDirectory: String
    public var launchArguments: [String]
    public var environment: [String: String]
    public var runtimeBundleID: String
    public var runtimeBundleVersion: String
    public var prefixID: UUID
    public var prefixManifestPath: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        gameID: UUID,
        gameTitle: String,
        executablePath: String,
        workingDirectory: String,
        launchArguments: [String],
        environment: [String: String],
        runtimeBundleID: String,
        runtimeBundleVersion: String,
        prefixID: UUID,
        prefixManifestPath: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.launchArguments = launchArguments
        self.environment = environment
        self.runtimeBundleID = runtimeBundleID
        self.runtimeBundleVersion = runtimeBundleVersion
        self.prefixID = prefixID
        self.prefixManifestPath = prefixManifestPath
        self.createdAt = createdAt
    }
}

public struct RuntimeHostSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var gameID: UUID
    public var gameTitle: String
    public var launchTicketPath: String
    public var sessionLogPath: String
    public var telemetryPath: String
    public var runtimeBundleID: String
    public var runtimeBundleVersion: String
    public var state: RuntimeHostSessionState
    public var stateHistory: [RuntimeHostSessionState]
    public var statusSummary: String
    public var failureCode: RuntimeFailureCode?
    public var failureReason: String?
    public var lastTelemetry: PerformanceTelemetrySnapshot?
    public var startedAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        gameID: UUID,
        gameTitle: String,
        launchTicketPath: String,
        sessionLogPath: String,
        telemetryPath: String,
        runtimeBundleID: String,
        runtimeBundleVersion: String,
        state: RuntimeHostSessionState,
        stateHistory: [RuntimeHostSessionState] = [],
        statusSummary: String,
        failureCode: RuntimeFailureCode? = nil,
        failureReason: String? = nil,
        lastTelemetry: PerformanceTelemetrySnapshot? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.launchTicketPath = launchTicketPath
        self.sessionLogPath = sessionLogPath
        self.telemetryPath = telemetryPath
        self.runtimeBundleID = runtimeBundleID
        self.runtimeBundleVersion = runtimeBundleVersion
        self.state = state
        self.stateHistory = stateHistory.isEmpty ? [state] : stateHistory
        self.statusSummary = statusSummary
        self.failureCode = failureCode
        self.failureReason = failureReason
        self.lastTelemetry = lastTelemetry
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public struct PrefixBootstrapManifest: Codable, Hashable, Sendable {
    public var prefixID: UUID
    public var title: String
    public var executableFingerprint: String?
    public var runtimeBundleID: String
    public var runtimeBundleVersion: String
    public var prefixRootPath: String
    public var runtimeBundleRootPath: String?
    public var environmentFilePath: String
    public var runtimeConfigurationPath: String
    public var environmentOverrides: [String: String]
    public var generatedAt: Date

    public init(
        prefixID: UUID,
        title: String,
        executableFingerprint: String?,
        runtimeBundleID: String,
        runtimeBundleVersion: String,
        prefixRootPath: String,
        runtimeBundleRootPath: String?,
        environmentFilePath: String,
        runtimeConfigurationPath: String,
        environmentOverrides: [String: String],
        generatedAt: Date = Date()
    ) {
        self.prefixID = prefixID
        self.title = title
        self.executableFingerprint = executableFingerprint
        self.runtimeBundleID = runtimeBundleID
        self.runtimeBundleVersion = runtimeBundleVersion
        self.prefixRootPath = prefixRootPath
        self.runtimeBundleRootPath = runtimeBundleRootPath
        self.environmentFilePath = environmentFilePath
        self.runtimeConfigurationPath = runtimeConfigurationPath
        self.environmentOverrides = environmentOverrides
        self.generatedAt = generatedAt
    }
}

public struct PrefixBootstrapResult: Codable, Hashable, Sendable {
    public var manifestPath: String
    public var manifestVersion: String
    public var status: String
    public var detail: String

    public init(manifestPath: String, manifestVersion: String, status: String, detail: String) {
        self.manifestPath = manifestPath
        self.manifestVersion = manifestVersion
        self.status = status
        self.detail = detail
    }
}

public protocol PrefixBootstrapService: Sendable {
    func bootstrap(
        game: GameRecord,
        prefix: PrefixRecord,
        runtimeBundle: RuntimeBundleManifest,
        policy: RuntimePolicy
    ) async -> Result<PrefixBootstrapResult, RuntimeFailure>
}

public protocol RuntimeHostController: Sendable {
    func submit(ticket: RuntimeLaunchTicket) async -> Result<RuntimeHostSession, RuntimeFailure>
}

public protocol RuntimeBridgeRequestProcessor: Sendable {
    func processRuntimeRequests() async throws -> Int
}

public protocol RuntimeExecutionMonitor: Sendable {
    func resolveTerminalState(for session: RuntimeHostSession) async -> RuntimeHostSession
}

public protocol RuntimeTelemetryCollector: Sendable {
    func collect(for session: RuntimeHostSession, policy: RuntimePolicy) async
        -> PerformanceTelemetrySnapshot?
}

private let providerRequiredArtifactPaths = [
    (identifier: "runtime-host-binary", relativePath: "Runtime/runtime-host.bin"),
    (identifier: "x64-jit-translator", relativePath: "Translator/x64-jit.bin"),
    (identifier: "wine-userland", relativePath: "Userland/wine-userland.tar.zst"),
    (identifier: "vkd3d-stack", relativePath: "Graphics/vkd3d-stack.json"),
    (identifier: "direct-launch-profile", relativePath: "Metadata/direct-launch.json"),
]

private func isStructurallyValidStagedWineUserland(at rootPath: String) -> Bool {
    guard !rootPath.isEmpty else {
        return false
    }

    let fileManager = FileManager.default
    var rootIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: rootPath, isDirectory: &rootIsDirectory),
        rootIsDirectory.boolValue
    else {
        return false
    }

    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let requiredAlternatives = [
        ["bin/wine64", "bin/wine", "wine64", "wine"],
        ["bin/wineserver", "wineserver"],
        ["lib/wine", "lib64/wine"],
        ["share/wine"],
        ["prefix-seed/system.reg"],
        ["prefix-seed/user.reg"],
        ["prefix-seed/userdef.reg"],
    ]

    return requiredAlternatives.allSatisfy { alternatives in
        alternatives.contains { relativePath in
            fileManager.fileExists(atPath: root.appending(path: relativePath).path)
        }
    }
}

public struct RuntimeBackendLaunchPackage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var gameID: UUID
    public var gameTitle: String
    public var executablePath: String
    public var workingDirectory: String
    public var launchArguments: [String]
    public var environment: [String: String]
    public var runtimeBundleID: String
    public var runtimeBundleVersion: String
    public var runtimeBundleRootPath: String
    public var prefixID: UUID
    public var prefixManifestPath: String
    public var runtimeConfigurationPath: String
    public var environmentFilePath: String
    public var rendererPreset: String
    public var directLaunchOnly: Bool
    public var createdAt: Date

    public init(
        id: String,
        gameID: UUID,
        gameTitle: String,
        executablePath: String,
        workingDirectory: String,
        launchArguments: [String],
        environment: [String: String],
        runtimeBundleID: String,
        runtimeBundleVersion: String,
        runtimeBundleRootPath: String,
        prefixID: UUID,
        prefixManifestPath: String,
        runtimeConfigurationPath: String,
        environmentFilePath: String,
        rendererPreset: String,
        directLaunchOnly: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.launchArguments = launchArguments
        self.environment = environment
        self.runtimeBundleID = runtimeBundleID
        self.runtimeBundleVersion = runtimeBundleVersion
        self.runtimeBundleRootPath = runtimeBundleRootPath
        self.prefixID = prefixID
        self.prefixManifestPath = prefixManifestPath
        self.runtimeConfigurationPath = runtimeConfigurationPath
        self.environmentFilePath = environmentFilePath
        self.rendererPreset = rendererPreset
        self.directLaunchOnly = directLaunchOnly
        self.createdAt = createdAt
    }
}

public struct RuntimeBackendSessionUpdate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var state: RuntimeHostSessionState
    public var stateHistory: [RuntimeHostSessionState]
    public var statusSummary: String
    public var failureCode: String?
    public var failureReason: String?
    public var updatedAt: Date

    public init(
        id: String,
        state: RuntimeHostSessionState,
        stateHistory: [RuntimeHostSessionState],
        statusSummary: String,
        failureCode: String? = nil,
        failureReason: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.state = state
        self.stateHistory = stateHistory
        self.statusSummary = statusSummary
        self.failureCode = failureCode
        self.failureReason = failureReason
        self.updatedAt = updatedAt
    }
}

public struct RuntimeBackendTerminalResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var terminalStatus: String
    public var stateHistory: [RuntimeHostSessionState]
    public var failureCode: String?
    public var failureReason: String?
    public var reportedAt: Date

    public init(
        id: String,
        terminalStatus: String,
        stateHistory: [RuntimeHostSessionState],
        failureCode: String? = nil,
        failureReason: String? = nil,
        reportedAt: Date = Date()
    ) {
        self.id = id
        self.terminalStatus = terminalStatus
        self.stateHistory = stateHistory
        self.failureCode = failureCode
        self.failureReason = failureReason
        self.reportedAt = reportedAt
    }
}

public protocol RuntimeBackendClient: Sendable {
    func startSession(_ package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate, RuntimeFailure
    >
    func latestSessionUpdate(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate?, RuntimeFailure
    >
    func terminalResult(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendTerminalResult?, RuntimeFailure
    >
    func telemetry(for package: RuntimeBackendLaunchPackage) async -> Result<
        PerformanceTelemetrySnapshot?, RuntimeFailure
    >
}

public struct ProviderBackedRuntimeBackendClient: RuntimeBackendClient {
    public let configuration: RuntimeProviderConfiguration

    public init(configuration: RuntimeProviderConfiguration = RuntimeProviderConfiguration()) {
        self.configuration = configuration
    }

    public func startSession(_ package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate, RuntimeFailure
    > {
        switch validateLaunchPackage(package) {
        case .success:
            break
        case .failure(let failure):
            return .failure(failure)
        }

        do {
            let requestURL = configuration.requestsRootURL.appending(
                path: "launch-\(package.id).json")
            try writeProviderPayload(package, to: requestURL)

            if let update = try await waitForProviderPayload(
                from: configuration.responsesRootURL.appending(path: "session-\(package.id).json"),
                as: RuntimeBackendSessionUpdate.self,
                attempts: 40,
                intervalMS: 100
            ) {
                return .success(update)
            }

            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Runtime provider did not acknowledge session start for \(package.id)\(providerStatusSuffix()).",
                    recoverySuggestion: "Check the device runtime provider and retry launch."
                )
            )
        } catch let failure as RuntimeFailure {
            return .failure(failure)
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to submit runtime provider launch package: \(error.localizedDescription)",
                    recoverySuggestion:
                        "Check the runtime provider request directory and retry launch."
                )
            )
        }
    }

    public func latestSessionUpdate(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate?, RuntimeFailure
    > {
        do {
            let responseURL = configuration.responsesRootURL.appending(
                path: "session-\(package.id).json")
            guard FileManager.default.fileExists(atPath: responseURL.path) else {
                return .success(nil)
            }
            return .success(
                try readProviderPayload(from: responseURL, as: RuntimeBackendSessionUpdate.self))
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to read runtime provider session update: \(error.localizedDescription)",
                    recoverySuggestion:
                        "Check the runtime provider response directory and retry launch."
                )
            )
        }
    }

    public func terminalResult(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendTerminalResult?, RuntimeFailure
    > {
        do {
            let responseURL = configuration.responsesRootURL.appending(
                path: "terminal-\(package.id).json")
            guard FileManager.default.fileExists(atPath: responseURL.path) else {
                return .success(nil)
            }
            return .success(
                try readProviderPayload(from: responseURL, as: RuntimeBackendTerminalResult.self))
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to read runtime provider terminal result: \(error.localizedDescription)",
                    recoverySuggestion:
                        "Check the runtime provider response directory and retry launch."
                )
            )
        }
    }

    public func telemetry(for package: RuntimeBackendLaunchPackage) async -> Result<
        PerformanceTelemetrySnapshot?, RuntimeFailure
    > {
        do {
            let responseURL = configuration.responsesRootURL.appending(
                path: "telemetry-\(package.id).json")
            guard FileManager.default.fileExists(atPath: responseURL.path) else {
                return .success(nil)
            }
            return .success(
                try readProviderPayload(from: responseURL, as: PerformanceTelemetrySnapshot.self))
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to read runtime provider telemetry: \(error.localizedDescription)",
                    recoverySuggestion:
                        "Check the runtime provider response directory and retry launch."
                )
            )
        }
    }

    private func providerStatusSuffix() -> String {
        guard let data = try? Data(contentsOf: configuration.statusURL),
            let status = try? JSONDecoder().decode(BridgeHeartbeatStatus.self, from: data)
        else {
            return " because the provider heartbeat is missing"
        }

        if Date().timeIntervalSince(status.lastUpdatedAt) > 30 {
            return " because the provider heartbeat is stale"
        }

        return ""
    }

    private func validateLaunchPackage(_ package: RuntimeBackendLaunchPackage) -> Result<
        Void, RuntimeFailure
    > {
        guard package.directLaunchOnly else {
            return .failure(
                RuntimeFailure(
                    code: .desktopShellEntrypointBlocked,
                    reason: "Runtime provider rejected a non-direct launch package.",
                    recoverySuggestion: "Repair the runtime launch package and retry."
                )
            )
        }

        let blockedEntrypoints = ["explorer.exe", "progman.exe", "cmd.exe", "powershell.exe"]
        let executableName = URL(fileURLWithPath: package.executablePath).lastPathComponent
            .lowercased()
        guard !blockedEntrypoints.contains(executableName) else {
            return .failure(
                RuntimeFailure(
                    code: .desktopShellEntrypointBlocked,
                    reason: "Runtime provider blocked desktop-shell entrypoint \(executableName).",
                    recoverySuggestion: "Choose a concrete game executable and retry launch."
                )
            )
        }

        guard FileManager.default.fileExists(atPath: package.executablePath) else {
            return .failure(
                RuntimeFailure(
                    code: .missingExecutable,
                    reason:
                        "Runtime provider launch package is missing the selected executable at \(package.executablePath).",
                    recoverySuggestion:
                        "Repair managed storage or re-import the title before retrying."
                )
            )
        }

        let requiredPaths:
            [(path: String, code: RuntimeFailureCode, reason: String, suggestion: String)] = [
                (
                    package.prefixManifestPath,
                    .prefixBootstrapFailed,
                    "Runtime provider launch package is missing the prepared prefix manifest.",
                    "Re-bootstrap the prefix and retry launch."
                ),
                (
                    package.runtimeConfigurationPath,
                    .prefixBootstrapFailed,
                    "Runtime provider launch package is missing the runtime configuration file.",
                    "Re-bootstrap the prefix runtime configuration and retry launch."
                ),
                (
                    package.environmentFilePath,
                    .prefixBootstrapFailed,
                    "Runtime provider launch package is missing the runtime environment file.",
                    "Re-bootstrap the prefix runtime environment and retry launch."
                ),
                (
                    package.runtimeBundleRootPath,
                    .invalidRuntimeBundle,
                    "Runtime provider launch package is missing the concrete runtime bundle root.",
                    "Bind the prefix to a validated runtime bundle and retry launch."
                ),
            ]

        for requiredPath in requiredPaths
        where !FileManager.default.fileExists(atPath: requiredPath.path) {
            return .failure(
                RuntimeFailure(
                    code: requiredPath.code,
                    reason: "\(requiredPath.reason) Expected path: \(requiredPath.path)",
                    recoverySuggestion: requiredPath.suggestion
                )
            )
        }

        for artifact in providerRequiredArtifactPaths {
            let artifactPath = URL(
                fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true
            )
            .appending(path: artifact.relativePath)
            .path
            guard FileManager.default.fileExists(atPath: artifactPath) else {
                return .failure(
                    RuntimeFailure(
                        code: .invalidRuntimeBundle,
                        reason:
                            "Runtime provider launch package is missing required runtime artifact \(artifact.identifier) at \(artifact.relativePath).",
                        recoverySuggestion: "Repair the runtime bundle inventory and retry launch."
                    )
                )
            }
        }

        return .success(())
    }
}

public struct FileSystemRuntimeBackendClient: RuntimeBackendClient {
    public init() {}

    public func startSession(_ package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate, RuntimeFailure
    > {
        do {
            let requestURL = backendRequestsRoot(for: package).appending(
                path: "launch-\(package.id).json")
            try writeBackendPayload(package, to: requestURL)

            if let update = try await waitForBackendPayload(
                from: backendResponsesRoot(for: package).appending(
                    path: "session-\(package.id).json"),
                as: RuntimeBackendSessionUpdate.self,
                attempts: 20,
                intervalMS: 50
            ) {
                return .success(update)
            }

            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason: "Runtime backend did not acknowledge session start for \(package.id).",
                    recoverySuggestion: "Check the runtime backend service and retry launch."
                )
            )
        } catch let failure as RuntimeFailure {
            return .failure(failure)
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to submit runtime backend launch package: \(error.localizedDescription)",
                    recoverySuggestion:
                        "Check runtime backend request directories and retry launch."
                )
            )
        }
    }

    public func latestSessionUpdate(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate?, RuntimeFailure
    > {
        do {
            let responseURL = backendResponsesRoot(for: package).appending(
                path: "session-\(package.id).json")
            guard FileManager.default.fileExists(atPath: responseURL.path) else {
                return .success(nil)
            }
            return .success(
                try readBackendPayload(from: responseURL, as: RuntimeBackendSessionUpdate.self))
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to read runtime backend session update: \(error.localizedDescription)",
                    recoverySuggestion:
                        "Check runtime backend response directories and retry launch."
                )
            )
        }
    }

    public func terminalResult(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendTerminalResult?, RuntimeFailure
    > {
        do {
            let responseURL = backendResponsesRoot(for: package).appending(
                path: "terminal-\(package.id).json")
            guard FileManager.default.fileExists(atPath: responseURL.path) else {
                return .success(nil)
            }
            return .success(
                try readBackendPayload(from: responseURL, as: RuntimeBackendTerminalResult.self))
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to read runtime backend terminal result: \(error.localizedDescription)",
                    recoverySuggestion:
                        "Check runtime backend response directories and retry launch."
                )
            )
        }
    }

    public func telemetry(for package: RuntimeBackendLaunchPackage) async -> Result<
        PerformanceTelemetrySnapshot?, RuntimeFailure
    > {
        do {
            let responseURL = backendResponsesRoot(for: package).appending(
                path: "telemetry-\(package.id).json")
            guard FileManager.default.fileExists(atPath: responseURL.path) else {
                return .success(nil)
            }
            return .success(
                try readBackendPayload(from: responseURL, as: PerformanceTelemetrySnapshot.self))
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to read runtime backend telemetry: \(error.localizedDescription)",
                    recoverySuggestion:
                        "Check runtime backend response directories and retry launch."
                )
            )
        }
    }
}

private struct BundledRuntimeHostInvocation: Sendable {
    var packageID: String
    var hostBinaryURL: URL
    var launchPackageURL: URL
    var sessionUpdateURL: URL
    var terminalResultURL: URL
    var telemetryURL: URL
    var hostLogURL: URL
}

public struct EmbeddedRuntimeHostInvocation: Sendable {
    public var packageID: String
    public var hostBinaryURL: URL
    public var launchPackageURL: URL
    public var sessionUpdateURL: URL
    public var terminalResultURL: URL
    public var telemetryURL: URL
    public var hostLogURL: URL

    public init(
        packageID: String,
        hostBinaryURL: URL,
        launchPackageURL: URL,
        sessionUpdateURL: URL,
        terminalResultURL: URL,
        telemetryURL: URL,
        hostLogURL: URL
    ) {
        self.packageID = packageID
        self.hostBinaryURL = hostBinaryURL
        self.launchPackageURL = launchPackageURL
        self.sessionUpdateURL = sessionUpdateURL
        self.terminalResultURL = terminalResultURL
        self.telemetryURL = telemetryURL
        self.hostLogURL = hostLogURL
    }
}

public typealias EmbeddedRuntimeHostLaunchHandler =
    @Sendable (EmbeddedRuntimeHostInvocation) async throws -> Void

private actor EmbeddedRuntimeHostLaunchRegistry {
    private var handler: EmbeddedRuntimeHostLaunchHandler?

    func register(_ handler: @escaping EmbeddedRuntimeHostLaunchHandler) {
        self.handler = handler
    }

    func clear() {
        handler = nil
    }

    func current() -> EmbeddedRuntimeHostLaunchHandler? {
        handler
    }
}

public enum EmbeddedRuntimeHostBridge {
    private static let registry = EmbeddedRuntimeHostLaunchRegistry()

    public static func registerLaunchHandler(_ handler: @escaping EmbeddedRuntimeHostLaunchHandler)
        async
    {
        await registry.register(handler)
    }

    public static func clearLaunchHandler() async {
        await registry.clear()
    }

    static func currentLaunchHandler() async -> EmbeddedRuntimeHostLaunchHandler? {
        await registry.current()
    }
}

enum EmbeddedRuntimeHostSDKBridge {
    static func launch(_ invocation: EmbeddedRuntimeHostInvocation) async throws {
        try launchSynchronously(invocation)
    }

    private static func launchSynchronously(_ invocation: EmbeddedRuntimeHostInvocation) throws {
        let launchPackagePath = duplicatedCString(invocation.launchPackageURL.path)
        let sessionUpdatePath = duplicatedCString(invocation.sessionUpdateURL.path)
        let terminalResultPath = duplicatedCString(invocation.terminalResultURL.path)
        let telemetryPath = duplicatedCString(invocation.telemetryURL.path)
        let hostLogPath = duplicatedCString(invocation.hostLogURL.path)

        defer {
            free(launchPackagePath)
            free(sessionUpdatePath)
            free(terminalResultPath)
            free(telemetryPath)
            free(hostLogPath)
        }

        var bridgedInvocation = IridiumRuntimeHostInvocationPaths(
            launch_package_path: launchPackagePath,
            session_update_path: sessionUpdatePath,
            terminal_result_path: terminalResultPath,
            telemetry_path: telemetryPath,
            host_log_path: hostLogPath
        )

        let exitCode = iridium_runtime_host_run(&bridgedInvocation)
        guard exitCode == 0 else {
            let terminalResult = try? readBackendPayload(
                from: invocation.terminalResultURL,
                as: RuntimeBackendTerminalResult.self
            )
            let failureCode =
                RuntimeFailureCode(rawValue: terminalResult?.failureCode ?? "")
                ?? .runtimeBootFailed
            var reason = terminalResult?.failureReason?.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if reason?.isEmpty == true {
                reason = nil
            }
            if let hostLogTail = readLogTail(from: invocation.hostLogURL), !hostLogTail.isEmpty {
                if let existingReason = reason {
                    if !existingReason.contains(hostLogTail) {
                        reason = "\(existingReason) Host log: \(hostLogTail)"
                    }
                } else {
                    reason = "Embedded runtime host log: \(hostLogTail)"
                }
            }
            throw RuntimeFailure(
                code: failureCode,
                reason: reason
                    ?? "Embedded runtime host returned exit code \(exitCode) for launch package \(invocation.packageID).",
                recoverySuggestion: "Inspect the embedded runtime host outputs and retry launch."
            )
        }
    }

    private static func duplicatedCString(_ value: String) -> UnsafeMutablePointer<CChar> {
        strdup(value)
    }

    private static func readLogTail(from url: URL, maxLines: Int = 6) -> String? {
        guard
            let contents = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !contents.isEmpty
        else {
            return nil
        }
        let lines =
            contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        return lines.suffix(maxLines).joined(separator: " | ")
    }
}

private protocol RuntimeHostExecutableRunner: Sendable {
    func launch(_ invocation: BundledRuntimeHostInvocation) async throws
}

#if os(macOS)
    private actor ProcessRuntimeHostExecutableRunner: RuntimeHostExecutableRunner {
        private var processes: [String: Process] = [:]

        func launch(_ invocation: BundledRuntimeHostInvocation) async throws {
            guard FileManager.default.fileExists(atPath: invocation.hostBinaryURL.path) else {
                throw RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Bundled runtime host binary is missing at \(invocation.hostBinaryURL.path).",
                    recoverySuggestion:
                        "Provision a runtime bundle that includes a real runtime host and retry launch."
                )
            }

            try FileManager.default.createDirectory(
                at: invocation.launchPackageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: invocation.sessionUpdateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: invocation.hostLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if !FileManager.default.isExecutableFile(atPath: invocation.hostBinaryURL.path) {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: invocation.hostBinaryURL.path
                )
            }

            if !FileManager.default.fileExists(atPath: invocation.hostLogURL.path) {
                FileManager.default.createFile(atPath: invocation.hostLogURL.path, contents: Data())
            }

            let logHandle = try FileHandle(forWritingTo: invocation.hostLogURL)
            try logHandle.seekToEnd()

            let process = Process()
            process.executableURL = invocation.hostBinaryURL
            process.arguments = [
                "--launch-package", invocation.launchPackageURL.path,
                "--session-update", invocation.sessionUpdateURL.path,
                "--terminal-result", invocation.terminalResultURL.path,
                "--telemetry", invocation.telemetryURL.path,
                "--host-log", invocation.hostLogURL.path,
            ]
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [actor = self, packageID = invocation.packageID] _ in
                try? logHandle.close()
                Task {
                    await actor.releaseProcess(for: packageID)
                }
            }
            try process.run()
            processes[invocation.packageID] = process
        }

        private func releaseProcess(for packageID: String) {
            processes.removeValue(forKey: packageID)
        }
    }
#else
    private actor ProcessRuntimeHostExecutableRunner: RuntimeHostExecutableRunner {
        func launch(_ invocation: BundledRuntimeHostInvocation) async throws {
            let embeddedInvocation = EmbeddedRuntimeHostInvocation(
                packageID: invocation.packageID,
                hostBinaryURL: invocation.hostBinaryURL,
                launchPackageURL: invocation.launchPackageURL,
                sessionUpdateURL: invocation.sessionUpdateURL,
                terminalResultURL: invocation.terminalResultURL,
                telemetryURL: invocation.telemetryURL,
                hostLogURL: invocation.hostLogURL
            )

            Task.detached(priority: .userInitiated) {
                do {
                    if let handler = await EmbeddedRuntimeHostBridge.currentLaunchHandler() {
                        try await handler(embeddedInvocation)
                    } else {
                        try await EmbeddedRuntimeHostSDKBridge.launch(embeddedInvocation)
                    }
                } catch {
                    try? persistEmbeddedLaunchFailure(error, for: embeddedInvocation)
                }
            }
        }
    }
#endif

#if !os(macOS)
    private func persistEmbeddedLaunchFailure(
        _ error: Error,
        for invocation: EmbeddedRuntimeHostInvocation
    ) throws {
        let runtimeFailure =
            (error as? RuntimeFailure)
            ?? RuntimeFailure(
                code: .runtimeBootFailed,
                reason: "Failed to launch the bundled runtime host: \(error.localizedDescription)",
                recoverySuggestion: "Check the bundled runtime host binary and retry launch."
            )
        let failureHistory: [RuntimeHostSessionState] = [.queued, .bootingRuntime, .failed]

        try writeBackendPayload(
            RuntimeBackendSessionUpdate(
                id: invocation.packageID,
                state: .failed,
                stateHistory: failureHistory,
                statusSummary: runtimeFailure.reason,
                failureCode: runtimeFailure.code.rawValue,
                failureReason: runtimeFailure.reason
            ),
            to: invocation.sessionUpdateURL
        )

        try writeBackendPayload(
            RuntimeBackendTerminalResult(
                id: invocation.packageID,
                terminalStatus: RuntimeHostSessionState.failed.rawValue,
                stateHistory: failureHistory,
                failureCode: runtimeFailure.code.rawValue,
                failureReason: runtimeFailure.reason
            ),
            to: invocation.terminalResultURL
        )
    }
#endif

private func makeRuntimeHostExecutableRunner() -> any RuntimeHostExecutableRunner {
    ProcessRuntimeHostExecutableRunner()
}

public actor BundledDeviceRuntimeBackendClient: RuntimeBackendClient {
    private let runner: any RuntimeHostExecutableRunner

    public init() {
        self.runner = makeRuntimeHostExecutableRunner()
    }

    fileprivate init(runner: any RuntimeHostExecutableRunner) {
        self.runner = runner
    }

    public func startSession(_ package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate, RuntimeFailure
    > {
        switch validateBundledLaunchPackage(package) {
        case .failure(let failure):
            return .failure(failure)
        case .success:
            break
        }

        do {
            let invocation = bundledRuntimeHostInvocation(for: package)
            if let existing = try? readBackendPayload(
                from: invocation.sessionUpdateURL, as: RuntimeBackendSessionUpdate.self)
            {
                return .success(existing)
            }

            for staleURL in [
                invocation.sessionUpdateURL, invocation.terminalResultURL, invocation.telemetryURL,
            ] {
                if FileManager.default.fileExists(atPath: staleURL.path) {
                    try FileManager.default.removeItem(at: staleURL)
                }
            }

            try writeBackendPayload(package, to: invocation.launchPackageURL)
            try await runner.launch(invocation)

            if let update = try await waitForBackendPayload(
                from: invocation.sessionUpdateURL,
                as: RuntimeBackendSessionUpdate.self,
                attempts: 40,
                intervalMS: 100
            ) {
                return .success(update)
            }

            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Bundled runtime host did not acknowledge session start for \(package.id).",
                    recoverySuggestion:
                        "Check the bundled runtime host integration and retry launch."
                )
            )
        } catch let failure as RuntimeFailure {
            return .failure(failure)
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to launch the bundled runtime host: \(error.localizedDescription)",
                    recoverySuggestion: "Check the bundled runtime host binary and retry launch."
                )
            )
        }
    }

    public func latestSessionUpdate(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate?, RuntimeFailure
    > {
        do {
            let responseURL = bundledRuntimeHostInvocation(for: package).sessionUpdateURL
            guard FileManager.default.fileExists(atPath: responseURL.path) else {
                return .success(nil)
            }
            return .success(
                try readBackendPayload(from: responseURL, as: RuntimeBackendSessionUpdate.self))
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to read bundled runtime host session update: \(error.localizedDescription)",
                    recoverySuggestion: "Check the bundled runtime host outputs and retry launch."
                )
            )
        }
    }

    public func terminalResult(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendTerminalResult?, RuntimeFailure
    > {
        do {
            let responseURL = bundledRuntimeHostInvocation(for: package).terminalResultURL
            guard FileManager.default.fileExists(atPath: responseURL.path) else {
                return .success(nil)
            }
            return .success(
                try readBackendPayload(from: responseURL, as: RuntimeBackendTerminalResult.self))
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to read bundled runtime host terminal result: \(error.localizedDescription)",
                    recoverySuggestion: "Check the bundled runtime host outputs and retry launch."
                )
            )
        }
    }

    public func telemetry(for package: RuntimeBackendLaunchPackage) async -> Result<
        PerformanceTelemetrySnapshot?, RuntimeFailure
    > {
        do {
            let responseURL = bundledRuntimeHostInvocation(for: package).telemetryURL
            guard FileManager.default.fileExists(atPath: responseURL.path) else {
                return .success(nil)
            }
            return .success(
                try readBackendPayload(from: responseURL, as: PerformanceTelemetrySnapshot.self))
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to read bundled runtime host telemetry: \(error.localizedDescription)",
                    recoverySuggestion: "Check the bundled runtime host outputs and retry launch."
                )
            )
        }
    }

    private func bundledRuntimeHostInvocation(for package: RuntimeBackendLaunchPackage)
        -> BundledRuntimeHostInvocation
    {
        let requestsRoot = backendRequestsRoot(for: package)
        let responsesRoot = backendResponsesRoot(for: package)
        let logRoot = backendRoot(for: package).appending(path: "logs", directoryHint: .isDirectory)

        return BundledRuntimeHostInvocation(
            packageID: package.id,
            hostBinaryURL: URL(fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true)
                .appending(path: "Runtime/runtime-host.bin"),
            launchPackageURL: requestsRoot.appending(path: "launch-\(package.id).json"),
            sessionUpdateURL: responsesRoot.appending(path: "session-\(package.id).json"),
            terminalResultURL: responsesRoot.appending(path: "terminal-\(package.id).json"),
            telemetryURL: responsesRoot.appending(path: "telemetry-\(package.id).json"),
            hostLogURL: logRoot.appending(path: "runtime-host-\(package.id).log")
        )
    }

    private func validateBundledLaunchPackage(_ package: RuntimeBackendLaunchPackage) -> Result<
        Void, RuntimeFailure
    > {
        guard package.directLaunchOnly else {
            return .failure(
                RuntimeFailure(
                    code: .desktopShellEntrypointBlocked,
                    reason: "Bundled device runtime rejected a non-direct launch package.",
                    recoverySuggestion: "Repair the prefix bootstrap inputs before retrying launch."
                )
            )
        }

        let requiredPaths = [
            ("executable", package.executablePath),
            ("working directory", package.workingDirectory),
            ("prefix manifest", package.prefixManifestPath),
            ("runtime configuration", package.runtimeConfigurationPath),
            ("environment file", package.environmentFilePath),
            ("runtime bundle root", package.runtimeBundleRootPath),
        ]

        for (label, path) in requiredPaths
        where path.isEmpty || !FileManager.default.fileExists(atPath: path) {
            return .failure(
                RuntimeFailure(
                    code: .invalidRuntimeBundle,
                    reason: "Bundled device runtime launch package is missing \(label) at \(path).",
                    recoverySuggestion: "Rebuild the managed runtime inputs and retry launch."
                )
            )
        }

        for artifact in providerRequiredArtifactPaths {
            let artifactPath = URL(
                fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true
            )
            .appending(path: artifact.relativePath)
            .path
            if FileManager.default.fileExists(atPath: artifactPath) {
                continue
            }

            if artifact.identifier == "wine-userland",
                let stagedRootPath = package.environment[RuntimeEnvironmentKey.userlandRoot],
                isStructurallyValidStagedWineUserland(at: stagedRootPath)
            {
                continue
            }

            let stagedUserlandDetail: String
            if artifact.identifier == "wine-userland" {
                let stagedRootPath =
                    package.environment[RuntimeEnvironmentKey.userlandRoot] ?? "not configured"
                stagedUserlandDetail =
                    " and no structurally valid staged Wine userland was found at \(stagedRootPath)"
            } else {
                stagedUserlandDetail = ""
            }

            return .failure(
                RuntimeFailure(
                    code: .invalidRuntimeBundle,
                    reason:
                        "Bundled device runtime is missing required runtime artifact \(artifact.identifier) at \(artifact.relativePath)\(stagedUserlandDetail).",
                    recoverySuggestion:
                        "Repair the bundled runtime installation and retry launch."
                )
            )
        }

        return .success(())
    }
}

public actor DevelopmentRuntimeBackendClient: RuntimeBackendClient {
    private var updates: [String: [RuntimeBackendSessionUpdate]] = [:]
    private var terminals: [String: RuntimeBackendTerminalResult] = [:]
    private var telemetrySnapshots: [String: PerformanceTelemetrySnapshot?] = [:]
    private var deliveredIndex: [String: Int] = [:]

    public init() {}

    public func startSession(_ package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate, RuntimeFailure
    > {
        guard package.directLaunchOnly else {
            return .failure(
                RuntimeFailure(
                    code: .desktopShellEntrypointBlocked,
                    reason: "Development runtime backend rejected a non-direct launch package.",
                    recoverySuggestion: "Repair the prefix bootstrap inputs before retrying launch."
                )
            )
        }

        let shouldCrash = package.environment["IRIDIUM_FORCE_CRASH"] == "1"
        let omitTelemetry = package.environment["IRIDIUM_BACKEND_NO_TELEMETRY"] == "1"
        let scriptedUpdates = [
            RuntimeBackendSessionUpdate(
                id: package.id,
                state: .queued,
                stateHistory: [.queued],
                statusSummary: "Development runtime backend accepted the launch package."
            ),
            RuntimeBackendSessionUpdate(
                id: package.id,
                state: .bootstrappingPrefix,
                stateHistory: [.queued, .bootstrappingPrefix],
                statusSummary: "Development runtime backend is preparing the prefix."
            ),
            RuntimeBackendSessionUpdate(
                id: package.id,
                state: .bootingRuntime,
                stateHistory: [.queued, .bootstrappingPrefix, .bootingRuntime],
                statusSummary: "Development runtime backend is booting the runtime."
            ),
            RuntimeBackendSessionUpdate(
                id: package.id,
                state: .running,
                stateHistory: [.queued, .bootstrappingPrefix, .bootingRuntime, .running],
                statusSummary: "Development runtime backend entered shell-free execution."
            ),
        ]
        updates[package.id] = scriptedUpdates
        terminals[package.id] = RuntimeBackendTerminalResult(
            id: package.id,
            terminalStatus: shouldCrash
                ? RuntimeHostSessionState.failed.rawValue
                : RuntimeHostSessionState.completed.rawValue,
            stateHistory: shouldCrash
                ? [.queued, .bootstrappingPrefix, .bootingRuntime, .running, .failed]
                : [.queued, .bootstrappingPrefix, .bootingRuntime, .running, .completed],
            failureCode: shouldCrash ? RuntimeFailureCode.gameProcessExited.rawValue : nil,
            failureReason: shouldCrash ? "Game process exited after runtime startup." : nil
        )
        telemetrySnapshots[package.id] =
            omitTelemetry
            ? nil
            : PerformanceTelemetrySnapshot(
                averageFPS: 60,
                frameTimeP95MS: 18,
                memoryPressureRatio: 0.42,
                thermalState: .nominal
            )
        deliveredIndex[package.id] = 0

        return .success(scriptedUpdates[0])
    }

    public func latestSessionUpdate(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate?, RuntimeFailure
    > {
        guard let updates = updates[package.id] else {
            return .success(nil)
        }
        let nextIndex = min((deliveredIndex[package.id] ?? 0) + 1, updates.count - 1)
        deliveredIndex[package.id] = nextIndex
        return .success(updates[nextIndex])
    }

    public func terminalResult(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendTerminalResult?, RuntimeFailure
    > {
        guard let terminal = terminals[package.id] else {
            return .success(nil)
        }
        let updateCount = updates[package.id]?.count ?? 0
        let currentIndex = deliveredIndex[package.id] ?? 0
        if currentIndex < max(updateCount - 1, 0) {
            return .success(nil)
        }
        return .success(terminal)
    }

    public func telemetry(for package: RuntimeBackendLaunchPackage) async -> Result<
        PerformanceTelemetrySnapshot?, RuntimeFailure
    > {
        .success(telemetrySnapshots[package.id] ?? nil)
    }
}

public struct RuntimeMitigationResult: Codable, Hashable, Sendable {
    public var action: ThermalMitigationAction
    public var adjustedPolicy: RuntimePolicy

    public init(action: ThermalMitigationAction, adjustedPolicy: RuntimePolicy) {
        self.action = action
        self.adjustedPolicy = adjustedPolicy
    }
}

public struct RuntimeMitigationCoordinator: Sendable {
    public let adaptationPolicy: any RuntimeAdaptationPolicy

    public init(adaptationPolicy: any RuntimeAdaptationPolicy = DefaultRuntimeAdaptationPolicy()) {
        self.adaptationPolicy = adaptationPolicy
    }

    public func apply(telemetry: PerformanceTelemetrySnapshot, to policy: RuntimePolicy)
        -> RuntimeMitigationResult
    {
        let action = adaptationPolicy.mitigation(for: telemetry, basePolicy: policy)
        var adjusted = policy

        switch action {
        case .none:
            break
        case .reduceResolution:
            adjusted.resolutionScale = max(policy.resolutionScale - 0.1, 0.5)
        case .capFrameRate:
            adjusted.framePacingCap = min(policy.framePacingCap ?? 60, 45)
        case .disableShaderPrewarm:
            adjusted.shaderStrategy = .onDemand
        case .blockLaunch:
            adjusted.environmentOverrides["IRIDIUM_BLOCK_RELAUNCH"] = "1"
        }

        return RuntimeMitigationResult(action: action, adjustedPolicy: adjusted)
    }
}

actor NativeRuntimeHostBackend {
    static let shared = NativeRuntimeHostBackend()
    private let backendClient: any RuntimeBackendClient

    init(backendClient: any RuntimeBackendClient = RuntimeBackendSelection.makeBackendClient()) {
        self.backendClient = backendClient
    }

    func submit(ticket: RuntimeLaunchTicket) async throws -> RuntimeHostSession {
        let hostRoot = URL(fileURLWithPath: ticket.workingDirectory, isDirectory: true)
            .appending(path: ".iridium/runtime-host", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)

        let launchTicketURL = hostRoot.appending(path: "ticket-\(ticket.id).json")
        let sessionLogURL = hostRoot.appending(path: "session-\(ticket.id).log")
        let telemetryURL = hostRoot.appending(path: "telemetry-\(ticket.id).json")
        let sessionURL = hostRoot.appending(path: "session-\(ticket.id).json")

        if let existingSession = try? Data(contentsOf: sessionURL),
            let decoded = try? JSONDecoder().decode(RuntimeHostSession.self, from: existingSession)
        {
            return decoded
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ticket).write(to: launchTicketURL, options: .atomic)
        try Data("state=queued\n".utf8).write(to: sessionLogURL, options: .atomic)

        let inputs = try loadPrefixBootstrapInputs(for: ticket)
        try appendLogLine(
            "prefixManifest=\(inputs.manifest.prefixRootPath)", to: sessionLogURL.path)
        try appendLogLine(
            "runtimeConfig=\(inputs.manifest.runtimeConfigurationPath)", to: sessionLogURL.path)
        try appendLogLine(
            "environmentFile=\(inputs.manifest.environmentFilePath)", to: sessionLogURL.path)
        if let runtimeBundleRootPath = inputs.manifest.runtimeBundleRootPath {
            try appendLogLine("runtimeBundleRoot=\(runtimeBundleRootPath)", to: sessionLogURL.path)
        }

        let launchPackage = try buildLaunchPackage(ticket: ticket, inputs: inputs)
        let backendSubmission = await backendClient.startSession(launchPackage)
        let submissionUpdate: RuntimeBackendSessionUpdate
        switch backendSubmission {
        case .success(let update):
            submissionUpdate = update
        case .failure(let failure):
            throw failure
        }

        let session = RuntimeHostSession(
            id: ticket.id,
            gameID: ticket.gameID,
            gameTitle: ticket.gameTitle,
            launchTicketPath: launchTicketURL.path,
            sessionLogPath: sessionLogURL.path,
            telemetryPath: telemetryURL.path,
            runtimeBundleID: ticket.runtimeBundleID,
            runtimeBundleVersion: ticket.runtimeBundleVersion,
            state: submissionUpdate.state,
            stateHistory: submissionUpdate.stateHistory,
            statusSummary: submissionUpdate.statusSummary,
            failureCode: mapBackendFailureCode(submissionUpdate.failureCode),
            failureReason: submissionUpdate.failureReason
        )
        try encoder.encode(session).write(to: sessionURL, options: .atomic)
        return session
    }

    func advance(session: RuntimeHostSession) async throws -> RuntimeHostSession {
        let latest = try loadPersistedSession(for: session) ?? session
        guard latest.state != .completed, latest.state != .failed else {
            return latest
        }

        let launchPackage = try loadLaunchPackage(for: latest)
        var updated = latest

        switch await backendClient.terminalResult(for: launchPackage) {
        case .success(let terminal?):
            updated = applyTerminalResult(terminal, to: latest)
            if case .success(let telemetry?) = await backendClient.telemetry(for: launchPackage) {
                updated.lastTelemetry = telemetry
                try persistTelemetry(telemetry, to: updated.telemetryPath)
            }
        case .success(nil):
            switch await backendClient.latestSessionUpdate(for: launchPackage) {
            case .success(let sessionUpdate?):
                updated = applySessionUpdate(sessionUpdate, to: latest)
            case .success(nil):
                break
            case .failure(let failure):
                updated = fail(latest, code: failure.code, reason: failure.reason)
            }
        case .failure(let failure):
            updated = fail(latest, code: failure.code, reason: failure.reason)
        }

        try persistSession(updated)
        return updated
    }

    func resolveTerminalState(for session: RuntimeHostSession) async throws -> RuntimeHostSession {
        var updated = try loadPersistedSession(for: session) ?? session
        for _ in 0..<40 {
            guard updated.state != .completed && updated.state != .failed else {
                return updated
            }
            updated = try await advance(session: updated)
            try await Task.sleep(nanoseconds: 50 * 1_000_000)
        }

        return updated
    }

    func telemetry(for session: RuntimeHostSession) async throws -> PerformanceTelemetrySnapshot? {
        if let telemetry = session.lastTelemetry {
            return telemetry
        }

        let telemetryURL = URL(fileURLWithPath: session.telemetryPath)
        if let data = try? Data(contentsOf: telemetryURL),
            let snapshot = try? JSONDecoder().decode(PerformanceTelemetrySnapshot.self, from: data)
        {
            return snapshot
        }

        let launchPackage = try loadLaunchPackage(for: session)
        switch await backendClient.telemetry(for: launchPackage) {
        case .success(let telemetry):
            if let telemetry {
                try persistTelemetry(telemetry, to: session.telemetryPath)
            }
            return telemetry
        case .failure(let failure):
            throw failure
        }
    }

    private func loadLaunchTicket(from path: String) throws -> RuntimeLaunchTicket {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(RuntimeLaunchTicket.self, from: data)
    }

    private func loadPersistedSession(for session: RuntimeHostSession) throws -> RuntimeHostSession?
    {
        let sessionURL = URL(fileURLWithPath: session.launchTicketPath)
            .deletingLastPathComponent()
            .appending(path: "session-\(session.id).json")
        guard FileManager.default.fileExists(atPath: sessionURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: sessionURL)
        return try JSONDecoder().decode(RuntimeHostSession.self, from: data)
    }

    private func loadPrefixBootstrapInputs(for ticket: RuntimeLaunchTicket) throws
        -> PrefixBootstrapInputs
    {
        guard FileManager.default.fileExists(atPath: ticket.prefixManifestPath) else {
            throw RuntimeFailure(
                code: .prefixBootstrapFailed,
                reason: "Runtime host could not locate the prepared prefix manifest.",
                recoverySuggestion: "Rebuild the prefix bootstrap inputs before retrying launch."
            )
        }

        let manifestData = try Data(contentsOf: URL(fileURLWithPath: ticket.prefixManifestPath))
        let manifest = try JSONDecoder().decode(PrefixBootstrapManifest.self, from: manifestData)

        guard FileManager.default.fileExists(atPath: manifest.environmentFilePath) else {
            throw RuntimeFailure(
                code: .prefixBootstrapFailed,
                reason: "Runtime host could not locate the prepared runtime environment file.",
                recoverySuggestion: "Rebuild the prefix bootstrap inputs before retrying launch."
            )
        }

        guard FileManager.default.fileExists(atPath: manifest.runtimeConfigurationPath) else {
            throw RuntimeFailure(
                code: .prefixBootstrapFailed,
                reason: "Runtime host could not locate the prepared runtime configuration file.",
                recoverySuggestion: "Rebuild the prefix bootstrap inputs before retrying launch."
            )
        }

        let runtimeConfigurationData = try Data(
            contentsOf: URL(fileURLWithPath: manifest.runtimeConfigurationPath))
        let runtimeConfiguration = try JSONDecoder().decode(
            PrefixRuntimeConfiguration.self, from: runtimeConfigurationData)
        let environmentOverrides = try loadEnvironmentOverrides(from: manifest.environmentFilePath)

        return PrefixBootstrapInputs(
            manifest: manifest,
            runtimeConfiguration: runtimeConfiguration,
            environmentOverrides: environmentOverrides
        )
    }

    private func persistSession(_ session: RuntimeHostSession) throws {
        let sessionURL = URL(fileURLWithPath: session.launchTicketPath)
            .deletingLastPathComponent()
            .appending(path: "session-\(session.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: sessionURL, options: .atomic)
        try appendLogLine(
            "state=\(session.state.rawValue) summary=\(session.statusSummary)",
            to: session.sessionLogPath)
    }

    private func persistTelemetry(_ telemetry: PerformanceTelemetrySnapshot, to path: String) throws
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(telemetry).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func appendLogLine(_ line: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path),
            let handle = try? FileHandle(forWritingTo: url)
        {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(line)\n".utf8))
            try handle.close()
        } else {
            try Data("\(line)\n".utf8).write(to: url, options: .atomic)
        }
    }

    private func transition(
        _ session: RuntimeHostSession,
        to state: RuntimeHostSessionState,
        summary: String
    ) -> RuntimeHostSession {
        var updated = session
        updated.state = state
        updated.stateHistory.append(state)
        updated.statusSummary = summary
        updated.updatedAt = Date()
        return updated
    }

    private func fail(
        _ session: RuntimeHostSession,
        code: RuntimeFailureCode,
        reason: String
    ) -> RuntimeHostSession {
        var updated = session
        updated.state = .failed
        updated.stateHistory.append(.failed)
        updated.failureCode = code
        updated.failureReason = reason
        updated.statusSummary = reason
        updated.updatedAt = Date()
        return updated
    }

    private func applySessionUpdate(
        _ update: RuntimeBackendSessionUpdate,
        to session: RuntimeHostSession
    ) -> RuntimeHostSession {
        var updated = session
        updated.state = update.state
        updated.stateHistory = update.stateHistory
        updated.statusSummary = update.statusSummary
        updated.failureCode = mapBackendFailureCode(update.failureCode)
        updated.failureReason = update.failureReason
        updated.updatedAt = update.updatedAt
        return updated
    }

    private func applyTerminalResult(
        _ result: RuntimeBackendTerminalResult,
        to session: RuntimeHostSession
    ) -> RuntimeHostSession {
        var updated = session
        let terminalState = RuntimeHostSessionState(rawValue: result.terminalStatus) ?? .failed
        updated.state = terminalState
        updated.stateHistory = result.stateHistory
        updated.statusSummary =
            result.failureReason
            ?? (terminalState == .completed
                ? "Runtime backend reported a completed shell-free session."
                : "Runtime backend reported a failed session.")
        updated.failureCode = mapBackendFailureCode(result.failureCode)
        updated.failureReason = result.failureReason
        updated.updatedAt = result.reportedAt
        return updated
    }

    private func buildLaunchPackage(
        ticket: RuntimeLaunchTicket,
        inputs: PrefixBootstrapInputs
    ) throws -> RuntimeBackendLaunchPackage {
        switch validatePrefixBootstrapInputs(inputs, ticket: ticket) {
        case .success:
            break
        case .failure(let failure):
            throw failure
        }

        guard inputs.runtimeConfiguration.directLaunchOnly else {
            throw RuntimeFailure(
                code: .desktopShellEntrypointBlocked,
                reason: "Runtime configuration attempted to enable a desktop shell launch path.",
                recoverySuggestion: "Repair the prefix runtime configuration and retry launch."
            )
        }

        guard let runtimeBundleRootPath = inputs.manifest.runtimeBundleRootPath,
            let configuredRuntimeBundleRootPath = inputs.runtimeConfiguration.runtimeBundleRootPath,
            runtimeBundleRootPath == configuredRuntimeBundleRootPath
        else {
            throw RuntimeFailure(
                code: .invalidRuntimeBundle,
                reason: "Runtime backend launch package is missing a concrete runtime bundle root.",
                recoverySuggestion:
                    "Re-bind the prefix to a validated runtime bundle and retry launch."
            )
        }

        let launchPackage = RuntimeBackendLaunchPackage(
            id: ticket.id,
            gameID: ticket.gameID,
            gameTitle: ticket.gameTitle,
            executablePath: ticket.executablePath,
            workingDirectory: ticket.workingDirectory,
            launchArguments: ticket.launchArguments,
            environment: inputs.environmentOverrides.merging(ticket.environment) { _, ticketValue in
                ticketValue
            },
            runtimeBundleID: ticket.runtimeBundleID,
            runtimeBundleVersion: ticket.runtimeBundleVersion,
            runtimeBundleRootPath: runtimeBundleRootPath,
            prefixID: ticket.prefixID,
            prefixManifestPath: ticket.prefixManifestPath,
            runtimeConfigurationPath: inputs.manifest.runtimeConfigurationPath,
            environmentFilePath: inputs.manifest.environmentFilePath,
            rendererPreset: inputs.runtimeConfiguration.rendererPreset,
            directLaunchOnly: inputs.runtimeConfiguration.directLaunchOnly
        )

        guard isRendererCompatible(package: launchPackage) else {
            throw RuntimeFailure(
                code: .rendererInitializationFailed,
                reason:
                    "Runtime backend launch package is incompatible with the requested renderer and runtime graphics stack.",
                recoverySuggestion:
                    "Choose a compatible renderer profile or runtime bundle before retrying launch."
            )
        }

        return launchPackage
    }

    private func loadLaunchPackage(for session: RuntimeHostSession) throws
        -> RuntimeBackendLaunchPackage
    {
        let ticket = try loadLaunchTicket(from: session.launchTicketPath)
        let inputs = try loadPrefixBootstrapInputs(for: ticket)
        return try buildLaunchPackage(ticket: ticket, inputs: inputs)
    }

    private func validatePrefixBootstrapInputs(
        _ inputs: PrefixBootstrapInputs,
        ticket: RuntimeLaunchTicket
    ) -> Result<Void, RuntimeFailure> {
        guard inputs.manifest.prefixID == ticket.prefixID else {
            return .failure(
                RuntimeFailure(
                    code: .prefixBootstrapFailed,
                    reason:
                        "Runtime host rejected prefix inputs because the prefix identifier does not match the launch ticket.",
                    recoverySuggestion: "Re-bootstrap the prefix for this title and retry launch."
                )
            )
        }

        guard inputs.runtimeConfiguration.prefixID == ticket.prefixID else {
            return .failure(
                RuntimeFailure(
                    code: .prefixBootstrapFailed,
                    reason:
                        "Runtime host rejected runtime configuration because the prefix identifier does not match the launch ticket.",
                    recoverySuggestion:
                        "Re-bootstrap the prefix runtime configuration and retry launch."
                )
            )
        }

        guard inputs.runtimeConfiguration.executablePath == ticket.executablePath else {
            return .failure(
                RuntimeFailure(
                    code: .managedArtifactMismatch,
                    reason:
                        "Runtime host rejected prefix inputs because the executable path no longer matches the launch ticket.",
                    recoverySuggestion:
                        "Refresh the import metadata and prefix bootstrap before retrying launch."
                )
            )
        }

        guard inputs.runtimeConfiguration.runtimeBundleID == ticket.runtimeBundleID,
            inputs.runtimeConfiguration.runtimeBundleVersion == ticket.runtimeBundleVersion,
            inputs.manifest.runtimeBundleID == ticket.runtimeBundleID,
            inputs.manifest.runtimeBundleVersion == ticket.runtimeBundleVersion
        else {
            return .failure(
                RuntimeFailure(
                    code: .invalidRuntimeBundle,
                    reason:
                        "Runtime host rejected prefix inputs because the bound runtime bundle no longer matches the launch ticket.",
                    recoverySuggestion:
                        "Re-bind the prefix to the current runtime bundle and retry launch."
                )
            )
        }

        guard inputs.runtimeConfiguration.environmentFilePath == inputs.manifest.environmentFilePath
        else {
            return .failure(
                RuntimeFailure(
                    code: .prefixBootstrapFailed,
                    reason:
                        "Runtime host rejected prefix inputs because the runtime environment file path drifted from the prefix manifest.",
                    recoverySuggestion:
                        "Re-bootstrap the prefix runtime configuration and retry launch."
                )
            )
        }

        if let runtimeBundleRootPath = inputs.manifest.runtimeBundleRootPath,
            let configuredRuntimeBundleRootPath = inputs.runtimeConfiguration.runtimeBundleRootPath,
            runtimeBundleRootPath != configuredRuntimeBundleRootPath
        {
            return .failure(
                RuntimeFailure(
                    code: .invalidRuntimeBundle,
                    reason:
                        "Runtime host rejected prefix inputs because the runtime bundle root path no longer matches the prefix manifest.",
                    recoverySuggestion:
                        "Re-bind the prefix to the current runtime bundle and retry launch."
                )
            )
        }

        guard inputs.manifest.runtimeBundleRootPath != nil,
            inputs.runtimeConfiguration.runtimeBundleRootPath != nil
        else {
            return .failure(
                RuntimeFailure(
                    code: .invalidRuntimeBundle,
                    reason:
                        "Runtime backend launch package requires a concrete runtime bundle root path.",
                    recoverySuggestion:
                        "Re-bind the prefix to a validated runtime bundle and retry launch."
                )
            )
        }

        if let runtimeBundleRootPath = inputs.manifest.runtimeBundleRootPath {
            let runtimeHostBinaryPath = URL(
                fileURLWithPath: runtimeBundleRootPath, isDirectory: true
            )
            .appending(path: "Runtime/runtime-host.bin")
            .path
            guard FileManager.default.fileExists(atPath: runtimeHostBinaryPath) else {
                return .failure(
                    RuntimeFailure(
                        code: .invalidRuntimeBundle,
                        reason:
                            "Runtime host could not locate the runtime binary declared by the bound bundle.",
                        recoverySuggestion:
                            "Repair the runtime bundle inventory before retrying launch."
                    )
                )
            }
        }

        guard
            inputs.environmentOverrides[RuntimeEnvironmentKey.noDesktop]
                ?? ticket.environment[RuntimeEnvironmentKey.noDesktop] == "1"
        else {
            return .failure(
                RuntimeFailure(
                    code: .desktopShellEntrypointBlocked,
                    reason:
                        "Runtime host rejected launch because the prefix environment does not enforce the no-desktop invariant.",
                    recoverySuggestion: "Repair the prefix runtime environment and retry launch."
                )
            )
        }

        return .success(())
    }

    private func isRendererCompatible(package: RuntimeBackendLaunchPackage) -> Bool {
        let requested = package.rendererPreset
        guard
            package.environment[RuntimeEnvironmentKey.rendererPreset] == nil
                || package.environment[RuntimeEnvironmentKey.rendererPreset] == requested
        else {
            return false
        }
        let activeStack =
            package.environment[RuntimeEnvironmentKey.runtimeGraphicsStack]
            ?? GraphicsStack.vkd3dViaMoltenVK.rawValue

        switch requested {
        case RendererPreset.vkd3dHighCompatibility.rawValue:
            return activeStack == GraphicsStack.vkd3dViaMoltenVK.rawValue
        case RendererPreset.dxvkBalanced.rawValue, RendererPreset.dxvkPerformance.rawValue:
            return activeStack == GraphicsStack.dxvkViaMoltenVK.rawValue
                || activeStack == GraphicsStack.vkd3dViaMoltenVK.rawValue
        case RendererPreset.metalOpenGLFallback.rawValue:
            return true
        default:
            return true
        }
    }

    private func loadEnvironmentOverrides(from path: String) throws -> [String: String] {
        let rawValue = try String(contentsOfFile: path, encoding: .utf8)
        var environmentOverrides: [String: String] = [:]

        for line in rawValue.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            environmentOverrides[String(parts[0])] = String(parts[1])
        }

        return environmentOverrides
    }

    private func mapBackendFailureCode(_ rawValue: String?) -> RuntimeFailureCode? {
        guard let rawValue else {
            return nil
        }
        return RuntimeFailureCode(rawValue: rawValue) ?? .runtimeBootFailed
    }
}

private struct PrefixBootstrapInputs: Sendable {
    var manifest: PrefixBootstrapManifest
    var runtimeConfiguration: PrefixRuntimeConfiguration
    var environmentOverrides: [String: String]
}

private func bundledRuntimeUserlandRoot(for runtimeBundleID: String) -> String? {
    guard !runtimeBundleID.isEmpty else {
        return nil
    }

    let candidate = Bundle.main.bundleURL.appending(
        path: "IridiumWineUserland", directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate.path
    }

    return nil
}

public struct FileSystemPrefixBootstrapService: PrefixBootstrapService {
    public init() {}

    public func bootstrap(
        game: GameRecord,
        prefix: PrefixRecord,
        runtimeBundle: RuntimeBundleManifest,
        policy: RuntimePolicy
    ) async -> Result<PrefixBootstrapResult, RuntimeFailure> {
        do {
            let manifestRoot = URL(fileURLWithPath: game.installPath, isDirectory: true)
                .appending(path: ".iridium/prefixes", directoryHint: .isDirectory)
            let prefixRoot = manifestRoot.appending(
                path: prefix.id.uuidString, directoryHint: .isDirectory)
            let driveCURL = prefixRoot.appending(path: "drive_c", directoryHint: .isDirectory)
            let usersURL = driveCURL.appending(path: "users/steamuser", directoryHint: .isDirectory)
            let dosDevicesURL = prefixRoot.appending(
                path: "dosdevices", directoryHint: .isDirectory)
            let configURL = prefixRoot.appending(path: "config", directoryHint: .isDirectory)
            let wineServerRootURL = prefixRoot.appending(
                path: ".wineserver", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: manifestRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: usersURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: dosDevicesURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: configURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: wineServerRootURL, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: wineServerRootURL.path)

            let environmentFileURL = configURL.appending(path: "runtime.env")
            let runtimeConfigurationURL = configURL.appending(path: "runtime.json")
            let manifestURL = manifestRoot.appending(path: "\(prefix.id.uuidString).json")
            let runtimeBundleRootPath = runtimeBundle.bundleRootPath ?? ""
            var bootstrapEnvironment = [
                RuntimeEnvironmentKey.noDesktop: "1",
                RuntimeEnvironmentKey.wineServerRoot: wineServerRootURL.path,
                "WINEPREFIX": prefixRoot.path,
                "WINEARCH": "win64",
            ]
            if !runtimeBundleRootPath.isEmpty {
                bootstrapEnvironment[RuntimeEnvironmentKey.runtimeBundleRoot] = runtimeBundleRootPath
                bootstrapEnvironment["IRIDIUM_RUNTIME_HOST"] =
                    URL(fileURLWithPath: runtimeBundleRootPath, isDirectory: true)
                    .appending(path: "Runtime/runtime-host.bin")
                    .path
                bootstrapEnvironment["IRIDIUM_TRANSLATOR_BINARY"] =
                    URL(fileURLWithPath: runtimeBundleRootPath, isDirectory: true)
                    .appending(path: "Translator/x64-jit.bin")
                    .path
                let userlandArchivePath =
                    URL(fileURLWithPath: runtimeBundleRootPath, isDirectory: true)
                    .appending(path: "Userland/wine-userland.tar.zst")
                    .path
                if FileManager.default.fileExists(atPath: userlandArchivePath) {
                    bootstrapEnvironment["IRIDIUM_USERLAND_ARCHIVE"] = userlandArchivePath
                }
                bootstrapEnvironment["IRIDIUM_DIRECT_LAUNCH_PROFILE"] =
                    URL(fileURLWithPath: runtimeBundleRootPath, isDirectory: true)
                    .appending(path: "Metadata/direct-launch.json")
                    .path
            }
            if let bundledUserlandRoot = bundledRuntimeUserlandRoot(for: runtimeBundle.id) {
                bootstrapEnvironment[RuntimeEnvironmentKey.userlandRoot] = bundledUserlandRoot
                bootstrapEnvironment[RuntimeEnvironmentKey.wineDataDirectory] = URL(
                    fileURLWithPath: bundledUserlandRoot, isDirectory: true
                ).appending(path: "share/wine", directoryHint: .isDirectory).path
            }
            let environmentLines =
                bootstrapEnvironment
                .merging(policy.environmentOverrides) { _, override in override }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
            let runtimeConfiguration = PrefixRuntimeConfiguration(
                prefixID: prefix.id,
                title: game.title,
                executablePath: game.launchProfile.executablePath,
                runtimeBundleID: runtimeBundle.id,
                runtimeBundleVersion: runtimeBundle.version,
                runtimeBundleRootPath: runtimeBundle.bundleRootPath,
                environmentFilePath: environmentFileURL.path,
                rendererPreset: (policy.rendererOverride ?? game.rendererPreset).rawValue,
                resolutionScale: policy.resolutionScale,
                framePacingCap: policy.framePacingCap,
                shaderStrategy: policy.shaderStrategy.rawValue,
                directLaunchOnly: true
            )
            let manifest = PrefixBootstrapManifest(
                prefixID: prefix.id,
                title: game.title,
                executableFingerprint: game.executableFingerprint,
                runtimeBundleID: runtimeBundle.id,
                runtimeBundleVersion: runtimeBundle.version,
                prefixRootPath: prefixRoot.path,
                runtimeBundleRootPath: runtimeBundle.bundleRootPath,
                environmentFilePath: environmentFileURL.path,
                runtimeConfigurationPath: runtimeConfigurationURL.path,
                environmentOverrides: policy.environmentOverrides
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try Data((environmentLines.isEmpty ? "" : "\(environmentLines)\n").utf8).write(
                to: environmentFileURL, options: .atomic)
            try encoder.encode(runtimeConfiguration).write(
                to: runtimeConfigurationURL, options: .atomic)
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

            return .success(
                PrefixBootstrapResult(
                    manifestPath: manifestURL.path,
                    manifestVersion: "1",
                    status: "bootstrapped",
                    detail:
                        "Prepared prefix filesystem layout and runtime config for native runtime host submission."
                )
            )
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .prefixBootstrapFailed,
                    reason:
                        "Failed to bootstrap the prefix manifest: \(error.localizedDescription)",
                    recoverySuggestion: "Repair the prefix and retry launch."
                )
            )
        }
    }
}

private struct PrefixRuntimeConfiguration: Codable, Hashable, Sendable {
    var prefixID: UUID
    var title: String
    var executablePath: String
    var runtimeBundleID: String
    var runtimeBundleVersion: String
    var runtimeBundleRootPath: String?
    var environmentFilePath: String
    var rendererPreset: String
    var resolutionScale: Double
    var framePacingCap: Int?
    var shaderStrategy: String
    var directLaunchOnly: Bool
}

public struct FileSystemRuntimeHostController: RuntimeHostController {
    private let backend: NativeRuntimeHostBackend

    public init(
        backendClient: any RuntimeBackendClient = RuntimeBackendSelection.makeBackendClient()
    ) {
        self.backend = NativeRuntimeHostBackend(backendClient: backendClient)
    }

    public func submit(ticket: RuntimeLaunchTicket) async -> Result<
        RuntimeHostSession, RuntimeFailure
    > {
        do {
            return .success(try await backend.submit(ticket: ticket))
        } catch let failure as RuntimeFailure {
            return .failure(failure)
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to submit the native runtime host session: \(error.localizedDescription)",
                    recoverySuggestion: "Check runtime host write access and retry."
                )
            )
        }
    }
}

public struct NativeRuntimeBridgeRequestProcessor: RuntimeBridgeRequestProcessor {
    private let runtimeConfiguration: RuntimeHostBridgeConfiguration
    private let runtimeBackendClient: any RuntimeBackendClient

    public init(
        runtimeConfiguration: RuntimeHostBridgeConfiguration = RuntimeHostBridgeConfiguration(),
        runtimeBackendClient: any RuntimeBackendClient = RuntimeBackendSelection.makeBackendClient()
    ) {
        self.runtimeConfiguration = runtimeConfiguration
        self.runtimeBackendClient = runtimeBackendClient
    }

    public func processRuntimeRequests() async throws -> Int {
        try await NativeBridgeService(
            runtimeConfiguration: runtimeConfiguration,
            runtimeBackendClient: runtimeBackendClient,
            steamConfiguration: SteamBridgeConfiguration(
                rootURL: runtimeConfiguration.rootURL
                    .deletingLastPathComponent()
                    .appending(path: "Steam", directoryHint: .isDirectory)
            )
        ).processRuntimeRequests()
    }
}

public struct BridgedRuntimeHostController: RuntimeHostController {
    private let configuration: RuntimeHostBridgeConfiguration
    private let processor: (any RuntimeBridgeRequestProcessor)?
    private let fallbackMode: RuntimeBridgeFallbackMode
    private let fallbackController: any RuntimeHostController

    public init(
        configuration: RuntimeHostBridgeConfiguration = RuntimeHostBridgeConfiguration(),
        processor: (any RuntimeBridgeRequestProcessor)? = nil,
        fallbackMode: RuntimeBridgeFallbackMode = .never,
        fallbackController: any RuntimeHostController = FileSystemRuntimeHostController()
    ) {
        self.configuration = configuration
        self.processor = processor
        self.fallbackMode = fallbackMode
        self.fallbackController = fallbackController
    }

    public func submit(ticket: RuntimeLaunchTicket) async -> Result<
        RuntimeHostSession, RuntimeFailure
    > {
        let requestURL = configuration.requestsRootURL.appending(path: "launch-\(ticket.id).json")
        let responseURL = configuration.responsesRootURL.appending(
            path: "session-\(ticket.id).json")

        do {
            if let response = try? readBridgePayload(from: responseURL, as: RuntimeHostSession.self)
            {
                return .success(response)
            }
            try writeBridgePayload(ticket, to: requestURL)
            if let processor {
                _ = try await processor.processRuntimeRequests()
            }
            if let response = try await waitForBridgePayload(
                from: responseURL, as: RuntimeHostSession.self)
            {
                return .success(response)
            }
        } catch {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason:
                        "Failed to submit the bridged runtime host request: \(error.localizedDescription)",
                    recoverySuggestion: "Check the native bridge request directory and retry."
                )
            )
        }

        if shouldUseDevelopmentFallback(fallbackMode) {
            return await fallbackController.submit(ticket: ticket)
        }

        return .failure(
            RuntimeFailure(
                code: .runtimeBootFailed,
                reason: "Runtime bridge did not return a host session for request \(ticket.id).",
                recoverySuggestion: "Check the bridge runtime service and retry launch."
            )
        )
    }
}

public struct FileSystemRuntimeExecutionMonitor: RuntimeExecutionMonitor {
    private let backend: NativeRuntimeHostBackend

    public init(
        backendClient: any RuntimeBackendClient = RuntimeBackendSelection.makeBackendClient()
    ) {
        self.backend = NativeRuntimeHostBackend(backendClient: backendClient)
    }

    public func resolveTerminalState(for session: RuntimeHostSession) async -> RuntimeHostSession {
        (try? await backend.resolveTerminalState(for: session)) ?? session
    }
}

public struct BridgedRuntimeExecutionMonitor: RuntimeExecutionMonitor {
    private let configuration: RuntimeHostBridgeConfiguration
    private let processor: (any RuntimeBridgeRequestProcessor)?
    private let fallbackMode: RuntimeBridgeFallbackMode
    private let fallback: any RuntimeExecutionMonitor

    public init(
        configuration: RuntimeHostBridgeConfiguration = RuntimeHostBridgeConfiguration(),
        processor: (any RuntimeBridgeRequestProcessor)? = nil,
        fallbackMode: RuntimeBridgeFallbackMode = .never,
        fallback: any RuntimeExecutionMonitor = FileSystemRuntimeExecutionMonitor()
    ) {
        self.configuration = configuration
        self.processor = processor
        self.fallbackMode = fallbackMode
        self.fallback = fallback
    }

    public func resolveTerminalState(for session: RuntimeHostSession) async -> RuntimeHostSession {
        let responseURL = configuration.responsesRootURL.appending(
            path: "session-\(session.id).json")
        var latest = session

        for _ in 0..<40 {
            if let response = try? readBridgePayload(from: responseURL, as: RuntimeHostSession.self)
            {
                latest = response
                if response.state == .completed || response.state == .failed {
                    return response
                }
            }

            if let processor {
                _ = try? await processor.processRuntimeRequests()
            }

            try? await Task.sleep(nanoseconds: 50 * 1_000_000)
        }

        guard shouldUseDevelopmentFallback(fallbackMode) else {
            return latest
        }
        return await fallback.resolveTerminalState(for: session)
    }
}

public struct FileSystemRuntimeTelemetryCollector: RuntimeTelemetryCollector {
    private let backend: NativeRuntimeHostBackend

    public init(
        backendClient: any RuntimeBackendClient = RuntimeBackendSelection.makeBackendClient()
    ) {
        self.backend = NativeRuntimeHostBackend(backendClient: backendClient)
    }

    public func collect(for session: RuntimeHostSession, policy: RuntimePolicy) async
        -> PerformanceTelemetrySnapshot?
    {
        try? await backend.telemetry(for: session)
    }
}

public struct BridgedRuntimeTelemetryCollector: RuntimeTelemetryCollector {
    private let configuration: RuntimeHostBridgeConfiguration
    private let processor: (any RuntimeBridgeRequestProcessor)?
    private let fallbackMode: RuntimeBridgeFallbackMode
    private let fallback: any RuntimeTelemetryCollector

    public init(
        configuration: RuntimeHostBridgeConfiguration = RuntimeHostBridgeConfiguration(),
        processor: (any RuntimeBridgeRequestProcessor)? = nil,
        fallbackMode: RuntimeBridgeFallbackMode = .never,
        fallback: any RuntimeTelemetryCollector = FileSystemRuntimeTelemetryCollector()
    ) {
        self.configuration = configuration
        self.processor = processor
        self.fallbackMode = fallbackMode
        self.fallback = fallback
    }

    public func collect(for session: RuntimeHostSession, policy: RuntimePolicy) async
        -> PerformanceTelemetrySnapshot?
    {
        let responseURL = configuration.responsesRootURL.appending(
            path: "telemetry-\(session.id).json")
        for _ in 0..<20 {
            if let response = try? readBridgePayload(
                from: responseURL, as: PerformanceTelemetrySnapshot.self)
            {
                return response
            }

            if let processor {
                _ = try? await processor.processRuntimeRequests()
            }

            try? await Task.sleep(nanoseconds: 50 * 1_000_000)
        }
        guard shouldUseDevelopmentFallback(fallbackMode) else {
            return nil
        }
        return await fallback.collect(for: session, policy: policy)
    }
}

private func writeBridgePayload<Value: Encodable>(_ value: Value, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func readBridgePayload<Value: Decodable>(from url: URL, as type: Value.Type) throws -> Value
{
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Value.self, from: data)
}

private func waitForBridgePayload<Value: Decodable>(
    from url: URL,
    as type: Value.Type,
    attempts: Int = 20,
    intervalMS: UInt64 = 50
) async throws -> Value? {
    for _ in 0..<attempts {
        if let value = try? readBridgePayload(from: url, as: type) {
            return value
        }
        try await Task.sleep(nanoseconds: intervalMS * 1_000_000)
    }
    return nil
}

private func writeProviderPayload<Value: Encodable>(_ value: Value, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func readProviderPayload<Value: Decodable>(from url: URL, as type: Value.Type) throws
    -> Value
{
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Value.self, from: data)
}

private func waitForProviderPayload<Value: Decodable>(
    from url: URL,
    as type: Value.Type,
    attempts: Int = 40,
    intervalMS: UInt64 = 100
) async throws -> Value? {
    for _ in 0..<attempts {
        if let value = try? readProviderPayload(from: url, as: type) {
            return value
        }
        try await Task.sleep(nanoseconds: intervalMS * 1_000_000)
    }
    return nil
}

private func shouldUseDevelopmentFallback(_ mode: RuntimeBridgeFallbackMode) -> Bool {
    switch mode {
    case .never:
        return false
    case .developmentOnly:
        #if os(macOS) || targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }
}

private func backendRoot(for package: RuntimeBackendLaunchPackage) -> URL {
    URL(fileURLWithPath: package.workingDirectory, isDirectory: true)
        .appending(path: ".iridium/runtime-backend", directoryHint: .isDirectory)
}

private func backendRequestsRoot(for package: RuntimeBackendLaunchPackage) -> URL {
    backendRoot(for: package).appending(path: "requests", directoryHint: .isDirectory)
}

private func backendResponsesRoot(for package: RuntimeBackendLaunchPackage) -> URL {
    backendRoot(for: package).appending(path: "responses", directoryHint: .isDirectory)
}

private func writeBackendPayload<Value: Encodable>(_ value: Value, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func readBackendPayload<Value: Decodable>(from url: URL, as type: Value.Type) throws
    -> Value
{
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Value.self, from: data)
}

private func waitForBackendPayload<Value: Decodable>(
    from url: URL,
    as type: Value.Type,
    attempts: Int = 20,
    intervalMS: UInt64 = 50
) async throws -> Value? {
    for _ in 0..<attempts {
        if let value = try? readBackendPayload(from: url, as: type) {
            return value
        }
        try await Task.sleep(nanoseconds: intervalMS * 1_000_000)
    }
    return nil
}
