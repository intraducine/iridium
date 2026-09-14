import Foundation
import IridiumRuntime

#if canImport(Darwin)
    import Darwin
#endif

struct LiveContainerIntegrationStatus: Equatable, Sendable {
    let isHosted: Bool
    let configurationFilePresent: Bool
    let legacyFilePickerFixEnabled: Bool
    let documentHostFixEnabled: Bool
    let launchWithJITEnabled: Bool
    let jitScriptInstalled: Bool
    let jitScriptMatches: Bool

    var filePickerConfigured: Bool {
        configurationFilePresent
            && legacyFilePickerFixEnabled
            && documentHostFixEnabled
    }

    // This describes the legacy LiveContainer-owned JIT launch path only. It is
    // intentionally separate from fullyConfigured because Iridium now requests
    // StikDebug for its already-running PID when the user starts a game.
    var jitConfigured: Bool {
        configurationFilePresent
            && launchWithJITEnabled
            && jitScriptMatches
    }

    var automaticJITDisabled: Bool {
        configurationFilePresent && !launchWithJITEnabled
    }

    var fullyConfigured: Bool {
        filePickerConfigured
            && automaticJITDisabled
            && jitScriptMatches
    }

    func setupFeedback(launchStatus: LiveContainerIntegrationStatus) -> String? {
        guard isHosted else { return nil }
        guard configurationFilePresent else {
            return "Could not verify LiveContainer setup. Its settings file is missing or unreadable."
        }
        guard fullyConfigured else {
            return "LiveContainer setup is incomplete. Use Add Game to repair the file-picker settings and disable LiveContainer's automatic JIT launch."
        }
        guard launchStatus.fullyConfigured else {
            return "Setup saved and verified. Restart required: fully close Iridium, then open it from LiveContainer. LiveContainer loads these per-app settings only when Iridium starts."
        }
        return "LiveContainer setup complete. Automatic host JIT is disabled; Iridium will request JIT for the running process when you play."
    }

}

enum LiveContainerIntegrationError: LocalizedError {
    case notHosted
    case missingConfiguration
    case malformedConfiguration

    var errorDescription: String? {
        switch self {
        case .notHosted:
            "Iridium is not running inside LiveContainer."
        case .missingConfiguration:
            "LiveContainer's LCAppInfo.plist is missing from the Iridium app bundle."
        case .malformedConfiguration:
            "LiveContainer's LCAppInfo.plist could not be read as a property list."
        }
    }
}

enum LiveContainerIntegration {
    static let configurationFileName = "LCAppInfo.plist"
    // The picker hooks and any host-owned JIT launch script are loaded before
    // guest code runs. Preserve what the host supplied for this process so an
    // in-app repair can never be mistaken for settings that were already active.
    static let processLaunchStatus = currentStatus()

    static func inferredActiveJITProviderIdentifier(
        for status: LiveContainerIntegrationStatus
    ) -> String? {
        guard status.isHosted, status.jitConfigured else {
            return nil
        }

        // Legacy configurations may have been launched by LiveContainer with
        // this exact StikDebug script. Never infer that provider from the safe
        // configuration where automatic host JIT is disabled.
        return ExternalJITProvider.stikDebug.runtimeIdentifier
    }

    @discardableResult
    static func configureProcessLaunchEnvironment(
        status: LiveContainerIntegrationStatus = processLaunchStatus
    ) -> String? {
        let inferredProvider = inferredActiveJITProviderIdentifier(for: status)
        if let inferredProvider {
            setenv(RuntimeEnvironmentKey.activeJITProvider, inferredProvider, 1)
        }

        let effectiveProvider = getenv(RuntimeEnvironmentKey.activeJITProvider).map {
            String(cString: $0)
        } ?? "none"
        print(
            "[IridiumRuntime] LiveContainer process launch: hosted=\(status.isHosted) configuration=\(status.configurationFilePresent) launch_with_jit=\(status.launchWithJITEnabled) script_matches=\(status.jitScriptMatches) inferred_provider=\(inferredProvider ?? "none") effective_provider=\(effectiveProvider)"
        )
        return inferredProvider
    }

    static func isHosted(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        bundleURL.path.contains("/Documents/Applications/")
    }

    static func currentStatus(
        bundleURL: URL = Bundle.main.bundleURL,
        expectedJITScriptData: Data = JITBootstrapAssetBundle.liveContainerScriptData
    ) -> LiveContainerIntegrationStatus {
        status(
            configurationURL: bundleURL.appending(path: configurationFileName),
            isHosted: isHosted(bundleURL: bundleURL),
            expectedJITScriptData: expectedJITScriptData
        )
    }

    static func status(
        configurationURL: URL,
        isHosted: Bool,
        expectedJITScriptData: Data
    ) -> LiveContainerIntegrationStatus {
        guard isHosted else {
            return LiveContainerIntegrationStatus(
                isHosted: false,
                configurationFilePresent: false,
                legacyFilePickerFixEnabled: false,
                documentHostFixEnabled: false,
                launchWithJITEnabled: false,
                jitScriptInstalled: false,
                jitScriptMatches: false
            )
        }

        guard let configuration = readConfiguration(at: configurationURL) else {
            return LiveContainerIntegrationStatus(
                isHosted: true,
                configurationFilePresent: false,
                legacyFilePickerFixEnabled: false,
                documentHostFixEnabled: false,
                launchWithJITEnabled: false,
                jitScriptInstalled: false,
                jitScriptMatches: false
            )
        }

        let expectedScript = expectedJITScriptData.base64EncodedString()
        let installedScript = configuration["jitLaunchScriptJs"] as? String
        return LiveContainerIntegrationStatus(
            isHosted: true,
            configurationFilePresent: true,
            legacyFilePickerFixEnabled: configuration["doSymlinkInbox"] as? Bool == true,
            documentHostFixEnabled: configuration["fixFilePickerNew"] as? Bool == true,
            launchWithJITEnabled: configuration["isJITNeeded"] as? Bool == true,
            jitScriptInstalled: installedScript?.isEmpty == false,
            jitScriptMatches: installedScript == expectedScript
        )
    }

    @discardableResult
    static func repairCurrentProcessConfiguration(
        bundleURL: URL = Bundle.main.bundleURL,
        expectedJITScriptData: Data = JITBootstrapAssetBundle.liveContainerScriptData
    ) throws -> LiveContainerIntegrationStatus {
        guard isHosted(bundleURL: bundleURL) else {
            throw LiveContainerIntegrationError.notHosted
        }
        return try repair(
            configurationURL: bundleURL.appending(path: configurationFileName),
            expectedJITScriptData: expectedJITScriptData
        )
    }

    @discardableResult
    static func repair(
        configurationURL: URL,
        expectedJITScriptData: Data
    ) throws -> LiveContainerIntegrationStatus {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            throw LiveContainerIntegrationError.missingConfiguration
        }
        guard var configuration = readConfiguration(at: configurationURL) else {
            throw LiveContainerIntegrationError.malformedConfiguration
        }

        // LiveContainer's bundle-ID JIT path can ask StikDebug to relaunch a
        // hosted guest and fail before it obtains a PID. Keep its automatic JIT
        // launch disabled. Iridium's in-app handoff targets getpid() directly.
        // The exact bootstrap script remains staged for compatibility and audit.
        configuration["doSymlinkInbox"] = true
        configuration["fixFilePickerNew"] = true
        configuration["isJITNeeded"] = false
        configuration["jitLaunchScriptJs"] = expectedJITScriptData.base64EncodedString()

        let encoded = try PropertyListSerialization.data(
            fromPropertyList: configuration,
            format: .binary,
            options: 0
        )
        try encoded.write(to: configurationURL, options: .atomic)

        return status(
            configurationURL: configurationURL,
            isHosted: true,
            expectedJITScriptData: expectedJITScriptData
        )
    }

    private static func readConfiguration(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) else {
            return nil
        }
        return propertyList as? [String: Any]
    }
}
