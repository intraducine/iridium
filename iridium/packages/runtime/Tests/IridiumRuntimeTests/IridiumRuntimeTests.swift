import CryptoKit
import Foundation
import IridiumCore
import XCTest

@testable import IridiumRuntime

private struct FixedHostCapabilityProvider: HostCapabilityProvider {
    let snapshotValue: HostCapabilitySnapshot

    func snapshot() async -> HostCapabilitySnapshot {
        snapshotValue
    }
}

private func makeDevelopmentRuntimeExecutor() -> FileSystemRuntimeSessionExecutor {
    let backendClient = DevelopmentRuntimeBackendClient()
    return makeRuntimeExecutor(backendClient: backendClient)
}

private func makeRuntimeExecutor(backendClient: any RuntimeBackendClient)
    -> FileSystemRuntimeSessionExecutor
{
    FileSystemRuntimeSessionExecutor(
        hostController: FileSystemRuntimeHostController(backendClient: backendClient),
        executionMonitor: FileSystemRuntimeExecutionMonitor(backendClient: backendClient),
        telemetryCollector: FileSystemRuntimeTelemetryCollector(backendClient: backendClient)
    )
}

private func makeDevelopmentRuntimeHostTools() -> (
    hostController: FileSystemRuntimeHostController,
    executionMonitor: FileSystemRuntimeExecutionMonitor,
    telemetryCollector: FileSystemRuntimeTelemetryCollector
) {
    let backendClient = DevelopmentRuntimeBackendClient()
    return (
        FileSystemRuntimeHostController(backendClient: backendClient),
        FileSystemRuntimeExecutionMonitor(backendClient: backendClient),
        FileSystemRuntimeTelemetryCollector(backendClient: backendClient)
    )
}

private func makeDevelopmentRuntimeProcessor(
    runtimeConfiguration: RuntimeHostBridgeConfiguration = RuntimeHostBridgeConfiguration()
) -> NativeRuntimeBridgeRequestProcessor {
    NativeRuntimeBridgeRequestProcessor(
        runtimeConfiguration: runtimeConfiguration,
        runtimeBackendClient: DevelopmentRuntimeBackendClient()
    )
}

private func withTemporarilyUnsetEnvironmentVariables<T>(
    _ keys: [String],
    operation: () async throws -> T
) async rethrows -> T {
    let previousValues = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }

    for key in keys {
        unsetenv(key)
    }

    defer {
        for (key, value) in previousValues {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    return try await operation()
}

private func withTemporarilyOverriddenEnvironmentVariables<T>(
    _ overrides: [String: String],
    operation: () async throws -> T
) async rethrows -> T {
    let previousValues = overrides.map { ($0.key, ProcessInfo.processInfo.environment[$0.key]) }

    for (key, value) in overrides {
        setenv(key, value, 1)
    }

    defer {
        for (key, value) in previousValues {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    return try await operation()
}

private let embeddedSmokeExecutionEnvironment = [
    "IRIDIUM_TEST_HARNESS": "1",
    "IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY": "1",
    "IRIDIUM_FEX_IOS_SMOKE_EXECUTION": "1",
    "IRIDIUM_FEX_IOS_SMOKE_GUEST_IMAGE": "1",
]

#if os(macOS)
    private func runShellCommand(_ command: String, currentDirectoryURL: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = currentDirectoryURL

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr =
                String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? ""
            throw NSError(
                domain: "IridiumRuntimeTests.Shell",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Command failed: \(command)\n\(stderr)"]
            )
        }
    }
#endif

private actor FailingRuntimeBackendClient: RuntimeBackendClient {
    func startSession(_ package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate, RuntimeFailure
    > {
        .failure(
            RuntimeFailure(
                code: .runtimeBootFailed,
                reason: "Runtime backend rejected session start.",
                recoverySuggestion: "Check the runtime backend service."
            )
        )
    }

    func latestSessionUpdate(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate?, RuntimeFailure
    > {
        .success(nil)
    }

    func terminalResult(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendTerminalResult?, RuntimeFailure
    > {
        .success(nil)
    }

    func telemetry(for package: RuntimeBackendLaunchPackage) async -> Result<
        PerformanceTelemetrySnapshot?, RuntimeFailure
    > {
        .success(nil)
    }
}

private actor CapturingRuntimeBackendClient: RuntimeBackendClient {
    private var capturedPackage: RuntimeBackendLaunchPackage?

    func startSession(_ package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate, RuntimeFailure
    > {
        capturedPackage = package
        return .success(
            RuntimeBackendSessionUpdate(
                id: package.id,
                state: .queued,
                stateHistory: [.queued],
                statusSummary: "Captured launch package."
            )
        )
    }

    func latestSessionUpdate(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate?, RuntimeFailure
    > {
        .success(
            RuntimeBackendSessionUpdate(
                id: package.id,
                state: .running,
                stateHistory: [.queued, .bootstrappingPrefix, .bootingRuntime, .running],
                statusSummary: "Captured launch package entered running state."
            )
        )
    }

    func terminalResult(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendTerminalResult?, RuntimeFailure
    > {
        .success(
            RuntimeBackendTerminalResult(
                id: package.id,
                terminalStatus: RuntimeHostSessionState.completed.rawValue,
                stateHistory: [
                    .queued, .bootstrappingPrefix, .bootingRuntime, .running, .completed,
                ]
            )
        )
    }

    func telemetry(for package: RuntimeBackendLaunchPackage) async -> Result<
        PerformanceTelemetrySnapshot?, RuntimeFailure
    > {
        .success(nil)
    }

    func lastCapturedPackage() -> RuntimeBackendLaunchPackage? {
        capturedPackage
    }
}

private actor DeferredTerminalRuntimeBackendClient: RuntimeBackendClient {
    func startSession(_ package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate, RuntimeFailure
    > {
        .success(
            RuntimeBackendSessionUpdate(
                id: package.id,
                state: .queued,
                stateHistory: [.queued],
                statusSummary: "Deferred terminal backend accepted the launch package."
            )
        )
    }

    func latestSessionUpdate(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate?, RuntimeFailure
    > {
        .success(
            RuntimeBackendSessionUpdate(
                id: package.id,
                state: .running,
                stateHistory: [.queued, .bootstrappingPrefix, .bootingRuntime, .running],
                statusSummary: "Deferred terminal backend entered shell-free execution."
            )
        )
    }

    func terminalResult(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendTerminalResult?, RuntimeFailure
    > {
        .success(nil)
    }

    func telemetry(for package: RuntimeBackendLaunchPackage) async -> Result<
        PerformanceTelemetrySnapshot?, RuntimeFailure
    > {
        .success(nil)
    }
}

private actor StalledBootingRuntimeBackendClient: RuntimeBackendClient {
    func startSession(_ package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate, RuntimeFailure
    > {
        .success(
            RuntimeBackendSessionUpdate(
                id: package.id,
                state: .queued,
                stateHistory: [.queued],
                statusSummary: "Stalled backend accepted the launch package."
            )
        )
    }

    func latestSessionUpdate(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendSessionUpdate?, RuntimeFailure
    > {
        .success(
            RuntimeBackendSessionUpdate(
                id: package.id,
                state: .bootingRuntime,
                stateHistory: [.queued, .bootstrappingPrefix, .bootingRuntime],
                statusSummary: "Embedded FEX is initializing FEXCore runtime and loading Wine binary."
            )
        )
    }

    func terminalResult(for package: RuntimeBackendLaunchPackage) async -> Result<
        RuntimeBackendTerminalResult?, RuntimeFailure
    > {
        .success(nil)
    }

    func telemetry(for package: RuntimeBackendLaunchPackage) async -> Result<
        PerformanceTelemetrySnapshot?, RuntimeFailure
    > {
        .success(nil)
    }
}

private actor QueuedHandoffRuntimeHostController: RuntimeHostController {
    private var submittedTickets: [RuntimeLaunchTicket] = []

    func submit(ticket: RuntimeLaunchTicket) async -> Result<RuntimeHostSession, RuntimeFailure> {
        submittedTickets.append(ticket)
        return .success(
            RuntimeHostSession(
                id: ticket.id,
                gameID: ticket.gameID,
                gameTitle: ticket.gameTitle,
                launchTicketPath: "/tmp/ticket-\(ticket.id).json",
                sessionLogPath: "/tmp/session-\(ticket.id).log",
                telemetryPath: "/tmp/telemetry-\(ticket.id).json",
                runtimeBundleID: ticket.runtimeBundleID,
                runtimeBundleVersion: ticket.runtimeBundleVersion,
                state: .queued,
                stateHistory: [.queued],
                statusSummary: "Queued handoff host accepted the launch package."
            )
        )
    }

    func submitCount() -> Int {
        submittedTickets.count
    }
}

private actor CountingRuntimeExecutionMonitor: RuntimeExecutionMonitor {
    private var resolveCount = 0

    func resolveTerminalState(for session: RuntimeHostSession) async -> RuntimeHostSession {
        resolveCount += 1
        return RuntimeHostSession(
            id: session.id,
            gameID: session.gameID,
            gameTitle: session.gameTitle,
            launchTicketPath: session.launchTicketPath,
            sessionLogPath: session.sessionLogPath,
            telemetryPath: session.telemetryPath,
            runtimeBundleID: session.runtimeBundleID,
            runtimeBundleVersion: session.runtimeBundleVersion,
            state: .completed,
            stateHistory: [.queued, .bootstrappingPrefix, .bootingRuntime, .running, .completed],
            statusSummary: "Foreground monitor resolved terminal state.",
            startedAt: session.startedAt,
            updatedAt: Date()
        )
    }

    func count() -> Int {
        resolveCount
    }
}

private actor RunningHandoffRuntimeExecutionMonitor: RuntimeExecutionMonitor {
    private var resolveCount = 0

    func resolveTerminalState(for session: RuntimeHostSession) async -> RuntimeHostSession {
        resolveCount += 1
        return RuntimeHostSession(
            id: session.id,
            gameID: session.gameID,
            gameTitle: session.gameTitle,
            launchTicketPath: session.launchTicketPath,
            sessionLogPath: session.sessionLogPath,
            telemetryPath: session.telemetryPath,
            runtimeBundleID: session.runtimeBundleID,
            runtimeBundleVersion: session.runtimeBundleVersion,
            state: .running,
            stateHistory: [.queued, .bootstrappingPrefix, .bootingRuntime, .running],
            statusSummary: "Embedded runtime reported shell-free execution.",
            startedAt: session.startedAt,
            updatedAt: Date()
        )
    }

    func count() -> Int {
        resolveCount
    }
}

private actor BootingThenCompletedRuntimeExecutionMonitor: RuntimeExecutionMonitor {
    private var resolveCount = 0

    func resolveTerminalState(for session: RuntimeHostSession) async -> RuntimeHostSession {
        resolveCount += 1
        let state: RuntimeHostSessionState = resolveCount == 1 ? .bootingRuntime : .completed
        let history: [RuntimeHostSessionState] =
            state == .bootingRuntime
            ? [.queued, .bootstrappingPrefix, .bootingRuntime]
            : [.queued, .bootstrappingPrefix, .bootingRuntime, .running, .completed]
        return RuntimeHostSession(
            id: session.id,
            gameID: session.gameID,
            gameTitle: session.gameTitle,
            launchTicketPath: session.launchTicketPath,
            sessionLogPath: session.sessionLogPath,
            telemetryPath: session.telemetryPath,
            runtimeBundleID: session.runtimeBundleID,
            runtimeBundleVersion: session.runtimeBundleVersion,
            state: state,
            stateHistory: history,
            statusSummary:
                state == .bootingRuntime
                ? "Native embedded Wine server is accepting guest clients."
                : "Runtime process completed.",
            startedAt: session.startedAt,
            updatedAt: Date()
        )
    }

    func count() -> Int {
        resolveCount
    }
}

private actor CountingRuntimeTelemetryCollector: RuntimeTelemetryCollector {
    private var collectCount = 0

    func collect(for session: RuntimeHostSession, policy: RuntimePolicy) async
        -> PerformanceTelemetrySnapshot?
    {
        _ = session
        _ = policy
        collectCount += 1
        return nil
    }

    func count() -> Int {
        collectCount
    }
}

private struct AcceptanceHarnessManifestClient: SteamDepotManifestClient {
    func installPlan(for entry: SteamLibraryEntry, targetPath: String) -> SteamInstallPlan {
        SteamInstallPlan(
            title: entry.title,
            appID: entry.appID,
            targetPath: targetPath,
            primaryExecutable: "SampleBalancedGame.exe",
            contentSets: ["base-game"],
            estimatedInstallSizeGB: 8,
            requiredDiskHeadroomGB: 12,
            verificationSteps: ["Verify imported payload"]
        )
    }

    func manifest(for entry: SteamLibraryEntry) -> SteamManifestResolution {
        SteamManifestResolution(
            title: entry.title,
            appID: entry.appID,
            buildID: "sample-balanced-build",
            branchName: "public",
            depots: [
                SteamDepotManifest(
                    depotID: "1145351",
                    manifestID: "fixture-manifest",
                    label: "Base Game",
                    compressedSizeGB: 7.5,
                    mountedPath: "Game"
                )
            ],
            verificationStages: ["Verify imported payload"]
        )
    }
}

private struct AcceptanceHarnessInstallCoordinator: SteamInstallCoordinator {
    func advance(
        execution: InstallExecutionRecord,
        manifest: SteamManifestResolution
    ) async -> InstallExecutionRecord {
        var updated = execution
        updated.completedDepotIDs = manifest.depots.map(\.depotID)
        updated.depotVerifiedIDs = manifest.depots.map(\.depotID)
        updated.stage = .completed
        updated.detail = "Fixture install completed."
        updated.resumeCheckpoint = "\(manifest.depots.first?.depotID ?? "fixture"):complete"
        updated.lastUpdatedAt = Date()
        return updated
    }
}

private struct FixtureSteamContentServerClient: SteamContentServerClient {
    func transfer(
        depot: SteamDepotManifest,
        into execution: InstallExecutionRecord
    ) async -> (bytesTransferred: Int64, resumeCheckpoint: String) {
        _ = execution
        return (Int64(depot.compressedSizeGB * 1_000_000_000), "\(depot.depotID):complete")
    }
}

private struct FixtureDepotVerificationService: DepotVerificationService {
    func verify(
        execution: InstallExecutionRecord,
        manifest: SteamManifestResolution
    ) async -> InstallExecutionRecord {
        var updated = execution
        updated.depotVerifiedIDs = manifest.depots.map(\.depotID)
        updated.detail = "Fixture verification completed."
        return updated
    }
}

private func waitForFile(at url: URL, attempts: Int = 40, intervalMS: UInt64 = 50) async -> Bool {
    for _ in 0..<attempts {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        try? await Task.sleep(nanoseconds: intervalMS * 1_000_000)
    }
    return false
}

private func makeEmbeddedRuntimeHostLaunchHandler(
    terminalState: RuntimeHostSessionState = .completed
) -> EmbeddedRuntimeHostLaunchHandler {
    { invocation in
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: invocation.sessionUpdateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: invocation.terminalResultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: invocation.telemetryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: invocation.hostLogURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let bundleRoot = invocation.hostBinaryURL.deletingLastPathComponent()
            .deletingLastPathComponent()
        let managedRoot = bundleRoot.deletingLastPathComponent().deletingLastPathComponent()
        let capabilityURL = FileSystemHostCapabilityProvider.capabilityRecordURL(for: managedRoot)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try encoder.encode(
            RuntimeHostCapabilityRecord(
                jitStatus: .ready,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                translatorReady: true,
                runtimeHostVersion: "embedded-test",
                supportedArchitectures: ["x64"],
                supportedGraphicsAPIs: ["opengl"],
                measuredAt: Date()
            )
        ).write(to: capabilityURL)

        try encoder.encode(
            RuntimeBackendSessionUpdate(
                id: invocation.packageID,
                state: .queued,
                stateHistory: [.queued],
                statusSummary: "Embedded runtime host accepted the launch package."
            )
        ).write(to: invocation.sessionUpdateURL)

        try encoder.encode(
            RuntimeBackendTerminalResult(
                id: invocation.packageID,
                terminalStatus: terminalState.rawValue,
                stateHistory: terminalState == .failed
                    ? [.queued, .bootstrappingPrefix, .bootingRuntime, .running, .failed]
                    : [.queued, .bootstrappingPrefix, .bootingRuntime, .running, .completed],
                failureCode: terminalState == .failed
                    ? RuntimeFailureCode.gameProcessExited.rawValue : nil,
                failureReason: terminalState == .failed
                    ? "Embedded runtime host observed a terminal failure." : nil
            )
        ).write(to: invocation.terminalResultURL)

        try encoder.encode(
            PerformanceTelemetrySnapshot(
                averageFPS: 59,
                frameTimeP95MS: 19,
                memoryPressureRatio: 0.44,
                thermalState: .nominal
            )
        ).write(to: invocation.telemetryURL)

        try Data("embedded runtime host\n".utf8).write(to: invocation.hostLogURL)
    }
}

private func makeRuntimeLaunchFixture(root: URL, title: String = "SampleLightweightGame")
    async throws -> (
        game: GameRecord,
        prefix: PrefixRecord,
        runtimeBundle: RuntimeBundleManifest,
        ticket: RuntimeLaunchTicket
    )
{
    let workingDirectory = root.appending(path: "game", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let executableURL = workingDirectory.appending(path: "\(title).exe")
    try Data(title.lowercased().utf8).write(to: executableURL)
    let runtimeRoot = root.appending(path: "RuntimeBundles", directoryHint: .isDirectory)
    let runtimeBundle = try materializeRuntimeBundle(root: runtimeRoot)
    let game = GameRecord(
        title: title,
        source: .manualImport,
        installPath: workingDirectory.path,
        savePathMapping: "Documents/Saves/\(title)",
        compatibilityProfileName: "\(title.lowercased())-default",
        inputProfileName: "Touch + Controller",
        touchOverlayName: "Default Layout",
        controllerPresetName: "Standard Gamepad",
        keyboardMouseEnabled: true,
        prefixState: .clean,
        deviceTier: .tier1,
        rendererPreset: .metalOpenGLFallback,
        launchProfile: GameLaunchProfile(
            executablePath: executableURL.path,
            arguments: [],
            prefixID: UUID(),
            rendererPreset: .metalOpenGLFallback,
            deviceTier: .tier1,
            titleFlags: ["manual-import"]
        ),
        installedSizeGB: 1.2,
        executableFingerprint: try FileSystemGameArtifactInventory().fingerprintExecutable(
            at: executableURL.path
        ).value,
        summary: "Runtime provider test"
    )
    let prefix = PrefixRecord(
        id: game.launchProfile.prefixID,
        name: "\(title) Prefix",
        runtimeName: runtimeBundle.name,
        state: .clean,
        storageFootprint: "2.0 GB",
        storageFootprintGB: 2.0
    )
    let bootstrap = await FileSystemPrefixBootstrapService().bootstrap(
        game: game,
        prefix: prefix,
        runtimeBundle: runtimeBundle,
        policy: RuntimePolicy(
            memoryBudgetClass: .compact,
            resolutionScale: 1.0,
            shaderStrategy: .onDemand
        )
    )
    let prefixManifestPath: String
    switch bootstrap {
    case .success(let payload):
        prefixManifestPath = payload.manifestPath
    case .failure(let failure):
        throw failure
    }

    let ticket = RuntimeLaunchTicket(
        id: UUID().uuidString,
        gameID: UUID(),
        gameTitle: title,
        executablePath: executableURL.path,
        workingDirectory: workingDirectory.path,
        launchArguments: [],
        environment: [
            "IRIDIUM_NO_DESKTOP": "1",
            "IRIDIUM_HOST_JIT_STATUS": "ready",
            "IRIDIUM_RENDERER_PRESET": RendererPreset.metalOpenGLFallback.rawValue,
            "IRIDIUM_RUNTIME_GRAPHICS_STACK": GraphicsStack.metalOpenGLFallback.rawValue,
        ],
        runtimeBundleID: runtimeBundle.id,
        runtimeBundleVersion: runtimeBundle.version,
        prefixID: prefix.id,
        prefixManifestPath: prefixManifestPath
    )

    return (game, prefix, runtimeBundle, ticket)
}

private func makeBackendLaunchPackage(
    from fixture: (
        game: GameRecord,
        prefix: PrefixRecord,
        runtimeBundle: RuntimeBundleManifest,
        ticket: RuntimeLaunchTicket
    )
) throws -> RuntimeBackendLaunchPackage {
    let prefixRoot = URL(fileURLWithPath: fixture.game.installPath, isDirectory: true)
        .appending(
            path: ".iridium/prefixes/\(fixture.prefix.id.uuidString)", directoryHint: .isDirectory)
    let configRoot = prefixRoot.appending(path: "config", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)

    let environmentFileURL = configRoot.appending(path: "runtime.env")
    let runtimeConfigurationURL = configRoot.appending(path: "runtime.json")
    try Data(
        """
        IRIDIUM_NO_DESKTOP=1
        WINEPREFIX=\(prefixRoot.path)
        WINEARCH=win64
        """.utf8
    ).write(to: environmentFileURL)
    try JSONEncoder().encode(
        [
            "rendererPreset": fixture.game.rendererPreset.rawValue,
            "runtimeBundleRootPath": fixture.runtimeBundle.bundleRootPath ?? "",
        ]
    ).write(to: runtimeConfigurationURL)

    return RuntimeBackendLaunchPackage(
        id: fixture.ticket.id,
        gameID: fixture.game.id,
        gameTitle: fixture.game.title,
        executablePath: fixture.ticket.executablePath,
        workingDirectory: fixture.ticket.workingDirectory,
        launchArguments: fixture.ticket.launchArguments,
        environment: fixture.ticket.environment,
        runtimeBundleID: fixture.runtimeBundle.id,
        runtimeBundleVersion: fixture.runtimeBundle.version,
        runtimeBundleRootPath: fixture.runtimeBundle.bundleRootPath ?? "",
        prefixID: fixture.prefix.id,
        prefixManifestPath: fixture.ticket.prefixManifestPath,
        runtimeConfigurationPath: runtimeConfigurationURL.path,
        environmentFilePath: environmentFileURL.path,
        rendererPreset: fixture.game.rendererPreset.rawValue,
        directLaunchOnly: true
    )
}

private let validWineRegistrySeed = """
    WINE REGISTRY Version 2
    #arch=win64

    """

private func minimalExecutableX8664ELFLoader() -> Data {
    var image = Data(count: 0x1001)

    func writeUInt16(_ value: UInt16, at offset: Int) {
        image[offset] = UInt8(value & 0xff)
        image[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    func writeUInt32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 {
            image[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff)
        }
    }

    func writeUInt64(_ value: UInt64, at offset: Int) {
        for index in 0..<8 {
            image[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff)
        }
    }

    image[0] = 0x7f
    image[1] = 0x45
    image[2] = 0x4c
    image[3] = 0x46
    image[4] = 0x02
    image[5] = 0x01
    image[6] = 0x01

    writeUInt16(3, at: 16)
    writeUInt16(0x3E, at: 18)
    writeUInt32(1, at: 20)
    writeUInt64(0x1000, at: 24)
    writeUInt64(0x40, at: 32)
    writeUInt16(0x40, at: 52)
    writeUInt16(0x38, at: 54)
    writeUInt16(2, at: 56)

    writeUInt32(1, at: 0x40)
    writeUInt32(0x4, at: 0x44)
    writeUInt64(0x100, at: 0x60)
    writeUInt64(0x100, at: 0x68)
    writeUInt64(0x1000, at: 0x70)

    writeUInt32(1, at: 0x78)
    writeUInt32(0x5, at: 0x7c)
    writeUInt64(0x1000, at: 0x80)
    writeUInt64(0x1000, at: 0x88)
    writeUInt64(1, at: 0x98)
    writeUInt64(1, at: 0xa0)
    writeUInt64(0x1000, at: 0xa8)

    image[0x1000] = 0xC3

    return image
}

private func writeEmbeddedWineUserlandRoot(
    at root: URL,
    wineScript: String? = nil,
    marker: String? = nil
) throws {
    let binRoot = root.appending(path: "bin", directoryHint: .isDirectory)
    let shareRoot = root.appending(path: "share/wine", directoryHint: .isDirectory)
    let nlsRoot = shareRoot.appending(path: "nls", directoryHint: .isDirectory)
    let libRoot = root.appending(path: "lib/wine", directoryHint: .isDirectory)
    let embeddedLoaderRoot = root.appending(
        path: "lib/wine/x86_64-unix", directoryHint: .isDirectory)
    let windowsDllRoot = root.appending(
        path: "lib/wine/x86_64-windows", directoryHint: .isDirectory)
    let prefixSeedRoot = root.appending(path: "prefix-seed", directoryHint: .isDirectory)

    try FileManager.default.createDirectory(at: binRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: shareRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nlsRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: libRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: embeddedLoaderRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: windowsDllRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: prefixSeedRoot, withIntermediateDirectories: true)

    let embeddedLoader = minimalExecutableX8664ELFLoader()
    try embeddedLoader.write(to: embeddedLoaderRoot.appending(path: "wine-preloader"))
    try embeddedLoader.write(to: embeddedLoaderRoot.appending(path: "wine"))
    try Data("dll".utf8).write(to: libRoot.appending(path: "builtin.dll"))
    try Data("dll".utf8).write(to: windowsDllRoot.appending(path: "kernel32.dll"))
    try Data("dll".utf8).write(to: windowsDllRoot.appending(path: "kernelbase.dll"))
    try Data("intl".utf8).write(to: nlsRoot.appending(path: "l_intl.nls"))

    let effectiveWineScript =
        wineScript
            ?? """
            #!/bin/sh
            if [ -n "${IRIDIUM_TEST_OUTPUT_FILE:-}" ]; then
              printf 'wine=stub\n' > "$IRIDIUM_TEST_OUTPUT_FILE"
            fi
            exit 0
            """
    for relativePath in ["bin/wine64", "bin/wine", "wine64", "wine"] {
        let wineURL = root.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: wineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(effectiveWineScript.utf8).write(to: wineURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wineURL.path)
    }

    let wineserverURL = binRoot.appending(path: "wineserver")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wineserverURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: wineserverURL.path)

    try Data(validWineRegistrySeed.utf8).write(to: prefixSeedRoot.appending(path: "system.reg"))
    try Data(validWineRegistrySeed.utf8).write(to: prefixSeedRoot.appending(path: "user.reg"))
    try Data(validWineRegistrySeed.utf8).write(to: prefixSeedRoot.appending(path: "userdef.reg"))

    if let marker {
        try Data("marker=\(marker)\n".utf8).write(to: root.appending(path: "MARKER.txt"))
    }
}

private func makeExplicitWineUserlandRoot(
    under root: URL,
    relativePath: String = "explicit-userland",
    wineScript: String? = nil,
    marker: String? = nil
) throws -> URL {
    let userlandRoot = root.appending(path: relativePath, directoryHint: .isDirectory)
    try writeEmbeddedWineUserlandRoot(
        at: userlandRoot,
        wineScript: wineScript,
        marker: marker
    )
    return userlandRoot
}

private func writeStagedWineUserlandRoot(
    for runtimeBundle: RuntimeBundleManifest,
    relativePath: String = "Userland/root",
    wineScript: String? = nil,
    marker: String? = nil
) throws -> URL {
    let bundleRoot = URL(
        fileURLWithPath: runtimeBundle.bundleRootPath ?? "", isDirectory: true
    )
    let userlandRoot = bundleRoot.appending(path: relativePath, directoryHint: .isDirectory)
    try writeEmbeddedWineUserlandRoot(
        at: userlandRoot,
        wineScript: wineScript,
        marker: marker
    )
    return userlandRoot
}

private func materializeRuntimeBundle(
    root runtimeRoot: URL,
    bundleID: String = "iridium-runtime-base",
    includeStagedOpenGLBackendPayload: Bool = false
) throws -> RuntimeBundleManifest {
    try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
    let bundleRoot = runtimeRoot.appending(path: bundleID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
    let runtimeBundleVersion = FileSystemRuntimeBundleRegistry.defaultManifest.version

    let runtimeHostFixture = """
        #!/usr/bin/env python3
        import argparse
        import json
        import pathlib
        import time

        parser = argparse.ArgumentParser()
        parser.add_argument("--launch-package", required=True)
        parser.add_argument("--session-update", required=True)
        parser.add_argument("--terminal-result", required=True)
        parser.add_argument("--telemetry", required=True)
        parser.add_argument("--host-log", required=True)
        args = parser.parse_args()

        with open(args.launch_package, "r", encoding="utf-8") as handle:
            package = json.load(handle)

        environment = package.get("environment", {})
        should_crash = environment.get("IRIDIUM_FORCE_CRASH") == "1"
        omit_telemetry = environment.get("IRIDIUM_BACKEND_NO_TELEMETRY") == "1"

        pathlib.Path(args.session_update).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.terminal_result).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.telemetry).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.host_log).parent.mkdir(parents=True, exist_ok=True)

        def write_json(path: str, payload: dict) -> None:
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2, sort_keys=True)

        with open(args.host_log, "a", encoding="utf-8") as log_handle:
            log_handle.write(f"launch-package={args.launch_package}\\n")
            log_handle.write(f"game={package.get('gameTitle')}\\n")

        write_json(
            args.session_update,
            {
                "failureCode": None,
                "failureReason": None,
                "id": package["id"],
                "state": "queued",
                "stateHistory": ["queued"],
                "statusSummary": "Bundled runtime host accepted the launch package.",
                "updatedAt": 0
            }
        )

        time.sleep(0.05)

        running_history = ["queued", "bootstrappingPrefix", "bootingRuntime", "running"]
        write_json(
            args.session_update,
            {
                "failureCode": None,
                "failureReason": None,
                "id": package["id"],
                "state": "running",
                "stateHistory": running_history,
                "statusSummary": "Bundled runtime host entered shell-free execution.",
                "updatedAt": 1
            }
        )

        if not omit_telemetry:
            write_json(
                args.telemetry,
                {
                    "averageFPS": 60,
                    "frameTimeP95MS": 18,
                    "memoryPressureRatio": 0.42,
                    "thermalState": "nominal"
                }
            )

        terminal_state = "failed" if should_crash else "completed"
        terminal_history = running_history + [terminal_state]
        write_json(
            args.terminal_result,
            {
                "failureCode": "gameProcessExited" if should_crash else None,
                "failureReason": "Bundled runtime host reported that the game process exited after startup." if should_crash else None,
                "id": package["id"],
                "reportedAt": 2,
                "stateHistory": terminal_history,
                "terminalStatus": terminal_state
            }
        )
        """

    let userlandArchiveURL = bundleRoot.appending(path: "Userland/wine-userland.tar.zst")
    try writeValidUserlandArchive(
        to: userlandArchiveURL,
        root: runtimeRoot.appending(
            path: "\(bundleID)-userland-source", directoryHint: .isDirectory)
    )
    if includeStagedOpenGLBackendPayload {
        let unixWineRoot = bundleRoot.appending(
            path: "Support/wine-userland/lib/wine/x86_64-unix",
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: unixWineRoot,
            withIntermediateDirectories: true)
        try Data("wineios".utf8).write(to: unixWineRoot.appending(path: "wineios.so"))
        try Data("ELF egl_handle eglGetProcAddress".utf8).write(
            to: unixWineRoot.appending(path: "opengl32.so"))
        try Data("ELF libEGL.so.1 eglGetProcAddress".utf8).write(
            to: unixWineRoot.appending(path: "win32u.so"))
    }

    let artifacts:
        [(identifier: String, relativePath: String, kind: RuntimeArtifactKind, contents: Data?)] = [
            (
                "runtime-host-binary", "Runtime/runtime-host.bin", .runtimeBinary,
                Data(runtimeHostFixture.utf8)
            ),
            (
                "x64-jit-translator", "Translator/x64-jit.bin", .translationLayer,
                Data("jit-translator".utf8)
            ),
            ("wine-userland", "Userland/wine-userland.tar.zst", .userlandPayload, nil),
            (
                "vkd3d-stack", "Graphics/vkd3d-stack.json", .graphicsStack,
                Data("{\"stack\":\"vkd3d\"}\n".utf8)
            ),
            (
                "ios-presentation-backend",
                "Graphics/ios-presentation-backend.json",
                .graphicsStack,
                Data("{\"presentable\":true,\"supportedGraphicsAPIs\":[\"opengl\"]}\n".utf8)
            ),
            (
                "direct-launch-profile",
                "Metadata/direct-launch.json",
                .metadata,
                Data(
                    """
                    {"blockedEntryPoints":["explorer.exe","cmd.exe","powershell.exe","steam.exe"],"directLaunchOnly":true,"supportsArchitectures":["x64"]}
                    \n
                    """.utf8
                )
            ),
        ]

    let manifestArtifacts = try artifacts.map { artifact -> RuntimeArtifact in
        let artifactURL = bundleRoot.appending(path: artifact.relativePath)
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents: Data
        if let artifactContents = artifact.contents {
            try artifactContents.write(to: artifactURL)
            contents = artifactContents
        } else {
            contents = try Data(contentsOf: artifactURL)
        }
        if artifact.identifier == "runtime-host-binary" {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: artifactURL.path)
        }
        return RuntimeArtifact(
            identifier: artifact.identifier,
            relativePath: artifact.relativePath,
            sizeBytes: Int64(contents.count),
            checksum: SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined(),
            kind: artifact.kind
        )
    }

    let manifest = RuntimeBundleManifest(
        id: bundleID,
        name: "Iridium Runtime Base",
        version: runtimeBundleVersion,
        descriptor: .defaultDescriptor,
        artifacts: manifestArtifacts,
        minimumDeviceTier: .tier1,
        supportsDirectGameLaunch: true,
        bundleRootPath: bundleRoot.path,
        supportMetadata: [
            "bundleSource": "managed-storage",
            "engineFamily": "wine-derived",
            "launchMode": "direct-executable-only",
            "runtimeHostContractVersion": "1",
            "supportedArchitectures": "x64",
            "supportedGraphicsAPIs": "opengl",
            "translatorBackend": "fex-derived",
        ]
    )

    let manifestURL = bundleRoot.appending(path: "manifest.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: manifestURL)
    return manifest
}

private func writeValidUserlandArchive(
    to archiveURL: URL,
    root sourceRoot: URL,
    wineScript: String = """
    #!/bin/sh
    exit 0
    """,
    marker: String? = nil
) throws {
    try FileManager.default.createDirectory(
        at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeEmbeddedWineUserlandRoot(
        at: sourceRoot,
        wineScript: wineScript == "#!/bin/sh\nexit 0\n" ? nil : wineScript,
        marker: marker
    )

    #if os(macOS)
        let tarPath = archiveURL.deletingPathExtension()
        try runShellCommand(
            """
            if command -v zstd >/dev/null 2>&1; then
              ZSTD="$(command -v zstd)"
            elif [ -x /opt/local/bin/zstd ]; then
              ZSTD=/opt/local/bin/zstd
            else
              echo "zstd not found" >&2
              exit 127
            fi
            tar -C '\(sourceRoot.path)' -cf '\(tarPath.path)' . && \
            "$ZSTD" -f -q '\(tarPath.path)' -o '\(archiveURL.path)' && \
            rm -f '\(tarPath.path)'
            """
        )
    #else
        // Simulator and non-macOS test targets only need a stable placeholder archive.
        try Data("placeholder-userland-archive\n".utf8).write(to: archiveURL)
    #endif
}

private func fakeX8664ELFBinary() -> Data {
    var bytes = Array(repeating: UInt8(0), count: 64)
    bytes[0] = 0x7f
    bytes[1] = 0x45
    bytes[2] = 0x4c
    bytes[3] = 0x46
    bytes[4] = 0x02
    bytes[5] = 0x01
    bytes[18] = 0x3e
    bytes[19] = 0x00
    return Data(bytes)
}

private func writePlayableUserlandRoot(at root: URL) throws {
    let unixWineRoot = root.appending(
        path: "lib/wine/x86_64-unix", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: unixWineRoot,
        withIntermediateDirectories: true)
    try fakeX8664ELFBinary().write(to: unixWineRoot.appending(path: "wine"))
    try Data("wineios".utf8).write(to: unixWineRoot.appending(path: "wineios.so"))
    try Data("ELF egl_handle eglGetProcAddress".utf8).write(
        to: unixWineRoot.appending(path: "opengl32.so"))
    try Data("ELF libEGL.so.1 eglGetProcAddress".utf8).write(
        to: unixWineRoot.appending(path: "win32u.so"))
}

private func fakeX8664ELFBinaryWithProgramInterpreter() -> Data {
    let interpreter = Array("/lib64/ld-linux-x86-64.so.2\0".utf8)
    var bytes = Array(repeating: UInt8(0), count: 160)
    bytes[0] = 0x7f
    bytes[1] = 0x45
    bytes[2] = 0x4c
    bytes[3] = 0x46
    bytes[4] = 0x02
    bytes[5] = 0x01
    bytes[16] = 0x02
    bytes[18] = 0x3e
    bytes[32] = 0x40
    bytes[52] = 0x40
    bytes[54] = 0x38
    bytes[56] = 0x01
    bytes[64] = 0x03
    bytes[72] = 0x80
    bytes[96] = UInt8(interpreter.count)
    bytes[104] = UInt8(interpreter.count)
    for (index, byte) in interpreter.enumerated() {
        bytes[128 + index] = byte
    }
    return Data(bytes)
}

private func fakeMachOBinary() -> Data {
    Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01])
}

private func fakeCodeSignedMachOBinary(
    codeByte: UInt8 = 0xa5,
    linkeditSize: UInt64 = 0x4000,
    signature: [UInt8]
) -> Data {
    let signatureOffset = 160
    var data = Data(count: signatureOffset + signature.count)

    func writeUInt32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 {
            data[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff)
        }
    }

    func writeUInt64(_ value: UInt64, at offset: Int) {
        for index in 0..<8 {
            data[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff)
        }
    }

    writeUInt32(0xfeed_facf, at: 0)
    writeUInt32(2, at: 16)
    writeUInt32(88, at: 20)
    writeUInt32(0x19, at: 32)
    writeUInt32(72, at: 36)
    data.replaceSubrange(40..<50, with: Data("__LINKEDIT".utf8))
    writeUInt64(linkeditSize, at: 64)
    writeUInt64(UInt64(signatureOffset), at: 72)
    writeUInt64(linkeditSize, at: 80)
    writeUInt32(0x1d, at: 104)
    writeUInt32(16, at: 108)
    writeUInt32(UInt32(signatureOffset), at: 112)
    writeUInt32(UInt32(signature.count), at: 116)
    data[128] = codeByte
    data.replaceSubrange(signatureOffset..<data.count, with: signature)
    return data
}

final class IridiumRuntimeTests: XCTestCase {
    func testCodeSignatureInvariantMachOChecksumIgnoresOnlySignatureReplacement() throws {
        let original = fakeCodeSignedMachOBinary(signature: [1, 2, 3, 4])
        let resigned = fakeCodeSignedMachOBinary(
            linkeditSize: 0x2000,
            signature: [9, 8, 7, 6, 5, 4]
        )
        let tampered = fakeCodeSignedMachOBinary(codeByte: 0xff, signature: [9, 8, 7, 6, 5, 4])

        XCTAssertEqual(
            codeSignatureInvariantMachOChecksum(original),
            codeSignatureInvariantMachOChecksum(resigned)
        )
        XCTAssertNotEqual(
            codeSignatureInvariantMachOChecksum(original),
            codeSignatureInvariantMachOChecksum(tampered)
        )
    }

    func testBridgeAndProviderConfigurationsFollowConfiguredIridiumRoot() {
        let configuredRoot = URL(fileURLWithPath: "/tmp/iridium-runtime-root", isDirectory: true)
        let environment = [IridiumDeploymentPaths.rootEnvironmentKey: configuredRoot.path]

        let runtimeBridge = RuntimeHostBridgeConfiguration(
            environment: environment,
            infoDictionary: nil
        )
        let steamBridge = SteamBridgeConfiguration(
            environment: environment,
            infoDictionary: nil
        )
        let provider = RuntimeProviderConfiguration(
            environment: environment,
            infoDictionary: nil
        )
        let sessionStore = FileSystemSteamSessionStore(
            environment: environment,
            infoDictionary: nil
        )

        XCTAssertEqual(
            runtimeBridge.rootURL,
            configuredRoot.appending(path: "NativeBridge/RuntimeHost", directoryHint: .isDirectory)
        )
        XCTAssertEqual(
            steamBridge.rootURL,
            configuredRoot.appending(path: "NativeBridge/Steam", directoryHint: .isDirectory)
        )
        XCTAssertEqual(
            provider.rootURL,
            configuredRoot.appending(path: "RuntimeProvider", directoryHint: .isDirectory)
        )

        let persistedSession = SteamSessionRecord(accountName: "configured@steam")
        let expectation = expectation(description: "persist session in configured root")
        Task {
            await sessionStore.persistSession(persistedSession)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    configuredRoot
                    .appending(path: "SteamSessions", directoryHint: .isDirectory)
                    .appending(path: "\(persistedSession.id).json")
                    .path
            )
        )
    }

    func testDefaultRuntimeNeverExposesDesktopShell() {
        XCTAssertFalse(BundledRuntimeCatalog.defaultRuntime.exposesDesktopShell)
    }

    func testHostCapabilityProviderDetectsProvisionedRuntimeBundleAndHostCapabilityRecord()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedRoot = root.appending(path: "Managed", directoryHint: .isDirectory)
        let runtimeRoot = managedRoot.appending(path: "Runtime", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let hostCapabilitiesURL = FileSystemHostCapabilityProvider.capabilityRecordURL(
            for: managedRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(
            RuntimeHostCapabilityRecord(
                jitStatus: .ready,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                presentationReadiness: RuntimeSubsystemReadiness(
                    ready: false,
                    status: "presentationServiceMissing",
                    statusSummary:
                        "Runtime host does not provide an iOS presentation service for guest windows yet."
                ),
                inputReadiness: RuntimeSubsystemReadiness(
                    ready: false,
                    status: "inputBridgeMissing",
                    statusSummary:
                        "Runtime host does not provide an iOS input bridge for guest events yet."
                ),
                audioReadiness: RuntimeSubsystemReadiness(
                    ready: false,
                    status: "audioBridgeMissing",
                    statusSummary:
                        "Runtime host does not provide an iOS audio bridge for guest output yet."
                ),
                translatorReady: true,
                runtimeHostVersion: "0.1.0-dev",
                supportedArchitectures: ["x64"],
                supportedGraphicsAPIs: ["opengl"],
                measuredAt: Date()
            )
        ).write(to: hostCapabilitiesURL)
        _ = try materializeRuntimeBundle(root: runtimeRoot)

        let registry = FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot)

        let snapshot = await FileSystemHostCapabilityProvider(
            runtimeBundleRegistry: registry,
            managedRootURL: managedRoot
        ).snapshot()

        XCTAssertEqual(snapshot.jitStatus, .ready)
        XCTAssertEqual(snapshot.deviceCapabilityClass, .balanced)
        XCTAssertEqual(snapshot.deviceTier, .tier2)
        XCTAssertEqual(snapshot.selectedRuntimeBundle?.id, "iridium-runtime-base")
        XCTAssertFalse(snapshot.runtimeBundles.isEmpty)
        XCTAssertEqual(snapshot.presentationReadiness?.ready, false)
        XCTAssertEqual(snapshot.inputReadiness?.ready, false)
        XCTAssertEqual(snapshot.audioReadiness?.ready, false)
        XCTAssertTrue(
            snapshot.constraints.contains(
                "Runtime host does not provide an iOS presentation service for guest windows yet."
            )
        )
    }

    func testNativeRuntimePlayerRegistryDrivesFilesystemPlayabilityReadiness() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let managedRoot = root.appending(path: "Managed", directoryHint: .isDirectory)
        let runtimeRoot = managedRoot.appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBundle = try materializeRuntimeBundle(
            root: runtimeRoot,
            includeStagedOpenGLBackendPayload: true)
        let registry = NativeRuntimePlayerServiceRegistry()
        let hostLogURL = root.appending(path: "player-session.log")
        let reservation = RuntimePlayerReservation(
            sessionIdentifier: "player-session",
            runtimeBundleRootPath: runtimeBundle.bundleRootPath ?? "",
            hostLogPath: hostLogURL.path,
            services: [
                RuntimePlayerServiceDescriptor(kind: .render, handle: "surface.player"),
                RuntimePlayerServiceDescriptor(kind: .input, handle: "input.player"),
                RuntimePlayerServiceDescriptor(kind: .audio, handle: "audio.player"),
            ]
        )

        await withTemporarilyOverriddenEnvironmentVariables([
            "IRIDIUM_HOST_JIT_STATUS": "ready",
            "IRIDIUM_FEX_IOS_SMOKE_EXECUTION": "1",
        ]) {
            switch registry.reserve(reservation) {
            case .success:
                break
            case .failure(let failure):
                XCTFail("Expected playable session reservation to succeed, got \(failure)")
            }

            for service in RuntimePlayerServiceKind.allCases {
                switch registry.setServiceLiveness(
                    sessionIdentifier: reservation.sessionIdentifier,
                    serviceKind: service,
                    isLive: true
                ) {
                case .success:
                    break
                case .failure(let failure):
                    XCTFail("Expected \(service.rawValue) service liveness to succeed, got \(failure)")
                }
            }

            let snapshot = await FileSystemHostCapabilityProvider(
                runtimeBundleRegistry: FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot),
                managedRootURL: managedRoot
            ).snapshot()

            XCTAssertEqual(snapshot.launchReady, true)
            XCTAssertEqual(snapshot.playabilityReady, true)
            XCTAssertEqual(snapshot.presentationReadiness?.status, "ready")
            XCTAssertEqual(snapshot.inputReadiness?.status, "ready")
            XCTAssertEqual(snapshot.audioReadiness?.status, "ready")

            registry.release(sessionIdentifier: reservation.sessionIdentifier)

            let releasedSnapshot = await FileSystemHostCapabilityProvider(
                runtimeBundleRegistry: FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot),
                managedRootURL: managedRoot
            ).snapshot()

            XCTAssertEqual(releasedSnapshot.playabilityReady, false)
            XCTAssertEqual(releasedSnapshot.presentationReadiness?.status, "presentationServiceMissing")
        }
    }

    func testNativeRuntimePlayerRegistryUsesReservationUserlandRootForPlayabilityReadiness()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let managedRoot = root.appending(path: "Managed", directoryHint: .isDirectory)
        let runtimeRoot = managedRoot.appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBundle = try materializeRuntimeBundle(root: runtimeRoot)
        let appStagedUserlandRoot = root.appending(
            path: "IridiumWineUserland", directoryHint: .isDirectory)
        try writePlayableUserlandRoot(at: appStagedUserlandRoot)

        let registry = NativeRuntimePlayerServiceRegistry()
        let hostLogURL = root.appending(path: "player-session.log")
        let reservation = RuntimePlayerReservation(
            sessionIdentifier: "player-session",
            runtimeBundleRootPath: runtimeBundle.bundleRootPath ?? "",
            userlandRootPath: appStagedUserlandRoot.path,
            hostLogPath: hostLogURL.path,
            services: [
                RuntimePlayerServiceDescriptor(kind: .render, handle: "surface.player"),
                RuntimePlayerServiceDescriptor(kind: .input, handle: "input.player"),
                RuntimePlayerServiceDescriptor(kind: .audio, handle: "audio.player"),
            ]
        )

        await withTemporarilyOverriddenEnvironmentVariables([
            "IRIDIUM_HOST_JIT_STATUS": "ready",
            "IRIDIUM_FEX_IOS_SMOKE_EXECUTION": "1",
        ]) {
            switch registry.reserve(reservation) {
            case .success:
                break
            case .failure(let failure):
                XCTFail("Expected playable session reservation to succeed, got \(failure)")
            }

            for service in RuntimePlayerServiceKind.allCases {
                switch registry.setServiceLiveness(
                    sessionIdentifier: reservation.sessionIdentifier,
                    serviceKind: service,
                    isLive: true
                ) {
                case .success:
                    break
                case .failure(let failure):
                    XCTFail("Expected \(service.rawValue) service liveness to succeed, got \(failure)")
                }
            }

            let snapshot = await FileSystemHostCapabilityProvider(
                runtimeBundleRegistry: FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot),
                managedRootURL: managedRoot
            ).snapshot()

            XCTAssertEqual(snapshot.playabilityReady, true)
            XCTAssertEqual(snapshot.presentationReadiness?.status, "ready")

            registry.release(sessionIdentifier: reservation.sessionIdentifier)
        }
    }

    func testHostCapabilityProviderSurfacesUnavailableEmbeddedLaunchSupport() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedRoot = root.appending(path: "Managed", directoryHint: .isDirectory)
        let runtimeRoot = managedRoot.appending(path: "Runtime", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let hostCapabilitiesURL = FileSystemHostCapabilityProvider.capabilityRecordURL(
            for: managedRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(
            RuntimeHostCapabilityRecord(
                jitStatus: .ready,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                launchReady: false,
                launchStatus: "bootstrapMissing",
                launchStatusSummary:
                    "Embedded FEX build does not include the FEXCore runtime bootstrap.",
                translatorReady: false,
                runtimeHostVersion: "0.1.0-dev",
                supportedArchitectures: ["x64"],
                supportedGraphicsAPIs: ["opengl"],
                measuredAt: Date()
            )
        ).write(to: hostCapabilitiesURL)
        _ = try materializeRuntimeBundle(root: runtimeRoot)

        let registry = FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot)

        let snapshot = await FileSystemHostCapabilityProvider(
            runtimeBundleRegistry: registry,
            managedRootURL: managedRoot
        ).snapshot()

        XCTAssertEqual(snapshot.launchReady, false)
        XCTAssertEqual(snapshot.launchStatus, "bootstrapMissing")
        XCTAssertEqual(
            snapshot.launchStatusSummary,
            "Embedded FEX build does not include the FEXCore runtime bootstrap."
        )
        XCTAssertTrue(
            snapshot.constraints.contains(
                "Embedded FEX build does not include the FEXCore runtime bootstrap."))
    }

    func testHostCapabilityProviderDowngradesUnverifiedDebuggerBackedRecordToBootstrapReady()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedRoot = root.appending(path: "Managed", directoryHint: .isDirectory)
        let runtimeRoot = managedRoot.appending(path: "Runtime", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let hostCapabilitiesURL = FileSystemHostCapabilityProvider.capabilityRecordURL(
            for: managedRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(
            RuntimeHostCapabilityRecord(
                jitStatus: .ready,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                launchReady: true,
                launchStatus: "ready",
                launchStatusSummary: "Runtime ready.",
                allocatorBackend: "debugger-mirrored-rx-rw",
                jitSessionKind: .debuggerBacked,
                jitFailureStage: "execution probe skipped under xcode debugger",
                jitToolRecommendation: JITToolRecommendation.none,
                jitToolBootstrapRequired: false,
                jitToolBootstrapKind: nil,
                jitToolBootstrapSummary: nil,
                jitSummary: "Runtime ready.",
                exceptionPortsActive: false,
                translatorReady: true,
                runtimeHostVersion: "0.1.0-dev",
                supportedArchitectures: ["x64"],
                supportedGraphicsAPIs: ["opengl"],
                measuredAt: Date()
            )
        ).write(to: hostCapabilitiesURL)
        _ = try materializeRuntimeBundle(root: runtimeRoot)

        let snapshot = await withTemporarilyUnsetEnvironmentVariables(
            ["SIMULATOR_DEVICE_NAME", "XCODE_RUNNING_FOR_PREVIEWS", "__XCODE_BUILT_PRODUCTS_DIR_PATHS"]
        ) {
            await FileSystemHostCapabilityProvider(
                runtimeBundleRegistry: FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot),
                managedRootURL: managedRoot,
                infoDictionary: [RuntimeBackendSelection.modeInfoDictionaryKey: "bundled"],
                nativeJITAvailabilityProbe: { _ in true }
            ).snapshot()
        }

        XCTAssertEqual(snapshot.jitStatus, .ready)
        XCTAssertEqual(snapshot.launchReady, true)
        XCTAssertEqual(snapshot.launchStatus, "bootstrapReady")
        XCTAssertEqual(
            snapshot.launchStatusSummary,
            "JIT and embedded bootstrap are ready; Wine server, Windows process, and first-frame milestones are not yet verified."
        )
        XCTAssertFalse(snapshot.usesLightweightDebuggerCheck)
        XCTAssertFalse(
            snapshot.constraints.contains(
                "Xcode-attached JIT checks use lightweight debugger detection only. Direct launch stays blocked until the embedded runtime backend is validated outside the Xcode check flow."
            )
        )
    }

    func testHostCapabilityProviderMarksNativeRuntimeJITReadyWhenExternalDebuggerProbeSucceeds()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedRoot = root.appending(path: "Managed", directoryHint: .isDirectory)
        let runtimeRoot = managedRoot.appending(path: "Runtime", directoryHint: .isDirectory)
        _ = try materializeRuntimeBundle(root: runtimeRoot)

        let snapshot = await withTemporarilyUnsetEnvironmentVariables(["SIMULATOR_DEVICE_NAME"])
        {
            await FileSystemHostCapabilityProvider(
                runtimeBundleRegistry: FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot),
                managedRootURL: managedRoot,
                infoDictionary: [RuntimeBackendSelection.modeInfoDictionaryKey: "bundled"],
                nativeJITAvailabilityProbe: { _ in true }
            ).snapshot()
        }

        XCTAssertEqual(snapshot.executionEnvironment, .nativeRuntime)
        XCTAssertEqual(snapshot.jitStatus, .ready)
    }

    func testHostCapabilityProviderRequiresCapabilityRecordForNativeRuntimeJITReady()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        _ = try materializeRuntimeBundle(root: runtimeRoot)

        let snapshot = await withTemporarilyUnsetEnvironmentVariables(["SIMULATOR_DEVICE_NAME"])
        {
            await FileSystemHostCapabilityProvider(
                runtimeBundleRegistry: FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot),
                managedRootURL: nil,
                infoDictionary: [RuntimeBackendSelection.modeInfoDictionaryKey: "bundled"],
                nativeJITAvailabilityProbe: { _ in true }
            ).snapshot()
        }

        XCTAssertEqual(snapshot.executionEnvironment, .nativeRuntime)
        XCTAssertEqual(snapshot.jitStatus, .required)
    }

    func testHostCapabilityProviderIgnoresXcodeDebugLaunchesForNativeRuntimeFallback() async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedRoot = root.appending(path: "Managed", directoryHint: .isDirectory)
        let runtimeRoot = managedRoot.appending(path: "Runtime", directoryHint: .isDirectory)
        _ = try materializeRuntimeBundle(root: runtimeRoot)

        let snapshot = await withTemporarilyUnsetEnvironmentVariables(["SIMULATOR_DEVICE_NAME"])
        {
            await FileSystemHostCapabilityProvider(
                runtimeBundleRegistry: FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot),
                managedRootURL: managedRoot,
                processInfo: .processInfo,
                infoDictionary: [RuntimeBackendSelection.modeInfoDictionaryKey: "bundled"],
                nativeJITAvailabilityProbe: { environment in
                    FileSystemHostCapabilityProvider.detectNativeJITAvailability(
                        environment: environment)
                }
            ).snapshot()
        }

        XCTAssertEqual(snapshot.executionEnvironment, .nativeRuntime)
        XCTAssertEqual(snapshot.jitStatus, .required)
    }

    func testDetectNativeJITAvailabilityAcceptsDetachedDebugSignedProcess() {
        XCTAssertTrue(
            FileSystemHostCapabilityProvider.evaluateNativeJITAvailability(
                environment: [:],
                processIsBeingTraced: false,
                processCodeSigningFlags: 0x1000_0000
            )
        )
    }

    func testDetectNativeJITAvailabilityAcceptsTracedDebugSignedProcess() {
        XCTAssertTrue(
            FileSystemHostCapabilityProvider.evaluateNativeJITAvailability(
                environment: [:],
                processIsBeingTraced: true,
                processCodeSigningFlags: 0x1000_0000
            )
        )
    }

    func testHostCapabilityProviderKeepsMacOSInDevelopmentFallbackWithoutNativeBackendOverride()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedRoot = root.appending(path: "Managed", directoryHint: .isDirectory)
        let runtimeRoot = managedRoot.appending(path: "Runtime", directoryHint: .isDirectory)
        _ = try materializeRuntimeBundle(root: runtimeRoot)

        let snapshot = await FileSystemHostCapabilityProvider(
            runtimeBundleRegistry: FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot),
            managedRootURL: managedRoot
        ).snapshot()

        #if os(macOS)
            XCTAssertEqual(snapshot.executionEnvironment, .macOSDevelopmentFallback)
        #else
            XCTAssertNotEqual(snapshot.executionEnvironment, .macOSDevelopmentFallback)
        #endif
    }

    func testNativeJITAvailabilityTreatsPrivateEntitlementPathAsReady() {
        XCTAssertTrue(
            FileSystemHostCapabilityProvider.evaluateNativeJITAvailability(
                environment: [:],
                processIsBeingTraced: false,
                processCodeSigningFlags: nil,
                privateEntitlementJITAvailable: true
            )
        )
    }

    func testNativeJITAvailabilityRejectsXcodeLaunchEvenWhenDebugSignalsArePresent() {
        XCTAssertFalse(
            FileSystemHostCapabilityProvider.evaluateNativeJITAvailability(
                environment: ["__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/tmp/xcode-products"],
                processIsBeingTraced: true,
                processCodeSigningFlags: 0x1000_0000
            )
        )
    }

    func testRuntimeBundleRegistryProvisionsBundledRuntimeIntoManagedStorage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "RuntimeBundles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)

        let registry = FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot)

        XCTAssertTrue(try registry.availableBundles().isEmpty)
        let provisioned = try registry.provisionDefaultBundle()

        XCTAssertEqual(provisioned.id, "iridium-runtime-base")
        XCTAssertEqual(provisioned.supportMetadata["bundleSource"], "managed-storage")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    runtimeRoot
                    .appending(path: "\(provisioned.id)/manifest.json")
                    .path
            )
        )
        XCTAssertFalse(try registry.availableBundles().isEmpty)
    }

    func testRuntimeBundleRegistryProvisionIsIdempotentForMatchingVersion() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "RuntimeBundles", directoryHint: .isDirectory)
        let registry = FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot)

        let first = try registry.provisionDefaultBundle()
        let manifestPath = runtimeRoot.appending(path: "\(first.id)/manifest.json").path
        let firstTimestamp = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: manifestPath)[.modificationDate] as? Date
        )
        Thread.sleep(forTimeInterval: 0.01)
        let second = try registry.provisionDefaultBundle()
        let secondTimestamp = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: manifestPath)[.modificationDate] as? Date
        )

        XCTAssertEqual(first.version, second.version)
        XCTAssertEqual(firstTimestamp, secondTimestamp)
    }

    func testRuntimeBundleRegistryTreatsAppStagedUserlandAsProvisioned() {
        XCTAssertTrue(
            managedUserlandRequirementSatisfied(
                managedUserlandStaged: false,
                appStagedUserlandAvailable: true,
                userlandArchiveAvailable: true
            )
        )
    }

    func testRuntimeBundleRegistryRefreshesSameVersionBundleWhenBundledManifestChanges() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "RuntimeBundles", directoryHint: .isDirectory)
        let registry = FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot)

        let first = try registry.provisionDefaultBundle()
        let manifestURL = runtimeRoot.appending(path: "\(first.id)/manifest.json")
        let decoder = JSONDecoder()
        var installedManifest = try decoder.decode(
            RuntimeBundleManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        installedManifest.supportMetadata["wineForkRevision"] = "stale-same-version-runtime"

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(installedManifest).write(to: manifestURL, options: .atomic)

        let refreshed = try registry.provisionDefaultBundle()
        let refreshedManifest = try decoder.decode(
            RuntimeBundleManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(refreshed.version, first.version)
        XCTAssertNotEqual(
            refreshedManifest.supportMetadata["wineForkRevision"],
            "stale-same-version-runtime"
        )
        XCTAssertEqual(refreshedManifest.supportMetadata["bundleSource"], "managed-storage")
    }

    func testHostCapabilityProviderMarksStaleRuntimeBridgeHeartbeat() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedRoot = root.appending(path: "Managed", directoryHint: .isDirectory)
        let runtimeRoot = managedRoot.appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBridgeRoot = root.appending(path: "runtime-bridge", directoryHint: .isDirectory)
        let steamBridgeRoot = root.appending(path: "steam-bridge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: runtimeBridgeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: steamBridgeRoot, withIntermediateDirectories: true)
        _ = try materializeRuntimeBundle(root: runtimeRoot)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(
            BridgeHeartbeatStatus(
                lastUpdatedAt: Date().addingTimeInterval(-120),
                serviceName: "IridiumBridgeHost"
            )
        ).write(to: runtimeBridgeRoot.appending(path: "bridge-status.json"), options: .atomic)

        let snapshot = await FileSystemHostCapabilityProvider(
            runtimeBundleRegistry: FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRoot),
            managedRootURL: managedRoot,
            runtimeBridgeRootURL: runtimeBridgeRoot,
            steamBridgeRootURL: steamBridgeRoot
        ).snapshot()

        XCTAssertFalse(snapshot.runtimeBridgeAvailable)
        XCTAssertTrue(snapshot.runtimeBridgeStale)
        XCTAssertTrue(snapshot.constraints.contains("Runtime bridge heartbeat is stale."))
    }

    func testRuntimeBackendSelectionDefaultsToBundledDeviceOnIOSDevices() {
        XCTAssertEqual(
            RuntimeBackendSelection.resolvedMode(
                configuredMode: nil,
                isSimulator: false,
                isMacOSHost: false
            ),
            .bundledDevice
        )
    }

    func testRuntimeBackendSelectionDefaultsToDevelopmentOnSimulatorAndMacOS() {
        XCTAssertEqual(
            RuntimeBackendSelection.resolvedMode(
                configuredMode: nil,
                isSimulator: true,
                isMacOSHost: false
            ),
            .development
        )
        XCTAssertEqual(
            RuntimeBackendSelection.resolvedMode(
                configuredMode: nil,
                isSimulator: false,
                isMacOSHost: true
            ),
            .development
        )
    }

    func testRuntimeBackendSelectionRespectsProviderOverride() {
        XCTAssertEqual(
            RuntimeBackendSelection.resolvedMode(
                configuredMode: .providerBacked,
                isSimulator: false,
                isMacOSHost: false
            ),
            .providerBacked
        )
    }

    func testRuntimeValidationFailsWhenDeclaredArtifactIsMissing() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "RuntimeBundles", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        try FileManager.default.removeItem(
            at: runtimeRoot.appending(path: "\(bundle.id)/Translator/x64-jit.bin"))

        let report = await DefaultRuntimeValidationService().validate(
            snapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [bundle],
                selectedRuntimeBundle: bundle,
                constraints: [],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime
            )
        )

        XCTAssertEqual(report.status, .actionRequired)
        XCTAssertTrue(
            report.notes.contains(where: {
                $0.contains("Missing runtime artifact x64-jit-translator")
            }))
    }

    func testRuntimeValidationFailsWhenDeclaredArtifactChecksumMismatches() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        try Data("tampered-runtime-host".utf8).write(
            to: runtimeRoot.appending(path: "\(bundle.id)/Runtime/runtime-host.bin"),
            options: .atomic
        )

        let report = await DefaultRuntimeValidationService().validate(
            snapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [bundle],
                selectedRuntimeBundle: bundle,
                constraints: [],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime
            )
        )

        XCTAssertEqual(report.status, .actionRequired)
        XCTAssertTrue(
            report.notes.contains(where: {
                $0.contains("Checksum mismatch for runtime artifact runtime-host-binary")
            }))
    }

    func testRuntimeInventoryAcceptsLiveContainerRuntimeHostResigning() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        var bundle = try materializeRuntimeBundle(root: runtimeRoot)
        let original = fakeCodeSignedMachOBinary(signature: [1, 2, 3, 4])
        let resigned = fakeCodeSignedMachOBinary(signature: [9, 8, 7, 6, 5, 4])
        let hostURL = runtimeRoot.appending(
            path: "\(bundle.id)/Runtime/runtime-host.bin",
            directoryHint: .notDirectory
        )
        try resigned.write(to: hostURL, options: .atomic)

        let hostIndex = try XCTUnwrap(
            bundle.artifacts.firstIndex(where: { $0.identifier == "runtime-host-binary" })
        )
        bundle.artifacts[hostIndex].sizeBytes = Int64(original.count)
        bundle.artifacts[hostIndex].checksum = SHA256.hash(data: original)
            .map { String(format: "%02x", $0) }
            .joined()
        bundle.supportMetadata[runtimeHostCodeSignatureInvariantChecksumKey] = try XCTUnwrap(
            codeSignatureInvariantMachOChecksum(original)
        )

        let validation = validateRuntimeBundleInventory(bundle)

        XCTAssertFalse(
            validation.failures.contains(where: {
                $0.contains("Checksum mismatch for runtime artifact runtime-host-binary")
            })
        )
        XCTAssertTrue(
            validation.evidence.contains("artifact:runtime-host-binary:code-signature-invariant")
        )
    }

    func testRuntimeValidationRejectsDesktopShellCapableBundle() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        var bundle = try materializeRuntimeBundle(root: runtimeRoot)
        bundle.descriptor.exposesDesktopShell = true

        let report = await DefaultRuntimeValidationService().validate(
            snapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [bundle],
                selectedRuntimeBundle: bundle,
                constraints: [],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime
            )
        )

        XCTAssertEqual(report.status, .actionRequired)
        XCTAssertTrue(
            report.notes.contains(where: { $0.contains("exposes a desktop shell and is rejected") })
        )
    }

    func testRuntimeValidationRejectsBundleMissingRequiredArtifactDeclaration() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        var bundle = try materializeRuntimeBundle(root: runtimeRoot)
        bundle.artifacts.removeAll { $0.identifier == "x64-jit-translator" }

        let report = await DefaultRuntimeValidationService().validate(
            snapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [bundle],
                selectedRuntimeBundle: bundle,
                constraints: [],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime
            )
        )

        XCTAssertEqual(report.status, .actionRequired)
        XCTAssertTrue(
            report.notes.contains(where: {
                $0.contains("missing required artifact declaration x64-jit-translator")
            }))
    }

    func testRuntimeBundleInventoryRejectsStagedWineUserlandWithoutEmbeddedGuestLoader() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        let stagedUserlandRoot = runtimeRoot.appending(
            path: "\(bundle.id)/Support/wine-userland/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagedUserlandRoot, withIntermediateDirectories: true)
        try fakeMachOBinary().write(
            to: stagedUserlandRoot.appending(path: "wine"), options: .atomic)

        let validation = validateRuntimeBundleInventory(bundle)

        XCTAssertTrue(
            validation.failures.contains(where: {
                $0.contains("embedded-FEX-compatible x86_64 ELF Wine loader")
                    && $0.contains("bin/wine")
                    && $0.contains("Mach-O")
            })
        )
    }

    func testRuntimeBundleInventoryRejectsPTInterpWineLoaderOnly() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        let stagedLoaderURL = runtimeRoot.appending(
            path: "\(bundle.id)/Support/wine-userland/lib/wine/x86_64-unix/wine",
            directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: stagedLoaderURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fakeX8664ELFBinaryWithProgramInterpreter().write(
            to: stagedLoaderURL,
            options: .atomic)

        let validation = validateRuntimeBundleInventory(bundle)

        XCTAssertTrue(
            validation.failures.contains(where: {
                $0.contains("embedded-FEX-compatible x86_64 ELF Wine loader")
                    && $0.contains("without PT_INTERP")
                    && $0.contains("lib/wine/x86_64-unix/wine")
                    && $0.contains("PT_INTERP")
            })
        )
    }

    func testRuntimeBundleInventoryPrefersWinePreloaderOverPTInterpWineBinary() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        let stagedUserlandRoot = runtimeRoot.appending(
            path: "\(bundle.id)/Support/wine-userland", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagedUserlandRoot.appending(path: "lib/wine/x86_64-unix")
                .deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let wineRoot = stagedUserlandRoot.appending(
            path: "lib/wine/x86_64-unix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wineRoot, withIntermediateDirectories: true)
        try fakeX8664ELFBinaryWithProgramInterpreter().write(
            to: wineRoot.appending(path: "wine"),
            options: .atomic)
        let interpreterURL = stagedUserlandRoot.appending(path: "lib64/ld-linux-x86-64.so.2")
        try FileManager.default.createDirectory(
            at: interpreterURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fakeX8664ELFBinary().write(to: interpreterURL, options: .atomic)
        try fakeX8664ELFBinary().write(
            to: wineRoot.appending(path: "wine-preloader"),
            options: .atomic)
        try Data("wineios".utf8).write(
            to: wineRoot.appending(path: "wineios.so"),
            options: .atomic)
        try Data("ELF egl_handle eglGetProcAddress".utf8).write(
            to: wineRoot.appending(path: "opengl32.so"),
            options: .atomic)
        try Data("ELF libEGL.so.1 eglGetProcAddress".utf8).write(
            to: wineRoot.appending(path: "win32u.so"),
            options: .atomic)

        let validation = validateRuntimeBundleInventory(bundle)

        XCTAssertFalse(
            validation.failures.contains(where: {
                $0.contains("embedded-FEX-compatible x86_64 ELF Wine loader")
            })
        )
        XCTAssertTrue(
            validation.evidence.contains(
                "embedded-guest-loader:lib/wine/x86_64-unix/wine-preloader")
        )
    }

    func testRuntimeBundleInventoryRejectsWinePreloaderWithoutCompanionWineBinary() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        let stagedLoaderURL = runtimeRoot.appending(
            path: "\(bundle.id)/Support/wine-userland/lib/wine/x86_64-unix/wine-preloader",
            directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: stagedLoaderURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fakeX8664ELFBinary().write(to: stagedLoaderURL, options: .atomic)

        let validation = validateRuntimeBundleInventory(bundle)

        XCTAssertTrue(
            validation.failures.contains(where: {
                $0.contains("wine-preloader requires a sibling Unix Wine loader")
            })
        )
    }

    func testRuntimeBundleInventoryRejectsWinePreloaderWhenCompanionInterpreterIsMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        let wineRoot = runtimeRoot.appending(
            path: "\(bundle.id)/Support/wine-userland/lib/wine/x86_64-unix",
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wineRoot, withIntermediateDirectories: true)
        try fakeX8664ELFBinaryWithProgramInterpreter().write(
            to: wineRoot.appending(path: "wine"),
            options: .atomic)
        try fakeX8664ELFBinary().write(
            to: wineRoot.appending(path: "wine-preloader"),
            options: .atomic)

        let validation = validateRuntimeBundleInventory(bundle)

        XCTAssertTrue(
            validation.failures.contains(where: {
                $0.contains("wine-preloader requires a sibling Unix Wine loader")
                    && $0.contains("PT_INTERP ELF interpreter")
            })
        )
    }

    func testRuntimeBundleInventoryRejectsStagedWineUserlandWithoutWineIOSDriver() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        let stagedLoaderURL = runtimeRoot.appending(
            path: "\(bundle.id)/Support/wine-userland/lib/wine/x86_64-unix/wine",
            directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: stagedLoaderURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fakeX8664ELFBinary().write(to: stagedLoaderURL, options: .atomic)

        let validation = validateRuntimeBundleInventory(bundle)

        XCTAssertTrue(
            validation.failures.contains(where: {
                $0.contains("wineios.drv Unix driver")
            })
        )
    }

    func testRuntimeBundleInventoryRejectsStagedWineUserlandWithoutOpenGLBackend() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        let stagedLoaderURL = runtimeRoot.appending(
            path: "\(bundle.id)/Support/wine-userland/lib/wine/x86_64-unix/wine",
            directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: stagedLoaderURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fakeX8664ELFBinary().write(to: stagedLoaderURL, options: .atomic)
        try Data("wineios".utf8).write(
            to: stagedLoaderURL.deletingLastPathComponent().appending(path: "wineios.so"),
            options: .atomic)

        let validation = validateRuntimeBundleInventory(bundle)

        XCTAssertTrue(
            validation.failures.contains(where: {
                $0.contains("Wine OpenGL backend")
            })
        )
    }

    func testRuntimeBundleInventoryAcceptsStagedWineUserlandWithEmbeddedGuestLoader() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        let stagedLoaderURL = runtimeRoot.appending(
            path: "\(bundle.id)/Support/wine-userland/lib/wine/x86_64-unix/wine",
            directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: stagedLoaderURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fakeX8664ELFBinary().write(to: stagedLoaderURL, options: .atomic)
        try Data("wineios".utf8).write(
            to: stagedLoaderURL.deletingLastPathComponent().appending(path: "wineios.so"),
            options: .atomic)
        try Data("ELF egl_handle eglGetProcAddress".utf8).write(
            to: stagedLoaderURL.deletingLastPathComponent().appending(path: "opengl32.so"),
            options: .atomic)
        try Data("ELF libEGL.so.1 eglGetProcAddress".utf8).write(
            to: stagedLoaderURL.deletingLastPathComponent().appending(path: "win32u.so"),
            options: .atomic)

        let validation = validateRuntimeBundleInventory(bundle)

        XCTAssertFalse(
            validation.failures.contains(where: {
                $0.contains("embedded-FEX-compatible x86_64 ELF Wine loader")
            })
        )
        XCTAssertTrue(
            validation.evidence.contains("embedded-guest-loader:lib/wine/x86_64-unix/wine")
        )
        XCTAssertTrue(
            validation.evidence.contains("wineios-driver:lib/wine/x86_64-unix/wineios.so")
        )
        XCTAssertTrue(
            validation.evidence.contains("opengl-backend:lib/wine/x86_64-unix/opengl32.so")
        )
    }

    func testRuntimeBundleInventoryAcceptsDeclaredAppStagedUserlandWithoutDuplicateArchive() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        var bundle = try materializeRuntimeBundle(root: runtimeRoot)
        bundle.supportMetadata["userlandDelivery"] = "app-staged-extracted"
        let managedBundleRoot = runtimeRoot.appending(
            path: bundle.id, directoryHint: .isDirectory)
        try FileManager.default.removeItem(
            at: managedBundleRoot.appending(path: "Userland/wine-userland.tar.zst"))

        let appStagedRoot = root.appending(
            path: "App/IridiumWineUserland", directoryHint: .isDirectory)
        let wineRoot = appStagedRoot.appending(
            path: "lib/wine/x86_64-unix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wineRoot, withIntermediateDirectories: true)
        try fakeX8664ELFBinary().write(to: wineRoot.appending(path: "wine"), options: .atomic)
        try Data("wineios".utf8).write(
            to: wineRoot.appending(path: "wineios.so"), options: .atomic)
        try Data("ELF egl_handle eglGetProcAddress".utf8).write(
            to: wineRoot.appending(path: "opengl32.so"), options: .atomic)
        try Data("ELF libEGL.so.1 eglGetProcAddress".utf8).write(
            to: wineRoot.appending(path: "win32u.so"), options: .atomic)

        let validation = validateRuntimeBundleInventory(
            bundle,
            appStagedUserlandRootURL: appStagedRoot
        )

        XCTAssertFalse(
            validation.failures.contains(where: {
                $0.contains("Missing runtime artifact wine-userland")
            })
        )
        XCTAssertTrue(validation.evidence.contains("artifact:wine-userland:app-staged"))
        XCTAssertTrue(validation.evidence.contains("userland-source:app-staged"))
        XCTAssertTrue(
            validation.evidence.contains("embedded-guest-loader:lib/wine/x86_64-unix/wine")
        )
    }

    func testRuntimeValidationFailsClosedWhenEmbeddedLaunchSupportIsUnavailable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)

        let report = await DefaultRuntimeValidationService().validate(
            snapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [bundle],
                selectedRuntimeBundle: bundle,
                constraints: [],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime,
                launchReady: false,
                launchStatus: "bootstrapMissing",
                launchStatusSummary:
                    "Embedded FEX build does not include the FEXCore runtime bootstrap."
            )
        )

        XCTAssertEqual(report.status, .actionRequired)
        XCTAssertTrue(
            report.notes.contains(
                where: {
                    $0.contains(
                        "Embedded FEX build does not include the FEXCore runtime bootstrap.")
                }
            )
        )
    }

    func testRuntimeValidationDegradesWhenLaunchIsReadyButPlayabilityIsBlocked() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)

        let report = await DefaultRuntimeValidationService().validate(
            snapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [bundle],
                selectedRuntimeBundle: bundle,
                constraints: [],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime,
                launchReady: true,
                launchStatus: "ready",
                launchStatusSummary: "Runtime ready.",
                presentationReadiness: RuntimeSubsystemReadiness(
                    ready: false,
                    status: "presentationServiceMissing",
                    statusSummary:
                        "Runtime host does not provide an iOS presentation service for guest windows yet."
                ),
                inputReadiness: RuntimeSubsystemReadiness(
                    ready: false,
                    status: "inputBridgeMissing",
                    statusSummary:
                        "Runtime host does not provide an iOS input bridge for guest events yet."
                ),
                audioReadiness: RuntimeSubsystemReadiness(
                    ready: false,
                    status: "audioBridgeMissing",
                    statusSummary:
                        "Runtime host does not provide an iOS audio bridge for guest output yet."
                )
            )
        )

        XCTAssertEqual(report.status, .degraded)
        XCTAssertTrue(
            report.notes.contains(
                "Embedded launch bootstrap is ready, but the runtime is not yet playable on this host."
            )
        )
        XCTAssertTrue(
            report.notes.contains(
                "Runtime host does not provide an iOS presentation service for guest windows yet."
            )
        )
    }

    func testRuntimeValidationDegradesBootstrapReadyUntilRuntimeMilestonesAreVerified()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        let summary =
            "JIT and embedded bootstrap are ready; Wine server, Windows process, and first-frame milestones are not yet verified."
        let snapshot = HostCapabilitySnapshot(
            jitStatus: .ready,
            availableManagedStorageGB: 64,
            deviceCapabilityClass: .balanced,
            deviceTier: .tier2,
            thermalState: .nominal,
            lowPowerModeEnabled: false,
            runtimeBundles: [bundle],
            selectedRuntimeBundle: bundle,
            constraints: [],
            runtimeBridgeAvailable: true,
            steamBridgeAvailable: true,
            executionEnvironment: .nativeRuntime,
            launchReady: true,
            launchStatus: "bootstrapReady",
            launchStatusSummary: summary,
            presentationReadiness: RuntimeSubsystemReadiness(ready: true, status: "ready"),
            inputReadiness: RuntimeSubsystemReadiness(ready: true, status: "ready"),
            audioReadiness: RuntimeSubsystemReadiness(ready: true, status: "ready")
        )

        let report = await DefaultRuntimeValidationService().validate(snapshot: snapshot)

        XCTAssertTrue(snapshot.runtimeMilestoneVerificationPending)
        XCTAssertEqual(report.status, .degraded)
        XCTAssertTrue(report.notes.contains(summary))
    }

    func testRuntimeValidationAcceptsVerifiedServerProcessAndFirstFrameMilestones() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)
        let snapshot = HostCapabilitySnapshot(
            jitStatus: .ready,
            availableManagedStorageGB: 64,
            deviceCapabilityClass: .balanced,
            deviceTier: .tier2,
            thermalState: .nominal,
            lowPowerModeEnabled: false,
            runtimeBundles: [bundle],
            selectedRuntimeBundle: bundle,
            constraints: [],
            runtimeBridgeAvailable: true,
            steamBridgeAvailable: true,
            executionEnvironment: .nativeRuntime,
            launchReady: true,
            launchStatus: "runtimeVerified",
            launchStatusSummary: "Runtime verified through first frame.",
            runtimeMilestones: RuntimeLaunchMilestones(
                sessionIdentifier: "verified-session",
                wineServerReady: true,
                windowsProcessStarted: true,
                firstFramePresented: true
            ),
            presentationReadiness: RuntimeSubsystemReadiness(ready: true, status: "ready"),
            inputReadiness: RuntimeSubsystemReadiness(ready: true, status: "ready"),
            audioReadiness: RuntimeSubsystemReadiness(ready: true, status: "ready")
        )

        let report = await DefaultRuntimeValidationService().validate(snapshot: snapshot)

        XCTAssertFalse(snapshot.runtimeMilestoneVerificationPending)
        XCTAssertNotEqual(report.status, .degraded)
    }

    func testHostCapabilitySnapshotReportsOnlyBlockedPlayabilitySummaries() {
        let snapshot = HostCapabilitySnapshot(
            jitStatus: .ready,
            availableManagedStorageGB: 64,
            deviceCapabilityClass: .balanced,
            deviceTier: .tier2,
            thermalState: .nominal,
            lowPowerModeEnabled: false,
            runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
            selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
            constraints: [],
            runtimeBridgeAvailable: true,
            executionEnvironment: .nativeRuntime,
            launchReady: true,
            launchStatus: "ready",
            launchStatusSummary: "Runtime ready.",
            presentationReadiness: RuntimeSubsystemReadiness(
                ready: false,
                status: "presentationServiceMissing",
                statusSummary:
                    "Runtime host does not provide an iOS presentation service for guest windows yet."
            ),
            inputReadiness: RuntimeSubsystemReadiness(
                ready: true,
                status: "ready",
                statusSummary: "Guest input path is ready."
            )
        )

        XCTAssertEqual(snapshot.playabilityReady, false)
        XCTAssertEqual(
            snapshot.playabilityBlockingSummaries,
            ["Runtime host does not provide an iOS presentation service for guest windows yet."]
        )
    }

    func testPrimaryRuntimeHealthDetailPrefersPlayabilityAdvisoryOverSubsystemDetail() async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let bundle = try materializeRuntimeBundle(root: runtimeRoot)

        let snapshot = HostCapabilitySnapshot(
            jitStatus: .ready,
            availableManagedStorageGB: 64,
            deviceCapabilityClass: .balanced,
            deviceTier: .tier2,
            thermalState: .nominal,
            lowPowerModeEnabled: false,
            runtimeBundles: [bundle],
            selectedRuntimeBundle: bundle,
            constraints: [],
            runtimeBridgeAvailable: true,
            executionEnvironment: .nativeRuntime,
            launchReady: true,
            launchStatus: "ready",
            launchStatusSummary: "Runtime ready.",
            presentationReadiness: RuntimeSubsystemReadiness(
                ready: false,
                status: "presentationServiceMissing",
                statusSummary:
                    "Runtime host does not provide an iOS presentation service for guest windows yet."
            ),
            inputReadiness: RuntimeSubsystemReadiness(
                ready: true,
                status: "ready",
                statusSummary: "Guest input path is ready."
            ),
            audioReadiness: RuntimeSubsystemReadiness(
                ready: true,
                status: "ready",
                statusSummary: "Guest audio path is ready."
            )
        )

        let report = await DefaultRuntimeValidationService().validate(snapshot: snapshot)
        let detail = primaryRuntimeHealthDetail(for: report, hostSnapshot: snapshot)

        XCTAssertEqual(report.status, .degraded)
        XCTAssertEqual(
            detail,
            "Embedded launch bootstrap is ready, but the runtime is not yet playable on this host."
        )
        XCTAssertTrue(
            report.notes.contains(
                "Runtime host does not provide an iOS presentation service for guest windows yet."
            )
        )
        XCTAssertFalse(
            report.notes.contains(
                "Runtime host does not provide an iOS input bridge for guest events yet."
            )
        )
        XCTAssertFalse(
            report.notes.contains(
                "Runtime host does not provide an iOS audio bridge for guest output yet."
            )
        )
    }

    func testPrimaryRuntimeHealthDetailPrefersBlockingLaunchReason() {
        let detail = primaryRuntimeHealthDetail(
            for: RuntimeHealthReport(
                status: .actionRequired,
                runtimeName: "Iridium Runtime Base",
                notes: [
                    "Runtime bundle Iridium Runtime Base 2026.03.27-real is registered.",
                    "Embedded FEX build does not include the FEXCore runtime bootstrap.",
                    "Host is configured for native runtime execution.",
                ]
            ),
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
                selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
                constraints: [],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime,
                launchReady: false,
                launchStatus: "bootstrapMissing",
                launchStatusSummary:
                    "Embedded FEX build does not include the FEXCore runtime bootstrap."
            )
        )

        XCTAssertEqual(detail, "Embedded FEX build does not include the FEXCore runtime bootstrap.")
    }

    func testGameArtifactInventoryFingerprintsExecutable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("samplelightweightgame".utf8).write(to: executableURL)

        let inventory = FileSystemGameArtifactInventory()
        let fingerprint = try inventory.fingerprintExecutable(at: executableURL.path)
        let artifact = try inventory.makeManagedArtifact(
            title: "SampleLightweightGame",
            executablePath: executableURL.path,
            installPath: root.path
        )

        XCTAssertEqual(fingerprint.algorithm, "SHA256")
        XCTAssertFalse(fingerprint.value.isEmpty)
        XCTAssertEqual(artifact.identifier, "samplelightweightgame")
        XCTAssertEqual(artifact.relativePath, "SampleLightweightGame.exe")
        XCTAssertEqual(artifact.checksum, fingerprint.value)
    }

    func testRuntimeSessionExecutorWritesDirectLaunchHandoff() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("samplelightweightgame".utf8).write(to: executableURL)
        let runtimeBundle = try materializeRuntimeBundle(
            root: root.appending(path: "Runtime", directoryHint: .isDirectory))
        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: root.path,
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: executableURL.path,
                arguments: [],
                prefixID: UUID(),
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 1.2,
            summary: "Test title"
        )
        let prefix = PrefixRecord(
            id: game.launchProfile.prefixID,
            name: "SampleLightweightGame Prefix",
            runtimeName: runtimeBundle.name,
            state: .clean,
            storageFootprint: "2.0 GB",
            storageFootprintGB: 2.0
        )
        let session = LaunchCoordinator(
            runtime: runtimeBundle.descriptor,
            jitStatus: .ready,
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [runtimeBundle],
                selectedRuntimeBundle: runtimeBundle,
                constraints: []
            ),
            runtimePolicy: RuntimePolicy(
                memoryBudgetClass: .compact,
                resolutionScale: 1.0,
                shaderStrategy: .onDemand
            )
        ).prepareLaunch(
            for: game,
            runtimeHealth: RuntimeHealthReport(
                status: .healthy,
                runtimeName: runtimeBundle.name,
                runtimeBundleIdentifier: runtimeBundle.id,
                runtimeBundleVersion: runtimeBundle.version,
                notes: []
            ),
            filePresence: ManagedFilePresence(installRootExists: true, executableExists: true)
        )

        let result = await makeDevelopmentRuntimeExecutor().execute(
            RuntimeSessionRequest(
                game: game,
                prefix: prefix,
                session: session,
                hostSnapshot: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 64,
                    deviceCapabilityClass: .balanced,
                    deviceTier: .tier2,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [runtimeBundle],
                    selectedRuntimeBundle: runtimeBundle,
                    constraints: []
                ),
                runtimeBundle: runtimeBundle,
                policy: RuntimePolicy(
                    memoryBudgetClass: .compact,
                    resolutionScale: 1.0,
                    shaderStrategy: .onDemand
                )
            )
        )

        switch result {
        case .success(let payload):
            XCTAssertEqual(payload.terminalStatus, RuntimeHostSessionState.completed.rawValue)
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload.launchTicketPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload.prefixManifestPath))
            XCTAssertEqual(payload.runtimeBundleVersion, runtimeBundle.version)
            XCTAssertEqual(payload.environment["IRIDIUM_NO_DESKTOP"], "1")
            XCTAssertEqual(payload.stateHistory.first, RuntimeHostSessionState.queued.rawValue)
            XCTAssertEqual(payload.telemetrySnapshot?.thermalState, .nominal)
        case .failure(let failure):
            XCTFail("Expected launch handoff to succeed, got \(failure)")
        }
    }

    func testBundledDeviceRuntimeBackendExecutesWithoutProviderTransport() async throws {
        try await withTemporarilyOverriddenEnvironmentVariables(
            embeddedSmokeExecutionEnvironment
        ) {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = try await makeRuntimeLaunchFixture(
                root: root, title: "BundledDeviceGame")
            #if os(iOS)
                _ = try writeStagedWineUserlandRoot(for: fixture.runtimeBundle)
            #endif
            var sessionEnvironment = fixture.ticket.environment
            sessionEnvironment["IRIDIUM_HOST_TELEMETRY_AVERAGE_FPS"] = "60"
            sessionEnvironment["IRIDIUM_HOST_TELEMETRY_FRAME_TIME_P95_MS"] = "18"
            sessionEnvironment["IRIDIUM_HOST_TELEMETRY_MEMORY_PRESSURE_RATIO"] = "0.42"
            sessionEnvironment["IRIDIUM_HOST_TELEMETRY_THERMAL_STATE"] = "nominal"
            let session = LaunchSession(
                gameID: fixture.game.id,
                title: fixture.game.title,
                executablePath: fixture.ticket.executablePath,
                arguments: fixture.ticket.launchArguments,
                workingDirectory: fixture.ticket.workingDirectory,
                environment: sessionEnvironment,
                readiness: .ready,
                issues: []
            )

            let result = await makeRuntimeExecutor(
                backendClient: BundledDeviceRuntimeBackendClient()
            )
            .execute(
                RuntimeSessionRequest(
                    game: fixture.game,
                    prefix: fixture.prefix,
                    session: session,
                    hostSnapshot: HostCapabilitySnapshot(
                        jitStatus: .ready,
                        availableManagedStorageGB: 64,
                        deviceCapabilityClass: .balanced,
                        deviceTier: .tier2,
                        thermalState: .nominal,
                        lowPowerModeEnabled: false,
                        runtimeBundles: [fixture.runtimeBundle],
                        selectedRuntimeBundle: fixture.runtimeBundle,
                        constraints: [],
                        runtimeBridgeAvailable: false,
                        backendMode: .bundledDevice,
                        executionEnvironment: .nativeRuntime
                    ),
                    runtimeBundle: fixture.runtimeBundle,
                    policy: RuntimePolicy(
                        memoryBudgetClass: .compact,
                        resolutionScale: 1.0,
                        shaderStrategy: .onDemand
                    )
                )
            )

            switch result {
            case .success(let payload):
                XCTAssertEqual(
                    payload.terminalStatus, RuntimeHostSessionState.completed.rawValue)
                XCTAssertEqual(
                    payload.stateHistory,
                    RuntimeHostSessionState.allCases.map(\.rawValue).filter {
                        $0 != RuntimeHostSessionState.failed.rawValue
                    }
                )
                XCTAssertEqual(payload.runtimeBundleID, fixture.runtimeBundle.id)
                XCTAssertEqual(payload.runtimeBundleVersion, fixture.runtimeBundle.version)
                XCTAssertEqual(payload.environment["IRIDIUM_NO_DESKTOP"], "1")
                XCTAssertEqual(payload.telemetrySnapshot?.averageFPS, 60)
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: root.appending(
                            path: "RuntimeProvider", directoryHint: .isDirectory
                        )
                        .path
                    )
                )
            case .failure(let failure):
                XCTFail("Expected bundled-device backend execution to succeed, got \(failure)")
            }
        }
    }

    func testBundledDeviceRuntimeBackendAcceptsCompleteStagedUserlandWithoutArchive()
        async throws
    {
        try await withTemporarilyOverriddenEnvironmentVariables(
            embeddedSmokeExecutionEnvironment
        ) {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = try await makeRuntimeLaunchFixture(
                root: root, title: "AppStagedUserlandGame")
            let stagedUserlandRoot = try makeExplicitWineUserlandRoot(
                under: root,
                relativePath: "IridiumWineUserland"
            )
            let runtimeBundleRoot = URL(
                fileURLWithPath: fixture.runtimeBundle.bundleRootPath ?? "",
                isDirectory: true
            )
            let userlandArchiveURL = runtimeBundleRoot.appending(
                path: "Userland/wine-userland.tar.zst")
            try FileManager.default.removeItem(at: userlandArchiveURL)

            let prefixManifest = try JSONDecoder().decode(
                PrefixBootstrapManifest.self,
                from: Data(contentsOf: URL(fileURLWithPath: fixture.ticket.prefixManifestPath))
            )
            let environmentFileURL = URL(fileURLWithPath: prefixManifest.environmentFilePath)
            var environmentLines = try String(contentsOf: environmentFileURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.hasPrefix("IRIDIUM_USERLAND_ARCHIVE=") }
            environmentLines.append(
                "\(RuntimeEnvironmentKey.userlandRoot)=\(stagedUserlandRoot.path)")
            let wineDataDirectory = stagedUserlandRoot.appending(
                path: "share/wine", directoryHint: .isDirectory
            ).path
            environmentLines.append(
                "\(RuntimeEnvironmentKey.wineDataDirectory)=\(wineDataDirectory)")
            try Data("\(environmentLines.joined(separator: "\n"))\n".utf8).write(
                to: environmentFileURL,
                options: .atomic
            )

            let result = await FileSystemRuntimeHostController(
                backendClient: BundledDeviceRuntimeBackendClient()
            ).submit(ticket: fixture.ticket)

            switch result {
            case .success(let session):
                XCTAssertTrue(
                    session.state == .queued || session.state == .running,
                    "Accepted app-staged userland should produce a live nonterminal session, got \(session.state.rawValue)"
                )
                let requestURL = URL(
                    fileURLWithPath: fixture.ticket.workingDirectory,
                    isDirectory: true
                )
                .appending(
                    path: ".iridium/runtime-backend/requests/launch-\(fixture.ticket.id).json")
                let launchPackage = try JSONDecoder().decode(
                    RuntimeBackendLaunchPackage.self,
                    from: Data(contentsOf: requestURL)
                )
                XCTAssertEqual(
                    launchPackage.environment[RuntimeEnvironmentKey.userlandRoot],
                    stagedUserlandRoot.path
                )
                XCTAssertEqual(
                    launchPackage.environment[RuntimeEnvironmentKey.wineDataDirectory],
                    wineDataDirectory
                )
                XCTAssertNil(launchPackage.environment["IRIDIUM_USERLAND_ARCHIVE"])
            case .failure(let failure):
                XCTFail(
                    "Expected complete app-staged Wine userland to replace the removed archive, got \(failure)"
                )
            }
        }
    }

    func testBundledDeviceRuntimeBackendRejectsIncompleteStagedUserlandWithoutArchive()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try await makeRuntimeLaunchFixture(
            root: root, title: "IncompleteStagedUserlandGame")
        let runtimeBundleRoot = URL(
            fileURLWithPath: fixture.runtimeBundle.bundleRootPath ?? "",
            isDirectory: true
        )
        try FileManager.default.removeItem(
            at: runtimeBundleRoot.appending(path: "Userland/wine-userland.tar.zst"))

        let incompleteRoot = root.appending(
            path: "IncompleteIridiumWineUserland",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: incompleteRoot.appending(path: "bin", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("wine".utf8).write(to: incompleteRoot.appending(path: "bin/wine"))

        var package = try makeBackendLaunchPackage(from: fixture)
        package.environment[RuntimeEnvironmentKey.userlandRoot] = incompleteRoot.path
        let result = await BundledDeviceRuntimeBackendClient().startSession(package)

        switch result {
        case .success:
            XCTFail("An incomplete staged Wine tree must not replace the bundled archive.")
        case .failure(let failure):
            XCTAssertEqual(failure.code, .invalidRuntimeBundle)
            XCTAssertTrue(failure.reason.contains("no structurally valid staged Wine userland"))
            XCTAssertTrue(failure.reason.contains(incompleteRoot.path))
        }
    }

    func testBundledDeviceRuntimeBackendUsesEmbeddedHostHandlerOnNonMacHosts() async throws {
        #if os(macOS)
            throw XCTSkip("Embedded runtime host handler is only used on non-macOS hosts.")
        #else
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = try await makeRuntimeLaunchFixture(
                root: root, title: "EmbeddedDeviceGame")
            let session = LaunchSession(
                gameID: fixture.game.id,
                title: fixture.game.title,
                executablePath: fixture.ticket.executablePath,
                arguments: fixture.ticket.launchArguments,
                workingDirectory: fixture.ticket.workingDirectory,
                environment: fixture.ticket.environment,
                readiness: .ready,
                issues: []
            )

            await EmbeddedRuntimeHostBridge.registerLaunchHandler(
                makeEmbeddedRuntimeHostLaunchHandler())
            let result = await makeRuntimeExecutor(
                backendClient: BundledDeviceRuntimeBackendClient()
            ).execute(
                RuntimeSessionRequest(
                    game: fixture.game,
                    prefix: fixture.prefix,
                    session: session,
                    hostSnapshot: HostCapabilitySnapshot(
                        jitStatus: .ready,
                        availableManagedStorageGB: 64,
                        deviceCapabilityClass: .balanced,
                        deviceTier: .tier2,
                        thermalState: .nominal,
                        lowPowerModeEnabled: false,
                        runtimeBundles: [fixture.runtimeBundle],
                        selectedRuntimeBundle: fixture.runtimeBundle,
                        constraints: [],
                        runtimeBridgeAvailable: false,
                        backendMode: .bundledDevice,
                        executionEnvironment: .nativeRuntime
                    ),
                    runtimeBundle: fixture.runtimeBundle,
                    policy: RuntimePolicy(
                        memoryBudgetClass: .compact,
                        resolutionScale: 1.0,
                        shaderStrategy: .onDemand
                    )
                )
            )
            await EmbeddedRuntimeHostBridge.clearLaunchHandler()

            switch result {
            case .success(let payload):
                XCTAssertEqual(payload.terminalStatus, RuntimeHostSessionState.completed.rawValue)
                XCTAssertEqual(payload.runtimeBundleID, fixture.runtimeBundle.id)
                XCTAssertEqual(payload.telemetrySnapshot?.averageFPS, 59)
            case .failure(let failure):
                XCTFail(
                    "Expected embedded runtime host handler execution to succeed, got \(failure)")
            }
        #endif
    }

    func testBundledDeviceRuntimeBackendUsesEmbeddedSDKHostOnNonMacHosts() async throws {
        #if os(macOS)
            throw XCTSkip("Embedded SDK runtime host is only used on non-macOS hosts.")
        #else
            try await withTemporarilyOverriddenEnvironmentVariables(
                embeddedSmokeExecutionEnvironment
            ) {
                let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let fixture = try await makeRuntimeLaunchFixture(
                    root: root, title: "EmbeddedSDKGame")
                _ = try writeStagedWineUserlandRoot(for: fixture.runtimeBundle)
                var sessionEnvironment = fixture.ticket.environment
                sessionEnvironment["IRIDIUM_HOST_TELEMETRY_AVERAGE_FPS"] = "60"
                sessionEnvironment["IRIDIUM_HOST_TELEMETRY_FRAME_TIME_P95_MS"] = "18"
                sessionEnvironment["IRIDIUM_HOST_TELEMETRY_MEMORY_PRESSURE_RATIO"] = "0.42"
                sessionEnvironment["IRIDIUM_HOST_TELEMETRY_THERMAL_STATE"] = "nominal"
                let session = LaunchSession(
                    gameID: fixture.game.id,
                    title: fixture.game.title,
                    executablePath: fixture.ticket.executablePath,
                    arguments: fixture.ticket.launchArguments,
                    workingDirectory: fixture.ticket.workingDirectory,
                    environment: sessionEnvironment,
                    readiness: .ready,
                    issues: []
                )

                let result = await makeRuntimeExecutor(
                    backendClient: BundledDeviceRuntimeBackendClient()
                ).execute(
                    RuntimeSessionRequest(
                        game: fixture.game,
                        prefix: fixture.prefix,
                        session: session,
                        hostSnapshot: HostCapabilitySnapshot(
                            jitStatus: .ready,
                            availableManagedStorageGB: 64,
                            deviceCapabilityClass: .balanced,
                            deviceTier: .tier2,
                            thermalState: .nominal,
                            lowPowerModeEnabled: false,
                            runtimeBundles: [fixture.runtimeBundle],
                            selectedRuntimeBundle: fixture.runtimeBundle,
                            constraints: [],
                            runtimeBridgeAvailable: false,
                            backendMode: .bundledDevice,
                            executionEnvironment: .nativeRuntime
                        ),
                        runtimeBundle: fixture.runtimeBundle,
                        policy: RuntimePolicy(
                            memoryBudgetClass: .compact,
                            resolutionScale: 1.0,
                            shaderStrategy: .onDemand
                        )
                    )
                )

                switch result {
                case .success(let payload):
                    XCTAssertEqual(
                        payload.terminalStatus, RuntimeHostSessionState.completed.rawValue)
                    XCTAssertEqual(payload.telemetrySnapshot?.averageFPS, 60)
                    XCTAssertEqual(payload.runtimeBundleID, fixture.runtimeBundle.id)
                case .failure(let failure):
                    XCTFail(
                        "Expected embedded SDK runtime host execution to succeed, got \(failure)")
                }
            }
        #endif
    }

    func testEmbeddedRuntimeHostSDKBridgeWritesBackendOutputs() async throws {
        try await withTemporarilyOverriddenEnvironmentVariables(embeddedSmokeExecutionEnvironment) {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = try await makeRuntimeLaunchFixture(
                root: root, title: "EmbeddedBridgeProbe")
            #if os(iOS)
                _ = try writeStagedWineUserlandRoot(for: fixture.runtimeBundle)
            #endif
            let package = try makeBackendLaunchPackage(from: fixture)
            let probeRoot = root.appending(path: "probe", directoryHint: .isDirectory)
            let launchPackageURL = probeRoot.appending(path: "requests/launch-\(package.id).json")
            let sessionUpdateURL = probeRoot.appending(path: "responses/session-\(package.id).json")
            let terminalResultURL = probeRoot.appending(
                path: "responses/terminal-\(package.id).json")
            let telemetryURL = probeRoot.appending(path: "responses/telemetry-\(package.id).json")
            let hostLogURL = probeRoot.appending(path: "logs/runtime-host-\(package.id).log")

            try FileManager.default.createDirectory(
                at: launchPackageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(package).write(to: launchPackageURL)

            try await EmbeddedRuntimeHostSDKBridge.launch(
                EmbeddedRuntimeHostInvocation(
                    packageID: package.id,
                    hostBinaryURL: URL(
                        fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true
                    )
                    .appending(path: "Runtime/runtime-host.bin"),
                    launchPackageURL: launchPackageURL,
                    sessionUpdateURL: sessionUpdateURL,
                    terminalResultURL: terminalResultURL,
                    telemetryURL: telemetryURL,
                    hostLogURL: hostLogURL
                )
            )

            XCTAssertTrue(FileManager.default.fileExists(atPath: sessionUpdateURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: terminalResultURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: hostLogURL.path))
            let managedRoot = URL(fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let capabilityURL = FileSystemHostCapabilityProvider.capabilityRecordURL(
                for: managedRoot)
            XCTAssertTrue(FileManager.default.fileExists(atPath: capabilityURL.path))

            let decodedSession = try JSONDecoder().decode(
                RuntimeBackendSessionUpdate.self,
                from: Data(contentsOf: sessionUpdateURL)
            )
            let decodedTerminal = try JSONDecoder().decode(
                RuntimeBackendTerminalResult.self,
                from: Data(contentsOf: terminalResultURL)
            )
            let decodedCapabilities = try JSONDecoder().decode(
                RuntimeHostCapabilityRecord.self,
                from: Data(contentsOf: capabilityURL)
            )

            XCTAssertEqual(decodedSession.id, package.id)
            XCTAssertEqual(decodedTerminal.id, package.id)
            XCTAssertEqual(decodedSession.state, .running)
            XCTAssertEqual(
                decodedTerminal.terminalStatus, RuntimeHostSessionState.completed.rawValue)
            XCTAssertNil(decodedTerminal.failureCode)
            XCTAssertEqual(decodedCapabilities.jitStatus, .ready)
            XCTAssertEqual(decodedCapabilities.launchReady, true)
            XCTAssertEqual(decodedCapabilities.presentationReadiness?.ready, false)
            XCTAssertEqual(
                decodedCapabilities.presentationReadiness?.status, "presentationServiceMissing")
            XCTAssertEqual(decodedCapabilities.inputReadiness?.ready, false)
            XCTAssertEqual(decodedCapabilities.audioReadiness?.ready, false)
        }
    }

    func testEmbeddedRuntimeHostSDKBridgeFailsClosedWhenJITIsNotReady() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try await makeRuntimeLaunchFixture(root: root, title: "JITBlockedBridgeProbe")
        #if os(iOS)
            _ = try writeStagedWineUserlandRoot(for: fixture.runtimeBundle)
        #endif
        var package = try makeBackendLaunchPackage(from: fixture)
        package.environment["IRIDIUM_HOST_JIT_STATUS"] = "required"

        let probeRoot = root.appending(path: "jit-blocked-probe", directoryHint: .isDirectory)
        let launchPackageURL = probeRoot.appending(path: "requests/launch-\(package.id).json")
        let sessionUpdateURL = probeRoot.appending(path: "responses/session-\(package.id).json")
        let terminalResultURL = probeRoot.appending(path: "responses/terminal-\(package.id).json")
        let telemetryURL = probeRoot.appending(path: "responses/telemetry-\(package.id).json")
        let hostLogURL = probeRoot.appending(path: "logs/runtime-host-\(package.id).log")

        try FileManager.default.createDirectory(
            at: launchPackageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(package).write(to: launchPackageURL)

        do {
            try await EmbeddedRuntimeHostSDKBridge.launch(
                EmbeddedRuntimeHostInvocation(
                    packageID: package.id,
                    hostBinaryURL: URL(
                        fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true
                    )
                    .appending(path: "Runtime/runtime-host.bin"),
                    launchPackageURL: launchPackageURL,
                    sessionUpdateURL: sessionUpdateURL,
                    terminalResultURL: terminalResultURL,
                    telemetryURL: telemetryURL,
                    hostLogURL: hostLogURL
                )
            )
            XCTFail("Expected the embedded runtime host to fail closed when JIT is not ready.")
        } catch let failure as RuntimeFailure {
            XCTAssertEqual(failure.code, .jitNotReady)
            XCTAssertTrue(
                failure.reason.contains(
                    "No external debugger/JIT session detected.")
            )
            XCTAssertTrue(failure.reason.contains("Host log:"))
        }

        let terminalResult = try JSONDecoder().decode(
            RuntimeBackendTerminalResult.self,
            from: Data(contentsOf: terminalResultURL)
        )
        let managedRoot = URL(fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let capabilityURL = FileSystemHostCapabilityProvider.capabilityRecordURL(for: managedRoot)
        let decodedCapabilities = try JSONDecoder().decode(
            RuntimeHostCapabilityRecord.self,
            from: Data(contentsOf: capabilityURL)
        )

        XCTAssertEqual(terminalResult.terminalStatus, RuntimeHostSessionState.failed.rawValue)
        XCTAssertEqual(terminalResult.failureCode, RuntimeFailureCode.jitNotReady.rawValue)
        XCTAssertEqual(
            terminalResult.failureReason,
            "No external debugger/JIT session detected.")
        XCTAssertEqual(decodedCapabilities.jitStatus, .required)
        XCTAssertFalse(FileManager.default.fileExists(atPath: telemetryURL.path))
    }

    func testEmbeddedRuntimeHostSDKBridgeRejectsBundledBlockedEntrypoint() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try await makeRuntimeLaunchFixture(root: root, title: "BlockedLauncher")

        let executableURL = URL(fileURLWithPath: fixture.ticket.executablePath)
        let blockedExecutableURL = executableURL.deletingLastPathComponent().appending(
            path: "launcher.exe")
        try FileManager.default.moveItem(at: executableURL, to: blockedExecutableURL)

        let profileURL = URL(
            fileURLWithPath: fixture.runtimeBundle.bundleRootPath ?? "", isDirectory: true
        )
        .appending(path: "Metadata/direct-launch.json")
        try Data(
            """
            {"blockedEntryPoints":["launcher.exe"],"directLaunchOnly":true,"supportsArchitectures":["x64"]}
            \n
            """.utf8
        ).write(to: profileURL, options: .atomic)

        var game = fixture.game
        game.launchProfile = GameLaunchProfile(
            executablePath: blockedExecutableURL.path,
            arguments: game.launchProfile.arguments,
            prefixID: game.launchProfile.prefixID,
            rendererPreset: game.launchProfile.rendererPreset,
            deviceTier: game.launchProfile.deviceTier,
            titleFlags: game.launchProfile.titleFlags
        )

        var ticket = fixture.ticket
        ticket.executablePath = blockedExecutableURL.path

        let package = try makeBackendLaunchPackage(
            from: (
                game: game,
                prefix: fixture.prefix,
                runtimeBundle: fixture.runtimeBundle,
                ticket: ticket
            )
        )

        let probeRoot = root.appending(path: "blocked-probe", directoryHint: .isDirectory)
        let launchPackageURL = probeRoot.appending(path: "requests/launch-\(package.id).json")
        let sessionUpdateURL = probeRoot.appending(path: "responses/session-\(package.id).json")
        let terminalResultURL = probeRoot.appending(path: "responses/terminal-\(package.id).json")
        let telemetryURL = probeRoot.appending(path: "responses/telemetry-\(package.id).json")
        let hostLogURL = probeRoot.appending(path: "logs/runtime-host-\(package.id).log")

        try FileManager.default.createDirectory(
            at: launchPackageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(package).write(to: launchPackageURL)

        do {
            try await EmbeddedRuntimeHostSDKBridge.launch(
                EmbeddedRuntimeHostInvocation(
                    packageID: package.id,
                    hostBinaryURL: URL(
                        fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true
                    )
                    .appending(path: "Runtime/runtime-host.bin"),
                    launchPackageURL: launchPackageURL,
                    sessionUpdateURL: sessionUpdateURL,
                    terminalResultURL: terminalResultURL,
                    telemetryURL: telemetryURL,
                    hostLogURL: hostLogURL
                )
            )
            XCTFail("Expected the embedded runtime host to reject the blocked entrypoint.")
        } catch let failure as RuntimeFailure {
            XCTAssertEqual(failure.code, .desktopShellEntrypointBlocked)
            XCTAssertNotNil(failure.reason)
        }

        let terminalResult = try JSONDecoder().decode(
            RuntimeBackendTerminalResult.self,
            from: Data(contentsOf: terminalResultURL)
        )
        XCTAssertEqual(terminalResult.terminalStatus, RuntimeHostSessionState.failed.rawValue)
        XCTAssertEqual(
            terminalResult.failureCode, RuntimeFailureCode.desktopShellEntrypointBlocked.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: telemetryURL.path))
    }

    func testEmbeddedRuntimeHostSDKBridgeCanInvokeConfiguredExternalWineBinary() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try await makeRuntimeLaunchFixture(root: root, title: "ExternalWineProbe")
        var package = try makeBackendLaunchPackage(from: fixture)
        package.launchArguments = ["--smoke-flag"]

        let scriptURL = root.appending(path: "fake-wine.sh")
        let outputURL = root.appending(path: "external-wine-output.txt")
        let script = """
            #!/bin/sh
            {
              printf 'arg1=%s\\n' "$1"
              printf 'arg2=%s\\n' "$2"
              printf 'wineprefix=%s\\n' "$WINEPREFIX"
              printf 'nodesktop=%s\\n' "$IRIDIUM_NO_DESKTOP"
            } > "$IRIDIUM_TEST_OUTPUT_FILE"
            exit 0
            """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        package.environment["IRIDIUM_HOST_ENABLE_EXTERNAL_ENGINE"] = "1"
        package.environment["IRIDIUM_EXTERNAL_WINE_BINARY"] = scriptURL.path
        package.environment["IRIDIUM_TEST_OUTPUT_FILE"] = outputURL.path

        let probeRoot = root.appending(path: "external-probe", directoryHint: .isDirectory)
        let launchPackageURL = probeRoot.appending(path: "requests/launch-\(package.id).json")
        let sessionUpdateURL = probeRoot.appending(path: "responses/session-\(package.id).json")
        let terminalResultURL = probeRoot.appending(path: "responses/terminal-\(package.id).json")
        let telemetryURL = probeRoot.appending(path: "responses/telemetry-\(package.id).json")
        let hostLogURL = probeRoot.appending(path: "logs/runtime-host-\(package.id).log")

        try FileManager.default.createDirectory(
            at: launchPackageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(package).write(to: launchPackageURL)

        try await EmbeddedRuntimeHostSDKBridge.launch(
            EmbeddedRuntimeHostInvocation(
                packageID: package.id,
                hostBinaryURL: URL(
                    fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true
                )
                .appending(path: "Runtime/runtime-host.bin"),
                launchPackageURL: launchPackageURL,
                sessionUpdateURL: sessionUpdateURL,
                terminalResultURL: terminalResultURL,
                telemetryURL: telemetryURL,
                hostLogURL: hostLogURL
            )
        )

        let terminal = try JSONDecoder().decode(
            RuntimeBackendTerminalResult.self,
            from: Data(contentsOf: terminalResultURL)
        )
        let output = try String(contentsOf: outputURL, encoding: .utf8)
        let hostLog = try String(contentsOf: hostLogURL, encoding: .utf8)

        XCTAssertEqual(terminal.terminalStatus, RuntimeHostSessionState.completed.rawValue)
        XCTAssertTrue(output.contains("arg1=\(package.executablePath)"))
        XCTAssertTrue(output.contains("arg2=--smoke-flag"))
        XCTAssertTrue(output.contains("nodesktop=1"))
        XCTAssertTrue(output.contains("wineprefix="))
        XCTAssertTrue(hostLog.contains("engine=external-wine"))
    }

    func testEmbeddedRuntimeHostSDKBridgeUnpacksBundledUserlandArchiveForExternalEngine()
        async throws
    {
        #if os(macOS)
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = try await makeRuntimeLaunchFixture(
                root: root, title: "BundledUserlandProbe")
            var package = try makeBackendLaunchPackage(from: fixture)

            let outputURL = root.appending(path: "bundled-userland-output.txt")
            let wineScript = """
                #!/bin/sh
                {
                  printf 'source=archive\\n'
                  printf 'arg1=%s\\n' "$1"
                  printf 'arg2=%s\\n' "$2"
                } > "$IRIDIUM_TEST_OUTPUT_FILE"
                exit 0
                """
            let bundledRoot = URL(
                fileURLWithPath: fixture.runtimeBundle.bundleRootPath ?? "", isDirectory: true
            )
            .appending(path: "Userland/root", directoryHint: .isDirectory)
            let bundledBinRoot = bundledRoot.appending(path: "bin", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: bundledBinRoot, withIntermediateDirectories: true)
            let bundledWineURL = bundledBinRoot.appending(path: "wine64")
            try Data(
                """
                #!/bin/sh
                printf 'source=bundled-root\\n' > "$IRIDIUM_TEST_OUTPUT_FILE"
                exit 0
                """.utf8
            ).write(to: bundledWineURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: bundledWineURL.path)
            let bundledWineServerURL = bundledBinRoot.appending(path: "wineserver")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundledWineServerURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: bundledWineServerURL.path)

            let userlandSourceRoot = root.appending(
                path: "userland-root", directoryHint: .isDirectory)
            let archiveURL = URL(
                fileURLWithPath: fixture.runtimeBundle.bundleRootPath ?? "", isDirectory: true
            )
            .appending(path: "Userland/wine-userland.tar.zst")
            try writeValidUserlandArchive(
                to: archiveURL, root: userlandSourceRoot, wineScript: wineScript)

            let extractedRoot = URL(
                fileURLWithPath: fixture.runtimeBundle.bundleRootPath ?? "", isDirectory: true
            )
            .appending(path: "Userland/extracted", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: extractedRoot.path) {
                try FileManager.default.removeItem(at: extractedRoot)
            }

            package.launchArguments = ["--archive-smoke"]
            package.environment["IRIDIUM_HOST_ENABLE_EXTERNAL_ENGINE"] = "1"
            package.environment["IRIDIUM_TEST_OUTPUT_FILE"] = outputURL.path

            let probeRoot = root.appending(
                path: "bundled-userland-probe", directoryHint: .isDirectory)
            let launchPackageURL = probeRoot.appending(path: "requests/launch-\(package.id).json")
            let sessionUpdateURL = probeRoot.appending(path: "responses/session-\(package.id).json")
            let terminalResultURL = probeRoot.appending(
                path: "responses/terminal-\(package.id).json")
            let telemetryURL = probeRoot.appending(path: "responses/telemetry-\(package.id).json")
            let hostLogURL = probeRoot.appending(path: "logs/runtime-host-\(package.id).log")

            try FileManager.default.createDirectory(
                at: launchPackageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(package).write(to: launchPackageURL)

            try await EmbeddedRuntimeHostSDKBridge.launch(
                EmbeddedRuntimeHostInvocation(
                    packageID: package.id,
                    hostBinaryURL: URL(
                        fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true
                    )
                    .appending(path: "Runtime/runtime-host.bin"),
                    launchPackageURL: launchPackageURL,
                    sessionUpdateURL: sessionUpdateURL,
                    terminalResultURL: terminalResultURL,
                    telemetryURL: telemetryURL,
                    hostLogURL: hostLogURL
                )
            )

            let terminal = try JSONDecoder().decode(
                RuntimeBackendTerminalResult.self,
                from: Data(contentsOf: terminalResultURL)
            )
            let output = try String(contentsOf: outputURL, encoding: .utf8)
            let hostLog = try String(contentsOf: hostLogURL, encoding: .utf8)
            let versionStampURL = extractedRoot.appending(path: ".iridium-userland-version")

            XCTAssertEqual(terminal.terminalStatus, RuntimeHostSessionState.completed.rawValue)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: extractedRoot.appending(path: "bin/wine64").path))
            XCTAssertTrue(output.contains("source=archive"))
            XCTAssertTrue(output.contains("arg1=\(package.executablePath)"))
            XCTAssertTrue(output.contains("arg2=--archive-smoke"))
            XCTAssertTrue(hostLog.contains("userland-unpack=ok"))
            XCTAssertTrue(hostLog.contains("userland-root=\(extractedRoot.path)"))
            XCTAssertEqual(
                try String(contentsOf: versionStampURL, encoding: .utf8),
                fixture.runtimeBundle.version
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: telemetryURL.path))
        #else
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = try await makeRuntimeLaunchFixture(
                root: root, title: "BundledUserlandProbe")
            var package = try makeBackendLaunchPackage(from: fixture)

            let outputURL = root.appending(path: "bundled-userland-output.txt")
            let bundledRoot = URL(
                fileURLWithPath: fixture.runtimeBundle.bundleRootPath ?? "", isDirectory: true
            )
            .appending(path: "Userland/root", directoryHint: .isDirectory)
            try writeEmbeddedWineUserlandRoot(
                at: bundledRoot,
                wineScript: """
                    #!/bin/sh
                    {
                      printf 'source=bundled-root\\n'
                      printf 'arg1=%s\\n' "$1"
                      printf 'arg2=%s\\n' "$2"
                    } > "$IRIDIUM_TEST_OUTPUT_FILE"
                    exit 0
                    """
            )

            let extractedRoot = URL(
                fileURLWithPath: fixture.runtimeBundle.bundleRootPath ?? "", isDirectory: true
            )
            .appending(path: "Userland/extracted", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: extractedRoot.path) {
                try FileManager.default.removeItem(at: extractedRoot)
            }

            package.launchArguments = ["--archive-smoke"]
            package.environment["IRIDIUM_HOST_ENABLE_EXTERNAL_ENGINE"] = "1"
            package.environment["IRIDIUM_TEST_OUTPUT_FILE"] = outputURL.path

            let probeRoot = root.appending(
                path: "bundled-userland-probe", directoryHint: .isDirectory)
            let launchPackageURL = probeRoot.appending(path: "requests/launch-\(package.id).json")
            let sessionUpdateURL = probeRoot.appending(path: "responses/session-\(package.id).json")
            let terminalResultURL = probeRoot.appending(
                path: "responses/terminal-\(package.id).json")
            let telemetryURL = probeRoot.appending(path: "responses/telemetry-\(package.id).json")
            let hostLogURL = probeRoot.appending(path: "logs/runtime-host-\(package.id).log")

            try FileManager.default.createDirectory(
                at: launchPackageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(package).write(to: launchPackageURL)

            try await EmbeddedRuntimeHostSDKBridge.launch(
                EmbeddedRuntimeHostInvocation(
                    packageID: package.id,
                    hostBinaryURL: URL(
                        fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true
                    )
                    .appending(path: "Runtime/runtime-host.bin"),
                    launchPackageURL: launchPackageURL,
                    sessionUpdateURL: sessionUpdateURL,
                    terminalResultURL: terminalResultURL,
                    telemetryURL: telemetryURL,
                    hostLogURL: hostLogURL
                )
            )

            let terminal = try JSONDecoder().decode(
                RuntimeBackendTerminalResult.self,
                from: Data(contentsOf: terminalResultURL)
            )
            let output = try String(contentsOf: outputURL, encoding: .utf8)
            let hostLog = try String(contentsOf: hostLogURL, encoding: .utf8)

            XCTAssertEqual(terminal.terminalStatus, RuntimeHostSessionState.completed.rawValue)
            XCTAssertTrue(output.contains("source=bundled-root"))
            XCTAssertTrue(output.contains("arg1=\(package.executablePath)"))
            XCTAssertTrue(output.contains("arg2=--archive-smoke"))
            XCTAssertTrue(hostLog.contains("userland-unpack=fallback-bundled-root"))
            XCTAssertTrue(hostLog.contains("userland-root=\(bundledRoot.path)"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: telemetryURL.path))
        #endif
    }

    func testEmbeddedRuntimeHostSDKBridgeRefreshesExtractedUserlandWhenBundleVersionChanges()
        async throws
    {
        #if os(macOS)
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = try await makeRuntimeLaunchFixture(
                root: root, title: "BundledUserlandRefreshProbe")
            var package = try makeBackendLaunchPackage(from: fixture)

            let bundleRoot = URL(
                fileURLWithPath: fixture.runtimeBundle.bundleRootPath ?? "", isDirectory: true)
            let archiveURL = bundleRoot.appending(path: "Userland/wine-userland.tar.zst")
            let extractedRoot = bundleRoot.appending(
                path: "Userland/extracted", directoryHint: .isDirectory)
            let versionStampURL = extractedRoot.appending(path: ".iridium-userland-version")

            func writeUserlandArchive(marker: String) throws {
                let sourceRoot = root.appending(
                    path: "userland-\(marker)", directoryHint: .isDirectory)
                let wineScript = """
                    #!/bin/sh
                    printf 'marker=%s\\n' "\(marker)" > "$IRIDIUM_TEST_OUTPUT_FILE"
                    exit 0
                    """
                try writeValidUserlandArchive(
                    to: archiveURL, root: sourceRoot, wineScript: wineScript, marker: marker)
            }

            func runLaunch(outputURL: URL, hostLogURL: URL) async throws {
                package.launchArguments = []
                package.environment["IRIDIUM_HOST_ENABLE_EXTERNAL_ENGINE"] = "1"
                package.environment["IRIDIUM_TEST_OUTPUT_FILE"] = outputURL.path

                let probeRoot = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                let launchPackageURL = probeRoot.appending(
                    path: "requests/launch-\(package.id).json")
                let sessionUpdateURL = probeRoot.appending(
                    path: "responses/session-\(package.id).json")
                let terminalResultURL = probeRoot.appending(
                    path: "responses/terminal-\(package.id).json")
                let telemetryURL = probeRoot.appending(
                    path: "responses/telemetry-\(package.id).json")

                try FileManager.default.createDirectory(
                    at: launchPackageURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(package).write(to: launchPackageURL)

                try await EmbeddedRuntimeHostSDKBridge.launch(
                    EmbeddedRuntimeHostInvocation(
                        packageID: package.id,
                        hostBinaryURL: URL(
                            fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true
                        )
                        .appending(path: "Runtime/runtime-host.bin"),
                        launchPackageURL: launchPackageURL,
                        sessionUpdateURL: sessionUpdateURL,
                        terminalResultURL: terminalResultURL,
                        telemetryURL: telemetryURL,
                        hostLogURL: hostLogURL
                    )
                )

                let terminal = try JSONDecoder().decode(
                    RuntimeBackendTerminalResult.self,
                    from: Data(contentsOf: terminalResultURL)
                )
                XCTAssertEqual(terminal.terminalStatus, RuntimeHostSessionState.completed.rawValue)
            }

            try writeUserlandArchive(marker: "v1")
            if FileManager.default.fileExists(atPath: extractedRoot.path) {
                try FileManager.default.removeItem(at: extractedRoot)
            }

            let firstOutputURL = root.appending(path: "userland-refresh-v1.txt")
            let firstLogURL = root.appending(path: "userland-refresh-v1.log")
            try await runLaunch(outputURL: firstOutputURL, hostLogURL: firstLogURL)
            XCTAssertTrue(
                (try String(contentsOf: firstOutputURL, encoding: .utf8)).contains("marker=v1"))
            XCTAssertEqual(
                try String(contentsOf: versionStampURL, encoding: .utf8),
                fixture.runtimeBundle.version)

            let manifestURL = bundleRoot.appending(path: "manifest.json")
            let updatedVersion = "2026.03.13"
            let manifestData = try Data(contentsOf: manifestURL)
            var manifest = try JSONDecoder().decode(RuntimeBundleManifest.self, from: manifestData)
            manifest.version = updatedVersion
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL)

            try writeUserlandArchive(marker: "v2")

            let secondOutputURL = root.appending(path: "userland-refresh-v2.txt")
            let secondLogURL = root.appending(path: "userland-refresh-v2.log")
            try await runLaunch(outputURL: secondOutputURL, hostLogURL: secondLogURL)

            XCTAssertTrue(
                (try String(contentsOf: secondOutputURL, encoding: .utf8)).contains("marker=v2"))
            XCTAssertEqual(try String(contentsOf: versionStampURL, encoding: .utf8), updatedVersion)
            XCTAssertTrue(
                (try String(contentsOf: secondLogURL, encoding: .utf8)).contains(
                    "userland-unpack=cleanup-ok"))
        #else
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = try await makeRuntimeLaunchFixture(
                root: root, title: "BundledUserlandRefreshProbe")
            var package = try makeBackendLaunchPackage(from: fixture)

            let bundleRoot = URL(
                fileURLWithPath: fixture.runtimeBundle.bundleRootPath ?? "", isDirectory: true)
            let extractedRoot = bundleRoot.appending(
                path: "Userland/extracted", directoryHint: .isDirectory)
            let bundledRoot = bundleRoot.appending(
                path: "Userland/root", directoryHint: .isDirectory)
            let versionStampURL = extractedRoot.appending(path: ".iridium-userland-version")

            func makeWineScript(marker: String) -> String {
                """
                #!/bin/sh
                printf 'marker=%s\\n' "\(marker)" > "$IRIDIUM_TEST_OUTPUT_FILE"
                exit 0
                """
            }

            func runLaunch(outputURL: URL, hostLogURL: URL) async throws {
                package.launchArguments = []
                package.environment["IRIDIUM_HOST_ENABLE_EXTERNAL_ENGINE"] = "1"
                package.environment["IRIDIUM_TEST_OUTPUT_FILE"] = outputURL.path

                let probeRoot = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                let launchPackageURL = probeRoot.appending(
                    path: "requests/launch-\(package.id).json")
                let sessionUpdateURL = probeRoot.appending(
                    path: "responses/session-\(package.id).json")
                let terminalResultURL = probeRoot.appending(
                    path: "responses/terminal-\(package.id).json")
                let telemetryURL = probeRoot.appending(
                    path: "responses/telemetry-\(package.id).json")

                try FileManager.default.createDirectory(
                    at: launchPackageURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(package).write(to: launchPackageURL)

                try await EmbeddedRuntimeHostSDKBridge.launch(
                    EmbeddedRuntimeHostInvocation(
                        packageID: package.id,
                        hostBinaryURL: URL(
                            fileURLWithPath: package.runtimeBundleRootPath, isDirectory: true
                        )
                        .appending(path: "Runtime/runtime-host.bin"),
                        launchPackageURL: launchPackageURL,
                        sessionUpdateURL: sessionUpdateURL,
                        terminalResultURL: terminalResultURL,
                        telemetryURL: telemetryURL,
                        hostLogURL: hostLogURL
                    )
                )

                let terminal = try JSONDecoder().decode(
                    RuntimeBackendTerminalResult.self,
                    from: Data(contentsOf: terminalResultURL)
                )
                XCTAssertEqual(terminal.terminalStatus, RuntimeHostSessionState.completed.rawValue)
            }

            try writeEmbeddedWineUserlandRoot(
                at: extractedRoot,
                wineScript: makeWineScript(marker: "existing"))
            try Data(fixture.runtimeBundle.version.utf8).write(to: versionStampURL)

            let firstOutputURL = root.appending(path: "userland-refresh-existing.txt")
            let firstLogURL = root.appending(path: "userland-refresh-existing.log")
            try await runLaunch(outputURL: firstOutputURL, hostLogURL: firstLogURL)
            XCTAssertTrue(
                (try String(contentsOf: firstOutputURL, encoding: .utf8)).contains(
                    "marker=existing"))
            XCTAssertTrue(
                (try String(contentsOf: firstLogURL, encoding: .utf8)).contains(
                    "userland-unpack=reused"))

            try writeEmbeddedWineUserlandRoot(
                at: bundledRoot,
                wineScript: makeWineScript(marker: "fallback"))
            try Data("stale-version".utf8).write(to: versionStampURL)

            let secondOutputURL = root.appending(path: "userland-refresh-fallback.txt")
            let secondLogURL = root.appending(path: "userland-refresh-fallback.log")
            try await runLaunch(outputURL: secondOutputURL, hostLogURL: secondLogURL)
            XCTAssertTrue(
                (try String(contentsOf: secondOutputURL, encoding: .utf8)).contains(
                    "marker=fallback"))
            XCTAssertTrue(
                (try String(contentsOf: secondLogURL, encoding: .utf8)).contains(
                    "userland-unpack=fallback-bundled-root"))
        #endif
    }

    func testRuntimeSessionExecutorBlocksDesktopShellEntrypoints() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBundle = try materializeRuntimeBundle(root: runtimeRoot)
        let executableURL = root.appending(path: "explorer.exe")
        try Data("explorer".utf8).write(to: executableURL)

        let game = GameRecord(
            title: "Blocked Shell",
            source: .manualImport,
            installPath: root.path,
            savePathMapping: "Documents/Saves/BlockedShell",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: executableURL.path,
                arguments: [],
                prefixID: UUID(),
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 0.1,
            summary: "Test title"
        )
        let prefix = PrefixRecord(
            id: game.launchProfile.prefixID,
            name: "Blocked Shell Prefix",
            runtimeName: runtimeBundle.name,
            state: .clean,
            storageFootprint: "2.0 GB",
            storageFootprintGB: 2.0
        )
        let session = LaunchCoordinator(
            runtime: runtimeBundle.descriptor,
            jitStatus: .ready,
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [runtimeBundle],
                selectedRuntimeBundle: runtimeBundle,
                constraints: [],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime
            ),
            runtimePolicy: RuntimePolicy(
                memoryBudgetClass: .compact,
                resolutionScale: 1.0,
                shaderStrategy: .onDemand
            )
        ).prepareLaunch(
            for: game,
            runtimeHealth: RuntimeHealthReport(
                status: .healthy,
                runtimeName: runtimeBundle.name,
                runtimeBundleIdentifier: runtimeBundle.id,
                runtimeBundleVersion: runtimeBundle.version,
                notes: []
            ),
            filePresence: ManagedFilePresence(installRootExists: true, executableExists: true)
        )

        let result = await makeDevelopmentRuntimeExecutor().execute(
            RuntimeSessionRequest(
                game: game,
                prefix: prefix,
                session: session,
                hostSnapshot: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 64,
                    deviceCapabilityClass: .balanced,
                    deviceTier: .tier2,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [runtimeBundle],
                    selectedRuntimeBundle: runtimeBundle,
                    constraints: [],
                    runtimeBridgeAvailable: true,
                    executionEnvironment: .nativeRuntime
                ),
                runtimeBundle: runtimeBundle,
                policy: RuntimePolicy(
                    memoryBudgetClass: .compact,
                    resolutionScale: 1.0,
                    shaderStrategy: .onDemand
                )
            )
        )

        switch result {
        case .success:
            XCTFail("Desktop shell executable should not launch.")
        case .failure(let failure):
            XCTAssertEqual(failure.code, .desktopShellEntrypointBlocked)
        }
    }

    func testRuntimeSessionExecutorRejectsExecutableFingerprintMismatch() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBundle = try materializeRuntimeBundle(root: runtimeRoot)
        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("current-binary".utf8).write(to: executableURL)

        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: root.path,
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: executableURL.path,
                arguments: [],
                prefixID: UUID(),
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 0.1,
            managedArtifactIdentifier: "samplelightweightgame",
            executableFingerprint: "stale-fingerprint",
            summary: "Test title"
        )
        let prefix = PrefixRecord(
            id: game.launchProfile.prefixID,
            name: "SampleLightweightGame Prefix",
            runtimeName: runtimeBundle.name,
            state: .clean,
            storageFootprint: "2.0 GB",
            storageFootprintGB: 2.0
        )

        let result = await makeDevelopmentRuntimeExecutor().execute(
            RuntimeSessionRequest(
                game: game,
                prefix: prefix,
                session: LaunchSession(
                    gameID: game.id,
                    title: game.title,
                    executablePath: executableURL.path,
                    arguments: [],
                    workingDirectory: root.path,
                    environment: ["IRIDIUM_NO_DESKTOP": "1"],
                    readiness: .ready,
                    issues: []
                ),
                hostSnapshot: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 64,
                    deviceCapabilityClass: .balanced,
                    deviceTier: .tier2,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [runtimeBundle],
                    selectedRuntimeBundle: runtimeBundle,
                    constraints: [],
                    runtimeBridgeAvailable: true,
                    executionEnvironment: .nativeRuntime
                ),
                runtimeBundle: runtimeBundle,
                policy: RuntimePolicy(
                    memoryBudgetClass: .compact,
                    resolutionScale: 1.0,
                    shaderStrategy: .onDemand
                )
            )
        )

        switch result {
        case .success:
            XCTFail("Fingerprint mismatch should block launch.")
        case .failure(let failure):
            XCTAssertEqual(failure.code, .executableFingerprintMismatch)
        }
    }

    func testRuntimeSessionExecutorPreservesHostSessionContextOnRuntimeFailure() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBundle = try materializeRuntimeBundle(root: runtimeRoot)
        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("samplelightweightgame".utf8).write(to: executableURL)

        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: root.path,
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: executableURL.path,
                arguments: [],
                prefixID: UUID(),
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 0.1,
            managedArtifactIdentifier: "samplelightweightgame",
            executableFingerprint: try FileSystemGameArtifactInventory().fingerprintExecutable(
                at: executableURL.path
            ).value,
            summary: "Test title"
        )
        let prefix = PrefixRecord(
            id: game.launchProfile.prefixID,
            name: "SampleLightweightGame Prefix",
            runtimeName: runtimeBundle.name,
            state: .clean,
            storageFootprint: "2.0 GB",
            storageFootprintGB: 2.0
        )

        let result = await makeDevelopmentRuntimeExecutor().execute(
            RuntimeSessionRequest(
                game: game,
                prefix: prefix,
                session: LaunchSession(
                    gameID: game.id,
                    title: game.title,
                    executablePath: executableURL.path,
                    arguments: [],
                    workingDirectory: root.path,
                    environment: [
                        "IRIDIUM_NO_DESKTOP": "1",
                        "IRIDIUM_FORCE_CRASH": "1",
                    ],
                    readiness: .ready,
                    issues: []
                ),
                hostSnapshot: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 64,
                    deviceCapabilityClass: .balanced,
                    deviceTier: .tier2,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [runtimeBundle],
                    selectedRuntimeBundle: runtimeBundle,
                    constraints: [],
                    runtimeBridgeAvailable: true,
                    executionEnvironment: .nativeRuntime
                ),
                runtimeBundle: runtimeBundle,
                policy: RuntimePolicy(
                    memoryBudgetClass: .compact,
                    resolutionScale: 1.0,
                    shaderStrategy: .onDemand
                )
            )
        )

        switch result {
        case .success:
            XCTFail("Forced runtime crash should fail launch.")
        case .failure(let failure):
            XCTAssertEqual(failure.code, .gameProcessExited)
            XCTAssertEqual(failure.terminalStatus, RuntimeHostSessionState.failed.rawValue)
            XCTAssertEqual(failure.runtimeBundleVersion, runtimeBundle.version)
            XCTAssertFalse(failure.hostSessionIdentifier?.isEmpty ?? true)
            XCTAssertTrue(failure.stateHistory.contains(RuntimeHostSessionState.running.rawValue))
            XCTAssertEqual(failure.stateHistory.last, RuntimeHostSessionState.failed.rawValue)
            XCTAssertNotNil(failure.launchedAt)
        }
    }

    func testRuntimeSessionExecutorFailsClosedWhenBackendStartFails() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBundle = try materializeRuntimeBundle(root: runtimeRoot)
        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("samplelightweightgame".utf8).write(to: executableURL)

        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: root.path,
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: executableURL.path,
                arguments: [],
                prefixID: UUID(),
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 0.1,
            managedArtifactIdentifier: "samplelightweightgame",
            executableFingerprint: try FileSystemGameArtifactInventory().fingerprintExecutable(
                at: executableURL.path
            ).value,
            summary: "Test title"
        )
        let prefix = PrefixRecord(
            id: game.launchProfile.prefixID,
            name: "SampleLightweightGame Prefix",
            runtimeName: runtimeBundle.name,
            state: .clean,
            storageFootprint: "2.0 GB",
            storageFootprintGB: 2.0
        )

        let result = await makeRuntimeExecutor(backendClient: FailingRuntimeBackendClient())
            .execute(
                RuntimeSessionRequest(
                    game: game,
                    prefix: prefix,
                    session: LaunchSession(
                        gameID: game.id,
                        title: game.title,
                        executablePath: executableURL.path,
                        arguments: [],
                        workingDirectory: root.path,
                        environment: ["IRIDIUM_NO_DESKTOP": "1"],
                        readiness: .ready,
                        issues: []
                    ),
                    hostSnapshot: HostCapabilitySnapshot(
                        jitStatus: .ready,
                        availableManagedStorageGB: 64,
                        deviceCapabilityClass: .balanced,
                        deviceTier: .tier1,
                        thermalState: .nominal,
                        lowPowerModeEnabled: false,
                        runtimeBundles: [runtimeBundle],
                        selectedRuntimeBundle: runtimeBundle,
                        constraints: [],
                        runtimeBridgeAvailable: true,
                        executionEnvironment: .nativeRuntime
                    ),
                    runtimeBundle: runtimeBundle,
                    policy: RuntimePolicy(
                        memoryBudgetClass: .compact,
                        resolutionScale: 1.0,
                        shaderStrategy: .onDemand
                    )
                )
            )

        switch result {
        case .success:
            XCTFail("Backend start failure should not fall back to synthetic success.")
        case .failure(let failure):
            XCTAssertEqual(failure.code, .runtimeBootFailed)
            XCTAssertEqual(failure.reason, "Runtime backend rejected session start.")
        }
    }

    func testRuntimeSessionExecutorRecordsMissingTelemetryHonestly() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBundle = try materializeRuntimeBundle(root: runtimeRoot)
        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("samplelightweightgame".utf8).write(to: executableURL)

        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: root.path,
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: executableURL.path,
                arguments: [],
                prefixID: UUID(),
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 0.1,
            managedArtifactIdentifier: "samplelightweightgame",
            executableFingerprint: try FileSystemGameArtifactInventory().fingerprintExecutable(
                at: executableURL.path
            ).value,
            summary: "Test title"
        )
        let prefix = PrefixRecord(
            id: game.launchProfile.prefixID,
            name: "SampleLightweightGame Prefix",
            runtimeName: runtimeBundle.name,
            state: .clean,
            storageFootprint: "2.0 GB",
            storageFootprintGB: 2.0
        )
        let backendClient = DevelopmentRuntimeBackendClient()

        let result = await makeRuntimeExecutor(backendClient: backendClient).execute(
            RuntimeSessionRequest(
                game: game,
                prefix: prefix,
                session: LaunchSession(
                    gameID: game.id,
                    title: game.title,
                    executablePath: executableURL.path,
                    arguments: [],
                    workingDirectory: root.path,
                    environment: [
                        "IRIDIUM_NO_DESKTOP": "1",
                        "IRIDIUM_BACKEND_NO_TELEMETRY": "1",
                    ],
                    readiness: .ready,
                    issues: []
                ),
                hostSnapshot: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 64,
                    deviceCapabilityClass: .balanced,
                    deviceTier: .tier1,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [runtimeBundle],
                    selectedRuntimeBundle: runtimeBundle,
                    constraints: [],
                    runtimeBridgeAvailable: true,
                    executionEnvironment: .nativeRuntime
                ),
                runtimeBundle: runtimeBundle,
                policy: RuntimePolicy(
                    memoryBudgetClass: .compact,
                    resolutionScale: 1.0,
                    shaderStrategy: .onDemand
                )
            )
        )

        switch result {
        case .success(let payload):
            XCTAssertNil(payload.telemetrySnapshot)
            XCTAssertEqual(payload.mitigationAction, .none)
        case .failure(let failure):
            XCTFail("Missing backend telemetry should not force a synthetic failure: \(failure)")
        }
    }

    func testRuntimeSessionExecutorAcceptsRunningSessionWhenTerminalResultIsDeferred() async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try await makeRuntimeLaunchFixture(root: root, title: "DeferredTerminalProbe")
        let executor = makeRuntimeExecutor(backendClient: DeferredTerminalRuntimeBackendClient())

        let result = await executor.execute(
            RuntimeSessionRequest(
                game: fixture.game,
                prefix: fixture.prefix,
                session: LaunchSession(
                    gameID: fixture.game.id,
                    title: fixture.game.title,
                    executablePath: fixture.ticket.executablePath,
                    arguments: fixture.ticket.launchArguments,
                    workingDirectory: fixture.ticket.workingDirectory,
                    environment: fixture.ticket.environment,
                    readiness: .ready,
                    issues: []
                ),
                hostSnapshot: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 64,
                    deviceCapabilityClass: .balanced,
                    deviceTier: .tier1,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [fixture.runtimeBundle],
                    selectedRuntimeBundle: fixture.runtimeBundle,
                    constraints: [],
                    runtimeBridgeAvailable: true,
                    executionEnvironment: .nativeRuntime
                ),
                runtimeBundle: fixture.runtimeBundle,
                policy: RuntimePolicy(
                    memoryBudgetClass: .compact,
                    resolutionScale: 1.0,
                    shaderStrategy: .onDemand
                )
            )
        )

        switch result {
        case .success(let payload):
            XCTAssertEqual(payload.terminalStatus, RuntimeHostSessionState.running.rawValue)
            XCTAssertEqual(payload.stateHistory.last, RuntimeHostSessionState.running.rawValue)
            XCTAssertTrue(payload.stateHistory.contains(RuntimeHostSessionState.running.rawValue))
            XCTAssertNil(payload.telemetrySnapshot)
            XCTAssertEqual(payload.mitigationAction, .none)
        case .failure(let failure):
            XCTFail(
                "A deferred terminal result should still report a running launch session, got \(failure)"
            )
        }
    }

    func testRuntimeSessionExecutorWaitsForRunningBeforePreferredFullscreenHandoff()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try await makeRuntimeLaunchFixture(root: root, title: "FullscreenHandoffProbe")
        let hostController = QueuedHandoffRuntimeHostController()
        let monitor = RunningHandoffRuntimeExecutionMonitor()
        let telemetryCollector = CountingRuntimeTelemetryCollector()
        let executor = FileSystemRuntimeSessionExecutor(
            hostController: hostController,
            executionMonitor: monitor,
            telemetryCollector: telemetryCollector
        )
        let preferredSessionIdentifier = "fullscreen-session-\(UUID().uuidString)"

        let result = await executor.execute(
            RuntimeSessionRequest(
                game: fixture.game,
                prefix: fixture.prefix,
                session: LaunchSession(
                    gameID: fixture.game.id,
                    title: fixture.game.title,
                    executablePath: fixture.ticket.executablePath,
                    arguments: fixture.ticket.launchArguments,
                    workingDirectory: fixture.ticket.workingDirectory,
                    environment: fixture.ticket.environment,
                    readiness: .ready,
                    issues: []
                ),
                hostSnapshot: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 64,
                    deviceCapabilityClass: .balanced,
                    deviceTier: .tier1,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [fixture.runtimeBundle],
                    selectedRuntimeBundle: fixture.runtimeBundle,
                    constraints: [],
                    runtimeBridgeAvailable: true,
                    executionEnvironment: .nativeRuntime
                ),
                runtimeBundle: fixture.runtimeBundle,
                policy: RuntimePolicy(
                    memoryBudgetClass: .compact,
                    resolutionScale: 1.0,
                    shaderStrategy: .onDemand
                ),
                preferredSessionIdentifier: preferredSessionIdentifier
            )
        )

        switch result {
        case .success(let payload):
            XCTAssertEqual(payload.sessionIdentifier, preferredSessionIdentifier)
            XCTAssertEqual(payload.terminalStatus, RuntimeHostSessionState.running.rawValue)
            XCTAssertEqual(payload.stateHistory.last, RuntimeHostSessionState.running.rawValue)
            XCTAssertNil(payload.telemetrySnapshot)
            XCTAssertEqual(payload.mitigationAction, .none)
        case .failure(let failure):
            XCTFail("Preferred fullscreen handoff should wait for running state: \(failure)")
        }
        let submitCount = await hostController.submitCount()
        let monitorCount = await monitor.count()
        let telemetryCount = await telemetryCollector.count()
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(monitorCount, 1)
        XCTAssertEqual(telemetryCount, 0)
    }

    func testRuntimeExecutionMonitorKeepsBootingSessionNonTerminalWhenTerminalResultIsAbsent()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try await makeRuntimeLaunchFixture(root: root, title: "BootingRuntimeProbe")
        let backendClient = StalledBootingRuntimeBackendClient()

        let submission = await FileSystemRuntimeHostController(backendClient: backendClient).submit(
            ticket: fixture.ticket
        )
        let session: RuntimeHostSession
        switch submission {
        case .success(let value):
            session = value
        case .failure(let failure):
            XCTFail("Expected stalled booting submission to succeed, got \(failure)")
            return
        }

        let resolved = await FileSystemRuntimeExecutionMonitor(backendClient: backendClient)
            .resolveTerminalState(for: session)

        XCTAssertEqual(resolved.state, .bootingRuntime)
        XCTAssertEqual(resolved.failureCode, nil)
        XCTAssertEqual(resolved.failureReason, nil)
        XCTAssertEqual(
            resolved.statusSummary,
            "Embedded FEX is initializing FEXCore runtime and loading Wine binary."
        )
    }

    func testRunningSessionObserverWaitsPastBootingRuntimeForTrueTerminalState() async {
        let sessionIdentifier = UUID().uuidString
        let monitor = BootingThenCompletedRuntimeExecutionMonitor()
        let observer = FileSystemRuntimeRunningSessionObserver(
            executionMonitor: monitor,
            pollInterval: .milliseconds(1)
        )
        let execution = RuntimeSessionResult(
            sessionIdentifier: sessionIdentifier,
            terminalStatus: RuntimeHostSessionState.running.rawValue,
            launchTicketPath: "/tmp/launch-\(sessionIdentifier).json",
            sessionLogPath: "/tmp/session-\(sessionIdentifier).log",
            telemetryPath: "/tmp/telemetry-\(sessionIdentifier).json",
            prefixManifestPath: "/tmp/prefix-\(sessionIdentifier).json",
            runtimeBundleID: "iridium-runtime-base",
            runtimeBundleVersion: "physical-build-56-regression",
            resolvedExecutablePath: "/tmp/hollow_knight.exe",
            stateHistory: [RuntimeHostSessionState.running.rawValue],
            environment: [:],
            telemetrySnapshot: nil,
            mitigationAction: .none
        )

        let resolved = await observer.resolveTerminalState(
            from: execution,
            gameID: UUID(),
            gameTitle: "Hollow Knight"
        )
        let resolveCount = await monitor.count()

        XCTAssertFalse(RuntimeHostSessionState.queued.isTerminal)
        XCTAssertFalse(RuntimeHostSessionState.bootstrappingPrefix.isTerminal)
        XCTAssertFalse(RuntimeHostSessionState.bootingRuntime.isTerminal)
        XCTAssertFalse(RuntimeHostSessionState.running.isTerminal)
        XCTAssertTrue(RuntimeHostSessionState.completed.isTerminal)
        XCTAssertTrue(RuntimeHostSessionState.failed.isTerminal)
        XCTAssertEqual(resolved.state, .completed)
        XCTAssertEqual(resolveCount, 2)
    }

    func testProviderBackedRuntimeBackendFailsClosedWithoutProviderResponse() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let providerRoot = root.appending(path: "provider", directoryHint: .isDirectory)
        let runtimeRoot = root.appending(path: "RuntimeBundles", directoryHint: .isDirectory)
        let runtimeBundle = try materializeRuntimeBundle(root: runtimeRoot)
        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("samplelightweightgame".utf8).write(to: executableURL)
        let prefixManifestURL = root.appending(path: "prefix.json")
        let runtimeConfigurationURL = root.appending(path: "runtime.json")
        let environmentFileURL = root.appending(path: "runtime.env")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(
            PrefixBootstrapManifest(
                prefixID: UUID(),
                title: "SampleLightweightGame",
                executableFingerprint: nil,
                runtimeBundleID: runtimeBundle.id,
                runtimeBundleVersion: runtimeBundle.version,
                prefixRootPath: root.appending(path: "prefix", directoryHint: .isDirectory).path,
                runtimeBundleRootPath: runtimeBundle.bundleRootPath,
                environmentFilePath: environmentFileURL.path,
                runtimeConfigurationPath: runtimeConfigurationURL.path,
                environmentOverrides: ["IRIDIUM_NO_DESKTOP": "1"]
            )
        ).write(to: prefixManifestURL, options: .atomic)
        try Data("{}".utf8).write(to: runtimeConfigurationURL, options: .atomic)
        try Data("IRIDIUM_NO_DESKTOP=1\n".utf8).write(to: environmentFileURL, options: .atomic)
        let package = RuntimeBackendLaunchPackage(
            id: "provider-timeout",
            gameID: UUID(),
            gameTitle: "SampleLightweightGame",
            executablePath: executableURL.path,
            workingDirectory: root.path,
            launchArguments: [],
            environment: ["IRIDIUM_NO_DESKTOP": "1"],
            runtimeBundleID: runtimeBundle.id,
            runtimeBundleVersion: runtimeBundle.version,
            runtimeBundleRootPath: runtimeBundle.bundleRootPath ?? "",
            prefixID: UUID(),
            prefixManifestPath: prefixManifestURL.path,
            runtimeConfigurationPath: runtimeConfigurationURL.path,
            environmentFilePath: environmentFileURL.path,
            rendererPreset: RendererPreset.metalOpenGLFallback.rawValue,
            directLaunchOnly: true
        )

        let result = await ProviderBackedRuntimeBackendClient(
            configuration: RuntimeProviderConfiguration(rootURL: providerRoot)
        ).startSession(package)

        switch result {
        case .success:
            XCTFail("Missing provider response should fail closed.")
        case .failure(let failure):
            XCTAssertEqual(failure.code, .runtimeBootFailed)
            XCTAssertTrue(
                failure.reason.contains("Runtime provider did not acknowledge session start"))
        }
    }

    func testProviderBackedRuntimeBackendRejectsDesktopShellSubmission() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let providerRoot = root.appending(path: "provider", directoryHint: .isDirectory)
        let requestURL = providerRoot.appending(path: "requests/launch-shell-blocked.json")
        let package = RuntimeBackendLaunchPackage(
            id: "shell-blocked",
            gameID: UUID(),
            gameTitle: "Desktop Shell",
            executablePath: "/Windows/explorer.exe",
            workingDirectory: root.path,
            launchArguments: [],
            environment: ["IRIDIUM_NO_DESKTOP": "1"],
            runtimeBundleID: "iridium-runtime-base",
            runtimeBundleVersion: FileSystemRuntimeBundleRegistry.defaultManifest.version,
            runtimeBundleRootPath: root.appending(
                path: "RuntimeBundles/iridium-runtime-base", directoryHint: .isDirectory
            ).path,
            prefixID: UUID(),
            prefixManifestPath: root.appending(path: "prefix.json").path,
            runtimeConfigurationPath: root.appending(path: "runtime.json").path,
            environmentFilePath: root.appending(path: "runtime.env").path,
            rendererPreset: RendererPreset.metalOpenGLFallback.rawValue,
            directLaunchOnly: true
        )

        let result = await ProviderBackedRuntimeBackendClient(
            configuration: RuntimeProviderConfiguration(rootURL: providerRoot)
        ).startSession(package)

        switch result {
        case .success:
            XCTFail("Desktop shell entrypoints should be rejected before provider submission.")
        case .failure(let failure):
            XCTAssertEqual(failure.code, .desktopShellEntrypointBlocked)
            XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))
        }
    }

    func testProviderBackedRuntimeBackendRejectsMissingBootstrapInputsBeforeSubmission()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let providerRoot = root.appending(path: "provider", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("samplelightweightgame".utf8).write(to: executableURL)

        let package = RuntimeBackendLaunchPackage(
            id: "missing-bootstrap-inputs",
            gameID: UUID(),
            gameTitle: "SampleLightweightGame",
            executablePath: executableURL.path,
            workingDirectory: root.path,
            launchArguments: [],
            environment: ["IRIDIUM_NO_DESKTOP": "1"],
            runtimeBundleID: "iridium-runtime-base",
            runtimeBundleVersion: FileSystemRuntimeBundleRegistry.defaultManifest.version,
            runtimeBundleRootPath: root.appending(
                path: "RuntimeBundles/iridium-runtime-base", directoryHint: .isDirectory
            ).path,
            prefixID: UUID(),
            prefixManifestPath: root.appending(path: "prefix.json").path,
            runtimeConfigurationPath: root.appending(path: "runtime.json").path,
            environmentFilePath: root.appending(path: "runtime.env").path,
            rendererPreset: RendererPreset.metalOpenGLFallback.rawValue,
            directLaunchOnly: true
        )

        let result = await ProviderBackedRuntimeBackendClient(
            configuration: RuntimeProviderConfiguration(rootURL: providerRoot)
        ).startSession(package)

        switch result {
        case .success:
            XCTFail(
                "Provider-backed runtime backend should fail closed when bootstrap inputs are missing."
            )
        case .failure(let failure):
            XCTAssertEqual(failure.code, .prefixBootstrapFailed)
            XCTAssertTrue(failure.reason.contains("missing the prepared prefix manifest"))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: providerRoot.appending(
                        path: "requests/launch-missing-bootstrap-inputs.json"
                    ).path
                )
            )
        }
    }

    func testProviderBackedRuntimeHostPersistsOrderedSessionHistoryAndTelemetry() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let providerRoot = root.appending(path: "provider", directoryHint: .isDirectory)
        let fixture = try await makeRuntimeLaunchFixture(root: root)
        let providerConfig = RuntimeProviderConfiguration(rootURL: providerRoot)
        let backendClient = ProviderBackedRuntimeBackendClient(configuration: providerConfig)
        let requestURL = providerConfig.requestsRootURL.appending(
            path: "launch-\(fixture.ticket.id).json")
        let sessionResponseURL = providerConfig.responsesRootURL.appending(
            path: "session-\(fixture.ticket.id).json")
        let terminalResponseURL = providerConfig.responsesRootURL.appending(
            path: "terminal-\(fixture.ticket.id).json")
        let telemetryResponseURL = providerConfig.responsesRootURL.appending(
            path: "telemetry-\(fixture.ticket.id).json")
        let ticketID = fixture.ticket.id

        Task {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard await waitForFile(at: requestURL) else {
                return
            }
            try? FileManager.default.createDirectory(
                at: providerConfig.responsesRootURL, withIntermediateDirectories: true)
            try? encoder.encode(
                RuntimeBackendSessionUpdate(
                    id: ticketID,
                    state: .queued,
                    stateHistory: [.queued],
                    statusSummary: "Provider accepted the launch package."
                )
            ).write(to: sessionResponseURL, options: .atomic)
            try? encoder.encode(
                BridgeHeartbeatStatus(lastUpdatedAt: Date(), serviceName: "IridiumRuntimeProvider")
            ).write(to: providerConfig.statusURL, options: .atomic)
            try? await Task.sleep(nanoseconds: 100 * 1_000_000)
            try? encoder.encode(
                RuntimeBackendSessionUpdate(
                    id: ticketID,
                    state: .running,
                    stateHistory: [.queued, .bootstrappingPrefix, .bootingRuntime, .running],
                    statusSummary: "Provider entered shell-free execution."
                )
            ).write(to: sessionResponseURL, options: .atomic)
            try? await Task.sleep(nanoseconds: 100 * 1_000_000)
            try? encoder.encode(
                RuntimeBackendTerminalResult(
                    id: ticketID,
                    terminalStatus: RuntimeHostSessionState.completed.rawValue,
                    stateHistory: [
                        .queued, .bootstrappingPrefix, .bootingRuntime, .running, .completed,
                    ]
                )
            ).write(to: terminalResponseURL, options: .atomic)
            try? encoder.encode(
                PerformanceTelemetrySnapshot(
                    averageFPS: 58,
                    frameTimeP95MS: 20,
                    memoryPressureRatio: 0.51,
                    thermalState: .nominal
                )
            ).write(to: telemetryResponseURL, options: .atomic)
        }

        let submission = await FileSystemRuntimeHostController(backendClient: backendClient).submit(
            ticket: fixture.ticket)
        let session: RuntimeHostSession
        switch submission {
        case .success(let value):
            session = value
            XCTAssertEqual(value.state, .queued)
        case .failure(let failure):
            XCTFail("Expected provider-backed submission to succeed, got \(failure)")
            return
        }

        let terminal = await FileSystemRuntimeExecutionMonitor(backendClient: backendClient)
            .resolveTerminalState(for: session)
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertEqual(
            terminal.stateHistory,
            [.queued, .bootstrappingPrefix, .bootingRuntime, .running, .completed]
        )

        let telemetry = await FileSystemRuntimeTelemetryCollector(backendClient: backendClient)
            .collect(
                for: terminal,
                policy: RuntimePolicy(
                    memoryBudgetClass: .compact, resolutionScale: 1.0, shaderStrategy: .onDemand)
            )
        XCTAssertEqual(telemetry?.averageFPS, 58)
    }

    func testRuntimeSessionExecutorRecordsMissingProviderTelemetryHonestly() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let providerConfig = RuntimeProviderConfiguration(
            rootURL: root.appending(path: "provider", directoryHint: .isDirectory))
        let fixture = try await makeRuntimeLaunchFixture(root: root)
        let backendClient = ProviderBackedRuntimeBackendClient(configuration: providerConfig)

        Task {
            guard await waitForFile(at: providerConfig.requestsRootURL) else {
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard
                let requestURL = try? FileManager.default.contentsOfDirectory(
                    at: providerConfig.requestsRootURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).first(where: { $0.lastPathComponent.hasPrefix("launch-") })
            else {
                return
            }
            let ticketID = requestURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "launch-", with: "")
            let sessionResponseURL = providerConfig.responsesRootURL.appending(
                path: "session-\(ticketID).json")
            let terminalResponseURL = providerConfig.responsesRootURL.appending(
                path: "terminal-\(ticketID).json")
            try? FileManager.default.createDirectory(
                at: providerConfig.responsesRootURL, withIntermediateDirectories: true)
            try? encoder.encode(
                RuntimeBackendSessionUpdate(
                    id: ticketID,
                    state: .queued,
                    stateHistory: [.queued],
                    statusSummary: "Provider accepted the launch package."
                )
            ).write(to: sessionResponseURL, options: .atomic)
            try? await Task.sleep(nanoseconds: 100 * 1_000_000)
            try? encoder.encode(
                RuntimeBackendTerminalResult(
                    id: ticketID,
                    terminalStatus: RuntimeHostSessionState.completed.rawValue,
                    stateHistory: [
                        .queued, .bootstrappingPrefix, .bootingRuntime, .running, .completed,
                    ]
                )
            ).write(to: terminalResponseURL, options: .atomic)
        }

        let executor = makeRuntimeExecutor(backendClient: backendClient)
        let result = await executor.execute(
            RuntimeSessionRequest(
                game: fixture.game,
                prefix: fixture.prefix,
                session: LaunchSession(
                    gameID: fixture.game.id,
                    title: fixture.game.title,
                    executablePath: fixture.ticket.executablePath,
                    arguments: [],
                    workingDirectory: fixture.game.installPath,
                    environment: fixture.ticket.environment,
                    readiness: .ready,
                    issues: []
                ),
                hostSnapshot: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 64,
                    deviceCapabilityClass: .balanced,
                    deviceTier: .tier1,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [fixture.runtimeBundle],
                    selectedRuntimeBundle: fixture.runtimeBundle,
                    constraints: [],
                    runtimeBridgeAvailable: true,
                    executionEnvironment: .nativeRuntime
                ),
                runtimeBundle: fixture.runtimeBundle,
                policy: RuntimePolicy(
                    memoryBudgetClass: .compact,
                    resolutionScale: 1.0,
                    shaderStrategy: .onDemand
                )
            )
        )

        switch result {
        case .success(let payload):
            XCTAssertNil(payload.telemetrySnapshot)
            XCTAssertEqual(payload.mitigationAction, .none)
        case .failure(let failure):
            XCTFail(
                "Missing provider telemetry should remain an honest success with nil telemetry, got \(failure)"
            )
        }
    }

    func testRuntimeSessionExecutorPropagatesHostJITStatusIntoBootstrapEnvironment() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try await makeRuntimeLaunchFixture(root: root)
        let backendClient = CapturingRuntimeBackendClient()
        let executor = makeRuntimeExecutor(backendClient: backendClient)

        var sessionEnvironment = fixture.ticket.environment
        sessionEnvironment["IRIDIUM_HOST_JIT_STATUS"] = nil

        let result = await executor.execute(
            RuntimeSessionRequest(
                game: fixture.game,
                prefix: fixture.prefix,
                session: LaunchSession(
                    gameID: fixture.game.id,
                    title: fixture.game.title,
                    executablePath: fixture.ticket.executablePath,
                    arguments: [],
                    workingDirectory: fixture.game.installPath,
                    environment: sessionEnvironment,
                    readiness: .ready,
                    issues: []
                ),
                hostSnapshot: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 64,
                    deviceCapabilityClass: .balanced,
                    deviceTier: .tier1,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [fixture.runtimeBundle],
                    selectedRuntimeBundle: fixture.runtimeBundle,
                    constraints: [],
                    runtimeBridgeAvailable: true,
                    executionEnvironment: .nativeRuntime
                ),
                runtimeBundle: fixture.runtimeBundle,
                policy: RuntimePolicy(
                    memoryBudgetClass: .compact,
                    resolutionScale: 1.0,
                    shaderStrategy: .onDemand
                )
            )
        )

        switch result {
        case .success(let payload):
            let package = await backendClient.lastCapturedPackage()
            XCTAssertEqual(
                package?.environment["IRIDIUM_HOST_JIT_STATUS"], JITStatus.ready.rawValue)
            XCTAssertEqual(payload.environment["IRIDIUM_HOST_JIT_STATUS"], JITStatus.ready.rawValue)
            XCTAssertEqual(package?.environment["IRIDIUM_WINE_IOS_GRAPHICS_DRIVER"], "wineios.drv")
            XCTAssertEqual(package?.environment["IRIDIUM_WINE_IOS_AUDIO_DRIVER"], "winecoreaudio.drv")

            guard let environmentFilePath = package?.environmentFilePath else {
                XCTFail(
                    "Expected backend package to capture the generated runtime environment file path."
                )
                return
            }
            let environmentFile = try String(contentsOfFile: environmentFilePath, encoding: .utf8)
            XCTAssertTrue(environmentFile.contains("IRIDIUM_HOST_JIT_STATUS=ready"))
        case .failure(let failure):
            XCTFail("Expected runtime session execution to succeed, got \(failure)")
        }
    }

    func testRuntimeSessionExecutorFailsClosedWhenLaunchBootstrapIsUnavailable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try await makeRuntimeLaunchFixture(root: root)
        let backendClient = CapturingRuntimeBackendClient()
        let executor = makeRuntimeExecutor(backendClient: backendClient)

        let result = await executor.execute(
            RuntimeSessionRequest(
                game: fixture.game,
                prefix: fixture.prefix,
                session: LaunchSession(
                    gameID: fixture.game.id,
                    title: fixture.game.title,
                    executablePath: fixture.ticket.executablePath,
                    arguments: [],
                    workingDirectory: fixture.game.installPath,
                    environment: fixture.ticket.environment,
                    readiness: .ready,
                    issues: []
                ),
                hostSnapshot: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 64,
                    deviceCapabilityClass: .balanced,
                    deviceTier: .tier1,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [fixture.runtimeBundle],
                    selectedRuntimeBundle: fixture.runtimeBundle,
                    constraints: [],
                    runtimeBridgeAvailable: true,
                    executionEnvironment: .nativeRuntime,
                    launchReady: false,
                    launchStatus: "xcodeDebugCheckOnly",
                    launchStatusSummary:
                        "Xcode-attached JIT checks use lightweight debugger detection only. Direct launch stays blocked until the embedded runtime backend is validated outside the Xcode check flow."
                ),
                runtimeBundle: fixture.runtimeBundle,
                policy: RuntimePolicy(
                    memoryBudgetClass: .compact,
                    resolutionScale: 1.0,
                    shaderStrategy: .onDemand
                )
            )
        )

        switch result {
        case .success:
            XCTFail("Expected execution to fail closed when launch bootstrap is unavailable.")
        case .failure(let failure):
            XCTAssertEqual(failure.code, .jitNotReady)
            XCTAssertEqual(
                failure.reason,
                "Xcode-attached JIT checks use lightweight debugger detection only. Direct launch stays blocked until the embedded runtime backend is validated outside the Xcode check flow."
            )
        }

        let package = await backendClient.lastCapturedPackage()
        XCTAssertNil(package)
    }

    func testRuntimeHostRejectsMissingRuntimeConfigurationInputs() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        _ = try materializeRuntimeBundle(root: runtimeRoot)
        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("samplelightweightgame".utf8).write(to: executableURL)

        let prefixManifestURL = root.appending(path: "prefix.json")
        let prefixRoot = root.appending(path: "prefix", directoryHint: .isDirectory)
        let environmentFileURL = prefixRoot.appending(path: "config/runtime.env")
        let runtimeConfigurationURL = prefixRoot.appending(path: "config/runtime.json")
        try FileManager.default.createDirectory(at: prefixRoot, withIntermediateDirectories: true)
        let manifest = PrefixBootstrapManifest(
            prefixID: UUID(),
            title: "SampleLightweightGame",
            executableFingerprint: nil,
            runtimeBundleID: "iridium-runtime-base",
            runtimeBundleVersion: FileSystemRuntimeBundleRegistry.defaultManifest.version,
            prefixRootPath: prefixRoot.path,
            runtimeBundleRootPath: runtimeRoot.appending(
                path: "iridium-runtime-base", directoryHint: .isDirectory
            ).path,
            environmentFilePath: environmentFileURL.path,
            runtimeConfigurationPath: runtimeConfigurationURL.path,
            environmentOverrides: ["IRIDIUM_NO_DESKTOP": "1"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: environmentFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("IRIDIUM_NO_DESKTOP=1\n".utf8).write(to: environmentFileURL, options: .atomic)
        try encoder.encode(manifest).write(to: prefixManifestURL, options: .atomic)

        let submission = await FileSystemRuntimeHostController().submit(
            ticket: RuntimeLaunchTicket(
                gameID: UUID(),
                gameTitle: "SampleLightweightGame",
                executablePath: executableURL.path,
                workingDirectory: root.path,
                launchArguments: [],
                environment: ["IRIDIUM_NO_DESKTOP": "1"],
                runtimeBundleID: "iridium-runtime-base",
                runtimeBundleVersion: FileSystemRuntimeBundleRegistry.defaultManifest.version,
                prefixID: manifest.prefixID,
                prefixManifestPath: prefixManifestURL.path
            )
        )

        switch submission {
        case .success:
            XCTFail("Missing runtime config inputs should block host submission.")
        case .failure(let failure):
            XCTAssertEqual(failure.code, .prefixBootstrapFailed)
            XCTAssertTrue(failure.reason.contains("runtime configuration file"))
        }
    }

    func testImportScannerPrefersGameExecutableOverInstallerArtifacts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: root.appending(path: "SampleLightweightGame.exe").path, contents: Data())
        FileManager.default.createFile(
            atPath: root.appending(path: "unins000.exe").path, contents: Data())
        FileManager.default.createFile(
            atPath: root.appending(path: "CrashReporter.exe").path, contents: Data())

        let result = ImportScanner().scan(installPath: root.path, title: "SampleLightweightGame")

        XCTAssertEqual(result.recommendedExecutable?.filename, "SampleLightweightGame.exe")
        XCTAssertEqual(result.executables.first?.filename, "SampleLightweightGame.exe")
    }

    func testLaunchCoordinatorInjectsNoDesktopEnvironment() {
        let prefixID = UUID()
        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .steam,
            installPath: "/Managed/Steam/SampleLightweightGame",
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: "SampleLightweightGame.exe",
                arguments: ["--windowed"],
                prefixID: prefixID,
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["steam"]
            ),
            installedSizeGB: 1.2,
            summary: "Test title"
        )

        let session = LaunchCoordinator(
            runtime: .defaultDescriptor,
            jitStatus: .ready
        ).prepareLaunch(
            for: game,
            runtimeHealth: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: []
            )
        )

        XCTAssertEqual(session.readiness, .ready)
        XCTAssertEqual(session.environment["IRIDIUM_NO_DESKTOP"], "1")
        XCTAssertTrue(
            session.executablePath.hasSuffix(
                "/Managed/Steam/SampleLightweightGame/SampleLightweightGame.exe"))
    }

    func testLaunchCoordinatorBlocksWhenJITIsNotReady() {
        let prefixID = UUID()
        let game = GameRecord(
            title: "SamplePerformanceGame",
            source: .manualImport,
            installPath: "/Managed/Imports/SamplePerformanceGame",
            savePathMapping: "Documents/Saves/SamplePerformanceGame",
            compatibilityProfileName: "performance-default",
            inputProfileName: "Controller + KBM",
            touchOverlayName: "Racing Overlay",
            controllerPresetName: "Racing Triggers",
            keyboardMouseEnabled: true,
            prefixState: .customized,
            deviceTier: .tier2,
            rendererPreset: .dxvkPerformance,
            launchProfile: GameLaunchProfile(
                executablePath: "SamplePerformanceGame.exe",
                arguments: [],
                prefixID: prefixID,
                rendererPreset: .dxvkPerformance,
                deviceTier: .tier2,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 15.3,
            summary: "Test title"
        )

        let session = LaunchCoordinator(
            runtime: .defaultDescriptor,
            jitStatus: .required
        ).prepareLaunch(
            for: game,
            runtimeHealth: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: []
            )
        )

        XCTAssertEqual(session.readiness, .blockedByJIT)
        XCTAssertTrue(session.issues.contains(where: { $0.message.contains("JIT") }))
    }

    func testLaunchCoordinatorSurfacesHostFailureWhenJITIsUnavailable() {
        let prefixID = UUID()
        let game = GameRecord(
            title: "SamplePerformanceGame",
            source: .manualImport,
            installPath: "/Managed/Imports/SamplePerformanceGame",
            savePathMapping: "Documents/Saves/SamplePerformanceGame",
            compatibilityProfileName: "performance-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Default Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .customized,
            deviceTier: .tier2,
            rendererPreset: .dxvkPerformance,
            launchProfile: GameLaunchProfile(
                executablePath: "SamplePerformanceGame.exe",
                arguments: [],
                prefixID: prefixID,
                rendererPreset: .dxvkPerformance,
                deviceTier: .tier2,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 15.3,
            summary: "Test title"
        )

        let summary =
            "Embedded FEX runtime could not allocate a MAP_JIT code page: Operation not permitted"
        let session = LaunchCoordinator(
            runtime: .defaultDescriptor,
            jitStatus: .unavailable,
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .unavailable,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
                selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
                constraints: [summary],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime,
                launchReady: false,
                launchStatus: "jitUnavailable",
                launchStatusSummary: summary
            )
        ).prepareLaunch(
            for: game,
            runtimeHealth: RuntimeHealthReport(
                status: .actionRequired,
                runtimeName: "Iridium Runtime Base",
                notes: [summary]
            )
        )

        XCTAssertEqual(session.readiness, .blockedByJIT)
        XCTAssertEqual(session.issues.first(where: { $0.severity == .blocking })?.message, summary)
    }

    func testLaunchCoordinatorBlocksWhenEmbeddedLaunchSupportIsUnavailable() {
        let prefixID = UUID()
        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: "/Managed/Imports/SampleLightweightGame",
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: "SampleLightweightGame.exe",
                arguments: [],
                prefixID: prefixID,
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 1.2,
            summary: "Test title"
        )

        let session = LaunchCoordinator(
            runtime: .defaultDescriptor,
            jitStatus: .ready,
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier1,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
                selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
                constraints: [],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime,
                launchReady: false,
                launchStatus: "bootstrapMissing",
                launchStatusSummary:
                    "Embedded FEX build does not include the FEXCore runtime bootstrap."
            )
        ).prepareLaunch(
            for: game,
            runtimeHealth: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: []
            )
        )

        XCTAssertEqual(session.readiness, .blockedByPolicy)
        XCTAssertTrue(
            session.issues.contains(
                where: { $0.message.contains("FEXCore runtime bootstrap") }
            )
        )
    }

    func testLaunchCoordinatorSurfacesHelperBootstrapSummaryWhenDebuggerAttachNeedsBootstrap() {
        let prefixID = UUID()
        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: "/Managed/Imports/SampleLightweightGame",
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: "SampleLightweightGame.exe",
                arguments: [],
                prefixID: prefixID,
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 1.2,
            summary: "Test title"
        )

        let summary =
            "Debugger attach is present, but StikDebug still needs to complete the required executable region bootstrap script."
        let session = LaunchCoordinator(
            runtime: .defaultDescriptor,
            jitStatus: .unavailable,
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .unavailable,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier1,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
                selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
                constraints: [summary],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime,
                launchReady: false,
                launchStatus: "jitBootstrapRequired",
                launchStatusSummary: summary,
                allocatorBackend: "debugger-mirrored-rx-rw",
                jitSessionKind: .debuggerBacked,
                jitFailureStage: "external bootstrap required",
                jitToolRecommendation: .stikDebug,
                jitToolBootstrapRequired: true,
                jitToolBootstrapKind: "stikdebug-script",
                jitToolBootstrapSummary: summary,
                jitSummary: summary
            )
        ).prepareLaunch(
            for: game,
            runtimeHealth: RuntimeHealthReport(
                status: .actionRequired,
                runtimeName: "Iridium Runtime Base",
                notes: [summary]
            )
        )

        XCTAssertEqual(session.readiness, .blockedByJIT)
        XCTAssertEqual(session.issues.first(where: { $0.severity == .blocking })?.message, summary)
    }

    func testLaunchCoordinatorDoesNotTreatReadyStikDebugSessionAsXcodeOnly() {
        let prefixID = UUID()
        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: "/Managed/Imports/SampleLightweightGame",
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: "SampleLightweightGame.exe",
                arguments: [],
                prefixID: prefixID,
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 1.2,
            summary: "Test title"
        )

        let session = LaunchCoordinator(
            runtime: .defaultDescriptor,
            jitStatus: .ready,
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier1,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
                selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
                constraints: [],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime,
                launchReady: true,
                launchStatus: "ready",
                launchStatusSummary: "Runtime ready.",
                allocatorBackend: "debugger-mirrored-rx-rw",
                jitSessionKind: .debuggerBacked,
                jitFailureStage: "execution probe skipped under xcode debugger",
                jitToolRecommendation: .stikDebug,
                jitSummary: "Runtime ready.",
                exceptionPortsActive: false
            )
        ).prepareLaunch(
            for: game,
            runtimeHealth: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: []
            )
        )

        XCTAssertNotEqual(session.readiness, .blockedByPolicy)
        XCTAssertFalse(
            session.issues.contains {
                $0.message.contains("Xcode-attached JIT checks use lightweight debugger detection only.")
            }
        )
    }

    func testLaunchCoordinatorBlocksWhenManagedExecutableIsMissing() {
        let prefixID = UUID()
        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: "/Managed/Imports/SampleLightweightGame",
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: "SampleLightweightGame.exe",
                arguments: [],
                prefixID: prefixID,
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 1.2,
            summary: "Test title"
        )

        let session = LaunchCoordinator(
            runtime: .defaultDescriptor,
            jitStatus: .ready
        ).prepareLaunch(
            for: game,
            runtimeHealth: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: []
            ),
            filePresence: ManagedFilePresence(installRootExists: true, executableExists: false)
        )

        XCTAssertEqual(session.readiness, .missingExecutable)
        XCTAssertTrue(
            session.issues.contains(where: { $0.message.contains("Launch target is missing") }))
    }

    func testSteamInstallPlannerProvidesExpectedLaunchTargetForHeavyTitle() {
        let entry = SteamLibraryEntry(
            title: "SampleHeavyGame",
            appID: "1659040",
            installed: false,
            cloudSavesEnabled: true
        )

        let plan = SteamInstallPlanner().plan(
            for: entry, targetPath: "/Managed/Steam/SampleHeavyGame")

        XCTAssertTrue(plan.primaryExecutable.isEmpty)
        XCTAssertEqual(
            plan.verificationSteps, ["Steam bridge unavailable; install planning is blocked."])
    }

    func testManifestResolverProvidesMultipleDepotsForHeavyTitle() {
        let entry = SteamLibraryEntry(
            title: "SampleHeavyGame",
            appID: "1659040",
            installed: false,
            cloudSavesEnabled: true
        )

        let manifest = SteamManifestResolver().resolve(for: entry)

        XCTAssertEqual(manifest.branchName, "unavailable")
        XCTAssertTrue(manifest.depots.isEmpty)
        XCTAssertEqual(
            manifest.verificationStages,
            ["Steam bridge unavailable; manifest resolution is blocked."])
    }

    func testInstallPipelineMarksInstalledTitleAsCompleted() {
        let entry = SteamLibraryEntry(
            title: "SampleLightweightGame",
            appID: "2379780",
            installed: true,
            cloudSavesEnabled: true
        )
        let plan = SteamInstallPlanner().plan(
            for: entry, targetPath: "/Managed/Steam/SampleLightweightGame")
        let manifest = SteamManifestResolver().resolve(for: entry)

        let pipeline = InstallPipelineBuilder().build(
            for: entry,
            plan: plan,
            manifest: manifest,
            task: DownloadTask(
                title: "SampleLightweightGame",
                progress: 1.0,
                state: .installed,
                detail: "Installed and verified.",
                reservedDiskGB: 0
            ),
            execution: InstallExecutionRecord(
                title: "SampleLightweightGame",
                appID: "2379780",
                buildID: manifest.buildID,
                branchName: manifest.branchName,
                targetPath: "/Managed/Steam/SampleLightweightGame",
                primaryExecutable: "SampleLightweightGame.exe",
                depotIDs: ["2379781"],
                depotMountPaths: ["2379781": "Game"],
                completedDepotIDs: ["2379781"],
                stage: .completed,
                detail: "Mounted and complete.",
                reservedDiskGB: 3
            )
        )

        XCTAssertTrue(pipeline.phases.allSatisfy { $0.state == .completed })
    }

    func testEligibilityAuditorBlocksWhenRuntimeAndPipelineAreNotReady() {
        let prefixID = UUID()
        let game = GameRecord(
            title: "SampleHeavyGame",
            source: .steam,
            installPath: "/Managed/Steam/SampleHeavyGame",
            savePathMapping: "Documents/Saves/SampleHeavyGame",
            compatibilityProfileName: "heavy-whitelist",
            inputProfileName: "Controller + Precision Touch",
            touchOverlayName: "Stealth Overlay",
            controllerPresetName: "Shooter Layout",
            keyboardMouseEnabled: true,
            prefixState: .customized,
            deviceTier: .tier3,
            rendererPreset: .vkd3dHighCompatibility,
            launchProfile: GameLaunchProfile(
                executablePath: "SampleHeavyGame.exe",
                arguments: ["-skip_launcher"],
                prefixID: prefixID,
                rendererPreset: .vkd3dHighCompatibility,
                deviceTier: .tier3,
                titleFlags: ["steam", "tier3-whitelist"]
            ),
            installedSizeGB: 91.7,
            summary: "Test title"
        )
        let entry = SteamLibraryEntry(
            title: game.title,
            appID: "1659040",
            installed: false,
            cloudSavesEnabled: true
        )
        let plan = SteamInstallPlanner().plan(for: entry, targetPath: game.installPath)
        let manifest = SteamManifestResolver().resolve(for: entry)
        let pipeline = InstallPipelineBuilder().build(
            for: entry,
            plan: plan,
            manifest: manifest,
            task: DownloadTask(
                title: entry.title,
                progress: 0.4,
                state: .downloading,
                detail: "Downloading",
                reservedDiskGB: 115
            ),
            execution: InstallExecutionRecord(
                title: entry.title,
                appID: entry.appID,
                buildID: manifest.buildID,
                branchName: manifest.branchName,
                targetPath: game.installPath,
                primaryExecutable: plan.primaryExecutable,
                depotIDs: manifest.depots.map(\.depotID),
                depotMountPaths: Dictionary(
                    uniqueKeysWithValues: manifest.depots.map { ($0.depotID, $0.mountedPath) }),
                completedDepotIDs: ["1659041"],
                stage: .downloading,
                detail: "Downloaded 1 depot.",
                reservedDiskGB: 115
            )
        )
        let session = LaunchCoordinator(runtime: .defaultDescriptor, jitStatus: .ready)
            .prepareLaunch(
                for: game,
                runtimeHealth: RuntimeHealthReport(
                    status: .actionRequired,
                    runtimeName: "Iridium Runtime Base",
                    notes: ["Runtime validation is required."]
                )
            )
        let report = LaunchEligibilityAuditor().audit(
            game: game,
            session: session,
            runtimeHealth: RuntimeHealthReport(
                status: .actionRequired,
                runtimeName: "Iridium Runtime Base",
                notes: ["Runtime validation is required."]
            ),
            storage: ManagedStorageStatus(
                totalCapacityGB: 256,
                reservedForSystemGB: 24,
                usedByGamesGB: 140,
                usedByPrefixesGB: 12,
                reservedForQueuedDownloadsGB: 70,
                pressure: .critical,
                notes: ["Headroom exhausted."]
            ),
            pipeline: pipeline
        )

        XCTAssertEqual(report.overallStatus, .blocked)
        XCTAssertTrue(
            report.checks.contains(where: { $0.title == "Runtime health" && $0.status == .blocked })
        )
        XCTAssertTrue(
            report.checks.contains(where: {
                $0.title == "Install pipeline" && $0.status == .blocked
            }))
    }

    func testEligibilityAuditorBlocksWhenManagedExecutableIsMissing() {
        let prefixID = UUID()
        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: "/Managed/Imports/SampleLightweightGame",
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: "/Managed/Imports/SampleLightweightGame/SampleLightweightGame.exe",
                arguments: [],
                prefixID: prefixID,
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 1.2,
            summary: "Test title"
        )

        let session = LaunchCoordinator(runtime: .defaultDescriptor, jitStatus: .ready)
            .prepareLaunch(
                for: game,
                runtimeHealth: RuntimeHealthReport(
                    status: .healthy,
                    runtimeName: "Iridium Runtime Base",
                    notes: []
                )
            )

        let report = LaunchEligibilityAuditor().audit(
            game: game,
            session: session,
            runtimeHealth: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: []
            ),
            storage: ManagedStorageStatus(
                totalCapacityGB: 256,
                reservedForSystemGB: 24,
                usedByGamesGB: 8,
                usedByPrefixesGB: 4,
                reservedForQueuedDownloadsGB: 0,
                pressure: .healthy,
                notes: []
            ),
            pipeline: nil,
            filePresence: ManagedFilePresence(installRootExists: true, executableExists: false)
        )

        XCTAssertEqual(report.overallStatus, .blocked)
        XCTAssertTrue(
            report.checks.contains(where: { $0.title == "Managed files" && $0.status == .blocked }))
    }

    func testInstallPipelineUsesExecutionStageForMountedPhase() {
        let entry = SteamLibraryEntry(
            title: "SampleBalancedGame",
            appID: "1145350",
            installed: false,
            cloudSavesEnabled: true
        )
        let plan = SteamInstallPlanner().plan(
            for: entry, targetPath: "/Managed/Steam/SampleBalancedGame")
        let manifest = SteamManifestResolver().resolve(for: entry)

        let pipeline = InstallPipelineBuilder().build(
            for: entry,
            plan: plan,
            manifest: manifest,
            task: DownloadTask(
                title: entry.title,
                progress: 0.94,
                state: .mounting,
                detail: "Mounting runtime target",
                reservedDiskGB: 24
            ),
            execution: InstallExecutionRecord(
                title: entry.title,
                appID: entry.appID,
                buildID: manifest.buildID,
                branchName: manifest.branchName,
                targetPath: "/Managed/Steam/SampleBalancedGame",
                primaryExecutable: plan.primaryExecutable,
                depotIDs: manifest.depots.map(\.depotID),
                depotMountPaths: Dictionary(
                    uniqueKeysWithValues: manifest.depots.map { ($0.depotID, $0.mountedPath) }),
                completedDepotIDs: manifest.depots.map(\.depotID),
                stage: .mounting,
                detail: "Verification passed.",
                reservedDiskGB: 24
            )
        )

        XCTAssertEqual(
            pipeline.phases.first(where: { $0.title == "Resolve depots" })?.state, .completed)
        XCTAssertEqual(
            pipeline.phases.first(where: { $0.title == "Download payloads" })?.state, .completed)
        XCTAssertEqual(
            pipeline.phases.first(where: { $0.title == "Verify content" })?.state, .completed)
        XCTAssertEqual(
            pipeline.phases.first(where: { $0.title == "Mount runtime target" })?.state, .inFlight)
    }

    func testNativeSteamInstallCoordinatorTracksResumeVerificationAndCompletion() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let targetPath = root.appending(
            path: "Managed/Steam/SampleGame", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: targetPath, withIntermediateDirectories: true)
        let entry = SteamLibraryEntry(
            title: "Sample Game",
            appID: "1000000",
            installed: false,
            cloudSavesEnabled: true
        )
        let runtimeBundle = FileSystemRuntimeBundleRegistry.defaultManifest
        let plan = SteamInstallPlan(
            title: entry.title,
            appID: entry.appID,
            targetPath: targetPath.path,
            primaryExecutable: "SampleGame.exe",
            contentSets: ["base-game"],
            estimatedInstallSizeGB: 8.0,
            requiredDiskHeadroomGB: 12.0,
            verificationSteps: ["Verify install manifest", "Validate runtime mount"]
        )
        let manifest = SteamManifestResolution(
            title: entry.title,
            appID: entry.appID,
            buildID: "sample-game-build",
            branchName: "public",
            depots: [
                SteamDepotManifest(
                    depotID: "1000001",
                    manifestID: "111222333444",
                    label: "Base Game",
                    compressedSizeGB: 7.5,
                    mountedPath: "Game"
                )
            ],
            verificationStages: ["Verify install manifest", "Validate runtime mount"]
        )
        let coordinator = NativeSteamInstallCoordinator(
            contentClient: FixtureSteamContentServerClient(),
            verificationService: FixtureDepotVerificationService()
        )
        let seededExecution = DefaultDepotTransferEngine().makeExecution(
            for: entry, plan: plan, manifest: manifest)
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

        execution = await coordinator.advance(execution: execution, manifest: manifest)
        XCTAssertEqual(execution.stage, .resolving)

        execution = await coordinator.advance(execution: execution, manifest: manifest)
        XCTAssertEqual(execution.stage, .verifying)
        XCTAssertFalse(execution.resumeCheckpoint?.isEmpty ?? true)
        XCTAssertEqual(execution.completedDepotIDs, manifest.depots.map(\.depotID))

        execution = await coordinator.advance(execution: execution, manifest: manifest)
        XCTAssertEqual(execution.stage, .mounting)
        XCTAssertEqual(execution.depotVerifiedIDs, manifest.depots.map(\.depotID))

        execution = await coordinator.advance(execution: execution, manifest: manifest)
        XCTAssertEqual(execution.stage, .completed)
        XCTAssertEqual(execution.depotVerifiedIDs, manifest.depots.map(\.depotID))

        execution = await coordinator.advance(execution: execution, manifest: manifest)
        XCTAssertEqual(execution.stage, .completed)
        XCTAssertEqual(execution.runtimeBundleIdentifier, runtimeBundle.id)
        XCTAssertEqual(execution.runtimeBundleVersion, runtimeBundle.version)
        XCTAssertEqual(execution.managedArtifactIdentifier, "sample-game")
        XCTAssertFalse(execution.executableFingerprint?.isEmpty ?? true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetPath.appending(path: plan.primaryExecutable).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetPath.appending(path: ".iridium/steam-host/mount.json").path
            )
        )
    }

    func testWhitelistBlocksHeavyTitleOnTierTwoHost() {
        let game = GameRecord(
            title: "Heavy Sample Game",
            source: .steam,
            installPath: "/Managed/Steam/HeavySampleGame",
            savePathMapping: "Documents/Saves/HeavySampleGame",
            compatibilityProfileName: "heavy-whitelist",
            inputProfileName: "Controller + Precision Touch",
            touchOverlayName: "Heavy Overlay",
            controllerPresetName: "Shooter Layout",
            keyboardMouseEnabled: true,
            prefixState: .customized,
            deviceTier: .tier3,
            rendererPreset: .vkd3dHighCompatibility,
            launchProfile: GameLaunchProfile(
                executablePath: "HeavyGame.exe",
                arguments: ["-skip_launcher"],
                prefixID: UUID(),
                rendererPreset: .vkd3dHighCompatibility,
                deviceTier: .tier3,
                titleFlags: ["steam", "tier3-whitelist"]
            ),
            installedSizeGB: 91.7,
            summary: "Test title"
        )

        let result = DefaultWhitelistPolicy().evaluate(
            game: game,
            runtimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 128,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
                selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
                constraints: []
            ),
            runtimePolicy: RuntimePolicy(
                memoryBudgetClass: .expansive,
                rendererOverride: .vkd3dHighCompatibility,
                resolutionScale: 0.7,
                framePacingCap: 45,
                shaderStrategy: .fullPrewarm,
                requiresExplicitWhitelist: true
            )
        )

        switch result {
        case .success:
            XCTFail("Expected tier-two host to be blocked")
        case .failure(let failure):
            XCTAssertEqual(failure.code, .whitelistBlocked)
        }
    }

    func testWhitelistAllowsHeavyProfileOnTierThreeWithSufficientBundleVersion() {
        let game = GameRecord(
            title: "Heavy Sample Game",
            source: .steam,
            installPath: "/Managed/Steam/HeavySampleGame",
            savePathMapping: "Documents/Saves/HeavySampleGame",
            compatibilityProfileName: "heavy-whitelist",
            inputProfileName: "Controller + Precision Touch",
            touchOverlayName: "Heavy Overlay",
            controllerPresetName: "Shooter Layout",
            keyboardMouseEnabled: true,
            prefixState: .customized,
            deviceTier: .tier3,
            rendererPreset: .vkd3dHighCompatibility,
            launchProfile: GameLaunchProfile(
                executablePath: "HeavyGame.exe",
                arguments: ["-skip_launcher"],
                prefixID: UUID(),
                rendererPreset: .vkd3dHighCompatibility,
                deviceTier: .tier3,
                titleFlags: ["steam", "tier3-whitelist"]
            ),
            installedSizeGB: 91.7,
            summary: "Test title"
        )

        let bundle = RuntimeBundleManifest(
            id: FileSystemRuntimeBundleRegistry.defaultManifest.id,
            name: FileSystemRuntimeBundleRegistry.defaultManifest.name,
            version: FileSystemRuntimeBundleRegistry.defaultManifest.version,
            descriptor: FileSystemRuntimeBundleRegistry.defaultManifest.descriptor,
            artifacts: FileSystemRuntimeBundleRegistry.defaultManifest.artifacts,
            minimumDeviceTier: .tier3,
            supportsDirectGameLaunch: true,
            bundleRootPath: FileSystemRuntimeBundleRegistry.defaultManifest.bundleRootPath,
            supportMetadata: FileSystemRuntimeBundleRegistry.defaultManifest.supportMetadata
        )

        let result = DefaultWhitelistPolicy().evaluate(
            game: game,
            runtimeBundle: bundle,
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 128,
                deviceCapabilityClass: .heavyweight,
                deviceTier: .tier3,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [bundle],
                selectedRuntimeBundle: bundle,
                constraints: []
            ),
            runtimePolicy: RuntimePolicy(
                memoryBudgetClass: .expansive,
                rendererOverride: .vkd3dHighCompatibility,
                resolutionScale: 0.7,
                framePacingCap: 45,
                shaderStrategy: .fullPrewarm,
                requiresExplicitWhitelist: true
            )
        )

        switch result {
        case .success(let entry):
            XCTAssertEqual(entry?.id, "heavy-whitelist")
        case .failure(let failure):
            XCTFail("Expected whitelist to pass, got \(failure)")
        }
    }

    func testRuntimePolicyResolverAppliesGenericEvidence() {
        let game = GameRecord(
            title: "Performance Sample Game",
            source: .manualImport,
            installPath: "/Managed/Imports/PerformanceSampleGame",
            savePathMapping: "Documents/Saves/PerformanceSampleGame",
            compatibilityProfileName: "performance-default",
            inputProfileName: "Controller + KBM",
            touchOverlayName: "Performance Overlay",
            controllerPresetName: "Racing Triggers",
            keyboardMouseEnabled: true,
            prefixState: .customized,
            deviceTier: .tier2,
            rendererPreset: .dxvkPerformance,
            launchProfile: GameLaunchProfile(
                executablePath: "PerformanceGame.exe",
                arguments: [],
                prefixID: UUID(),
                rendererPreset: .dxvkPerformance,
                deviceTier: .tier2,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 15.3,
            managedArtifactIdentifier: "performance-sample",
            executableFingerprint: "fingerprint",
            summary: "Test title"
        )

        let resolver = DefaultRuntimePolicyResolver()
        let overrides = DefaultTitleOverrideResolver()
        let policy = resolver.resolve(
            game: game,
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
                selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
                constraints: []
            ),
            runtimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
            basePolicy: RuntimePolicy(
                memoryBudgetClass: .balanced,
                resolutionScale: 1.0,
                shaderStrategy: .onDemand
            ),
            overrideResolver: overrides
        )

        XCTAssertEqual(policy.rendererOverride, .metalOpenGLFallback)
        XCTAssertEqual(policy.framePacingCap, 45)
        XCTAssertEqual(overrides.evidenceSummary(for: game).contains("fingerprint"), true)
    }

    func testRuntimePolicyResolverResolvesGenericAcceptanceProfiles() {
        let resolver = DefaultRuntimePolicyResolver()
        let overrides = DefaultTitleOverrideResolver()
        let hostSnapshot = HostCapabilitySnapshot(
            jitStatus: .ready,
            availableManagedStorageGB: 128,
            deviceCapabilityClass: .balanced,
            deviceTier: .tier3,
            thermalState: .nominal,
            lowPowerModeEnabled: false,
            runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
            selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
            constraints: []
        )

        let lightweightPolicy = resolver.resolve(
            game: GameRecord(
                title: "Lightweight Sample Game",
                source: .manualImport,
                installPath: "/Managed/Imports/LightweightSampleGame",
                savePathMapping: "Documents/Saves/LightweightSampleGame",
                compatibilityProfileName: "lightweight-default",
                inputProfileName: "Touch + Controller",
                touchOverlayName: "Lightweight Touch Layout",
                controllerPresetName: "Standard Gamepad",
                keyboardMouseEnabled: true,
                prefixState: .clean,
                deviceTier: .tier1,
                rendererPreset: .metalOpenGLFallback,
                launchProfile: GameLaunchProfile(
                    executablePath: "LightweightGame.exe",
                    arguments: [],
                    prefixID: UUID(),
                    rendererPreset: .metalOpenGLFallback,
                    deviceTier: .tier1,
                    titleFlags: ["manual-import"]
                ),
                installedSizeGB: 1.2,
                managedArtifactIdentifier: "lightweight-sample",
                executableFingerprint: "lightweight-fingerprint",
                summary: "Generic title"
            ),
            hostSnapshot: hostSnapshot,
            runtimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
            basePolicy: RuntimePolicy(
                memoryBudgetClass: .balanced, resolutionScale: 1.0, shaderStrategy: .onDemand),
            overrideResolver: overrides
        )
        XCTAssertEqual(lightweightPolicy.rendererOverride, .metalOpenGLFallback)
        XCTAssertEqual(lightweightPolicy.memoryBudgetClass, .compact)
        XCTAssertEqual(
            lightweightPolicy.environmentOverrides["IRIDIUM_POLICY_PRECEDENCE"],
            "generic-broad-catalog")

        let balancedPolicy = resolver.resolve(
            game: GameRecord(
                title: "Balanced Sample Game",
                source: .steam,
                installPath: "/Managed/Steam/BalancedSampleGame",
                savePathMapping: "Documents/Saves/BalancedSampleGame",
                compatibilityProfileName: "balanced-default",
                inputProfileName: "Controller",
                touchOverlayName: "Balanced Overlay",
                controllerPresetName: "Standard Gamepad",
                keyboardMouseEnabled: false,
                prefixState: .clean,
                deviceTier: .tier2,
                rendererPreset: .dxvkBalanced,
                launchProfile: GameLaunchProfile(
                    executablePath: "BalancedGame.exe",
                    arguments: [],
                    prefixID: UUID(),
                    rendererPreset: .dxvkBalanced,
                    deviceTier: .tier2,
                    titleFlags: ["steam"]
                ),
                installedSizeGB: 16.4,
                managedArtifactIdentifier: "balanced-sample",
                executableFingerprint: "balanced-fingerprint",
                summary: "Generic title"
            ),
            hostSnapshot: hostSnapshot,
            runtimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
            basePolicy: RuntimePolicy(
                memoryBudgetClass: .balanced, resolutionScale: 1.0, shaderStrategy: .onDemand),
            overrideResolver: overrides
        )
        XCTAssertEqual(balancedPolicy.rendererOverride, .metalOpenGLFallback)
        XCTAssertEqual(balancedPolicy.framePacingCap, 60)

        let heavyTierThreeBundle = RuntimeBundleManifest(
            id: FileSystemRuntimeBundleRegistry.defaultManifest.id,
            name: FileSystemRuntimeBundleRegistry.defaultManifest.name,
            version: FileSystemRuntimeBundleRegistry.defaultManifest.version,
            descriptor: FileSystemRuntimeBundleRegistry.defaultManifest.descriptor,
            artifacts: FileSystemRuntimeBundleRegistry.defaultManifest.artifacts,
            minimumDeviceTier: .tier3,
            supportsDirectGameLaunch: true,
            bundleRootPath: FileSystemRuntimeBundleRegistry.defaultManifest.bundleRootPath,
            supportMetadata: FileSystemRuntimeBundleRegistry.defaultManifest.supportMetadata
        )

        let heavyPolicy = resolver.resolve(
            game: GameRecord(
                title: "Heavy Sample Game",
                source: .steam,
                installPath: "/Managed/Steam/HeavySampleGame",
                savePathMapping: "Documents/Saves/HeavySampleGame",
                compatibilityProfileName: "heavy-whitelist",
                inputProfileName: "Controller + Precision Touch",
                touchOverlayName: "Heavy Overlay",
                controllerPresetName: "Shooter Layout",
                keyboardMouseEnabled: true,
                prefixState: .customized,
                deviceTier: .tier3,
                rendererPreset: .vkd3dHighCompatibility,
                launchProfile: GameLaunchProfile(
                    executablePath: "HeavyGame.exe",
                    arguments: ["-skip_launcher"],
                    prefixID: UUID(),
                    rendererPreset: .vkd3dHighCompatibility,
                    deviceTier: .tier3,
                    titleFlags: ["steam", "tier3-whitelist"]
                ),
                installedSizeGB: 91.7,
                managedArtifactIdentifier: "heavy-sample",
                executableFingerprint: "heavy-fingerprint",
                summary: "Generic title"
            ),
            hostSnapshot: hostSnapshot,
            runtimeBundle: heavyTierThreeBundle,
            basePolicy: RuntimePolicy(
                memoryBudgetClass: .balanced, resolutionScale: 1.0, shaderStrategy: .onDemand),
            overrideResolver: overrides
        )
        XCTAssertEqual(heavyPolicy.rendererOverride, .metalOpenGLFallback)
        XCTAssertEqual(heavyPolicy.environmentOverrides["IRIDIUM_HEAVY_PROFILE"], "1")
        XCTAssertEqual(heavyPolicy.requiresExplicitWhitelist, true)
    }

    func testRuntimePolicyResolverClassifiesUnknownTitlesConservativelyByTier() {
        let resolver = DefaultRuntimePolicyResolver()
        let overrides = DefaultTitleOverrideResolver()
        let tierOneHost = HostCapabilitySnapshot(
            jitStatus: .ready,
            availableManagedStorageGB: 32,
            deviceCapabilityClass: .lightweight,
            deviceTier: .tier1,
            thermalState: .nominal,
            lowPowerModeEnabled: false,
            runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
            selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
            constraints: []
        )

        let lightweight = resolver.resolve(
            game: GameRecord(
                title: "Unknown Card Game",
                source: .manualImport,
                installPath: "/Managed/Imports/UnknownCardGame",
                savePathMapping: "Documents/Saves/UnknownCardGame",
                compatibilityProfileName: "unknown",
                inputProfileName: "Touch + Controller",
                touchOverlayName: "Default",
                controllerPresetName: "Default",
                keyboardMouseEnabled: true,
                prefixState: .clean,
                deviceTier: .tier1,
                rendererPreset: .metalOpenGLFallback,
                launchProfile: GameLaunchProfile(
                    executablePath: "Game.exe",
                    arguments: [],
                    prefixID: UUID(),
                    rendererPreset: .metalOpenGLFallback,
                    deviceTier: .tier1,
                    titleFlags: ["manual-import"]
                ),
                installedSizeGB: 2.4,
                summary: "Unknown title"
            ),
            hostSnapshot: tierOneHost,
            runtimeBundle: RuntimeBundleManifest(
                id: "dxvk-tier1",
                name: "DXVK Tier 1",
                version: "2026.03.13",
                descriptor: RuntimeDescriptor(
                    identifier: "dxvk-tier1",
                    name: "DXVK Tier 1",
                    cpuTranslation: .x64ToARM64JIT,
                    graphicsStack: .dxvkViaMoltenVK,
                    exposesDesktopShell: false
                ),
                artifacts: [],
                minimumDeviceTier: .tier1,
                supportsDirectGameLaunch: true
            ),
            basePolicy: RuntimePolicy(
                memoryBudgetClass: .balanced, resolutionScale: 1.0, shaderStrategy: .onDemand),
            overrideResolver: overrides
        )
        XCTAssertEqual(lightweight.memoryBudgetClass, MemoryBudgetClass.compact)
        XCTAssertEqual(lightweight.rendererOverride, RendererPreset.metalOpenGLFallback)
        XCTAssertEqual(lightweight.framePacingCap, 45)
        XCTAssertEqual(
            lightweight.environmentOverrides["IRIDIUM_TITLE_CLASS"], "lightweight-unknown")

        let balanced = resolver.resolve(
            game: GameRecord(
                title: "Unknown Action Game",
                source: .steam,
                installPath: "/Managed/Steam/UnknownActionGame",
                savePathMapping: "Documents/Saves/UnknownActionGame",
                compatibilityProfileName: "unknown",
                inputProfileName: "Controller",
                touchOverlayName: "Default",
                controllerPresetName: "Default",
                keyboardMouseEnabled: false,
                prefixState: .clean,
                deviceTier: .tier2,
                rendererPreset: .dxvkBalanced,
                launchProfile: GameLaunchProfile(
                    executablePath: "Game.exe",
                    arguments: [],
                    prefixID: UUID(),
                    rendererPreset: .dxvkBalanced,
                    deviceTier: .tier2,
                    titleFlags: ["steam"]
                ),
                installedSizeGB: 18.0,
                summary: "Unknown title"
            ),
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 128,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
                selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
                constraints: []
            ),
            runtimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
            basePolicy: RuntimePolicy(
                memoryBudgetClass: .balanced, resolutionScale: 1.0, shaderStrategy: .onDemand),
            overrideResolver: overrides
        )
        XCTAssertEqual(balanced.memoryBudgetClass, .balanced)
        XCTAssertEqual(balanced.rendererOverride, .metalOpenGLFallback)
        XCTAssertEqual(balanced.framePacingCap, 45)
        XCTAssertEqual(balanced.environmentOverrides["IRIDIUM_TITLE_CLASS"], "balanced-unknown")

        let heavy = resolver.resolve(
            game: GameRecord(
                title: "Unknown Open World Game",
                source: .steam,
                installPath: "/Managed/Steam/UnknownOpenWorldGame",
                savePathMapping: "Documents/Saves/UnknownOpenWorldGame",
                compatibilityProfileName: "unknown",
                inputProfileName: "Controller",
                touchOverlayName: "Default",
                controllerPresetName: "Default",
                keyboardMouseEnabled: true,
                prefixState: .clean,
                deviceTier: .tier3,
                rendererPreset: .vkd3dHighCompatibility,
                launchProfile: GameLaunchProfile(
                    executablePath: "Game.exe",
                    arguments: [],
                    prefixID: UUID(),
                    rendererPreset: .vkd3dHighCompatibility,
                    deviceTier: .tier3,
                    titleFlags: ["steam"]
                ),
                installedSizeGB: 75.0,
                summary: "Unknown title"
            ),
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 256,
                deviceCapabilityClass: .heavyweight,
                deviceTier: .tier3,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
                selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
                constraints: []
            ),
            runtimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
            basePolicy: RuntimePolicy(
                memoryBudgetClass: .balanced, resolutionScale: 1.0, shaderStrategy: .onDemand),
            overrideResolver: overrides
        )
        XCTAssertEqual(heavy.memoryBudgetClass, MemoryBudgetClass.expansive)
        XCTAssertEqual(heavy.rendererOverride, RendererPreset.metalOpenGLFallback)
        XCTAssertEqual(heavy.environmentOverrides["IRIDIUM_TITLE_CLASS"], "heavy-unknown")
    }

    func testRuntimePolicyResolverDowngradesRendererWhenBundleCannotSupportVKD3D() {
        let resolver = DefaultRuntimePolicyResolver()
        let overrides = DefaultTitleOverrideResolver()
        let dxvkOnlyBundle = RuntimeBundleManifest(
            id: "dxvk-only",
            name: "DXVK Only Runtime",
            version: "2026.03.13",
            descriptor: RuntimeDescriptor(
                identifier: "dxvk-only",
                name: "DXVK Only Runtime",
                cpuTranslation: .x64ToARM64JIT,
                graphicsStack: .dxvkViaMoltenVK,
                exposesDesktopShell: false
            ),
            artifacts: [],
            minimumDeviceTier: .tier1,
            supportsDirectGameLaunch: true
        )

        let policy = resolver.resolve(
            game: GameRecord(
                title: "SampleHeavyGame",
                source: .steam,
                installPath: "/Managed/Steam/SampleHeavyGame",
                savePathMapping: "Documents/Saves/SampleHeavyGame",
                compatibilityProfileName: "heavy-whitelist",
                inputProfileName: "Controller + Precision Touch",
                touchOverlayName: "Stealth Overlay",
                controllerPresetName: "Shooter Layout",
                keyboardMouseEnabled: true,
                prefixState: .customized,
                deviceTier: .tier3,
                rendererPreset: .vkd3dHighCompatibility,
                launchProfile: GameLaunchProfile(
                    executablePath: "SampleHeavyGame.exe",
                    arguments: ["-skip_launcher"],
                    prefixID: UUID(),
                    rendererPreset: .vkd3dHighCompatibility,
                    deviceTier: .tier3,
                    titleFlags: ["steam", "tier3-whitelist"]
                ),
                installedSizeGB: 91.7,
                summary: "Representative title"
            ),
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 256,
                deviceCapabilityClass: .heavyweight,
                deviceTier: .tier3,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [dxvkOnlyBundle],
                selectedRuntimeBundle: dxvkOnlyBundle,
                constraints: []
            ),
            runtimeBundle: dxvkOnlyBundle,
            basePolicy: RuntimePolicy(
                memoryBudgetClass: .balanced, resolutionScale: 1.0, shaderStrategy: .onDemand),
            overrideResolver: overrides
        )

        XCTAssertEqual(policy.rendererOverride, RendererPreset.dxvkBalanced)
    }

    func testLaunchCoordinatorBlocksWhitelistPolicyBeforeExecution() {
        let prefixID = UUID()
        let game = GameRecord(
            title: "SampleHeavyGame",
            source: .steam,
            installPath: "/Managed/Steam/SampleHeavyGame",
            savePathMapping: "Documents/Saves/SampleHeavyGame",
            compatibilityProfileName: "heavy-whitelist",
            inputProfileName: "Controller + Precision Touch",
            touchOverlayName: "Stealth Overlay",
            controllerPresetName: "Shooter Layout",
            keyboardMouseEnabled: true,
            prefixState: .customized,
            deviceTier: .tier3,
            rendererPreset: .vkd3dHighCompatibility,
            launchProfile: GameLaunchProfile(
                executablePath: "/Managed/Steam/SampleHeavyGame/SampleHeavyGame.exe",
                arguments: ["-skip_launcher"],
                prefixID: prefixID,
                rendererPreset: .vkd3dHighCompatibility,
                deviceTier: .tier3,
                titleFlags: ["steam", "tier3-whitelist"]
            ),
            installedSizeGB: 91.7,
            summary: "Representative title"
        )

        let session = LaunchCoordinator(
            runtime: .defaultDescriptor,
            jitStatus: .ready,
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 128,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier2,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [FileSystemRuntimeBundleRegistry.defaultManifest],
                selectedRuntimeBundle: FileSystemRuntimeBundleRegistry.defaultManifest,
                constraints: []
            ),
            runtimePolicy: RuntimePolicy(
                memoryBudgetClass: .expansive,
                rendererOverride: .vkd3dHighCompatibility,
                resolutionScale: 0.7,
                framePacingCap: 45,
                shaderStrategy: .fullPrewarm,
                requiresExplicitWhitelist: true
            )
        ).prepareLaunch(
            for: game,
            runtimeHealth: RuntimeHealthReport(
                status: .healthy, runtimeName: "Iridium Runtime Base", notes: []),
            filePresence: ManagedFilePresence(installRootExists: true, executableExists: true)
        )

        XCTAssertEqual(session.readiness, .blockedByPolicy)
        XCTAssertTrue(
            session.issues.contains(where: {
                $0.message.contains("whitelist") || $0.message.contains("capability tier")
            }))

        let report = LaunchEligibilityAuditor().audit(
            game: game,
            session: session,
            runtimeHealth: RuntimeHealthReport(
                status: .healthy, runtimeName: "Iridium Runtime Base", notes: []),
            storage: ManagedStorageStatus(
                totalCapacityGB: 256,
                reservedForSystemGB: 24,
                usedByGamesGB: 120,
                usedByPrefixesGB: 14,
                reservedForQueuedDownloadsGB: 0,
                pressure: .healthy,
                notes: []
            ),
            pipeline: InstallPipeline(
                title: game.title,
                manifest: SteamManifestResolution(
                    title: game.title,
                    appID: "1659040",
                    buildID: "20260313",
                    branchName: "public",
                    depots: [],
                    verificationStages: ["verify"]
                ),
                phases: [
                    InstallPhase(title: "Resolve depots", detail: "Done", state: .completed),
                    InstallPhase(title: "Download payloads", detail: "Done", state: .completed),
                    InstallPhase(title: "Verify content", detail: "Done", state: .completed),
                    InstallPhase(title: "Mount runtime target", detail: "Done", state: .completed),
                ]
            ),
            filePresence: ManagedFilePresence(installRootExists: true, executableExists: true)
        )

        XCTAssertEqual(report.overallStatus, .blocked)
        XCTAssertTrue(
            report.checks.contains(where: {
                $0.title == "Launch readiness" && $0.status == .blocked
            }))
    }

    func testValidationHarnessProducesAcceptanceReport() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "SampleLightweightGame.exe")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        let runtimeBundle = try! materializeRuntimeBundle(
            root: root.appending(path: "Runtime", directoryHint: .isDirectory))

        let report = ValidationHarness().run(
            ValidationHarnessRequest(
                title: "SampleLightweightGame",
                source: .manualImport,
                installPath: root.path,
                executablePath: executable.path,
                runtimeBundle: runtimeBundle,
                runtimePolicy: RuntimePolicy(
                    memoryBudgetClass: .compact,
                    resolutionScale: 1.0,
                    shaderStrategy: .onDemand
                )
            )
        )

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.runtimeBundleVersion, runtimeBundle.version)
        XCTAssertEqual(report.evidence?.runtimeBundleIdentifier, runtimeBundle.id)
    }

    func testPrefixBootstrapPersistsManifestForRuntimeHost() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtimeBundle = try materializeRuntimeBundle(
            root: root.appending(path: "Runtime", directoryHint: .isDirectory))

        let prefixID = UUID()
        let game = GameRecord(
            title: "SampleBalancedGame",
            source: .steam,
            installPath: root.path,
            savePathMapping: "Documents/Saves/SampleBalancedGame",
            compatibilityProfileName: "balanced-default",
            inputProfileName: "Controller First",
            touchOverlayName: "Action Overlay",
            controllerPresetName: "Action Layout",
            keyboardMouseEnabled: false,
            prefixState: .customized,
            deviceTier: .tier2,
            rendererPreset: .dxvkBalanced,
            launchProfile: GameLaunchProfile(
                executablePath: "SampleBalancedGame.exe",
                arguments: [],
                prefixID: prefixID,
                rendererPreset: .dxvkBalanced,
                deviceTier: .tier2,
                titleFlags: ["steam"]
            ),
            installedSizeGB: 8.4,
            executableFingerprint: "balanced-fingerprint",
            summary: "Test title"
        )
        let prefix = PrefixRecord(
            id: prefixID,
            name: "SampleBalancedGame Prefix",
            runtimeName: runtimeBundle.name,
            state: .customized,
            storageFootprint: "3.0 GB",
            storageFootprintGB: 3.0
        )

        let result = await FileSystemPrefixBootstrapService().bootstrap(
            game: game,
            prefix: prefix,
            runtimeBundle: runtimeBundle,
            policy: RuntimePolicy(
                memoryBudgetClass: .balanced,
                resolutionScale: 0.9,
                framePacingCap: 60,
                shaderStrategy: .selectivePrewarm,
                environmentOverrides: ["IRIDIUM_TITLE_OVERRIDE": "balanced-default"]
            )
        )

        switch result {
        case .success(let payload):
            XCTAssertEqual(payload.status, "bootstrapped")
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload.manifestPath))
            let data = try Data(contentsOf: URL(fileURLWithPath: payload.manifestPath))
            let manifest = try JSONDecoder().decode(PrefixBootstrapManifest.self, from: data)
            XCTAssertEqual(manifest.prefixID, prefixID)
            XCTAssertEqual(
                manifest.environmentOverrides["IRIDIUM_TITLE_OVERRIDE"], "balanced-default")
            let environment = try String(
                contentsOfFile: manifest.environmentFilePath, encoding: .utf8)
            let expectedServerRoot = URL(
                fileURLWithPath: manifest.prefixRootPath, isDirectory: true
            ).appending(path: ".wineserver", directoryHint: .isDirectory)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: expectedServerRoot.path),
                "Prefix bootstrap must create a sandbox-writable Wine server root."
            )
            let serverRootAttributes = try FileManager.default.attributesOfItem(
                atPath: expectedServerRoot.path)
            XCTAssertEqual(
                serverRootAttributes[.posixPermissions] as? NSNumber,
                NSNumber(value: 0o700),
                "Wine requires its server socket root to be private to the app user."
            )
            XCTAssertTrue(
                environment.contains(
                    "\(RuntimeEnvironmentKey.wineServerRoot)=\(expectedServerRoot.path)\n"),
                "Runtime environment must bind guest and native Wine server paths."
            )
        case .failure(let failure):
            XCTFail("Expected prefix bootstrap to succeed, got \(failure)")
        }
    }

    func testRuntimeHostControllerPersistsLaunchTicketAndSession() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBundle = try materializeRuntimeBundle(root: runtimeRoot)
        let executableURL = root.appending(path: "SamplePerformanceGame.exe")
        try Data("performance".utf8).write(to: executableURL)
        let game = GameRecord(
            title: "SamplePerformanceGame",
            source: .manualImport,
            installPath: root.path,
            savePathMapping: "Documents/Saves/SamplePerformanceGame",
            compatibilityProfileName: "performance-default",
            inputProfileName: "Controller + KBM",
            touchOverlayName: "Racing Overlay",
            controllerPresetName: "Racing Triggers",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier2,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: executableURL.path,
                arguments: ["-noborder"],
                prefixID: UUID(),
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier2,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 21,
            executableFingerprint: try FileSystemGameArtifactInventory().fingerprintExecutable(
                at: executableURL.path
            ).value,
            summary: "Test title"
        )
        let prefix = PrefixRecord(
            id: game.launchProfile.prefixID,
            name: "SamplePerformanceGame Prefix",
            runtimeName: runtimeBundle.name,
            state: .clean,
            storageFootprint: "4.0 GB",
            storageFootprintGB: 4.0
        )
        let bootstrap = await FileSystemPrefixBootstrapService().bootstrap(
            game: game,
            prefix: prefix,
            runtimeBundle: runtimeBundle,
            policy: RuntimePolicy(
                memoryBudgetClass: .balanced,
                resolutionScale: 1.0,
                shaderStrategy: .onDemand
            )
        )
        let manifestPath: String
        switch bootstrap {
        case .success(let payload):
            manifestPath = payload.manifestPath
        case .failure(let failure):
            XCTFail("Expected prefix bootstrap to succeed, got \(failure)")
            return
        }

        let ticket = RuntimeLaunchTicket(
            gameID: UUID(),
            gameTitle: "SamplePerformanceGame",
            executablePath: executableURL.path,
            workingDirectory: root.path,
            launchArguments: ["-noborder"],
            environment: ["IRIDIUM_NO_DESKTOP": "1"],
            runtimeBundleID: runtimeBundle.id,
            runtimeBundleVersion: runtimeBundle.version,
            prefixID: prefix.id,
            prefixManifestPath: manifestPath
        )

        let runtimeHostTools = makeDevelopmentRuntimeHostTools()
        let submission = await runtimeHostTools.hostController.submit(ticket: ticket)

        switch submission {
        case .success(let session):
            XCTAssertEqual(session.state, .queued)
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.launchTicketPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.sessionLogPath))

            let terminal = await runtimeHostTools.executionMonitor.resolveTerminalState(
                for: session)
            XCTAssertEqual(terminal.state, .completed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: terminal.telemetryPath))
            XCTAssertTrue(terminal.statusSummary.contains("shell-free"))
            XCTAssertTrue(terminal.stateHistory.contains(.running))
        case .failure(let failure):
            XCTFail("Expected runtime host submission to succeed, got \(failure)")
        }
    }

    func testBridgedRuntimeHostControllerUsesBridgeResponseWhenAvailable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let bridge = RuntimeHostBridgeConfiguration(
            rootURL: root.appending(path: "bridge", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(
            at: bridge.responsesRootURL, withIntermediateDirectories: true)

        let ticket = RuntimeLaunchTicket(
            id: "bridge-session",
            gameID: UUID(),
            gameTitle: "SampleLightweightGame",
            executablePath: root.appending(path: "SampleLightweightGame.exe").path,
            workingDirectory: root.path,
            launchArguments: [],
            environment: ["IRIDIUM_NO_DESKTOP": "1"],
            runtimeBundleID: FileSystemRuntimeBundleRegistry.defaultManifest.id,
            runtimeBundleVersion: FileSystemRuntimeBundleRegistry.defaultManifest.version,
            prefixID: UUID(),
            prefixManifestPath: root.appending(path: "prefix.json").path
        )

        let bridgedSession = RuntimeHostSession(
            id: ticket.id,
            gameID: ticket.gameID,
            gameTitle: ticket.gameTitle,
            launchTicketPath: "/bridge/ticket.json",
            sessionLogPath: "/bridge/session.log",
            telemetryPath: "/bridge/telemetry.json",
            runtimeBundleID: ticket.runtimeBundleID,
            runtimeBundleVersion: ticket.runtimeBundleVersion,
            state: .running,
            stateHistory: [.queued, .bootstrappingPrefix, .bootingRuntime, .running],
            statusSummary: "Handled by external runtime bridge."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bridgedSession).write(
            to: bridge.responsesRootURL.appending(path: "session-\(ticket.id).json"),
            options: .atomic
        )

        let submission = await BridgedRuntimeHostController(configuration: bridge).submit(
            ticket: ticket)
        switch submission {
        case .success(let session):
            XCTAssertEqual(session.statusSummary, "Handled by external runtime bridge.")
            XCTAssertEqual(session.launchTicketPath, "/bridge/ticket.json")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: bridge.responsesRootURL.appending(path: "session-\(ticket.id).json")
                        .path
                )
            )
        case .failure(let failure):
            XCTFail("Expected bridged runtime submission to succeed, got \(failure)")
        }
    }

    func testBridgedRuntimeHostControllerProcessesBridgeRequestWhenResponseIsNotPreseeded()
        async throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let bridge = RuntimeHostBridgeConfiguration(
            rootURL: root.appending(path: "bridge", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(
            at: bridge.requestsRootURL, withIntermediateDirectories: true)
        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("samplelightweightgame".utf8).write(to: executableURL)
        let runtimeRoot = root.appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBundle = try materializeRuntimeBundle(root: runtimeRoot)
        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: root.path,
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: executableURL.path,
                arguments: [],
                prefixID: UUID(),
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 1.2,
            executableFingerprint: try FileSystemGameArtifactInventory().fingerprintExecutable(
                at: executableURL.path
            ).value,
            summary: "Test title"
        )
        let prefix = PrefixRecord(
            id: game.launchProfile.prefixID,
            name: "SampleLightweightGame Prefix",
            runtimeName: runtimeBundle.name,
            state: .clean,
            storageFootprint: "2.0 GB",
            storageFootprintGB: 2.0
        )
        let bootstrap = await FileSystemPrefixBootstrapService().bootstrap(
            game: game,
            prefix: prefix,
            runtimeBundle: runtimeBundle,
            policy: RuntimePolicy(
                memoryBudgetClass: .compact,
                resolutionScale: 1.0,
                shaderStrategy: .onDemand
            )
        )
        let prefixManifestPath: String
        switch bootstrap {
        case .success(let payload):
            prefixManifestPath = payload.manifestPath
        case .failure(let failure):
            XCTFail("Expected prefix bootstrap to succeed, got \(failure)")
            return
        }

        let ticket = RuntimeLaunchTicket(
            id: "bridge-runtime-flow",
            gameID: UUID(),
            gameTitle: "SampleLightweightGame",
            executablePath: executableURL.path,
            workingDirectory: root.path,
            launchArguments: [],
            environment: [
                "IRIDIUM_NO_DESKTOP": "1",
                "IRIDIUM_RENDERER_PRESET": RendererPreset.metalOpenGLFallback.rawValue,
                "IRIDIUM_RUNTIME_GRAPHICS_STACK": GraphicsStack.metalOpenGLFallback.rawValue,
            ],
            runtimeBundleID: runtimeBundle.id,
            runtimeBundleVersion: runtimeBundle.version,
            prefixID: prefix.id,
            prefixManifestPath: prefixManifestPath
        )

        let backendClient = DevelopmentRuntimeBackendClient()
        let processor = NativeRuntimeBridgeRequestProcessor(
            runtimeConfiguration: bridge,
            runtimeBackendClient: backendClient
        )

        let submission = await BridgedRuntimeHostController(
            configuration: bridge,
            processor: processor
        ).submit(ticket: ticket)

        switch submission {
        case .success(let session):
            XCTAssertEqual(session.id, ticket.id)
            XCTAssertEqual(session.state, .queued)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: bridge.responsesRootURL.appending(path: "session-\(ticket.id).json")
                        .path
                )
            )

            let terminal = await BridgedRuntimeExecutionMonitor(
                configuration: bridge,
                processor: processor
            ).resolveTerminalState(for: session)
            XCTAssertEqual(terminal.state, .completed)
            XCTAssertTrue(terminal.stateHistory.contains(.running))
        case .failure(let failure):
            XCTFail("Expected bridged runtime request processing to succeed, got \(failure)")
        }
    }

    func testSteamSessionStoreSupportsRestoreAndSignOut() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sessionStore = FileSystemSteamSessionStore(rootURL: root)
        let authClient = LocalSteamAuthClient(sessionStore: sessionStore)
        let librarySync = LocalSteamLibrarySyncService(
            catalogClient: LocalSteamCatalogClient(),
            sessionStore: sessionStore
        )

        let account = await authClient.authenticate(accountName: "device-owner@steam")
        let restored = await sessionStore.session(reference: account.sessionReference ?? "")
        let library = await librarySync.sync(using: restored)

        XCTAssertEqual(restored?.accountName, "device-owner@steam")
        XCTAssertTrue(library.isEmpty)

        _ = await authClient.signOut()
        let cleared = await sessionStore.activeSession()
        XCTAssertNil(cleared)
    }

    func testBridgedSteamAuthPersistsHostedSessionAndLibrarySyncUsesBridgeCatalog() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sessionStore = FileSystemSteamSessionStore(
            rootURL: root.appending(path: "sessions", directoryHint: .isDirectory))
        let bridge = SteamBridgeConfiguration(
            rootURL: root.appending(path: "bridge", directoryHint: .isDirectory))
        let processor = NativeSteamBridgeRequestProcessor(
            steamConfiguration: bridge,
            runtimeConfiguration: RuntimeHostBridgeConfiguration(
                rootURL: root.appending(path: "runtime", directoryHint: .isDirectory)
            )
        )

        let authClient = BridgedSteamAuthClient(
            configuration: bridge,
            sessionStore: sessionStore,
            processor: processor
        )
        let catalogClient = BridgedSteamCatalogClient(
            configuration: bridge,
            processor: processor
        )
        let librarySync = LocalSteamLibrarySyncService(
            catalogClient: catalogClient, sessionStore: sessionStore)

        let account = await authClient.authenticate(accountName: "bridge@steam")
        let restored = await sessionStore.activeSession()
        let synced = await librarySync.sync(using: restored)

        XCTAssertEqual(account.state, .signedIn)
        XCTAssertEqual(restored?.accountName, "bridge@steam")
        XCTAssertTrue(synced.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bridge.requestsRootURL.appending(path: "auth-bridge-steam.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bridge.rootURL.appending(path: "bridge-status.json").path
            )
        )
    }

    func testBridgedSteamClientsFailClosedWithoutHostResponse() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sessionStore = FileSystemSteamSessionStore(
            rootURL: root.appending(path: "sessions", directoryHint: .isDirectory))
        let bridge = SteamBridgeConfiguration(
            rootURL: root.appending(path: "bridge", directoryHint: .isDirectory))

        let authClient = BridgedSteamAuthClient(configuration: bridge, sessionStore: sessionStore)
        let catalogClient = BridgedSteamCatalogClient(configuration: bridge)
        let manifestClient = BridgedSteamDepotManifestClient(configuration: bridge)

        let account = await authClient.authenticate(accountName: "offline@steam")
        let restored = await sessionStore.activeSession()
        let library = await catalogClient.syncLibrary(
            for: SteamAccount(
                accountName: "offline@steam", state: .signedIn, sessionReference: "missing")
        )
        let entry = SteamLibraryEntry(
            title: "Unknown Hosted Title",
            appID: "999999",
            installed: false,
            cloudSavesEnabled: true
        )
        let plan = manifestClient.installPlan(
            for: entry, targetPath: "/Managed/Steam/UnknownHostedTitle")
        let manifest = manifestClient.manifest(for: entry)

        XCTAssertEqual(account.state, .signedOut)
        XCTAssertNil(account.sessionReference)
        XCTAssertNil(restored)
        XCTAssertTrue(library.isEmpty)
        XCTAssertTrue(plan.primaryExecutable.isEmpty)
        XCTAssertEqual(
            plan.verificationSteps, ["Steam bridge unavailable; install planning is blocked."])
        XCTAssertTrue(manifest.depots.isEmpty)
        XCTAssertEqual(manifest.branchName, "unavailable")
    }

    func testNativeBridgeServiceProcessesRuntimeLaunchRequests() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let runtimeBridge = RuntimeHostBridgeConfiguration(
            rootURL: root.appending(path: "runtime", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(
            at: runtimeBridge.requestsRootURL, withIntermediateDirectories: true)
        let fixture = try await makeRuntimeLaunchFixture(root: root)
        let providerConfig = RuntimeProviderConfiguration(
            rootURL: root.appending(path: "provider", directoryHint: .isDirectory))
        var ticket = fixture.ticket
        ticket.id = "native-bridge-launch"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ticket).write(
            to: runtimeBridge.requestsRootURL.appending(path: "launch-\(ticket.id).json"),
            options: .atomic
        )

        let providerRequestURL = providerConfig.requestsRootURL.appending(
            path: "launch-\(ticket.id).json")
        let providerSessionURL = providerConfig.responsesRootURL.appending(
            path: "session-\(ticket.id).json")
        let providerTerminalURL = providerConfig.responsesRootURL.appending(
            path: "terminal-\(ticket.id).json")
        let providerTelemetryURL = providerConfig.responsesRootURL.appending(
            path: "telemetry-\(ticket.id).json")
        let ticketID = ticket.id

        Task {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard await waitForFile(at: providerRequestURL) else {
                return
            }
            try? FileManager.default.createDirectory(
                at: providerConfig.responsesRootURL, withIntermediateDirectories: true)
            try? encoder.encode(
                BridgeHeartbeatStatus(lastUpdatedAt: Date(), serviceName: "IridiumRuntimeProvider")
            ).write(to: providerConfig.statusURL, options: .atomic)
            try? encoder.encode(
                RuntimeBackendSessionUpdate(
                    id: ticketID,
                    state: .queued,
                    stateHistory: [.queued],
                    statusSummary: "Provider accepted the launch package."
                )
            ).write(to: providerSessionURL, options: .atomic)
            try? await Task.sleep(nanoseconds: 100 * 1_000_000)
            try? encoder.encode(
                RuntimeBackendSessionUpdate(
                    id: ticketID,
                    state: .running,
                    stateHistory: [.queued, .bootstrappingPrefix, .bootingRuntime, .running],
                    statusSummary: "Provider entered shell-free execution."
                )
            ).write(to: providerSessionURL, options: .atomic)
            try? await Task.sleep(nanoseconds: 100 * 1_000_000)
            try? encoder.encode(
                RuntimeBackendTerminalResult(
                    id: ticketID,
                    terminalStatus: RuntimeHostSessionState.completed.rawValue,
                    stateHistory: [
                        .queued, .bootstrappingPrefix, .bootingRuntime, .running, .completed,
                    ]
                )
            ).write(to: providerTerminalURL, options: .atomic)
            try? encoder.encode(
                PerformanceTelemetrySnapshot(
                    averageFPS: 57,
                    frameTimeP95MS: 21,
                    memoryPressureRatio: 0.47,
                    thermalState: .nominal
                )
            ).write(to: providerTelemetryURL, options: .atomic)
        }

        let bridgeService = NativeBridgeService(
            runtimeConfiguration: runtimeBridge,
            runtimeBackendClient: ProviderBackedRuntimeBackendClient(configuration: providerConfig),
            steamConfiguration: SteamBridgeConfiguration(
                rootURL: root.appending(path: "steam", directoryHint: .isDirectory))
        )

        let first = try await bridgeService.processRuntimeRequests()
        let queued = try JSONDecoder().decode(
            RuntimeHostSession.self,
            from: Data(
                contentsOf: runtimeBridge.responsesRootURL.appending(
                    path: "session-\(ticket.id).json"))
        )

        XCTAssertEqual(first, 1)
        XCTAssertEqual(queued.state, .queued)

        for _ in 0..<10 {
            _ = try await bridgeService.processRuntimeRequests()
            let current = try JSONDecoder().decode(
                RuntimeHostSession.self,
                from: Data(
                    contentsOf: runtimeBridge.responsesRootURL.appending(
                        path: "session-\(ticket.id).json"))
            )
            if current.state == .completed {
                break
            }
            try await Task.sleep(nanoseconds: 50 * 1_000_000)
        }

        let terminal = try JSONDecoder().decode(
            RuntimeHostSession.self,
            from: Data(
                contentsOf: runtimeBridge.responsesRootURL.appending(
                    path: "session-\(ticket.id).json"))
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtimeBridge.responsesRootURL.appending(path: "session-\(ticket.id).json")
                    .path
            )
        )
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertTrue(terminal.stateHistory.contains(.running))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtimeBridge.responsesRootURL.appending(
                    path: "telemetry-\(ticket.id).json"
                ).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtimeBridge.rootURL.appending(path: "bridge-status.json").path
            )
        )
    }

    func testNativeBridgeServiceProcessesSteamAuthRequests() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let steamBridge = SteamBridgeConfiguration(
            rootURL: root.appending(path: "steam", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(
            at: steamBridge.requestsRootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(["accountName": "hosted@steam"]).write(
            to: steamBridge.requestsRootURL.appending(path: "auth-hosted-steam.json"),
            options: .atomic
        )

        let report = try await NativeBridgeService(
            runtimeConfiguration: RuntimeHostBridgeConfiguration(
                rootURL: root.appending(path: "runtime", directoryHint: .isDirectory)),
            steamConfiguration: steamBridge
        ).processAll()

        XCTAssertEqual(report.steamRequestsHandled, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: steamBridge.responsesRootURL.appending(path: "auth-hosted-steam.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: steamBridge.rootURL.appending(path: "bridge-status.json").path
            )
        )
    }

    func testAcceptanceHarnessServiceEmitsDeterministicReport() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("samplelightweightgame".utf8).write(to: executableURL)
        let outputURL = root.appending(path: "report.json")
        let runtimeBundle = try materializeRuntimeBundle(
            root: root.appending(path: "Runtime", directoryHint: .isDirectory))

        let report = try await AcceptanceHarnessService(
            runtimeBundleRegistry: FileSystemRuntimeBundleRegistry(
                runtimeRootURL: root.appending(path: "Runtime", directoryHint: .isDirectory)
            ),
            capabilityProvider: FixedHostCapabilityProvider(
                snapshotValue: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 64,
                    deviceCapabilityClass: .balanced,
                    deviceTier: .tier2,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [runtimeBundle],
                    selectedRuntimeBundle: runtimeBundle,
                    constraints: [],
                    runtimeBridgeAvailable: true,
                    steamBridgeAvailable: true,
                    executionEnvironment: .nativeRuntime,
                    launchReady: true,
                    presentationReadiness: RuntimeSubsystemReadiness(
                        ready: true,
                        status: "ready",
                        statusSummary: "Presentation service is live."
                    ),
                    inputReadiness: RuntimeSubsystemReadiness(
                        ready: true,
                        status: "ready",
                        statusSummary: "Input bridge is live."
                    ),
                    audioReadiness: RuntimeSubsystemReadiness(
                        ready: true,
                        status: "ready",
                        statusSummary: "Audio bridge is live."
                    )
                )
            ),
            executor: makeDevelopmentRuntimeExecutor()
        ).run(
            AcceptanceHarnessConfiguration(
                title: "SampleLightweightGame",
                source: .manualImport,
                installPath: root.path,
                outputPath: outputURL.path
            )
        )

        XCTAssertEqual(report.title, "SampleLightweightGame")
        XCTAssertEqual(report.source, .manualImport)
        XCTAssertEqual(
            report.selectedExecutablePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            executableURL.standardizedFileURL.path
        )
        XCTAssertEqual(report.validationReport.title, "SampleLightweightGame")
        XCTAssertTrue(
            report.validationReport.accepted,
            report.validationReport.failureReason ?? report.validationReport.evidenceSummary
        )
        XCTAssertNotNil(report.validationReport.launchTicketPath)
        XCTAssertNotNil(report.validationReport.prefixManifestPath)
        XCTAssertEqual(report.hostCapabilitySnapshot?.launchReady, true)
        XCTAssertEqual(report.hostCapabilitySnapshot?.playabilityReady, true)
        XCTAssertEqual(report.hostCapabilitySnapshot?.presentationReadiness?.status, "ready")
        XCTAssertEqual(report.hostCapabilitySnapshot?.inputReadiness?.status, "ready")
        XCTAssertEqual(report.hostCapabilitySnapshot?.audioReadiness?.status, "ready")
        XCTAssertEqual(report.readinessChecks.first?.title, "Install pipeline")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let encodedReport = try Data(contentsOf: outputURL)
        let decodedReport = try JSONDecoder().decode(
            AcceptanceHarnessReportArtifact.self,
            from: encodedReport
        )
        XCTAssertEqual(decodedReport.hostCapabilitySnapshot?.playabilityReady, true)
    }

    func testAcceptanceHarnessServiceBuildsSteamInstallSummary() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appending(path: "SampleBalancedGame.exe")
        try Data("balanced".utf8).write(to: executableURL)
        let runtimeBundle = try materializeRuntimeBundle(
            root: root.appending(path: "Runtime", directoryHint: .isDirectory))
        let report = try await AcceptanceHarnessService(
            runtimeBundleRegistry: FileSystemRuntimeBundleRegistry(
                runtimeRootURL: root.appending(path: "Runtime", directoryHint: .isDirectory)
            ),
            capabilityProvider: FixedHostCapabilityProvider(
                snapshotValue: HostCapabilitySnapshot(
                    jitStatus: .ready,
                    availableManagedStorageGB: 128,
                    deviceCapabilityClass: .heavyweight,
                    deviceTier: .tier3,
                    thermalState: .nominal,
                    lowPowerModeEnabled: false,
                    runtimeBundles: [runtimeBundle],
                    selectedRuntimeBundle: runtimeBundle,
                    constraints: []
                )
            ),
            steamManifestClient: AcceptanceHarnessManifestClient(),
            steamInstallCoordinator: AcceptanceHarnessInstallCoordinator()
        ).run(
            AcceptanceHarnessConfiguration(
                title: "SampleBalancedGame",
                source: .steam,
                installPath: root.path,
                steamAppID: "1145350"
            )
        )

        XCTAssertEqual(report.installSummary?.appID, "1145350")
        XCTAssertEqual(report.installSummary?.stage, InstallExecutionStage.completed.rawValue)
        XCTAssertFalse(report.installSummary?.completedDepotIDs.isEmpty ?? true)
        XCTAssertEqual(report.installSummary?.primaryExecutable, "SampleBalancedGame.exe")
    }

    func testAcceptanceHarnessReportDecodesLegacyArtifactWithoutHostSnapshot() throws {
        let legacyJSON = """
        {
          "title": "Legacy Report",
          "source": "manualImport",
          "installPath": "/tmp/Legacy",
          "discoveredExecutables": [],
          "warnings": [],
          "policySummary": "unresolved",
          "launchReadiness": "missingExecutable",
          "launchIssues": [],
          "readinessSummary": "Blocked",
          "readinessChecks": [],
          "hostConstraints": [],
          "validationReport": {
            "title": "Legacy Report",
            "accepted": false,
            "runtimeBundleVersion": "unknown",
            "stateHistory": [],
            "evidenceSummary": "Legacy report",
            "generatedAt": 0
          },
          "generatedAt": 0
        }
        """

        let report = try JSONDecoder().decode(
            AcceptanceHarnessReportArtifact.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertNil(report.hostCapabilitySnapshot)
        XCTAssertEqual(report.title, "Legacy Report")
    }

    func testValidationHarnessCanExecuteRuntimeSession() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appending(path: "SampleLightweightGame.exe")
        try Data("samplelightweightgame".utf8).write(to: executableURL)
        let runtimeBundle = try materializeRuntimeBundle(
            root: root.appending(path: "Runtime", directoryHint: .isDirectory))
        let fingerprint = SHA256.hash(data: Data("samplelightweightgame".utf8)).map {
            String(format: "%02x", $0)
        }.joined()

        let game = GameRecord(
            title: "SampleLightweightGame",
            source: .manualImport,
            installPath: root.path,
            savePathMapping: "Documents/Saves/SampleLightweightGame",
            compatibilityProfileName: "lightweight-default",
            inputProfileName: "Touch + Controller",
            touchOverlayName: "Card Touch Layout",
            controllerPresetName: "Standard Gamepad",
            keyboardMouseEnabled: true,
            prefixState: .clean,
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchProfile: GameLaunchProfile(
                executablePath: executableURL.path,
                arguments: [],
                prefixID: UUID(),
                rendererPreset: .metalOpenGLFallback,
                deviceTier: .tier1,
                titleFlags: ["manual-import"]
            ),
            installedSizeGB: 1.2,
            managedArtifactIdentifier: "samplelightweightgame",
            executableFingerprint: fingerprint,
            summary: "Harness test"
        )
        let prefix = PrefixRecord(
            id: game.launchProfile.prefixID,
            name: "SampleLightweightGame Prefix",
            runtimeName: runtimeBundle.name,
            state: .clean,
            storageFootprint: "2.0 GB",
            storageFootprintGB: 2.0
        )
        let policy = RuntimePolicy(
            memoryBudgetClass: .compact,
            rendererOverride: .metalOpenGLFallback,
            resolutionScale: 1.0,
            framePacingCap: 60,
            shaderStrategy: .onDemand
        )
        let session = LaunchCoordinator(
            runtime: runtimeBundle.descriptor,
            jitStatus: .ready,
            hostSnapshot: HostCapabilitySnapshot(
                jitStatus: .ready,
                availableManagedStorageGB: 64,
                deviceCapabilityClass: .balanced,
                deviceTier: .tier1,
                thermalState: .nominal,
                lowPowerModeEnabled: false,
                runtimeBundles: [runtimeBundle],
                selectedRuntimeBundle: runtimeBundle,
                constraints: [],
                runtimeBridgeAvailable: true,
                executionEnvironment: .nativeRuntime
            ),
            runtimePolicy: policy
        ).prepareLaunch(
            for: game,
            runtimeHealth: RuntimeHealthReport(
                status: .healthy,
                runtimeName: runtimeBundle.name,
                runtimeBundleIdentifier: runtimeBundle.id,
                runtimeBundleVersion: runtimeBundle.version,
                notes: []
            ),
            filePresence: ManagedFilePresence(installRootExists: true, executableExists: true)
        )

        let report = await ValidationHarness().runExecution(
            ValidationHarnessExecutionRequest(
                runtimeRequest: RuntimeSessionRequest(
                    game: game,
                    prefix: prefix,
                    session: session,
                    hostSnapshot: HostCapabilitySnapshot(
                        jitStatus: .ready,
                        availableManagedStorageGB: 64,
                        deviceCapabilityClass: .balanced,
                        deviceTier: .tier1,
                        thermalState: .nominal,
                        lowPowerModeEnabled: false,
                        runtimeBundles: [runtimeBundle],
                        selectedRuntimeBundle: runtimeBundle,
                        constraints: [],
                        runtimeBridgeAvailable: true,
                        executionEnvironment: .nativeRuntime
                    ),
                    runtimeBundle: runtimeBundle,
                    policy: policy
                )
            ),
            executor: makeDevelopmentRuntimeExecutor()
        )

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.terminalStatus, RuntimeHostSessionState.completed.rawValue)
        XCTAssertEqual(report.evidence?.hostSessionID, report.hostSessionID)
        XCTAssertEqual(report.mitigationAction, ThermalMitigationAction.none.rawValue)
    }

    func testRuntimeMitigationCoordinatorAppliesPlannedOrdering() {
        let coordinator = RuntimeMitigationCoordinator()
        let basePolicy = RuntimePolicy(
            memoryBudgetClass: .expansive,
            rendererOverride: .vkd3dHighCompatibility,
            resolutionScale: 0.8,
            framePacingCap: 90,
            shaderStrategy: .fullPrewarm
        )

        let resolutionMitigation = coordinator.apply(
            telemetry: PerformanceTelemetrySnapshot(
                averageFPS: 41,
                frameTimeP95MS: 38,
                memoryPressureRatio: 0.91,
                thermalState: .nominal
            ),
            to: basePolicy
        )
        XCTAssertEqual(resolutionMitigation.action, .reduceResolution)
        XCTAssertLessThan(
            resolutionMitigation.adjustedPolicy.resolutionScale, basePolicy.resolutionScale)

        let frameCapMitigation = coordinator.apply(
            telemetry: PerformanceTelemetrySnapshot(
                averageFPS: 39,
                frameTimeP95MS: 38,
                memoryPressureRatio: 0.91,
                thermalState: .nominal
            ),
            to: RuntimePolicy(
                memoryBudgetClass: .expansive,
                rendererOverride: .vkd3dHighCompatibility,
                resolutionScale: 0.5,
                framePacingCap: 90,
                shaderStrategy: .fullPrewarm
            )
        )
        XCTAssertEqual(frameCapMitigation.action, .capFrameRate)
        XCTAssertEqual(frameCapMitigation.adjustedPolicy.framePacingCap, 45)

        let shaderMitigation = coordinator.apply(
            telemetry: PerformanceTelemetrySnapshot(
                averageFPS: 39,
                frameTimeP95MS: 38,
                memoryPressureRatio: 0.91,
                thermalState: .nominal
            ),
            to: RuntimePolicy(
                memoryBudgetClass: .expansive,
                rendererOverride: .vkd3dHighCompatibility,
                resolutionScale: 0.5,
                framePacingCap: 45,
                shaderStrategy: .fullPrewarm
            )
        )
        XCTAssertEqual(shaderMitigation.action, .disableShaderPrewarm)
        XCTAssertEqual(shaderMitigation.adjustedPolicy.shaderStrategy, .onDemand)

        let blockMitigation = coordinator.apply(
            telemetry: PerformanceTelemetrySnapshot(
                averageFPS: 22,
                frameTimeP95MS: 52,
                memoryPressureRatio: 0.99,
                thermalState: .critical
            ),
            to: RuntimePolicy(
                memoryBudgetClass: .expansive,
                rendererOverride: .vkd3dHighCompatibility,
                resolutionScale: 0.5,
                framePacingCap: 45,
                shaderStrategy: .onDemand
            )
        )
        XCTAssertEqual(blockMitigation.action, .blockLaunch)
        XCTAssertEqual(
            blockMitigation.adjustedPolicy.environmentOverrides["IRIDIUM_BLOCK_RELAUNCH"], "1")
    }

    func testRuntimeMitigationCoordinatorKeepsAdjustmentsWithinBasePolicyBounds() {
        let coordinator = RuntimeMitigationCoordinator()

        let resolutionMitigation = coordinator.apply(
            telemetry: PerformanceTelemetrySnapshot(
                averageFPS: 30,
                frameTimeP95MS: 40,
                memoryPressureRatio: 0.92,
                thermalState: .serious
            ),
            to: RuntimePolicy(
                memoryBudgetClass: .balanced,
                rendererOverride: .dxvkBalanced,
                resolutionScale: 0.55,
                framePacingCap: 30,
                shaderStrategy: .onDemand
            )
        )
        XCTAssertEqual(resolutionMitigation.action, .reduceResolution)
        XCTAssertEqual(resolutionMitigation.adjustedPolicy.resolutionScale, 0.5)
        XCTAssertEqual(resolutionMitigation.adjustedPolicy.framePacingCap, 30)

        let frameCapMitigation = coordinator.apply(
            telemetry: PerformanceTelemetrySnapshot(
                averageFPS: 34,
                frameTimeP95MS: 42,
                memoryPressureRatio: 0.91,
                thermalState: .serious
            ),
            to: RuntimePolicy(
                memoryBudgetClass: .balanced,
                rendererOverride: .dxvkBalanced,
                resolutionScale: 0.5,
                framePacingCap: 30,
                shaderStrategy: .fullPrewarm
            )
        )
        XCTAssertEqual(frameCapMitigation.action, .disableShaderPrewarm)
        XCTAssertEqual(frameCapMitigation.adjustedPolicy.framePacingCap, 30)
        XCTAssertEqual(frameCapMitigation.adjustedPolicy.shaderStrategy, .onDemand)
    }
}
