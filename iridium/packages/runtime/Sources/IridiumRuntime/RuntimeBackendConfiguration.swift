import Foundation
import IridiumCore

public struct RuntimeHostBridgeConfiguration: Sendable {
    public var rootURL: URL

    public init(
        rootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) {
        self.rootURL =
            rootURL
            ?? IridiumDeploymentPaths.runtimeBridgeRootURL(
                environment: environment,
                infoDictionary: infoDictionary
            )
    }

    public var requestsRootURL: URL {
        rootURL.appending(path: "requests", directoryHint: .isDirectory)
    }

    public var responsesRootURL: URL {
        rootURL.appending(path: "responses", directoryHint: .isDirectory)
    }
}

public struct RuntimeProviderConfiguration: Sendable {
    public var rootURL: URL

    public init(
        rootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) {
        self.rootURL =
            rootURL
            ?? IridiumDeploymentPaths.runtimeProviderRootURL(
                environment: environment,
                infoDictionary: infoDictionary
            )
    }

    public var requestsRootURL: URL {
        rootURL.appending(path: "requests", directoryHint: .isDirectory)
    }

    public var responsesRootURL: URL {
        rootURL.appending(path: "responses", directoryHint: .isDirectory)
    }

    public var statusURL: URL {
        rootURL.appending(path: "provider-status.json")
    }
}

public enum RuntimeBackendMode: String, Codable, CaseIterable, Sendable {
    case bundledDevice
    case providerBacked
    case development
}

public enum RuntimeBackendSelection {
    public static let modeEnvironmentKey = "IRIDIUM_RUNTIME_BACKEND_MODE"
    public static let modeInfoDictionaryKey = "IridiumRuntimeBackendMode"

    public static func resolvedMode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        processInfo: ProcessInfo = .processInfo
    ) -> RuntimeBackendMode {
        resolvedMode(
            configuredMode: configuredMode(
                environment: environment, infoDictionary: infoDictionary),
            isSimulator: processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil,
            isMacOSHost: {
                #if os(macOS)
                    true
                #else
                    false
                #endif
            }()
        )
    }

    public static func makeBackendClient(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        processInfo: ProcessInfo = .processInfo
    ) -> any RuntimeBackendClient {
        switch resolvedMode(
            environment: environment, infoDictionary: infoDictionary, processInfo: processInfo)
        {
        case .bundledDevice:
            return BundledDeviceRuntimeBackendClient()
        case .providerBacked:
            return ProviderBackedRuntimeBackendClient()
        case .development:
            return DevelopmentRuntimeBackendClient()
        }
    }

    private static func configuredMode(
        environment: [String: String],
        infoDictionary: [String: Any]?
    ) -> RuntimeBackendMode? {
        let rawValue =
            (environment[modeEnvironmentKey] ?? infoDictionary?[modeInfoDictionaryKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch rawValue {
        case "bundled", "bundleddevice", "local", "device":
            return .bundledDevice
        case "provider", "providerbacked":
            return .providerBacked
        case "development", "dev":
            return .development
        default:
            return nil
        }
    }

    public static func resolvedMode(
        configuredMode: RuntimeBackendMode?,
        isSimulator: Bool,
        isMacOSHost: Bool
    ) -> RuntimeBackendMode {
        if let configuredMode {
            return configuredMode
        }

        if isSimulator || isMacOSHost {
            return .development
        }

        return .bundledDevice
    }
}

public enum RuntimeBridgeFallbackMode: Sendable {
    case never
    case developmentOnly
}
