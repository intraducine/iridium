import CryptoKit
// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

// Madeira's JIT helper: a classic app extension that Madeira starts by its bundle ID
// (app/Madeira/JITBuiltInHost.swift), so a sideloader's renamed install still finds it.
// One MadeiraJITRequest per extension request, answered when the request completes.

import Foundation
#if !targetEnvironment(simulator)
import StikJIT
#endif

#if targetEnvironment(simulator)
private struct DDIPaths {
    static func `default`(in directory: URL) -> DDIPaths { DDIPaths() }
}

private enum StikJIT {
    enum Script { case customBase64(String) }
    struct DeviceSecurityState { let isTXMPresent: Bool? }
    enum PreparationStage { case unavailable }
    enum JITReadiness {
        case unreachable(reason: String)
        case preparationFailed(reason: String)
        case ready(DeviceSecurityState)
    }

    static var isTXMPresent: Bool? { nil }
    static func prepareDevice(pairingFile: URL, paths: DDIPaths,
                              progress: (PreparationStage) -> Void) -> JITReadiness {
        .unreachable(reason: "Built-in JIT is available only on a physical device.")
    }
    static func enableJIT(targetPID: Int32, pairingFile: URL, ddiPaths: DDIPaths,
                          script: Script, forceScript: Bool,
                          preparationProgress: (PreparationStage) -> Void,
                          progress: (String) -> Void) throws {
        throw NSError(domain: "MadeiraJITHelper", code: 100,
                      userInfo: [NSLocalizedDescriptionKey:
                        "Built-in JIT is available only on a physical device."])
    }
    static func resetCachedDDI(at paths: DDIPaths) throws {}
}
#endif

private enum MadeiraJITWork {
    /// One request at a time, as the XPC handler ran them before.
    static let queue = DispatchQueue(label: "com.willfaust.madeora.jit-helper")

    static func handle(_ request: MadeiraJITRequest) -> MadeiraJITRequest.Response {
        if request.operation == .diagnostics {
            guard let attempt = request.diagnosticAttemptID, IridiumJITHelperSnapshot.validAttemptID(attempt) else {
                return .init(success: false, message: "Invalid helper diagnostic request.", txmPresent: nil)
            }
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            return .init(success: true, message: "Helper diagnostic snapshot.", txmPresent: nil,
                         diagnosticAttemptID: attempt,
                         diagnosticRecords: directory.map { IridiumJITHelperSnapshot.read(in: $0) } ?? [],
                         pspReceipt: IridiumPSPHelperJournal.read().flatMap { receipt in
                             request.pspAttemptID == nil || request.pspAttemptID == receipt.attempt ? receipt : nil
                         })
        }
        var pspJournal: IridiumPSPHelperJournal?
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true,
                             message: "Developer Disk Image cache reset.",
                             txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "MadeiraJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file was not provided."])
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL, paths: paths,
                    progress: { NSLog("[MadeiraJIT] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready(let security):
                    return .init(success: true,
                                 message: "LocalDevVPN is reachable and the Developer Disk Image is ready.",
                                 txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason,
                                 txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false,
                                 message: "StikJIT returned an unknown preparation state.",
                                 txmPresent: StikJIT.isTXMPresent)
                }
            case .enable:
                guard let targetPID = request.targetPID,
                      let scriptBase64 = request.scriptBase64,
                      !scriptBase64.isEmpty else {
                    throw NSError(domain: "MadeiraJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "The target process or Madeira JIT script was not provided."])
                }
                if request.pspProtocolVersion != nil {
                    guard request.pspProtocolVersion == 2,
                          let attempt = request.pspAttemptID, IridiumJITHelperSnapshot.validAttemptID(attempt),
                          request.diagnosticAttemptID == attempt,
                          let script = Data(base64Encoded: scriptBase64), script.count <= 65536,
                          String(decoding: script, as: UTF8.self).contains("IRIDIUM_PSP_PREPARED_V2"),
                          let expected = request.pspScriptSHA256,
                          SHA256.hash(data: script).map({ String(format: "%02x", $0) }).joined() == expected else {
                        throw NSError(domain: "IridiumPSPHelper", code: 1)
                    }
                    let journal = IridiumPSPHelperJournal(attempt: attempt, hash: expected, pid: targetPID)
                    guard journal.healthy else { throw NSError(domain: "IridiumPSPHelper", code: 2) }
                    pspJournal = journal
                }
                let diagnostic = IridiumJITHelperDiagnostic(attemptID: request.diagnosticAttemptID ?? IridiumJITHelperSnapshot.newAttemptID())
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    script: .customBase64(scriptBase64),
                    forceScript: true,
                    preparationProgress: {
                        if pspJournal == nil { NSLog("[MadeiraJIT] prepare: %@", String(describing: $0)) }
                    },
                    progress: { diagnostic.receive($0); pspJournal?.receive($0) })
                pspJournal?.sdkReturned(clean: true)
                if let pspJournal {
                    let receipt = pspJournal.receipt
                    return .init(success: pspJournal.healthy && receipt.sdkReturnedClean,
                                 message: "PSP helper operation returned.", txmPresent: StikJIT.isTXMPresent,
                                 diagnosticAttemptID: request.diagnosticAttemptID, pspReceipt: receipt)
                }
                return .init(success: true,
                             message: "Madeira detached cleanly from its built-in JIT helper.",
                             txmPresent: StikJIT.isTXMPresent)
            case .resetDDI, .diagnostics:
                preconditionFailure("Handled above")
            }
        } catch {
            if let pspJournal {
                pspJournal.sdkReturned(clean: false)
                return .init(success: false, message: "PSP helper failed; restart may be required.",
                             txmPresent: StikJIT.isTXMPresent, diagnosticAttemptID: request.diagnosticAttemptID,
                             pspReceipt: pspJournal.receipt)
            }
            return .init(success: false, message: error.localizedDescription,
                         txmPresent: StikJIT.isTXMPresent)
        }
    }
}

/// NSExtensionPrincipalClass (Info.plist). The request arrives as JSON in the first input
/// item; the response goes back as JSON in the item the request completes with. Enable
/// completes only when Madeira's script has detached, so the request, and this process,
/// last as long as the debugger does.
@objc(MadeiraJITHelperHandler)
final class MadeiraJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[MadeiraJITRequest.itemKey] as? Data
        let diagnosticRequest = data.flatMap { try? JSONDecoder().decode(MadeiraJITRequest.self, from: $0) }?.operation == .diagnostics
        let queue = diagnosticRequest ? DispatchQueue.global(qos: .utility) : MadeiraJITWork.queue
        queue.async {
            let response: MadeiraJITRequest.Response
            if let data, let request = try? JSONDecoder().decode(MadeiraJITRequest.self, from: data) {
                response = MadeiraJITWork.handle(request)
            } else {
                response = .init(success: false, message: "Madeira's JIT helper received no request.",
                                 txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [MadeiraJITRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}

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
