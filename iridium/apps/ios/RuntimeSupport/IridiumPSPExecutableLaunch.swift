// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit
import Darwin

/// Main owns launch transitions; one retained thread owns preflight calls. A stopped
/// target can prevent all app callbacks: none of these waits is a debugger timeout.
final class IridiumPSPExecutableLaunch: @unchecked Sendable {
    enum Outcome { case ready, fallback(String), restart(String) }
    // Stable journal values; never persist the unstructured reason string.
    private enum FallbackReason: Int64 {
        case observation = 1, cancelled, admission, owner, helper, preparation, probe
    }
    private let worker = PreflightWorker()
    private let diagnostic: IridiumJITDiagnostic
    private let component: String
    private let attempt = IridiumJITHelperSnapshot.newAttemptID()
    private let script = StikJITHelper.pspScriptData
    private let lock = NSLock()
    private let finalSignal = DispatchSemaphore(value: 0)
    private var finalResponse: MadeiraJITRequest.Response?
    private var cancelled = false
    private var observation: OpaquePointer?
    // Retained preflight-worker only. Later snapshots and final SDK completion
    // must preserve every previously accepted allocation, not merely its count.
    private var acceptedAllocations: [IridiumPSPHelperArena] = []
    private var preparedArenas = 0
    // These fields are main-queue confined.
    private var owner: UUID?
    private var startRequested = false
    private var workerStarted = false
    private var preparationReturned = false
    private(set) var finished = false
    var changed: (String) -> Void = { _ in }
    var completed: (Outcome) -> Void = { _ in }
    private var hash: String { SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined() }
    private var admission: UInt64 { UInt64(attempt, radix: 16) ?? 0 }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    init(diagnostic: IridiumJITDiagnostic, component: String) {
        self.diagnostic = diagnostic; self.component = component
    }
    deinit { worker.close(); if let observation { ir_psp_teardown_free(observation) } }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    @MainActor func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !finished, !startRequested else { return }
        startRequested = true
        guard !JITCoordinator.shared.pspRecoveryPending else {
            finish(.restart("An earlier network restoration is still pending. Complete Launch Support recovery and reopen Iridium before playing.")); return
        }
        changed("Inspecting PSP debugger teardown routes…")
        onWorker { [self] in
            var result = IRPSPObservationDiagnostic()
            guard let before = ir_psp_teardown_capture_diagnostic(&result) else {
                diagnostic.mark(IR_JIT_OBSERVATION_FAILED, pass: UInt32(result.failure.rawValue),
                                value: Int64(result.count), error: result.code) { _ in
                    DispatchQueue.main.async {
                        self.fallback(.observation, "Required app/worker debugger-route observations are unavailable or unrecognized.")
                    }
                }
                return
            }
            observation = before
            DispatchQueue.main.async { [self] in
                if isCancelled { fallback(.cancelled, "JIT preparation was cancelled."); return }
                changed("Starting the owned PSP helper…")
                // Persist the attempt before any activation/network mutation.
                diagnostic.mark(IR_JIT_ACTIVATION_ENTER, value: Int64(bitPattern: admission)) { persisted in
                    guard persisted, !self.isCancelled else {
                        self.fallback(self.isCancelled ? .cancelled : .admission, "The PSP attempt could not be durably admitted."); return
                    }
                    guard !JITCoordinator.shared.pspRecoveryPending else {
                        self.finish(.restart("Network restoration is still pending. Fully close and reopen Iridium after recovery.")); return
                    }
                    self.owner = JITCoordinator.shared.beginPSP(attempt: self.attempt, hash: self.hash, script: self.script,
                    shouldProceed: { !self.isCancelled },
                    started: { DispatchQueue.main.async { self.pollReady(remaining: 12) } },
                    final: { requested, result in
                        DispatchQueue.main.async { self.helperReturned(requested: requested, result: result) }
                    })
                    if self.owner == nil { self.fallback(.owner, "PSP requires an available owned built-in helper and no foreign debugger.") }
                }
            }
        }
    }
    private func matches(_ receipt: IridiumPSPHelperReceipt) -> Bool {
        receipt.matches(attempt: attempt, hash: hash, pid: getpid())
    }
    @MainActor private func helperReturned(requested: Bool, result: Result<MadeiraJITRequest.Response, Error>) {
        dispatchPrecondition(condition: .onQueue(.main))
        if case .success(let response) = result {
            lock.lock(); finalResponse = response; lock.unlock()
            if let receipt = response.pspReceipt, receipt.valid { RuntimeDiagnosticLogFiles.writeConsoleLine(receipt.publicSummary) }
        }
        finalSignal.signal()
        guard !finished, !workerStarted else { return }
        workerStarted = true
        if !requested {
            restore(prepared: false, shutdown: true, reason: "The PSP helper was not started.", fallbackReason: .helper)
        } else {
            // A failed/interrupted original operation is not an owned detach,
            // even if a subsequent read-only route snapshot happens to match.
            restore(prepared: false, shutdown: false, reason: "The PSP helper stopped before verified owned teardown.")
        }
    }
    @MainActor private func pollReady(remaining: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !finished, !workerStarted else { return }
        MadeiraBuiltInJIT.pspSnapshot(attempt: attempt) { [self] receipt in
            guard !finished, !workerStarted else { return }
            if let receipt, matches(receipt), receipt.ready, !receipt.terminal, receipt.preparedCount == 0 {
                workerStarted = true
                diagnostic.mark(IR_JIT_ACTIVATION_RETURN, value: 1)
                changed("Preparing four bounded PSP executable arenas…")
                onWorker { self.prepareAndDetach() }
                // Best-effort UI observation, not command cancellation or an
                // all-stop recovery deadline. Keep the context and lease.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    guard !self.finished, !self.preparationReturned else { return }
                    self.cancel(); ir_psp_native_exec_cancel(self.admission)
                    self.diagnostic.mark(IR_JIT_TIMEOUT)
                    self.finish(.restart("PSP preparation has not completed. Fully close and reopen Iridium."))
                }
            } else if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.pollReady(remaining: remaining - 1) }
            } else {
                // Unknown attachment is terminal. Do not issue a speculative BRK.
                workerStarted = true
                restore(prepared: false, shutdown: false, reason: "The owned helper did not provide a current ready receipt.")
            }
        }
    }
    private func snapshot() -> IridiumPSPHelperReceipt? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let signal = DispatchSemaphore(value: 0)
        let box = ReceiptBox()
        DispatchQueue.main.async {
            MadeiraBuiltInJIT.pspSnapshot(attempt: self.attempt) { value in box.set(value); signal.signal() }
        }
        // A normal request wait only; target all-stop can prevent this code running.
        guard signal.wait(timeout: .now() + 3) == .success else { return nil }
        return box.get()
    }
    private func allocateRegion(_ owned: UnsafeMutablePointer<UnsafeMutableRawPointer?>?, bytes: Int, sequence: UInt32) -> Int32 {
        guard let owned else { return Int32(IR_PSP_EXEC_IDENTITY.rawValue) }
        owned.pointee = nil
        guard !isCancelled else { return Int32(IR_PSP_EXEC_CLOSING.rawValue) }
        guard (1...4).contains(sequence), bytes == (sequence == 1 ? 16_777_216 : 262_144) else {
            return Int32(IR_PSP_EXEC_IDENTITY.rawValue)
        }
        let result = ir_psp_owned_allocate_region(UInt(bytes), sequence)
        guard let receipt = snapshot(), matches(receipt), !receipt.terminal,
              receipt.ready, !receipt.detachAcknowledged, !receipt.sdkReturnedClean,
              receipt.sequence == Int(sequence), receipt.bytes == bytes,
              acceptedAllocations.count == Int(sequence) - 1,
              Array(receipt.arenas.prefix(acceptedAllocations.count)) == acceptedAllocations else {
            return Int32(IR_PSP_EXEC_UNCERTAIN.rawValue)
        }
        let allocation = receipt.arenas.count == Int(sequence) ? receipt.arenas.last : nil
        let address = allocation?.pointer.flatMap { UnsafeMutableRawPointer(bitPattern: UInt($0)) }
        if let address, result == address, receipt.address == allocation?.address,
           receipt.stage == "prepared", receipt.preparedCount == Int(sequence) {
            acceptedAllocations = receipt.arenas; preparedArenas = Int(sequence)
            owned.pointee = address; return 0
        }
        if result == nil, receipt.stage == "prepare.failed", receipt.preparedCount == Int(sequence) - 1,
           (allocation != nil ? address != nil && receipt.address == allocation?.address
                : receipt.arenas.count == Int(sequence) - 1 && receipt.address == nil) {
            acceptedAllocations = receipt.arenas
            owned.pointee = address // Definitive allocated failure still belongs to cleanup.
            return Int32(IR_PSP_EXEC_PREPARATION.rawValue)
        }
        return Int32(IR_PSP_EXEC_UNCERTAIN.rawValue)
    }
    private func prepareAndDetach() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var prepared = false
        var result: Int32 = Int32(IR_PSP_EXEC_CLOSING.rawValue)
        if !isCancelled {
            var host = IRPSPExecHost()
            host.size = UInt32(MemoryLayout<IRPSPExecHost>.size); host.version = UInt32(IR_PSP_EXEC_VERSION)
            host.admission = admission; host.generation = 1; host.attempt = admission
            let digest = Data(SHA256.hash(data: script))
            withUnsafeMutableBytes(of: &host.script_sha256) { $0.copyBytes(from: digest) }
            host.context = Unmanaged.passUnretained(self).toOpaque()
            host.prepare = { context, owned, bytes, sequence in
                guard let context else { return Int32(IR_PSP_EXEC_IDENTITY.rawValue) }
                return Unmanaged<IridiumPSPExecutableLaunch>.fromOpaque(context).takeUnretainedValue().allocateRegion(owned, bytes: bytes, sequence: sequence)
            }
            host.detach = { _ in ir_psp_owned_detach() }
            result = withUnsafePointer(to: &host) { diagnostic.prepare(component: component, host: $0) }
            prepared = result == 0
        }
        let uncertain = result == Int32(IR_PSP_EXEC_UNCERTAIN.rawValue)
        let returned: Bool
        if uncertain { returned = false }
        else if result == Int32(IR_PSP_EXEC_UNAVAILABLE.rawValue) || (isCancelled && result == Int32(IR_PSP_EXEC_CLOSING.rawValue)) {
            returned = ir_psp_owned_detach() == 0 // Ready, owned script; no arena request was issued.
        } else { returned = ir_psp_native_exec_detach(admission) == 0 }
        let received = returned && finalSignal.wait(timeout: .now() + 5) == .success
        lock.lock(); let response = finalResponse; lock.unlock()
        let receipt = response?.pspReceipt
        let clean = received && response?.success == true && response?.diagnosticAttemptID == attempt &&
            receipt.map { matches($0) && $0.detachAcknowledged && $0.sdkReturnedClean && !$0.terminal
                && $0.arenas == acceptedAllocations && $0.preparedCount == preparedArenas } == true
        var observationResult = IRPSPObservationDiagnostic()
        let routes = clean && ir_psp_teardown_matches_diagnostic(observation, &observationResult)
        if clean && !routes { recordObservationFailure(observationResult) }

        var accepted = !prepared
        if prepared && routes {
            var shutdown = IRPSPExecShutdown()
            shutdown.size = UInt32(MemoryLayout<IRPSPExecShutdown>.size); shutdown.version = UInt32(IR_PSP_EXEC_VERSION)
            shutdown.flags = UInt32(IR_PSP_SHUTDOWN_ALL); shutdown.admission = admission
            shutdown.generation = 1; shutdown.attempt = admission
            withUnsafeMutableBytes(of: &shutdown.script_sha256) { $0.copyBytes(from: Data(SHA256.hash(data: script))) }
            accepted = ir_psp_native_exec_shutdown(&shutdown) == 0
        }
        DispatchQueue.main.async {
            self.preparationReturned = true
            self.restore(prepared: prepared && accepted, shutdown: routes,
                         reason: "PSP preparation or owned debugger teardown could not be verified.")
        }
    }
    @MainActor private func restore(prepared: Bool, shutdown: Bool, reason: String,
                                    fallbackReason: FallbackReason = .preparation) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !finished, let owner else { return }
        if !shutdown { ir_psp_native_exec_cancel(admission) }
        changed("Restoring PSP network settings…")
        diagnostic.mark(IR_JIT_RESTORE_ENTER)
        JITCoordinator.shared.restorePSP(owner: owner) { [self] restored in
            diagnostic.mark(IR_JIT_RESTORE_RETURN, value: restored ? 1 : 0)
            guard restored && shutdown else {
                ir_psp_native_exec_cancel(admission)
                finish(.restart(restored ? reason : "Network restoration remains pending. Fully close and reopen Iridium.")); return
            }
            if !prepared || isCancelled {
                onWorker {
                    let ended = ir_psp_native_exec_end(self.admission) == 0
                    DispatchQueue.main.async {
                        if ended { JITCoordinator.shared.releasePSP(owner: owner) }
                        if ended { self.fallback(self.isCancelled ? .cancelled : fallbackReason, reason) }
                        else { self.finish(.restart("PSP executable memory has not drained. Restart required.")) }
                    }
                }
                return
            }
            changed("Verifying restored PSP mappings and the 42/7 probe…")
            let worker = IridiumJITWorkerReceipt()
            onWorker {
                guard self.diagnostic.restored(admission: self.admission) == 0 else {
                    DispatchQueue.main.async {
                        worker.returned = true
                        guard !self.finished else { return }
                        self.finish(.restart("PSP restoration receipt did not match. Restart required."))
                    }
                    return
                }
                var observationResult = IRPSPObservationDiagnostic()
                guard ir_psp_teardown_matches_diagnostic(self.observation, &observationResult) else {
                    self.recordObservationFailure(observationResult) {
                        DispatchQueue.main.async {
                            worker.returned = true
                            guard !self.finished else { return }
                            ir_psp_native_exec_cancel(self.admission)
                            self.finish(.restart("App/worker observations changed after restoration. Restart required."))
                        }
                    }
                    return
                }
                let result = self.isCancelled ? 0 : self.diagnostic.check(component: self.component)
                DispatchQueue.main.async {
                    worker.returned = true
                    guard !self.finished else { return }
                    if result == 1 && !self.isCancelled {
                        JITCoordinator.shared.releasePSP(owner: owner); self.finish(.ready)
                    } else {
                        self.onWorker {
                            let ended = ir_psp_native_exec_end(self.admission) == 0
                            DispatchQueue.main.async {
                                if ended { JITCoordinator.shared.releasePSP(owner: owner) }
                                if ended { self.fallback(self.isCancelled ? .cancelled : .probe, "PPSSPP did not verify executable code after restoration.") }
                                else { self.finish(.restart("The PSP worker has not drained. Restart required.")) }
                            }
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard !worker.returned, !self.finished else { return }
                self.cancel(); ir_psp_native_exec_cancel(self.admission)
                self.diagnostic.mark(IR_JIT_TIMEOUT)
                self.finish(.restart("The PSP execution probe has not returned. Fully close and reopen Iridium."))
            }
        }
    }
    @MainActor private func fallback(_ reason: FallbackReason, _ message: String) {
        guard !finished else { return }
        finished = true; worker.close()
        // Attempt the durable terminal mark before handing control to the player.
        // I/O failure must not promote, decline differently, or retry this launch.
        diagnostic.mark(IR_JIT_FALLBACK, value: reason.rawValue) { _ in
            DispatchQueue.main.async { self.completed(.fallback(message)) }
        }
    }
    @MainActor private func finish(_ outcome: Outcome) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !finished else { return }
        finished = true; worker.close(); completed(outcome)
    }
    private func recordObservationFailure(_ result: IRPSPObservationDiagnostic,
                                          completed: @escaping @Sendable () -> Void = {}) {
        diagnostic.mark(IR_JIT_OBSERVATION_FAILED, pass: UInt32(result.failure.rawValue),
                        value: Int64(result.count), error: result.code) { _ in completed() }
    }
    @MainActor private func onWorker(_ operation: @escaping @Sendable () -> Void) {
        guard !finished else { return }
        guard worker.submit(operation) else {
            finish(.restart("The PSP preflight worker is unavailable. Restart required.")); return
        }
    }
    // A serial GCD queue may switch threads. This thread stays alive across the
    // main-thread helper/network callbacks; close never interrupts an active call.
    private final class PreflightWorker: @unchecked Sendable {
        private let condition = NSCondition()
        private var operations: [@Sendable () -> Void] = []
        private var closing = false
        init() {
            let thread = Thread { [self] in run() }
            thread.name = "software.iridium.psp-preflight"
            thread.start()
        }
        func submit(_ operation: @escaping @Sendable () -> Void) -> Bool {
            condition.lock(); defer { condition.unlock() }
            guard !closing else { return false }
            operations.append(operation); condition.signal(); return true
        }
        func close() {
            condition.lock(); closing = true; condition.signal(); condition.unlock()
        }
        private func run() {
            while true {
                condition.lock()
                while operations.isEmpty && !closing { condition.wait() }
                guard !operations.isEmpty else { condition.unlock(); return }
                let operation = operations.removeFirst()
                condition.unlock()
                autoreleasepool { operation() }
            }
        }
    }
    private final class ReceiptBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: IridiumPSPHelperReceipt?
        func set(_ value: IridiumPSPHelperReceipt?) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> IridiumPSPHelperReceipt? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
