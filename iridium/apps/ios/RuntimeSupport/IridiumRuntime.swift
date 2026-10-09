// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum IridiumPlatform: String, Codable, CaseIterable, Sendable {
    case windows, gameBoy, gameBoyColor
    var title: String {
        switch self { case .windows: return "Windows"; case .gameBoy: return "Game Boy"; case .gameBoyColor: return "Game Boy Color" }
    }
}

enum IridiumExecutionMode: String, Codable, Sendable { case interpreter, jit }
enum IridiumJITRequirement: String, Codable, Sendable { case none, optional, required }

struct IridiumRuntimeDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let platforms: Set<IridiumPlatform>
    let jit: IridiumJITRequirement
    let supportsPause: Bool
    let restartAfterStop: Bool

    func executionMode(jitAvailable: Bool) throws -> IridiumExecutionMode {
        switch jit {
        case .none: return .interpreter
        case .optional: return jitAvailable ? .jit : .interpreter
        case .required:
            guard jitAvailable else { throw IridiumRuntimeError.jitRequired }
            return .jit
        }
    }
}

enum IridiumRuntimeRegistry {
    // Only linked and implemented runtimes belong here. Research candidates
    // are deliberately absent from the import UI and compatibility claims.
    static let madeira = IridiumRuntimeDescriptor(id: "madeira", name: "Madeira", platforms: [.windows],
        jit: .required, supportsPause: false, restartAfterStop: true)
    static let sameBoy = IridiumRuntimeDescriptor(id: "sameboy", name: "SameBoy", platforms: [.gameBoy, .gameBoyColor],
        jit: .none, supportsPause: true, restartAfterStop: false)
    static let all = [madeira, sameBoy]
    static func compatible(with platform: IridiumPlatform) -> [IridiumRuntimeDescriptor] {
        all.filter { $0.platforms.contains(platform) }
    }
    static func resolve(platform: IridiumPlatform, preferred: String?) throws -> IridiumRuntimeDescriptor {
        let choices = compatible(with: platform)
        if let preferred {
            guard let runtime = choices.first(where: { $0.id == preferred }) else { throw IridiumRuntimeError.unavailable }
            return runtime
        }
        guard let runtime = choices.first else { throw IridiumRuntimeError.unavailable }
        return runtime
    }
}

enum IridiumRuntimeError: LocalizedError {
    case unavailable, unsupportedOperation, jitRequired, busy, restartRequired, invalidGame, unsafePath, newerLibrary, unreadableLibrary
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The selected runtime is not available for this game. Choose an installed compatible runtime."
        case .unsupportedOperation: return "This runtime does not support that operation."
        case .jitRequired: return "This runtime needs JIT. Enable it before launching this game."
        case .busy: return "Another runtime is starting or running. Stop it before launching another game."
        case .restartRequired: return "Windows runtime state is still loaded. Fully close and reopen Iridium before changing runtimes."
        case .invalidGame: return "Choose an uncompressed Game Boy (.gb) or Game Boy Color (.gbc) ROM, up to 8 MB."
        case .unsafePath: return "The game or save path is outside its runtime folder or uses a symbolic link."
        case .newerLibrary: return "This runtime library uses a newer format. Its original file has been preserved."
        case .unreadableLibrary: return "The runtime library could not be read. Its original file has been preserved."
        }
    }
}

enum IridiumRuntimeState: Sendable { case idle, starting, running, paused, stopping, restartRequired }

/// Runtime-specific app models never cross this frontend-facing boundary.
/// Surface, controller and save implementations belong to each driver, while
/// the shared library chooses drivers from the capability registry.
@MainActor protocol IridiumRuntimeDriver {
    var descriptor: IridiumRuntimeDescriptor { get }
    var state: IridiumRuntimeState { get }
    func launch(gameID: UUID) throws
    func pause() throws
    func resume() throws
    func stop()
}

/// One owner across asynchronous start/stop. Stale callbacks cannot release a
/// newer launch. A runtime that cannot unload must explicitly require restart.
struct IridiumRuntimeLease: Equatable, Sendable {
    let token: UUID
    let runtimeID: String
}

struct IridiumRuntimeOwnership {
    private(set) var lease: IridiumRuntimeLease?
    private(set) var requiresRestart = false
    mutating func acquire(_ runtime: IridiumRuntimeDescriptor) throws -> IridiumRuntimeLease {
        guard !requiresRestart else { throw IridiumRuntimeError.restartRequired }
        guard lease == nil else { throw IridiumRuntimeError.busy }
        let next = IridiumRuntimeLease(token: UUID(), runtimeID: runtime.id)
        lease = next
        return next
    }
    mutating func release(_ owner: IridiumRuntimeLease, restart: Bool = false) {
        guard lease == owner else { return }
        lease = nil
        requiresRestart = restart
    }
}

struct IridiumConsoleGame: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let platform: IridiumPlatform
    var runtimeID: String
    let fileExtension: String
    let importedAt: Date

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 512,
              [.gameBoy, .gameBoyColor].contains(platform), ["gb", "gbc"].contains(fileExtension)
        else { throw IridiumRuntimeError.invalidGame }
        _ = try IridiumRuntimeRegistry.resolve(platform: platform, preferred: runtimeID)
    }
}

/// This additive library never rewrites Madeira's library or Wine prefixes.
/// Removing a record retains its ROM and saves. Unknown versions fail closed.
struct IridiumConsoleStore {
    let root: URL
    private let manager = FileManager.default
    private struct Document: Codable { let version: Int; let games: [IridiumConsoleGame] }

    func checked(_ components: [String], createDirectory: Bool = false) throws -> URL {
        let normalized = root.standardizedFileURL
        guard normalized.resolvingSymlinksInPath().path == normalized.path else { throw IridiumRuntimeError.unsafePath }
        var url = normalized
        for component in components {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/"), !component.contains("\\")
            else { throw IridiumRuntimeError.unsafePath }
            url.appendPathComponent(component)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw IridiumRuntimeError.unsafePath
            }
        }
        if createDirectory { try manager.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    func load() throws -> [IridiumConsoleGame] {
        let url = try checked(["library.json"])
        guard manager.fileExists(atPath: url.path) else { return [] }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url)) }
        catch { throw IridiumRuntimeError.unreadableLibrary }
        guard document.version == 1 else { throw IridiumRuntimeError.newerLibrary }
        guard Set(document.games.map(\.id)).count == document.games.count else { throw IridiumRuntimeError.unreadableLibrary }
        for game in document.games { try game.validate() }
        return document.games
    }

    func save(_ games: [IridiumConsoleGame]) throws {
        // Never overwrite a corrupt/future document, including one changed by
        // another writer since the UI loaded. The caller owns serialization.
        _ = try load()
        guard Set(games.map(\.id)).count == games.count else { throw IridiumRuntimeError.unreadableLibrary }
        for game in games { try game.validate() }
        _ = try checked([], createDirectory: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: 1, games: games)).write(to: checked(["library.json"]), options: .atomic)
    }

    func rom(_ game: IridiumConsoleGame) throws -> URL {
        try game.validate()
        return try checked(["Games", game.id.uuidString, "game." + game.fileExtension])
    }

    func saveDirectory(_ game: IridiumConsoleGame) throws -> URL {
        try game.validate()
        return try checked(["Saves", game.runtimeID, game.id.uuidString], createDirectory: true)
    }

    func importROM(_ source: URL, into games: [IridiumConsoleGame]) throws -> IridiumConsoleGame {
        _ = try load()
        let ext = source.pathExtension.lowercased()
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard ["gb", "gbc"].contains(ext), values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0x150, size <= 8 * 1024 * 1024 else { throw IridiumRuntimeError.invalidGame }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 0x150), header.count == 0x150 else { throw IridiumRuntimeError.invalidGame }
        let platform: IridiumPlatform = [0x80, 0xc0].contains(header[0x143]) ? .gameBoyColor : .gameBoy
        let game = IridiumConsoleGame(id: UUID(), title: String(source.deletingPathExtension().lastPathComponent.prefix(128)),
            platform: platform, runtimeID: "sameboy", fileExtension: ext, importedAt: Date())
        let directory = try checked(["Games", game.id.uuidString], createDirectory: true)
        let target = try rom(game)
        // Copy without overwrite; the source and its parent directories remain
        // untouched. Check size again after copy to catch a changing provider.
        try manager.copyItem(at: source, to: target)
        let copied = try target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard copied.fileSize == size, copied.isRegularFile == true, copied.isSymbolicLink != true else {
            throw IridiumRuntimeError.invalidGame
        }
        _ = directory // Retain an unlisted copy on persistence failure for recovery.
        try save(games + [game])
        return game
    }
}
