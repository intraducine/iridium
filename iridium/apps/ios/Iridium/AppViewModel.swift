import Foundation
import IridiumCore
import IridiumProfiles
import IridiumRuntime

#if os(iOS)
    import AVFoundation
    import Darwin
    import UIKit
    #if canImport(AltKit)
        import AltKit
    #endif
#endif

struct ReadinessDashboard {
    var readyCount: Int
    var warningCount: Int
    var blockedCount: Int
    var latestBlockedTitle: String?
    var latestBlockedSummary: String?
}

struct GamePresentationStatus {
    var title: String
    var summary: String
    var tone: VerificationGateStatus
}

struct RuntimeSubsystemStatus: Identifiable {
    var id: String { title }
    var title: String
    var status: String
    var summary: String
    var tone: VerificationGateStatus
}

struct RuntimePlayerSession: Identifiable, Equatable {
    var id: String { sessionIdentifier }
    var sessionIdentifier: String
    var gameID: UUID
    var gameTitle: String
    var runtimeBundleID: String
    var runtimeBundleVersion: String
    var userlandRootPath: String?
    var graphicsStack: GraphicsStack
    var launchTicketPath: String
    var sessionLogPath: String
    var telemetryPath: String
    var state: RuntimeHostSessionState
    var stateHistory: [RuntimeHostSessionState]
    var statusSummary: String
    var launchedAt: Date
}

struct RuntimePlayerBridgeConfiguration: Equatable {
    var sessionIdentifier: String
    var surfaceIdentifier: String
    var bridgeRootPath: String
    var bridgeConfigPath: String
    var framebufferPath: String
    var frameReadyPath: String
    var inputEventsPath: String
    var audioStatePath: String
    var tracePath: String
    var wineDebugLogPath: String
    var surfaceWidth: Int
    var surfaceHeight: Int
}

private struct RuntimePlayerBridgeConfigurationFile: Encodable {
    var sessionIdentifier: String
    var surfaceIdentifier: String
    var framebufferPath: String
    var inputEventsPath: String
    var audioStatePath: String
    var tracePath: String
    var wineDebugLogPath: String
    var graphicsDriver: String
    var audioDriver: String
    var graphicsStack: String
    var surfaceWidth: Int
    var surfaceHeight: Int
    var fullscreenOnly: Bool
}

func runtimePlayerSurfaceSize(nativeWidth: Int, nativeHeight: Int) -> (width: Int, height: Int) {
    _ = nativeWidth
    _ = nativeHeight
    return (960, 540)
}

@MainActor
private func withRuntimePlayerUserlandRoot<T>(
    _ userlandRootPath: String?,
    operation: @MainActor () async -> T
) async -> T {
    guard let userlandRootPath, !userlandRootPath.isEmpty else {
        return await operation()
    }

    let previous = getenv(RuntimeEnvironmentKey.userlandRoot).map { String(cString: $0) }
    setenv(RuntimeEnvironmentKey.userlandRoot, userlandRootPath, 1)
    defer {
        if let previous {
            setenv(RuntimeEnvironmentKey.userlandRoot, previous, 1)
        } else {
            unsetenv(RuntimeEnvironmentKey.userlandRoot)
        }
    }
    return await operation()
}

private struct ReservedRuntimePlayerSession {
    var sessionIdentifier: String
    var gameID: UUID
    var gameTitle: String
    var runtimeBundleID: String
    var runtimeBundleVersion: String
    var runtimeBundleRootPath: String
    var userlandRootPath: String?
    var graphicsStack: GraphicsStack
    var launchTicketPath: String
    var sessionLogPath: String
    var telemetryPath: String
}

private struct RuntimePlayerVerificationContext {
    var execution: RuntimeSessionResult
    var game: GameRecord
    var launchRecord: LaunchHistoryEntry
    var resolvedPolicy: RuntimePolicy
    var issueSummary: [String]
    var successStatusMessage: String
}

private final class RuntimePlayerPreparedSession {
    let sessionIdentifier: String
    private(set) var bridgeConfiguration: RuntimePlayerBridgeConfiguration
    let serviceDescriptors: [RuntimePlayerServiceDescriptor]
    let launchEnvironment: [String: String]

    private let bridgeRootURL: URL

    #if os(iOS)
        private var audioSessionIsActive = false
    #endif

    private init(
        sessionIdentifier: String,
        bridgeConfiguration: RuntimePlayerBridgeConfiguration,
        graphicsStack: GraphicsStack
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.bridgeConfiguration = bridgeConfiguration
        self.bridgeRootURL = URL(fileURLWithPath: bridgeConfiguration.bridgeRootPath, isDirectory: true)
        self.serviceDescriptors = [
            RuntimePlayerServiceDescriptor(
                kind: .render,
                handle: bridgeConfiguration.framebufferPath,
                metadata:
                    "graphicsStack=\(graphicsStack.rawValue) fullscreen=true surfaceID=\(bridgeConfiguration.surfaceIdentifier) size=\(bridgeConfiguration.surfaceWidth)x\(bridgeConfiguration.surfaceHeight)"
            ),
            RuntimePlayerServiceDescriptor(
                kind: .input,
                handle: bridgeConfiguration.inputEventsPath,
                metadata: "routes=touch,controller,keyboard format=csv"
            ),
            RuntimePlayerServiceDescriptor(
                kind: .audio,
                handle: bridgeConfiguration.audioStatePath,
                metadata: "driver=winecoreaudio category=playback state=file"
            ),
        ]
        self.launchEnvironment = [
            RuntimeEnvironmentKey.wineIOSSurfaceID: bridgeConfiguration.surfaceIdentifier,
            RuntimeEnvironmentKey.wineIOSBridgeRoot: bridgeConfiguration.bridgeRootPath,
            RuntimeEnvironmentKey.wineIOSBridgeConfig: bridgeConfiguration.bridgeConfigPath,
            RuntimeEnvironmentKey.wineIOSFramebufferPath: bridgeConfiguration.framebufferPath,
            RuntimeEnvironmentKey.wineIOSInputEventsPath: bridgeConfiguration.inputEventsPath,
            RuntimeEnvironmentKey.wineIOSAudioStatePath: bridgeConfiguration.audioStatePath,
            RuntimeEnvironmentKey.wineIOSTracePath: bridgeConfiguration.tracePath,
            RuntimeEnvironmentKey.wineIOSGraphicsDriver: "wineios.drv",
            RuntimeEnvironmentKey.wineIOSSurfaceWidth: String(bridgeConfiguration.surfaceWidth),
            RuntimeEnvironmentKey.wineIOSSurfaceHeight: String(bridgeConfiguration.surfaceHeight),
            "WINEDEBUG": "err+all,warn+loaddll,warn+seh,warn+driver,warn+winediag,warn+winstation",
            "WINEDEBUGLOG": bridgeConfiguration.wineDebugLogPath,
        ]
    }

    static func prepare(
        sessionIdentifier: String,
        graphicsStack: GraphicsStack
    ) -> Result<RuntimePlayerPreparedSession, RuntimeFailure> {
        let bridgeRootURL = FileManager.default.temporaryDirectory
            .appending(path: "IridiumRuntimePlayer", directoryHint: .isDirectory)
            .appending(path: sessionIdentifier, directoryHint: .isDirectory)
        let surfaceSize = defaultSurfaceSize()
        let bridgeConfiguration = RuntimePlayerBridgeConfiguration(
            sessionIdentifier: sessionIdentifier,
            surfaceIdentifier: "surface.\(sessionIdentifier)",
            bridgeRootPath: bridgeRootURL.path,
            bridgeConfigPath: bridgeRootURL.appending(path: "iridium-playable-session.json").path,
            framebufferPath: bridgeRootURL.appending(path: "framebuffer.bgra").path,
            frameReadyPath: bridgeRootURL.appending(path: "framebuffer.bgra.ready").path,
            inputEventsPath: bridgeRootURL.appending(path: "input-events.csv").path,
            audioStatePath: bridgeRootURL.appending(path: "audio-state.txt").path,
            tracePath: bridgeRootURL.appending(path: "wineios-trace.log").path,
            wineDebugLogPath: bridgeRootURL.appending(path: "wine-debug.log").path,
            surfaceWidth: surfaceSize.width,
            surfaceHeight: surfaceSize.height
        )
        let preparedSession = RuntimePlayerPreparedSession(
            sessionIdentifier: sessionIdentifier,
            bridgeConfiguration: bridgeConfiguration,
            graphicsStack: graphicsStack
        )
        return preparedSession.activate()
    }

    func teardown() {
        #if os(iOS)
            if audioSessionIsActive {
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: [.notifyOthersOnDeactivation]
                )
                audioSessionIsActive = false
            }
        #endif

        try? writeAudioState(isActive: false)
        logBridgeTraceIfPresent()
        logWineDebugLogIfPresent()
        try? FileManager.default.removeItem(at: bridgeRootURL)
    }

    func logDiagnostics(reason: String) {
        print(
            "[IridiumRuntime] runtimePlayer: diagnosticsSnapshot session=\(sessionIdentifier) reason=\"\(reason)\""
        )
        logBridgeArtifactSnapshot(label: "bridgeConfig", path: bridgeConfiguration.bridgeConfigPath)
        logBridgeArtifactSnapshot(label: "framebuffer", path: bridgeConfiguration.framebufferPath)
        logBridgeArtifactSnapshot(label: "frameReady", path: bridgeConfiguration.frameReadyPath)
        logBridgeArtifactSnapshot(label: "inputEvents", path: bridgeConfiguration.inputEventsPath)
        logBridgeArtifactSnapshot(label: "audioState", path: bridgeConfiguration.audioStatePath)
        logBridgeTraceIfPresent()
        logWineDebugLogIfPresent()
    }

    private func logBridgeTraceIfPresent() {
        logTextFileIfPresent(
            path: bridgeConfiguration.tracePath,
            statusLabel: "wineiosTrace",
            linePrefix: "wineios"
        )
    }

    private func logWineDebugLogIfPresent() {
        logTextFileIfPresent(
            path: bridgeConfiguration.wineDebugLogPath,
            statusLabel: "wineDebugLog",
            linePrefix: "wine"
        )
    }

    private func logBridgeArtifactSnapshot(label: String, path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            print(
                "[IridiumRuntime] runtimePlayer: bridgeArtifact session=\(sessionIdentifier) label=\(label) status=absent path=\(path)"
            )
            return
        }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        print(
            "[IridiumRuntime] runtimePlayer: bridgeArtifact session=\(sessionIdentifier) label=\(label) status=present size=\(size) modifiedAt=\(modifiedAt) path=\(path)"
        )
    }

    private func logTextFileIfPresent(path: String, statusLabel: String, linePrefix: String) {
        guard
            FileManager.default.fileExists(atPath: path),
            let contents = try? String(contentsOfFile: path, encoding: .utf8),
            !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            print("[IridiumRuntime] runtimePlayer: \(statusLabel) session=\(sessionIdentifier) status=absent path=\(path)")
            return
        }

        for line in contents.split(separator: "\n").suffix(80) {
            print("[IridiumRuntime] \(linePrefix): \(line)")
        }
    }

    private func activate() -> Result<RuntimePlayerPreparedSession, RuntimeFailure> {
        do {
            if FileManager.default.fileExists(atPath: bridgeRootURL.path) {
                try FileManager.default.removeItem(at: bridgeRootURL)
            }
            try FileManager.default.createDirectory(
                at: bridgeRootURL,
                withIntermediateDirectories: true
            )
            try createFramebufferFile()
            try Data().write(to: URL(fileURLWithPath: bridgeConfiguration.inputEventsPath), options: .atomic)
            try activateAudioSessionIfNeeded()
            try writeAudioState(isActive: true)
            try writeBridgeConfiguration()
            return .success(self)
        } catch {
            teardown()
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason: "Failed to prepare the fullscreen player bridge: \(error.localizedDescription)",
                    recoverySuggestion: "Recreate the runtime player bridge and retry the launch."
                )
            )
        }
    }

    private func createFramebufferFile() throws {
        let pixelBytes = bridgeConfiguration.surfaceWidth * bridgeConfiguration.surfaceHeight * 4
        try Data(count: pixelBytes).write(
            to: URL(fileURLWithPath: bridgeConfiguration.framebufferPath),
            options: .atomic
        )
    }

    private func writeAudioState(isActive: Bool) throws {
        let payload = """
        sessionIdentifier=\(sessionIdentifier)
        sessionActive=\(isActive ? 1 : 0)
        interrupted=0
        category=playback
        updatedAt=\(Date().timeIntervalSince1970)
        """
        try payload.write(
            to: URL(fileURLWithPath: bridgeConfiguration.audioStatePath),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeBridgeConfiguration() throws {
        let payload = RuntimePlayerBridgeConfigurationFile(
            sessionIdentifier: bridgeConfiguration.sessionIdentifier,
            surfaceIdentifier: bridgeConfiguration.surfaceIdentifier,
            framebufferPath: bridgeConfiguration.framebufferPath,
            inputEventsPath: bridgeConfiguration.inputEventsPath,
            audioStatePath: bridgeConfiguration.audioStatePath,
            tracePath: bridgeConfiguration.tracePath,
            wineDebugLogPath: bridgeConfiguration.wineDebugLogPath,
            graphicsDriver: "wineios.drv",
            audioDriver: "winecoreaudio.drv",
            graphicsStack: "metalOpenGLFallback",
            surfaceWidth: bridgeConfiguration.surfaceWidth,
            surfaceHeight: bridgeConfiguration.surfaceHeight,
            fullscreenOnly: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: URL(fileURLWithPath: bridgeConfiguration.bridgeConfigPath), options: .atomic)
    }

    private func activateAudioSessionIfNeeded() throws {
        #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionIsActive = true
        #endif
    }

    private static func defaultSurfaceSize() -> (width: Int, height: Int) {
        #if os(iOS)
            let nativeBounds = UIScreen.main.nativeBounds
            return runtimePlayerSurfaceSize(
                nativeWidth: max(1, Int(nativeBounds.width.rounded(.down))),
                nativeHeight: max(1, Int(nativeBounds.height.rounded(.down)))
            )
        #else
            return (1280, 720)
        #endif
    }
}

enum JITEnablementState: String, Sendable {
    case notDetected
    case toolLaunchAvailable
    case waitingForExternalEnablement
    case bootstrapRequired
    case backendUnavailable
    case ready
}

#if os(iOS)
    private enum ExternalJITRequestError: LocalizedError {
        case altJITUnavailable
        case missingBundleIdentifier
        case missingJitStreamerAddress
        case invalidJitStreamerAddress(String)
        case failedToOpen(ExternalJITProvider)
        case jitStreamerRejected(String)
        case jitStreamerNetworkFailure(String)

        var errorDescription: String? {
            switch self {
            case .altJITUnavailable:
                return "AltJIT is unavailable in this build."
            case .missingBundleIdentifier:
                return "Iridium could not determine its bundle identifier for JIT enablement."
            case .missingJitStreamerAddress:
                return "Set a JitStreamer address before requesting JIT through JitStreamer."
            case .invalidJitStreamerAddress(let value):
                return "Invalid JitStreamer address: \(value)"
            case .failedToOpen(let provider):
                return "Iridium could not open \(provider.displayName)."
            case .jitStreamerRejected(let message):
                return "JitStreamer rejected the attach request: \(message)"
            case .jitStreamerNetworkFailure(let message):
                return "JitStreamer request failed: \(message)"
            }
        }
    }

    private struct JitStreamerAttachResponse: Decodable {
        var success: Bool
        var message: String
    }
#endif

private struct AppViewModelDependencies: Sendable {
    let store: IridiumStore
    let runtimeBundleRegistry: any RuntimeBundleRegistry
    let runtimeProvisioningService: any RuntimeProvisioningService
    let capabilityProvider: any HostCapabilityProvider
    let validationService: any RuntimeValidationService
    let artifactInventory: any GameArtifactInventory
    let sessionExecutor: any RuntimeSessionExecutor
    let runtimePlayerServiceRegistry: any RuntimePlayerServiceRegistry
    let runningSessionObserver: any RuntimeRunningSessionObserver
    let runtimePlayerFirstFrameTimeoutNanoseconds: UInt64?
    let runtimePolicyResolver: any RuntimePolicyResolver
    let titleOverrideResolver: any TitleOverrideResolver
    let compatibilityProfiles: [CompatibilityProfile]
    let runtimeDescriptor: RuntimeDescriptor
    #if os(iOS)
        let externalJITBundleInfo: @Sendable () -> ExternalJITBundleInfo
        let loadJitStreamerAddress: @Sendable () -> String
        let saveJitStreamerAddress: @Sendable (String) -> Void
        let requestAltJIT: @Sendable () async throws -> Void
        let requestJitStreamer: @Sendable (_ normalizedAddress: String, _ processIdentifier: pid_t) async throws -> Void
        let openExternalJITURL: @MainActor @Sendable (URL) async -> Bool
        let externalJITSchemeProbeResults: @MainActor @Sendable () -> [(scheme: String, available: Bool)]
    #endif
}

@MainActor
final class AppViewModel: ObservableObject {
    private static let importDebugBuildMarker = "2026-03-27-import-scope-v2"

    @Published private(set) var jitStatus: JITStatus = .required
    @Published private(set) var jitEnablementState: JITEnablementState = .notDetected
    @Published private(set) var isCheckingJIT = false
    @Published private(set) var lastJITCheckSummary: String?
    @Published private(set) var jitStreamerAddress = ""
    @Published private(set) var games: [GameRecord] = []
    @Published private(set) var prefixes: [PrefixRecord] = []
    @Published private(set) var compatibilityProfiles: [CompatibilityProfile] = []
    @Published private(set) var runtimeDescriptor: RuntimeDescriptor = .defaultDescriptor
    @Published private(set) var runtimeHealth = RuntimeHealthReport(
        status: .actionRequired,
        runtimeName: "Iridium Runtime Base",
        notes: ["Runtime validation has not run yet."]
    )
    @Published private(set) var managedStorage = ManagedStorageStatus(
        totalCapacityGB: 256,
        reservedForSystemGB: 24,
        usedByGamesGB: 0,
        usedByPrefixesGB: 0,
        reservedForQueuedDownloadsGB: 0,
        pressure: .healthy,
        notes: ["Managed storage status has not been measured yet."]
    )
    @Published private(set) var onboardingChecks: [OnboardingCheck] = []
    @Published private(set) var launchHistory: [LaunchHistoryEntry] = []
    @Published private(set) var pendingLaunches: [PendingLaunchRecord] = []
    @Published private(set) var installHistory: [InstallHistoryEntry] = []
    @Published private(set) var compatibilityEvidence: [CompatibilityEvidenceRecord] = []
    @Published private(set) var activityFeed: [ActivityLogEntry] = []
    @Published private(set) var verificationAudits: [VerificationAuditEntry] = []
    @Published private(set) var isImportingGame = false
    @Published private(set) var importScanResult: ImportScanResult?
    @Published private(set) var importStatusMessage: String?
    @Published private(set) var activityStatusMessage: String?
    @Published private(set) var activeRuntimePlayerSession: RuntimePlayerSession?
    @Published private(set) var hostCapabilities = HostCapabilitySnapshot(
        jitStatus: .required,
        availableManagedStorageGB: 0,
        deviceCapabilityClass: .balanced,
        deviceTier: .tier2,
        thermalState: .nominal,
        lowPowerModeEnabled: false,
        runtimeBundles: [],
        selectedRuntimeBundle: nil,
        constraints: []
    )

    let store: IridiumStore
    private let runtimeBundleRegistry: any RuntimeBundleRegistry
    private let runtimeProvisioningService: any RuntimeProvisioningService
    private let capabilityProvider: any HostCapabilityProvider
    private let validationService: any RuntimeValidationService
    private let artifactInventory: any GameArtifactInventory
    private let sessionExecutor: any RuntimeSessionExecutor
    private let runtimePlayerServiceRegistry: any RuntimePlayerServiceRegistry
    private let runningSessionObserver: any RuntimeRunningSessionObserver
    private let runtimePlayerFirstFrameTimeoutNanoseconds: UInt64?
    private let runtimePolicyResolver: any RuntimePolicyResolver
    private let titleOverrideResolver: any TitleOverrideResolver
    private let preparesArtworkAutomatically: Bool
    private var refreshInProgress = false
    private var refreshRequestedWhileBusy = false
    private var isResumingPendingLaunch = false
    private var pendingLaunchPollingTask: Task<Void, Never>?
    private var externalJITEnablementTask: Task<Void, Never>?
    private var runtimePlayerReservation: ReservedRuntimePlayerSession?
    private var runtimePlayerPreparedSession: RuntimePlayerPreparedSession?
    private var runningSessionMonitorTask: Task<Void, Never>?
    private var runtimePlayerFirstFrameWatchdogTask: Task<Void, Never>?
    private var runtimePlayerVerificationContext: RuntimePlayerVerificationContext?
    private var verifiedRuntimePlayerSessions: Set<String> = []
    private var pendingExternalJITProvider: ExternalJITProvider?
    private var importScanTask: Task<Void, Never>?
    private var importSourceURL: URL?
    private var importSourceAccessActive = false
    private var importMetadataCache: [String: (identifier: String, fingerprint: String)] = [:]
    // Title the cached identifiers were derived from. Launch validation
    // recomputes the identifier from the registered game title, so a cache
    // entry computed under a different scan-time title must not be reused.
    private var importMetadataCacheTitle: String?
    private var importScanRequestID = UUID()
    #if os(iOS)
        private let externalJITBundleInfo: @Sendable () -> ExternalJITBundleInfo
        private let loadJitStreamerAddress: @Sendable () -> String
        private let saveJitStreamerAddress: @Sendable (String) -> Void
        private let requestAltJIT: @Sendable () async throws -> Void
        private let requestJitStreamer: @Sendable (_ normalizedAddress: String, _ processIdentifier: pid_t) async throws -> Void
        private let openExternalJITURL: @MainActor @Sendable (URL) async -> Bool
        private let externalJITSchemeProbeResults: @MainActor @Sendable () -> [(scheme: String, available: Bool)]
    #endif

    fileprivate init(dependencies: AppViewModelDependencies, autoRefresh: Bool = true) {
        self.store = dependencies.store
        self.runtimeBundleRegistry = dependencies.runtimeBundleRegistry
        self.runtimeProvisioningService = dependencies.runtimeProvisioningService
        self.capabilityProvider = dependencies.capabilityProvider
        self.validationService = dependencies.validationService
        self.artifactInventory = dependencies.artifactInventory
        self.sessionExecutor = dependencies.sessionExecutor
        self.runtimePlayerServiceRegistry = dependencies.runtimePlayerServiceRegistry
        self.runningSessionObserver = dependencies.runningSessionObserver
        self.runtimePlayerFirstFrameTimeoutNanoseconds =
            dependencies.runtimePlayerFirstFrameTimeoutNanoseconds
        self.runtimePolicyResolver = dependencies.runtimePolicyResolver
        self.titleOverrideResolver = dependencies.titleOverrideResolver
        self.preparesArtworkAutomatically = autoRefresh
        self.compatibilityProfiles = dependencies.compatibilityProfiles
        self.runtimeDescriptor = dependencies.runtimeDescriptor
        #if os(iOS)
            self.externalJITBundleInfo = dependencies.externalJITBundleInfo
            self.loadJitStreamerAddress = dependencies.loadJitStreamerAddress
            self.saveJitStreamerAddress = dependencies.saveJitStreamerAddress
            self.requestAltJIT = dependencies.requestAltJIT
            self.requestJitStreamer = dependencies.requestJitStreamer
            self.openExternalJITURL = dependencies.openExternalJITURL
            self.externalJITSchemeProbeResults = dependencies.externalJITSchemeProbeResults
            self.jitStreamerAddress = dependencies.loadJitStreamerAddress()
        #endif

        if autoRefresh {
            Task {
                await refresh()
                #if DEBUG && os(iOS)
                #if MADEIRA_RUNTIME
                let autoLaunchTitle = MadeiraRuntimeAdapter.enabled
                    ? (UserDefaults.standard.string(forKey: "IridiumPendingMadeiraLaunchTitle")
                        ?? ProcessInfo.processInfo.environment["IRIDIUM_DEBUG_LAUNCH_TITLE"])
                    : ProcessInfo.processInfo.environment["IRIDIUM_DEBUG_LAUNCH_TITLE"]
                #else
                let autoLaunchTitle = ProcessInfo.processInfo.environment["IRIDIUM_DEBUG_LAUNCH_TITLE"]
                #endif
                if let title = autoLaunchTitle,
                   let game = games.first(where: { $0.title == title }) {
                    print("[IridiumRuntime] debug launch requested: \(title)")
                    recordLaunchPreparation(for: game)
                    #if MADEIRA_RUNTIME
                    if !MadeiraRuntimeAdapter.enabled && jitStatus != .ready { enableJITWithRecommendedTool() }
                    #else
                    if jitStatus != .ready { enableJITWithRecommendedTool() }
                    #endif
                }
                #endif
            }
        }
    }

    nonisolated static func make() async -> AppViewModel {
        let dependencies = await Task.detached(priority: .userInitiated) {
            makeDependencies()
        }.value

        return await MainActor.run {
            AppViewModel(dependencies: dependencies)
        }
    }

    private nonisolated static func makeDependencies() -> AppViewModelDependencies {
        makeDependencies(
            store: IridiumStore.persistentDefault(),
            managedRootURL: IridiumStore.defaultManagedRootURL()
        )
    }

    private nonisolated static func makeDependencies(
        store: IridiumStore,
        managedRootURL: URL
    ) -> AppViewModelDependencies {
        let runtimeRootURL = managedRootURL.appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBundleRegistry = FileSystemRuntimeBundleRegistry(runtimeRootURL: runtimeRootURL)
        let runtimeProvisioningService = BundledRuntimeProvisioningService(
            registry: runtimeBundleRegistry)
        #if targetEnvironment(simulator)
            let runtimeBridgeConfiguration = RuntimeHostBridgeConfiguration()
            let runtimeBackendClient = DevelopmentRuntimeBackendClient()
            let runtimeBridgeProcessor: (any RuntimeBridgeRequestProcessor)? =
                NativeRuntimeBridgeRequestProcessor(
                    runtimeConfiguration: runtimeBridgeConfiguration,
                    runtimeBackendClient: runtimeBackendClient
                )
        #else
            let runtimeBackendClient = RuntimeBackendSelection.makeBackendClient()
        #endif

        let capabilityProvider = FileSystemHostCapabilityProvider(
            runtimeBundleRegistry: runtimeBundleRegistry,
            managedRootURL: managedRootURL
        )
        let validationService = DefaultRuntimeValidationService()
        let artifactInventory = FileSystemGameArtifactInventory()
        let runtimePlayerServiceRegistry = NativeRuntimePlayerServiceRegistry()
        #if targetEnvironment(simulator)
            let fallbackMonitor = FileSystemRuntimeExecutionMonitor(backendClient: runtimeBackendClient)
            let sessionExecutor = FileSystemRuntimeSessionExecutor(
                hostController: BridgedRuntimeHostController(
                    configuration: RuntimeHostBridgeConfiguration(),
                    processor: runtimeBridgeProcessor,
                    fallbackMode: .never,
                    fallbackController: FileSystemRuntimeHostController(
                        backendClient: runtimeBackendClient)
                ),
                executionMonitor: BridgedRuntimeExecutionMonitor(
                    configuration: RuntimeHostBridgeConfiguration(),
                    processor: runtimeBridgeProcessor,
                    fallbackMode: .never,
                    fallback: fallbackMonitor
                ),
                telemetryCollector: BridgedRuntimeTelemetryCollector(
                    configuration: RuntimeHostBridgeConfiguration(),
                    processor: runtimeBridgeProcessor,
                    fallbackMode: .never,
                    fallback: FileSystemRuntimeTelemetryCollector(
                        backendClient: runtimeBackendClient)
                )
            )
            let runningSessionObserver = FileSystemRuntimeRunningSessionObserver(
                executionMonitor: fallbackMonitor
            )
        #else
            let executionMonitor = FileSystemRuntimeExecutionMonitor(backendClient: runtimeBackendClient)
            let sessionExecutor = FileSystemRuntimeSessionExecutor(
                hostController: FileSystemRuntimeHostController(
                    backendClient: runtimeBackendClient),
                executionMonitor: executionMonitor,
                telemetryCollector: FileSystemRuntimeTelemetryCollector(
                    backendClient: runtimeBackendClient)
            )
            let runningSessionObserver = FileSystemRuntimeRunningSessionObserver(
                executionMonitor: executionMonitor
            )
        #endif
        let runtimePolicyResolver = DefaultRuntimePolicyResolver()
        let titleOverrideResolver = DefaultTitleOverrideResolver()
        let compatibilityProfiles = BuiltInCompatibilityProfiles.all
        let runtimeDescriptor =
            (try? runtimeBundleRegistry.defaultBundle()?.descriptor)
            ?? BundledRuntimeCatalog.defaultRuntime
        #if os(iOS)
            let externalJITBundleInfo: @Sendable () -> ExternalJITBundleInfo = {
                let infoDictionary = Bundle.main.infoDictionary ?? [:]
                return ExternalJITBundleInfo(
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    altServerID: infoDictionary["ALTServerID"] as? String,
                    altDeviceID: infoDictionary["ALTDeviceID"] as? String
                )
            }
            let jitStreamerDefaultsKey = "JitStreamerAddress"
            let loadJitStreamerAddress: @Sendable () -> String = {
                UserDefaults.standard.string(forKey: jitStreamerDefaultsKey) ?? ""
            }
            let saveJitStreamerAddress: @Sendable (String) -> Void = { value in
                UserDefaults.standard.set(value, forKey: jitStreamerDefaultsKey)
            }
            let requestAltJIT: @Sendable () async throws -> Void = {
                try await Self.requestAltJIT()
            }
            let requestJitStreamer: @Sendable (String, pid_t) async throws -> Void = {
                normalizedAddress, processIdentifier in
                try await Self.requestJitStreamer(
                    normalizedAddress: normalizedAddress,
                    processIdentifier: processIdentifier
                )
            }
            let openExternalJITURL: @MainActor @Sendable (URL) async -> Bool = { url in
                await withCheckedContinuation { continuation in
                    UIApplication.shared.open(url, options: [:]) { opened in
                        continuation.resume(returning: opened)
                    }
                }
            }
            let externalJITSchemeProbeResults: @MainActor @Sendable () -> [(
                scheme: String, available: Bool
            )] = {
                ExternalJITProviderResolver.schemeProbeResults()
            }
        #endif

        #if os(iOS)
            return AppViewModelDependencies(
                store: store,
                runtimeBundleRegistry: runtimeBundleRegistry,
                runtimeProvisioningService: runtimeProvisioningService,
                capabilityProvider: capabilityProvider,
                validationService: validationService,
                artifactInventory: artifactInventory,
                sessionExecutor: sessionExecutor,
                runtimePlayerServiceRegistry: runtimePlayerServiceRegistry,
                runningSessionObserver: runningSessionObserver,
                runtimePlayerFirstFrameTimeoutNanoseconds: 60 * 1_000_000_000,
                runtimePolicyResolver: runtimePolicyResolver,
                titleOverrideResolver: titleOverrideResolver,
                compatibilityProfiles: compatibilityProfiles,
                runtimeDescriptor: runtimeDescriptor,
                externalJITBundleInfo: externalJITBundleInfo,
                loadJitStreamerAddress: loadJitStreamerAddress,
                saveJitStreamerAddress: saveJitStreamerAddress,
                requestAltJIT: requestAltJIT,
                requestJitStreamer: requestJitStreamer,
                openExternalJITURL: openExternalJITURL,
                externalJITSchemeProbeResults: externalJITSchemeProbeResults
            )
        #else
            return AppViewModelDependencies(
                store: store,
                runtimeBundleRegistry: runtimeBundleRegistry,
                runtimeProvisioningService: runtimeProvisioningService,
                capabilityProvider: capabilityProvider,
                validationService: validationService,
                artifactInventory: artifactInventory,
                sessionExecutor: sessionExecutor,
                runtimePlayerServiceRegistry: runtimePlayerServiceRegistry,
                runningSessionObserver: runningSessionObserver,
                runtimePlayerFirstFrameTimeoutNanoseconds: 60 * 1_000_000_000,
                runtimePolicyResolver: runtimePolicyResolver,
                titleOverrideResolver: titleOverrideResolver,
                compatibilityProfiles: compatibilityProfiles,
                runtimeDescriptor: runtimeDescriptor
            )
        #endif
    }

    @MainActor
    static func makeForTesting(
        managedRootURL: URL? = nil,
        jitStatus: JITStatus = .required,
        runtimeHealth: RuntimeHealthReport = RuntimeHealthReport(
            status: .actionRequired,
            runtimeName: "Iridium Runtime Base",
            notes: ["Runtime validation has not run yet."]
        ),
        managedStorage: ManagedStorageStatus = ManagedStorageStatus(
            totalCapacityGB: 256,
            reservedForSystemGB: 24,
            usedByGamesGB: 0,
            usedByPrefixesGB: 0,
            reservedForQueuedDownloadsGB: 0,
            pressure: .healthy,
            notes: ["Managed storage status has not been measured yet."]
        ),
        games: [GameRecord] = [],
        prefixes: [PrefixRecord] = [],
        launchHistory: [LaunchHistoryEntry] = [],
        pendingLaunches: [PendingLaunchRecord] = [],
        installHistory: [InstallHistoryEntry] = [],
        compatibilityEvidence: [CompatibilityEvidenceRecord] = [],
        activityFeed: [ActivityLogEntry] = [],
        verificationAudits: [VerificationAuditEntry] = [],
        importScanResult: ImportScanResult? = nil,
        activeRuntimePlayerSession: RuntimePlayerSession? = nil,
        pendingExternalJITProvider: ExternalJITProvider? = nil,
        jitStreamerAddress: String = "",
        externalJITBundleInfo: ExternalJITBundleInfo = ExternalJITBundleInfo(
            bundleIdentifier: "software.iridium",
            altServerID: nil,
            altDeviceID: nil
        ),
        installedExternalJITSchemes: Set<String> = [],
        altJITRequest: (@Sendable () async throws -> Void)? = nil,
        jitStreamerRequest: (@Sendable (_ normalizedAddress: String, _ processIdentifier: pid_t) async throws -> Void)? = nil,
        openExternalJITURL: (@MainActor @Sendable (URL) async -> Bool)? = nil,
        sessionExecutor: (any RuntimeSessionExecutor)? = nil,
        capabilityProvider: (any HostCapabilityProvider)? = nil,
        validationService: (any RuntimeValidationService)? = nil,
        runtimePlayerServiceRegistry: (any RuntimePlayerServiceRegistry)? = nil,
        runningSessionObserver: (any RuntimeRunningSessionObserver)? = nil,
        runtimePlayerFirstFrameTimeoutNanoseconds: UInt64? = nil,
        hostCapabilities: HostCapabilitySnapshot = HostCapabilitySnapshot(
            jitStatus: .required,
            availableManagedStorageGB: 0,
            deviceCapabilityClass: .balanced,
            deviceTier: .tier2,
            thermalState: .nominal,
            lowPowerModeEnabled: false,
            runtimeBundles: [],
            selectedRuntimeBundle: nil,
            constraints: []
        )
    ) -> AppViewModel {
        let resolvedManagedRootURL =
            managedRootURL
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: resolvedManagedRootURL,
            withIntermediateDirectories: true
        )

        var testingSnapshot = IridiumSnapshot.empty
        testingSnapshot.games = games
        testingSnapshot.prefixes = prefixes
        testingSnapshot.runtimeHealth = runtimeHealth
        testingSnapshot.launchHistory = launchHistory
        testingSnapshot.pendingLaunches = pendingLaunches
        testingSnapshot.installHistory = installHistory
        testingSnapshot.compatibilityEvidence = compatibilityEvidence
        testingSnapshot.activityFeed = activityFeed
        testingSnapshot.verificationAudits = verificationAudits

        let dependencies = makeDependencies(
            store: IridiumStore(snapshot: testingSnapshot, snapshotURL: nil),
            managedRootURL: resolvedManagedRootURL
        )
        #if os(iOS)
            let testingDependencies = AppViewModelDependencies(
                store: dependencies.store,
                runtimeBundleRegistry: dependencies.runtimeBundleRegistry,
                runtimeProvisioningService: dependencies.runtimeProvisioningService,
                capabilityProvider: capabilityProvider ?? dependencies.capabilityProvider,
                validationService: validationService ?? dependencies.validationService,
                artifactInventory: dependencies.artifactInventory,
                sessionExecutor: sessionExecutor ?? dependencies.sessionExecutor,
                runtimePlayerServiceRegistry: runtimePlayerServiceRegistry ?? NoopRuntimePlayerServiceRegistry(),
                runningSessionObserver: runningSessionObserver
                    ?? StaticRuntimeRunningSessionObserver(terminalState: .completed),
                runtimePlayerFirstFrameTimeoutNanoseconds:
                    runtimePlayerFirstFrameTimeoutNanoseconds,
                runtimePolicyResolver: dependencies.runtimePolicyResolver,
                titleOverrideResolver: dependencies.titleOverrideResolver,
                compatibilityProfiles: dependencies.compatibilityProfiles,
                runtimeDescriptor: dependencies.runtimeDescriptor,
                externalJITBundleInfo: { externalJITBundleInfo },
                loadJitStreamerAddress: { jitStreamerAddress },
                saveJitStreamerAddress: { _ in },
                requestAltJIT: altJITRequest ?? {
                    throw ExternalJITRequestError.altJITUnavailable
                },
                requestJitStreamer: jitStreamerRequest ?? { _, _ in },
                openExternalJITURL: openExternalJITURL ?? { _ in true },
                externalJITSchemeProbeResults: {
                    ExternalJITProviderResolver.probedSchemes.map { scheme in
                        (scheme: scheme, available: installedExternalJITSchemes.contains(scheme))
                    }
                }
            )
        #else
            let testingDependencies = AppViewModelDependencies(
                store: dependencies.store,
                runtimeBundleRegistry: dependencies.runtimeBundleRegistry,
                runtimeProvisioningService: dependencies.runtimeProvisioningService,
                capabilityProvider: capabilityProvider ?? dependencies.capabilityProvider,
                validationService: validationService ?? dependencies.validationService,
                artifactInventory: dependencies.artifactInventory,
                sessionExecutor: sessionExecutor ?? dependencies.sessionExecutor,
                runtimePlayerServiceRegistry: runtimePlayerServiceRegistry ?? NoopRuntimePlayerServiceRegistry(),
                runningSessionObserver: runningSessionObserver
                    ?? StaticRuntimeRunningSessionObserver(terminalState: .completed),
                runtimePlayerFirstFrameTimeoutNanoseconds:
                    runtimePlayerFirstFrameTimeoutNanoseconds,
                runtimePolicyResolver: dependencies.runtimePolicyResolver,
                titleOverrideResolver: dependencies.titleOverrideResolver,
                compatibilityProfiles: dependencies.compatibilityProfiles,
                runtimeDescriptor: dependencies.runtimeDescriptor
            )
        #endif
        let viewModel = AppViewModel(dependencies: testingDependencies, autoRefresh: false)
        viewModel.jitStatus = jitStatus
        viewModel.runtimeHealth = runtimeHealth
        viewModel.managedStorage = managedStorage
        viewModel.importScanResult = importScanResult
        viewModel.games = games
        viewModel.prefixes = prefixes
        viewModel.launchHistory = launchHistory
        viewModel.pendingLaunches = pendingLaunches
        viewModel.installHistory = installHistory
        viewModel.compatibilityEvidence = compatibilityEvidence
        viewModel.activityFeed = activityFeed
        viewModel.verificationAudits = verificationAudits
        viewModel.activeRuntimePlayerSession = activeRuntimePlayerSession
        viewModel.pendingExternalJITProvider = pendingExternalJITProvider
        viewModel.jitStreamerAddress = jitStreamerAddress
        viewModel.hostCapabilities = hostCapabilities
        viewModel.refreshJITEnablementState()
        viewModel.onboardingChecks = viewModel.buildOnboardingChecks()
        return viewModel
    }

    deinit {
        pendingLaunchPollingTask?.cancel()
        externalJITEnablementTask?.cancel()
        runningSessionMonitorTask?.cancel()
        runtimePlayerFirstFrameWatchdogTask?.cancel()
    }

    private func refreshHostReadinessSnapshot() async {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled { return }
        #endif
        let userlandRootPath =
            runtimePlayerReservation?.userlandRootPath
            ?? activeRuntimePlayerSession?.userlandRootPath
        await withRuntimePlayerUserlandRoot(userlandRootPath) {
            hostCapabilities = await capabilityProvider.snapshot()
            jitStatus = hostCapabilities.jitStatus
            refreshJITEnablementState()
            runtimeHealth = await validationService.validate(snapshot: hostCapabilities)
            runtimeDescriptor = hostCapabilities.selectedRuntimeBundle?.descriptor
                ?? BundledRuntimeCatalog.defaultRuntime
            onboardingChecks = buildOnboardingChecks()
        }
    }

    private func refreshLaunchHistorySnapshot() async {
        let visibleGameTitles = Set(games.map(\.title))
        launchHistory = (await store.launchHistory()).filter {
            visibleGameTitles.contains($0.gameTitle)
        }
    }

    private func refreshRuntimeEvidenceSnapshots() async {
        let storedGames = await store.allGames()
        let storedGamesByID = Dictionary(uniqueKeysWithValues: storedGames.map { ($0.id, $0) })
        games = games.map { storedGamesByID[$0.id] ?? $0 }
        let visibleGameTitles = Set(games.map(\.title))
        compatibilityEvidence = (await store.compatibilityEvidence()).filter {
            $0.source == .manualImport && visibleGameTitles.contains($0.title)
        }
    }

    func dismissActiveRuntimePlayer() {
        let sessionTitle = activeRuntimePlayerSession?.gameTitle ?? runtimePlayerReservation?.gameTitle
        let sessionIdentifier = activeRuntimePlayerSession?.sessionIdentifier
            ?? runtimePlayerReservation?.sessionIdentifier

        guard let sessionIdentifier else {
            return
        }

        releaseRuntimePlayerReservation(sessionIdentifier: sessionIdentifier)
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            UserDefaults.standard.removeObject(forKey: "IridiumPendingMadeiraLaunchTitle")
            activityStatusMessage = "Game player closed. Restart Iridium before starting another game."
            return
        }
        #endif
        if let sessionTitle {
            activityStatusMessage =
                "Dismissed the fullscreen runtime player for \(sessionTitle). Iridium will keep monitoring terminal completion in the background."
        }

        Task {
            await refreshHostReadinessSnapshot()
        }
    }

    func refresh() async {
        if refreshInProgress {
            refreshRequestedWhileBusy = true
            return
        }

        refreshInProgress = true
        defer {
            refreshInProgress = false
            if refreshRequestedWhileBusy {
                refreshRequestedWhileBusy = false
                Task { @MainActor in
                    await refresh()
                }
            }
        }

        do {
            _ = try await Self.provisionRuntimeIfNeeded(runtimeProvisioningService)
            if activityStatusMessage?.hasPrefix("Bundled runtime provisioning failed:") == true {
                activityStatusMessage = nil
            }
        } catch {
            activityStatusMessage =
                "Bundled runtime provisioning failed: \(error.localizedDescription)"
        }

        await store.recoverInterruptedOperations()
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            jitStatus = jit_check_debugged() ? .ready : .required
        } else {
            hostCapabilities = await capabilityProvider.snapshot()
            jitStatus = hostCapabilities.jitStatus
        }
        #else
        hostCapabilities = await capabilityProvider.snapshot()
        jitStatus = hostCapabilities.jitStatus
        #endif
        refreshJITEnablementState()
        let storedRuntimeHealth = await store.healthReport()
        let refreshedRuntimeHealth = await validationService.validate(snapshot: hostCapabilities)
        runtimeHealth = refreshedRuntimeHealth
        if runtimeHealthNeedsPersistence(
            current: storedRuntimeHealth, refreshed: refreshedRuntimeHealth)
        {
            await store.provisionRuntimeBundleMetadata(refreshedRuntimeHealth)
        }

        var allGames = await store.allGames()
        let gamesNeedingVerification =
            allGames
            .filter { $0.source == .manualImport && $0.prefixState == .verificationFailed }
            .map(\.id)
        if !gamesNeedingVerification.isEmpty {
            for gameID in gamesNeedingVerification {
                _ = await store.verify(gameID: gameID)
            }
            allGames = await store.allGames()
        }

        let allPrefixes = await store.allPrefixes()
        let visibleGames = allGames.filter { $0.source == .manualImport }
        let hiddenSteamPrefixIDs = Set(
            allGames
                .filter { $0.source == .steam }
                .map(\.launchProfile.prefixID)
        )
        let visiblePrefixes = allPrefixes.filter { !hiddenSteamPrefixIDs.contains($0.id) }
        let visibleGameTitles = Set(visibleGames.map(\.title))
        let visibleGameIDs = Set(visibleGames.map(\.id))
        let visiblePendingLaunches = (await store.pendingLaunches())
            .filter { visibleGameIDs.contains($0.gameID) }

        games = visibleGames
        if preparesArtworkAutomatically {
            print("[IridiumArtwork] Preparing artwork for \(visibleGames.count) game(s)")
            Task { await LibraryArtwork.shared.prepare(visibleGames) }
        }
        prefixes = visiblePrefixes
        pendingLaunches = visiblePendingLaunches
        runtimeDescriptor =
            hostCapabilities.selectedRuntimeBundle?.descriptor
            ?? BundledRuntimeCatalog.defaultRuntime
        managedStorage = importOnlyManagedStorage(
            from: await store.managedStorageStatus(),
            games: visibleGames,
            prefixes: visiblePrefixes
        )
        launchHistory = (await store.launchHistory()).filter {
            visibleGameTitles.contains($0.gameTitle)
        }
        installHistory = []
        compatibilityEvidence = (await store.compatibilityEvidence()).filter {
            $0.source == .manualImport && visibleGameTitles.contains($0.title)
        }
        activityFeed = visibleActivityEntries(
            from: await store.activityFeed(),
            visibleGameTitles: visibleGameTitles
        )
        verificationAudits = (await store.verificationAudits()).filter {
            visibleGameIDs.contains($0.gameID)
        }
        onboardingChecks = buildOnboardingChecks()
        configurePendingLaunchPolling()

        if jitStatus == .ready, hostCapabilities.launchReady == true, !isResumingPendingLaunch,
            let pendingLaunch = visiblePendingLaunches.first
        {
            isResumingPendingLaunch = true
            Task { @MainActor in
                await resumePendingLaunch(pendingLaunch)
            }
        }
    }

    private func runtimeHealthNeedsPersistence(
        current: RuntimeHealthReport,
        refreshed: RuntimeHealthReport
    ) -> Bool {
        current.status != refreshed.status
            || current.runtimeName != refreshed.runtimeName
            || current.runtimeBundleIdentifier != refreshed.runtimeBundleIdentifier
            || current.runtimeBundleVersion != refreshed.runtimeBundleVersion
            || current.validationEvidence != refreshed.validationEvidence
            || current.activeConstraints != refreshed.activeConstraints
            || current.notes != refreshed.notes
            || (current.lastValidatedAt == nil) != (refreshed.lastValidatedAt == nil)
    }

    func validateRuntime() {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            activityStatusMessage = "Madeira test runtime selected. Device verification is pending."
            return
        }
        #endif
        Task {
            let snapshot = await capabilityProvider.snapshot()
            let report = await validationService.validate(snapshot: snapshot)
            await store.validateRuntime(report: report)
            await refresh()
        }
    }

    private nonisolated static func provisionRuntimeIfNeeded(
        _ service: any RuntimeProvisioningService
    ) async throws -> RuntimeBundleManifest {
        try await Task.detached(priority: .utility) {
            try service.provisionIfNeeded()
        }.value
    }

    func repairPrefix(_ prefix: PrefixRecord) {
        Task {
            await store.repair(prefixID: prefix.id)
            await refresh()
        }
    }

    func rebuildPrefix(_ prefix: PrefixRecord) {
        Task {
            await store.rebuild(prefixID: prefix.id)
            await refresh()
        }
    }

    func clonePrefix(_ prefix: PrefixRecord) {
        Task {
            _ = await store.clone(prefixID: prefix.id, newName: "\(prefix.name) Copy")
            await refresh()
        }
    }

    func scanImportFolder(at url: URL) {
        print("[IridiumRuntime] scanImportFolder: buildMarker=\(Self.importDebugBuildMarker)")
        importScanTask?.cancel()
        releaseImportSecurityScopedAccess()
        importMetadataCache = [:]
        importMetadataCacheTitle = nil
        importScanResult = nil

        let installURL = resolvedImportInstallURL(for: url)
        let resolvedInstallPath = installURL.path
        let inferredTitle = resolvedImportTitle(for: installURL)
        importSourceURL = url
        importScanRequestID = UUID()
        let requestID = importScanRequestID

        if url.startAccessingSecurityScopedResource() {
            importSourceAccessActive = true
            print(
                "[IridiumRuntime] scanImportFolder: Started security-scoped access for \(url.path)")
        } else {
            print(
                "[IridiumRuntime] scanImportFolder: Failed to start security-scoped access for \(url.path)"
            )
        }

        importStatusMessage = "Scanning \(installURL.lastPathComponent)…"
        let artifactInventory = self.artifactInventory
        importScanTask = Task.detached(priority: .userInitiated) {
            [resolvedInstallPath, inferredTitle, installURL] in
            let scanResult = ImportScanner().scan(
                installPath: installURL.path, title: inferredTitle)
            var metadataCache: [String: (identifier: String, fingerprint: String)] = [:]

            for executable in scanResult.executables {
                let artifact = try? artifactInventory.makeManagedArtifact(
                    title: inferredTitle,
                    executablePath: executable.path,
                    installPath: resolvedInstallPath
                )
                let fingerprint =
                    artifact?.checksum
                    ?? (try? artifactInventory.fingerprintExecutable(at: executable.path).value)
                guard let identifier = artifact?.identifier,
                    !identifier.isEmpty,
                    let fingerprint,
                    !fingerprint.isEmpty
                else {
                    print(
                        "[IridiumRuntime] scanImportFolder: Failed to cache metadata for \(executable.path)"
                    )
                    continue
                }
                metadataCache[executable.path] = (identifier, fingerprint)
            }
            let resolvedMetadataCache = metadataCache

            await MainActor.run {
                guard requestID == self.importScanRequestID else {
                    return
                }

                self.importScanResult = scanResult
                self.importMetadataCache = resolvedMetadataCache
                self.importMetadataCacheTitle = inferredTitle
                print(
                    "[IridiumRuntime] scanImportFolder: Cached metadata for \(resolvedMetadataCache.count) executable(s)"
                )

                if scanResult.executables.isEmpty {
                    self.importStatusMessage =
                        "No Windows executable was found in \(installURL.lastPathComponent)."
                } else {
                    self.importStatusMessage =
                        "Scanned \(installURL.lastPathComponent) and ranked \(scanResult.executables.count) executables."
                }
            }
        }
    }

    func reportImportSelectionFailure(_ error: Error) {
        importStatusMessage = "Import selection failed: \(error.localizedDescription)"
    }

    func relocateScannedImport(_ game: GameRecord) {
        guard !isImportingGame else { return }
        guard let scan = importScanResult, let executable = scan.recommendedExecutable else { return }
        let source = importSourceURL
        isImportingGame = true
        Task {
            defer { isImportingGame = false }
            let access = source?.startAccessingSecurityScopedResource() ?? false
            defer { if access { source?.stopAccessingSecurityScopedResource() } }
            guard let metadata = validatedImportMetadata(title: game.title, executablePath: executable.path, installPath: scan.installPath) else { return }
            do {
                try await store.relocateLibraryEntry(gameID: game.id, folder: URL(fileURLWithPath: scan.installPath),
                    executable: URL(fileURLWithPath: executable.path), identifier: metadata.identifier, fingerprint: metadata.fingerprint)
                dismissImportScan()
                await refresh()
                importStatusMessage = "Game location updated. Existing files and saves were kept."
            } catch { importStatusMessage = "Could not update game location: \(error.localizedDescription)" }
        }
    }

    func chooseImportExecutable(path: String) {
        guard let executable = importScanResult?.executables.first(where: { $0.path == path }) else { return }
        importScanResult?.recommendedExecutable = executable
    }

    func removeLibraryEntry(_ game: GameRecord) {
        guard activeRuntimePlayerSession?.gameID != game.id, runtimePlayerReservation?.gameID != game.id else { return }
        Task {
            await store.removeLibraryEntry(gameID: game.id)
            await refresh()
        }
    }

    func registerScannedImport(title: String? = nil) {
        guard !isImportingGame else { return }
        print("[IridiumRuntime] registerScannedImport: buildMarker=\(Self.importDebugBuildMarker)")
        guard let scan = importScanResult,
            let executable = scan.recommendedExecutable
        else {
            importStatusMessage = "No recommended executable is available yet."
            return
        }

        let inferredTitle = resolvedImportTitle(for: scan, preferredTitle: title)
        let compatibility = BuiltInCompatibilityProfiles.recommendedCompatibilityProfile(
            forTitle: inferredTitle)
        // The scan-time cache is keyed by executable path but its identifiers
        // were derived from the scan-time (folder) title, which can normalize
        // differently than the final registration title (e.g. folder
        // "HollowKnight" vs executable stem "hollow_knight"). Reusing it would
        // store an identifier that launch validation recomputes differently,
        // permanently bricking launch with managedArtifactMismatch. Only reuse
        // the cache when it was computed under this same title; otherwise
        // recompute fresh below inside security-scoped access.
        let cachedMetadata: (identifier: String, fingerprint: String)?
        if let cached = importMetadataCache[executable.path],
            importMetadataCacheTitle == inferredTitle
        {
            cachedMetadata = cached
        } else {
            if importMetadataCache[executable.path] != nil {
                print(
                    "[IridiumRuntime] registerScannedImport: Discarding scan-time metadata cached under title \(importMetadataCacheTitle ?? "nil") for registration title \(inferredTitle)"
                )
            }
            cachedMetadata = nil
        }
        let importSourceURL = importSourceURL
        let requestID = importScanRequestID
        let importInstallPath =
            importSourceURL.map { resolvedImportInstallURL(for: $0).path } ?? scan.installPath

        print(
            "[IridiumRuntime] registerScannedImport: metadata cache hit = \(cachedMetadata != nil) for \(executable.path)"
        )

        isImportingGame = true
        Task {
            defer { isImportingGame = false }
            let metadata =
                cachedMetadata
                ?? withImportSecurityScopedAccess(
                    importSourceURL
                ) {
                    validatedImportMetadata(
                        title: inferredTitle,
                        executablePath: executable.path,
                        installPath: importInstallPath
                    )
                }
            guard let metadata else {
                print(
                    "[IridiumRuntime] registerScannedImport: Metadata resolution failed for \(executable.path)"
                )
                return
            }
            let importedGame = await withImportSecurityScopedAccess(
                importSourceURL
            ) {
                await store.importGame(
                    title: inferredTitle,
                    installPath: importInstallPath,
                    executablePath: executable.path,
                    compatibilityProfileName: compatibility.slug,
                    inputProfileName: defaultInputProfileName(for: compatibility),
                    deviceTier: compatibility.minimumDeviceTier,
                    rendererPreset: compatibility.recommendedRenderer,
                    managedArtifactIdentifier: metadata.identifier,
                    executableFingerprint: metadata.fingerprint,
                    runtimeBundleIdentifier: hostCapabilities.selectedRuntimeBundle?.id,
                    runtimeBundleVersion: hostCapabilities.selectedRuntimeBundle?.version
                )
            }

            print(
                "[IridiumRuntime] registerScannedImport: Registered game id=\(importedGame.id) title=\(importedGame.title) executable=\(importedGame.launchProfile.executablePath)"
            )

            if requestID == importScanRequestID {
                importScanTask?.cancel()
                importScanTask = nil
                importMetadataCache = [:]
                importMetadataCacheTitle = nil
                importScanResult = nil
                releaseImportSecurityScopedAccess()
                importStatusMessage = "Registered \(inferredTitle) with \(compatibility.title)."
                print(
                    "[IridiumRuntime] registerScannedImport: Completed import UI state and released source access"
                )
            } else {
                print(
                    "[IridiumRuntime] registerScannedImport: Preserved newer import UI state after request changed"
                )
            }
            await refresh()
            await LibraryArtwork.shared.prepare([importedGame])
        }
    }

    func dismissImportScan() {
        importScanTask?.cancel()
        importMetadataCache = [:]
        importMetadataCacheTitle = nil
        releaseImportSecurityScopedAccess()
        importScanResult = nil
        importStatusMessage = nil
    }

    func compatibilityProfile(for game: GameRecord) -> CompatibilityProfile? {
        compatibilityProfiles.first(where: { $0.slug == game.compatibilityProfileName })
    }

    func ownerTitle(for prefix: PrefixRecord) -> String? {
        games.first(where: { $0.launchProfile.prefixID == prefix.id })?.title
    }

    func launchSession(for game: GameRecord) -> LaunchSession {
        var session = buildLaunchSession(for: game, jitStatus: jitStatus)
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            let issue = activeRuntimePlayerSession?.gameID == game.id ? nil : madeiraLaunchIssue(for: game)
            session.readiness = issue == nil ? .ready : .blockedByPolicy
            session.issues = issue.map { [LaunchIssue(severity: .blocking, message: $0)] } ?? []
        }
        #endif
        return session
    }

    var recommendedJITToolDisplayName: String? {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled { return "StikDebug through LiveContainer2" }
        #endif
        #if os(iOS)
            return recommendedExternalJITProvider()?.displayName
        #else
            return nil
        #endif
    }

    var jitToolActionTitle: String? {
        #if BUILTIN_STIKJIT
        if BuiltinJIT.selected { return nil }
        #endif
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            return StikJITHelper.persistentScriptRequested
                ? "Run JIT Script Again"
                : "Run JIT Script in LiveContainer2"
        }
        #endif
        switch jitEnablementState {
        case .toolLaunchAvailable:
            guard let provider = recommendedExternalJITProvider() else {
                return nil
            }
            return provider.actionTitle
        case .bootstrapRequired:
            return "Waiting for Runtime Readiness..."
        case .backendUnavailable:
            guard let provider = recommendedExternalJITProvider() else {
                return nil
            }
            return "Retry JIT With \(provider.displayName)"
        case .waitingForExternalEnablement:
            guard let provider = pendingExternalJITProvider ?? recommendedExternalJITProvider()
            else {
                return nil
            }
            return provider.waitingForReadinessSummary
        case .notDetected, .ready:
            return nil
        }
    }

    var canLaunchRecommendedJITTool: Bool {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled { return true }
        #endif
        return recommendedJITToolDisplayName != nil && jitStatus != .ready
            && jitEnablementState != .waitingForExternalEnablement
    }

    func updateJitStreamerAddress(_ value: String) {
        jitStreamerAddress = value
        #if os(iOS)
            saveJitStreamerAddress(value)
            refreshJITEnablementState()
        #endif
    }

    func pendingLaunch(for game: GameRecord) -> PendingLaunchRecord? {
        pendingLaunches.first(where: { $0.gameID == game.id })
    }

    func requestRefresh() {
        Task {
            await refresh()
        }
    }

    func runtimePlayerBridgeConfiguration(for sessionIdentifier: String) -> RuntimePlayerBridgeConfiguration? {
        guard runtimePlayerPreparedSession?.sessionIdentifier == sessionIdentifier else {
            return nil
        }
        return runtimePlayerPreparedSession?.bridgeConfiguration
    }

    func recordRuntimePlayerFirstFramePresented(sessionIdentifier: String) {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            UserDefaults.standard.removeObject(forKey: "IridiumPendingMadeiraLaunchTitle")
            activeRuntimePlayerSession?.statusSummary = "Madeira presented a guest frame. Gameplay verification is pending."
            print("[IridiumMadeira] first-present session=\(sessionIdentifier)")
            return
        }
        #endif
        guard
            let activeSession = activeRuntimePlayerSession,
            activeSession.sessionIdentifier == sessionIdentifier,
            activeSession.state == .running,
            let verification = runtimePlayerVerificationContext,
            verification.execution.sessionIdentifier == sessionIdentifier
        else {
            return
        }

        switch runtimePlayerServiceRegistry.recordFirstFramePresented(
            sessionIdentifier: sessionIdentifier
        ) {
        case .success:
            runtimePlayerFirstFrameWatchdogTask?.cancel()
            runtimePlayerFirstFrameWatchdogTask = nil
            verifiedRuntimePlayerSessions.insert(sessionIdentifier)
            runtimePlayerVerificationContext = nil
            if var activeSession = activeRuntimePlayerSession {
                activeSession.statusSummary = "Runtime player presented its first guest frame."
                activeRuntimePlayerSession = activeSession
            }
            activityStatusMessage = verification.successStatusMessage
            print(
                "[IridiumRuntime] runtimePlayer: firstFrameObserved session=\(sessionIdentifier) milestonePersisted=true"
            )
            Task {
                await store.recordRuntimeExecutionSuccess(
                    gameID: verification.game.id,
                    launchEntryID: verification.launchRecord.id,
                    resolvedExecutablePath: verification.execution.resolvedExecutablePath,
                    issueSummary: verification.issueSummary + [
                        "Fullscreen player persisted the first guest frame.",
                        "State history: \(verification.execution.stateHistory.joined(separator: " -> ")).",
                    ],
                    hostSessionID: sessionIdentifier,
                    stateHistory: verification.execution.stateHistory + ["firstFramePresented"],
                    terminalStatus: "firstFramePresented",
                    runtimeBundleIdentifier: verification.execution.runtimeBundleID,
                    runtimeBundleVersion: verification.execution.runtimeBundleVersion,
                    manifestPath: verification.execution.prefixManifestPath,
                    manifestVersion: "1",
                    environmentOverrides: verification.execution.environment,
                    prefixState: .customized,
                    bootstrapDetail: "Fullscreen player persisted the first guest frame.",
                    telemetrySummary: telemetrySummary(verification.execution.telemetrySnapshot),
                    mitigationAction: verification.execution.mitigationAction.rawValue,
                    evidenceSummary: titleOverrideResolver.evidenceSummary(for: verification.game),
                    resolvedPolicySummary: policySummary(
                        for: verification.game.compatibilityProfileName,
                        runtimePolicy: verification.resolvedPolicy
                    ),
                    launchedAt: verification.execution.launchedAt
                )
                await refreshRuntimeEvidenceSnapshots()
                await refreshLaunchHistorySnapshot()
                print(
                    "[IridiumRuntime] executeLaunch: launchVerified session=\(sessionIdentifier) firstFrame=true"
                )
            }
        case .failure(let failure):
            print(
                "[IridiumRuntime] runtimePlayer: firstFrameObserved session=\(sessionIdentifier) milestonePersisted=false code=\(failure.code.rawValue) reason=\"\(failure.reason)\""
            )
        }
    }

    func enableJITWithRecommendedTool() {
        #if BUILTIN_STIKJIT
        if BuiltinJIT.selected {
            lastJITCheckSummary = "Built-in JIT starts when you press Play. Import its pairing file in Launch Support first."
            return
        }
        #endif
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            StikJITHelper.enableJIT { [weak self] ready in
                guard let self else { return }
                if ready {
                    self.refreshJITEnablementState()
                    self.lastJITCheckSummary = "StikDebug attached. Launch a game to prepare its code memory."
                }
                self.activityStatusMessage = ready ? "Madeira JIT attached." : "StikDebug could not attach."
            }
            return
        }
        #endif
        #if os(iOS)
            let schemeProbeResults = externalJITSchemeProbeResults()
            let installedSchemes = ExternalJITProviderResolver.installedSchemes(from: schemeProbeResults)
            let bundleInfo = externalJITBundleInfo()
            let normalizedJitStreamerAddress = ExternalJITProviderResolver.normalizedJitStreamerAddress(
                jitStreamerAddress
            )
            print(
                "[IridiumRuntime] jit-provider: probe_results=altjit=\(bundleInfo.isAltJITCompatible ? "available" : "missing"), jitstreamer=\(normalizedJitStreamerAddress != nil ? "configured" : "missing"), \(ExternalJITProviderResolver.formattedSchemeProbeResults(schemeProbeResults))"
            )

            guard let provider = ExternalJITProviderResolver.recommendedProvider(
                for: hostCapabilities,
                bundleInfo: bundleInfo,
                jitStreamerAddress: jitStreamerAddress,
                installedSchemes: installedSchemes
            ) else {
                print(
                    "[IridiumRuntime] jit-provider: no_launchable_provider recommendation=\(hostCapabilities.jitToolRecommendation?.rawValue ?? "none") installed_schemes=\(installedSchemes.sorted().joined(separator: ",")) altjit=\(bundleInfo.isAltJITCompatible) jitstreamer=\(normalizedJitStreamerAddress ?? "none")"
                )
                return
            }

            print(
                "[IridiumRuntime] jit-provider: selected_provider=\(provider.displayName) recommendation=\(hostCapabilities.jitToolRecommendation?.rawValue ?? "none")"
            )
            pendingExternalJITProvider = provider
            jitEnablementState = .waitingForExternalEnablement
            lastJITCheckSummary = provider.requestInProgressSummary
            externalJITEnablementTask?.cancel()
            externalJITEnablementTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await self.requestExternalJITEnablement(
                    provider: provider,
                    bundleInfo: bundleInfo,
                    installedSchemes: installedSchemes,
                    normalizedJitStreamerAddress: normalizedJitStreamerAddress
                )
            }
        #endif
    }

    func checkJITAgain() {
        guard !isCheckingJIT else {
            return
        }

        let previousStatus = jitStatus
        isCheckingJIT = true
        lastJITCheckSummary = "Checking JIT availability..."

        Task {
            await refresh()
            let refreshedStatus = jitStatus
            let checkedAt = Date().formatted(date: .omitted, time: .shortened)
            if refreshedStatus == .ready {
                if hostCapabilities.launchReady != true {
                    lastJITCheckSummary =
                        "Checked at \(checkedAt). JIT is attached, but the embedded launch bootstrap is unavailable: \(hostCapabilities.launchStatusSummary ?? "no launch-ready backend was reported")."
                } else if hostCapabilities.runtimeMilestones?.fullyVerified == true {
                    lastJITCheckSummary = "Checked at \(checkedAt). Runtime remains verified through first frame."
                } else if refreshedStatus == previousStatus {
                    lastJITCheckSummary =
                        "Checked at \(checkedAt). JIT remains attached and the embedded bootstrap is ready; launch a game to verify Wine startup and first frame."
                } else {
                    lastJITCheckSummary =
                        "Checked at \(checkedAt). JIT is now attached and the embedded bootstrap is ready; launch a game to verify Wine startup and first frame."
                }
            } else if hostCapabilities.executionEnvironment == .nativeRuntime {
                lastJITCheckSummary = checkedJITSummary(
                    at: checkedAt,
                    status: refreshedStatus
                )
            } else if refreshedStatus == previousStatus {
                lastJITCheckSummary =
                    "Checked at \(checkedAt). JIT is still \(refreshedStatus.displayName.lowercased())."
            } else {
                lastJITCheckSummary =
                    "Checked at \(checkedAt). JIT is now \(refreshedStatus.displayName.lowercased())."
            }
            isCheckingJIT = false
        }
    }

    var jitLaunchNotice: String? {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            return nil // Madeira requests JIT during launch; missing JIT does not disable Play.
        }
        #endif
        let runtimeReadyForLaunch = jitStatus == .ready && hostCapabilities.launchReady == true
        let xcodeLightweightCheck = hostCapabilities.usesLightweightDebuggerCheck

        if let newestPendingLaunch = pendingLaunches.first {
            let queuedCount = pendingLaunches.count
            let queuedSummary: String
            if queuedCount == 1 {
                queuedSummary =
                    "\(newestPendingLaunch.gameTitle) is queued and will resume automatically once JIT becomes available."
            } else {
                queuedSummary =
                    "\(queuedCount) launches are queued and will resume automatically once JIT becomes available."
            }

            return runtimeReadyForLaunch
                ? "JIT and the embedded launch bootstrap are ready. Iridium is resuming queued launches now."
                : queuedSummary
        }

        guard !runtimeReadyForLaunch else {
            return nil
        }

        if let summary = liveContainerJITSetupSummary() {
            return summary
        }

        if xcodeLightweightCheck {
            return hostCapabilities.jitSummary
                ?? hostCapabilities.launchStatusSummary
                ?? "Xcode-attached JIT checks use lightweight debugger detection only. Direct launch stays blocked in this mode."
        }

        if jitStatus == .unavailable {
            return helperBootstrapIncompleteSummary()
                ?? hostCapabilities.jitSummary
                ?? hostCapabilities.launchStatusSummary
                ?? "JIT was requested, but Iridium still did not observe runtime readiness."
        }

        if jitEnablementState == .bootstrapRequired {
            return helperBootstrapIncompleteSummary()
        }

        if let summary = helperOpenedWithoutAttachSummary() {
            return summary
        }

        if jitEnablementState == .waitingForExternalEnablement,
            let provider = pendingExternalJITProvider ?? recommendedExternalJITProvider()
        {
            return provider.waitingNotice
        }

        if let toolName = recommendedJITToolDisplayName {
            return
                "Iridium can open \(toolName) for this app process, or you can enable JIT externally and then check again."
        }

        #if os(iOS)
            if JITPlatformCompatibility.requiresPersistentDebuggerCallback {
                return
                    "This device requires StikDebug 3.1.6 or newer with Iridium's persistent TXM callback. Install StikDebug, then return here to enable JIT."
            }
        #endif

        return
            "Iridium is ready for imports and prefix management, but Windows game launching stays disabled until this app process is launched under a trusted external debugger/JIT session."
    }

    #if MADEIRA_RUNTIME
    private var madeiraRuntimeAvailable: Bool {
        ["prefix-template.tar.gz", "arm64ec-windows/xtajit64.dll"].allSatisfy {
            FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent($0).path)
        }
    }

    private func madeiraLaunchIssue(for game: GameRecord) -> String? {
        MadeiraLaunchReadiness.issue(
            runtimeAvailable: madeiraRuntimeAvailable,
            executableExists: FileManager.default.fileExists(atPath: buildLaunchSession(for: game, jitStatus: jitStatus).executablePath),
            busy: activeRuntimePlayerSession != nil || runtimePlayerReservation != nil,
            started: MadeiraRuntimeAdapter.started
        )
    }
    #endif

    func launchActionTitle(for game: GameRecord) -> String {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            if activeRuntimePlayerSession?.gameID == game.id { return "Player Open" }
            if runtimePlayerReservation?.gameID == game.id { return "Preparing…" }
            if MadeiraRuntimeAdapter.started { return "Restart Iridium to Play" }
            return "Play"
        }
        #endif
        let session = launchSession(for: game)
        if let activeRuntimePlayerSession, activeRuntimePlayerSession.gameID == game.id {
            return "Running in Player"
        }
        if runtimePlayerReservation?.gameID == game.id {
            return "Preparing Player..."
        }
        if pendingLaunch(for: game) != nil {
            return (jitStatus == .ready && hostCapabilities.launchReady == true)
                ? "Resuming Direct Launch..."
                : "Waiting for JIT"
        }

        if canPrepareRuntimePlayer(for: game, session: session) {
            return "Prepare Player and Launch"
        }

        if canLaunchWithRuntimeValidationWarning(session: session, report: readinessReport(for: game)) {
            return "Execute Direct Launch"
        }

        if session.readiness == .blockedByJIT, canQueueLaunchAfterJIT(for: game) {
            return "Queue Launch Until JIT Ready"
        }

        switch session.readiness {
        case .blockedByJIT:
            return "Direct Launch Unavailable"
        case .blockedByPolicy, .needsRuntimeValidation, .missingExecutable:
            return "Direct Launch Blocked"
        case .ready:
            return "Execute Direct Launch"
        }
    }

    func launchActionDetail(for game: GameRecord) -> String? {
        if !FileManager.default.fileExists(atPath: game.launchProfile.executablePath) {
            return "Game file moved or missing. Open Game Options to locate its folder."
        }
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            return madeiraLaunchIssue(for: game) ?? "Launch this game. Iridium will request JIT through LiveContainer2 if needed."
        }
        #endif
        let session = launchSession(for: game)
        if let activeRuntimePlayerSession, activeRuntimePlayerSession.gameID == game.id {
            return "This title currently owns the fullscreen runtime player. Dismiss the player before starting another launch."
        }
        if activeRuntimePlayerSession != nil || runtimePlayerReservation != nil {
            return "Another title already owns the fullscreen runtime player services. Finish or dismiss that session before launching a new title."
        }
        if let pendingLaunch = pendingLaunch(for: game) {
            return pendingLaunch.detail
        }

        if canPrepareRuntimePlayer(for: game, session: session) {
            return "Iridium can arm the fullscreen player services, refresh live host readiness, and launch once presentation, input, and audio are bound to this session."
        }

        if canLaunchWithRuntimeValidationWarning(session: session, report: readinessReport(for: game)) {
            return nil
        }

        switch session.readiness {
        case .blockedByJIT:
            if canQueueLaunchAfterJIT(for: game) {
                return
                    "Iridium will save this launch request, keep watching for JIT readiness, and continue automatically once JIT is enabled."
            }

            if jitStatus == .unavailable {
                return hostCapabilities.jitSummary
                    ?? hostCapabilities.launchStatusSummary
                    ?? session.issues.first(where: { $0.severity == .blocking })?.message
                    ?? "Embedded runtime JIT probing failed on this host."
            }

            if let toolName = recommendedJITToolDisplayName {
                return
                    "Open \(toolName) to enable JIT for this app process, or enable JIT externally and then retry direct launch after the remaining launch checks pass."
            }

            #if os(iOS)
                if JITPlatformCompatibility.requiresPersistentDebuggerCallback {
                    return
                        "Install StikDebug 3.1.6 or newer; this device's TXM path cannot launch through a one-shot AltJIT, JitStreamer, or SideStore attach."
                }
            #endif

            return
                "Enable JIT for this Iridium app process with AltJIT, JitStreamer, SideStore, or a private-JIT path, then retry direct launch after the remaining launch checks pass."
        case .blockedByPolicy, .needsRuntimeValidation, .missingExecutable:
            return session.issues.first(where: { $0.severity == .blocking })?.message
                ?? readinessReport(for: game).summary
        case .ready:
            return nil
        }
    }

    func isLaunchActionDisabled(for game: GameRecord) -> Bool {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled { return madeiraLaunchIssue(for: game) != nil }
        #endif
        if activeRuntimePlayerSession != nil || runtimePlayerReservation != nil {
            return true
        }

        if pendingLaunch(for: game) != nil {
            return true
        }

        let session = launchSession(for: game)
        if canPrepareRuntimePlayer(for: game, session: session) {
            return false
        }
        if canLaunchWithRuntimeValidationWarning(session: session, report: readinessReport(for: game)) {
            return false
        }
        if session.readiness == .blockedByJIT {
            return !canQueueLaunchAfterJIT(for: game)
        }

        return readinessReport(for: game).overallStatus == .blocked
    }

    func logLaunchAvailability(for game: GameRecord) {
        let session = launchSession(for: game)
        let report = readinessReport(for: game)
        let actionTitle = launchActionTitle(for: game)
        let actionDetail = launchActionDetail(for: game)
        let disabled = isLaunchActionDisabled(for: game)
        let issueSummary = session.issues.map(\.message).joined(separator: " | ")

        print(
            "[IridiumRuntime] launchAvailability: game=\(game.title) actionTitle=\(actionTitle) disabled=\(disabled) readiness=\(session.readiness.displayName) overallStatus=\(report.overallStatus.displayName)"
        )
        print("[IridiumRuntime] launchAvailability: summary=\(report.summary)")
        print(
            "[IridiumRuntime] launchAvailability: executable=\(session.executablePath) workingDirectory=\(session.workingDirectory)"
        )
        print(
            "[IridiumRuntime] launchAvailability: arguments=\(launchArgumentsSummary(session.arguments))"
        )

        if let actionDetail, !actionDetail.isEmpty {
            print("[IridiumRuntime] launchAvailability: detail=\(actionDetail)")
        }

        if !issueSummary.isEmpty {
            print("[IridiumRuntime] launchAvailability: issues=\(issueSummary)")
        }
    }

    func recordLaunchPreparation(for game: GameRecord) {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            if let issue = madeiraLaunchIssue(for: game) { activityStatusMessage = issue; return }
            UserDefaults.standard.set(game.title, forKey: "IridiumPendingMadeiraLaunchTitle")
            let id = UUID().uuidString
            switch RuntimePlayerPreparedSession.prepare(sessionIdentifier: id, graphicsStack: .dxmtViaMetal) {
            case .failure(let error):
                UserDefaults.standard.removeObject(forKey: "IridiumPendingMadeiraLaunchTitle")
                activityStatusMessage = error.reason
            case .success(let prepared):
                runtimePlayerPreparedSession = prepared
                activeRuntimePlayerSession = RuntimePlayerSession(
                    sessionIdentifier: id, gameID: game.id,
                    gameTitle: UserDefaults.standard.string(forKey: "IridiumMadeiraTest") == "cube" ? "Madeira x64 DX11 cube" : game.title,
                    runtimeBundleID: "madeira-experimental", runtimeBundleVersion: "local",
                    userlandRootPath: Bundle.main.bundlePath, graphicsStack: .dxmtViaMetal,
                    launchTicketPath: "", sessionLogPath: prepared.bridgeConfiguration.wineDebugLogPath,
                    telemetryPath: "", state: .running, stateHistory: [.running],
                    statusSummary: "Preparing Madeira. No rendered frame yet.", launchedAt: Date())
                MadeiraRuntimeAdapter.start(executable: launchSession(for: game).executablePath, gameRoot: game.installPath, gameID: game.id) { [weak self] message in
                    guard self?.activeRuntimePlayerSession?.sessionIdentifier == id else { return }
                    if message.contains("failed") || message.hasPrefix("Cannot") {
                        UserDefaults.standard.removeObject(forKey: "IridiumPendingMadeiraLaunchTitle")
                    }
                    self?.activeRuntimePlayerSession?.statusSummary = message
                    self?.activityStatusMessage = message
                    print("[IridiumMadeira] \(message)")
                }
            }
            return
        }
        #endif
        Task {
            let currentGame = games.first(where: { $0.id == game.id }) ?? game
            var launchTimer = RuntimeLaunchPhaseTimer(
                operation: "recordLaunchPreparation",
                gameTitle: currentGame.title
            )
            let session = launchSession(for: currentGame)
            let report = readinessReport(for: currentGame)
            let issueSummary = session.issues.map(\.message).joined(separator: " | ")
            var effectiveSession = session
            var effectiveReport = report
            var preparedPlayerReservation: ReservedRuntimePlayerSession?

            print(
                "[IridiumRuntime] recordLaunchPreparation: invoked game=\(currentGame.title) readiness=\(session.readiness.displayName) overallStatus=\(report.overallStatus.displayName)"
            )
            print(
                "[IridiumRuntime] recordLaunchPreparation: arguments=\(launchArgumentsSummary(session.arguments))"
            )
            print("[IridiumRuntime] recordLaunchPreparation: summary=\(report.summary)")
            if !issueSummary.isEmpty {
                print("[IridiumRuntime] recordLaunchPreparation: issues=\(issueSummary)")
            }

            await store.recordVerificationAudit(makeAuditEntry(for: currentGame, report: report))
            launchTimer.mark("verificationAuditRecorded")

            if session.readiness == .blockedByJIT, canQueueLaunchAfterJIT(for: currentGame) {
                print(
                    "[IridiumRuntime] recordLaunchPreparation: queueingForJIT game=\(currentGame.title)"
                )
                let now = Date()
                let launchEntryID = UUID()
                let queuedDetail =
                    "Launch is queued while Iridium waits for JIT. The app will continue automatically after JIT is enabled and the launch stays valid."
                let pendingLaunch = PendingLaunchRecord(
                    launchEntryID: launchEntryID,
                    gameID: currentGame.id,
                    gameTitle: currentGame.title,
                    prefixID: currentGame.launchProfile.prefixID,
                    resolvedExecutablePath: session.executablePath,
                    workingDirectory: session.workingDirectory,
                    launchArguments: session.arguments,
                    environment: session.environment,
                    runtimeBundleIdentifier: hostCapabilities.selectedRuntimeBundle?.id,
                    runtimeBundleVersion: hostCapabilities.selectedRuntimeBundle?.version,
                    resolvedPolicySummary: policySummary(
                        for: currentGame.compatibilityProfileName,
                        runtimePolicy: runtimePolicy(for: currentGame)
                    ),
                    status: .waitingForJIT,
                    detail: queuedDetail,
                    requestedAt: now,
                    lastUpdatedAt: now
                )
                let launchRecord = LaunchHistoryEntry(
                    id: launchEntryID,
                    gameTitle: session.title,
                    resolvedExecutablePath: session.executablePath,
                    readiness: "Waiting For JIT",
                    issueSummary: session.issues.map(\.message) + [
                        "Launch queued until JIT becomes ready."
                    ],
                    hostSessionID: nil,
                    stateHistory: ["queued", "waitingForJIT"],
                    terminalStatus: "waitingForJIT",
                    failureCode: nil,
                    failureReason: nil,
                    runtimeBundleVersion: hostCapabilities.selectedRuntimeBundle?.version,
                    telemetrySummary: nil,
                    launchedAt: now
                )
                await store.queueLaunchWaitingForJIT(pendingLaunch, launchEntry: launchRecord)
                activityStatusMessage =
                    "Queued direct launch for \(currentGame.title). Enable JIT externally and Iridium will resume it automatically."
                await refresh()
                return
            }

            if session.readiness != .ready, canPrepareRuntimePlayer(for: currentGame, session: session)
            {
                launchTimer.mark("runtimePlayerPrepareStarting")
                switch await prepareRuntimePlayerReservation(for: currentGame) {
                case .success(let reservation):
                    preparedPlayerReservation = reservation
                    effectiveSession = launchSession(for: currentGame)
                    effectiveReport = readinessReport(for: currentGame)
                    launchTimer.mark(
                        "runtimePlayerPrepareSucceeded",
                        detail: "session=\(reservation.sessionIdentifier)"
                    )
                case .failure(let failure):
                    launchTimer.mark("runtimePlayerPrepareFailed", detail: "code=\(failure.code.rawValue)")
                    print(
                        "[IridiumRuntime] recordLaunchPreparation: playerPrepareFailed game=\(currentGame.title) reason=\(failure.reason)"
                    )
                    activityStatusMessage =
                        "Player preparation failed for \(currentGame.title): \(failure.reason)"
                    await refresh()
                    return
                }
            }

            guard effectiveSession.readiness == .ready
                || canLaunchWithRuntimeValidationWarning(
                    session: effectiveSession,
                    report: effectiveReport
                )
            else {
                if let preparedPlayerReservation {
                    releaseRuntimePlayerReservation(
                        sessionIdentifier: preparedPlayerReservation.sessionIdentifier)
                }
                print(
                    "[IridiumRuntime] recordLaunchPreparation: blocked game=\(currentGame.title) summary=\(effectiveReport.summary)"
                )
                activityStatusMessage =
                    "Launch prep blocked for \(currentGame.title): \(effectiveReport.summary)."
                await refresh()
                return
            }

            print("[IridiumRuntime] recordLaunchPreparation: proceeding game=\(currentGame.title)")
            launchTimer.mark("launchRecordCreating")

            let launchRecord = LaunchHistoryEntry(
                gameTitle: effectiveSession.title,
                resolvedExecutablePath: effectiveSession.executablePath,
                readiness: effectiveReport.overallStatus.displayName,
                issueSummary: effectiveSession.issues.map(\.message) + [
                    preparedPlayerReservation == nil
                        ? "Runtime launch started and is awaiting a terminal host session."
                        : "Runtime launch started after arming the fullscreen player services for a live session handoff."
                ],
                terminalStatus: "started",
                runtimeBundleVersion: hostCapabilities.selectedRuntimeBundle?.version,
                launchedAt: Date()
            )
            activityStatusMessage = "Starting direct launch for \(currentGame.title)..."
            launchTimer.mark("executeLaunchStarting")
            await executeLaunch(
                game: currentGame,
                session: effectiveSession,
                launchRecord: launchRecord,
                preferredSessionIdentifier: preparedPlayerReservation?.sessionIdentifier,
                successStatusMessage:
                    preparedPlayerReservation == nil
                        ? "Launched \(currentGame.title) through the runtime backend without exposing a desktop shell."
                        : "Entered a running session for \(currentGame.title) and handed it off to the fullscreen player."
            )
            launchTimer.mark("executeLaunchReturned")
        }
    }

    private func buildLaunchSession(for game: GameRecord, jitStatus: JITStatus) -> LaunchSession {
        let resolvedPolicy = runtimePolicy(for: game)
        let effectiveGame = gameApplyingCompatibilityLaunchDefaults(
            game,
            resolvedPolicy: resolvedPolicy
        )
        return LaunchCoordinator(
            runtime: runtimeDescriptor,
            jitStatus: jitStatus,
            hostSnapshot: hostCapabilities,
            runtimePolicy: resolvedPolicy
        ).prepareLaunch(
            for: effectiveGame,
            runtimeHealth: runtimeHealth,
            filePresence: managedFilePresence(for: effectiveGame)
        )
    }

    private func launchArgumentsSummary(_ arguments: [String]) -> String {
        guard !arguments.isEmpty else {
            return "[]"
        }

        return arguments.enumerated()
            .map { index, argument in "[\(index)]=\(argument)" }
            .joined(separator: " ")
    }

    private func gameApplyingCompatibilityLaunchDefaults(
        _ game: GameRecord,
        resolvedPolicy: RuntimePolicy
    ) -> GameRecord {
        if game.rendererPreset == .metalOpenGLFallback
            || game.launchProfile.rendererPreset == .metalOpenGLFallback
            || resolvedPolicy.rendererOverride == .metalOpenGLFallback
        {
            guard !launchArgumentsContainExplicitGraphicsAPI(game.launchProfile.arguments) else {
                return game
            }

            var effectiveGame = game
            effectiveGame.launchProfile.arguments = metalOpenGLFallbackArguments(
                replacing: game.launchProfile.arguments
            )
            return effectiveGame
        }

        guard game.launchProfile.arguments.isEmpty else {
            return game
        }

        let defaultArguments: [String]
        if let compatibility = compatibilityProfile(for: game),
            !compatibility.launchArguments.isEmpty
        {
            defaultArguments = compatibility.launchArguments
        } else {
            return game
        }

        var effectiveGame = game
        effectiveGame.launchProfile.arguments = defaultArguments
        return effectiveGame
    }

    private func launchArgumentsContainExplicitGraphicsAPI(_ arguments: [String]) -> Bool {
        let explicitGraphicsArguments: Set<String> = [
            "-force-d3d9",
            "-force-d3d11",
            "-force-d3d12",
            "-force-glcore",
            "-force-gles",
            "-force-metal",
            "-force-opengl",
            "-force-vulkan",
        ]
        return arguments.contains { argument in
            explicitGraphicsArguments.contains(argument.lowercased())
        }
    }

    private func metalOpenGLFallbackArguments(replacing arguments: [String]) -> [String] {
        let extraArguments = argumentsFilteringPresentationOnlyDefaults(arguments)
        return BuiltInCompatibilityProfiles.unityOpenGLLaunchArguments + extraArguments
    }

    private func argumentsFilteringPresentationOnlyDefaults(_ arguments: [String]) -> [String] {
        let presentationOnlyArguments: Set<String> = [
            "--windowed",
            "-noborder",
            "-popupwindow",
            "-windowed",
        ]
        var filteredArguments: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let normalizedArgument = argument.lowercased()
            if presentationOnlyArguments.contains(normalizedArgument) {
                index = arguments.index(after: index)
                continue
            }

            if normalizedArgument == "-screen-fullscreen" {
                let nextIndex = arguments.index(after: index)
                index = nextIndex < arguments.endIndex ? arguments.index(after: nextIndex) : nextIndex
                continue
            }

            filteredArguments.append(argument)
            index = arguments.index(after: index)
        }

        return filteredArguments
    }

    private func canQueueLaunchAfterJIT(for game: GameRecord) -> Bool {
        guard !hostCapabilities.usesLightweightDebuggerCheck else {
            return false
        }
        let currentSession = launchSession(for: game)
        guard currentSession.readiness == .blockedByJIT else {
            return false
        }

        let resumedSession = buildLaunchSession(for: game, jitStatus: .ready)
        return resumedSession.readiness == .ready
    }

    private func configurePendingLaunchPolling() {
        pendingLaunchPollingTask?.cancel()
        pendingLaunchPollingTask = nil

        guard !pendingLaunches.isEmpty, jitStatus != .ready else {
            return
        }

        pendingLaunchPollingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self.refresh()
            }
        }
    }

    private func resumePendingLaunch(_ pendingLaunch: PendingLaunchRecord) async {
        defer {
            isResumingPendingLaunch = false
        }

        guard let currentGame = games.first(where: { $0.id == pendingLaunch.gameID }) else {
            await store.markPendingLaunchValidationFailure(
                id: pendingLaunch.id,
                failureReason: "The queued title is no longer registered in the library.",
                issueSummary: [
                    "Queued launch could not resume because the registered title is missing."
                ],
                failedAt: Date()
            )
            activityStatusMessage =
                "Queued launch could not resume because the title is no longer registered."
            await refresh()
            return
        }

        let resumedSession = buildLaunchSession(for: currentGame, jitStatus: .ready)
        guard resumedSession.readiness == .ready,
            resumedSession.executablePath == pendingLaunch.resolvedExecutablePath,
            resumedSession.workingDirectory == pendingLaunch.workingDirectory,
            resumedSession.arguments == pendingLaunch.launchArguments,
            resumedSession.environment == pendingLaunch.environment,
            hostCapabilities.selectedRuntimeBundle?.id == pendingLaunch.runtimeBundleIdentifier,
            hostCapabilities.selectedRuntimeBundle?.version == pendingLaunch.runtimeBundleVersion
        else {
            let resumedReport = LaunchEligibilityAuditor().audit(
                game: currentGame,
                session: resumedSession,
                runtimeHealth: runtimeHealth,
                storage: managedStorage,
                pipeline: nil,
                filePresence: managedFilePresence(for: currentGame),
                hostSnapshot: hostCapabilities
            )
            await store.markPendingLaunchValidationFailure(
                id: pendingLaunch.id,
                failureReason:
                    "Queued launch no longer matches the current runtime, executable, or prefix state. \(resumedReport.summary)",
                issueSummary: resumedSession.issues.map(\.message) + [
                    "Queued launch no longer satisfies the current launch requirements."
                ],
                failedAt: Date()
            )
            activityStatusMessage =
                "Queued launch for \(currentGame.title) could not resume because the launch requirements changed."
            await refresh()
            return
        }

        let resumeDetail =
            "JIT became available and Iridium resumed the queued launch automatically."
        await store.markPendingLaunchResumed(
            id: pendingLaunch.id, detail: resumeDetail, resumedAt: Date())
        let launchRecord = LaunchHistoryEntry(
            id: pendingLaunch.launchEntryID,
            gameTitle: currentGame.title,
            resolvedExecutablePath: resumedSession.executablePath,
            readiness: "Resumed After JIT",
            issueSummary: resumedSession.issues.map(\.message) + [resumeDetail],
            terminalStatus: "started",
            runtimeBundleVersion: hostCapabilities.selectedRuntimeBundle?.version
                ?? pendingLaunch.runtimeBundleVersion,
            launchedAt: Date()
        )
        await executeLaunch(
            game: currentGame,
            session: resumedSession,
            launchRecord: launchRecord,
            successStatusMessage:
                "Resumed and launched \(currentGame.title) after JIT became available."
        )
    }

    private func runtimeHostArtifactPaths(
        sessionIdentifier: String,
        workingDirectory: String
    ) -> (launchTicketPath: String, sessionLogPath: String, telemetryPath: String) {
        let hostRoot = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appending(path: ".iridium/runtime-host", directoryHint: .isDirectory)
        return (
            hostRoot.appending(path: "ticket-\(sessionIdentifier).json").path,
            hostRoot.appending(path: "session-\(sessionIdentifier).log").path,
            hostRoot.appending(path: "telemetry-\(sessionIdentifier).json").path
        )
    }

    private func prepareRuntimePlayerReservation(
        for game: GameRecord
    ) async -> Result<ReservedRuntimePlayerSession, RuntimeFailure> {
        var launchTimer = RuntimeLaunchPhaseTimer(
            operation: "prepareRuntimePlayerReservation",
            gameTitle: game.title
        )
        guard activeRuntimePlayerSession == nil, runtimePlayerReservation == nil else {
            return .failure(
                RuntimeFailure(
                    code: .runtimeBootFailed,
                    reason: "Another runtime session already owns the fullscreen player.",
                    recoverySuggestion: "Dismiss the current player session before launching another title."
                )
            )
        }

        guard let runtimeBundle = hostCapabilities.selectedRuntimeBundle else {
            return .failure(
                RuntimeFailure(
                    code: .missingRuntimeBundle,
                    reason: "No runtime bundle is selected for playable device launch.",
                    recoverySuggestion: "Validate the bundled device runtime before preparing the player."
                )
            )
        }

        guard let runtimeBundleRootPath = runtimeBundle.bundleRootPath,
            !runtimeBundleRootPath.isEmpty
        else {
            return .failure(
                RuntimeFailure(
                    code: .missingRuntimeBundle,
                    reason: "The selected runtime bundle is missing its bundle root path.",
                    recoverySuggestion: "Refresh the bundled runtime inventory before preparing the player."
                )
            )
        }

        let session = launchSession(for: game)
        let sessionIdentifier = UUID().uuidString
        let artifactPaths = runtimeHostArtifactPaths(
            sessionIdentifier: sessionIdentifier,
            workingDirectory: session.workingDirectory
        )
        let preparedSessionResult = RuntimePlayerPreparedSession.prepare(
            sessionIdentifier: sessionIdentifier,
            graphicsStack: runtimeBundle.descriptor.graphicsStack
        )
        launchTimer.mark("preparedSessionCreated", detail: "session=\(sessionIdentifier)")
        let preparedSession: RuntimePlayerPreparedSession
        switch preparedSessionResult {
        case .success(let session):
            preparedSession = session
        case .failure(let failure):
            return .failure(failure)
        }
        let userlandRootPath = RuntimeAppStagedUserlandRoot.rootPath()

        let reservation = ReservedRuntimePlayerSession(
            sessionIdentifier: sessionIdentifier,
            gameID: game.id,
            gameTitle: game.title,
            runtimeBundleID: runtimeBundle.id,
            runtimeBundleVersion: runtimeBundle.version,
            runtimeBundleRootPath: runtimeBundleRootPath,
            userlandRootPath: userlandRootPath,
            graphicsStack: runtimeBundle.descriptor.graphicsStack,
            launchTicketPath: artifactPaths.launchTicketPath,
            sessionLogPath: artifactPaths.sessionLogPath,
            telemetryPath: artifactPaths.telemetryPath
        )

        let registryReservation = RuntimePlayerReservation(
            sessionIdentifier: reservation.sessionIdentifier,
            runtimeBundleRootPath: reservation.runtimeBundleRootPath,
            userlandRootPath: userlandRootPath,
            hostLogPath: reservation.sessionLogPath,
            services: preparedSession.serviceDescriptors
        )

        switch runtimePlayerServiceRegistry.reserve(registryReservation) {
        case .success:
            for service in preparedSession.serviceDescriptors {
                switch runtimePlayerServiceRegistry.setServiceLiveness(
                    sessionIdentifier: reservation.sessionIdentifier,
                    serviceKind: service.kind,
                    isLive: true
                ) {
                case .success:
                    continue
                case .failure(let failure):
                    runtimePlayerServiceRegistry.release(sessionIdentifier: reservation.sessionIdentifier)
                    preparedSession.teardown()
                    return .failure(failure)
                }
            }

            runtimePlayerPreparedSession = preparedSession
            runtimePlayerReservation = reservation
            launchTimer.mark("servicesReserved", detail: "session=\(reservation.sessionIdentifier)")
            print(
                "[IridiumRuntime] runtimePlayer: prepared session=\(reservation.sessionIdentifier) surface=\(preparedSession.bridgeConfiguration.surfaceWidth)x\(preparedSession.bridgeConfiguration.surfaceHeight) framebuffer=\(preparedSession.bridgeConfiguration.framebufferPath)"
            )
            await refreshHostReadinessSnapshot()
            launchTimer.mark(
                "hostReadinessRefreshed",
                detail: "playabilityReady=\(hostCapabilities.playabilityReady == true)"
            )
            guard hostCapabilities.playabilityReady == true else {
                let blockedSummary = hostCapabilities.playabilityBlockingSummaries.first
                    ?? "Fullscreen player services were reserved, but the runtime host still reports blocked playability."
                releaseRuntimePlayerReservation(sessionIdentifier: reservation.sessionIdentifier)
                await refreshHostReadinessSnapshot()
                return .failure(
                    RuntimeFailure(
                        code: .runtimeBootFailed,
                        reason: blockedSummary,
                        recoverySuggestion: "Inspect host-capabilities.json and the runtime session log before retrying."
                    )
                )
            }
            return .success(reservation)
        case .failure(let failure):
            preparedSession.teardown()
            return .failure(failure)
        }
    }

    private func releaseRuntimePlayerReservation(sessionIdentifier: String? = nil) {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            guard sessionIdentifier == nil || activeRuntimePlayerSession?.sessionIdentifier == sessionIdentifier else { return }
            MadeiraRuntimeAdapter.stop()
            runtimePlayerReservation = nil
            runtimePlayerPreparedSession?.teardown()
            runtimePlayerPreparedSession = nil
            activeRuntimePlayerSession = nil
            RuntimeLogCapture.writeLine("[Launch] Game close requested. Player session released.")
            return
        }
        #endif
        let resolvedIdentifier = sessionIdentifier
            ?? activeRuntimePlayerSession?.sessionIdentifier
            ?? runtimePlayerReservation?.sessionIdentifier

        guard let resolvedIdentifier else {
            return
        }

        let reservationForSession =
            runtimePlayerReservation?.sessionIdentifier == resolvedIdentifier
            ? runtimePlayerReservation
            : nil
        let activeSessionForRelease =
            activeRuntimePlayerSession?.sessionIdentifier == resolvedIdentifier
            ? activeRuntimePlayerSession
            : nil
        let sessionLogPath = reservationForSession?.sessionLogPath
            ?? activeSessionForRelease?.sessionLogPath
        let launchTicketPath = reservationForSession?.launchTicketPath
            ?? activeSessionForRelease?.launchTicketPath

        print("[IridiumRuntime] runtimePlayer: release session=\(resolvedIdentifier)")
        runtimePlayerServiceRegistry.release(sessionIdentifier: resolvedIdentifier)
        if let sessionLogPath {
            logRuntimePlayerLogTail(
                kind: "sessionLog",
                sessionIdentifier: resolvedIdentifier,
                path: sessionLogPath
            )
        }
        if let launchTicketPath,
            let hostLogPath = bundledRuntimeHostLogPath(
                launchTicketPath: launchTicketPath,
                sessionIdentifier: resolvedIdentifier
            )
        {
            logRuntimePlayerLogTail(
                kind: "hostLog",
                sessionIdentifier: resolvedIdentifier,
                path: hostLogPath
            )
        }
        if runtimePlayerPreparedSession?.sessionIdentifier == resolvedIdentifier {
            runtimePlayerPreparedSession?.teardown()
            runtimePlayerPreparedSession = nil
        }
        if runtimePlayerReservation?.sessionIdentifier == resolvedIdentifier {
            runtimePlayerReservation = nil
        }
        if activeRuntimePlayerSession?.sessionIdentifier == resolvedIdentifier {
            activeRuntimePlayerSession = nil
        }
        if runtimePlayerVerificationContext?.execution.sessionIdentifier == resolvedIdentifier {
            runtimePlayerVerificationContext = nil
        }
        runtimePlayerFirstFrameWatchdogTask?.cancel()
        runtimePlayerFirstFrameWatchdogTask = nil
    }

    private func bundledRuntimeHostLogPath(
        launchTicketPath: String,
        sessionIdentifier: String
    ) -> String? {
        let runtimeHostDirectory = URL(fileURLWithPath: launchTicketPath).deletingLastPathComponent()
        let iridiumDirectory = runtimeHostDirectory.deletingLastPathComponent()
        let workingDirectory = iridiumDirectory.deletingLastPathComponent()
        guard iridiumDirectory.lastPathComponent == ".iridium" else {
            return nil
        }
        return workingDirectory
            .appending(path: ".iridium/runtime-backend/logs", directoryHint: .isDirectory)
            .appending(path: "runtime-host-\(sessionIdentifier).log")
            .path
    }

    private func logRuntimePlayerLogTail(
        kind: String,
        sessionIdentifier: String,
        path: String,
        maxLines: Int = 40
    ) {
        guard
            FileManager.default.fileExists(atPath: path),
            let contents = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !contents.isEmpty
        else {
            print(
                "[IridiumRuntime] runtimePlayer: \(kind) session=\(sessionIdentifier) status=absent path=\(path)"
            )
            return
        }

        print("[IridiumRuntime] runtimePlayer: \(kind) session=\(sessionIdentifier) tailStart path=\(path)")
        for line in contents.split(separator: "\n").suffix(maxLines) {
            print("[IridiumRuntime] runtimePlayerLog[\(kind)]: \(line)")
        }
        print("[IridiumRuntime] runtimePlayer: \(kind) session=\(sessionIdentifier) tailEnd")
    }

    private func promoteRuntimePlayerReservation(
        _ reservation: ReservedRuntimePlayerSession,
        execution: RuntimeSessionResult
    ) {
        activeRuntimePlayerSession = RuntimePlayerSession(
            sessionIdentifier: reservation.sessionIdentifier,
            gameID: reservation.gameID,
            gameTitle: reservation.gameTitle,
            runtimeBundleID: reservation.runtimeBundleID,
            runtimeBundleVersion: reservation.runtimeBundleVersion,
            userlandRootPath: reservation.userlandRootPath,
            graphicsStack: reservation.graphicsStack,
            launchTicketPath: execution.launchTicketPath,
            sessionLogPath: execution.sessionLogPath,
            telemetryPath: execution.telemetryPath,
            state: .running,
            stateHistory: execution.stateHistory.compactMap(RuntimeHostSessionState.init(rawValue:)),
            statusSummary: "Runtime session entered shell-free execution and is now owned by the fullscreen player.",
            launchedAt: execution.launchedAt
        )
        runtimePlayerReservation = nil
    }

    private func startRunningSessionMonitor(
        execution: RuntimeSessionResult,
        game: GameRecord,
        launchRecord: LaunchHistoryEntry,
        resolvedPolicy: RuntimePolicy
    ) {
        runningSessionMonitorTask?.cancel()
        runningSessionMonitorTask = Task { [weak self] in
            guard let self else {
                return
            }

            let terminalSession = await self.runningSessionObserver.resolveTerminalState(
                from: execution,
                gameID: game.id,
                gameTitle: game.title
            )
            await self.handleRunningSessionTerminalState(
                terminalSession,
                execution: execution,
                game: game,
                launchRecord: launchRecord,
                resolvedPolicy: resolvedPolicy
            )
        }
    }

    private func handleRunningSessionTerminalState(
        _ terminalSession: RuntimeHostSession,
        execution: RuntimeSessionResult,
        game: GameRecord,
        launchRecord: LaunchHistoryEntry,
        resolvedPolicy: RuntimePolicy
    ) async {
        guard terminalSession.state.isTerminal else {
            print(
                "[IridiumRuntime] runningSessionMonitor: ignoredNonterminal session=\(terminalSession.id) state=\(terminalSession.state.rawValue)"
            )
            return
        }

        print(
            "[IridiumRuntime] runningSessionMonitor: terminal session=\(terminalSession.id) state=\(terminalSession.state.rawValue) summary=\(terminalSession.statusSummary)"
        )

        let presentedFirstFrame = verifiedRuntimePlayerSessions.contains(terminalSession.id)
        switch terminalSession.state {
        case .completed:
            if presentedFirstFrame {
                activityStatusMessage = "Runtime session completed for \(game.title)."
                break
            }
            let reason = "Runtime process completed before the fullscreen player presented a frame."
            await store.recordRuntimeExecutionFailure(
                gameID: game.id,
                launchEntryID: launchRecord.id,
                issueSummary: failureIssueSummary(
                    for: RuntimeFailure(
                        code: .gameProcessExited,
                        reason: reason,
                        hostSessionIdentifier: terminalSession.id,
                        terminalStatus: terminalSession.state.rawValue,
                        runtimeBundleID: execution.runtimeBundleID,
                        runtimeBundleVersion: execution.runtimeBundleVersion,
                        stateHistory: terminalSession.stateHistory.map(\.rawValue),
                        launchedAt: execution.launchedAt
                    )
                ),
                hostSessionID: terminalSession.id,
                stateHistory: terminalSession.stateHistory.map(\.rawValue),
                terminalStatus: terminalSession.state.rawValue,
                failureCode: RuntimeFailureCode.gameProcessExited.rawValue,
                failureReason: reason,
                runtimeBundleIdentifier: execution.runtimeBundleID,
                runtimeBundleVersion: execution.runtimeBundleVersion,
                evidenceSummary: titleOverrideResolver.evidenceSummary(for: game),
                resolvedPolicySummary: policySummary(
                    for: game.compatibilityProfileName,
                    runtimePolicy: resolvedPolicy
                ),
                launchedAt: execution.launchedAt
            )
            activityStatusMessage = "Runtime session ended before the first frame for \(game.title)."
        case .failed:
            await store.recordRuntimeExecutionFailure(
                gameID: game.id,
                launchEntryID: launchRecord.id,
                issueSummary: failureIssueSummary(
                    for: RuntimeFailure(
                        code: terminalSession.failureCode ?? .gameProcessExited,
                        reason: terminalSession.failureReason ?? terminalSession.statusSummary,
                        hostSessionIdentifier: terminalSession.id,
                        terminalStatus: terminalSession.state.rawValue,
                        runtimeBundleID: execution.runtimeBundleID,
                        runtimeBundleVersion: execution.runtimeBundleVersion,
                        stateHistory: terminalSession.stateHistory.map(\.rawValue),
                        launchedAt: execution.launchedAt
                    )
                ),
                hostSessionID: terminalSession.id,
                stateHistory: terminalSession.stateHistory.map(\ .rawValue),
                terminalStatus: terminalSession.state.rawValue,
                failureCode: terminalSession.failureCode?.rawValue ?? RuntimeFailureCode.gameProcessExited.rawValue,
                failureReason: terminalSession.failureReason ?? terminalSession.statusSummary,
                runtimeBundleIdentifier: execution.runtimeBundleID,
                runtimeBundleVersion: execution.runtimeBundleVersion,
                evidenceSummary: titleOverrideResolver.evidenceSummary(for: game),
                resolvedPolicySummary: policySummary(
                    for: game.compatibilityProfileName,
                    runtimePolicy: resolvedPolicy
                ),
                launchedAt: execution.launchedAt
            )
            activityStatusMessage =
                "Runtime session failed for \(game.title): \(terminalSession.failureReason ?? terminalSession.statusSummary)"
        default:
            break
        }

        await refreshRuntimeEvidenceSnapshots()
        await refreshLaunchHistorySnapshot()

        if runtimePlayerVerificationContext?.execution.sessionIdentifier == terminalSession.id {
            runtimePlayerVerificationContext = nil
        }
        verifiedRuntimePlayerSessions.remove(terminalSession.id)

        if var activeSession = activeRuntimePlayerSession,
            activeSession.sessionIdentifier == terminalSession.id
        {
            activeSession.state = terminalSession.state
            activeSession.stateHistory = terminalSession.stateHistory
            activeSession.statusSummary = terminalSession.failureReason ?? terminalSession.statusSummary
            activeRuntimePlayerSession = activeSession
            runtimePlayerFirstFrameWatchdogTask?.cancel()
            runtimePlayerFirstFrameWatchdogTask = nil
            await refreshHostReadinessSnapshot()
        } else {
            releaseRuntimePlayerReservation(sessionIdentifier: terminalSession.id)
            await refresh()
        }
    }

    private func executeLaunch(
        game: GameRecord,
        session: LaunchSession,
        launchRecord: LaunchHistoryEntry,
        preferredSessionIdentifier: String? = nil,
        successStatusMessage: String
    ) async {
        var launchTimer = RuntimeLaunchPhaseTimer(operation: "executeLaunch", gameTitle: game.title)
        var launchSession = session
        if let preferredSessionIdentifier,
            let preparedSession = runtimePlayerPreparedSession,
            preparedSession.sessionIdentifier == preferredSessionIdentifier
        {
            launchSession.environment.merge(preparedSession.launchEnvironment) { _, newValue in
                newValue
            }
        }

        print(
            "[IridiumRuntime] executeLaunch: Starting direct launch for \(game.title) executable=\(session.executablePath)"
        )
        print(
            "[IridiumRuntime] executeLaunch: arguments=\(launchArgumentsSummary(launchSession.arguments))"
        )
        await store.upsertLaunch(launchRecord)
        launchTimer.mark("launchRecordUpserted")
        await refreshLaunchHistorySnapshot()
        launchTimer.mark("launchHistoryRefreshed")

        let resolvedPolicy = runtimePolicy(for: game)
        launchTimer.mark("sessionExecutorStarting")
        let result = await sessionExecutor.execute(
            RuntimeSessionRequest(
                game: game,
                prefix: prefixes.first(where: { $0.id == game.launchProfile.prefixID }),
                session: launchSession,
                hostSnapshot: hostCapabilities,
                runtimeBundle: hostCapabilities.selectedRuntimeBundle,
                policy: resolvedPolicy,
                preferredSessionIdentifier: preferredSessionIdentifier
            )
        )
        launchTimer.mark("sessionExecutorReturned")

        switch result {
        case .success(let execution):
            let enteredRunningSession = execution.terminalStatus == RuntimeHostSessionState.running.rawValue
            let sessionStatusSummary =
                "Native runtime host session \(execution.sessionIdentifier) reported \(execution.terminalStatus)."
            if enteredRunningSession,
                let reservation = runtimePlayerReservation,
                reservation.sessionIdentifier == execution.sessionIdentifier
            {
                let issueSummary = session.issues.map(\.message) + [
                    sessionStatusSummary,
                    "Runtime session handed off to the fullscreen player; awaiting its first guest frame.",
                    "State history: \(execution.stateHistory.joined(separator: " -> ")).",
                ]
                print(
                    "[IridiumRuntime] executeLaunch: Session started for \(game.title) session=\(execution.sessionIdentifier) status=\(execution.terminalStatus) awaitingFirstFrame=true"
                )
                await store.recordRuntimeExecutionStarted(
                    gameID: game.id,
                    launchEntryID: launchRecord.id,
                    resolvedExecutablePath: execution.resolvedExecutablePath,
                    issueSummary: issueSummary,
                    hostSessionID: execution.sessionIdentifier,
                    stateHistory: execution.stateHistory,
                    runtimeBundleVersion: execution.runtimeBundleVersion,
                    launchedAt: execution.launchedAt
                )
                await refreshLaunchHistorySnapshot()
                runtimePlayerVerificationContext = RuntimePlayerVerificationContext(
                    execution: execution,
                    game: game,
                    launchRecord: launchRecord,
                    resolvedPolicy: resolvedPolicy,
                    issueSummary: issueSummary,
                    successStatusMessage: successStatusMessage + " First guest frame presented."
                )
                launchTimer.mark(
                    "executionStartedRecorded",
                    detail: "session=\(execution.sessionIdentifier) awaitingFirstFrame=true"
                )
                promoteRuntimePlayerReservation(reservation, execution: execution)
                startRuntimePlayerFirstFrameWatchdog(
                    reservation: reservation,
                    execution: execution,
                    game: game,
                    launchRecord: launchRecord,
                    resolvedPolicy: resolvedPolicy
                )
                startRunningSessionMonitor(
                    execution: execution,
                    game: game,
                    launchRecord: launchRecord,
                    resolvedPolicy: resolvedPolicy
                )
                activityStatusMessage = "Runtime session started for \(game.title). Waiting for the first frame."
            } else {
                let reason =
                    "Runtime process reported \(execution.terminalStatus) before the fullscreen player presented a frame."
                print(
                    "[IridiumRuntime] executeLaunch: Launch rejected for \(game.title) session=\(execution.sessionIdentifier) code=\(RuntimeFailureCode.gameProcessExited.rawValue) reason=\"\(reason)\""
                )
                releaseRuntimePlayerReservation(sessionIdentifier: preferredSessionIdentifier)
                await store.recordRuntimeExecutionFailure(
                    gameID: game.id,
                    launchEntryID: launchRecord.id,
                    issueSummary: session.issues.map(\.message) + [sessionStatusSummary, reason],
                    hostSessionID: execution.sessionIdentifier,
                    stateHistory: execution.stateHistory,
                    terminalStatus: execution.terminalStatus,
                    failureCode: RuntimeFailureCode.gameProcessExited.rawValue,
                    failureReason: reason,
                    runtimeBundleIdentifier: execution.runtimeBundleID,
                    runtimeBundleVersion: execution.runtimeBundleVersion,
                    evidenceSummary: titleOverrideResolver.evidenceSummary(for: game),
                    resolvedPolicySummary: policySummary(
                        for: game.compatibilityProfileName, runtimePolicy: resolvedPolicy),
                    launchedAt: execution.launchedAt
                )
                launchTimer.mark("executionFailureRecorded", detail: "completedBeforeFirstFrame")
                activityStatusMessage = "Direct launch failed for \(game.title): \(reason)"
            }
        case .failure(let failure):
            print(
                "[IridiumRuntime] executeLaunch: Launch failed for \(game.title) code=\(failure.code.rawValue) reason=\(failure.reason)"
            )
            releaseRuntimePlayerReservation(sessionIdentifier: preferredSessionIdentifier)
            await store.recordRuntimeExecutionFailure(
                gameID: game.id,
                launchEntryID: launchRecord.id,
                issueSummary: session.issues.map(\.message) + failureIssueSummary(for: failure),
                hostSessionID: failure.hostSessionIdentifier,
                stateHistory: failure.stateHistory,
                terminalStatus: failure.terminalStatus,
                failureCode: failure.code.rawValue,
                failureReason: failure.reason,
                runtimeBundleIdentifier: failure.runtimeBundleID
                    ?? hostCapabilities.selectedRuntimeBundle?.id,
                runtimeBundleVersion: failure.runtimeBundleVersion
                    ?? hostCapabilities.selectedRuntimeBundle?.version,
                evidenceSummary: titleOverrideResolver.evidenceSummary(for: game),
                resolvedPolicySummary: policySummary(
                    for: game.compatibilityProfileName, runtimePolicy: resolvedPolicy),
                launchedAt: failure.launchedAt ?? launchRecord.launchedAt
            )
            launchTimer.mark(
                "executionFailureRecorded",
                detail: "code=\(failure.code.rawValue)"
            )
            activityStatusMessage = "Direct launch failed for \(game.title): \(failure.reason)"
        }

        if activeRuntimePlayerSession != nil {
            launchTimer.mark("postLaunchHostReadinessSkippedForActivePlayer")
        } else {
            await refresh()
            launchTimer.mark("postLaunchFullRefreshCompleted")
        }
    }

    private func startRuntimePlayerFirstFrameWatchdog(
        reservation: ReservedRuntimePlayerSession,
        execution: RuntimeSessionResult,
        game: GameRecord,
        launchRecord: LaunchHistoryEntry,
        resolvedPolicy: RuntimePolicy
    ) {
        guard let timeout = runtimePlayerFirstFrameTimeoutNanoseconds,
            timeout > 0,
            let bridgeConfiguration = runtimePlayerPreparedSession?.bridgeConfiguration,
            bridgeConfiguration.sessionIdentifier == reservation.sessionIdentifier
        else {
            return
        }

        runtimePlayerFirstFrameWatchdogTask?.cancel()
        runtimePlayerFirstFrameWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else {
                return
            }

            await self?.handleRuntimePlayerFirstFrameTimeout(
                sessionIdentifier: reservation.sessionIdentifier,
                framebufferPath: bridgeConfiguration.framebufferPath,
                execution: execution,
                game: game,
                launchRecord: launchRecord,
                resolvedPolicy: resolvedPolicy
            )
        }
    }

    private func handleRuntimePlayerFirstFrameTimeout(
        sessionIdentifier: String,
        framebufferPath: String,
        execution: RuntimeSessionResult,
        game: GameRecord,
        launchRecord: LaunchHistoryEntry,
        resolvedPolicy: RuntimePolicy
    ) async {
        guard
            activeRuntimePlayerSession?.sessionIdentifier == sessionIdentifier,
            runtimePlayerVerificationContext?.execution.sessionIdentifier == sessionIdentifier,
            !verifiedRuntimePlayerSessions.contains(sessionIdentifier)
        else {
            return
        }

        let rendererName = (resolvedPolicy.rendererOverride ?? game.rendererPreset).rawValue
        let reason =
            "Runtime reached shell-free execution, but no guest frame was presented through the \(execution.runtimeBundleVersion) \(rendererName) graphics path."
        print(
            "[IridiumRuntime] runtimePlayer: firstFrameTimeout session=\(sessionIdentifier) framebuffer=\(framebufferPath) reason=\"\(reason)\""
        )
        runtimePlayerPreparedSession?.logDiagnostics(reason: "firstFrameTimeout")
        activityStatusMessage =
            "Still waiting for the first frame for \(game.title): \(reason)"
        if var activeSession = activeRuntimePlayerSession,
            activeSession.sessionIdentifier == sessionIdentifier
        {
            activeSession.statusSummary =
                "Still waiting for the first guest frame; the runtime session remains active."
            activeRuntimePlayerSession = activeSession
        }
        print(
            "[IridiumRuntime] runtimePlayer: firstFrameTimeoutContinue session=\(sessionIdentifier)"
        )
        runtimePlayerFirstFrameWatchdogTask = nil
    }

    func verifyGameRegistration(_ game: GameRecord) {
        Task {
            _ = await store.verify(gameID: game.id)
            await refresh()
            guard let refreshedGame = games.first(where: { $0.id == game.id }) else {
                return
            }
            let report = readinessReport(for: refreshedGame)
            await store.recordVerificationAudit(makeAuditEntry(for: refreshedGame, report: report))
            activityStatusMessage =
                "Recorded \(report.overallStatus.displayName.lowercased()) audit for \(refreshedGame.title)."
            await refresh()
        }
    }

    var usesMadeiraRuntime: Bool {
        #if MADEIRA_RUNTIME
        return MadeiraRuntimeAdapter.enabled
        #else
        return false
        #endif
    }

    var activeRuntimeHealth: RuntimeHealthReport {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            return RuntimeHealthReport(
                status: madeiraRuntimeAvailable ? .healthy : .actionRequired,
                runtimeName: "Madeira", runtimeBundleIdentifier: "madeira-experimental",
                notes: [madeiraRuntimeAvailable
                    ? "Bundled runtime available. Each game is checked when you launch it."
                    : "The bundled runtime is incomplete. Reinstall Iridium."]
            )
        }
        #endif
        return runtimeHealth
    }

    func readinessReport(for game: GameRecord) -> TitleReadinessReport {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            if activeRuntimePlayerSession?.gameID == game.id {
                return TitleReadinessReport(title: game.title, overallStatus: .ready, checks: [
                    VerificationCheck(title: "Player", detail: activeRuntimePlayerSession?.statusSummary ?? "Game session open.", status: .ready)
                ])
            }
            let issue = madeiraLaunchIssue(for: game)
            let status: VerificationGateStatus = issue == nil ? .ready : .blocked
            return TitleReadinessReport(title: game.title, overallStatus: status, checks: [
                VerificationCheck(title: "Launch", detail: issue ?? "Ready to launch. JIT will be requested through LiveContainer2 if needed.", status: status)
            ])
        }
        #endif
        return LaunchEligibilityAuditor().audit(
            game: game,
            session: launchSession(for: game),
            runtimeHealth: runtimeHealth,
            storage: managedStorage,
            pipeline: nil,
            filePresence: managedFilePresence(for: game),
            hostSnapshot: hostCapabilities
        )
    }

    func auditHistory(for game: GameRecord) -> [VerificationAuditEntry] {
        verificationAudits
            .filter { $0.gameID == game.id }
            .sorted { $0.verifiedAt > $1.verifiedAt }
    }

    func runtimePolicy(for game: GameRecord) -> RuntimePolicy {
        runtimePolicyResolver.resolve(
            game: game,
            hostSnapshot: hostCapabilities,
            runtimeBundle: hostCapabilities.selectedRuntimeBundle,
            basePolicy: BuiltInCompatibilityProfiles.runtimePolicy(
                forTitle: game.title, deviceTier: game.deviceTier),
            overrideResolver: titleOverrideResolver
        )
    }

    func lastAudit(for game: GameRecord) -> VerificationAuditEntry? {
        auditHistory(for: game).first
    }

    func presentationStatus(for game: GameRecord) -> GamePresentationStatus? {
        if let activeRuntimePlayerSession, activeRuntimePlayerSession.gameID == game.id {
            return GamePresentationStatus(
                title: "Player Open",
                summary: activeRuntimePlayerSession.statusSummary,
                tone: .ready
            )
        }

        if pendingLaunch(for: game) != nil {
            return GamePresentationStatus(
                title: "Queued For JIT",
                summary:
                    "Iridium saved this launch request and will resume it automatically once JIT becomes available.",
                tone: .warning
            )
        }

        let filePresence = managedFilePresence(for: game)
        if filePresence.installRootExists && filePresence.executableExists {
            return playabilityPresentationStatus()
        }

        return GamePresentationStatus(
            title: "Missing Files",
            summary:
                "This title is registered, but its imported game folder or launch target is missing from disk.",
            tone: .blocked
        )
    }

    private func canPrepareRuntimePlayer(for game: GameRecord, session: LaunchSession? = nil) -> Bool {
        guard activeRuntimePlayerSession == nil, runtimePlayerReservation == nil else {
            return false
        }
        guard jitStatus == .ready,
            !hostCapabilities.usesLightweightDebuggerCheck,
            hostCapabilities.launchReady == true,
            hostCapabilities.playabilityReady == false,
            hostCapabilities.executionEnvironment == .nativeRuntime,
            hostCapabilities.selectedRuntimeBundle != nil,
            !hostCapabilities.playabilityBlockingSummaries.isEmpty
        else {
            return false
        }

        return (session ?? launchSession(for: game)).readiness == .needsRuntimeValidation
    }

    private func canLaunchWithRuntimeValidationWarning(
        session: LaunchSession,
        report: TitleReadinessReport
    ) -> Bool {
        guard session.readiness == .needsRuntimeValidation,
            report.overallStatus != .blocked,
            hostCapabilities.playabilityReady != false
        else {
            return false
        }

        return !session.issues.contains { $0.severity == .blocking }
    }

    var readinessDashboard: ReadinessDashboard {
        let statuses = games.map { game -> (GameRecord, VerificationGateStatus, String, Date) in
            if pendingLaunch(for: game) != nil {
                return (
                    game, .warning,
                    "Queued for JIT. Iridium will resume this launch automatically once JIT becomes available.",
                    Date()
                )
            }

            if let audit = lastAudit(for: game) {
                let status: VerificationGateStatus
                switch audit.overallStatus {
                case .ready:
                    status = .ready
                case .warning:
                    status = .warning
                case .blocked:
                    status = .blocked
                }
                return (game, status, audit.summary, audit.verifiedAt)
            }

            let report = readinessReport(for: game)
            return (game, report.overallStatus, report.summary, Date())
        }

        let latestBlocked =
            statuses
            .compactMap { game, status, summary, recordedAt -> (Date, String, String)? in
                guard status == .blocked else {
                    return nil
                }
                return (recordedAt, game.title, summary)
            }
            .sorted { $0.0 > $1.0 }
            .first

        return ReadinessDashboard(
            readyCount: statuses.filter { $0.1 == VerificationGateStatus.ready }.count,
            warningCount: statuses.filter { $0.1 == VerificationGateStatus.warning }.count,
            blockedCount: statuses.filter { $0.1 == VerificationGateStatus.blocked }.count,
            latestBlockedTitle: latestBlocked?.1,
            latestBlockedSummary: latestBlocked?.2
        )
    }

    var runtimeSubsystemStatuses: [RuntimeSubsystemStatus] {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled { return [] }
        #endif
        let subsystemReadiness: [(String, RuntimeSubsystemReadiness?, String, String)] = [
            (
                "Presentation",
                hostCapabilities.presentationReadiness,
                "Guest windows can present inside the app.",
                "Runtime host does not provide an iOS presentation service for guest windows yet."
            ),
            (
                "Input",
                hostCapabilities.inputReadiness,
                "Guest keyboard, pointer, and controller input can reach the runtime.",
                "Runtime host does not provide an iOS input bridge for guest events yet."
            ),
            (
                "Audio",
                hostCapabilities.audioReadiness,
                "Guest audio output can reach the device speaker path.",
                "Runtime host does not provide an iOS audio bridge for guest output yet."
            ),
        ]

        guard
            hostCapabilities.launchReady == true
                || subsystemReadiness.contains(where: { $0.1 != nil })
        else {
            return []
        }

        return subsystemReadiness.map { title, readiness, readySummary, blockedSummary in
            runtimeSubsystemStatus(
                title: title,
                readiness: readiness,
                readySummary: readySummary,
                blockedSummary: blockedSummary
            )
        }
    }

    var runtimeConstraintNotes: [String] {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            return ["Restart Iridium between game sessions.", "Game compatibility, audio, and input require testing for each title."]
        }
        #endif
        let subsystemSummaries = Set(hostCapabilities.playabilityBlockingSummaries)
        guard !subsystemSummaries.isEmpty else {
            return hostCapabilities.constraints
        }

        return hostCapabilities.constraints.filter { !subsystemSummaries.contains($0) }
    }


    private func resolvedImportTitle(for scan: ImportScanResult, preferredTitle: String?) -> String
    {
        if let preferredTitle, !preferredTitle.isEmpty {
            return preferredTitle
        }

        let folder = URL(fileURLWithPath: scan.installPath).lastPathComponent
        if !folder.isEmpty { return folder }
        return scan.recommendedExecutable.map {
            URL(fileURLWithPath: $0.filename).deletingPathExtension().lastPathComponent
        } ?? "Imported Game"
    }

    private func managedFilePresence(for game: GameRecord) -> ManagedFilePresence {
        let executablePath: String
        if game.launchProfile.executablePath.isEmpty {
            executablePath = ""
        } else if game.launchProfile.executablePath.hasPrefix("/") {
            executablePath = game.launchProfile.executablePath
        } else {
            executablePath =
                URL(fileURLWithPath: game.installPath, isDirectory: true)
                .appending(path: game.launchProfile.executablePath)
                .path
        }

        return ManagedFilePresence(
            installRootExists: FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: game.installPath).standardizedFileURL.path),
            executableExists: !executablePath.isEmpty
                && FileManager.default.fileExists(
                    atPath: URL(fileURLWithPath: executablePath).standardizedFileURL.path)
        )
    }

    private func buildOnboardingChecks() -> [OnboardingCheck] {
        [
            OnboardingCheck(
                title: "JIT availability",
                detail: {
                    if hostCapabilities.launchStatus == "xcodeDebugCheckOnly" {
                        return
                            "Debugger-backed JIT was detected under Xcode, but Iridium intentionally skipped embedded runtime validation. Direct launch remains blocked in this lightweight check mode."
                    }

                    if jitStatus == .ready, hostCapabilities.launchReady == true {
                        return pendingLaunches.isEmpty
                            ? "Translation is enabled. Imported Windows games can launch when the other runtime checks pass."
                            : "Translation is enabled and Iridium is resuming queued launches automatically."
                    }

                    if jitStatus == .ready {
                        return
                            "Debugger-backed JIT was detected for development checks, but direct launch remains blocked until the embedded runtime backend is validated outside the lightweight Xcode check path."
                    }

                    if pendingLaunches.isEmpty {
                        return
                            "Iridium can import and manage games now, but launching stays disabled until JIT is enabled externally."
                    }

                    return
                        "\(pendingLaunches.count) queued launch\(pendingLaunches.count == 1 ? "" : "es") will resume automatically once JIT becomes available."
                }(),
                state: (jitStatus == .ready && hostCapabilities.launchReady == true)
                    ? .ready
                    : .warning
            ),
            OnboardingCheck(
                title: "Runtime backend",
                detail: runtimeBackendDetail(),
                state: runtimeBackendState()
            ),
            OnboardingCheck(
                title: "Runtime health",
                detail: primaryRuntimeHealthDetail(
                    for: runtimeHealth, hostSnapshot: hostCapabilities),
                state: {
                    switch runtimeHealth.status {
                    case .healthy:
                        .ready
                    case .degraded:
                        .warning
                    case .actionRequired:
                        .actionRequired
                    }
                }()
            ),
            OnboardingCheck(
                title: "Manual import",
                detail: games.isEmpty
                    ? "The app starts empty. Import a Windows game folder to register the first title."
                    : "\(games.count) imported titles and \(prefixes.count) prefixes are registered.",
                state: games.isEmpty ? .warning : .ready
            ),
            OnboardingCheck(
                title: "Managed storage",
                detail:
                    "\(managedStorage.availableInstallHeadroomGB.formatted(.number.precision(.fractionLength(0)))) GB headroom remains for imported titles and prefixes.",
                state: {
                    switch managedStorage.pressure {
                    case .healthy:
                        .ready
                    case .warning:
                        .warning
                    case .critical:
                        .actionRequired
                    }
                }()
            ),
        ]
    }

    private func runtimeBackendState() -> OnboardingCheckState {
        switch hostCapabilities.executionEnvironment {
        case .nativeRuntime:
            return .ready
        case .macOSDevelopmentFallback, .simulatorDevelopmentFallback:
            return .warning
        case .unavailable:
            return .actionRequired
        }
    }

    private func runtimeBackendDetail() -> String {
        switch hostCapabilities.backendMode {
        case .bundledDevice:
            return "Bundled on-device runtime backend is selected for direct launch."
        case .providerBacked:
            return "Provider-backed runtime backend override is active for internal testing."
        case .development:
            return "Development runtime backend is active for simulator or internal fallback flows."
        }
    }

    private func refreshJITEnablementState() {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled {
            if jit_check_debugged() && StikJITHelper.persistentScriptRequested {
                jitStatus = .ready
                jitEnablementState = .ready
            } else {
                jitStatus = .required
                jitEnablementState = .toolLaunchAvailable
            }
            return
        }
        #endif
        #if os(iOS)
            if hostCapabilities.launchStatus == "xcodeDebugCheckOnly" {
                pendingExternalJITProvider = nil
                jitEnablementState = .notDetected
                return
            }

            if jitStatus == .ready {
                jitEnablementState = .ready
                pendingExternalJITProvider = nil
                return
            }

            if pendingExternalJITProvider != nil {
                jitEnablementState = .waitingForExternalEnablement
                return
            }

            if recommendedExternalJITProvider() != nil {
                jitEnablementState = jitStatus == .unavailable
                    ? .backendUnavailable
                    : .toolLaunchAvailable
                return
            }

            jitEnablementState = jitStatus == .unavailable ? .backendUnavailable : .notDetected
        #else
            jitEnablementState = jitStatus == .ready ? .ready : .notDetected
        #endif
    }

    #if os(iOS)
        private func recommendedExternalJITProvider(
            installedSchemes: Set<String>? = nil,
            bundleInfo: ExternalJITBundleInfo? = nil
        ) -> ExternalJITProvider? {
            let probeResults = installedSchemes.map { schemes in
                ExternalJITProviderResolver.probedSchemes.map { scheme in
                    (scheme: scheme, available: schemes.contains(scheme))
                }
            } ?? externalJITSchemeProbeResults()

            return ExternalJITProviderResolver.recommendedProvider(
                for: hostCapabilities,
                bundleInfo: bundleInfo ?? externalJITBundleInfo(),
                jitStreamerAddress: jitStreamerAddress,
                installedSchemes: installedSchemes
                    ?? ExternalJITProviderResolver.installedSchemes(from: probeResults)
            )
        }
    #else
        private func recommendedExternalJITProvider(
            installedSchemes: Set<String>? = nil,
            bundleInfo: ExternalJITBundleInfo? = nil
        ) -> ExternalJITProvider? {
            _ = installedSchemes
            _ = bundleInfo
            return nil
        }
    #endif

    #if os(iOS)
        private func requestExternalJITEnablement(
            provider: ExternalJITProvider,
            bundleInfo: ExternalJITBundleInfo,
            installedSchemes: Set<String>,
            normalizedJitStreamerAddress: String?
        ) async {
            setenv(RuntimeEnvironmentKey.activeJITProvider, provider.runtimeIdentifier, 1)
            do {
                switch provider {
                case .altJIT:
                    print("[IridiumRuntime] jit-provider: requesting_altjit")
                    try await requestAltJIT()
                case .jitStreamer:
                    guard let normalizedJitStreamerAddress else {
                        throw ExternalJITRequestError.missingJitStreamerAddress
                    }
                    print(
                        "[IridiumRuntime] jit-provider: requesting_jitstreamer address=\(normalizedJitStreamerAddress)"
                    )
                    try await requestJitStreamer(normalizedJitStreamerAddress, getpid())
                case .stikDebug, .sideStore, .trollStore:
                    guard let bundleIdentifier = bundleInfo.bundleIdentifier else {
                        throw ExternalJITRequestError.missingBundleIdentifier
                    }
                    let bootstrapAssets = JITBootstrapAssetBundle.recommended(
                        kind: hostCapabilities.jitToolBootstrapKind,
                        recommendation: hostCapabilities.jitToolRecommendation
                    )
                    let launchURL: URL?
                    if provider == .stikDebug {
                        let resolvedBootstrapAssets =
                            bootstrapAssets
                            ?? JITBootstrapAssetBundle.recommended(
                                kind: "stikdebug-script",
                                recommendation: .stikDebug
                            )
                        launchURL = JITHelperLaunchURLFactory.launchURL(
                            tool: .stikDebug,
                            bundleIdentifier: bundleIdentifier,
                            processIdentifier: getpid(),
                            installedSchemes: installedSchemes,
                            bootstrapAssets: resolvedBootstrapAssets
                        )
                        print(
                            "[IridiumRuntime] jit-provider: stikdebug bootstrap_kind=\(resolvedBootstrapAssets?.kind ?? "none") script_name=\(resolvedBootstrapAssets?.baseScript.name ?? "none")"
                        )
                    } else {
                        launchURL = ExternalJITProviderResolver.launchURL(
                            for: provider,
                            bundleIdentifier: bundleIdentifier,
                            processIdentifier: getpid(),
                            installedSchemes: installedSchemes
                        )
                    }
                    guard let launchURL else {
                        throw ExternalJITRequestError.failedToOpen(provider)
                    }
                    print("[IridiumRuntime] jit-provider: launch_url=\(launchURL.absoluteString)")
                    let opened = await openExternalJITURL(launchURL)
                    print(
                        "[IridiumRuntime] jit-provider: open_complete provider=\(provider.displayName) opened=\(opened)"
                    )
                    guard opened else {
                        throw ExternalJITRequestError.failedToOpen(provider)
                    }
                }

                await pollForExternalJITReadiness(after: provider)
            } catch {
                print(
                    "[IridiumRuntime] jit-provider: request_failed provider=\(provider.displayName) error=\(error.localizedDescription)"
                )
                pendingExternalJITProvider = nil
                unsetenv(RuntimeEnvironmentKey.activeJITProvider)
                refreshJITEnablementState()
                lastJITCheckSummary = error.localizedDescription
            }
        }

        private func pollForExternalJITReadiness(after provider: ExternalJITProvider) async {
            lastJITCheckSummary = provider.waitingForReadinessSummary

            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if Task.isCancelled {
                    return
                }
                await refreshHostReadinessSnapshot()
                if jitStatus == .ready, hostCapabilities.launchReady == true,
                    !hostCapabilities.usesLightweightDebuggerCheck
                {
                    pendingExternalJITProvider = nil
                    lastJITCheckSummary =
                        "JIT attached through \(provider.displayName); the embedded bootstrap is ready. Launch a game to verify Wine startup and first frame."
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            pendingExternalJITProvider = nil
            refreshJITEnablementState()
            lastJITCheckSummary = provider.timeoutSummary
        }

        private nonisolated static func requestJitStreamer(
            normalizedAddress: String,
            processIdentifier: pid_t
        ) async throws {
            let normalized = ExternalJITProviderResolver.normalizedJitStreamerAddress(
                normalizedAddress
            ) ?? normalizedAddress
            let urlString = "\(normalized)/attach/\(processIdentifier)/"
            guard let url = URL(string: urlString) else {
                throw ExternalJITRequestError.invalidJitStreamerAddress(normalizedAddress)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data()

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let response = try JSONDecoder().decode(JitStreamerAttachResponse.self, from: data)
                guard response.success else {
                    throw ExternalJITRequestError.jitStreamerRejected(response.message)
                }
            } catch let error as ExternalJITRequestError {
                throw error
            } catch is DecodingError {
                throw ExternalJITRequestError.jitStreamerNetworkFailure(
                    "Failed to decode the JitStreamer response."
                )
            } catch {
                throw ExternalJITRequestError.jitStreamerNetworkFailure(error.localizedDescription)
            }
        }

        private nonisolated static func requestAltJIT() async throws {
            #if canImport(AltKit)
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.main.async {
                        ServerManager.shared.autoconnect { result in
                            switch result {
                            case .failure(let error):
                                ServerManager.shared.stopDiscovering()
                                continuation.resume(throwing: error)
                            case .success(let connection):
                                connection.enableUnsignedCodeExecution { result in
                                    switch result {
                                    case .failure(let error):
                                        continuation.resume(throwing: error)
                                    case .success:
                                        continuation.resume(returning: ())
                                    }
                                    connection.disconnect()
                                    ServerManager.shared.stopDiscovering()
                                }
                            }
                        }
                        ServerManager.shared.startDiscovering()
                    }
                }
            #else
                throw ExternalJITRequestError.altJITUnavailable
            #endif
        }
    #endif

    func checkedJITSummary(at checkedAt: String, status: JITStatus) -> String {
        if hostCapabilities.launchStatus == "xcodeDebugCheckOnly" {
            return
                "Checked at \(checkedAt). Debugger-backed JIT was detected under Xcode, but Iridium intentionally skipped embedded runtime validation. Direct launch stays blocked in this check mode."
        }

        switch status {
        case .ready:
            if hostCapabilities.launchReady != true {
                return
                    "Checked at \(checkedAt). JIT is attached, but the embedded launch bootstrap is unavailable: \(hostCapabilities.launchStatusSummary ?? "no launch-ready backend was reported")."
            }
            if hostCapabilities.runtimeMilestones?.fullyVerified == true {
                return "Checked at \(checkedAt). Runtime verified through Wine startup and first frame."
            }
            return
                "Checked at \(checkedAt). JIT is attached and the embedded bootstrap is ready; launch a game to verify Wine startup and first frame."
        case .required:
            if let summary = liveContainerJITSetupSummary() {
                return "Checked at \(checkedAt). \(summary)"
            }
            if let summary = helperOpenedWithoutAttachSummary(checkedAt: checkedAt) {
                return summary
            }
            if let toolName = recommendedJITToolDisplayName {
                return
                    "Checked at \(checkedAt). No external debugger/JIT session detected. Open \(toolName) or enable JIT externally, then retry."
            }
            #if os(iOS)
                if JITPlatformCompatibility.requiresPersistentDebuggerCallback {
                    return
                        "Checked at \(checkedAt). This device requires StikDebug 3.1.6 or newer with Iridium's persistent TXM callback."
                }
            #endif
            return
                "Checked at \(checkedAt). No external debugger/JIT session detected. Request JIT through AltJIT, JitStreamer, SideStore, or a private-JIT path, then retry."
        case .unavailable:
            if let summary = liveContainerJITSetupSummary() {
                return "Checked at \(checkedAt). \(summary)"
            }
            if let summary = helperBootstrapIncompleteSummary(checkedAt: checkedAt) {
                return summary
            }
            let detail =
                hostCapabilities.jitSummary
                ?? hostCapabilities.launchStatusSummary
                ?? "Iridium still did not observe runtime readiness after JIT enablement."
            return "Checked at \(checkedAt). \(detail)"
        }
    }

    private func helperOpenedWithoutAttachSummary(checkedAt: String? = nil) -> String? {
        guard let provider = pendingExternalJITProvider ?? recommendedExternalJITProvider(),
            hostCapabilities.jitSessionKind == JITSessionKind.none,
            hostCapabilities.jitFailureStage == "debugger signal missing"
        else {
            return nil
        }

        if let checkedAt {
            return "Checked at \(checkedAt). \(provider.attachMissingSummary)"
        }

        return provider.attachMissingSummary
    }

    private func helperBootstrapIncompleteSummary(checkedAt: String? = nil) -> String? {
        guard hostCapabilities.jitSessionKind == .debuggerBacked,
            hostCapabilities.jitFailureStage == "external bootstrap required"
                || hostCapabilities.jitFailureStage == "persistent TXM callback unavailable"
        else {
            return nil
        }

        if let summary = liveContainerJITSetupSummary() {
            if let checkedAt {
                return "Checked at \(checkedAt). \(summary)"
            }
            return summary
        }

        let detail =
            hostCapabilities.jitToolBootstrapSummary
            ?? hostCapabilities.jitSummary
            ?? hostCapabilities.launchStatusSummary
            ?? (pendingExternalJITProvider?.timeoutSummary
                ?? "JIT was requested, but Iridium still did not observe runtime readiness.")

        if let checkedAt {
            return "Checked at \(checkedAt). \(detail)"
        }

        return detail
    }

    private func liveContainerJITSetupSummary() -> String? {
        #if os(iOS)
            guard ExternalJITProviderResolver.isHostedByLiveContainer,
                JITPlatformCompatibility.requiresPersistentDebuggerCallback
            else {
                return nil
            }
            let integrationStatus = LiveContainerIntegration.currentStatus()
            if integrationStatus.jitConfigured {
                return "LiveContainer's JIT settings are configured, but this process does not have Iridium's persistent TXM callback. Fully close Iridium, then relaunch it from LiveContainer."
            }
            return "LiveContainer must launch Iridium with JIT and Iridium's persistent TXM script. Repair the LiveContainer setup below, fully close Iridium, then relaunch it from LiveContainer."
        #else
            return nil
        #endif
    }

    private func playabilityPresentationStatus() -> GamePresentationStatus? {
        #if MADEIRA_RUNTIME
        if MadeiraRuntimeAdapter.enabled { return nil }
        #endif
        guard hostCapabilities.launchReady == true,
            !hostCapabilities.usesLightweightDebuggerCheck,
            hostCapabilities.playabilityReady == false
        else {
            return nil
        }

        let blockedSubsystems =
            runtimeSubsystemStatuses
            .filter { $0.tone == .blocked }
            .map { $0.title.lowercased() }
        let summary: String
        if blockedSubsystems.isEmpty {
            summary =
                "Embedded launch bootstrap is ready, but the runtime is not yet playable on this host."
        } else {
            summary =
                "Embedded launch bootstrap is ready, but playability is still blocked by \(naturalLanguageList(blockedSubsystems)) support."
        }

        return GamePresentationStatus(
            title: "Not Playable Yet",
            summary: summary,
            tone: .warning
        )
    }

    private func runtimeSubsystemStatus(
        title: String,
        readiness: RuntimeSubsystemReadiness?,
        readySummary: String,
        blockedSummary: String
    ) -> RuntimeSubsystemStatus {
        if readiness?.ready == true {
            return RuntimeSubsystemStatus(
                title: title,
                status: "Ready",
                summary: readiness?.statusSummary ?? readySummary,
                tone: .ready
            )
        }

        if readiness?.isBlocked == true {
            return RuntimeSubsystemStatus(
                title: title,
                status: "Blocked",
                summary: readiness?.statusSummary ?? blockedSummary,
                tone: .blocked
            )
        }

        if hostCapabilities.launchReady == false {
            return RuntimeSubsystemStatus(
                title: title,
                status: "Pending",
                summary:
                    hostCapabilities.launchStatusSummary
                    ?? "Subsystem readiness will be reported after embedded launch bootstrap becomes available.",
                tone: .warning
            )
        }

        return RuntimeSubsystemStatus(
            title: title,
            status: "Unreported",
            summary:
                readiness?.statusSummary
                ?? "Runtime host has not reported this subsystem yet.",
            tone: .warning
        )
    }

    private func naturalLanguageList(_ items: [String]) -> String {
        switch items.count {
        case 0:
            return "runtime support"
        case 1:
            return items[0]
        case 2:
            return "\(items[0]) and \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head), and \(items.last ?? "runtime")"
        }
    }

    private func makeAuditEntry(for game: GameRecord, report: TitleReadinessReport)
        -> VerificationAuditEntry
    {
        VerificationAuditEntry(
            gameID: game.id,
            gameTitle: game.title,
            overallStatus: auditStatus(from: report.overallStatus),
            summary: report.summary,
            gates: report.checks.map { check in
                VerificationAuditGate(
                    title: check.title,
                    detail: check.detail,
                    status: auditStatus(from: check.status)
                )
            },
            verifiedAt: Date()
        )
    }

    private func auditStatus(from status: VerificationGateStatus) -> VerificationAuditStatus {
        switch status {
        case .ready:
            .ready
        case .warning:
            .warning
        case .blocked:
            .blocked
        }
    }

    private func importMetadata(title: String, executablePath: String, installPath: String) -> (
        identifier: String?, fingerprint: String?
    ) {
        let artifact = try? artifactInventory.makeManagedArtifact(
            title: title,
            executablePath: executablePath,
            installPath: installPath
        )
        let fingerprint =
            artifact?.checksum
            ?? (try? artifactInventory.fingerprintExecutable(at: executablePath).value)
        return (artifact?.identifier, fingerprint)
    }

    private func resolvedImportInstallURL(for url: URL) -> URL {
        let isDirectory =
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
            ?? url.hasDirectoryPath
        return isDirectory ? url : url.deletingLastPathComponent()
    }

    private func resolvedImportTitle(for url: URL) -> String {
        let title = url.lastPathComponent
        return title.isEmpty ? "Imported Game" : title
    }

    private func validatedImportMetadata(
        title: String,
        executablePath: String,
        installPath: String
    ) -> (identifier: String, fingerprint: String)? {
        let metadata = importMetadata(
            title: title, executablePath: executablePath, installPath: installPath)
        guard let identifier = metadata.identifier,
            !identifier.isEmpty,
            let fingerprint = metadata.fingerprint,
            !fingerprint.isEmpty
        else {
            importStatusMessage =
                "Import registration is blocked until \(title) has a concrete executable target and fingerprint."
            return nil
        }

        return (identifier, fingerprint)
    }

    private func cachedImportMetadata(
        for scan: ImportScanResult,
        title: String,
        installPath: String
    ) -> [String: (identifier: String, fingerprint: String)] {
        var cache: [String: (identifier: String, fingerprint: String)] = [:]

        for executable in scan.executables {
            let metadata = importMetadata(
                title: title,
                executablePath: executable.path,
                installPath: installPath
            )
            guard let identifier = metadata.identifier,
                !identifier.isEmpty,
                let fingerprint = metadata.fingerprint,
                !fingerprint.isEmpty
            else {
                print(
                    "[IridiumRuntime] scanImportFolder: Failed to cache metadata for \(executable.path)"
                )
                continue
            }

            cache[executable.path] = (identifier, fingerprint)
        }

        return cache
    }

    private func withImportSecurityScopedAccess<T>(
        _ importSourceURL: URL?,
        reuseExistingAccess: Bool = false,
        _ operation: () -> T
    ) -> T {
        guard let importSourceURL else {
            print(
                "[IridiumRuntime] registerScannedImport: No retained source URL; running without security-scoped access"
            )
            return operation()
        }

        if reuseExistingAccess {
            print(
                "[IridiumRuntime] registerScannedImport: Reusing active security-scoped access for \(importSourceURL.path)"
            )
            return operation()
        }

        let didStartAccessing = importSourceURL.startAccessingSecurityScopedResource()
        print(
            "[IridiumRuntime] registerScannedImport: startAccessingSecurityScopedResource returned \(didStartAccessing) for \(importSourceURL.path)"
        )

        defer {
            if didStartAccessing {
                importSourceURL.stopAccessingSecurityScopedResource()
                print(
                    "[IridiumRuntime] registerScannedImport: Stopped temporary security-scoped access"
                )
            }
        }

        return operation()
    }

    private func withImportSecurityScopedAccess<T>(
        _ importSourceURL: URL?,
        reuseExistingAccess: Bool = false,
        _ operation: () async -> T
    ) async -> T {
        guard let importSourceURL else {
            print(
                "[IridiumRuntime] registerScannedImport: No retained source URL; running without security-scoped access"
            )
            return await operation()
        }

        if reuseExistingAccess {
            print(
                "[IridiumRuntime] registerScannedImport: Reusing active security-scoped access for \(importSourceURL.path)"
            )
            return await operation()
        }

        let didStartAccessing = importSourceURL.startAccessingSecurityScopedResource()
        print(
            "[IridiumRuntime] registerScannedImport: startAccessingSecurityScopedResource returned \(didStartAccessing) for \(importSourceURL.path)"
        )

        defer {
            if didStartAccessing {
                importSourceURL.stopAccessingSecurityScopedResource()
                print(
                    "[IridiumRuntime] registerScannedImport: Stopped temporary security-scoped access"
                )
            }
        }

        return await operation()
    }

    private func releaseImportSecurityScopedAccess() {
        guard let importSourceURL else {
            importSourceAccessActive = false
            return
        }

        if importSourceAccessActive {
            importSourceURL.stopAccessingSecurityScopedResource()
            print(
                "[IridiumRuntime] importAccess: Released security-scoped access for \(importSourceURL.path)"
            )
        }

        importSourceAccessActive = false
        self.importSourceURL = nil
    }

    private func defaultInputProfileName(for compatibility: CompatibilityProfile) -> String {
        if compatibility.titleFlags.contains("kbm-primary") {
            return "Controller + KBM"
        }

        if compatibility.titleFlags.contains("aaa") {
            return "Controller + Precision Touch"
        }

        return "Touch + Controller"
    }

    private func runtimePolicy(forTitle title: String, deviceTier: DeviceTier) -> RuntimePolicy {
        runtimePolicyResolver.resolve(
            game: GameRecord(
                title: title,
                source: .manualImport,
                installPath: "",
                savePathMapping: "",
                compatibilityProfileName:
                    BuiltInCompatibilityProfiles.recommendedCompatibilityProfile(forTitle: title)
                    .slug,
                inputProfileName: "Touch + Controller",
                touchOverlayName: "",
                controllerPresetName: "",
                keyboardMouseEnabled: true,
                prefixState: .clean,
                deviceTier: deviceTier,
                rendererPreset: BuiltInCompatibilityProfiles.recommendedCompatibilityProfile(
                    forTitle: title
                ).recommendedRenderer,
                launchProfile: GameLaunchProfile(
                    executablePath: "",
                    arguments: [],
                    prefixID: UUID(),
                    rendererPreset: BuiltInCompatibilityProfiles.recommendedCompatibilityProfile(
                        forTitle: title
                    ).recommendedRenderer,
                    deviceTier: deviceTier,
                    titleFlags: []
                ),
                summary: ""
            ),
            hostSnapshot: hostCapabilities,
            runtimeBundle: hostCapabilities.selectedRuntimeBundle,
            basePolicy: BuiltInCompatibilityProfiles.runtimePolicy(
                forTitle: title, deviceTier: deviceTier),
            overrideResolver: titleOverrideResolver
        )
    }

    private func policySummary(for profileName: String, runtimePolicy: RuntimePolicy) -> String {
        [
            profileName,
            runtimePolicy.memoryBudgetClass.rawValue,
            runtimePolicy.rendererOverride?.rawValue ?? "default-renderer",
            "scale=\(String(format: "%.2f", runtimePolicy.resolutionScale))",
            "cap=\(runtimePolicy.framePacingCap.map(String.init) ?? "uncapped")",
            runtimePolicy.shaderStrategy.rawValue,
        ].joined(separator: ", ")
    }

    private func telemetrySummary(_ telemetry: PerformanceTelemetrySnapshot?) -> String {
        guard let telemetry else {
            return "Telemetry unavailable from runtime backend."
        }
        return
            "fps=\(Int(telemetry.averageFPS.rounded())) p95=\(Int(telemetry.frameTimeP95MS.rounded()))ms mem=\(String(format: "%.2f", telemetry.memoryPressureRatio)) thermal=\(telemetry.thermalState.rawValue)"
    }

    private func failureIssueSummary(for failure: RuntimeFailure) -> [String] {
        var summary = ["Runtime launch failed: \(failure.reason)"]

        if let hostSessionIdentifier = failure.hostSessionIdentifier,
            let terminalStatus = failure.terminalStatus
        {
            summary.append(
                "Native runtime host session \(hostSessionIdentifier) ended with \(terminalStatus)."
            )
        } else {
            summary.append("Runtime launch failed before reaching a terminal session.")
        }

        if !failure.stateHistory.isEmpty {
            summary.append("State history: \(failure.stateHistory.joined(separator: " -> ")).")
        }

        return summary
    }

    private func importOnlyManagedStorage(
        from base: ManagedStorageStatus,
        games: [GameRecord],
        prefixes: [PrefixRecord]
    ) -> ManagedStorageStatus {
        let usedByGamesGB = games.reduce(0) { $0 + ($1.installedSizeGB ?? 0) }
        let usedByPrefixesGB = prefixes.reduce(0) { $0 + ($1.storageFootprintGB ?? 0) }
        let reservedForQueuedDownloadsGB = 0.0
        let headroom =
            base.totalCapacityGB - base.reservedForSystemGB - usedByGamesGB - usedByPrefixesGB

        let pressure: StoragePressure
        if headroom <= 16 {
            pressure = .critical
        } else if headroom <= 40 {
            pressure = .warning
        } else {
            pressure = .healthy
        }

        var notes = [
            "Managed storage reserves \(base.reservedForSystemGB.formatted(.number.precision(.fractionLength(0)))) GB for iOS, caches, and rollback buffers."
        ]
        if pressure != .healthy {
            notes.append("Large imports should be deferred until storage headroom is recovered.")
        }

        return ManagedStorageStatus(
            totalCapacityGB: base.totalCapacityGB,
            reservedForSystemGB: base.reservedForSystemGB,
            usedByGamesGB: usedByGamesGB,
            usedByPrefixesGB: usedByPrefixesGB,
            reservedForQueuedDownloadsGB: reservedForQueuedDownloadsGB,
            pressure: pressure,
            notes: notes,
            lastMeasuredAt: base.lastMeasuredAt ?? Date()
        )
    }

    private func visibleActivityEntries(
        from entries: [ActivityLogEntry],
        visibleGameTitles: Set<String>
    ) -> [ActivityLogEntry] {
        let importedTitles = Set(
            entries.compactMap { entry -> String? in
                guard entry.kind == .imported else {
                    return nil
                }
                return entry.relatedTitle
            }
        )

        return entries.filter { entry in
            switch entry.kind {
            case .runtimeValidated:
                return true
            case .imported, .prefixRepairScheduled, .prefixRebuilt, .launchQueuedForJIT,
                .launchResumed, .launchResumeFailed:
                guard let relatedTitle = entry.relatedTitle else {
                    return true
                }
                return visibleGameTitles.contains(relatedTitle)
                    || importedTitles.contains(relatedTitle)
            case .uninstalled:
                guard let relatedTitle = entry.relatedTitle else {
                    return false
                }
                return visibleGameTitles.contains(relatedTitle)
                    || importedTitles.contains(relatedTitle)
            case .steamRegistered, .stagedReset:
                return false
            }
        }
    }
}
