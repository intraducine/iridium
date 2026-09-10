import Foundation

public enum IridiumDeploymentPaths {
    public static let rootEnvironmentKey = "IRIDIUM_ROOT_PATH"
    public static let rootInfoDictionaryKey = "IridiumRootPath"
    public static let sharedContainerEnvironmentKey = "IRIDIUM_SHARED_CONTAINER_IDENTIFIER"
    public static let sharedContainerInfoDictionaryKey = "IridiumSharedContainerIdentifier"

    public static func defaultRootURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        if let configuredRoot = configuredRootValue(environment: environment, infoDictionary: infoDictionary) {
            return resolveConfiguredRoot(
                configuredRoot,
                fileManager: fileManager,
                environment: environment,
                infoDictionary: infoDictionary
            )
        }

        if let containerURL = sharedContainerRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        ) {
            return containerURL.appending(path: "Iridium", directoryHint: .isDirectory).standardizedFileURL
        }

        return applicationSupportRootURL(fileManager: fileManager)
            .appending(path: "Iridium", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    public static func managedRootURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        defaultRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        ).appending(path: "Managed", directoryHint: .isDirectory)
    }

    public static func runtimeBridgeRootURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        defaultRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        ).appending(path: "NativeBridge/RuntimeHost", directoryHint: .isDirectory)
    }

    public static func steamBridgeRootURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        defaultRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        ).appending(path: "NativeBridge/Steam", directoryHint: .isDirectory)
    }

    public static func runtimeProviderRootURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        defaultRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        ).appending(path: "RuntimeProvider", directoryHint: .isDirectory)
    }

    public static func steamSessionsRootURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        defaultRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        ).appending(path: "SteamSessions", directoryHint: .isDirectory)
    }

    private static func configuredRootValue(
        environment: [String: String],
        infoDictionary: [String: Any]?
    ) -> String? {
        sanitized(
            environment[rootEnvironmentKey]
                ?? infoDictionary?[rootInfoDictionaryKey] as? String
        )
    }

    private static func sharedContainerIdentifier(
        environment: [String: String],
        infoDictionary: [String: Any]?
    ) -> String? {
        sanitized(
            environment[sharedContainerEnvironmentKey]
                ?? infoDictionary?[sharedContainerInfoDictionaryKey] as? String
        )
    }

    private static func resolveConfiguredRoot(
        _ configuredRoot: String,
        fileManager: FileManager,
        environment: [String: String],
        infoDictionary: [String: Any]?
    ) -> URL {
        if let fileURL = URL(string: configuredRoot), fileURL.isFileURL {
            return fileURL.standardizedFileURL
        }

        if configuredRoot.hasPrefix("/") {
            return URL(fileURLWithPath: configuredRoot, isDirectory: true).standardizedFileURL
        }

        if let containerURL = sharedContainerRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        ) {
            return containerURL.appending(path: configuredRoot, directoryHint: .isDirectory).standardizedFileURL
        }

        return applicationSupportRootURL(fileManager: fileManager)
            .appending(path: configuredRoot, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    private static func sharedContainerRootURL(
        fileManager: FileManager,
        environment: [String: String],
        infoDictionary: [String: Any]?
    ) -> URL? {
        guard let identifier = sharedContainerIdentifier(environment: environment, infoDictionary: infoDictionary) else {
            return nil
        }

        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)?.standardizedFileURL
        #else
        return nil
        #endif
    }

    private static func applicationSupportRootURL(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
