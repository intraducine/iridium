// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit
import Darwin

enum IridiumImportFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// One writer owns inbox receipts. No game contents or pairing bytes enter them.
actor IridiumImportFiles {
    struct Receipt: Codable, Sendable {
        let id: UUID
        let path: String
        let fingerprint: String
        var choice: String?
        var expanded: String?
        var expandedFingerprint: String?
        var importedPayload: Bool? = nil
    }
    private struct Document: Codable {
        var version = 1
        var receipts: [String: Receipt] = [:]
        var pairingChoice = false
    }
    let storage: IridiumGameStorage
    private var state = Document()
    private var loaded = false
    private var savedData: Data?
    private var file: URL { storage.documents.appendingPathComponent(".iridium-import-receipts.json") }
    init(documents: URL) { storage = IridiumGameStorage(documents: documents) }

    func prepare(windows: [(UUID, String, Bool)], consoles: [UUID], oldConsoleRoot: URL, titles: [UUID: String] = [:]) throws {
        try storage.prepare()
        if !loaded {
            if FileManager.default.fileExists(atPath: file.path) {
                let values = try storage.checked(file).resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 4 * 1024 * 1024 else { throw IridiumGameStorage.Failure.unsafePath }
                let data = try readRecords() ?? Data()
                state = try JSONDecoder().decode(Document.self, from: data)
                savedData = data
                guard state.version == 1 else { throw IridiumGameStorage.Failure.newerLibrary }
            }
            loaded = true
        }
        try storage.nameGames(titles)
        try storage.migrateWindows(windows.map { (id: $0.0, relative: $0.1, steam: $0.2) }, titles: titles)
        try storage.migrateConsoles(consoles, from: oldConsoleRoot, titles: titles)
    }

    func children(_ folder: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: storage.checked(folder),
            includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        guard files.count <= 100_000 else { throw IridiumImportFailure.message("This folder contains too many files.") }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func receipt(_ url: URL) throws -> Receipt {
        let url = try storage.checked(url)
        guard url.path.hasPrefix(storage.inbox.path + "/") else { throw IridiumGameStorage.Failure.unsafePath }
        let path = String(url.path.dropFirst(storage.inbox.path.count + 1))
        let fingerprint = try signature(url)
        if let old = state.receipts[path], old.fingerprint == fingerprint { return old }
        let record = Receipt(id: UUID(), path: path, fingerprint: fingerprint)
        var next = state; next.receipts[path] = record
        try persist(next)
        return record
    }

    func choose(_ value: String, receipt: Receipt) throws {
        guard state.receipts[receipt.path]?.id == receipt.id else { throw IridiumGameStorage.Failure.unsafePath }
        var next = state; next.receipts[receipt.path]?.choice = value
        try persist(next)
    }

    func roots(registered: Set<UUID> = []) throws -> [URL] {
        try removeEmptyStagingFolders()
        var next = state
        for (path, _) in state.receipts {
            let source = try storage.checked(storage.inbox.appendingPathComponent(path))
            if !FileManager.default.fileExists(atPath: source.path) {
                if let receipt = next.receipts[path], registered.contains(receipt.id) { markArchive(path, in: &next) }
                next.receipts[path] = nil
            }
        }
        if next.receipts.count != state.receipts.count { try persist(next) }
        let expanded = Set(state.receipts.values.compactMap(\.expanded))
        var roots: [URL] = []
        for item in try children(storage.inbox) where !expanded.contains(item.lastPathComponent) {
            let received = item.appendingPathComponent(".iridium-received")
            if item.lastPathComponent.hasPrefix("From Files-"), try isDirectory(item),
               (try? matchesMarker(received, Data("Iridium file selection 1\n".utf8))) == true { roots += try children(item) }
            else { roots.append(item) }
        }
        return roots
    }

    func removeEmptyStagingFolders() throws {
        let pending = Set(state.receipts.values.compactMap(\.expanded))
        for folder in try children(storage.inbox) {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let received = folder.appendingPathComponent(".iridium-received")
            let extracted = folder.appendingPathComponent(".iridium-extracted")
            if folder.lastPathComponent.hasPrefix("From Files-"),
               (try? matchesMarker(received, Data("Iridium file selection 1\n".utf8))) == true {
                var budget = 100_000
                try pruneEmpty(folder, marker: received, budget: &budget)
            } else if !pending.contains(folder.lastPathComponent),
                      let size = try? storage.checked(extracted).resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 128, let data = try? Data(contentsOf: storage.checked(extracted)),
                      let text = String(data: data, encoding: .utf8) {
                let parts = text.split(separator: "\n")
                if parts.count == 2, let id = UUID(uuidString: String(parts[0])),
                   folder.lastPathComponent.hasSuffix(" extracted-" + id.uuidString), parts[1].count == 64,
                   parts[1].allSatisfy({ $0.isHexDigit }) {
                    var budget = 100_000
                    try pruneEmpty(folder, marker: extracted, budget: &budget)
                }
            }
        }
    }

    private func pruneEmpty(_ folder: URL, marker: URL? = nil, depth: Int = 0, budget: inout Int) throws {
        guard depth < 64 else { return }
        let fm = FileManager.default
        for child in try fm.contentsOfDirectory(at: storage.checked(folder), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            budget -= 1
            guard budget >= 0 else { throw IridiumFilesImport.Failure.tooManyFiles }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true { try pruneEmpty(child, depth: depth + 1, budget: &budget) }
        }
        let contents = try fm.contentsOfDirectory(atPath: folder.path)
        if let marker {
            guard contents == [marker.lastPathComponent] else { return }
            try fm.removeItem(at: storage.checked(marker))
        } else if !contents.isEmpty { return }
        // rmdir cannot remove a file that arrives after the empty-directory check.
        if folder.path.withCString({ Darwin.rmdir($0) }) != 0, errno != ENOTEMPTY, errno != EEXIST, errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func expand(_ source: URL, receipt: Receipt) throws -> URL {
        let fm = FileManager.default
        var title = String(source.deletingPathExtension().lastPathComponent.prefix(80))
        while title.utf8.count > 120 { title.removeLast() }
        let name = receipt.expanded ?? title + " extracted-" + receipt.id.uuidString
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.hasPrefix(".") else {
            throw IridiumGameStorage.Failure.unsafePath
        }
        let output = try storage.checked(storage.inbox.appendingPathComponent(name, isDirectory: true))
        let seal = Data((receipt.id.uuidString + "\n" + receipt.fingerprint).utf8)
        if receipt.expanded != nil, fm.fileExists(atPath: output.path) {
            let marker = try storage.checked(output.appendingPathComponent(".iridium-extracted"))
            guard try matchesMarker(marker, seal) else {
                throw IridiumGameStorage.Failure.unsafePath
            }
            return output
        }
        guard !fm.fileExists(atPath: output.path) else { throw IridiumGameStorage.Failure.unsafePath }
        let staging = try storage.checked(storage.inbox.appendingPathComponent(".extract-" + receipt.id.uuidString))
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? fm.removeItem(at: staging) } }
        let space = try storage.inbox.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let limit = min(UInt64(max(0, space ?? Int64(64 * 1024 * 1024 * 1024))), 64 * 1024 * 1024 * 1024)
        let status = ir_archive_extract(source.path, staging.path, limit, 100_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        guard status == 0 else {
            if status == 3 { throw CancellationError() }
            throw IridiumImportFailure.message(status == 2 ? "The archive exceeds the available space or import limits." :
                "This archive could not be unpacked safely. Incomplete, encrypted, or damaged archives stay in Import.")
        }
        guard try signature(source) == receipt.fingerprint else { throw IridiumFilesImport.Failure.sourceChanged }
        // The final name is published only after the entire stream passed its checks.
        let marker = try storage.checked(staging.appendingPathComponent(".iridium-extracted"))
        guard !fm.fileExists(atPath: marker.path) else { throw IridiumGameStorage.Failure.unsafePath }
        try seal.write(to: marker, options: .atomic)
        let fingerprint = try signature(staging)
        var next = state; next.receipts[receipt.path]?.expanded = name
        next.receipts[receipt.path]?.expandedFingerprint = fingerprint
        try persist(next)
        try fm.moveItem(at: staging, to: output)
        published = true
        return output
    }

    func discardUnchangedExpansion(_ receipt: Receipt) throws {
        guard let name = receipt.expanded, let expected = receipt.expandedFingerprint else { return }
        let folder = try storage.checked(storage.inbox.appendingPathComponent(name))
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if try signature(folder) == expected { try FileManager.default.removeItem(at: folder) }
    }

    func consume(_ source: URL, receipt: Receipt) throws {
        guard try signature(source) == receipt.fingerprint else { throw IridiumFilesImport.Failure.sourceChanged }
        // Persist the durable registration before deleting any inbox payload.
        var registered = state
        markArchive(receipt.path, in: &registered)
        try persist(registered)
        var error: NSError?, outcome: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forDeleting, error: &error) { url in
            outcome = Result {
                guard try signature(url) == receipt.fingerprint else { throw IridiumFilesImport.Failure.sourceChanged }
                try FileManager.default.removeItem(at: storage.checked(url))
            }
        }
        if let outcome { try outcome.get() } else { throw error ?? CocoaError(.fileWriteUnknown) }
        var next = state
        markArchive(receipt.path, in: &next)
        next.receipts[receipt.path] = nil
        try persist(next)
    }

    private func markArchive(_ path: String, in state: inout Document) {
        for key in Array(state.receipts.keys) {
            if let expanded = state.receipts[key]?.expanded, path.hasPrefix(expanded + "/") {
                state.receipts[key]?.importedPayload = true
            }
        }
    }

    func pairingNeedsChoice(count: Int) throws -> Bool {
        let choice = count > 1 || (count > 0 && state.pairingChoice)
        if choice != state.pairingChoice { var next = state; next.pairingChoice = choice; try persist(next) }
        return choice
    }

    func isDirectory(_ source: URL) throws -> Bool {
        try storage.checked(source).resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    func pairing(_ source: URL) throws -> Data {
        let source = try storage.checked(source)
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 1024 * 1024 else { throw IridiumImportFailure.message("Choose a pairing file smaller than 1 MB.") }
        return try Data(contentsOf: source)
    }

    func executables(_ folder: URL) throws -> [String] {
        try IridiumFilesImport.executablePaths(in: storage.checked(folder), isCancelled: { Task.isCancelled })
    }

    func files(_ folder: URL, validate: Bool = true) throws -> [URL] {
        if validate { _ = try signature(folder) }
        _ = try storage.checked(folder)
        var result: [URL] = []
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
        else { throw IridiumGameStorage.Failure.unsafePath }
        var count = 0
        for case let url as URL in walk {
            try Task.checkCancellation()
            count += 1
            guard count <= 100_000 else { throw IridiumFilesImport.Failure.tooManyFiles }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { walk.skipDescendants(); continue }
            if values.isRegularFile == true { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }

    func consoleGames(_ store: IridiumConsoleStore) throws -> [IridiumConsoleGame] { try store.load() }

    func detection(_ source: URL, siblings: [URL]) throws -> ([IridiumPlatform], Bool) {
        let platforms = try IridiumGameFileDetection.platforms(source, selectedFiles: siblings)
        return (platforms, try IridiumGameFileDetection.needsConfirmation(source, platforms: platforms))
    }

    func hasConsoleGame(_ folder: URL) throws -> Bool {
        for source in try files(folder) where IridiumConsoleSystem.all.flatMap(\.extensions).contains(source.pathExtension.lowercased()) && source.pathExtension.lowercased() != "zip" {
            try Task.checkCancellation()
            let siblings = try children(source.deletingLastPathComponent())
            if (try? detection(source, siblings: siblings)) != nil { return true }
        }
        return false
    }

    func importConsole(_ source: URL, receipt: Receipt, platform: IridiumPlatform, siblings: [URL], store: IridiumConsoleStore) throws -> IridiumConsoleGame {
        try IridiumFilesAccess.readGame(source, selectedFiles: siblings) { url, files in
            try store.importROM(url, into: store.load(), preferredPlatform: platform, selectedFiles: files, gameID: receipt.id)
        }
    }

    func importWindows(_ source: URL, folder: URL?, receipt: Receipt) throws -> IridiumFilesImport.Imported {
        let imported = try IridiumFilesImport.importExecutable(at: source, drive: storage.drive, sourceRoot: folder,
            managedGamesRoot: storage.games, importID: receipt.id, isCancelled: { Task.isCancelled })
        try storage.prepareWindowsLink()
        return imported
    }

    func discFiles(_ source: URL, siblings: [URL]) throws -> [URL] {
        guard ["gdi", "cue"].contains(source.pathExtension.lowercased()) else { return [] }
        return try IridiumDiscSet(source, selectedFiles: siblings).filenames.map { source.deletingLastPathComponent().appendingPathComponent($0) }
    }

    func consumeTrack(_ track: URL, receipt: Receipt) throws {
        // A track can belong to more than one disc. Leave it until the last manifest is imported.
        for file in try files(storage.inbox, validate: false) where ["cue", "gdi"].contains(file.pathExtension.lowercased()) {
            let companions = try children(file.deletingLastPathComponent())
            // A damaged manifest still owns its possible sidecars until the user repairs it.
            guard let tracks = try? discFiles(file, siblings: companions) else { return }
            if tracks.contains(track) { return }
        }
        try consume(track, receipt: receipt)
    }

    func existing(_ paths: [String]) -> Set<String> {
        Set(paths.filter { path in
            guard let source = try? storage.checked(storage.inbox.appendingPathComponent(path)) else { return true }
            return FileManager.default.fileExists(atPath: source.path)
        })
    }

    func receive(_ urls: [URL]) throws {
        try storage.prepare()
        let fm = FileManager.default
        let staging = try storage.checked(storage.inbox.appendingPathComponent(".receive-" + UUID().uuidString))
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var names = Set<String>()
        for url in urls {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), names.insert(name.lowercased()).inserted else { throw IridiumFilesImport.Failure.conflictingPath }
            try IridiumFilesAccess.read(url) { source in
                let path = source.standardizedFileURL.path
                if path == storage.inbox.path || path.hasPrefix(storage.inbox.path + "/") { return }
                guard !storage.inbox.path.hasPrefix(path + "/") else { throw IridiumFilesImport.Failure.outsideFolder }
                if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    _ = try IridiumFilesImport.executablePaths(in: source, isCancelled: { Task.isCancelled })
                } else {
                    _ = try IridiumROMInspection.checkedFile(source)
                    guard (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 * 1024 * 1024 else {
                        throw IridiumFilesImport.Failure.tooLarge
                    }
                }
                try FileManager.default.copyItem(at: source, to: staging.appendingPathComponent(name))
            }
        }
        guard !(try fm.contentsOfDirectory(atPath: staging.path)).isEmpty else { return }
        try Data("Iridium file selection 1\n".utf8).write(to: staging.appendingPathComponent(".iridium-received"), options: .atomic)
        let destination = try storage.checked(storage.inbox.appendingPathComponent("From Files-" + UUID().uuidString))
        try fm.moveItem(at: staging, to: destination)
    }

    func signature(_ source: URL) throws -> String {
        let source = try storage.checked(source), fm = FileManager.default
        var urls = [source]
        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            var failure: Error?
            guard let walk = fm.enumerator(at: source, includingPropertiesForKeys: nil,
                errorHandler: { _, error in failure = error; return false }) else { throw IridiumGameStorage.Failure.unsafePath }
            for case let file as URL in walk {
                urls.append(file)
                guard urls.count <= 100_000 else { throw IridiumFilesImport.Failure.tooManyFiles }
            }
            if let failure { throw failure }
        }
        var hash = SHA256()
        for file in urls.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            _ = try storage.checked(file)
            let info = try fm.attributesOfItem(atPath: file.path)
            guard let type = info[.type] as? FileAttributeType, type == .typeRegular || type == .typeDirectory else {
                throw IridiumGameStorage.Failure.unsafePath
            }
            let path = String(file.path.dropFirst(source.path.count))
            hash.update(data: Data("\(path)\0\(info[.systemFileNumber] ?? 0)\0\(info[.size] ?? 0)\0\((info[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)\n".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func matchesMarker(_ file: URL, _ expected: Data) throws -> Bool {
        let input = try FileHandle(forReadingFrom: storage.checked(file))
        defer { try? input.close() }
        return try input.read(upToCount: expected.count + 1) == expected
    }

    private func readRecords() throws -> Data? {
        let path = try storage.checked(file)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let input = try FileHandle(forReadingFrom: path)
        defer { try? input.close() }
        let data = try input.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 4 * 1024 * 1024 else { throw IridiumGameStorage.Failure.unsafePath }
        return data
    }

    private func persist(_ next: Document) throws {
        let data = try JSONEncoder().encode(next)
        guard data.count <= 4 * 1024 * 1024 else { throw IridiumImportFailure.message("Too many pending imports. Finish or remove some files, then retry.") }
        guard try readRecords() == savedData else {
            throw IridiumImportFailure.message("Import records changed outside Iridium. Close and reopen the app, then retry. Original files stay in Import.")
        }
        try data.write(to: storage.checked(file), options: .atomic)
        savedData = data
        state = next
    }
}
