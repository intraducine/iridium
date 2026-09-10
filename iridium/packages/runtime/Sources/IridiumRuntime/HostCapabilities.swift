import Foundation
import IridiumCore
import IridiumRuntimeHostSDK

#if canImport(Darwin)
    import Darwin
#endif

#if os(iOS)
    @_silgen_name("csops")
    private func iridium_csops(
        _ pid: pid_t,
        _ ops: UInt32,
        _ useraddr: UnsafeMutableRawPointer?,
        _ usersize: Int
    ) -> Int32

    @_silgen_name("SecTaskCreateFromSelf")
    private func iridium_sec_task_create_from_self(_ allocator: CFAllocator?) -> CFTypeRef?

    @_silgen_name("SecTaskCopyValueForEntitlement")
    private func iridium_sec_task_copy_value_for_entitlement(
        _ task: CFTypeRef,
        _ entitlement: CFString,
        _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> CFTypeRef?
#endif

public enum DeviceCapabilityClass: String, Codable, CaseIterable, Sendable {
    case lightweight
    case balanced
    case heavyweight

    public var displayName: String {
        switch self {
        case .lightweight:
            "Lightweight"
        case .balanced:
            "Balanced"
        case .heavyweight:
            "Heavyweight"
        }
    }
}

public enum HostThermalState: String, Codable, CaseIterable, Sendable {
    case nominal
    case elevated
    case serious
    case critical

    public var displayName: String {
        switch self {
        case .nominal:
            "Nominal"
        case .elevated:
            "Elevated"
        case .serious:
            "Serious"
        case .critical:
            "Critical"
        }
    }
}

public enum RuntimeExecutionEnvironment: String, Codable, CaseIterable, Sendable {
    case nativeRuntime
    case macOSDevelopmentFallback
    case simulatorDevelopmentFallback
    case unavailable

    public var displayName: String {
        switch self {
        case .nativeRuntime:
            "Native Runtime"
        case .macOSDevelopmentFallback:
            "macOS Dev Fallback"
        case .simulatorDevelopmentFallback:
            "Simulator Dev Fallback"
        case .unavailable:
            "Unavailable"
        }
    }
}

public struct RuntimeSubsystemReadiness: Codable, Hashable, Sendable {
    public var ready: Bool?
    public var status: String?
    public var statusSummary: String?

    public init(
        ready: Bool? = nil,
        status: String? = nil,
        statusSummary: String? = nil
    ) {
        self.ready = ready
        self.status = status
        self.statusSummary = statusSummary
    }

    public var isBlocked: Bool {
        ready == false
    }
}

public struct RuntimeLaunchMilestones: Codable, Hashable, Sendable {
    public var sessionIdentifier: String?
    public var wineServerReady: Bool
    public var windowsProcessStarted: Bool
    public var firstFramePresented: Bool

    public init(
        sessionIdentifier: String? = nil,
        wineServerReady: Bool = false,
        windowsProcessStarted: Bool = false,
        firstFramePresented: Bool = false
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.wineServerReady = wineServerReady
        self.windowsProcessStarted = windowsProcessStarted
        self.firstFramePresented = firstFramePresented
    }

    public var fullyVerified: Bool {
        wineServerReady && windowsProcessStarted && firstFramePresented
    }
}

public struct HostCapabilitySnapshot: Codable, Hashable, Sendable {
    public var jitStatus: JITStatus
    public var availableManagedStorageGB: Double
    public var deviceCapabilityClass: DeviceCapabilityClass
    public var deviceTier: DeviceTier
    public var thermalState: HostThermalState
    public var lowPowerModeEnabled: Bool
    public var runtimeBundles: [RuntimeBundleManifest]
    public var selectedRuntimeBundle: RuntimeBundleManifest?
    public var constraints: [String]
    public var runtimeBridgeAvailable: Bool
    public var runtimeBridgeStale: Bool
    public var steamBridgeAvailable: Bool
    public var steamBridgeStale: Bool
    public var backendMode: RuntimeBackendMode
    public var executionEnvironment: RuntimeExecutionEnvironment
    public var launchReady: Bool?
    public var launchStatus: String?
    public var launchStatusSummary: String?
    public var runtimeMilestones: RuntimeLaunchMilestones?
    public var allocatorBackend: String?
    public var jitSessionKind: JITSessionKind?
    public var jitFailureStage: String?
    public var jitToolRecommendation: JITToolRecommendation?
    public var jitToolBootstrapRequired: Bool?
    public var jitToolBootstrapKind: String?
    public var jitToolBootstrapSummary: String?
    public var jitSummary: String?
    public var exceptionPortsActive: Bool?
    public var presentationReadiness: RuntimeSubsystemReadiness?
    public var inputReadiness: RuntimeSubsystemReadiness?
    public var audioReadiness: RuntimeSubsystemReadiness?
    public var measuredAt: Date

    public init(
        jitStatus: JITStatus,
        availableManagedStorageGB: Double,
        deviceCapabilityClass: DeviceCapabilityClass,
        deviceTier: DeviceTier,
        thermalState: HostThermalState,
        lowPowerModeEnabled: Bool,
        runtimeBundles: [RuntimeBundleManifest],
        selectedRuntimeBundle: RuntimeBundleManifest?,
        constraints: [String],
        runtimeBridgeAvailable: Bool = false,
        runtimeBridgeStale: Bool = false,
        steamBridgeAvailable: Bool = false,
        steamBridgeStale: Bool = false,
        backendMode: RuntimeBackendMode = .development,
        executionEnvironment: RuntimeExecutionEnvironment = .unavailable,
        launchReady: Bool? = nil,
        launchStatus: String? = nil,
        launchStatusSummary: String? = nil,
        runtimeMilestones: RuntimeLaunchMilestones? = nil,
        allocatorBackend: String? = nil,
        jitSessionKind: JITSessionKind? = nil,
        jitFailureStage: String? = nil,
        jitToolRecommendation: JITToolRecommendation? = nil,
        jitToolBootstrapRequired: Bool? = nil,
        jitToolBootstrapKind: String? = nil,
        jitToolBootstrapSummary: String? = nil,
        jitSummary: String? = nil,
        exceptionPortsActive: Bool? = nil,
        presentationReadiness: RuntimeSubsystemReadiness? = nil,
        inputReadiness: RuntimeSubsystemReadiness? = nil,
        audioReadiness: RuntimeSubsystemReadiness? = nil,
        measuredAt: Date = Date()
    ) {
        self.jitStatus = jitStatus
        self.availableManagedStorageGB = availableManagedStorageGB
        self.deviceCapabilityClass = deviceCapabilityClass
        self.deviceTier = deviceTier
        self.thermalState = thermalState
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.runtimeBundles = runtimeBundles
        self.selectedRuntimeBundle = selectedRuntimeBundle
        self.constraints = constraints
        self.runtimeBridgeAvailable = runtimeBridgeAvailable
        self.runtimeBridgeStale = runtimeBridgeStale
        self.steamBridgeAvailable = steamBridgeAvailable
        self.steamBridgeStale = steamBridgeStale
        self.backendMode = backendMode
        self.executionEnvironment = executionEnvironment
        self.launchReady = launchReady
        self.launchStatus = launchStatus
        self.launchStatusSummary = launchStatusSummary
        self.runtimeMilestones = runtimeMilestones
        self.allocatorBackend = allocatorBackend
        self.jitSessionKind = jitSessionKind
        self.jitFailureStage = jitFailureStage
        self.jitToolRecommendation = jitToolRecommendation
        self.jitToolBootstrapRequired = jitToolBootstrapRequired
        self.jitToolBootstrapKind = jitToolBootstrapKind
        self.jitToolBootstrapSummary = jitToolBootstrapSummary
        self.jitSummary = jitSummary
        self.exceptionPortsActive = exceptionPortsActive
        self.presentationReadiness = presentationReadiness
        self.inputReadiness = inputReadiness
        self.audioReadiness = audioReadiness
        self.measuredAt = measuredAt
    }

    public var playabilityReady: Bool? {
        let readinessStates = [presentationReadiness, inputReadiness, audioReadiness]
            .compactMap { $0?.ready }
        guard !readinessStates.isEmpty else {
            return nil
        }
        return readinessStates.allSatisfy { $0 }
    }

    /// The embedded translator and JIT are available, but no successful Wine
    /// process/server handshake or rendered frame has been observed yet.
    public var runtimeMilestoneVerificationPending: Bool {
        launchReady == true && runtimeMilestones?.fullyVerified != true
    }

    public var playabilityBlockingSummaries: [String] {
        [presentationReadiness, inputReadiness, audioReadiness].compactMap { readiness in
            guard readiness?.isBlocked == true else {
                return nil
            }
            return readiness?.statusSummary ?? "Runtime subsystem is not ready."
        }
    }

    public var usesLightweightDebuggerCheck: Bool {
        launchStatus == xcodeLightweightLaunchStatus
            || allocatorBackend == "xcode-debugger-check"
    }

    public var lightweightDebuggerCheckSummary: String {
        "Xcode-attached JIT checks use lightweight debugger detection only. Direct launch stays blocked until the embedded runtime backend is validated outside the Xcode check flow."
    }
}

public protocol HostCapabilityProvider: Sendable {
    func snapshot() async -> HostCapabilitySnapshot
}

private let xcodeLightweightLaunchStatus = "xcodeDebugCheckOnly"

public struct RuntimeHostCapabilityRecord: Codable, Hashable, Sendable {
    public var jitStatus: JITStatus?
    public var deviceCapabilityClass: DeviceCapabilityClass?
    public var deviceTier: DeviceTier?
    public var launchReady: Bool?
    public var launchStatus: String?
    public var launchStatusSummary: String?
    public var runtimeMilestones: RuntimeLaunchMilestones?
    public var allocatorBackend: String?
    public var jitSessionKind: JITSessionKind?
    public var jitFailureStage: String?
    public var jitToolRecommendation: JITToolRecommendation?
    public var jitToolBootstrapRequired: Bool?
    public var jitToolBootstrapKind: String?
    public var jitToolBootstrapSummary: String?
    public var jitSummary: String?
    public var exceptionPortsActive: Bool?
    public var presentationReadiness: RuntimeSubsystemReadiness?
    public var inputReadiness: RuntimeSubsystemReadiness?
    public var audioReadiness: RuntimeSubsystemReadiness?
    public var translatorReady: Bool?
    public var runtimeHostVersion: String?
    public var supportedArchitectures: [String]?
    public var supportedGraphicsAPIs: [String]?
    public var measuredAt: Date?

    public init(
        jitStatus: JITStatus? = nil,
        deviceCapabilityClass: DeviceCapabilityClass? = nil,
        deviceTier: DeviceTier? = nil,
        launchReady: Bool? = nil,
        launchStatus: String? = nil,
        launchStatusSummary: String? = nil,
        runtimeMilestones: RuntimeLaunchMilestones? = nil,
        allocatorBackend: String? = nil,
        jitSessionKind: JITSessionKind? = nil,
        jitFailureStage: String? = nil,
        jitToolRecommendation: JITToolRecommendation? = nil,
        jitToolBootstrapRequired: Bool? = nil,
        jitToolBootstrapKind: String? = nil,
        jitToolBootstrapSummary: String? = nil,
        jitSummary: String? = nil,
        exceptionPortsActive: Bool? = nil,
        presentationReadiness: RuntimeSubsystemReadiness? = nil,
        inputReadiness: RuntimeSubsystemReadiness? = nil,
        audioReadiness: RuntimeSubsystemReadiness? = nil,
        translatorReady: Bool? = nil,
        runtimeHostVersion: String? = nil,
        supportedArchitectures: [String]? = nil,
        supportedGraphicsAPIs: [String]? = nil,
        measuredAt: Date? = nil
    ) {
        self.jitStatus = jitStatus
        self.deviceCapabilityClass = deviceCapabilityClass
        self.deviceTier = deviceTier
        self.launchReady = launchReady
        self.launchStatus = launchStatus
        self.launchStatusSummary = launchStatusSummary
        self.runtimeMilestones = runtimeMilestones
        self.allocatorBackend = allocatorBackend
        self.jitSessionKind = jitSessionKind
        self.jitFailureStage = jitFailureStage
        self.jitToolRecommendation = jitToolRecommendation
        self.jitToolBootstrapRequired = jitToolBootstrapRequired
        self.jitToolBootstrapKind = jitToolBootstrapKind
        self.jitToolBootstrapSummary = jitToolBootstrapSummary
        self.jitSummary = jitSummary
        self.exceptionPortsActive = exceptionPortsActive
        self.presentationReadiness = presentationReadiness
        self.inputReadiness = inputReadiness
        self.audioReadiness = audioReadiness
        self.translatorReady = translatorReady
        self.runtimeHostVersion = runtimeHostVersion
        self.supportedArchitectures = supportedArchitectures
        self.supportedGraphicsAPIs = supportedGraphicsAPIs
        self.measuredAt = measuredAt
    }
}

public struct FileSystemHostCapabilityProvider: HostCapabilityProvider {
    public let runtimeBundleRegistry: any RuntimeBundleRegistry
    public let managedRootURL: URL?
    public let runtimeBridgeRootURL: URL
    public let steamBridgeRootURL: URL
    public let processInfo: ProcessInfo
    public let configuredBackendMode: RuntimeBackendMode
    private let nativeJITAvailabilityProbe: @Sendable ([String: String]) -> Bool?

    public init(
        runtimeBundleRegistry: any RuntimeBundleRegistry = FileSystemRuntimeBundleRegistry(),
        managedRootURL: URL? = nil,
        runtimeBridgeRootURL: URL = RuntimeHostBridgeConfiguration().rootURL,
        steamBridgeRootURL: URL = SteamBridgeConfiguration().rootURL,
        processInfo: ProcessInfo = .processInfo,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        nativeJITAvailabilityProbe: (@Sendable ([String: String]) -> Bool?)? = nil
    ) {
        self.runtimeBundleRegistry = runtimeBundleRegistry
        self.managedRootURL = managedRootURL
        self.runtimeBridgeRootURL = runtimeBridgeRootURL
        self.steamBridgeRootURL = steamBridgeRootURL
        self.processInfo = processInfo
        self.nativeJITAvailabilityProbe =
            nativeJITAvailabilityProbe ?? Self.detectNativeJITAvailability
        self.configuredBackendMode = RuntimeBackendSelection.resolvedMode(
            environment: processInfo.environment,
            infoDictionary: infoDictionary,
            processInfo: processInfo
        )
    }

    private struct NativeJITContext {
        var processIsTraced: Bool
        var codeSignDebugged: Bool
        var privateJITCapability: Bool
        var helperBootstrapRequested: Bool
        var xcodeDebugLaunch: Bool

        var debuggerBackedSession: Bool {
            processIsTraced || codeSignDebugged || helperBootstrapRequested
        }

        var trustedReadyHint: Bool {
            privateJITCapability || processIsTraced || codeSignDebugged
        }

        var sessionKind: JITSessionKind {
            if privateJITCapability {
                return .trollStorePrivate
            }
            if debuggerBackedSession {
                return .debuggerBacked
            }
            return .none
        }
    }

    public func snapshot() async -> HostCapabilitySnapshot {
        let bundles = (try? runtimeBundleRegistry.availableBundles()) ?? []
        let selectedBundle = ((try? runtimeBundleRegistry.defaultBundle()) ?? nil) ?? bundles.first
        let storageHeadroom = measureAvailableManagedStorageGB()
        let runtimeBridgeStatus = bridgeStatus(at: runtimeBridgeRootURL)
        let steamBridgeStatus = bridgeStatus(at: steamBridgeRootURL)
        let backendMode = configuredBackendMode
        let executionEnvironment = detectExecutionEnvironment(
            runtimeBridgeStatus: runtimeBridgeStatus,
            backendMode: backendMode
        )
        #if os(iOS)
            let jitContext = Self.currentNativeJITContext(environment: processInfo.environment)
            if jitContext.privateJITCapability {
                // The FEX allocator can be entered later, outside the scoped
                // capability-refresh call. Preserve this intrinsic process
                // capability so TXM hardware does not incorrectly require a
                // StikDebug callback for a genuine private-JIT session.
                setenv("IRIDIUM_FEX_IOS_PRIVATE_JIT_CAPABILITY", "1", 1)
            }
        #else
            let jitContext = NativeJITContext(
                processIsTraced: false,
                codeSignDebugged: false,
                privateJITCapability: false,
                helperBootstrapRequested: false,
                xcodeDebugLaunch: false
            )
        #endif
        refreshCapabilityRecordIfNeeded(
            executionEnvironment: executionEnvironment,
            selectedBundle: selectedBundle,
            jitContext: jitContext
        )
        let record = effectiveCapabilityRecord(
            from: loadCapabilityRecord(),
            executionEnvironment: executionEnvironment,
            jitContext: jitContext
        )
        let deviceClass =
            record?.deviceCapabilityClass ?? inferDeviceCapabilityClass(processInfo: processInfo)
        let deviceTier =
            record?.deviceTier
            ?? inferDeviceTier(deviceClass: deviceClass, storageHeadroom: storageHeadroom)
        let thermalState = inferThermalState(processInfo: processInfo)
        let lowPowerModeEnabled = inferLowPowerMode(processInfo: processInfo)
        let jitStatus = detectJITStatus(
            record: record,
            bundlesPresent: !bundles.isEmpty,
            executionEnvironment: executionEnvironment
        )
        logDevelopmentJITDiagnosticsIfNeeded(
            executionEnvironment: executionEnvironment,
            record: record,
            effectiveJITStatus: jitStatus
        )
        let runtimeBridgeAvailable = runtimeBridgeStatus.available
        let steamBridgeAvailable = steamBridgeStatus.available
        var constraints: [String] = []

        if jitStatus != .ready {
            if record?.launchStatus == xcodeLightweightLaunchStatus {
                constraints.append(
                    record?.jitSummary
                        ?? record?.launchStatusSummary
                        ?? "Xcode-attached JIT checks use lightweight debugger detection only."
                )
            } else if jitStatus == .required {
                constraints.append("No external debugger/JIT session detected.")
            } else {
                constraints.append(
                    record?.launchStatusSummary
                        ?? "Debugger session detected, but executable code allocation still failed."
                )
            }
        }

        if bundles.isEmpty {
            constraints.append("No runtime bundle is provisioned in managed storage.")
        }

        if record?.launchReady == false {
            constraints.append(
                record?.launchStatusSummary
                    ?? "Embedded runtime launch support is unavailable in this build."
            )
        }

        let launchBootstrapReady = (record?.launchReady ?? record?.translatorReady) == true
        if launchBootstrapReady, let readiness = record?.presentationReadiness, readiness.isBlocked
        {
            constraints.append(
                readiness.statusSummary ?? "Guest presentation path is not ready on this host."
            )
        }
        if launchBootstrapReady, let readiness = record?.inputReadiness, readiness.isBlocked {
            constraints.append(
                readiness.statusSummary ?? "Guest input path is not ready on this host."
            )
        }
        if launchBootstrapReady, let readiness = record?.audioReadiness, readiness.isBlocked {
            constraints.append(
                readiness.statusSummary ?? "Guest audio path is not ready on this host."
            )
        }

        if lowPowerModeEnabled {
            constraints.append("Low power mode is enabled.")
        }

        switch thermalState {
        case .serious, .critical:
            constraints.append("Thermal pressure requires mitigation before launch.")
        case .nominal, .elevated:
            break
        }

        if storageHeadroom < 8 {
            constraints.append("Managed storage headroom is below 8 GB.")
        }

        if runtimeBridgeStatus.stale {
            constraints.append("Runtime bridge heartbeat is stale.")
        } else if runtimeBridgeAvailable {
            constraints.append(
                "Runtime bridge heartbeat is available for internal bridge processing.")
        }

        if !steamBridgeAvailable {
            if steamBridgeStatus.stale {
                constraints.append("Steam bridge heartbeat is stale.")
            } else {
                constraints.append("Steam bridge heartbeat is missing.")
            }
        }

        switch backendMode {
        case .bundledDevice:
            constraints.append("Device launches use the bundled on-device runtime backend.")
        case .providerBacked:
            constraints.append("Device launches use the provider-backed runtime backend override.")
        case .development:
            constraints.append("Runtime execution uses the explicit development backend.")
        }

        switch executionEnvironment {
        case .nativeRuntime:
            break
        case .macOSDevelopmentFallback:
            constraints.append(
                "macOS hosts use an explicit development fallback and are not runtime-production targets."
            )
        case .simulatorDevelopmentFallback:
            constraints.append(
                "Simulator hosts use an explicit development fallback and are not runtime-production targets."
            )
        case .unavailable:
            constraints.append("Runtime execution backend is unavailable on this host.")
        }

        return HostCapabilitySnapshot(
            jitStatus: jitStatus,
            availableManagedStorageGB: storageHeadroom,
            deviceCapabilityClass: deviceClass,
            deviceTier: deviceTier,
            thermalState: thermalState,
            lowPowerModeEnabled: lowPowerModeEnabled,
            runtimeBundles: bundles,
            selectedRuntimeBundle: selectedBundle,
            constraints: constraints,
            runtimeBridgeAvailable: runtimeBridgeAvailable,
            runtimeBridgeStale: runtimeBridgeStatus.stale,
            steamBridgeAvailable: steamBridgeAvailable,
            steamBridgeStale: steamBridgeStatus.stale,
            backendMode: backendMode,
            executionEnvironment: executionEnvironment,
            launchReady: record?.launchReady ?? record?.translatorReady,
            launchStatus: record?.launchStatus,
            launchStatusSummary: record?.launchStatusSummary,
            runtimeMilestones: record?.runtimeMilestones,
            allocatorBackend: record?.allocatorBackend,
            jitSessionKind: record?.jitSessionKind,
            jitFailureStage: record?.jitFailureStage,
            jitToolRecommendation: record?.jitToolRecommendation,
            jitToolBootstrapRequired: record?.jitToolBootstrapRequired,
            jitToolBootstrapKind: record?.jitToolBootstrapKind,
            jitToolBootstrapSummary: record?.jitToolBootstrapSummary,
            jitSummary: record?.jitSummary,
            exceptionPortsActive: record?.exceptionPortsActive,
            presentationReadiness: record?.presentationReadiness,
            inputReadiness: record?.inputReadiness,
            audioReadiness: record?.audioReadiness,
            measuredAt: Date()
        )
    }

    public static func capabilityRecordURL(for managedRootURL: URL) -> URL {
        managedRootURL.appending(path: "host-capabilities.json")
    }

    private func loadCapabilityRecord() -> RuntimeHostCapabilityRecord? {
        guard let managedRootURL else {
            return nil
        }

        let recordURL = Self.capabilityRecordURL(for: managedRootURL)
        guard let data = try? Data(contentsOf: recordURL) else {
            return nil
        }

        return try? JSONDecoder().decode(RuntimeHostCapabilityRecord.self, from: data)
    }

    private func bridgeStatus(at rootURL: URL) -> (available: Bool, stale: Bool) {
        let statusURL = rootURL.appending(path: "bridge-status.json")
        guard let data = try? Data(contentsOf: statusURL),
            let status = try? JSONDecoder().decode(BridgeHeartbeatStatus.self, from: data)
        else {
            return (false, false)
        }

        let stale = Date().timeIntervalSince(status.lastUpdatedAt) > 30
        return (!stale, stale)
    }

    private func refreshCapabilityRecordIfNeeded(
        executionEnvironment: RuntimeExecutionEnvironment,
        selectedBundle: RuntimeBundleManifest?,
        jitContext: NativeJITContext
    ) {
        guard executionEnvironment == .nativeRuntime,
            let bundleRootPath = selectedBundle?.bundleRootPath,
            !bundleRootPath.isEmpty
        else {
            return
        }

        if jitContext.xcodeDebugLaunch {
            return
        }

        let environmentOverride: String?
        if jitContext.trustedReadyHint {
            environmentOverride = "ready"
        } else if let nativeJITReady = nativeJITAvailabilityProbe(processInfo.environment), nativeJITReady
        {
            environmentOverride = "ready"
        } else {
            environmentOverride = nil
        }

        var environmentOverrides: [String: String?] = [
            RuntimeEnvironmentKey.hostJITStatus: environmentOverride
        ]
        if jitContext.sessionKind != .none {
            environmentOverrides["IRIDIUM_FEX_IOS_JIT_SESSION_KIND"] =
                jitContext.sessionKind.rawValue
        } else if jitContext.xcodeDebugLaunch {
            environmentOverrides["IRIDIUM_FEX_IOS_JIT_SESSION_KIND"] =
                JITSessionKind.debuggerBacked.rawValue
        }
        if jitContext.privateJITCapability {
            environmentOverrides["IRIDIUM_FEX_IOS_PRIVATE_JIT_CAPABILITY"] = "1"
        }
        #if DEBUG
            environmentOverrides["IRIDIUM_HOST_INCLUDE_DEBUG_DIAGNOSTICS"] = "1"
        #endif

        withTemporaryEnvironmentOverrides(environmentOverrides) {
            bundleRootPath.withCString { bundleRootCString in
                var invocation = IridiumRuntimeHostCapabilityRefreshPaths(
                    runtime_bundle_root_path: bundleRootCString
                )
                _ = iridium_runtime_host_refresh_capabilities(&invocation)
            }
        }
    }

    private func effectiveCapabilityRecord(
        from baseRecord: RuntimeHostCapabilityRecord?,
        executionEnvironment: RuntimeExecutionEnvironment,
        jitContext: NativeJITContext
    ) -> RuntimeHostCapabilityRecord? {
        // Only synthesize the lightweight Xcode override for an actual Xcode launch.
        // StikDebug can legitimately produce a ready debugger-backed record that also
        // reports the skipped execute probe, and those sessions must remain launchable.
        let lightweightXcodeCheck =
            jitContext.xcodeDebugLaunch
            || baseRecord?.launchStatus == xcodeLightweightLaunchStatus

        guard executionEnvironment == .nativeRuntime, lightweightXcodeCheck else {
            return baseRecord
        }

        let sessionKind =
            jitContext.sessionKind == .none ? JITSessionKind.debuggerBacked : jitContext.sessionKind

        return RuntimeHostCapabilityRecord(
            jitStatus: .required,
            deviceCapabilityClass: baseRecord?.deviceCapabilityClass,
            deviceTier: baseRecord?.deviceTier,
            launchReady: false,
            launchStatus: xcodeLightweightLaunchStatus,
            launchStatusSummary:
                "Xcode-attached JIT checks use lightweight debugger detection only. Direct launch stays blocked until the embedded runtime backend is validated outside the Xcode check flow.",
            runtimeMilestones: baseRecord?.runtimeMilestones,
            allocatorBackend: "xcode-debugger-check",
            jitSessionKind: sessionKind,
            jitFailureStage: "execution probe skipped under xcode debugger",
            jitToolRecommendation: baseRecord?.jitToolRecommendation,
            jitToolBootstrapRequired: baseRecord?.jitToolBootstrapRequired ?? false,
            jitToolBootstrapKind: baseRecord?.jitToolBootstrapKind,
            jitToolBootstrapSummary:
                "Xcode is attached; Iridium will skip the unsafe execute probe but still requires the real runtime backend to pass under a non-Xcode debugger-backed session.",
            jitSummary:
                "Debugger-backed JIT was detected under Xcode, but Iridium intentionally skipped embedded runtime validation. Direct launch stays blocked in this check mode.",
            exceptionPortsActive: false,
            presentationReadiness: baseRecord?.presentationReadiness,
            inputReadiness: baseRecord?.inputReadiness,
            audioReadiness: baseRecord?.audioReadiness,
            translatorReady: false,
            runtimeHostVersion: baseRecord?.runtimeHostVersion,
            supportedArchitectures: baseRecord?.supportedArchitectures,
            supportedGraphicsAPIs: baseRecord?.supportedGraphicsAPIs,
            measuredAt: Date()
        )
    }

    private func detectExecutionEnvironment(
        runtimeBridgeStatus: (available: Bool, stale: Bool),
        backendMode: RuntimeBackendMode
    ) -> RuntimeExecutionEnvironment {
        if processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil {
            return .simulatorDevelopmentFallback
        }

        switch backendMode {
        case .bundledDevice, .providerBacked:
            return .nativeRuntime
        case .development:
            #if os(macOS)
                return .macOSDevelopmentFallback
            #else
                return runtimeBridgeStatus.available ? .nativeRuntime : .unavailable
            #endif
        }
    }

    private func detectJITStatus(
        record: RuntimeHostCapabilityRecord?,
        bundlesPresent: Bool,
        executionEnvironment: RuntimeExecutionEnvironment
    ) -> JITStatus {
        if let status = record?.jitStatus {
            return status
        }

        if let override = processInfo.environment["IRIDIUM_JIT_STATUS"]?.lowercased(),
            executionEnvironment != .nativeRuntime
        {
            switch override {
            case "ready":
                return .ready
            case "unavailable":
                return .unavailable
            default:
                return .required
            }
        }

        switch executionEnvironment {
        case .nativeRuntime:
            return bundlesPresent ? .required : .unavailable
        case .macOSDevelopmentFallback, .simulatorDevelopmentFallback:
            return bundlesPresent ? .ready : .required
        case .unavailable:
            return .unavailable
        }
    }

    static func detectNativeJITAvailability(environment: [String: String]) -> Bool? {
        #if os(iOS)
            let jitContext = currentNativeJITContext(environment: environment)
            return evaluateNativeJITAvailability(
                environment: environment,
                processIsBeingTraced: jitContext.processIsTraced,
                processCodeSigningFlags: jitContext.codeSignDebugged
                    ? codeSigningDebuggedFlag : 0,
                privateEntitlementJITAvailable: jitContext.privateJITCapability
            )
        #else
            return nil
        #endif
    }

    static func evaluateNativeJITAvailability(
        environment: [String: String],
        processIsBeingTraced: Bool,
        processCodeSigningFlags: UInt32?,
        privateEntitlementJITAvailable: Bool = false
    ) -> Bool {
        if privateEntitlementJITAvailable {
            return true
        }

        guard !looksLikeXcodeDebugLaunch(environment: environment) else {
            return false
        }

        if let processCodeSigningFlags {
            // External JIT tools attach long enough to set CS_DEBUGGED and then
            // commonly detach. P_TRACED is therefore transient, while
            // CS_DEBUGGED is the durable process capability that permits JIT.
            return (processCodeSigningFlags & codeSigningDebuggedFlag) != 0
        }

        // Older kernels or restricted hosts can reject csops. Retain the
        // active-trace fallback only when the durable signing flags are
        // unavailable.
        return processIsBeingTraced
    }

    static func looksLikeXcodeDebugLaunch(environment: [String: String]) -> Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    }

    private static let codeSigningDebuggedFlag: UInt32 = 0x1000_0000

    #if os(iOS)
        private static func currentNativeJITContext(environment: [String: String]) -> NativeJITContext {
            let codeSigningFlags = currentProcessCodeSigningFlags()
            let codeSignDebugged =
                codeSigningFlags.map { ($0 & codeSigningDebuggedFlag) != 0 } ?? false
            let helperBootstrapRequested =
                environment["IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_REQUIRED"] == "1"
                || environment["IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_KIND"] != nil
            return NativeJITContext(
                processIsTraced: processIsBeingTraced(),
                codeSignDebugged: codeSignDebugged,
                privateJITCapability: currentProcessHasPrivateJITCapability(),
                helperBootstrapRequested: helperBootstrapRequested,
                xcodeDebugLaunch: looksLikeXcodeDebugLaunch(environment: environment)
            )
        }

        private static func currentProcessHasPrivateJITCapability() -> Bool {
            currentProcessEntitlementValue("jb.pmap_cs_custom_trust")
                || currentProcessEntitlementValue("dynamic-codesigning")
                || currentProcessEntitlementValue("com.apple.private.security.no-sandbox")
        }

        private static func currentProcessEntitlementValue(_ entitlement: String) -> Bool {
            guard let task = iridium_sec_task_create_from_self(nil),
                let value = iridium_sec_task_copy_value_for_entitlement(
                    task,
                    entitlement as CFString,
                    nil
                )
            else {
                return false
            }

            if let number = value as? NSNumber {
                return number.boolValue
            }
            if let boolean = value as? Bool {
                return boolean
            }
            return false
        }
    #endif

    #if os(iOS)
        private static func processIsBeingTraced() -> Bool {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            let result = name.withUnsafeMutableBufferPointer { nameBuffer in
                sysctl(nameBuffer.baseAddress, u_int(nameBuffer.count), &info, &size, nil, 0)
            }

            guard result == 0 else {
                return false
            }

            return (info.kp_proc.p_flag & P_TRACED) != 0
        }

        private static func currentProcessCodeSigningFlags() -> UInt32? {
            let statusOperation: UInt32 = 0
            var flags: UInt32 = 0
            let result = withUnsafeMutablePointer(to: &flags) { pointer in
                iridium_csops(
                    getpid(),
                    statusOperation,
                    UnsafeMutableRawPointer(pointer),
                    MemoryLayout<UInt32>.size
                )
            }

            guard result == 0 else {
                return nil
            }

            return flags
        }
    #endif

    private func withTemporaryEnvironmentOverrides<T>(
        _ overrides: [String: String?],
        operation: () -> T
    ) -> T {
        var previousValues: [String: String?] = [:]

        for key in overrides.keys {
            previousValues[key] = processInfo.environment[key]
        }

        for (key, value) in overrides {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }

        defer {
            for (key, previousValue) in previousValues {
                if let previousValue {
                    setenv(key, previousValue, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        return operation()
    }

    private func logDevelopmentJITDiagnosticsIfNeeded(
        executionEnvironment: RuntimeExecutionEnvironment,
        record: RuntimeHostCapabilityRecord?,
        effectiveJITStatus: JITStatus
    ) {
        #if os(iOS)
            guard executionEnvironment == .nativeRuntime else {
                return
            }

            let codeSigningFlags = Self.currentProcessCodeSigningFlags()
            let debugFlagPresent =
                codeSigningFlags.map {
                    ($0 & Self.codeSigningDebuggedFlag) != 0
                } ?? false
            let allocatorBackend = record?.allocatorBackend ?? "none"
            let sessionKind = record?.jitSessionKind?.rawValue ?? "none"
            let failureStage = record?.jitFailureStage ?? "none"
            let toolRecommendation = record?.jitToolRecommendation?.rawValue ?? "none"
            let exceptionPortsActive = record?.exceptionPortsActive ?? false
            print(
                "[IridiumRuntime] jit-diagnostics: p_traced=\(Self.processIsBeingTraced()) code_sign_debugged=\(debugFlagPresent) host_jit_status=\(effectiveJITStatus.rawValue) allocator_backend=\(allocatorBackend) session_kind=\(sessionKind) failure_stage=\(failureStage) tool_recommendation=\(toolRecommendation) exception_ports_active=\(exceptionPortsActive)"
            )
        #endif
    }

    private func measureAvailableManagedStorageGB() -> Double {
        let probeURL = managedRootURL ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let values = try? probeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])

        let importantBytes =
            values?.allValues[.volumeAvailableCapacityForImportantUsageKey] as? Int64
        let availableBytes = values?.allValues[.volumeAvailableCapacityKey] as? Int
        let bytes = importantBytes ?? Int64(availableBytes ?? 0)
        return Double(bytes) / 1_000_000_000
    }

    private func inferLowPowerMode(processInfo: ProcessInfo) -> Bool {
        processInfo.isLowPowerModeEnabled
    }

    private func inferDeviceCapabilityClass(processInfo: ProcessInfo) -> DeviceCapabilityClass {
        if processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil {
            return .balanced
        }

        #if os(macOS)
            return .heavyweight
        #else
            return .balanced
        #endif
    }

    private func inferDeviceTier(deviceClass: DeviceCapabilityClass, storageHeadroom: Double)
        -> DeviceTier
    {
        switch deviceClass {
        case .lightweight:
            return .tier1
        case .balanced:
            return storageHeadroom >= 12 ? .tier2 : .tier1
        case .heavyweight:
            return storageHeadroom >= 24 ? .tier3 : .tier2
        }
    }

    private func inferThermalState(processInfo: ProcessInfo) -> HostThermalState {
        #if os(iOS)
            switch processInfo.thermalState {
            case .fair:
                return .elevated
            case .serious:
                return .serious
            case .critical:
                return .critical
            default:
                return .nominal
            }
        #else
            return .nominal
        #endif
    }
}
