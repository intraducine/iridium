// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum IridiumPlatform: String, Codable, CaseIterable, Sendable {
    case windows, gameBoy, gameBoyColor, psp, gameCube, wii, nintendo3DS, playStation2, dreamcast, arcade
    var isPhase3: Bool { ![Self.windows, .gameBoy, .gameBoyColor, .psp].contains(self) }
    var title: String {
        switch self {
        case .windows: return "Windows"
        case .gameBoy: return "Game Boy"
        case .gameBoyColor: return "Game Boy Color"
        case .psp: return "PSP"
        case .gameCube: return "GameCube"
        case .wii: return "Wii"
        case .nintendo3DS: return "Nintendo 3DS"
        case .playStation2: return "PlayStation 2"
        case .dreamcast: return "Dreamcast"
        case .arcade: return "Arcade (Flycast)"
        }
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
    static let ppsspp = IridiumRuntimeDescriptor(id: "ppsspp", name: "PPSSPP", platforms: [.psp],
        jit: .optional, supportsPause: true, restartAfterStop: false)
    static let dolphin = IridiumRuntimeDescriptor(id: "dolphin", name: "Dolphin", platforms: [.gameCube, .wii],
        jit: .required, supportsPause: true, restartAfterStop: false)
    static let azahar = IridiumRuntimeDescriptor(id: "azahar", name: "Azahar", platforms: [.nintendo3DS],
        jit: .required, supportsPause: true, restartAfterStop: false)
    static let play = IridiumRuntimeDescriptor(id: "play", name: "Play!", platforms: [.playStation2],
        jit: .required, supportsPause: true, restartAfterStop: false)
    static let flycast = IridiumRuntimeDescriptor(id: "flycast", name: "Flycast", platforms: [.dreamcast, .arcade],
        jit: .required, supportsPause: true, restartAfterStop: false)
    #if IRIDIUM_PHASE3 && IRIDIUM_PPSSPP
    static let all = [madeira, sameBoy, ppsspp, dolphin, azahar, play, flycast]
    #elseif IRIDIUM_PPSSPP
    static let all = [madeira, sameBoy, ppsspp]
    #else
    static let all = [madeira, sameBoy]
    #endif
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
        case .restartRequired: return "A runtime is still loaded. Fully close and reopen Iridium before changing runtimes."
        case .invalidGame: return "This game file could not be read. Choose the original game file or its complete game folder."
        case .unsafePath: return "The game or save path is outside its runtime folder or uses a symbolic link."
        case .newerLibrary: return "This runtime library uses a newer format. Its original file has been preserved."
        case .unreadableLibrary: return "The runtime library could not be read. Its original file has been preserved."
        }
    }
}

/// One catalog drives system discovery, setup guidance and Files filtering.
/// Availability follows the shipping registry, including builds without Phase 3.
struct IridiumConsoleSystem: Identifiable {
    let runtime: IridiumRuntimeDescriptor
    let title: String
    let primaryPlatform: IridiumPlatform
    let extensions: [String]
    let guidance: String
    var id: String { runtime.id }
    var platforms: [IridiumPlatform] { IridiumPlatform.allCases.filter { runtime.platforms.contains($0) } }
    var subtitle: String { platforms.map(\.title).joined(separator: " · ") }
    var importPlatforms: [IridiumPlatform] { platforms.filter { $0 != .gameBoyColor } }
    var storageGuidance: String {
        let root = "Files → Iridium → IridiumRuntimes. "
        switch id {
        case "azahar": return root + "Each game's Saves/azahar folder contains its Azahar user tree. Supply any required NAND/system data in that per-game Azahar tree."
        case "flycast": return root + "Per-game saves are in Saves/flycast. User-supplied BIOS and supporting system files go in System/flycast/dc, with their required upstream filenames."
        default: return root + "Saves/\(id) contains each game's saves and configuration. Removing a library entry keeps these files."
        }
    }
    func formats(for platform: IridiumPlatform) -> [String] {
        if platform == .wii { return extensions.filter { $0 != "gcm" } }
        if platform == .gameCube { return extensions.filter { $0 != "wad" } }
        if platform == .arcade { return ["zip"] }
        if platform == .dreamcast { return extensions.filter { $0 != "zip" } }
        return extensions
    }
    static var all: [Self] {
        IridiumRuntimeRegistry.all.compactMap { runtime in
            switch runtime.id {
            case "sameboy": return Self(runtime: runtime, title: "SameBoy · Game Boy / Color", primaryPlatform: .gameBoy,
                extensions: ["gb", "gbc"], guidance: "Game Boy and Game Boy Color games use SameBoy.")
            case "ppsspp": return Self(runtime: runtime, title: "PPSSPP · PSP", primaryPlatform: .psp,
                extensions: ["elf", "iso", "cso", "pbp"], guidance: "PSP games use PPSSPP. Open a game's menu for display and save-state options.")
            case "dolphin": return Self(runtime: runtime, title: "Dolphin · GameCube / Wii", primaryPlatform: .gameCube,
                extensions: ["dol", "gcm", "iso", "rvz", "wad"], guidance: "GameCube and Wii games use Dolphin and the shared JIT system.")
            case "azahar": return Self(runtime: runtime, title: "Azahar · Nintendo 3DS", primaryPlatform: .nintendo3DS,
                extensions: ["3dsx", "3ds", "cci", "cxi", "app"], guidance: "Nintendo 3DS games use Azahar. Use an unencrypted game file.")
            case "play": return Self(runtime: runtime, title: "Play! · PlayStation 2", primaryPlatform: .playStation2,
                extensions: ["elf", "iso", "chd", "cue"], guidance: "PlayStation 2 games use Play!. Open the game menu for core settings, save states, and disc changes.")
            case "flycast": return Self(runtime: runtime, title: "Flycast · Dreamcast / Arcade", primaryPlatform: .dreamcast,
                extensions: ["elf", "cdi", "chd", "gdi", "cue", "zip"], guidance: "Dreamcast and arcade games use Flycast.")
            default: return nil
            }
        }
    }
    static func system(for platform: IridiumPlatform) -> Self? { all.first { $0.runtime.platforms.contains(platform) } }
    static func system(titled title: String) -> Self? { all.first { $0.title == title } }
}

enum IridiumRuntimeState: Sendable { case idle, starting, running, paused, stopping, restartRequired }

/// The session protects this value with its lock, including while boot is in
/// progress. Stop wins over a late resume or pause until a new launch resets it.
struct IridiumConsoleIntent: Sendable {
    enum Request: Sendable { case play, pause, stop }
    private(set) var request: Request = .play
    mutating func pause() { if request != .stop { request = .pause } }
    mutating func resume() { if request != .stop { request = .play } }
    mutating func stop() { request = .stop }
}

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
    // Missing in existing version-1 records; nil deliberately means off.
    var pspJIT: Bool? = nil
    var originalFilename: String? = nil // Arcade set names are part of Flycast's loader protocol.
    var storageOwnerID: UUID? = nil
    var installedPath: String? = nil
    var pspJITEnabled: Bool { platform == .psp && pspJIT == true }

    func validate() throws {
        if let path = installedPath {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard runtimeID == "azahar", platform == .nintendo3DS, fileExtension == "app", storageOwnerID != nil,
                  path.utf8.count <= 4096, parts.count <= 32,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") })
            else { throw IridiumRuntimeError.unsafePath }
        } else if storageOwnerID != nil { throw IridiumRuntimeError.unsafePath }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 512
        else { throw IridiumRuntimeError.invalidGame }
        // Durable record validity is independent of the runtimes linked into
        // this build. Opening an older build must not poison a mixed library.
        switch platform {
        case .gameBoy, .gameBoyColor:
            guard runtimeID == "sameboy", ["gb", "gbc"].contains(fileExtension) else { throw IridiumRuntimeError.invalidGame }
        case .psp:
            guard runtimeID == "ppsspp", ["elf", "iso", "cso", "pbp"].contains(fileExtension) else { throw IridiumRuntimeError.invalidGame }
        case .gameCube, .wii:
            guard runtimeID == "dolphin", ["dol", "gcm", "iso", "rvz", "wad"].contains(fileExtension),
                  fileExtension != "wad" || platform == .wii else { throw IridiumRuntimeError.invalidGame }
        case .nintendo3DS:
            guard runtimeID == "azahar", ["3dsx", "3ds", "cci", "cxi", "app"].contains(fileExtension) else { throw IridiumRuntimeError.invalidGame }
        case .playStation2:
            guard runtimeID == "play", ["elf", "iso", "chd", "cue"].contains(fileExtension) else { throw IridiumRuntimeError.invalidGame }
        case .dreamcast:
            guard runtimeID == "flycast", ["elf", "cdi", "chd", "gdi", "cue"].contains(fileExtension) else { throw IridiumRuntimeError.invalidGame }
        case .arcade:
            guard runtimeID == "flycast", fileExtension == "zip", let name = originalFilename,
                  name.utf8.count <= 255, !name.contains("/"), !name.contains("\\"),
                  !name.hasPrefix("."), name.lowercased().hasSuffix(".zip") else { throw IridiumRuntimeError.invalidGame }
        case .windows: throw IridiumRuntimeError.invalidGame
        }
        if let name = originalFilename {
            guard !name.isEmpty, name.utf8.count <= 255, !name.hasPrefix("."), !name.contains("/"),
                  !name.contains("\\"), !name.contains("\0") else { throw IridiumRuntimeError.unsafePath }
        }
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
        if let relative = game.installedPath, let owner = game.storageOwnerID {
            return try checked(["Saves", "azahar", owner.uuidString, "Azahar"] + relative.split(separator: "/").map(String.init))
        }
        return try checked(["Games", game.id.uuidString, game.originalFilename ?? "game." + game.fileExtension])
    }

    /// Recheck the private copy at each launch. This is bounded structural
    /// validation, not a claim that a game is compatible or safe to execute.
    func validateROM(_ game: IridiumConsoleGame) throws -> URL {
        let url = try rom(game)
        let inspected = try IridiumROMInspection.inspect(url, fileExtension: game.fileExtension, preferredPlatform: game.platform)
        guard inspected.platform == game.platform else { throw IridiumRuntimeError.invalidGame }
        return url
    }

    func saveDirectory(_ game: IridiumConsoleGame) throws -> URL {
        try game.validate()
        let directory = try checked(["Saves", game.runtimeID, (game.storageOwnerID ?? game.id).uuidString], createDirectory: true)
        if game.platform == .psp || game.platform.isPhase3 {
            // PPSSPP owns a nested memory-stick tree. A safe root alone does
            // not prevent an existing PSP/SAVEDATA link from escaping it.
            var enumerationError: Error?
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
            guard let entries = manager.enumerator(at: directory, includingPropertiesForKeys: keys,
                errorHandler: { _, error in enumerationError = error; return false }) else { throw IridiumRuntimeError.unsafePath }
            var count = 0
            for case let entry as URL in entries {
                count += 1
                guard count <= 100_000 else { throw IridiumRuntimeError.unsafePath }
                let values = try entry.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true
                else { throw IridiumRuntimeError.unsafePath }
            }
            if let enumerationError { throw enumerationError }
        }
        return directory
    }

    func systemDirectory(_ game: IridiumConsoleGame) throws -> URL {
        try game.validate()
        let directory = try checked(["System", game.runtimeID], createDirectory: true)
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        var failure: Error?
        guard let contents = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in failure = error; return false }) else { throw IridiumRuntimeError.unsafePath }
        var count = 0
        for case let path as URL in contents {
            count += 1
            let values = try path.resourceValues(forKeys: keys)
            guard count <= 100_000, values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else { throw IridiumRuntimeError.unsafePath }
        }
        if let failure { throw failure }
        return directory
    }

    func importROM(_ source: URL, into games: [IridiumConsoleGame], preferredPlatform: IridiumPlatform? = nil,
                   selectedFiles: [URL] = []) throws -> IridiumConsoleGame {
        _ = try load()
        let ext = source.pathExtension.lowercased()
        let disc = ["gdi", "cue"].contains(ext) ? try IridiumDiscSet(source, selectedFiles: selectedFiles) : nil
        let inspected = try IridiumROMInspection.inspect(source, fileExtension: ext, preferredPlatform: preferredPlatform)
        let platform = inspected.platform
        if let preferredPlatform {
            let gameBoy = Set([IridiumPlatform.gameBoy, .gameBoyColor])
            guard platform == preferredPlatform || (gameBoy.contains(platform) && gameBoy.contains(preferredPlatform))
            else { throw IridiumRuntimeError.invalidGame }
        }
        let runtime = try IridiumRuntimeRegistry.resolve(platform: platform, preferred: nil)
        var game = IridiumConsoleGame(id: UUID(), title: String(source.deletingPathExtension().lastPathComponent.prefix(128)),
            platform: platform, runtimeID: runtime.id, fileExtension: ext, importedAt: Date())
        if platform == .arcade || disc != nil { game.originalFilename = source.lastPathComponent }
        let directory = try checked(["Games", game.id.uuidString], createDirectory: true)
        let target = try rom(game)
        // Copy without overwrite; the source and its parent directories remain
        // untouched. The caller coordinates provider access. Revalidate both
        // path ancestry and every inspected header in the copied file.
        let checkedSource = try IridiumROMInspection.checkedFile(source)
        try manager.copyItem(at: checkedSource, to: target)
        if let disc {
            for name in disc.filenames {
                let components = name.split(separator: "/").map(String.init)
                _ = try checked(["Games", game.id.uuidString] + Array(components.dropLast()), createDirectory: true)
                try manager.copyItem(at: IridiumROMInspection.checkedFile(source.deletingLastPathComponent().appendingPathComponent(name)),
                                     to: checked(["Games", game.id.uuidString] + components))
            }
        }
        let copied = try IridiumROMInspection.inspect(try rom(game), fileExtension: ext, preferredPlatform: platform)
        guard copied == inspected else {
            throw IridiumRuntimeError.invalidGame
        }
        _ = directory // Retain an unlisted copy on persistence failure for recovery.
        try save(games + [game])
        return game
    }
}

/// Only small headers are read, even for multi-gigabyte provider files. These
/// checks deliberately do not decompress a disc or load executable payloads.
struct IridiumROMInspection: Equatable {
    let platform: IridiumPlatform
    let size: UInt64
    let headers: Data
    private static let maximumDiscSize: UInt64 = 2 * 1024 * 1024 * 1024

    static func checkedFile(_ source: URL) throws -> URL {
        guard source.isFileURL else { throw IridiumRuntimeError.unsafePath }
        let url = source.standardizedFileURL
        // Checking only the leaf misses links in an ancestor directory.
        guard url.resolvingSymlinksInPath().path == url.path else { throw IridiumRuntimeError.unsafePath }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw IridiumRuntimeError.invalidGame }
        return url
    }

    static func inspect(_ source: URL, fileExtension ext: String, preferredPlatform: IridiumPlatform? = nil) throws -> Self {
        guard ["gb", "gbc", "elf", "iso", "cso", "pbp", "dol", "gcm", "rvz", "wad", "3dsx", "3ds", "cci", "cxi", "app", "cdi", "chd", "zip", "gdi", "cue"].contains(ext) else { throw IridiumRuntimeError.invalidGame }
        let url = try checkedFile(source)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let limit: UInt64 = ["gb", "gbc"].contains(ext) ? 8 * 1024 * 1024 : (ext == "elf" || ext == "dol" || ext == "3dsx" ? 128 * 1024 * 1024 : 16 * 1024 * 1024 * 1024)
        guard size > 0, size <= limit else { throw IridiumRuntimeError.invalidGame }
        var reader = HeaderReader(handle: handle, size: size)
        let platform: IridiumPlatform
        switch ext {
        case "gb", "gbc":
            // Preserve the existing Game Boy acceptance and color detection.
            let header = try reader.read(0, 0x150)
            platform = [0x80, 0xc0].contains(header[0x143]) ? .gameBoyColor : .gameBoy
        case "elf":
            let header = try reader.read(0, 52)
            if little(header, 18, 2) == 42 {
                try reader.validateELF(at: 0, length: size, machine: 42)
                platform = .dreamcast
            } else {
                try reader.validateELF(at: 0, length: size)
                let flags = little(header, 36, 4)
                let ps2 = flags & 0x00ff0000 == 0x00920000, psp = flags & 0xffff0000 == 0x10a20000
                platform = ps2 || (!psp && preferredPlatform == .playStation2) ? .playStation2 : .psp
            }
        case "iso":
            guard size % 2048 == 0 else { throw IridiumRuntimeError.invalidGame }
            let disc = try reader.read(0, 32)
            if big(disc, 28, 4) == 0xc2339f3d { platform = .gameCube; break }
            if big(disc, 24, 4) == 0x5d1c9ea3 { platform = .wii; break }
            let header = try reader.read(16 * 2048, 2048)
            let system = String(decoding: header[8..<40], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            let sectors = little(header, 80, 4)
            guard header[0] == 1, header[1..<6].elementsEqual("CD001".utf8), header[6] == 1,
                  system == "PSP GAME" || system == "\"PSP GAME\"" || system == "PLAYSTATION",
                  little(header, 128, 2) == 2048, big(header, 130, 2) == 2048,
                  sectors >= 17, sectors == big(header, 84, 4), sectors <= size / 2048
            else { throw IridiumRuntimeError.invalidGame }
            platform = system == "PLAYSTATION" ? .playStation2 : .psp
        case "dol":
            let header = try reader.read(0, 0x100)
            var sections = 0
            for index in 0..<18 {
                let offset = big(header, index * 4, 4), length = big(header, 0x90 + index * 4, 4)
                if length == 0 { continue }
                guard offset >= 0x100, offset <= size, length <= size - offset else { throw IridiumRuntimeError.invalidGame }
                sections += 1
            }
            guard sections > 0, big(header, 0xe0, 4) >= 0x80000000 else { throw IridiumRuntimeError.invalidGame }
            platform = preferredPlatform == .wii ? .wii : .gameCube
        case "wad":
            let header = try reader.read(0, 32)
            guard big(header, 0, 4) == 32, big(header, 4, 2) == 0x4973,
                  big(header, 16, 4) >= 0x2a4, big(header, 20, 4) >= 0x1e4 else { throw IridiumRuntimeError.invalidGame }
            var end: UInt64 = 64
            for offset in [8, 12, 16, 20, 24, 28] {
                let length = big(header, offset, 4)
                guard end <= size, length <= size - end else { throw IridiumRuntimeError.invalidGame }
                end += (length + 63) & ~63
            }
            platform = .wii
        case "gcm":
            let header = try reader.read(0, 32)
            guard big(header, 28, 4) == 0xc2339f3d else { throw IridiumRuntimeError.invalidGame }
            platform = .gameCube
        case "rvz":
            let header = try reader.read(0, 0x48)
            guard header.prefix(4).elementsEqual([0x52, 0x56, 0x5a, 1]), big(header, 12, 4) >= 0xc4 else { throw IridiumRuntimeError.invalidGame }
            let disc = try reader.read(0x48, 48)
            if big(disc, 0, 4) == 1, big(disc, 44, 4) == 0xc2339f3d { platform = .gameCube }
            else if big(disc, 0, 4) == 2, big(disc, 40, 4) == 0x5d1c9ea3 { platform = .wii }
            else { throw IridiumRuntimeError.invalidGame }
        case "gdi", "cue":
            let disc = try IridiumDiscSet(url)
            let choices = try disc.platforms()
            if let preferredPlatform, choices.contains(preferredPlatform) { platform = preferredPlatform }
            else if choices.count == 1 { platform = choices[0] }
            else { throw IridiumRuntimeError.invalidGame }
            if platform == .playStation2, disc.hasSharedTracks { throw IridiumDiscSet.Failure.sharedPS2Tracks }
            _ = try reader.read(0, Int(min(size, 4096)))
        case "3dsx":
            let header = try reader.read(0, 32)
            guard header.prefix(4).elementsEqual("3DSX".utf8), little(header, 4, 2) >= 32,
                  little(header, 4, 2) <= size, little(header, 6, 2) >= 8 else { throw IridiumRuntimeError.invalidGame }
            platform = .nintendo3DS
        case "3ds", "cci", "cxi", "app":
            let header = try reader.read(0x100, 0x100)
            let magic = String(decoding: header.prefix(4), as: UTF8.self)
            guard magic == (["3ds", "cci"].contains(ext) ? "NCSD" : "NCCH"), little(header, 4, 4) > 0,
                  little(header, 4, 4) <= size / 512 else { throw IridiumRuntimeError.invalidGame }
            platform = .nintendo3DS
        case "cdi":
            let trailer = try reader.read(size >= 8 ? size - 8 : 0, 8)
            guard [0x80000004, 0x80000005, 0x80000006].contains(little(trailer, 0, 4)),
                  little(trailer, 4, 4) > 0, little(trailer, 4, 4) < size else { throw IridiumRuntimeError.invalidGame }
            platform = .dreamcast
        case "chd":
            let header = try reader.read(0, 124)
            guard header.prefix(8).elementsEqual("MComprHD".utf8), big(header, 8, 4) == 124,
                  big(header, 12, 4) == 5, big(header, 32, 8) > 0,
                  big(header, 56, 4) > 0, big(header, 56, 4) <= 64 * 1024 * 1024,
                  preferredPlatform == .playStation2 || preferredPlatform == .dreamcast else { throw IridiumRuntimeError.invalidGame }
            platform = preferredPlatform!
        case "zip":
            guard size >= 22 else { throw IridiumRuntimeError.invalidGame }
            let end = try reader.read(size - 22, 22)
            guard end.prefix(4).elementsEqual([0x50,0x4b,5,6]), little(end, 4, 4) == 0,
                  little(end, 20, 2) == 0 else { throw IridiumRuntimeError.invalidGame }
            let entries = little(end, 10, 2), start = little(end, 16, 4), length = little(end, 12, 4)
            guard entries > 0, entries <= 4096, little(end, 8, 2) == entries,
                  start <= size - 22, length == size - 22 - start else { throw IridiumRuntimeError.invalidGame }
            var offset = start, expanded: UInt64 = 0
            var names = Set<String>()
            for _ in 0..<entries {
                let entry = try reader.read(offset, 46)
                guard entry.prefix(4).elementsEqual([0x50,0x4b,1,2]), little(entry, 8, 2) & 1 == 0,
                      [0,8].contains(little(entry, 10, 2)), little(entry, 34, 2) == 0 else { throw IridiumRuntimeError.invalidGame }
                let count = little(entry, 28, 2), extra = little(entry, 30, 2), comment = little(entry, 32, 2)
                let localOffset = little(entry, 42, 4), compressed = little(entry, 20, 4)
                let kind = (little(entry, 38, 4) >> 16) & 0xf000
                guard count > 0, count <= 255, localOffset < start, kind == 0 || kind == 0x8000,
                      little(entry, 20, 4) <= size else { throw IridiumRuntimeError.invalidGame }
                let nameBytes = try reader.read(offset + 46, Int(count))
                let name = String(decoding: nameBytes, as: UTF8.self)
                guard !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."), !name.contains("\0"),
                      names.insert(name.lowercased()).inserted else { throw IridiumRuntimeError.invalidGame }
                let local = try reader.read(localOffset, 30)
                let localCount = little(local, 26, 2), localExtra = little(local, 28, 2)
                let payload = localOffset + 30 + localCount + localExtra
                guard local.prefix(4).elementsEqual([0x50,0x4b,3,4]), localCount == count,
                      little(local, 6, 2) == little(entry, 8, 2), little(local, 8, 2) == little(entry, 10, 2),
                      try reader.read(localOffset + 30, Int(count)) == nameBytes,
                      payload <= start, compressed <= start - payload else { throw IridiumRuntimeError.invalidGame }
                expanded += little(entry, 24, 4)
                guard expanded <= 8 * 1024 * 1024 * 1024 else { throw IridiumRuntimeError.invalidGame }
                offset += 46 + count + extra + comment
                guard offset <= start + length else { throw IridiumRuntimeError.invalidGame }
            }
            guard offset == start + length else { throw IridiumRuntimeError.invalidGame }
            platform = .arcade
        case "cso":
            let header = try reader.read(0, 24)
            let originalSize = little(header, 8, 8)
            let block = little(header, 16, 4)
            // v0/v1 use a fixed 24-byte header, including files written with a
            // zero header-size field. CSOv2 and unbounded frames are excluded.
            guard header.prefix(4).elementsEqual("CISO".utf8), [0, 24].contains(little(header, 4, 4)),
                  header[20] <= 1, header[21] <= 20,
                  originalSize >= 17 * 2048, originalSize <= maximumDiscSize, originalSize % 2048 == 0,
                  block >= 2048, block <= 65536, block & (block - 1) == 0
            else { throw IridiumRuntimeError.invalidGame }
            let frames = (originalSize + block - 1) / block
            let tableEnd = 24 + (frames + 1) * 4
            guard tableEnd <= size else { throw IridiumRuntimeError.invalidGame }
            let first = little(try reader.read(24, 4), 0, 4) & 0x7fffffff
            let last = little(try reader.read(24 + frames * 4, 4), 0, 4) & 0x7fffffff
            let firstOffset = first << header[21], lastOffset = last << header[21]
            guard firstOffset >= tableEnd, lastOffset > firstOffset, lastOffset <= size else { throw IridiumRuntimeError.invalidGame }
            platform = .psp
        case "pbp":
            let header = try reader.read(0, 40)
            guard header.prefix(4).elementsEqual([0, 0x50, 0x42, 0x50]), little(header, 4, 4) == 0x10000
            else { throw IridiumRuntimeError.invalidGame }
            let offsets = (0..<8).map { little(header, 8 + $0 * 4, 4) }
            var previous: UInt64 = 40
            for offset in offsets {
                guard offset >= previous, offset <= size else { throw IridiumRuntimeError.invalidGame }
                previous = offset
            }
            let executable = offsets[6], length = offsets[7] - executable
            guard length >= 4 else { throw IridiumRuntimeError.invalidGame }
            let magic = try reader.read(executable, 4)
            if magic.elementsEqual([0x7f, 0x45, 0x4c, 0x46]) {
                try reader.validateELF(at: executable, length: length)
            } else {
                // Encrypted PSP executables have a fixed 0x150-byte header.
                guard magic.elementsEqual("~PSP".utf8), length >= 0x150 else { throw IridiumRuntimeError.invalidGame }
                _ = try reader.read(executable, 0x150)
            }
            platform = .psp
        default: throw IridiumRuntimeError.invalidGame
        }
        guard try handle.seekToEnd() == size else { throw IridiumRuntimeError.invalidGame }
        if platform == .psp { guard size <= (ext == "elf" ? 128 * 1024 * 1024 : maximumDiscSize) else { throw IridiumRuntimeError.invalidGame } }
        _ = try checkedFile(url)
        let finalSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let finalSize, finalSize >= 0, UInt64(finalSize) == size else { throw IridiumRuntimeError.invalidGame }
        return Self(platform: platform, size: size, headers: reader.headers)
    }

    private static func little(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(UInt64(0)) { $0 | (UInt64(data[offset + $1]) << ($1 * 8)) }
    }
    private static func big(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(UInt64(0)) { ($0 << 8) | UInt64(data[offset + $1]) }
    }

    private struct HeaderReader {
        let handle: FileHandle
        let size: UInt64
        var headers = Data()
        mutating func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count > 0, count <= 4096, offset <= size, UInt64(count) <= size - offset
            else { throw IridiumRuntimeError.invalidGame }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else { throw IridiumRuntimeError.invalidGame }
            headers.append(data)
            return data
        }

        mutating func validateELF(at base: UInt64, length: UInt64, machine: UInt64 = 8) throws {
            guard length >= 52 else { throw IridiumRuntimeError.invalidGame }
            let header = try read(base, 52)
            let programOffset = IridiumROMInspection.little(header, 28, 4), programCount = IridiumROMInspection.little(header, 44, 2)
            let sectionOffset = IridiumROMInspection.little(header, 32, 4), sectionCount = IridiumROMInspection.little(header, 48, 2)
            guard header.prefix(4).elementsEqual([0x7f, 0x45, 0x4c, 0x46]),
                  header[4] == 1, header[5] == 1, header[6] == 1,
                  [2, 3, 0xffa0].contains(IridiumROMInspection.little(header, 16, 2)), IridiumROMInspection.little(header, 18, 2) == machine,
                  IridiumROMInspection.little(header, 20, 4) == 1, IridiumROMInspection.little(header, 40, 2) == 52,
                  IridiumROMInspection.little(header, 42, 2) == 32, programCount > 0, programCount <= 128,
                  programOffset >= 52, programOffset <= length, programCount * 32 <= length - programOffset
            else { throw IridiumRuntimeError.invalidGame }
            if sectionCount > 0 {
                guard IridiumROMInspection.little(header, 46, 2) == 40, sectionOffset >= 52, sectionOffset <= length,
                      sectionCount * 40 <= length - sectionOffset, IridiumROMInspection.little(header, 50, 2) < sectionCount
                else { throw IridiumRuntimeError.invalidGame }
            }
            var hasLoadSegment = false
            for index in 0..<programCount {
                let entry = try read(base + programOffset + index * 32, 32)
                let offset = IridiumROMInspection.little(entry, 4, 4), fileSize = IridiumROMInspection.little(entry, 16, 4)
                guard offset <= length, fileSize <= length - offset else { throw IridiumRuntimeError.invalidGame }
                if IridiumROMInspection.little(entry, 0, 4) == 1 {
                    guard fileSize <= IridiumROMInspection.little(entry, 20, 4) else { throw IridiumRuntimeError.invalidGame }
                    hasLoadSegment = true
                }
            }
            guard hasLoadSegment else { throw IridiumRuntimeError.invalidGame }
        }
    }
}

/// A disc manifest and only its named tracks. Native Flycast/Play! read these
/// files directly, so retain their relative names instead of converting them.
struct IridiumDiscSet {
    enum Failure: LocalizedError {
        case missingTracks, invalidManifest, sharedPS2Tracks
        var errorDescription: String? {
            switch self {
            case .missingTracks: return "Some disc tracks are missing. Choose the folder containing the GDI or CUE file and all its tracks, or select those files together."
            case .invalidManifest: return "This disc's track list could not be read. Choose the original GDI or CUE file with all its tracks."
            case .sharedPS2Tracks: return "Play! cannot read this CUE layout. Use a CHD copy of this PlayStation 2 disc."
            }
        }
    }
    let source: URL
    let filenames: [String]
    let hasSharedTracks: Bool
    private let dataFiles: [String]

    init(_ source: URL, selectedFiles: [URL]? = nil, validateFiles: Bool = true) throws {
        self.source = try IridiumROMInspection.checkedFile(source)
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size < 65536, let text = String(data: try Data(contentsOf: source), encoding: .utf8) else { throw Failure.invalidManifest }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var names: [String] = [], dataNames: [String] = [], tracks: [String: Int] = [:]
        var current: String?, trackCount = 0
        let gdi = source.pathExtension.lowercased() == "gdi"
        let expected = gdi ? Int(lines.first?.trimmingCharacters(in: .whitespaces) ?? "") : nil
        if gdi { guard let expected, (3...99).contains(expected) else { throw Failure.invalidManifest } }
        for line in gdi ? Array(lines.dropFirst()) : lines {
            let tokens = try Self.tokens(line)
            if tokens.isEmpty { continue }
            if gdi {
                guard tokens.count == 6, Int(tokens[0]) == trackCount + 1,
                      let fad = UInt32(tokens[1]), let control = Int(tokens[2]), [0, 4].contains(control),
                      let sector = Int(tokens[3]), [2048, 2352].contains(sector), UInt32(tokens[5]) != nil,
                      trackCount != 0 || control == 4, trackCount != 1 || control == 0,
                      trackCount != 2 || (control == 4 && fad == 45000) else { throw Failure.invalidManifest }
                current = tokens[4]; trackCount += 1
                names.append(tokens[4]); tracks[tokens[4], default: 0] += 1
                if control == 4 { dataNames.append(tokens[4]) }
            } else if tokens[0].uppercased() == "FILE" {
                guard tokens.count == 3, tokens[2].uppercased() == "BINARY" else { throw Failure.invalidManifest }
                current = tokens[1]; names.append(tokens[1])
            } else if tokens[0].uppercased() == "TRACK" {
                guard tokens.count == 3, Int(tokens[1]) == trackCount + 1, let current,
                      ["AUDIO", "MODE1/2048", "MODE1/2352", "MODE2/2336", "MODE2/2352", "CDI/2336", "CDI/2352"].contains(tokens[2].uppercased()) else { throw Failure.invalidManifest }
                trackCount += 1; tracks[current, default: 0] += 1
                if tokens[2].uppercased() != "AUDIO" { dataNames.append(current) }
            } else if tokens[0].uppercased() == "INDEX" {
                guard tokens.count == 3, Int(tokens[1]) != nil,
                      tokens[2].split(separator: ":").count == 3,
                      tokens[2].split(separator: ":").allSatisfy({ UInt32($0) != nil }) else { throw Failure.invalidManifest }
            }
            guard trackCount <= 99, names.count <= 99 else { throw Failure.invalidManifest }
        }
        guard trackCount > 0, !dataNames.isEmpty, !gdi || trackCount == expected else { throw Failure.invalidManifest }
        var seen = Set<String>(), total: UInt64 = 0
        var unique: [String] = []
        for name in names {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.isEmpty, name.utf8.count <= 512, !name.contains("\\"), !name.contains("\0"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }),
                  name != source.lastPathComponent else { throw IridiumRuntimeError.unsafePath }
            let url = source.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
            if let selectedFiles {
                let authorized = selectedFiles.contains { selected in
                    let selected = selected.standardizedFileURL
                    if selected == url { return true }
                    return (try? selected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && url.path.hasPrefix(selected.path + "/")
                }
                guard authorized else { throw Failure.missingTracks }
            }
            if validateFiles {
                guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missingTracks }
                _ = try IridiumROMInspection.checkedFile(url)
                let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard bytes > 0 else { throw Failure.missingTracks }
                total += UInt64(bytes)
                guard total <= 64 * 1024 * 1024 * 1024 else { throw Failure.invalidManifest }
            }
            if seen.insert(name).inserted { unique.append(name) }
        }
        filenames = unique; dataFiles = Array(Set(dataNames)); hasSharedTracks = tracks.values.contains { $0 > 1 }
    }
    func platforms() throws -> [IridiumPlatform] {
        if source.pathExtension.lowercased() == "gdi" { return [.dreamcast] }
        var detected = Set<IridiumPlatform>()
        for name in dataFiles {
            let handle = try FileHandle(forReadingFrom: source.deletingLastPathComponent().appendingPathComponent(name))
            defer { try? handle.close() }
            // Cover cooked and raw CD sector headers without loading a track.
            for offset: UInt64 in [0, 8, 16, 24, 16 * 2048, 16 * 2336 + 8, 16 * 2352 + 16, 16 * 2352 + 24] {
                try handle.seek(toOffset: offset)
                let bytes = try handle.read(upToCount: 64) ?? Data()
                if bytes.starts(with: "SEGA SEGAKATANA".utf8) { detected.insert(.dreamcast) }
                if bytes.count >= 40, bytes[1..<6].elementsEqual("CD001".utf8),
                   String(decoding: bytes[8..<40], as: UTF8.self).contains("PLAYSTATION") { detected.insert(.playStation2) }
            }
        }
        if detected.count == 1 { return Array(detected) }
        if detected.count > 1 { throw Failure.invalidManifest }
        return [.dreamcast, .playStation2]
    }
    private static func tokens(_ line: String) throws -> [String] {
        var values: [String] = [], value = "", quoted = false, started = false
        for character in line {
            if character == "\"" { quoted.toggle(); started = true }
            else if character.isWhitespace && !quoted {
                if started { values.append(value); value = ""; started = false }
            } else { value.append(character); started = true }
        }
        guard !quoted else { throw Failure.invalidManifest }
        if started { values.append(value) }
        return values
    }
}

/// File contents choose the system whenever a supported format identifies it.
/// Ambiguous executable/disc containers require an explicit user choice.
enum IridiumGameFileDetection {
    enum Failure: LocalizedError {
        case playStation1
        var errorDescription: String? { "PlayStation games are not supported yet. Choose a PlayStation 2 game instead." }
    }
    static func platforms(_ source: URL, selectedFiles: [URL]) throws -> [IridiumPlatform] {
        _ = try IridiumROMInspection.checkedFile(source)
        let ext = source.pathExtension.lowercased()
        if ["gdi", "cue"].contains(ext) { return try IridiumDiscSet(source, selectedFiles: selectedFiles).platforms() }
        if ext == "exe" { return [.windows] } // Madeira's PE validator runs before import.
        if ext == "zip" { return [.arcade] } // Ask before treating an archive as an arcade set.
        if ext == "dol" {
            _ = try IridiumROMInspection.inspect(source, fileExtension: ext)
            return [.gameCube, .wii]
        }
        if ext == "chd" {
            _ = try IridiumROMInspection.inspect(source, fileExtension: ext, preferredPlatform: .dreamcast)
            return [.dreamcast, .playStation2]
        }
        let inspected = try IridiumROMInspection.inspect(source, fileExtension: ext)
        if ext == "elf", inspected.platform != .dreamcast {
            let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
            let header = try handle.read(upToCount: 52) ?? Data()
            let flags = header[36..<40].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            if flags & 0x00ff0000 != 0x00920000 && flags & 0xffff0000 != 0x10a20000 { return [.psp, .playStation2] }
        }
        if ext == "iso", inspected.platform == .playStation2, try playStationGeneration(source) == 1 { throw Failure.playStation1 }
        return [inspected.platform]
    }
    static func needsConfirmation(_ source: URL, platforms: [IridiumPlatform]) throws -> Bool {
        if platforms.count > 1 || source.pathExtension.lowercased() == "zip" { return true }
        if platforms == [.playStation2] {
            if source.pathExtension.lowercased() == "cue" { return true }
            if source.pathExtension.lowercased() == "iso" { return try playStationGeneration(source) == nil }
        }
        return false
    }
    /// ISO9660's system ID is shared by PS1 and PS2. BOOT2 in SYSTEM.CNF
    /// distinguishes PS2; do not silently label an unidentified disc as PS2.
    private static func playStationGeneration(_ source: URL) throws -> Int? {
        let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            try handle.seek(toOffset: offset); return try handle.read(upToCount: count) ?? Data()
        }
        func little(_ bytes: Data, _ offset: Int) -> UInt64 {
            (0..<4).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
        }
        let descriptor = try read(16 * 2048, 2048)
        guard descriptor.count == 2048, descriptor[156] >= 34 else { return nil }
        let length = little(descriptor, 166), extent = little(descriptor, 158)
        guard length > 0, length <= 65536, extent > 0 else { return nil }
        let directory = try read(extent * 2048, Int(length))
        var offset = 0
        while offset < directory.count {
            let count = Int(directory[offset])
            if count == 0 { offset = ((offset / 2048) + 1) * 2048; continue }
            guard count >= 34, count <= directory.count - offset else { return nil }
            let nameCount = Int(directory[offset + 32])
            guard 33 + nameCount <= count else { return nil }
            let name = String(decoding: directory[(offset + 33)..<(offset + 33 + nameCount)], as: UTF8.self).uppercased()
            if name == "SYSTEM.CNF;1" || name == "SYSTEM.CNF" {
                let record = directory.subdata(in: offset..<(offset + count))
                let bytes = try read(little(record, 2) * 2048, Int(min(4096, little(record, 10))))
                let text = String(decoding: bytes, as: UTF8.self)
                if text.range(of: #"(?im)^\s*BOOT2\s*="# , options: .regularExpression) != nil { return 2 }
                if text.range(of: #"(?im)^\s*BOOT\s*="# , options: .regularExpression) != nil { return 1 }
                return nil
            }
            offset += count
        }
        return nil
    }
}
