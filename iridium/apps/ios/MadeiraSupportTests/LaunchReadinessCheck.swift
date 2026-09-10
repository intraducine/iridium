import Foundation

@main struct LaunchReadinessCheck {
    static func main() {
        func issue(_ available: Bool = true, _ executable: Bool = true, _ busy: Bool = false, _ started: Bool = false) -> String? {
            MadeiraLaunchReadiness.issue(runtimeAvailable: available, executableExists: executable, busy: busy, started: started)
        }
        precondition(issue() == nil)
        precondition(issue(false)?.contains("runtime is incomplete") == true)
        precondition(issue(true, false)?.contains("executable is missing") == true)
        precondition(issue(true, true, true, true)?.contains("Close the current game") == true)
        precondition(issue(true, true, false, true)?.contains("Restart Iridium") == true)
        print("PASS: Madeira launch availability, missing runtime/game, busy and restart")
    }
}
