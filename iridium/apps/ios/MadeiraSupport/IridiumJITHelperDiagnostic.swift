// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

/// Appended to the generated helper by the declared Madeira diagnostic overlay.
/// Its private Documents journal survives either process ending. No shared group,
/// debugger operation or permission is introduced. The app retrieves a snapshot
/// through the existing helper request channel when the user exports diagnostics.
final class IridiumJITHelperDiagnostic {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var records = 0
    private var bytes = 0
    private let attemptID: String?
    private var faultRecorded = false

    init(directory: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
         attemptID: String = IridiumJITHelperSnapshot.newAttemptID()) {
        self.attemptID = IridiumJITHelperSnapshot.validAttemptID(attemptID) ? attemptID : nil
        guard self.attemptID != nil else { return }
        if let directory {
            _ = mkdir(directory.path, 0o700)
            let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if folder >= 0 {
                defer { close(folder) }
                var status = stat()
                let name = "iridium-jit-helper.log"
                let exists = fstatat(folder, name, &status, AT_SYMLINK_NOFOLLOW)
                let regular = status.st_mode & S_IFMT == S_IFREG && status.st_nlink == 1
                if (exists == 0 && regular && renameat(folder, name, folder, "iridium-jit-helper.previous.log") == 0)
                    || (exists != 0 && errno == ENOENT) {
                    descriptor = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                }
            }
        }
        let rawBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let build = rawBuild.range(of: #"\A[A-Za-z0-9._-]{1,40}\z"#, options: .regularExpression) != nil ? rawBuild : "unknown"
        append("IRJIT2 stage=helper.begin build=\(build)")
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    func receive(_ message: String) {
        // StikJIT may prepend a progress label. Never retain that prefix or any
        // unstructured payload; only an entire allowlisted suffix is accepted.
        guard message.utf8.count <= 2048, let range = message.range(of: "IRJIT2 ") else { return }
        let line = String(message[range.lowerBound...])
        guard !line.hasPrefix("IRJIT2 stage=helper.begin"),
              IridiumJITHelperSnapshot.validPayload(line) else { return }
        append(line)
    }

    private func append(_ line: String) {
        guard let attemptID, let publicLine = IridiumJITHelperSnapshot.publicPayload(line) else { return }
        lock.lock(); defer { lock.unlock() }
        let fault = line.hasPrefix("IRJIT2 stage=first.fault ")
        if fault && faultRecorded { return }
        let entry = String(format: "utc=%.6f ", Date().timeIntervalSince1970) + "attempt=\(attemptID) " + line + "\n"
        let data = Array(entry.utf8)
        guard records < 16, data.count <= 240, bytes + data.count <= 4096 else { return }
        if fault { faultRecorded = true }
        records += 1; bytes += data.count
        // Absolute fault locations remain only in the private 0600 journal.
        NSLog("[IRJIT2] %@", publicLine)
        guard descriptor >= 0 else { return }
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            var result: Int32
            repeat { result = fsync(descriptor) } while result < 0 && errno == EINTR
            return result == 0
        }
        if !wrote { close(descriptor); descriptor = -1 }
    }
}
