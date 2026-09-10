import Foundation

// Launch eligibility is separate from proof that a game renders or plays correctly.
enum MadeiraLaunchReadiness {
    static func issue(runtimeAvailable: Bool, executableExists: Bool, busy: Bool, started: Bool) -> String? {
        if busy { return "Close the current game before choosing another game." }
        if started { return "Restart Iridium before starting another game. The runtime cannot start a second session in the same app process yet." }
        if !runtimeAvailable { return "The bundled runtime is incomplete. Reinstall Iridium." }
        if !executableExists { return "The game executable is missing. Import the game again." }
        return nil
    }
}
