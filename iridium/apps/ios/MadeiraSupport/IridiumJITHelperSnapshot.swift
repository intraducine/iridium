// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

/// Shared by the generated app and helper. Only fixed diagnostic records cross
/// the existing extension request channel; retrieval never rotates the journal.
enum IridiumJITHelperSnapshot {
    static func newAttemptID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
    }

    static func validAttemptID(_ value: String) -> Bool {
        value.utf8.count == 16 && value.range(of: #"\A[0-9a-f]{16}\z"#, options: .regularExpression) != nil
    }

    private static let setup = try! NSRegularExpression(pattern:
        #"\AIRJIT2 stage=setup\.(attach|ignore|pass) status=(ok|empty|error|stop|other)\z"#)
    private static let stop = try! NSRegularExpression(pattern:
        #"\AIRJIT2 stage=first\.(stop|fault|exit) kind=(stop|exit|signal) signal=([0-9]{1,2}) exception=([0-9]{1,2}) code=([0-9]{1,3})(?:(?: pc=([0-9a-f]{16}|missing|invalid) addr=([0-9a-f]{16}|missing|invalid))? md=(0|1|2|more) insn=(mov42|mov7|ret|other|unreadable))?\z"#)
    private static let privateLocation = try! NSRegularExpression(pattern:
        #" pc=(?:[0-9a-f]{16}|missing|invalid) addr=(?:[0-9a-f]{16}|missing|invalid)"#)
    private static let begin = try! NSRegularExpression(pattern:
        #"\AIRJIT2 stage=helper.begin build=[A-Za-z0-9._-]{1,40}\z"#)
    private static let record = try! NSRegularExpression(pattern:
        #"\Autc=[0-9]{1,12}\.[0-9]{6} attempt=[0-9a-f]{16} (IRJIT2 .+)\z"#)

    static func validPayload(_ line: String) -> Bool {
        let full = NSRange(line.startIndex..., in: line)
        if setup.firstMatch(in: line, range: full) != nil || begin.firstMatch(in: line, range: full) != nil { return true }
        guard let match = stop.firstMatch(in: line, range: full),
              let signalRange = Range(match.range(at: 3), in: line),
              let exceptionRange = Range(match.range(at: 4), in: line),
              let codeRange = Range(match.range(at: 5), in: line),
              let signal = Int(line[signalRange]), signal <= 31,
              let exception = Int(line[exceptionRange]), exception <= 13,
              let code = Int(line[codeRange]), code <= 255 else { return false }
        if match.range(at: 8).location != NSNotFound {
            guard let stage = Range(match.range(at: 1), in: line), line[stage] == "fault",
                  let kind = Range(match.range(at: 2), in: line), line[kind] == "stop" else { return false }
        }
        return true
    }

    static func publicPayload(_ line: String) -> String? {
        guard validPayload(line) else { return nil }
        return privateLocation.stringByReplacingMatches(in: line,
            range: NSRange(line.startIndex..., in: line), withTemplate: "")
    }

    static func validRecord(_ line: String) -> Bool {
        guard line.utf8.count < 240,
              let match = record.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let payload = Range(match.range(at: 1), in: line) else { return false }
        return validPayload(String(line[payload]))
    }

    private static func publicRecord(_ line: String) -> String? {
        guard validRecord(line) else { return nil }
        return privateLocation.stringByReplacingMatches(in: line,
            range: NSRange(line.startIndex..., in: line), withTemplate: "")
    }

    static func read(in directory: URL) -> [String] {
        ["iridium-jit-helper.previous.log", "iridium-jit-helper.log"].flatMap {
            readFile($0, in: directory, limit: 4096, records: 16)
        }
    }

    private static func readFile(_ name: String, in directory: URL, limit: Int, records: Int) -> [String] {
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return [] }
        defer { close(folder) }
        let descriptor = openat(folder, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1, status.st_size <= limit else { return [] }
        var data = [UInt8](repeating: 0, count: limit)
        var count = 0
        while count < limit {
            let size = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: count), limit - count) }
            if size < 0 && errno == EINTR { continue }
            if size <= 0 { break }
            count += size
        }
        // An interrupted write may leave a fragment. Never interpret that fragment.
        var lines = String(decoding: data.prefix(count), as: UTF8.self).components(separatedBy: "\n")
        lines.removeLast()
        return Array(lines.prefix(records).filter(validRecord))
    }

    /// Revalidate on the app side and merge rather than erasing a prior snapshot
    /// when the helper is unavailable, empty or has only a partially written tail.
    static func mirror(_ records: [String], in directory: URL) throws {
        guard records.count <= 32, records.allSatisfy(validRecord) else { throw CocoaError(.fileReadCorruptFile) }
        guard !records.isEmpty else { return }
        let name = "iridium-jit-helper-mirror.log"
        var combined = readFile(name, in: directory, limit: 8192, records: 32).compactMap(publicRecord)
        for record in records.compactMap(publicRecord) where !combined.contains(record) { combined.append(record) }
        let data = Array((combined.suffix(32).joined(separator: "\n") + "\n").utf8)
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(folder) }
        var status = stat()
        let exists = fstatat(folder, name, &status, AT_SYMLINK_NOFOLLOW)
        guard (exists == 0 && status.st_mode & S_IFMT == S_IFREG && status.st_nlink == 1)
            || (exists != 0 && errno == ENOENT) else { throw CocoaError(.fileWriteNoPermission) }
        let temporary = ".iridium-helper-\(UUID().uuidString)"
        let descriptor = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor); unlinkat(folder, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        var synced: Int32
        repeat { synced = fsync(descriptor) } while synced < 0 && errno == EINTR
        guard synced == 0, renameat(folder, temporary, folder, name) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
