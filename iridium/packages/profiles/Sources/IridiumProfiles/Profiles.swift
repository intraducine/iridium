import Foundation
import IridiumCore

public struct DeviceCapabilityProfile: Equatable, Sendable {
    public let id: String
    public let tier: DeviceTier
    public let displayName: String
    public let chipFamilies: [String]
    public let notes: String

    public init(id: String, tier: DeviceTier, displayName: String, chipFamilies: [String], notes: String) {
        self.id = id
        self.tier = tier
        self.displayName = displayName
        self.chipFamilies = chipFamilies
        self.notes = notes
    }
}

public enum BuiltInCompatibilityProfiles {
    public static let unityOpenGLLaunchArguments = [
        "-force-opengl", "-screen-fullscreen", "0", "-popupwindow",
    ]

    public static let deviceProfiles: [DeviceCapabilityProfile] = [
        DeviceCapabilityProfile(
            id: "tier1-a17-mbase",
            tier: .tier1,
            displayName: "Tier 1 iPhone/iPad",
            chipFamilies: ["A17 Pro", "M1"],
            notes: "Baseline for lightweight titles, touch-first play, and conservative shader pressure."
        ),
        DeviceCapabilityProfile(
            id: "tier2-a17max-mclass",
            tier: .tier2,
            displayName: "Tier 2 High-End Mobile",
            chipFamilies: ["A17 Pro", "M2", "M3"],
            notes: "Targets medium/heavy titles with higher refresh or denser effects."
        ),
        DeviceCapabilityProfile(
            id: "tier3-mseries-whitelist",
            tier: .tier3,
            displayName: "Tier 3 M-series Whitelist",
            chipFamilies: ["M2", "M3", "M4"],
            notes: "Reserved for whitelist-only heavy titles and the highest compatibility budget."
        )
    ]

    public static let all: [CompatibilityProfile] = [
        CompatibilityProfile(
            slug: "lightweight-default",
            title: "Lightweight Default",
            minimumDeviceTier: .tier1,
            recommendedRenderer: .metalOpenGLFallback,
            launchArguments: unityOpenGLLaunchArguments,
            titleFlags: ["generic", "touch-safe", "2d"],
            knownIssues: ["Tune input and overlay hints to the specific title."]
        ),
        CompatibilityProfile(
            slug: "balanced-default",
            title: "Balanced Default",
            minimumDeviceTier: .tier1,
            recommendedRenderer: .dxvkBalanced,
            launchArguments: ["--windowed"],
            titleFlags: ["generic", "controller-first", "midweight"],
            knownIssues: ["Tune thermal policy and input affordances per title."]
        ),
        CompatibilityProfile(
            slug: "performance-default",
            title: "Performance Default",
            minimumDeviceTier: .tier1,
            recommendedRenderer: .dxvkPerformance,
            launchArguments: ["--windowed"],
            titleFlags: ["generic", "latency-sensitive", "kbm-primary"],
            knownIssues: ["Degrade effects before reducing frame rate."]
        ),
        CompatibilityProfile(
            slug: "heavy-whitelist",
            title: "Heavy Whitelist",
            minimumDeviceTier: .tier1,
            recommendedRenderer: .vkd3dHighCompatibility,
            launchArguments: ["--windowed"],
            titleFlags: ["generic", "aaa", "tier3-whitelist"],
            knownIssues: ["Whitelist required. Favor GPU memory safety over visual targets."]
        )
    ]

    private enum CatalogTitleClass: String, Sendable {
        case lightweight
        case balanced
        case performance
        case heavy
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func titleClass(for title: String) -> CatalogTitleClass {
        let normalized = normalizedTitle(title)

        if normalized.contains("heavy")
            || normalized.contains("aaa")
            || normalized.contains("whitelist") {
            return .heavy
        }

        if normalized.contains("performance")
            || normalized.contains("latency")
            || normalized.contains("race")
            || normalized.contains("racing")
            || normalized.contains("speed") {
            return .performance
        }

        if normalized.contains("light")
            || normalized.contains("card")
            || normalized.contains("deck")
            || normalized.contains("puzzle")
            || normalized.contains("indie")
            || normalized.contains("2d") {
            return .lightweight
        }

        return .balanced
    }

    public static func compatibilityProfile(slug: String) -> CompatibilityProfile? {
        all.first(where: { $0.slug == slug })
    }

    public static func recommendedCompatibilityProfile(forTitle title: String) -> CompatibilityProfile {
        switch titleClass(for: title) {
        case .lightweight:
            return all[0]
        case .balanced:
            return all[1]
        case .performance:
            return all[2]
        case .heavy:
            return all[3]
        }
    }

    public static func deviceProfile(id: String) -> DeviceCapabilityProfile? {
        deviceProfiles.first(where: { $0.id == id })
    }

    public static func runtimePolicy(forTitle title: String, deviceTier: DeviceTier) -> RuntimePolicy {
        switch titleClass(for: title) {
        case .lightweight:
            return RuntimePolicy(
                memoryBudgetClass: .compact,
                rendererOverride: deviceTier == .tier1 ? .metalOpenGLFallback : .dxvkBalanced,
                resolutionScale: deviceTier == .tier1 ? 1.0 : 0.95,
                framePacingCap: 60,
                shaderStrategy: .onDemand,
                environmentOverrides: ["IRIDIUM_TITLE_CLASS": "generic-lightweight"]
            )
        case .balanced:
            return RuntimePolicy(
                memoryBudgetClass: .balanced,
                rendererOverride: deviceTier == .tier1 ? .metalOpenGLFallback : .dxvkBalanced,
                resolutionScale: deviceTier == .tier1 ? 0.9 : 0.95,
                framePacingCap: deviceTier == .tier3 ? 60 : 45,
                shaderStrategy: .selectivePrewarm,
                environmentOverrides: ["IRIDIUM_TITLE_CLASS": "generic-balanced"]
            )
        case .performance:
            return RuntimePolicy(
                memoryBudgetClass: .balanced,
                rendererOverride: .dxvkPerformance,
                resolutionScale: deviceTier == .tier1 ? 0.85 : 0.9,
                framePacingCap: deviceTier == .tier3 ? 90 : 60,
                shaderStrategy: .selectivePrewarm,
                environmentOverrides: ["IRIDIUM_TITLE_CLASS": "generic-performance"]
            )
        case .heavy:
            return RuntimePolicy(
                memoryBudgetClass: .expansive,
                rendererOverride: .vkd3dHighCompatibility,
                resolutionScale: deviceTier == .tier3 ? 0.8 : 0.7,
                framePacingCap: deviceTier == .tier3 ? 60 : 45,
                shaderStrategy: .fullPrewarm,
                environmentOverrides: ["IRIDIUM_TITLE_CLASS": "generic-heavy"],
                requiresExplicitWhitelist: deviceTier == .tier3
            )
        }
    }
}
