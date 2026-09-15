import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

enum MadeiraGamePreparation {
    struct Manifest: Codable, Equatable {
        var version = 1
        var files: [String: String]
        var directories: [String] = []
    }
    struct SteamMetadata: Equatable {
        let appID: String
        let appPath: String
    }
    private struct Journal: Codable {
        let staging: String
        let backup: String
    }
    enum PreparationError: LocalizedError {
        case conflictingChanges
        case legacyCopy
        case sourceChanged
        case invalidManifest
        var errorDescription: String? {
            switch self {
            case .conflictingChanges:
                return "The source and isolated game copy both changed. Use Refresh Game Copy in Game Options to keep a backup before replacing conflicting files."
            case .legacyCopy:
                return "This existing game copy has no update baseline. Use Refresh Game Copy in Game Options. The current copy will be backed up first."
            case .sourceChanged:
                return "The source game folder changed during preparation. Finish updating the files and try again."
            case .invalidManifest:
                return "The game-copy update record is invalid. Existing files were kept. Restore the game-copy backup before retrying."
            }
        }
    }
    private static let manifestName = ".iridium-source-manifest.json"
    private static let oldStamp = ".iridium-test-copy-complete"
    private static let journalName = ".iridium-game-update.json"

    static func prefix(for gameID: UUID) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MadeiraTestPrefixes/\(gameID.uuidString)", isDirectory: true)
    }

    static func prepare(
        executable: URL,
        gameRoot: URL,
        prefix: URL,
        replaceConflictsWithBackup: Bool = false,
        fingerprint: (URL) throws -> String = fingerprintFile
    ) throws -> String {
        let fm = FileManager.default
        let root = gameRoot.resolvingSymlinksInPath().standardizedFileURL
        let exe = executable.resolvingSymlinksInPath().standardizedFileURL
        let prefix = prefix.resolvingSymlinksInPath().standardizedFileURL
        guard exe.path.hasPrefix(root.path + "/"),
              (try exe.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
              !prefix.path.hasPrefix(root.path + "/"), prefix != root else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let relative = String(exe.path.dropFirst(root.path.count + 1))
        let target = prefix.appendingPathComponent("drive_c/IridiumGame", isDirectory: true)
        for candidate in [target.deletingLastPathComponent(), target] {
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try recoverInterruptedUpdate(prefix: prefix, target: target)
        // Single-session callers hold the preparation/launch gate. Old staging
        // copies are never active saves and can be removed after recovery.
        for item in try fm.contentsOfDirectory(at: prefix, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            let name = item.lastPathComponent
            if name.hasPrefix("game-copy-"), UUID(uuidString: String(name.dropFirst(10))) != nil,
               (try item.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true {
                try fm.removeItem(at: item)
            }
        }
        try validateCompleteTree(root)
        let source = try snapshot(root, fingerprint: fingerprint)
        var prior = Manifest(files: [:])
        let hadTarget = fm.fileExists(atPath: target.path)
        if hadTarget {
            try validateCompleteTree(target)
            let url = target.appendingPathComponent(manifestName)
            if fm.fileExists(atPath: url.path) {
                prior = try JSONDecoder().decode(Manifest.self, from: boundedData(url, maximumBytes: 32 * 1024 * 1024))
                guard prior.version == 1, prior.files.keys.allSatisfy(validRelativePath), prior.directories.allSatisfy(validRelativePath) else {
                    throw PreparationError.invalidManifest
                }
                if prior == source, !replaceConflictsWithBackup,
                   fm.fileExists(atPath: target.appendingPathComponent(relative).path) {
                    _ = try snapshot(target, fingerprint: fingerprint)
                    guard fm.fileExists(atPath: target.appendingPathComponent(relative).path) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    return windowsPath(relative)
                }
            } else {
                let current = try snapshot(target, fingerprint: fingerprint)
                // An identical legacy copy can adopt a baseline without altering saves.
                if source.files.allSatisfy({ current.files[$0.key] == $0.value }) {
                    try JSONEncoder().encode(source).write(to: url, options: .atomic)
                    return windowsPath(relative)
                }
                guard replaceConflictsWithBackup else { throw PreparationError.legacyCopy }
            }
        }

        let id = UUID().uuidString
        let staging = prefix.appendingPathComponent("game-copy-" + id, isDirectory: true)
        let backup = prefix.appendingPathComponent("game-backup-" + id, isDirectory: true)
        let journalURL = prefix.appendingPathComponent(journalName)
        var installed = false
        var journalWritten = false
        defer {
            // A recorded swap is recovered on the next launch. Never delete its
            // backup or staging area if rollback itself could not complete.
            if !journalWritten && !installed { try? fm.removeItem(at: staging) }
        }
        if hadTarget {
            _ = try snapshot(target, fingerprint: fingerprint) // reject links/special files before copying
            try fm.copyItem(at: target, to: staging)
        } else {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        try validateCompleteTree(staging)
        let current = try snapshot(staging, fingerprint: fingerprint)
        for path in source.directories {
            let directory = staging.appendingPathComponent(path)
            if fm.fileExists(atPath: directory.path),
               (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true {
                throw PreparationError.conflictingChanges
            }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for (path, hash) in source.files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let oldHash = prior.files[path]
            // Preserve files changed only by the guest (including saves/configuration).
            if oldHash == hash, current.files[path] != nil { continue }
            if let localHash = current.files[path], localHash != oldHash, localHash != hash,
               !replaceConflictsWithBackup { throw PreparationError.conflictingChanges }
            let destination = staging.appendingPathComponent(path)
            // Directory/file conflicts are not guessed away.
            if fm.fileExists(atPath: destination.path) {
                guard (try destination.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    throw PreparationError.conflictingChanges
                }
                try fm.removeItem(at: destination)
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: root.appendingPathComponent(path), to: destination)
            guard try fingerprint(destination) == hash else { throw PreparationError.sourceChanged }
        }
        for (path, hash) in prior.files where source.files[path] == nil && current.files[path] == hash {
            try fm.removeItem(at: staging.appendingPathComponent(path))
        }
        guard try snapshot(root, fingerprint: fingerprint) == source else {
            throw PreparationError.sourceChanged
        }
        guard (try staging.appendingPathComponent(relative).resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw CocoaError(.fileNoSuchFile)
        }
        try JSONEncoder().encode(source).write(to: staging.appendingPathComponent(manifestName), options: .atomic)
        try Data().write(to: staging.appendingPathComponent(oldStamp), options: .atomic)
        try Task.checkCancellation()
        let journal = Journal(staging: staging.lastPathComponent, backup: backup.lastPathComponent)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        journalWritten = true
        do {
            if hadTarget { try fm.moveItem(at: target, to: backup) }
            try fm.moveItem(at: staging, to: target)
            installed = true
            try fm.removeItem(at: journalURL)
            journalWritten = false
        } catch {
            if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: backup.path) {
                try fm.moveItem(at: backup, to: target)
            }
            if !installed {
                try fm.removeItem(at: journalURL)
                journalWritten = false
            }
            throw error
        }
        return windowsPath(relative)
    }

    static func steamMetadata(appID: String?, windowsExecutable: String) -> SteamMetadata? {
        guard let normalized = normalizedSteamAppID(appID) else { return nil }
        return SteamMetadata(appID: normalized, appPath: windowsDirectory(for: windowsExecutable))
    }

    static func steamMetadata(executable: URL, gameRoot: URL, windowsExecutable: String) -> SteamMetadata? {
        let root = gameRoot.resolvingSymlinksInPath().standardizedFileURL
        let exe = executable.resolvingSymlinksInPath().standardizedFileURL
        guard exe.path.hasPrefix(root.path + "/") else { return nil }

        for directory in uniqueSteamMetadataDirectories(executable: exe, gameRoot: root) {
            guard let appID = steamAppID(from: directory.appendingPathComponent("steam_appid.txt")) else { continue }
            return SteamMetadata(appID: appID, appPath: windowsDirectory(for: windowsExecutable))
        }
        return nil
    }

    private static func windowsPath(_ relative: String) -> String {
        "C:\\IridiumGame\\" + relative.replacingOccurrences(of: "/", with: "\\")
    }

    private static func windowsDirectory(for path: String) -> String {
        guard let separator = path.lastIndex(of: "\\") else { return "C:\\IridiumGame" }
        return String(path[..<separator])
    }

    private static func uniqueSteamMetadataDirectories(executable: URL, gameRoot: URL) -> [URL] {
        var directories: [URL] = []
        func append(_ url: URL) {
            let candidate = url.resolvingSymlinksInPath().standardizedFileURL
            if !directories.contains(candidate) { directories.append(candidate) }
        }
        append(executable.deletingLastPathComponent())
        append(gameRoot)
        return directories
    }

    private static func steamAppID(from url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 1024,
              let data = try? Data(contentsOf: url), data.count <= 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return normalizedSteamAppID(text)
    }

    private static func normalizedSteamAppID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.allSatisfy({ $0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue! }) else {
            return nil
        }
        return trimmed
    }

    static func validRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && parts.first != ".iridium" && path != manifestName && path != oldStamp
    }

    private static func snapshot(_ root: URL, fingerprint: (URL) throws -> String) throws -> Manifest {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        let values = try root.resourceValues(forKeys: Set(keys))
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                             errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var files: [String: String] = [:]
        var directories: [String] = []
        for case let item as URL in enumerator {
            try Task.checkCancellation()
            let relative = String(item.path.dropFirst(root.path.count + 1))
            if relative == ".iridium" || relative == manifestName || relative == oldStamp {
                enumerator.skipDescendants()
                continue
            }
            guard validRelativePath(relative) else { throw CocoaError(.fileReadInvalidFileName) }
            let itemValues = try item.resourceValues(forKeys: Set(keys))
            guard itemValues.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            if itemValues.isDirectory == true { directories.append(relative); continue }
            guard itemValues.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            files[relative] = try fingerprint(item)
        }
        if let enumerationError { throw enumerationError }
        return Manifest(files: files, directories: directories.sorted())
    }

    private static func recoverInterruptedUpdate(prefix: URL, target: URL) throws {
        let fm = FileManager.default
        let url = prefix.appendingPathComponent(journalName)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw PreparationError.invalidManifest
        }
        guard fm.fileExists(atPath: url.path) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: boundedData(url, maximumBytes: 4096))
        func valid(_ name: String, startingWith prefix: String) -> Bool {
            name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
                && !name.contains("/") && !name.contains("\\")
        }
        guard valid(journal.staging, startingWith: "game-copy-"),
              valid(journal.backup, startingWith: "game-backup-") else { throw PreparationError.invalidManifest }
        let staging = prefix.appendingPathComponent(journal.staging)
        let backup = prefix.appendingPathComponent(journal.backup)
        for candidate in [staging, backup, target] {
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw PreparationError.invalidManifest
            }
        }
        if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: backup.path) {
            try fm.moveItem(at: backup, to: target)
        }
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.removeItem(at: url)
    }

    private static func boundedData(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else { throw PreparationError.invalidManifest }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw PreparationError.invalidManifest }
        return data
    }

    private static func validateCompleteTree(_ root: URL) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let rootValues = try root.resourceValues(forKeys: Set(keys))
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        var failure: Error?
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, error in failure = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let url as URL in entries {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        if let failure { throw failure }
    }

    static func fingerprintFile(_ url: URL) throws -> String {
        #if canImport(CryptoKit)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        // Portable tests inject a fingerprint function; the iOS app uses CryptoKit.
        throw CocoaError(.featureUnsupported)
        #endif
    }

}
