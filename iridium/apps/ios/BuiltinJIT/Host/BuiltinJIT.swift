import Foundation
import MadeiraNative

final class BuiltinJIT: NSObject, JITHost {
    static let shared = BuiltinJIT()
    static let settingKey = "IridiumBuiltinJIT"
    static var selected: Bool { UserDefaults.standard.bool(forKey: settingKey) }
    static var pairingURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT/pairingFile.plist")
    }
    static var isHosted: Bool {
        getenv("LC_HOME_PATH") != nil || Bundle.main.bundlePath.contains("/Documents/Applications/")
    }
    static func importPairing(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: url)
        try JITPairing.validate(data)
        try FileManager.default.createDirectory(at: pairingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: pairingURL, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var storedURL = pairingURL
        try storedURL.setResourceValues(values)
    }

    private var launcher: JITExtension?
    private var worker: JITWorker?
    private var onListening: (() -> Void)?
    private var report: ((String) -> Void)?
    private var lastStage: String?
    private var listening = false
    private var finishedSuccessfully = false
    private var operationFinished = false
    private var deadline: DispatchWorkItem?
    private let detached = DispatchGroup()

    // Call on the main thread. A failed/expired session is never silently sent to another provider.
    @discardableResult
    func start(onListening: @escaping () -> Void, report: @escaping (String) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard launcher == nil else { report("Restart Iridium before another built-in JIT attempt."); return false }
        guard #available(iOS 27, *) else { report("Built-in JIT requires iOS 27 or later."); return false }
        guard !Self.isHosted else { report("Built-in JIT requires standalone Iridium. Select external StikDebug in LiveContainer."); return false }
        guard IRHasDebugEntitlement() else { report("This installation lacks debugging permission. Sign Iridium with get-task-allow."); return false }
        guard !jit_check_debugged() else { report("A debugger is already attached. Restart Iridium without Xcode before using built-in JIT."); return false }
        let data: Data
        do { data = try Data(contentsOf: Self.pairingURL); try JITPairing.validate(data) }
        catch { report("Import a valid pairing file in Settings → Launch Support → Built-in JIT."); return false }
        self.onListening = onListening
        self.report = report
        detached.enter()
        let launcher = JITExtension()
        self.launcher = launcher
        launcher.failureHandler = { [weak self] message in self?.finished(message) }
        RuntimeLogCapture.writeLine("[Launch] Starting the built-in JIT helper.")
        launcher.start(withHost: self, hostProtocol: JITHost.self, workerProtocol: JITWorker.self) { [weak self] worker, error in
            guard let self else { return }
            guard let worker = worker as? JITWorker else {
                self.finished(error?.localizedDescription ?? "The built-in JIT helper did not start."); return
            }
            self.worker = worker
            worker.enable(getpid(), pairing: data)
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.operationFinished else { return }
            self.onListening = nil
            // Do not kill a possibly attached debugger: it may own a stopped host thread.
            self.finished("Built-in JIT timed out. Restart Iridium, then check LocalDevVPN and the pairing file.")
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: deadline)
        return true
    }

    func scriptListening() {
        DispatchQueue.main.async { [self] in
            guard !listening, !operationFinished, let start = onListening, jit_check_debugged() else { return }
            listening = true
            onListening = nil
            RuntimeLogCapture.writeLine("[Launch] JIT script attached. Preparing executable memory.")
            start()
        }
    }
    func preparation(_ stage: String) {
        DispatchQueue.main.async { [self] in
            guard !operationFinished, lastStage != stage else { return }
            lastStage = stage
            RuntimeLogCapture.writeLine("[Launch] \(stage)")
        }
    }
    func finished(_ error: String?) {
        DispatchQueue.main.async { [self] in
            guard !operationFinished else { return }
            operationFinished = true
            finishedSuccessfully = error == nil && listening
            deadline?.cancel()
            onListening = nil
            if !finishedSuccessfully {
                report?(error ?? "The helper ended before executable memory was ready. Restart Iridium.")
            } else {
                RuntimeLogCapture.writeLine("[Launch] Built-in JIT memory preparation and detach completed.")
            }
            detached.leave()
            // Successful return means the framework has released its debugger connection.
            // On failure keep the extension alive until app termination, avoiding a forced kill while attached.
            if finishedSuccessfully { launcher?.invalidate(); worker = nil }
        }
    }
    func waitForDetach() -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard detached.wait(timeout: .now() + 30) == .success else { return false }
        return DispatchQueue.main.sync { finishedSuccessfully && getenv("MADEIRA_DETACHED") != nil }
    }
}
