import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Files selected only when the user shares diagnostics. Do not initialize
/// LogStore here: doing so rotates Madeira's log and can hide the failed run.
enum RuntimeDiagnosticLogFiles {
    private static let fileLimit = 4 * 1024 * 1024
    private static let consoleSink = RuntimeConsoleLogSink()

    static func existing(in documents: URL) -> [URL] {
        let names = [
            "iridium-runtime.log",
            "madeira-log.txt",
            "madeira-log.prev.txt",
            "iridium-runtime.previous.log",
            "iridium-console.log",
            "iridium-console.previous.log"
        ]
        var result = names.compactMap { name -> URL? in
            let url = documents.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  FileManager.default.isReadableFile(atPath: url.path)
            else { return nil }
            return url
        }
        let directory = documents.appendingPathComponent("logs", isDirectory: true)
        if let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           values.isDirectory == true, values.isSymbolicLink != true {
            let runs = ((try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []).filter { url in
                guard url.lastPathComponent.range(of: #"^.+-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.txt$"#,
                    options: .regularExpression) != nil,
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }.sorted { $0.lastPathComponent.suffix(23) > $1.lastPathComponent.suffix(23) }
            result += runs.prefix(40)
        }
        return result
    }

    /// A single shareable text document contains sanitized copies and an inventory.
    /// Originals are never opened for writing; the export has no private filenames.
    static func export(in documents: URL, destination: URL = FileManager.default.temporaryDirectory) throws -> URL {
        consoleSink.flush()
        let files = existing(in: documents)
        guard !files.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let folder = destination.appendingPathComponent("Iridium-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("Iridium-Diagnostics.txt")
        var text = "Iridium diagnostics\nCreated: \(Date.now.ISO8601Format())\n"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        text += "App: \(version) (\(build))\n"
        text += "Sanitized copies; original files preserved. Up to 4 MiB of each log's latest complete lines; includes the newest 40 native session logs.\n"
        text += "Runtime activity, submitted frames and changing images do not establish game loading progress.\n"
        do {
            try Data(text.utf8).write(to: output, options: .atomic)
            let writer = try FileHandle(forWritingTo: output)
            defer { try? writer.close() }
            try writer.seekToEnd()
            for (index, file) in files.enumerated() {
                let label = file.deletingLastPathComponent().lastPathComponent == "logs" ? "Native session \(index + 1)" : file.lastPathComponent
                text = "\n===== \(label) =====\n"
                do {
                    let tail = try readTail(file, limit: fileLimit)
                    text += "Original bytes: \(tail.bytes); truncated: \(tail.truncated)\n"
                    text += tail.lines.map { sanitizedLine($0) }.joined(separator: "\n") + "\n"
                } catch {
                    text += "Log could not be read (code \((error as NSError).code)). Original preserved.\n"
                }
                try writer.write(contentsOf: Data(text.utf8))
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func recentLines(in documents: URL, maximum: Int = 300) -> [String] {
        let current = existing(in: documents).filter {
            !$0.lastPathComponent.contains("prev") && $0.deletingLastPathComponent().standardizedFileURL.path == documents.standardizedFileURL.path
        }
        let quota = max(1, maximum / max(1, current.count))
        return current.flatMap { file -> [String] in
            guard let tail = try? readTail(file, limit: 65_536) else { return [] }
            return tail.lines.filter { !$0.isEmpty }.suffix(quota).map { "[\(file.lastPathComponent)] \(sanitizedLine($0))" }
        }.suffix(maximum).map { $0 }
    }

    private static func readTail(_ url: URL, limit: Int) throws -> (lines: [String], bytes: UInt64, truncated: Bool) {
        // Pin the selected parent and reject link swaps between inventory and
        // read, including a swapped native-session directory.
        let parent = url.deletingLastPathComponent().path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard parent >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(parent) }
        let descriptor = url.lastPathComponent.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw CocoaError(.fileReadNoPermission) }
        let end = try handle.seekToEnd()
        let start = end > UInt64(limit) ? end - UInt64(limit) : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: limit) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        // A partial line can omit its credential label; never export that fragment.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        if data.last != 10, !lines.isEmpty { lines.removeLast() }
        return (lines, end, start > 0)
    }

    private static let privateFields = try! NSRegularExpression(pattern: #"(?i)token|password|passwd|secret|authorization|cookie|credential|api[_-]?key|pairing|account|username|user[_ -]?id|device[_ -]?id|serial|udid|steam[_ -]?id|game[_ -]?id"#)
    private static let controlCharacters = try! NSRegularExpression(pattern: #"[\x00-\x1f\x7f]"#)
    private static let redactions = [
        #"(?i)https?://[^\s]+"#,
        #"(?i)[a-z]:[\\/][^\r\n]*"#,
        #"(?:\"|')/[^\r\n]*"#,
        #"/[^\r\n]*"#,
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
        #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
        #"(?i)\b[0-9a-f]{32,}\b"#,
        #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]+)?\b"#,
        #"(?i)(?<![0-9a-z:])(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}(?![0-9a-z:])"#,
        #"(?i)(?<![0-9a-z:])(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{0,4}::(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{0,4}(?:%[a-z0-9]+)?(?![0-9a-z:])"#,
        #"(?i)\b(?:session|identifier|user|host|name)\s*[:=]\s*[^\s,;]+"#
    ].map { try! NSRegularExpression(pattern: $0) }

    static func sanitizedLine(_ line: String) -> String {
        if privateFields.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            return "[Private log entry redacted]"
        }
        var clean = line
        for expression in redactions {
            clean = expression.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "[redacted]")
        }
        clean = controlCharacters.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "")
        return String(clean.prefix(16_384)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The core callback only copies a bounded entry and reserves a queue slot.
    static func writeConsoleLine(_ line: String) {
        consoleSink.append(line, important: !line.hasPrefix("[PSP core]") || line.hasPrefix("[PSP core] level=3"))
    }
}

/// All filesystem work belongs to one serial queue; pending closures and their
/// payloads are bounded. The lock protects only admission and loss counters.
final class RuntimeConsoleLogSink: @unchecked Sendable {
    private let queue: DispatchQueue
    private let directory: URL?
    private let maximumBytes: UInt64
    private let pendingLimit: Int
    private let lock = NSLock()
    private var pending = 0
    private var dropped: UInt64 = 0
    private var writeFailures: UInt64 = 0

    init(directory: URL? = nil, maximumBytes: UInt64 = 8 * 1024 * 1024,
         pendingLimit: Int = 128, queue: DispatchQueue = DispatchQueue(label: "software.iridium.console.logs", qos: .utility)) {
        self.directory = directory; self.maximumBytes = max(1024, maximumBytes)
        self.pendingLimit = max(2, pendingLimit); self.queue = queue
    }

    func append(_ line: String, important: Bool = false) {
        lock.lock()
        let limit = important ? pendingLimit : max(1, pendingLimit - min(16, pendingLimit / 4))
        guard pending < limit else { dropped &+= 1; lock.unlock(); return }
        pending += 1
        lock.unlock()
        // Bound bytes rather than Characters: a single grapheme can be enormous.
        let bounded = String(decoding: line.utf8.prefix(16_384), as: UTF8.self)
        let observedAt = Date()
        queue.async { [self] in
            let safe = bounded.components(separatedBy: "\n").map { RuntimeDiagnosticLogFiles.sanitizedLine($0) }.joined(separator: "\n")
            lock.lock()
            let lost = dropped; dropped = 0
            let failures = writeFailures; writeFailures = 0
            lock.unlock()
            var entry = ""
            if lost > 0 || failures > 0 {
                entry += "[Console log] dropped_entries=\(lost) failed_writes=\(failures)\n"
            }
            entry += "\(observedAt.ISO8601Format()) \(safe)\n"
            do { try write(Data(entry.utf8)) }
            catch {
                lock.lock(); dropped &+= lost; writeFailures &+= failures &+ 1; lock.unlock()
            }
            lock.lock(); pending -= 1; lock.unlock()
        }
    }

    /// Call off the main/runtime threads before exporting; never from this queue.
    func flush() { queue.sync {} }

    private func write(_ entry: Data) throws {
        let data = UInt64(entry.count) <= maximumBytes ? entry : Data("[Console log] oversized entry omitted\n".utf8)
        guard let documents = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fm = FileManager.default
        let file = documents.appendingPathComponent("iridium-console.log")
        if fm.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
            if UInt64(max(0, values.fileSize ?? 0)) + UInt64(data.count) > maximumBytes {
                let previous = documents.appendingPathComponent("iridium-console.previous.log")
                // POSIX rename atomically replaces the previous name. On failure,
                // the current log survives; no remove-then-move loss window.
                let result = file.path.withCString { from in
                    previous.path.withCString { to in rename(from, to) }
                }
                guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        // O_NOFOLLOW also rejects dangling links and path swaps after inspection.
        let descriptor = file.path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }
}
