#!/usr/bin/env python3
"""Regression check for automatic external-JIT failover after a route opens but never attaches."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
production = root / "MadeiraSupport" / "MadeiraAutomaticExternalJIT.swift"

harness = r'''
import Foundation

var debugged = false
func jit_check_debugged() -> Bool { debugged }

final class RuntimeLogCapture {
    static var lines: [String] = []
    static func writeLine(_ line: String) { lines.append(line) }
}

enum StikJITHelper {
    enum Route: String, CaseIterable {
        case automatic, livecontainer2, livecontainer, stikdebug
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .livecontainer2: return "LiveContainer2"
            case .livecontainer: return "LiveContainer"
            case .stikdebug: return "StikDebug"
            }
        }
    }
    static let routeKey = "IridiumAutomaticJITFailoverTestRoute"
    static var route: Route {
        Route(rawValue: UserDefaults.standard.string(forKey: routeKey) ?? "") ?? .automatic
    }
    static var started: [Route] = []
    static var pending: ((Bool) -> Void)?
    static var succeeds: Route?
    static var lastFailure = "stub route failed"

    static func enableJIT(completion: @escaping (Bool) -> Void) {
        let chosen = route
        started.append(chosen)
        if chosen == succeeds {
            completion(true)
        } else {
            pending = completion
        }
    }

    static func cancel() {
        let callback = pending
        pending = nil
        callback?(false)
    }
}

enum MadeiraLiveContainer3JIT {
    static var started = 0
    static var pending: ((Bool) -> Void)?
    static var succeeds = false
    static var lastFailure = "LiveContainer3 stub failed"

    static func enableJIT(completion: @escaping (Bool) -> Void) {
        started += 1
        if succeeds {
            completion(true)
        } else {
            pending = completion
        }
    }

    static func cancel() {
        let callback = pending
        pending = nil
        callback?(false)
    }
}

func runFor(_ seconds: Double) {
    RunLoop.current.run(until: Foundation.Date().addingTimeInterval(seconds))
}

func reset() {
    debugged = false
    RuntimeLogCapture.lines = []
    StikJITHelper.started = []
    StikJITHelper.pending = nil
    StikJITHelper.succeeds = nil
    MadeiraLiveContainer3JIT.started = 0
    MadeiraLiveContainer3JIT.pending = nil
    MadeiraLiveContainer3JIT.succeeds = false
}

let defaults = UserDefaults.standard
let previous = defaults.object(forKey: StikJITHelper.routeKey)
defer {
    MadeiraAutomaticExternalJIT.cancel()
    if let previous {
        defaults.set(previous, forKey: StikJITHelper.routeKey)
    } else {
        defaults.removeObject(forKey: StikJITHelper.routeKey)
    }
}

defaults.set("automatic", forKey: StikJITHelper.routeKey)

reset()
var results: [Bool] = []
MadeiraAutomaticExternalJIT.enableJIT(routeTimeout: 0.03) { results.append($0) }
assert(defaults.string(forKey: StikJITHelper.routeKey) == "automatic")
runFor(0.25)
assert(StikJITHelper.started == [.livecontainer2, .stikdebug, .livecontainer])
assert(MadeiraLiveContainer3JIT.started == 1)
assert(results == [false])
assert(MadeiraAutomaticExternalJIT.lastFailure.contains("none attached"))

reset()
results = []
StikJITHelper.succeeds = .stikdebug
MadeiraAutomaticExternalJIT.enableJIT(routeTimeout: 0.03) { results.append($0) }
runFor(0.12)
assert(StikJITHelper.started == [.livecontainer2, .stikdebug])
assert(MadeiraLiveContainer3JIT.started == 0)
assert(results == [true])
assert(defaults.string(forKey: StikJITHelper.routeKey) == "automatic")

reset()
results = []
MadeiraAutomaticExternalJIT.enableJIT(routeTimeout: 1.0) { results.append($0) }
MadeiraAutomaticExternalJIT.cancel()
runFor(0.05)
assert(StikJITHelper.started == [.livecontainer2])
assert(MadeiraLiveContainer3JIT.started == 0)
assert(results == [false])

print("PASS automatic JIT advances after open-without-attach, preserves route preference, and cancels cleanly")
'''

with tempfile.TemporaryDirectory() as directory:
    main = Path(directory) / "main.swift"
    binary = Path(directory) / "check"
    main.write_text(harness)
    subprocess.run(
        ["xcrun", "swiftc", str(production), str(main), "-o", str(binary)],
        check=True,
    )
    subprocess.run([str(binary)], check=True)
