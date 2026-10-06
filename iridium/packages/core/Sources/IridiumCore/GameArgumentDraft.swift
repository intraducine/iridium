import Foundation

public enum GameArgumentEditError: LocalizedError {
    case gameMissing, busy, stale, invalidArgument, verificationFailed, recoveryFailed
    public var errorDescription: String? {
        switch self {
        case .gameMissing: "This game is no longer in the library."
        case .busy: "Stop the game and finish pending game operations before changing arguments."
        case .stale: "The game's launch settings changed. Cancel and reopen the editor."
        case .invalidArgument: "An argument cannot contain a null character."
        case .verificationFailed: "The saved arguments could not be verified. Your previous settings were restored."
        case .recoveryFailed: "The saved settings could not be confirmed. Reopen Iridium before trying again."
        }
    }
}

// A draft changes no library state. Each row is exactly one argv value, including
// an empty value; it never trims, tokenizes, unquotes, or interprets shell syntax.
public struct GameArgumentDraft: Sendable {
    public struct Row: Identifiable, Sendable {
        public let id: UUID
        public var value: String
        public init(id: UUID = UUID(), value: String) { self.id = id; self.value = value }
    }
    public let gameID: UUID
    private let profileID: UUID
    private let executablePath: String
    private let originalArguments: [String]
    public var rows: [Row]
    public init(game: GameRecord) {
        gameID = game.id
        profileID = game.launchProfile.id
        executablePath = game.launchProfile.executablePath
        originalArguments = game.launchProfile.arguments
        rows = originalArguments.map { Row(value: $0) }
    }
    public func isCurrent(for game: GameRecord) -> Bool {
        game.id == gameID && game.launchProfile.id == profileID
            && Array(game.launchProfile.executablePath.utf8) == Array(executablePath.utf8)
            && game.launchProfile.arguments.map { Array($0.utf8) } == originalArguments.map { Array($0.utf8) }
    }
    public func applying(to game: GameRecord) throws -> GameRecord {
        guard isCurrent(for: game) else { throw GameArgumentEditError.stale }
        let values = rows.map(\.value)
        guard !values.contains(where: { $0.utf8.contains(0) }) else { throw GameArgumentEditError.invalidArgument }
        var updated = game
        updated.launchProfile.arguments = values
        return updated
    }
}
