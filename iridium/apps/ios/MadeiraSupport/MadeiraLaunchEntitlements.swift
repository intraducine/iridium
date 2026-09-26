import Foundation
import CoreFoundation

#if os(iOS) && !targetEnvironment(simulator)
import Darwin
import Security
#endif

// Diagnostics only: the running task owns these entitlements, not the guest IPA.
// Their presence does not establish JIT readiness or guarantee an allocation.
enum MadeiraLaunchEntitlements {
    enum Presence: String {
        case present, absent, unknown
    }

    static let keys = [
        "com.apple.developer.kernel.increased-memory-limit",
        "com.apple.developer.kernel.extended-virtual-addressing"
    ]

    static func logLines(
        isHosted: Bool,
        read: (String) -> Presence = currentProcessPresence
    ) -> [String] {
        let environment = isHosted ? "livecontainer" : "standalone"
        let subject = isHosted ? "livecontainer-host-process" : "iridium-process"
        return ["[Launch] Runtime entitlements: environment=\(environment) subject=\(subject)"]
            + keys.map { "[Launch] Entitlement \($0)=\(read($0).rawValue)" }
    }

    static func presence(value: CFTypeRef?, queryFailed: Bool) -> Presence {
        guard !queryFailed else { return .unknown }
        guard let value else { return .absent }
        // Do not treat an integer or string as a granted Boolean entitlement.
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return .unknown }
        return CFEqual(value, kCFBooleanTrue) ? .present : .absent
    }

    private typealias CreateTask = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias CopyEntitlement = @convention(c) (
        CFTypeRef, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFTypeRef>?

    static func currentProcessPresence(_ key: String) -> Presence {
        #if os(iOS) && !targetEnvironment(simulator)
        // These Security APIs are also used by Iridium's existing JIT checks.
        // Resolve them defensively so a diagnostic cannot prevent app startup.
        guard let security = dlopen(
            "/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY
        ) else { return .unknown }
        defer { dlclose(security) }
        guard let createSymbol = dlsym(security, "SecTaskCreateFromSelf"),
              let copySymbol = dlsym(security, "SecTaskCopyValueForEntitlement")
        else { return .unknown }
        let createTask = unsafeBitCast(createSymbol, to: CreateTask.self)
        let copyEntitlement = unsafeBitCast(copySymbol, to: CopyEntitlement.self)
        guard let task = createTask(nil)?.takeRetainedValue() else { return .unknown }
        var error: Unmanaged<CFError>?
        let value = copyEntitlement(task, key as CFString, &error)?.takeRetainedValue()
        let queryError = error?.takeRetainedValue()
        return presence(value: value, queryFailed: queryError != nil)
        #else
        // A simulator or host test cannot report the installed iOS app's rights.
        return .unknown
        #endif
    }
}
