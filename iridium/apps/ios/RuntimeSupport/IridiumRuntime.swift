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
        jit: .none, supportsPause: true, restartAfterStop: false)
    static let azahar = IridiumRuntimeDescriptor(id: "azahar", name: "Azahar", platforms: [.nintendo3DS],
        jit: .none, supportsPause: true, restartAfterStop: false)
    // Play's app configuration is a process-lifetime upstream singleton. Its
    // per-game data root cannot safely change until a new process is started.
    static let play = IridiumRuntimeDescriptor(id: "play", name: "Play!", platforms: [.playStation2],
        jit: .required, supportsPause: true, restartAfterStop: true)
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
        case .invalidGame: return "The game file is unsupported, damaged, or too large. Choose a supported ROM, executable or single-file disc image. Encrypted 3DS files, installed-content packages and multi-track manifests require preparation outside Iridium."
        case .unsafePath: return "The game or save path is outside its runtime folder or uses a symbolic link."
        case .newerLibrary: return "This runtime library uses a newer format. Its original file has been preserved."
        case .unreadableLibrary: return "The runtime library could not be read. Its original file has been preserved."
        }
    }
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
    var pspJITEnabled: Bool { platform == .psp && pspJIT == true }

    func validate() throws {
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
            guard runtimeID == "dolphin", ["dol", "gcm", "iso", "rvz"].contains(fileExtension) else { throw IridiumRuntimeError.invalidGame }
        case .nintendo3DS:
            guard runtimeID == "azahar", ["3dsx", "cci", "cxi", "app"].contains(fileExtension) else { throw IridiumRuntimeError.invalidGame }
        case .playStation2:
            guard runtimeID == "play", ["elf", "iso", "chd"].contains(fileExtension) else { throw IridiumRuntimeError.invalidGame }
        case .dreamcast:
            guard runtimeID == "flycast", ["elf", "cdi", "chd"].contains(fileExtension) else { throw IridiumRuntimeError.invalidGame }
        case .arcade:
            guard runtimeID == "flycast", fileExtension == "zip", let name = originalFilename,
                  name.utf8.count <= 255, !name.contains("/"), !name.contains("\\"),
                  !name.hasPrefix("."), name.lowercased().hasSuffix(".zip") else { throw IridiumRuntimeError.invalidGame }
        case .windows: throw IridiumRuntimeError.invalidGame
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
        return try checked(["Games", game.id.uuidString, game.platform == .arcade ? game.originalFilename! : "game." + game.fileExtension])
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
        let directory = try checked(["Saves", game.runtimeID, game.id.uuidString], createDirectory: true)
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

    func importROM(_ source: URL, into games: [IridiumConsoleGame], preferredPlatform: IridiumPlatform? = nil) throws -> IridiumConsoleGame {
        _ = try load()
        let ext = source.pathExtension.lowercased()
        let inspected = try IridiumROMInspection.inspect(source, fileExtension: ext, preferredPlatform: preferredPlatform)
        let platform = inspected.platform
        let runtime = try IridiumRuntimeRegistry.resolve(platform: platform, preferred: nil)
        var game = IridiumConsoleGame(id: UUID(), title: String(source.deletingPathExtension().lastPathComponent.prefix(128)),
            platform: platform, runtimeID: runtime.id, fileExtension: ext, importedAt: Date())
        if platform == .arcade { game.originalFilename = source.lastPathComponent }
        let directory = try checked(["Games", game.id.uuidString], createDirectory: true)
        let target = try rom(game)
        // Copy without overwrite; the source and its parent directories remain
        // untouched. The caller coordinates provider access. Revalidate both
        // path ancestry and every inspected header in the copied file.
        let checkedSource = try IridiumROMInspection.checkedFile(source)
        try manager.copyItem(at: checkedSource, to: target)
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
        guard ["gb", "gbc", "elf", "iso", "cso", "pbp", "dol", "gcm", "rvz", "3dsx", "cci", "cxi", "app", "cdi", "chd", "zip"].contains(ext) else { throw IridiumRuntimeError.invalidGame }
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
                platform = little(header, 36, 4) & 0x00ff0000 == 0x00920000 ? .playStation2 : .psp
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
        case "gcm":
            let header = try reader.read(0, 32)
            guard big(header, 28, 4) == 0xc2339f3d else { throw IridiumRuntimeError.invalidGame }
            platform = .gameCube
        case "rvz":
            let header = try reader.read(0, 0x48)
            guard header.prefix(4).elementsEqual([0x52, 0x56, 0x5a, 1]) else { throw IridiumRuntimeError.invalidGame }
            // The import choice labels compressed discs; Dolphin validates
            // the actual disc and console before booting it.
            platform = preferredPlatform == .wii ? .wii : .gameCube
        case "3dsx":
            let header = try reader.read(0, 32)
            guard header.prefix(4).elementsEqual("3DSX".utf8), little(header, 4, 2) >= 32,
                  little(header, 4, 2) <= size, little(header, 6, 2) >= 8 else { throw IridiumRuntimeError.invalidGame }
            platform = .nintendo3DS
        case "cci", "cxi", "app":
            let header = try reader.read(0x100, 0x100)
            let magic = String(decoding: header.prefix(4), as: UTF8.self)
            guard magic == (ext == "cci" ? "NCSD" : "NCCH"), little(header, 4, 4) > 0,
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
