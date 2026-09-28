import Foundation
import CoreFoundation

@main
struct LaunchEntitlementsCheck {
    static func main() {
        typealias Check = MadeiraLaunchEntitlements
        precondition(Check.presence(value: kCFBooleanTrue, queryFailed: false) == .present)
        precondition(Check.presence(value: kCFBooleanFalse, queryFailed: false) == .absent)
        precondition(Check.presence(value: nil, queryFailed: false) == .absent)
        precondition(Check.presence(value: nil, queryFailed: true) == .unknown)
        precondition(Check.presence(value: kCFBooleanTrue, queryFailed: true) == .unknown)
        precondition(Check.presence(value: NSNumber(value: 1), queryFailed: false) == .unknown)
        precondition(Check.presence(value: "true" as NSString, queryFailed: false) == .unknown)

        for hosted in [false, true] {
            for memory in [Check.Presence.present, .absent, .unknown] {
                for addressSpace in [Check.Presence.present, .absent, .unknown] {
                    var queried: [String] = []
                    let lines = Check.logLines(isHosted: hosted) { key in
                        queried.append(key)
                        return key == Check.keys[0] ? memory : addressSpace
                    }
                    precondition(queried == Check.keys)
                    precondition(lines.count == 3)
                    let environment = hosted ? "livecontainer" : "standalone"
                    let subject = hosted ? "livecontainer-host-process" : "iridium-process"
                    precondition(lines[0] == "[Launch] Runtime entitlements: environment=\(environment) subject=\(subject)")
                    precondition(lines[1] == "[Launch] Entitlement \(Check.keys[0])=\(memory.rawValue)")
                    precondition(lines[2] == "[Launch] Entitlement \(Check.keys[1])=\(addressSpace.rawValue)")
                }
            }
        }
        // Each launch reads again instead of reusing a cached or configured value.
        var calls = 0
        for _ in 0..<2 {
            _ = Check.logLines(isHosted: true) { _ in calls += 1; return .present }
        }
        precondition(calls == 4)
        #if !os(iOS) || targetEnvironment(simulator)
        for key in Check.keys {
            precondition(Check.currentProcessPresence(key) == .unknown)
        }
        #endif
        print("Launch entitlement checks passed")
    }
}
