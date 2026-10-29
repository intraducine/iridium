// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The install's Documents folder is supplied by the host, including LiveContainer.
struct IridiumGameStorage: Sendable {
    enum Failure: LocalizedError {
        case unsafePath, newerLibrary
        var errorDescription: String? { "Game storage could not be updated safely. The existing files were kept." }
    }
    let documents: URL
    var inbox: URL { documents.appendingPathComponent("Import", isDirectory: true) }
    var games: URL { documents.appendingPathComponent("Games", isDirectory: true) }
    var drive: URL { documents.appendingPathComponent("wine/drive_c", isDirectory: true) }
    private var journal: URL { documents.appendingPathComponent(".iridium-game-moves.json") }
    private struct Move: Codable { let original: String; let gameID: UUID; var filename: String? = nil }
    private struct Journal: Codable { var version = 1; var moves: [Move] = [] }

    func prepare() throws {
        _ = try checked(documents)
        try FileManager.default.createDirectory(at: checked(inbox), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checked(games), withIntermediateDirectories: true)
    }

    func gameFolder(_ id: UUID, title: String? = nil) throws -> URL {
        try checked(IridiumGameFolder.folder(id, title: title, in: games))
    }

    func nameGames(_ titles: [UUID: String]) throws {
        for (id, title) in titles {
            try Task.checkCancellation()
            let source = try gameFolder(id)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = try checked(games.appendingPathComponent(IridiumGameFolder.name(title, id: id), isDirectory: true))
            if source != target { try FileManager.default.moveItem(at: source, to: target) }
        }
    }

    func checked(_ url: URL) throws -> URL {
        let url = url.standardizedFileURL, root = documents.standardizedFileURL
        guard url.isFileURL, root.resolvingSymlinksInPath().path == root.path,
              url.path == root.path || url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == url.path else {
            throw Failure.unsafePath
        }
        return url
    }

    /// Journal before moving. A restart repairs an interrupted move before any launch.
    func migrateWindows(_ entries: [(id: UUID, relative: String, steam: Bool)], titles: [UUID: String] = [:]) throws {
        try prepare()
        let fm = FileManager.default
        var state = Journal()
        if fm.fileExists(atPath: journal.path) {
            guard (try checked(journal).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4 * 1024 * 1024 else { throw Failure.unsafePath }
            state = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journal))
            guard state.version == 1 else { throw Failure.newerLibrary }
        }
        for entry in entries.sorted(by: {
            if $0.relative != $1.relative { return $0.relative < $1.relative }
            let folder = URL(fileURLWithPath: $0.relative).lastPathComponent
            let a = titles[$0.id]?.caseInsensitiveCompare(folder) == .orderedSame
            let b = titles[$1.id]?.caseInsensitiveCompare(folder) == .orderedSame
            if a != b { return a }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            try Task.checkCancellation()
            let parts = entry.relative.split(separator: "/").map(String.init)
            guard !parts.contains(".."), !parts.contains("."), !entry.relative.hasPrefix("/"),
                  !entry.relative.contains("\\"), !entry.relative.contains("\0") else { throw Failure.unsafePath }
            if parts.first == "iridium-games" { continue }
            if parts.count > 1, parts[1].lowercased() == "steam", !parts.contains("common") { continue }
            let original: String
            var filename: String?
            if entry.steam { original = entry.relative }
            else if let common = parts.firstIndex(of: "common"), parts.count > common + 1 {
                original = parts.prefix(common + 2).joined(separator: "/")
            } else if parts.first == "Imported", parts.count >= 3 { original = parts.prefix(2).joined(separator: "/") }
            else if ["Program Files", "Program Files (x86)", "Games"].contains(parts.first ?? ""), parts.count >= 3 {
                original = parts.prefix(2).joined(separator: "/")
            } else if parts.count >= 2, !["windows", "users", "programdata"].contains(parts[0].lowercased()) {
                original = parts[0]
            } else if parts.count == 1, ["exe", "bat", "cmd"].contains(URL(fileURLWithPath: entry.relative).pathExtension.lowercased()) {
                original = entry.relative; filename = parts[0]
            } else { continue }
            let source = drive.appendingPathComponent(original)
            if state.moves.contains(where: { $0.original == original }) { continue }
            if !fm.fileExists(atPath: source.path) { continue }
            _ = try checked(source)
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            guard filename == nil ? values.isDirectory == true : values.isRegularFile == true else { continue }
            state.moves.append(Move(original: original, gameID: entry.id, filename: filename))
            try JSONEncoder().encode(state).write(to: checked(journal), options: .atomic)
        }
        for move in state.moves {
            try Task.checkCancellation()
            let source = drive.appendingPathComponent(move.original).standardizedFileURL
            guard source.path.hasPrefix(drive.standardizedFileURL.path + "/"), !move.original.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw Failure.unsafePath
            }
            let folder = try gameFolder(move.gameID, title: titles[move.gameID])
            if let name = move.filename {
                guard name == URL(fileURLWithPath: name).lastPathComponent, !name.isEmpty, !name.contains("\\"), name != ".", name != ".." else { throw Failure.unsafePath }
            }
            let target = move.filename.map { folder.appendingPathComponent($0) } ?? folder
            if (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try repairLink(source, to: target, gameID: move.gameID, filename: move.filename)
                continue
            }
            if fm.fileExists(atPath: source.path) {
                _ = try checked(source)
                guard !fm.fileExists(atPath: target.path) else { throw Failure.unsafePath }
                if move.filename != nil {
                    if fm.fileExists(atPath: folder.path) {
                        guard try fm.contentsOfDirectory(atPath: folder.path).isEmpty else { throw Failure.unsafePath }
                    } else { try fm.createDirectory(at: folder, withIntermediateDirectories: false) }
                }
                try fm.moveItem(at: source, to: target)
            }
            if fm.fileExists(atPath: target.path) {
                _ = try checked(source.deletingLastPathComponent())
                try createLink(source, to: target)
            }
        }
        try prepareWindowsLink()
    }

    func prepareWindowsLink() throws {
        let fm = FileManager.default
        _ = try checked(drive)
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        let link = drive.appendingPathComponent("iridium-games")
        if (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            guard link.resolvingSymlinksInPath().path == games.path else { throw Failure.unsafePath }
            try fm.removeItem(at: link)
        }
        let marker = link.appendingPathComponent(".iridium-game-aliases")
        let seal = Data("Iridium game aliases 1\n".utf8)
        if fm.fileExists(atPath: link.path) {
            if fm.fileExists(atPath: marker.path) {
                let values = try checked(marker).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, values.fileSize == seal.count,
                      (try? Data(contentsOf: marker)) == seal else { throw Failure.unsafePath }
            } else {
                // A crash can leave the new alias directory empty before its marker is saved.
                guard try fm.contentsOfDirectory(atPath: link.path).isEmpty else { throw Failure.unsafePath }
                try seal.write(to: checked(marker), options: .atomic)
            }
        } else {
            try fm.createDirectory(at: checked(link), withIntermediateDirectories: false)
            try seal.write(to: checked(marker), options: .atomic)
        }
        let folders = try fm.contentsOfDirectory(at: checked(games), includingPropertiesForKeys: [.isDirectoryKey])
        guard folders.count <= 100_000 else { throw Failure.unsafePath }
        for folder in folders {
            guard let id = IridiumGameFolder.identifier(folder.lastPathComponent) else { continue }
            _ = try checked(folder)
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw Failure.unsafePath }
            let alias = link.appendingPathComponent(id.uuidString)
            if (try? alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try repairLink(alias, to: folder, gameID: id)
            } else {
                guard !fm.fileExists(atPath: alias.path) else { throw Failure.unsafePath }
                try createLink(alias, to: folder)
            }
        }
    }

    private func repairLink(_ link: URL, to target: URL, gameID: UUID, filename: String? = nil) throws {
        let path = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        let previous = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : link.deletingLastPathComponent().appendingPathComponent(path)).standardizedFileURL
        if previous.path == target.path { return }
        let folder = filename == nil ? previous : previous.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().path == games.path,
              IridiumGameFolder.identifier(folder.lastPathComponent) == gameID,
              filename == nil || previous.lastPathComponent == filename else {
            throw Failure.unsafePath
        }
        try FileManager.default.removeItem(at: link)
        try createLink(link, to: target)
    }

    private func createLink(_ link: URL, to target: URL) throws {
        let parent = link.deletingLastPathComponent().standardizedFileURL.pathComponents
        let destination = target.standardizedFileURL.pathComponents
        let shared = zip(parent, destination).prefix { $0 == $1 }.count
        let relative = Array(repeating: "..", count: parent.count - shared) + destination.dropFirst(shared)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: relative.joined(separator: "/"))
    }

    func migrateConsoles(_ ids: [UUID], from oldRoot: URL, titles: [UUID: String] = [:]) throws {
        try prepare()
        for id in ids {
            try Task.checkCancellation()
            let source = try checked(oldRoot.appendingPathComponent("Games/" + id.uuidString))
            let target = try gameFolder(id, title: titles[id])
            if FileManager.default.fileExists(atPath: source.path) {
                guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure.unsafePath }
                try FileManager.default.moveItem(at: source, to: target)
            }
        }
    }

    /// Only a journaled installation alias grants permission to remove its target.
    static func movedWindowsFolder(_ link: URL, drive: URL) -> URL? {
        let documents = drive.deletingLastPathComponent().deletingLastPathComponent()
        let storage = Self(documents: documents)
        guard (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
              link.standardizedFileURL.path.hasPrefix(drive.standardizedFileURL.path + "/"),
              let journal = try? storage.checked(storage.journal),
              let size = try? journal.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: journal), let state = try? JSONDecoder().decode(Journal.self, from: data), state.version == 1 else { return nil }
        let original = String(link.standardizedFileURL.path.dropFirst(drive.standardizedFileURL.path.count + 1))
        guard let move = state.moves.first(where: { $0.original == original && $0.filename == nil }),
              let target = try? storage.gameFolder(move.gameID), link.resolvingSymlinksInPath().path == target.path else { return nil }
        return target
    }

    static func windowsRelative(_ url: URL, drive: URL) -> String? {
        guard url.isFileURL, drive.isFileURL else { return nil }
        let original = url.standardizedFileURL
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        let drive = drive.resolvingSymlinksInPath().standardizedFileURL
        if url.path.hasPrefix(drive.path + "/") { return String(url.path.dropFirst(drive.path.count + 1)) }
        let games = drive.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Games")
        guard games.resolvingSymlinksInPath().path == games.path else { return nil }
        if url.path == games.path { return "iridium-games" }
        guard url.path.hasPrefix(games.path + "/") else { return nil }
        let parts = url.path.dropFirst(games.path.count + 1).split(separator: "/")
        guard let first = parts.first, let id = IridiumGameFolder.identifier(String(first)) else { return nil }
        if original.path.hasPrefix(drive.path + "/") { return String(original.path.dropFirst(drive.path.count + 1)) }
        return "iridium-games/" + ([id.uuidString] + parts.dropFirst().map(String.init)).joined(separator: "/")
    }
}
