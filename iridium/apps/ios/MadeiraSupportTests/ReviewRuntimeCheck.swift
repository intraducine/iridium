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
        while failures.isEmpty && (reports.isEmpty || NativeState.shared.startCount == 0) && ProcessInfo.processInfo.systemUptime < until {
            try await Task.sleep(nanoseconds:10_000_000)
        }
        if scenario.contains("failure") || scenario == "server-died" {
            precondition(failures.count == 1, "terminal failure not reported exactly once: \(failures)")
            precondition(!MadeiraController.active && !MadeiraHardwareInput.acceptingInput)
            precondition(reports.isEmpty)
            print("PASS \(scenario): terminal failure callback and input cleanup")
            return
        }
        precondition(!reports.isEmpty && failures.isEmpty, "startup did not report readiness: \(failures)")
        precondition(NativeState.shared.startCount == 1)
        if ["prerequisite-success", "prerequisite-cancel", "prerequisite-close-timeout", "prerequisite-nonzero-exit", "prerequisite-nonzero-close-timeout"].contains(scenario) {
            precondition(String(cString: getenv("MADEIRA_EXE")) == "C:\\helper.exe")
            precondition(String(cString: getenv("IRIDIUM_MADEIRA_ARGS_JSON")) == "[\"C:\\\\plan.ini\"]")
            precondition(String(cString: getenv("MADEIRA_GDI_SHARED_SECTION")) == "1")
            precondition(String(cString: getenv("MADEIRA_MADSYNC_SESSION")) == "0")
        } else {
            precondition(String(cString: getenv("MADEIRA_EXE")) == "C:\\IridiumGame\\game.exe")
        }
        if scenario == "exit-failure" { fatalError("unreachable") }
        if scenario == "prerequisite-nonzero-exit" {
            // The C helper tests separately prove failed installers cannot start the game.
            // Here the actual adapter must surface that helper's failure exactly once.
            NativeState.shared.write(2,5); NativeState.shared.write(0,0)
            let deadline=ProcessInfo.processInfo.systemUptime+5
            while failures.isEmpty && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds:10_000_000) }
            precondition(failures.count == 1 && failures[0].contains("exit code 5"))
            precondition(exits == 0 && !MadeiraController.active && !MadeiraHardwareInput.acceptingInput)
            let reportCountAfterFailure = reports.count
            NativeState.shared.write(1,0)
            try await Task.sleep(nanoseconds:400_000_000)
            precondition(failures.count == 1 && exits == 0 && reports.count == reportCountAfterFailure)
            precondition(NativeState.shared.startCount == 1 && MadeiraRuntimeAdapter.started)
            print("PASS \(scenario): helper failure reported once, input stopped, no success or relaunch")
            return
        }
        if scenario == "process-exit" {
            NativeState.shared.write(2,0); NativeState.shared.write(0,0); NativeState.shared.write(1,0)
            try await Task.sleep(nanoseconds:400_000_000)
            precondition(exits == 1 && !MadeiraController.active)
        } else {
            var closed:Bool?
            let reportCountBeforeClose = reports.count
            MadeiraRuntimeAdapter.requestClose { closed=$0 }
            let deadline=ProcessInfo.processInfo.systemUptime+10
            while closed == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds:10_000_000) }
            if scenario.hasSuffix("close-timeout") {
                precondition(closed == false, "timeout incorrectly confirmed a running guest")
                precondition(wine_process_is_running() != 0)
                precondition(exits == 0, "running guest reported as exited")
                precondition(reports.count == reportCountBeforeClose, "cancelled installer still reports status")
                if scenario.hasPrefix("prerequisite-") {
                    precondition(NativeState.shared.cancelCount >= 1)
                }
                if scenario == "prerequisite-nonzero-close-timeout" { NativeState.shared.write(2,5) }
                NativeState.shared.write(0,0); NativeState.shared.write(1,0)
                try await Task.sleep(nanoseconds:400_000_000)
                if scenario == "prerequisite-nonzero-close-timeout" {
                    precondition(failures.count == 1 && failures[0].contains("exit code 5"), "failure monitor lost after close timeout")
                    precondition(exits == 0 && NativeState.shared.startCount == 1)
                    precondition(!MadeiraController.active && !MadeiraHardwareInput.acceptingInput)
                } else { precondition(exits == 1, "monitor lost after close timeout") }
            } else { precondition(closed == true) }
            if scenario == "prerequisite-cancel" {
                try await Task.sleep(nanoseconds:100_000_000)
                precondition(NativeState.shared.cancelCount >= 1)
            }
            MadeiraRuntimeAdapter.stop()
            precondition(!MadeiraController.active)
        }
        print("PASS \(scenario): native lifecycle signaling and bounded close")
    }
}
