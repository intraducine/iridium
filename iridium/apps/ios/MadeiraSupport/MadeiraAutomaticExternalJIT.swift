import Foundation

enum MadeiraAutomaticExternalJIT {
    private enum ActiveHelper: Equatable {
        case stik
        case stikDebug
        case liveContainer3
    }

    private static let automaticRoutes: [StikJITHelper.Route] = [
        .livecontainer2,
        .stikdebug,
        .livecontainer,
    ]
    private static var watchdog: Timer?
    private static var completion: ((Bool) -> Void)?
    private static var request = UUID()
    private static var activeHelper: ActiveHelper?
    private(set) static var lastFailure = "Automatic JIT did not enable JIT."

    static func enableJIT(
        routeTimeout: TimeInterval = 8,
        completion: @escaping (Bool) -> Void
    ) {
        cancel()
        self.completion = completion
        let token = UUID()
        request = token
        let timeout = max(routeTimeout, 0.01)
        let wasDebugged = jit_check_debugged()
        var timedOutHelper: ActiveHelper?

        func finish(_ success: Bool, message: String? = nil) {
            guard request == token, let callback = Self.completion else { return }
            watchdog?.invalidate()
            watchdog = nil
            activeHelper = nil
            request = UUID()
            if let message {
                lastFailure = message
                RuntimeLogCapture.writeLine("[Launch] \(message)")
            }
            Self.completion = nil
            callback(success)
        }

        func cancelHelper(_ helper: ActiveHelper) {
            switch helper {
            case .stik:
                StikJITHelper.cancel()
            case .stikDebug:
                MadeiraStikDebugJIT.cancel()
            case .liveContainer3:
                MadeiraLiveContainer3JIT.cancel()
            }
        }

        func armWatchdog(_ helper: ActiveHelper, message: String) {
            watchdog?.invalidate()
            watchdog = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                guard request == token, Self.completion != nil, activeHelper == helper else { return }
                // If this request started without a debugger and attachment has now
                // appeared, let the helper's own poll complete the request instead of
                // racing it with a cancellation on the same run-loop turn.
                if !wasDebugged && jit_check_debugged() {
                    return
                }
                timedOutHelper = helper
                RuntimeLogCapture.writeLine("[Launch] \(message)")
                cancelHelper(helper)
            }
        }

        func startLiveContainer3() {
            guard request == token, Self.completion != nil else { return }
            RuntimeLogCapture.writeLine(
                "[Launch] Existing automatic JIT routes did not attach. Trying LiveContainer3."
            )
            var completedSynchronously = false
            activeHelper = .liveContainer3
            MadeiraLiveContainer3JIT.enableJIT { ready in
                completedSynchronously = true
                guard request == token, Self.completion != nil else { return }
                watchdog?.invalidate()
                watchdog = nil
                activeHelper = nil
                let timedOut = timedOutHelper == .liveContainer3
                timedOutHelper = nil
                if ready {
                    finish(true)
                } else if timedOut {
                    finish(
                        false,
                        message: "Automatic JIT routes opened, but none attached JIT to Iridium."
                    )
                } else {
                    finish(false, message: MadeiraLiveContainer3JIT.lastFailure)
                }
            }
            if !completedSynchronously, request == token, activeHelper == .liveContainer3 {
                armWatchdog(
                    .liveContainer3,
                    message: "LiveContainer3 opened but did not attach JIT."
                )
            }
        }

        func startRoute(_ index: Int) {
            guard request == token, Self.completion != nil else { return }
            guard index < automaticRoutes.count else {
                startLiveContainer3()
                return
            }

            let chosen = automaticRoutes[index]
            let defaults = UserDefaults.standard
            let previousRoute = defaults.object(forKey: StikJITHelper.routeKey)
            defaults.set(chosen.rawValue, forKey: StikJITHelper.routeKey)

            var completedSynchronously = false
            let helper: ActiveHelper = chosen == .stikdebug ? .stikDebug : .stik
            activeHelper = helper
            let callback: (Bool) -> Void = { ready in
                completedSynchronously = true
                guard request == token, Self.completion != nil else { return }
                watchdog?.invalidate()
                watchdog = nil
                activeHelper = nil
                let timedOut = timedOutHelper == helper
                timedOutHelper = nil
                if ready {
                    finish(true)
                    return
                }
                if !timedOut {
                    RuntimeLogCapture.writeLine(
                        "[Launch] \(chosen.title) did not enable JIT. Trying the next automatic route."
                    )
                }
                DispatchQueue.main.async {
                    guard request == token, Self.completion != nil else { return }
                    startRoute(index + 1)
                }
            }

            if chosen == .stikdebug {
                MadeiraStikDebugJIT.enableJIT(completion: callback)
            } else {
                StikJITHelper.enableJIT(completion: callback)
            }

            if let previousRoute {
                defaults.set(previousRoute, forKey: StikJITHelper.routeKey)
            } else {
                defaults.removeObject(forKey: StikJITHelper.routeKey)
            }

            if !completedSynchronously, request == token, activeHelper == helper {
                armWatchdog(
                    helper,
                    message: "\(chosen.title) opened but did not attach JIT. Trying the next automatic route."
                )
            }
        }

        startRoute(0)
    }

    static func cancel() {
        guard let callback = completion else { return }
        let helper = activeHelper
        completion = nil
        request = UUID()
        watchdog?.invalidate()
        watchdog = nil
        activeHelper = nil
        switch helper {
        case .stik:
            StikJITHelper.cancel()
        case .stikDebug:
            MadeiraStikDebugJIT.cancel()
        case .liveContainer3:
            MadeiraLiveContainer3JIT.cancel()
        case nil:
            break
        }
        lastFailure = "Automatic JIT request cancelled."
        callback(false)
    }
}
