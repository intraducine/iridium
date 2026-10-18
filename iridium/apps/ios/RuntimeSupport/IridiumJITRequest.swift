// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
typealias IridiumJITCleanup = (@escaping () -> Void) -> Void

/// A launch subscribes to the app's existing activation service. Cancelling it
/// discards its continuation, never terminates a helper that owns the debugger.
final class IridiumJITRequest {
    enum State: Equatable {
        case off, activating, validating, restoring, ready, fallback(String)
        var message: String {
            switch self {
            case .off: return "Off — using IR interpreter"
            case .activating: return "Enabling shared JIT support…"
            case .validating: return "Checking PPSSPP JIT…"
            case .restoring: return "Restoring JIT network settings…"
            case .ready: return "PPSSPP JIT verified for this launch"
            case .fallback(let reason): return "Using IR interpreter. " + reason
            }
        }
    }
    private(set) var state = State.off
    private var request: UUID?
    var changed: (State) -> Void = { _ in }

    func start(requested: Bool,
               activate: (@escaping (Result<Void, Error>) -> Void) -> Void,
               validate: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void,
               cleanup: @escaping IridiumJITCleanup = { $0() },
               completed: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard request == nil else { return }
        guard requested else { publish(.off); completed(false); return }
        let token = UUID(); request = token
        var activationFinished = false, validationFinished = false, cleanupStarted = false
        publish(.activating)
        func finish(_ result: Result<Void, Error>) {
            dispatchPrecondition(condition: .onQueue(.main))
            guard !cleanupStarted else { return }
            cleanupStarted = true
            if self.request == token { self.publish(.restoring) }
            cleanup {
                guard self.request == token else { return }
                self.request = nil
                switch result {
                case .success: self.publish(.ready); completed(true)
                case .failure(let error): self.publish(.fallback(error.localizedDescription)); completed(false)
                }
            }
        }
        activate { [weak self] result in
            dispatchPrecondition(condition: .onQueue(.main))
            guard !activationFinished else { return }
            activationFinished = true
            guard let self, self.request == token, self.state == .activating else { finish(result); return }
            switch result {
            case .failure: finish(result)
            case .success:
                self.publish(.validating)
                validate { result in
                    dispatchPrecondition(condition: .onQueue(.main))
                    guard !validationFinished else { return }
                    validationFinished = true
                    // Cleanup owns this activation even when its game was cancelled.
                    finish(result)
                }
            }
        }
    }

    func cancel() { dispatchPrecondition(condition: .onQueue(.main)); request = nil }
    private func publish(_ value: State) { state = value; changed(value) }
}
