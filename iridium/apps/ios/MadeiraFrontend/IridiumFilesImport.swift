// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Copy-only import from an explicitly selected Files document or folder.
/// The caller owns security-scoped access and runs this work off the UI thread.
enum IridiumFilesImport {
    /// Disk publication can outlive its sheet. Only the initiating presentation
    /// may update selection or dismiss itself when that publication finishes.
    static func shouldPresentCompletion(of sourceID: UUID, currentSourceID: UUID?) -> Bool {
        sourceID == currentSourceID
    }

    /// One import's cancellation-to-commit handoff. Once accepted, the caller
    /// must finish saving the returned entry even if its task is cancelled.
    /// Never reuse this gate for a second import.
    final class Publication: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var accepted = false

        var isAccepted: Bool {
            lock.lock(); defer { lock.unlock() }
            return accepted
        }

        /// True means cancellation won and the worker may be cancelled. False
        /// means publication already won; keep the continuation alive to save.
        @discardableResult
        func cancel() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !accepted else { return false }
            cancelled = true
            return true
        }

        fileprivate func checkCancellation() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }

        fileprivate func accept(isCancelled: Bool) throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled || isCancelled { throw CancellationError() }
            guard !accepted else { throw Failure.conflictingPath }
            accepted = true
        }
    }

    struct Imported: Sendable {
        let relativePath: String
        let title: String
        let bits: Int
        /// Nil means the original executable already lives in the shared drive.
        let importID: UUID?
        let copiedContainingFolder: Bool
    }

    struct Limits: Sendable {
        var maximumEntries = 100_000
        var maximumBytes: Int64 = 64 * 1024 * 1024 * 1024
        var maximumExecutables = 100
    }

    enum Failure: LocalizedError, Equatable {
        case invalidPath, symbolicLink, notRegularFile, invalidExecutable
        case unsupportedArchitecture, outsideFolder, tooManyFiles, tooLarge
        case tooManyExecutables, conflictingPath, sourceChanged

        var errorDescription: String? {
            switch self {
            case .invalidPath: return "A game file has a path Windows cannot use. Choose a folder with ordinary file names."
            case .symbolicLink: return "This selection contains a symbolic link. Choose the original game files instead."
            case .notRegularFile: return "Choose a regular Windows executable (.exe) or its game folder."
            case .invalidExecutable: return "This file is not a valid Windows executable."
            case .unsupportedArchitecture: return "Only x86 and x64 Windows executables are supported."
            case .outsideFolder: return "The executable must be inside the selected game folder."
            case .tooManyFiles: return "This folder contains too many files. Choose a smaller game folder."
            case .tooLarge: return "This game exceeds the import size limit. Choose a smaller game folder."
            case .tooManyExecutables: return "This folder contains too many executables. Choose a more specific game folder."
            case .conflictingPath: return "Two files use the same Windows path, or an import destination already exists. No existing files were replaced."
            case .sourceChanged: return "The game files changed during import. Wait for any download or copy to finish, then try again."
            }
        }
    }

    /// A folder grant is required to copy dependencies. A file grant alone only
    /// copies that EXE; never infer authority over its parent from its name.
    static func importExecutable(at source: URL, drive: URL, sourceRoot: URL? = nil,
                                 limits: Limits = .init(),
                                 publication: Publication = .init(),
                                 isCancelled: () -> Bool = { false }) throws -> Imported {
        try checkCancellation(isCancelled)
        try publication.checkCancellation()
        let source = try checkedPath(source)
        let drive = try checkedPath(drive)
        let bits = try executableBits(source)
        let title = source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        if isInside(source, root: drive) {
            let relative = try relativePath(source, root: drive)
            try publication.accept(isCancelled: isCancelled())
            return Imported(relativePath: relative, title: title, bits: bits,
                            importID: nil, copiedContainingFolder: false)
        }

        let root: URL
        let items: [Item]
        if let sourceRoot {
            root = try checkedPath(sourceRoot)
            guard try attributes(root)[.type] as? FileAttributeType == .typeDirectory,
                  isInside(source, root: root), !isInside(drive, root: root), drive != root else {
                throw Failure.outsideFolder
            }
            items = try contents(in: root, limits: limits, isCancelled: isCancelled)
        } else {
            root = source.deletingLastPathComponent()
            let item = try item(at: source, root: root)
            guard limits.maximumEntries >= 1 else { throw Failure.tooManyFiles }
            guard item.size <= limits.maximumBytes else { throw Failure.tooLarge }
            items = [item]
        }
        let executable = try relativePath(source, root: root)
        guard items.contains(where: { $0.relativePath == executable && !$0.isDirectory }) else {
            throw Failure.notRegularFile
        }
        try checkCancellation(isCancelled)

        let fm = FileManager.default
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        let imports = drive.appendingPathComponent("Imported", isDirectory: true)
        _ = try checkedPath(imports)
        do {
            guard try attributes(imports)[.type] as? FileAttributeType == .typeDirectory else {
                throw Failure.conflictingPath
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            try fm.createDirectory(at: imports, withIntermediateDirectories: false)
        }
        let id = UUID()
        let destination = imports.appendingPathComponent(id.uuidString, isDirectory: true)
        let staging = drive.appendingPathComponent(".iridium-files-import-" + id.uuidString, isDirectory: true)
        // Only remove a staging directory successfully created by this call.
        guard !fm.fileExists(atPath: staging.path), !fm.fileExists(atPath: destination.path) else {
            throw Failure.conflictingPath
        }
        _ = try checkedPath(staging)
        _ = try checkedPath(destination)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var ownsStaging = true
        defer { if ownsStaging { try? fm.removeItem(at: staging) } }
        var copiedBytes: Int64 = 0
        for entry in items {
            try checkCancellation(isCancelled)
            let input = root.appendingPathComponent(entry.relativePath)
            let output = staging.appendingPathComponent(entry.relativePath)
            _ = try checkedPath(staging)
            _ = try checkedPath(output)
            guard try item(at: input, root: root).matches(entry) else { throw Failure.sourceChanged }
            if entry.isDirectory {
                try fm.createDirectory(at: output, withIntermediateDirectories: false)
            } else {
                try copy(entry, from: input, to: output, root: root,
                         copiedBytes: &copiedBytes, limit: limits.maximumBytes, isCancelled: isCancelled)
            }
        }
        // Validate the copied EXE too; the selected file may have changed while
        // a provider was downloading or while dependencies were being copied.
        guard try executableBits(staging.appendingPathComponent(executable)) == bits else {
            throw Failure.sourceChanged
        }
        try checkCancellation(isCancelled)
        _ = try checkedPath(imports)
        _ = try checkedPath(staging)
        // Cancellation and acceptance serialize through the same gate. After
        // this point the caller must persist the result instead of discarding
        // it on a cancelled MainActor continuation, leaving an unlisted copy.
        try publication.accept(isCancelled: isCancelled())
        // moveItem never replaces an existing destination. Publication is one
        // same-volume move, and library-entry persistence belongs to the caller.
        try fm.moveItem(at: staging, to: destination)
        ownsStaging = false
        return Imported(relativePath: "Imported/" + id.uuidString + "/" + executable,
                        title: title, bits: bits, importID: id,
                        copiedContainingFolder: sourceRoot != nil)
    }

    /// Only supported PE executables are offered. Folder traversal and total
    /// bytes are bounded even when the folder contains no executable at all.
    static func executableCandidates(in folder: URL, limits: Limits = .init(),
                                     isCancelled: () -> Bool = { false }) throws -> [URL] {
        try checkCancellation(isCancelled)
        let folder = try checkedPath(folder)
        let entries = try contents(in: folder, limits: limits, isCancelled: isCancelled)
        let executables = entries.filter { !$0.isDirectory && ($0.relativePath as NSString).pathExtension.lowercased() == "exe" }
        guard executables.count <= limits.maximumExecutables else { throw Failure.tooManyExecutables }
        var result: [URL] = []
        for entry in executables.sorted(by: { $0.relativePath < $1.relativePath }) {
            try checkCancellation(isCancelled)
            let url = folder.appendingPathComponent(entry.relativePath)
            do {
                _ = try executableBits(url)
                result.append(url)
            } catch Failure.invalidExecutable {
                continue
            } catch Failure.unsupportedArchitecture {
                continue
            }
        }
        try checkCancellation(isCancelled)
        return result
    }

    private struct Item {
        let relativePath: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date?
        let inode: UInt64?

        func matches(_ other: Item) -> Bool {
            relativePath == other.relativePath && isDirectory == other.isDirectory &&
                size == other.size && modified == other.modified && inode == other.inode
        }
    }

    private static func contents(in root: URL, limits: Limits,
                                 isCancelled: () -> Bool) throws -> [Item] {
        guard try attributes(root)[.type] as? FileAttributeType == .typeDirectory else { throw Failure.notRegularFile }
        var readError: Error?
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                        errorHandler: { _, error in readError = error; return false }) else {
            throw Failure.notRegularFile
        }
        var result: [Item] = []
        var paths = Set<String>()
        var bytes: Int64 = 0
        for case let url as URL in walk {
            try checkCancellation(isCancelled)
            guard result.count < limits.maximumEntries else { throw Failure.tooManyFiles }
            let entry = try item(at: url, root: root)
            // Windows names are case-insensitive even on a case-sensitive host.
            let key = entry.relativePath.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(key).inserted else { throw Failure.conflictingPath }
            guard entry.size <= limits.maximumBytes - bytes else { throw Failure.tooLarge }
            bytes += entry.size
            result.append(entry)
        }
        if let readError { throw readError }
        // Parents before children, independently of a provider's walk order.
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private static func item(at url: URL, root: URL) throws -> Item {
        let url = try checkedPath(url)
        let relative = try relativePath(url, root: root)
        let values = try attributes(url)
        let type = values[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeDirectory else { throw Failure.notRegularFile }
        let directory = type == .typeDirectory
        let size = directory ? 0 : (values[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0 else { throw Failure.notRegularFile }
        return Item(relativePath: relative, isDirectory: directory, size: size,
                    modified: values[.modificationDate] as? Date,
                    inode: (values[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private static func copy(_ entry: Item, from input: URL, to output: URL, root: URL,
                             copiedBytes: inout Int64, limit: Int64,
                             isCancelled: () -> Bool) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw Failure.conflictingPath }
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        guard fm.createFile(atPath: output.path, contents: nil) else { throw Failure.conflictingPath }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var fileBytes: Int64 = 0
        while true {
            try checkCancellation(isCancelled)
            let data = try reader.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            let size = Int64(data.count)
            guard size <= entry.size - fileBytes else { throw Failure.sourceChanged }
            guard size <= limit - copiedBytes else { throw Failure.tooLarge }
            try writer.write(contentsOf: data)
            fileBytes += size
            copiedBytes += size
        }
        guard fileBytes == entry.size, try item(at: input, root: root).matches(entry) else { throw Failure.sourceChanged }
        try writer.close()
        if let modified = entry.modified {
            // A copied save must not appear newer just because it was imported.
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: output.path)
        }
    }

    private static func executableBits(_ url: URL) throws -> Int {
        _ = try checkedPath(url)
        let values = try attributes(url)
        guard values[.type] as? FileAttributeType == .typeRegular,
              url.pathExtension.lowercased() == "exe" else { throw Failure.notRegularFile }
        let size = (values[.size] as? NSNumber)?.uint64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let dos = try handle.read(upToCount: 64) ?? Data()
        guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { throw Failure.invalidExecutable }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | UInt64(dos[60 + $1]) << ($1 * 8) }
        guard offset >= 64, offset < 16 * 1024 * 1024, size >= offset + 26 else { throw Failure.invalidExecutable }
        try handle.seek(toOffset: offset)
        let pe = try handle.read(upToCount: 26) ?? Data()
        guard pe.count == 26, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { throw Failure.invalidExecutable }
        let machine = Int(pe[4]) | Int(pe[5]) << 8
        guard machine == 0x14c || machine == 0x8664 else { throw Failure.unsupportedArchitecture }
        let optionalSize = Int(pe[20]) | Int(pe[21]) << 8
        let flags = Int(pe[22]) | Int(pe[23]) << 8
        let magic = Int(pe[24]) | Int(pe[25]) << 8
        guard flags & 2 != 0, flags & 0x2000 == 0,
              optionalSize >= (machine == 0x14c ? 96 : 112),
              magic == (machine == 0x14c ? 0x10b : 0x20b),
              offset + 24 + UInt64(optionalSize) <= size else { throw Failure.invalidExecutable }
        return machine == 0x14c ? 32 : 64
    }

    private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any] {
        let result = try FileManager.default.attributesOfItem(atPath: url.path)
        guard result[.type] as? FileAttributeType != .typeSymbolicLink else { throw Failure.symbolicLink }
        return result
    }

    private static func checkedPath(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw Failure.invalidPath }
        let path = url.standardizedFileURL
        guard path.path == path.resolvingSymlinksInPath().path else { throw Failure.symbolicLink }
        // resolvingSymlinksInPath does not reliably expose dangling links.
        // Do not stat ancestors outside the document's security-scoped grant.
        do { _ = try attributes(path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
        return path
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") && url != root
    }

    private static func relativePath(_ url: URL, root: URL) throws -> String {
        guard isInside(url, root: root) else { throw Failure.outsideFolder }
        let relative = String(url.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        let forbidden = CharacterSet(charactersIn: "<>:\"\\|?*").union(.controlCharacters)
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })
        guard relative.utf8.count <= 4096, components.count <= 64,
              components.allSatisfy({ part in
                  !part.isEmpty && part != "." && part != ".." && part.last != "." && part.last != " " &&
                      !reserved.contains(String(part.split(separator: ".", omittingEmptySubsequences: false).first ?? part).uppercased()) &&
                      part.unicodeScalars.allSatisfy { !forbidden.contains($0) }
              }) else { throw Failure.invalidPath }
        return relative
    }

    private static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }
}
