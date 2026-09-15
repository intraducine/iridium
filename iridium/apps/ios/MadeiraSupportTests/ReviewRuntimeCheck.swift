import Foundation
@main struct RuntimeAdapterCheck {
    @MainActor static func main() async throws {
        defer { try? FileManager.default.removeItem(at: MadeiraGamePreparation.directory) }
        UserDefaults.standard.removeObject(forKey:"IridiumMadeiraTest")
        var failures:[String]=[]
        var reports:[String]=[]
        var exits=0
        MadeiraRuntimeAdapter.start(executable:"/fixture/game.exe",gameRoot:"/fixture",gameID:UUID(),arguments:["--name", "a b", "", "quote\""]) {
            reports.append($0)
        } fail: { failures.append($0) } exited: { exits += 1 }
        if scenario == "cancel-startup" {
            var closed:Bool?
            MadeiraRuntimeAdapter.requestClose { closed=$0 }
            let deadline=ProcessInfo.processInfo.systemUptime+5
            while closed == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds:10_000_000) }
            precondition(closed == true)
            try await Task.sleep(nanoseconds:100_000_000)
            precondition(NativeState.shared.startCount == 0 && !MadeiraController.active)
            print("PASS \(scenario): canceled worker cannot launch another guest")
            return
        }
        let until=ProcessInfo.processInfo.systemUptime+5
        while failures.isEmpty && reports.isEmpty && ProcessInfo.processInfo.systemUptime < until {
            try await Task.sleep(nanoseconds:10_000_000)
        }
        if scenario.contains("failure") || scenario == "server-died" {
            precondition(failures.count == 1, "terminal failure not reported exactly once: \(failures)")
            precondition(!MadeiraController.active && !MadeiraHardwareInput.acceptingInput)
            precondition(reports.isEmpty)
            print("PASS \(scenario): terminal failure callback and input cleanup")
            return
        }
        precondition(reports.count == 1 && failures.isEmpty, "startup did not report readiness: \(failures)")
        precondition(NativeState.shared.startCount == 1)
        if scenario == "exit-failure" { fatalError("unreachable") }
        if scenario == "process-exit" {
            NativeState.shared.write(2,0); NativeState.shared.write(0,0); NativeState.shared.write(1,0)
            try await Task.sleep(nanoseconds:400_000_000)
            precondition(exits == 1 && !MadeiraController.active)
        } else {
            var closed:Bool?
            MadeiraRuntimeAdapter.requestClose { closed=$0 }
            let deadline=ProcessInfo.processInfo.systemUptime+10
            while closed == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds:10_000_000) }
            if scenario == "close-timeout" {
                precondition(closed == false, "timeout incorrectly confirmed a running guest")
                precondition(wine_process_is_running() != 0)
                NativeState.shared.write(0,0); NativeState.shared.write(1,0)
                try await Task.sleep(nanoseconds:400_000_000)
                precondition(exits == 1, "monitor lost after close timeout")
            } else { precondition(closed == true) }
            MadeiraRuntimeAdapter.stop()
            precondition(!MadeiraController.active)
        }
        print("PASS \(scenario): native lifecycle signaling and bounded close")
    }
}
