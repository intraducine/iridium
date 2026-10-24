// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Codable messages shared by Madeira and its JIT helper extension. Each travels as JSON
/// in an extension request's item (userInfo[itemKey]), to the helper and back.
struct MadeiraJITRequest: Codable, Sendable {
    static let itemKey = "madeira-jit-request"

    enum Operation: String, Codable, Sendable {
        case prepare
        case enable
        case resetDDI
        case diagnostics
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let scriptBase64: String?
    var diagnosticAttemptID: String? = nil
    var pspProtocolVersion: Int? = nil
    var pspAttemptID: String? = nil
    var pspScriptSHA256: String? = nil

    static func prepare(pairingData: Data) -> MadeiraJITRequest {
        MadeiraJITRequest(operation: .prepare, targetPID: nil,
                          pairingData: pairingData, scriptBase64: nil)
    }

    static func enable(targetPID: Int32, pairingData: Data,
                       scriptBase64: String) -> MadeiraJITRequest {
        MadeiraJITRequest(operation: .enable, targetPID: targetPID,
                          pairingData: pairingData, scriptBase64: scriptBase64,
                          diagnosticAttemptID: IridiumJITHelperSnapshot.newAttemptID())
    }

    static var resetDDI: MadeiraJITRequest {
        MadeiraJITRequest(operation: .resetDDI, targetPID: nil,
                          pairingData: nil, scriptBase64: nil)
    }

    static var diagnostics: MadeiraJITRequest {
        MadeiraJITRequest(operation: .diagnostics, targetPID: nil, pairingData: nil,
                          scriptBase64: nil, diagnosticAttemptID: IridiumJITHelperSnapshot.newAttemptID())
    }

    struct Response: Codable, Sendable {
        static let itemKey = "madeira-jit-response"
        let success: Bool
        let message: String
        let txmPresent: Bool?
        var diagnosticAttemptID: String? = nil
        var diagnosticRecords: [String]? = nil
        var pspReceipt: IridiumPSPHelperReceipt? = nil
        var debuggerReleased: Bool? = nil
    }
}

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
        if line == "IRJIT2 stage=helper.return clean=0" || line == "IRJIT2 stage=helper.return clean=1" { return true }
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

// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

struct IridiumPSPHelperArena: Codable, Equatable, Sendable {
    var sequence: Int
    var bytes: Int
    var address: String
    var pointer: UInt64? {
        guard bytes > 0, bytes <= 16_777_216,
              address.range(of: #"\A[0-9a-f]{16}\z"#, options: .regularExpression) != nil,
              let value = UInt64(address, radix: 16), value > 0, value & 16383 == 0,
              value < (1 << 36), UInt64(bytes) <= (1 << 36) - value else { return nil }
        return value
    }
}

struct IridiumPSPHelperReceipt: Codable, Sendable {
    var version = 2
    var attempt: String
    var scriptSHA256: String
    var targetPID: Int32
    var stage = "begin"
    var sequence = 0
    var preparedCount = 0
    var arenas: [IridiumPSPHelperArena] = [] // Private owned allocations, including a definitive preparation failure.
    var bytes = 0
    var address: String? = nil // Helper-private; omitted from public summaries.
    var ready = false
    var detachAcknowledged = false
    var sdkReturnedClean = false
    var terminal = false
    // Optional for receipts saved by older builds. Never authorizes readiness.
    var phase: Int? = nil
    var code: Int? = nil
    var replyLength: Int? = nil
    var replyFields: Int? = nil
    var firstIssuePhase: Int? = nil
    var firstIssueCode: Int? = nil
    // Definitive preparation failure survives optional setup warnings and D/SDK
    // completion. Fixed numbers only; never a debugger reply or remote field.
    var preparationFailureCode: Int? = nil
    var preparationFailureSequence: Int? = nil
    var preparationFailureError: Int? = nil

    private static func validPhase(_ value: Int) -> Bool {
        [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 13, 14, 15, 16, 17].contains(value)
    }
    static func validDiagnostic(phase: Int, code: Int, length: Int, fields: Int) -> Bool {
        validPhase(phase) && ((0...26).contains(code) || (29...43).contains(code))
        && (0...65535).contains(length) && (0...255).contains(fields)
    }
    private var validDiagnostics: Bool {
        let values = [phase, code, replyLength, replyFields]
        let complete = values.allSatisfy { $0 == nil } || (values.allSatisfy { $0 != nil }
            && Self.validDiagnostic(phase: phase!, code: code!, length: replyLength!, fields: replyFields!))
        let issue = (firstIssuePhase == nil && firstIssueCode == nil)
            || (firstIssuePhase.map(Self.validPhase) == true
                && firstIssueCode.map { (2...26).contains($0) || (29...43).contains($0) } == true)
        let preparation = [preparationFailureCode, preparationFailureSequence, preparationFailureError]
        let validPreparation = preparation.allSatisfy { $0 == nil }
            || (preparation.allSatisfy { $0 != nil } && [22, 23, 39].contains(preparationFailureCode!)
                && (1...4).contains(preparationFailureSequence!) && (0...255).contains(preparationFailureError!)
                && (preparationFailureCode != 22 || preparationFailureError == 0))
        return complete && issue && validPreparation && (firstIssueCode == nil || phase != nil)
    }

    var valid: Bool {
        guard version == 2 && targetPID > 0 && IridiumJITHelperSnapshot.validAttemptID(attempt)
        && scriptSHA256.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
        && ["begin", "ready", "allocated", "prepared", "prepare.failed", "detach.ack", "sdk.return", "terminal"].contains(stage)
        && (0...4).contains(sequence) && (0...4).contains(preparedCount)
        && (0...16_777_216).contains(bytes)
        && (address == nil || address!.range(of: #"\A[0-9a-f]{16}\z"#, options: .regularExpression) != nil)
        && (!sdkReturnedClean || detachAcknowledged)
        && validDiagnostics && arenas.count <= 4 && preparedCount <= arenas.count
        && arenas.count <= preparedCount + 1 else { return false }
        for (index, arena) in arenas.enumerated() {
            guard arena.sequence == index + 1, arena.bytes == (index == 0 ? 16_777_216 : 262_144),
                  let pointer = arena.pointer else { return false }
            for previous in arenas.prefix(index) {
                guard let other = previous.pointer,
                      pointer >= other + UInt64(previous.bytes) || other >= pointer + UInt64(arena.bytes) else { return false }
            }
        }
        if terminal { return stage == "terminal" }
        switch stage {
        case "begin", "ready": return ready == (stage == "ready") && !detachAcknowledged && !sdkReturnedClean
            && sequence == 0 && preparedCount == 0 && arenas.isEmpty && bytes == 0 && address == nil
        case "allocated": return ready && !detachAcknowledged && !sdkReturnedClean && sequence == arenas.count && sequence == preparedCount + 1
            && address == arenas.last?.address && bytes == arenas.last?.bytes
        case "prepared": return ready && !detachAcknowledged && !sdkReturnedClean && sequence == preparedCount && arenas.count == preparedCount
            && sequence > 0 && address == arenas.last?.address && bytes == arenas.last?.bytes
        case "prepare.failed": return ready && !detachAcknowledged && !sdkReturnedClean && sequence == preparedCount + 1 && (1...4).contains(sequence)
            && bytes == (sequence == 1 ? 16_777_216 : 262_144)
            && (arenas.count == sequence ? address == arenas.last?.address : address == nil)
        case "detach.ack", "sdk.return": return ready && detachAcknowledged && sdkReturnedClean == (stage == "sdk.return")
            && sequence == preparedCount && bytes == 0 && address == nil
        default: return false
        }
    }
    func matches(attempt: String, hash: String, pid: Int32) -> Bool {
        valid && self.attempt == attempt && scriptSHA256 == hash && targetPID == pid
    }
    var publicSummary: String {
        var summary = "[PSP helper] version=\(version) attempt=\(attempt) stage=\(stage) sequence=\(sequence) allocated=\(arenas.count) prepared=\(preparedCount) detach=\(detachAcknowledged ? 1 : 0) sdk=\(sdkReturnedClean ? 1 : 0) terminal=\(terminal ? 1 : 0)"
        if let code = preparationFailureCode, let sequence = preparationFailureSequence, let error = preparationFailureError {
            summary += " prepCode=\(code) prepSequence=\(sequence) prepError=\(error)"
        }
        guard let phase, let code, let replyLength, let replyFields else { return summary }
        return summary + " phase=\(phase) code=\(code) length=\(replyLength) fields=\(replyFields) issuePhase=\(firstIssuePhase ?? 0) issueCode=\(firstIssueCode ?? 0)"
    }
}

/// One bounded current receipt. The existing fault journal retains first faults.
final class IridiumPSPHelperJournal {
    private let lock = NSLock()
    private let directory: URL?
    private var value: IridiumPSPHelperReceipt
    private(set) var healthy = true
    private static let filename = "iridium-psp-helper.json"
    init(attempt: String, hash: String, pid: Int32,
         directory: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first) {
        self.directory = directory
        value = IridiumPSPHelperReceipt(attempt: attempt, scriptSHA256: hash, targetPID: pid)
        if let directory { _ = mkdir(directory.path, 0o700) }
        healthy = value.valid && persist()
    }
    var receipt: IridiumPSPHelperReceipt { lock.lock(); defer { lock.unlock() }; return value }

    func receive(_ message: String) {
        guard message.hasPrefix("IRPSP1 ") || message.hasPrefix("IRPSP2 ") || message.hasPrefix("IRPSP3 ") else { return }
        lock.lock(); defer { lock.unlock() }
        guard healthy, !value.terminal else { return }
        if message.hasPrefix("IRPSP3 ") {
            receivePreparationFailureLocked(message)
            return
        }
        if message.hasPrefix("IRPSP2 ") {
            receiveDiagnosticLocked(message)
            return
        }
        guard message.utf8.count <= 160 else { failLocked(); return }
        let fields = message.split(separator: " ")
        guard fields.count == 6, fields[1].hasPrefix("event="), fields[2].hasPrefix("seq="),
              fields[3].hasPrefix("bytes="), fields[4].hasPrefix("addr="), fields[5] == "version=2",
              let sequence = Int(fields[2].dropFirst(4)), let bytes = Int(fields[3].dropFirst(6)),
              (0...4).contains(sequence), (0...16_777_216).contains(bytes) else { failLocked(); return }
        let event = String(fields[1].dropFirst(6)), address = String(fields[4].dropFirst(5))
        guard address.range(of: #"\A[0-9a-f]{16}\z"#, options: .regularExpression) != nil else { failLocked(); return }
        switch event {
        case "ready" where !value.ready && sequence == 0 && bytes == 0 && address == "0000000000000000":
            value.ready = true
        case "allocated" where value.ready && !value.detachAcknowledged && value.stage != "prepare.failed"
            && sequence == value.preparedCount + 1 && sequence == value.arenas.count + 1:
            let arena = IridiumPSPHelperArena(sequence: sequence, bytes: bytes, address: address)
            guard bytes == (sequence == 1 ? 16_777_216 : 262_144), let pointer = arena.pointer,
                  value.arenas.allSatisfy({ previous in
                      guard let other = previous.pointer else { return false }
                      return pointer >= other + UInt64(previous.bytes) || other >= pointer + UInt64(bytes)
                  }) else { failLocked(); return }
            value.arenas.append(arena)
        case "prepared" where value.ready && !value.detachAcknowledged && value.stage != "prepare.failed" && sequence == value.preparedCount + 1:
            guard bytes == (sequence == 1 ? 16_777_216 : 262_144),
                  let pointer = UInt64(address, radix: 16), pointer > 0, pointer & 16383 == 0,
                  pointer < (1 << 36), UInt64(bytes) <= (1 << 36) - pointer,
                  value.arenas.count == sequence, value.arenas.last?.address == address else { failLocked(); return }
            value.preparedCount = sequence
        case "prepare.failed" where value.ready && !value.detachAcknowledged && value.stage != "prepare.failed" && sequence == value.preparedCount + 1:
            break // Definitive return installation; helper can accept an owned abort.
        case "detach.ack" where value.ready && !value.detachAcknowledged && sequence == value.preparedCount && bytes == 0 && address == "0000000000000000":
            value.detachAcknowledged = true
        case "terminal":
            value.terminal = true
        default: failLocked(); return
        }
        value.stage = event; value.sequence = sequence; value.bytes = bytes
        value.address = address == "0000000000000000" ? nil : address
        healthy = value.valid && persist()
    }
    func sdkReturned(clean: Bool) {
        lock.lock(); defer { lock.unlock() }
        value.sdkReturnedClean = clean && value.detachAcknowledged && healthy && !value.terminal
        if !value.sdkReturnedClean, let phase = value.phase, (value.code ?? 0) < 2 {
            value.code = clean ? 29 : 30
            if value.firstIssueCode == nil { value.firstIssuePhase = phase; value.firstIssueCode = value.code }
        }
        value.terminal = !value.sdkReturnedClean
        value.stage = value.sdkReturnedClean ? "sdk.return" : "terminal"
        value.address = nil
        healthy = value.valid && persist()
    }
    private func receiveDiagnosticLocked(_ message: String) {
        // Malformed telemetry has no effect on the owned-operation state machine.
        guard message.utf8.count <= 160 else { return }
        let fields = message.split(separator: " ")
        guard fields.count == 6, fields[1].hasPrefix("phase="), fields[2].hasPrefix("code="),
              fields[3].hasPrefix("length="), fields[4].hasPrefix("fields="), fields[5] == "version=2",
              let phase = Int(fields[1].dropFirst(6)), let code = Int(fields[2].dropFirst(5)),
              let length = Int(fields[3].dropFirst(7)), let count = Int(fields[4].dropFirst(7)),
              IridiumPSPHelperReceipt.validDiagnostic(phase: phase, code: code, length: length, fields: count) else { return }
        value.phase = phase; value.code = code; value.replyLength = length; value.replyFields = count
        if code >= 2 && value.firstIssueCode == nil { value.firstIssuePhase = phase; value.firstIssueCode = code }
        healthy = value.valid && persist()
    }
    private func receivePreparationFailureLocked(_ message: String) {
        guard message.utf8.count <= 96, value.ready, !value.detachAcknowledged,
              value.preparationFailureCode == nil else { return }
        let fields = message.split(separator: " ")
        guard fields.count == 5, fields[1].hasPrefix("code="), fields[2].hasPrefix("seq="),
              fields[3].hasPrefix("error="), fields[4] == "version=2",
              let code = Int(fields[1].dropFirst(5)), [22, 23, 39].contains(code),
              let sequence = Int(fields[2].dropFirst(4)), (1...4).contains(sequence),
              sequence == value.preparedCount + 1,
              let error = Int(fields[3].dropFirst(6)), (0...255).contains(error),
              code != 22 || error == 0 else { return }
        value.preparationFailureCode = code; value.preparationFailureSequence = sequence
        value.preparationFailureError = error
        healthy = value.valid && persist()
    }
    private func failLocked() {
        value.stage = "terminal"; value.terminal = true
        healthy = persist()
    }
    private func persist() -> Bool {
        guard let directory, let data = try? JSONEncoder().encode(value), data.count <= 4096 else { return false }
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return false }; defer { close(folder) }
        var status = stat()
        let exists = fstatat(folder, Self.filename, &status, AT_SYMLINK_NOFOLLOW)
        guard (exists == 0 && status.st_mode & S_IFMT == S_IFREG && status.st_nlink == 1)
            || (exists != 0 && errno == ENOENT) else { return false }
        let temporary = ".psp-receipt-\(UUID().uuidString)"
        let file = openat(folder, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { return false }; defer { close(file); unlinkat(folder, temporary, 0) }
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }; offset += count
            }
            var result: Int32
            repeat { result = fsync(file) } while result < 0 && errno == EINTR
            return result == 0
        }
        return wrote && renameat(folder, temporary, folder, Self.filename) == 0
    }
    static func read(directory: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first) -> IridiumPSPHelperReceipt? {
        guard let directory else { return nil }
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return nil }; defer { close(folder) }
        let file = openat(folder, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return nil }; defer { close(file) }
        var status = stat()
        guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1, status.st_size > 0, status.st_size <= 4096 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(status.st_size)), offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }; offset += count
        }
        guard let result = try? JSONDecoder().decode(IridiumPSPHelperReceipt.self, from: Data(bytes)), result.valid else { return nil }
        return result
    }
}
