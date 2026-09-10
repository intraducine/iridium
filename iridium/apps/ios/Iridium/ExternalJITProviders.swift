import Foundation
import IridiumRuntime

#if os(iOS)
    import Darwin
    import UIKit
#endif

enum ExternalJITProvider: String, Sendable, Equatable {
    case altJIT
    case jitStreamer
    case stikDebug
    case sideStore
    case trollStore

    var runtimeIdentifier: String {
        switch self {
        case .altJIT:
            "altjit"
        case .jitStreamer:
            "jitstreamer"
        case .stikDebug:
            "stikdebug"
        case .sideStore:
            "sidestore"
        case .trollStore:
            "trollstore"
        }
    }

    var displayName: String {
        switch self {
        case .altJIT:
            "AltJIT"
        case .jitStreamer:
            "JitStreamer"
        case .stikDebug:
            "StikDebug"
        case .sideStore:
            "SideStore"
        case .trollStore:
            "TrollStore"
        }
    }

    var actionTitle: String {
        "Enable JIT With \(displayName)"
    }

    var requestInProgressSummary: String {
        switch self {
        case .altJIT:
            "Requesting JIT through AltJIT..."
        case .jitStreamer:
            "Requesting JIT through JitStreamer..."
        case .stikDebug:
            "Requesting JIT through StikDebug..."
        case .sideStore:
            "Requesting JIT through SideStore..."
        case .trollStore:
            "Requesting JIT through TrollStore..."
        }
    }

    var waitingForReadinessSummary: String {
        "Waiting for runtime readiness after JIT enablement..."
    }

    var timeoutSummary: String {
        switch self {
        case .altJIT:
            "AltServer request succeeded, but Iridium never observed runtime readiness."
        case .jitStreamer:
            "JitStreamer attach endpoint succeeded, but Iridium never observed runtime readiness."
        case .stikDebug:
            "StikDebug launched, but Iridium never observed runtime readiness."
        case .sideStore:
            "SideStore launched, but Iridium never observed runtime readiness."
        case .trollStore:
            "TrollStore launched, but Iridium never observed runtime readiness."
        }
    }

    var waitingNotice: String {
        switch self {
        case .altJIT:
            "Iridium requested JIT through AltJIT and is waiting for runtime readiness."
        case .jitStreamer:
            "Iridium requested JIT through JitStreamer and is waiting for runtime readiness."
        case .stikDebug:
            "Iridium opened StikDebug and is waiting for runtime readiness."
        case .sideStore:
            "Iridium opened SideStore and is waiting for runtime readiness."
        case .trollStore:
            "Iridium opened TrollStore and is waiting for runtime readiness."
        }
    }

    var attachMissingSummary: String {
        switch self {
        case .altJIT:
            "Iridium requested JIT through AltJIT, but this app process still does not appear ready. Keep AltServer available, then check again."
        case .jitStreamer:
            "Iridium requested JIT through JitStreamer, but this app process still does not appear ready. Keep JitStreamer reachable, then check again."
        case .stikDebug:
            "Iridium opened StikDebug, but this app process still does not appear ready. Finish the StikDebug JIT attach flow, then check again."
        case .sideStore:
            "Iridium opened SideStore, but this app process still does not appear ready. Finish SideStore JIT enablement, then check again."
        case .trollStore:
            "Iridium opened TrollStore, but this app process still does not appear ready. Finish TrollStore JIT enablement, then check again."
        }
    }
}

struct ExternalJITBundleInfo: Sendable, Equatable {
    var bundleIdentifier: String?
    var altServerID: String?
    var altDeviceID: String?

    var isAltJITCompatible: Bool {
        guard let altServerID, !altServerID.isEmpty else {
            return false
        }
        guard let altDeviceID, !altDeviceID.isEmpty else {
            return false
        }
        return true
    }
}

enum ExternalJITProviderResolver {
    static func normalizedJitStreamerAddress(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let stripped = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard !stripped.isEmpty else {
            return nil
        }

        if stripped.contains("://") {
            guard let url = URL(string: stripped), url.host?.isEmpty == false else {
                return nil
            }
            return stripped
        }

        let normalized = "http://\(stripped)"
        guard let url = URL(string: normalized), url.host?.isEmpty == false else {
            return nil
        }
        return normalized
    }

    #if os(iOS)
        static let probedSchemes = ["stikjit", "stikdebug", "livecontainer2", "sidestore", "apple-magnifier"]

        static var isHostedByLiveContainer: Bool {
            Bundle.main.bundlePath.contains("/Documents/Applications/")
        }

        @MainActor
        static func schemeProbeResults() -> [(scheme: String, available: Bool)] {
            if isHostedByLiveContainer {
                // LiveContainer owns URL routing and JIT-script execution. A
                // guest cannot infer which helper is installed from the host's
                // Info.plist, and direct guest opens fail unless the host has
                // explicitly configured a redirect. Never advertise helpers
                // that Iridium cannot actually open.
                return probedSchemes.map { ($0, false) }
            }
            return probedSchemes.map { scheme in
                guard let url = URL(string: "\(scheme)://") else {
                    return (scheme, false)
                }
                return (scheme, UIApplication.shared.canOpenURL(url))
            }
        }

        static func formattedSchemeProbeResults(_ results: [(scheme: String, available: Bool)]) -> String {
            results
                .map { "\($0.scheme)=\($0.available ? "available" : "missing")" }
                .joined(separator: ", ")
        }

        static func installedSchemes(from probeResults: [(scheme: String, available: Bool)]) -> Set<String> {
            Set(
                probeResults.compactMap { probe in
                    probe.available ? probe.scheme : nil
                }
            )
        }
    #endif

    static func recommendedProvider(
        for snapshot: HostCapabilitySnapshot,
        bundleInfo: ExternalJITBundleInfo,
        jitStreamerAddress: String,
        installedSchemes: Set<String>,
        requiresPersistentDebuggerCallback: Bool =
            JITPlatformCompatibility.requiresPersistentDebuggerCallback
    ) -> ExternalJITProvider? {
        if snapshot.jitSessionKind == .trollStorePrivate || snapshot.jitStatus == .ready {
            return nil
        }
        if requiresPersistentDebuggerCallback {
            if !installedSchemes.isDisjoint(with: ["stikjit", "stikdebug", "livecontainer2"]) {
                return .stikDebug
            }
            // AltJIT/JitStreamer/SideStore can establish CS_DEBUGGED, but do
            // not install StikDebug's persistent TXM region callback.
            return nil
        }
        if bundleInfo.isAltJITCompatible {
            return .altJIT
        }
        if normalizedJitStreamerAddress(jitStreamerAddress) != nil {
            return .jitStreamer
        }
        if !installedSchemes.isDisjoint(with: ["stikjit", "stikdebug", "livecontainer2"]) {
            return .stikDebug
        }
        if installedSchemes.contains("sidestore") {
            return .sideStore
        }
        if installedSchemes.contains("apple-magnifier") {
            return .trollStore
        }
        return nil
    }

    static func launchURL(
        for provider: ExternalJITProvider,
        bundleIdentifier: String,
        processIdentifier: pid_t,
        installedSchemes: Set<String>
    ) -> URL? {
        var components = URLComponents()
        switch provider {
        case .altJIT, .jitStreamer:
            return nil
        case .stikDebug:
            guard installedSchemes.contains("stikjit") else {
                return nil
            }
            components.scheme = "stikjit"
            components.host = "enable-jit"
            components.queryItems = [
                URLQueryItem(name: "bundle-id", value: bundleIdentifier),
                URLQueryItem(name: "pid", value: String(processIdentifier)),
            ]
        case .sideStore:
            guard installedSchemes.contains("sidestore") else {
                return nil
            }
            components.scheme = "sidestore"
            components.host = "sidejit-enable"
            components.queryItems = [
                URLQueryItem(name: "pid", value: String(processIdentifier))
            ]
        case .trollStore:
            guard installedSchemes.contains("apple-magnifier") else {
                return nil
            }
            components.scheme = "apple-magnifier"
            components.host = "enable-jit"
            components.queryItems = [
                URLQueryItem(name: "bundle-id", value: bundleIdentifier)
            ]
        }
        return components.url
    }
}

enum JITPlatformCompatibility {
    static var requiresPersistentDebuggerCallback: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
            var systemInfo = utsname()
            uname(&systemInfo)
            let hardwareIdentifier = withUnsafePointer(to: &systemInfo.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            return inferTXM(
                iOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                hardwareIdentifier: hardwareIdentifier
            )
        #else
            return false
        #endif
    }

    static func inferTXM(iOSMajorVersion: Int, hardwareIdentifier: String) -> Bool {
        if iOSMajorVersion >= 27 {
            return hardwareIdentifier != "iPad8,11" && hardwareIdentifier != "iPad8,12"
        }
        guard iOSMajorVersion == 26 else {
            return false
        }

        let prefix: String
        let threshold: (major: Int, minor: Int)
        if hardwareIdentifier.hasPrefix("iPhone") {
            prefix = "iPhone"
            threshold = (14, 2)
        } else if hardwareIdentifier.hasPrefix("iPad") {
            prefix = "iPad"
            threshold = (14, 5)
        } else {
            return false
        }

        let components = hardwareIdentifier.dropFirst(prefix.count).split(separator: ",")
        guard components.count == 2,
            let major = Int(components[0]),
            let minor = Int(components[1])
        else {
            return false
        }
        let divisor = pow(10.0, Double(String(minor).count))
        let version = Double(major) + (Double(minor) / divisor)
        let thresholdVersion = Double(threshold.major) + (Double(threshold.minor) / 10.0)
        return version >= thresholdVersion
    }
}
