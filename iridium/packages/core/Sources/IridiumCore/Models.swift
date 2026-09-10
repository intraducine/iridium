import Foundation

public enum GameSource: String, Codable, CaseIterable, Sendable {
    case manualImport
    case steam

    public var displayName: String {
        switch self {
        case .manualImport:
            "Manual Import"
        case .steam:
            "Steam"
        }
    }
}

public enum DeviceTier: String, Codable, CaseIterable, Sendable {
    case tier1
    case tier2
    case tier3

    public var displayName: String {
        switch self {
        case .tier1:
            "Tier 1"
        case .tier2:
            "Tier 2"
        case .tier3:
            "Tier 3"
        }
    }
}

public enum RendererPreset: String, Codable, CaseIterable, Sendable {
    case dxvkBalanced
    case dxvkPerformance
    case vkd3dHighCompatibility
    case metalOpenGLFallback

    public var displayName: String {
        switch self {
        case .dxvkBalanced:
            "DXVK Balanced"
        case .dxvkPerformance:
            "DXVK Performance"
        case .vkd3dHighCompatibility:
            "VKD3D High Compatibility"
        case .metalOpenGLFallback:
            "Metal OpenGL Fallback"
        }
    }
}

public enum MemoryBudgetClass: String, Codable, CaseIterable, Sendable {
    case compact
    case balanced
    case expansive
}

public enum ShaderStrategy: String, Codable, CaseIterable, Sendable {
    case onDemand
    case selectivePrewarm
    case fullPrewarm
}

public struct RuntimePolicy: Codable, Hashable, Sendable {
    public var memoryBudgetClass: MemoryBudgetClass
    public var rendererOverride: RendererPreset?
    public var resolutionScale: Double
    public var framePacingCap: Int?
    public var shaderStrategy: ShaderStrategy
    public var environmentOverrides: [String: String]
    public var requiresExplicitWhitelist: Bool

    public init(
        memoryBudgetClass: MemoryBudgetClass,
        rendererOverride: RendererPreset? = nil,
        resolutionScale: Double,
        framePacingCap: Int? = nil,
        shaderStrategy: ShaderStrategy,
        environmentOverrides: [String: String] = [:],
        requiresExplicitWhitelist: Bool = false
    ) {
        self.memoryBudgetClass = memoryBudgetClass
        self.rendererOverride = rendererOverride
        self.resolutionScale = resolutionScale
        self.framePacingCap = framePacingCap
        self.shaderStrategy = shaderStrategy
        self.environmentOverrides = environmentOverrides
        self.requiresExplicitWhitelist = requiresExplicitWhitelist
    }
}

public enum PrefixState: String, Codable, CaseIterable, Sendable {
    case clean
    case customized
    case rebuilding
    case verificationFailed

    public var displayName: String {
        switch self {
        case .clean:
            "Clean"
        case .customized:
            "Customized"
        case .rebuilding:
            "Rebuilding"
        case .verificationFailed:
            "Verification Failed"
        }
    }
}

public enum DownloadState: String, Codable, CaseIterable, Sendable {
    case queued
    case downloading
    case verifying
    case mounting
    case installed

    public var displayName: String {
        switch self {
        case .queued:
            "Queued"
        case .downloading:
            "Downloading"
        case .verifying:
            "Verifying"
        case .mounting:
            "Mounting"
        case .installed:
            "Installed"
        }
    }
}

public enum InstallExecutionStage: String, Codable, CaseIterable, Sendable {
    case queued
    case resolving
    case downloading
    case verifying
    case mounting
    case completed

    public var displayName: String {
        switch self {
        case .queued:
            "Queued"
        case .resolving:
            "Resolving Depots"
        case .downloading:
            "Downloading"
        case .verifying:
            "Verifying"
        case .mounting:
            "Mounting"
        case .completed:
            "Completed"
        }
    }
}

public struct InstallExecutionRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var appID: String
    public var buildID: String
    public var branchName: String
    public var targetPath: String
    public var primaryExecutable: String
    public var depotIDs: [String]
    public var depotMountPaths: [String: String]
    public var completedDepotIDs: [String]
    public var stage: InstallExecutionStage
    public var detail: String
    public var reservedDiskGB: Double
    public var accountSessionReference: String?
    public var depotProgressBytes: [String: Int64]
    public var depotVerifiedIDs: [String]
    public var resumeCheckpoint: String?
    public var managedArtifactIdentifier: String?
    public var executableFingerprint: String?
    public var runtimeBundleIdentifier: String?
    public var runtimeBundleVersion: String?
    public var lastUpdatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        appID: String,
        buildID: String,
        branchName: String,
        targetPath: String,
        primaryExecutable: String,
        depotIDs: [String],
        depotMountPaths: [String: String],
        completedDepotIDs: [String],
        stage: InstallExecutionStage,
        detail: String,
        reservedDiskGB: Double,
        accountSessionReference: String? = nil,
        depotProgressBytes: [String: Int64] = [:],
        depotVerifiedIDs: [String] = [],
        resumeCheckpoint: String? = nil,
        managedArtifactIdentifier: String? = nil,
        executableFingerprint: String? = nil,
        runtimeBundleIdentifier: String? = nil,
        runtimeBundleVersion: String? = nil,
        lastUpdatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.appID = appID
        self.buildID = buildID
        self.branchName = branchName
        self.targetPath = targetPath
        self.primaryExecutable = primaryExecutable
        self.depotIDs = depotIDs
        self.depotMountPaths = depotMountPaths
        self.completedDepotIDs = completedDepotIDs
        self.stage = stage
        self.detail = detail
        self.reservedDiskGB = reservedDiskGB
        self.accountSessionReference = accountSessionReference
        self.depotProgressBytes = depotProgressBytes
        self.depotVerifiedIDs = depotVerifiedIDs
        self.resumeCheckpoint = resumeCheckpoint
        self.managedArtifactIdentifier = managedArtifactIdentifier
        self.executableFingerprint = executableFingerprint
        self.runtimeBundleIdentifier = runtimeBundleIdentifier
        self.runtimeBundleVersion = runtimeBundleVersion
        self.lastUpdatedAt = lastUpdatedAt
    }
}

public struct InputBinding: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let input: String
    public let action: String

    public init(id: UUID = UUID(), input: String, action: String) {
        self.id = id
        self.input = input
        self.action = action
    }
}

public struct GameLaunchProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var executablePath: String
    public var arguments: [String]
    public var prefixID: UUID
    public var rendererPreset: RendererPreset
    public var deviceTier: DeviceTier
    public var titleFlags: [String]

    public init(
        id: UUID = UUID(),
        executablePath: String,
        arguments: [String],
        prefixID: UUID,
        rendererPreset: RendererPreset,
        deviceTier: DeviceTier,
        titleFlags: [String]
    ) {
        self.id = id
        self.executablePath = executablePath
        self.arguments = arguments
        self.prefixID = prefixID
        self.rendererPreset = rendererPreset
        self.deviceTier = deviceTier
        self.titleFlags = titleFlags
    }
}

public struct InputProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var touchLayoutName: String
    public var controllerBindings: [InputBinding]
    public var keyboardBindings: [InputBinding]
    public var mouseSensitivity: Double
    public var deadZone: Double

    public init(
        id: UUID = UUID(),
        name: String,
        touchLayoutName: String,
        controllerBindings: [InputBinding],
        keyboardBindings: [InputBinding],
        mouseSensitivity: Double,
        deadZone: Double
    ) {
        self.id = id
        self.name = name
        self.touchLayoutName = touchLayoutName
        self.controllerBindings = controllerBindings
        self.keyboardBindings = keyboardBindings
        self.mouseSensitivity = mouseSensitivity
        self.deadZone = deadZone
    }
}

public struct CompatibilityProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var slug: String
    public var title: String
    public var minimumDeviceTier: DeviceTier
    public var recommendedRenderer: RendererPreset
    public var launchArguments: [String]
    public var titleFlags: [String]
    public var knownIssues: [String]

    public init(
        id: UUID = UUID(),
        slug: String,
        title: String,
        minimumDeviceTier: DeviceTier,
        recommendedRenderer: RendererPreset,
        launchArguments: [String],
        titleFlags: [String],
        knownIssues: [String]
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.minimumDeviceTier = minimumDeviceTier
        self.recommendedRenderer = recommendedRenderer
        self.launchArguments = launchArguments
        self.titleFlags = titleFlags
        self.knownIssues = knownIssues
    }
}

public struct PrefixRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var runtimeName: String
    public var state: PrefixState
    public var storageFootprint: String
    public var storageFootprintGB: Double?
    public var manifestPath: String?
    public var manifestVersion: String?
    public var titleFingerprint: String?
    public var environmentOverrides: [String: String]
    public var lastBootstrapStatus: String?
    public var lastBootstrapDetail: String?
    public var runtimeBundleIdentifier: String?
    public var runtimeBundleVersion: String?

    public init(
        id: UUID = UUID(),
        name: String,
        runtimeName: String,
        state: PrefixState,
        storageFootprint: String,
        storageFootprintGB: Double? = nil,
        manifestPath: String? = nil,
        manifestVersion: String? = nil,
        titleFingerprint: String? = nil,
        environmentOverrides: [String: String] = [:],
        lastBootstrapStatus: String? = nil,
        lastBootstrapDetail: String? = nil,
        runtimeBundleIdentifier: String? = nil,
        runtimeBundleVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.runtimeName = runtimeName
        self.state = state
        self.storageFootprint = storageFootprint
        self.storageFootprintGB = storageFootprintGB
        self.manifestPath = manifestPath
        self.manifestVersion = manifestVersion
        self.titleFingerprint = titleFingerprint
        self.environmentOverrides = environmentOverrides
        self.lastBootstrapStatus = lastBootstrapStatus
        self.lastBootstrapDetail = lastBootstrapDetail
        self.runtimeBundleIdentifier = runtimeBundleIdentifier
        self.runtimeBundleVersion = runtimeBundleVersion
    }
}

public struct DownloadTask: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var progress: Double
    public var state: DownloadState
    public var detail: String
    public var reservedDiskGB: Double?

    public init(
        id: UUID = UUID(),
        title: String,
        progress: Double,
        state: DownloadState,
        detail: String,
        reservedDiskGB: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.progress = progress
        self.state = state
        self.detail = detail
        self.reservedDiskGB = reservedDiskGB
    }
}

public struct GameRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var source: GameSource
    public var installPath: String
    public var savePathMapping: String
    public var compatibilityProfileName: String
    public var inputProfileName: String
    public var touchOverlayName: String
    public var controllerPresetName: String
    public var keyboardMouseEnabled: Bool
    public var prefixState: PrefixState
    public var deviceTier: DeviceTier
    public var rendererPreset: RendererPreset
    public var launchProfile: GameLaunchProfile
    public var installedSizeGB: Double?
    public var managedArtifactIdentifier: String?
    public var executableFingerprint: String?
    public var lastSuccessfulRuntimeBundleIdentifier: String?
    public var lastSuccessfulRuntimeBundleVersion: String?
    public var validationEvidenceSummary: String?
    public var summary: String

    public init(
        id: UUID = UUID(),
        title: String,
        source: GameSource,
        installPath: String,
        savePathMapping: String,
        compatibilityProfileName: String,
        inputProfileName: String,
        touchOverlayName: String,
        controllerPresetName: String,
        keyboardMouseEnabled: Bool,
        prefixState: PrefixState,
        deviceTier: DeviceTier,
        rendererPreset: RendererPreset,
        launchProfile: GameLaunchProfile,
        installedSizeGB: Double? = nil,
        managedArtifactIdentifier: String? = nil,
        executableFingerprint: String? = nil,
        lastSuccessfulRuntimeBundleIdentifier: String? = nil,
        lastSuccessfulRuntimeBundleVersion: String? = nil,
        validationEvidenceSummary: String? = nil,
        summary: String
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.installPath = installPath
        self.savePathMapping = savePathMapping
        self.compatibilityProfileName = compatibilityProfileName
        self.inputProfileName = inputProfileName
        self.touchOverlayName = touchOverlayName
        self.controllerPresetName = controllerPresetName
        self.keyboardMouseEnabled = keyboardMouseEnabled
        self.prefixState = prefixState
        self.deviceTier = deviceTier
        self.rendererPreset = rendererPreset
        self.launchProfile = launchProfile
        self.installedSizeGB = installedSizeGB
        self.managedArtifactIdentifier = managedArtifactIdentifier
        self.executableFingerprint = executableFingerprint
        self.lastSuccessfulRuntimeBundleIdentifier = lastSuccessfulRuntimeBundleIdentifier
        self.lastSuccessfulRuntimeBundleVersion = lastSuccessfulRuntimeBundleVersion
        self.validationEvidenceSummary = validationEvidenceSummary
        self.summary = summary
    }

    public var shortCode: String {
        title.split(separator: " ").prefix(2).map { String($0.prefix(1)) }.joined()
    }
}
