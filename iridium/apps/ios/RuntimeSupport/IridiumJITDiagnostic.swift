// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

@MainActor final class IridiumJITWorkerReceipt { var returned = false }

/// Immutable handle; the C journal serializes normal-context writers with a mutex.
/// Each queued closure/worker retains this owner. Cancel/timeout never close it.
final class IridiumJITDiagnostic: @unchecked Sendable {
    private let handle: OpaquePointer
    func prepareShared(component: String, admission: UInt64, api: UnsafePointer<IRJITMemoryAPI>?) -> Int32 {
        component.withCString { ir_psp_native_exec_prepare_shared($0, admission, api, handle) }
    }
    private let io = DispatchQueue(label: "software.iridium.psp-jit-stages", qos: .utility)
    private init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { ir_psp_jit_diagnostic_close(handle) }

    static func create(directory: URL, identity: String, completed: @escaping (IridiumJITDiagnostic?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let handle = directory.path.withCString { path in
                identity.withCString { ir_psp_jit_diagnostic_open(path, $0) }
            }
            let owner = handle.map { IridiumJITDiagnostic($0) }
            DispatchQueue.main.async { completed(owner) }
        }
    }
    func mark(_ stage: IRJITDiagnosticStage, pass: UInt32 = 0, value: Int64 = 0, error: Int32 = 0,
              completed: @escaping (Bool) -> Void = { _ in }) {
        io.async { [self] in
            let persisted = ir_psp_jit_diagnostic_mark(handle, stage, pass, value, error)
            DispatchQueue.main.async { [self] in withExtendedLifetime(self) { completed(persisted) } }
        }
    }
    func check(component: String) -> Int32 {
        dispatchPrecondition(condition: .notOnQueue(.main))
        _ = ir_psp_jit_diagnostic_mark(handle, IR_JIT_WORKER_ENTER, 0, 0, 0)
        let result = component.withCString { ir_psp_native_check_jit_diagnostic($0, handle) }
        return ir_psp_jit_diagnostic_mark(handle, IR_JIT_WORKER_RETURN, 0, Int64(result), 0) ? result : -6
    }
    func prepare(component: String, host: UnsafePointer<IRPSPExecHost>) -> Int32 {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return component.withCString { ir_psp_native_exec_prepare($0, host, handle) }
    }
    func restored(admission: UInt64) -> Int32 {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return ir_psp_native_exec_restored_diagnostic(admission, true, handle)
    }
}
