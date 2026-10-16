import Foundation

/// Transfer existing files to Madeira's shared folder. Originals are retained.
enum IridiumLibraryImport {
    struct Game: Decodable, Identifiable {
        let id: UUID
        let title: String
        let installPath: String
        let launchProfile: Profile
        struct Profile: Decodable { let executablePath: String; let arguments: [String] }
    }
    struct Snapshot: Decodable { let games: [Game] }
    struct Imported {
        let game: Game
        let executable: String
    }
    enum Failure: LocalizedError {
        case outsideFolder, missingExecutable, conflictingSave, conflictingGame, incompletePrefix
        var errorDescription: String? {
            switch self {
            case .outsideFolder: return "This folder contains a link outside the game. The original files were kept."
            case .missingExecutable: return "The saved executable could not be found. Choose it from the original game folder."
            case .conflictingSave: return "A different save already uses this name. Both original folders were kept. Back up and restore the save you want through Settings."
            case .conflictingGame: return "A different game folder already uses this ID. The original files were kept."
            case .incompletePrefix: return "The game's runtime folder is incomplete. Choose its executable from Add Game."
            }
        }
    }

    static func games(applicationSupport: URL) throws -> [Game] {
        let state = applicationSupport.appendingPathComponent("Iridium/state.json")
        guard FileManager.default.fileExists(atPath: state.path) else { return [] }
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: state)).games
    }

    static func transfer(_ game: Game, documents: URL) throws -> Imported {
        let fm = FileManager.default
        let prefix = documents.appendingPathComponent("MadeiraTestPrefixes/" + game.id.uuidString)
        let source = prefix.appendingPathComponent("drive_c/IridiumGame").resolvingSymlinksInPath()
        let root = documents.resolvingSymlinksInPath()
        guard prefix.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
              source.path.hasPrefix(prefix.resolvingSymlinksInPath().path + "/") else { throw Failure.outsideFolder }
        // Old absolute sandbox paths can name a previous installation. The
        // relative executable path survives an update; the UUID finds its prefix.
        let relative: String
        if game.launchProfile.executablePath.hasPrefix(game.installPath + "/") {
            relative = String(game.launchProfile.executablePath.dropFirst(game.installPath.count + 1))
        } else {
            relative = URL(fileURLWithPath: game.launchProfile.executablePath).lastPathComponent
        }
        let executable = source.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard executable.path.hasPrefix(source.path + "/"), fm.fileExists(atPath: executable.path),
              ["exe", "bat", "cmd"].contains(executable.pathExtension.lowercased()) else { throw Failure.missingExecutable }
        let shared = documents.appendingPathComponent("wine")
        let user = prefix.appendingPathComponent("drive_c/users/madeira")
        guard user.resolvingSymlinksInPath().path.hasPrefix(prefix.resolvingSymlinksInPath().path + "/") else {
            throw Failure.outsideFolder
        }
        if !fm.fileExists(atPath: shared.path) {
            // Copy the complete first prefix, including registry and prerequisites.
            // Madeira can update its own copy without changing the original.
            guard ["system.reg", "user.reg"].allSatisfy({ fm.fileExists(atPath: prefix.appendingPathComponent($0).path) }) else {
                throw Failure.incompletePrefix
            }
            let temporary = documents.appendingPathComponent(".iridium-import-" + UUID().uuidString)
            do {
                try fm.copyItem(at: prefix, to: temporary)
                try fm.moveItem(at: temporary, to: shared)
            } catch {
                try? fm.removeItem(at: temporary)
                throw error
            }
            return Imported(game: game, executable: "IridiumGame/" + relative)
        }
        if shared.resolvingSymlinksInPath() == prefix.resolvingSymlinksInPath() {
            return Imported(game: game, executable: "IridiumGame/" + relative)
        }
        let drive = shared.appendingPathComponent("drive_c").resolvingSymlinksInPath()
        guard drive.path.hasPrefix(root.path + "/") else { throw Failure.outsideFolder }
        let destination = drive.appendingPathComponent("Imported/" + game.id.uuidString)
        // Preflight every collision before writing any save. Do not choose a
        // winning save or merge Wine registries from different prefixes.
        let savedUser = drive.appendingPathComponent("users/madeira")
        guard user.resolvingSymlinksInPath().path.hasPrefix(prefix.resolvingSymlinksInPath().path + "/"),
              destination.resolvingSymlinksInPath().path.hasPrefix(drive.path + "/"),
              savedUser.resolvingSymlinksInPath().path.hasPrefix(drive.path + "/") else { throw Failure.outsideFolder }
        let saves = try copies(from: user, to: savedUser, conflict: .conflictingSave)
        let files = try copies(from: source, to: destination, conflict: .conflictingGame)
        for (from, to, directory) in files + saves {
            if directory { try fm.createDirectory(at: to, withIntermediateDirectories: true) }
            else {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: from, to: to)
            }
        }
        return Imported(game: game, executable: "Imported/" + game.id.uuidString + "/" + relative)
    }

    private static func copies(from source: URL, to destination: URL, conflict: Failure) throws -> [(URL, URL, Bool)] {
        let fm = FileManager.default
        // Enumerators return canonical paths, including /private on macOS.
        // Use the same root when calculating a relative file name.
        let source = source.resolvingSymlinksInPath()
        let destination = destination.resolvingSymlinksInPath()
        if !fm.fileExists(atPath: source.path) { return [] }
        var readError: Error?
        guard let walk = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
                                       errorHandler: { _, error in readError = error; return false }) else { throw Failure.outsideFolder }
        var result: [(URL, URL, Bool)] = []
        for case let file as URL in walk {
            let attributes = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard attributes.isSymbolicLink != true else { throw Failure.outsideFolder }
            let file = file.resolvingSymlinksInPath()
            guard file.path.hasPrefix(source.path + "/") else { throw Failure.outsideFolder }
            let relative = String(file.path.dropFirst(source.path.count + 1))
            let target = destination.appendingPathComponent(relative)
            // An existing parent link must not redirect a write outside this folder.
            guard target.resolvingSymlinksInPath().path.hasPrefix(destination.resolvingSymlinksInPath().path + "/") else {
                throw Failure.outsideFolder
            }
            if attributes.isRegularFile == true {
                if fm.fileExists(atPath: target.path) {
                    guard fm.contentsEqual(atPath: file.path, andPath: target.path) else { throw conflict }
                } else { result.append((file, target, false)) }
            } else if attributes.isDirectory == true {
                var directory: ObjCBool = false
                if fm.fileExists(atPath: target.path, isDirectory: &directory) && !directory.boolValue { throw conflict }
                result.append((file, target, true))
            }
        }
        if let readError { throw readError }
        return result
    }

    static func commandLine(_ arguments: [String]) -> String {
        arguments.map { argument in
            var result = "\"", slashes = 0
            for character in argument {
                if character == "\\" { slashes += 1; continue }
                if character == "\"" {
                    result += String(repeating: "\\", count: slashes * 2 + 1) + "\""
                } else {
                    result += String(repeating: "\\", count: slashes) + String(character)
                }
                slashes = 0
            }
            return result + String(repeating: "\\", count: slashes * 2) + "\""
        }.joined(separator: " ")
    }
}
